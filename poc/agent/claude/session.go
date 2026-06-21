package claude

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"crosslink-poc/ollama"
)

// Session manages a long-running Claude CLI subprocess.
// It implements both ollama.Backend and ollama.ExtendedBackend.
type Session struct {
	cfg Config

	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser
	stderr io.ReadCloser

	sessionID string // returned by Claude in system/init
	model     string // current model

	eventCb func(ollama.BackendEvent) // event callback (ExtendedBackend)
	models  []ollama.ModelInfo        // cached model list

	// Per-invocation streaming state
	mu       sync.Mutex
	tokenCh  chan string    // ChatStream token output
	errCh    chan error     // ChatStream error output
	parseCh  chan ParseEvent // parser events
	ctx      context.Context
	cancel   context.CancelFunc

	// Tool accumulation state
	toolInputBuf  map[string]json.RawMessage // tool_use ID → accumulated input JSON
	toolNameByID  map[string]string          // tool_use ID → tool name

	// Last completion usage (exposed via LastUsage())
	lastInputTokens  int
	lastOutputTokens int
	lastStopReason   string

	// Reconnect state
	reconnectCount int
}

// Ensure interface compliance.
var _ ollama.Backend = (*Session)(nil)
var _ ollama.ExtendedBackend = (*Session)(nil)

// NewSession creates and starts a Claude CLI subprocess.
// Returns an error if the binary cannot be found or the process fails to start.
func NewSession(cfg Config) (*Session, error) {
	if cfg.BinaryPath == "" {
		cfg = DefaultConfig()
	}
	if cfg.Model == "" {
		cfg.Model = "sonnet"
	}

	s := &Session{
		cfg:          cfg,
		model:        cfg.Model,
		models:       defaultModels(),
		toolInputBuf: make(map[string]json.RawMessage),
		toolNameByID: make(map[string]string),
	}

	if err := s.start(); err != nil {
		return nil, err
	}

	return s, nil
}

// ---- Backend interface ----

func (s *Session) ChatStream(req ollama.ChatRequest) (<-chan string, <-chan error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// If we're recovering from a crash, reconnect first
	if s.cmd == nil || s.ctx.Err() != nil {
		if err := s.start(); err != nil {
			errs := make(chan error, 1)
			errs <- fmt.Errorf("claude restart failed: %w", err)
			close(errs)
			return nil, errs
		}
	}

	// Reset per-turn state
	s.tokenCh = make(chan string, 64)
	s.errCh = make(chan error, 1)
	s.toolInputBuf = make(map[string]json.RawMessage)
	s.toolNameByID = make(map[string]string)

	// Extract the last user message as the prompt
	userContent := ""
	if len(req.Messages) > 0 {
		userContent = req.Messages[len(req.Messages)-1].Content
	}

	// Model switch if requested
	if req.Model != "" && req.Model != s.model {
		s.writeControl(map[string]any{
			"subtype": "set_model",
			"model":   req.Model,
		})
		s.model = req.Model
	}

	// Write user message
	msg := userMsg{
		Type: "user",
		Message: userMsgInner{
			Role:    "user",
			Content: userContent,
		},
	}
	data, _ := json.Marshal(msg)
	if _, err := io.WriteString(s.stdin, string(data)+"\n"); err != nil {
		errs := make(chan error, 1)
		errs <- fmt.Errorf("write to claude stdin: %w", err)
		close(errs)
		s.closeProcess()
		return nil, errs
	}

	log.Printf("[claude] <- stdin: model=%s, msglen=%d", s.model, len(userContent))

	// readLoop + parseCh handle the rest
	// ChatStream returns immediately; the caller reads from tokenCh/errCh
	return s.tokenCh, s.errCh
}

func (s *Session) ListModels() ([]ollama.ModelInfo, error) {
	return s.models, nil
}

func (s *Session) Ping() (string, error) {
	return "claude-code", nil
}

// ---- ExtendedBackend interface ----

func (s *Session) SetEventCallback(fn func(ollama.BackendEvent)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.eventCb = fn
}

func (s *Session) Models() []ollama.ModelInfo {
	return s.models
}

func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
	s.closeProcess()
	return nil
}

// ---- internal ----

func (s *Session) start() error {
	s.ctx, s.cancel = context.WithCancel(context.Background())

	args := []string{
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--include-partial-messages",
		"--model", s.model,
	}
	// Append extra args (e.g. --resume <session-id>)
	args = append(args, s.cfg.Args...)

	s.cmd = exec.CommandContext(s.ctx, s.cfg.BinaryPath, args...)

	var err error
	s.stdin, err = s.cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}
	s.stdout, err = s.cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	s.stderr, err = s.cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("stderr pipe: %w", err)
	}

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("start claude: %w", err)
	}

	// Start stderr logger
	go func() {
		data, _ := io.ReadAll(s.stderr)
		if len(data) > 0 {
			log.Printf("[claude] stderr: %s", string(data))
		}
	}()

	// Start parser → parseCh
	s.parseCh = make(chan ParseEvent, 128)
	startParser(s.stdout, s.parseCh)

	// Start event pump (handles init, text, thinking, etc.)
	go s.eventLoop()

	// Start crash watcher
	go s.watchProcess()

	s.reconnectCount = 0
	return nil
}

func (s *Session) eventLoop() {
	defer func() {
		if s.tokenCh != nil {
			close(s.tokenCh)
		}
		if s.errCh != nil {
			close(s.errCh)
		}
	}()

	for evt := range s.parseCh {
		switch evt.Type {
		case "init":
			s.sessionID = evt.SessionID
			s.model = evt.Model
			log.Printf("[claude] ✓ session started: %s (model=%s)", s.sessionID, evt.Model)

		case "thinking":
			s.emitEvent("thinking", map[string]string{"token": evt.Token})

		case "text":
			if s.tokenCh != nil {
				s.tokenCh <- evt.Token
			} else {
				// Text arriving outside a ChatStream call: drop safely
			}

		case "tool_use":
			s.toolInputBuf[evt.ToolID] = nil
			s.toolNameByID[evt.ToolID] = evt.ToolName
			s.emitEvent("tool_use", map[string]any{
				"id":   evt.ToolID,
				"name": evt.ToolName,
			})

		case "tool_input":
			existing := s.toolInputBuf[evt.ToolID]
			existing = append(existing, []byte(evt.Token)...)
			s.toolInputBuf[evt.ToolID] = existing

		case "tool_stop":
			// Tool input complete — send accumulated input, execute, and respond
			toolName := s.toolNameByID[evt.ToolID]
			if input, ok := s.toolInputBuf[evt.ToolID]; ok {
				s.emitEvent("tool_input", map[string]any{
					"id":    evt.ToolID,
					"input": json.RawMessage(input),
				})
				// Execute tool locally and send result back to Claude
				go s.executeAndRespond(evt.ToolID, toolName, input)
			}

		case "done":
			s.lastInputTokens = evt.InputTokens
			s.lastOutputTokens = evt.OutputTokens
			// message_delta carries the authoritative stop_reason; message_stop
			// follows without one. Only update from non-empty values so a trailing
			// message_stop doesn't overwrite "tool_use" with "".
			if evt.StopReason != "" {
				s.lastStopReason = evt.StopReason
			}
			// If Claude stopped for tool_use, don't close channels yet —
			// the tool will execute and Claude will continue streaming.
			if s.lastStopReason == "tool_use" {
				continue
			}
			if s.tokenCh != nil {
				close(s.tokenCh)
				s.tokenCh = nil
			}
			if s.errCh != nil {
				s.errCh <- nil
				close(s.errCh)
				s.errCh = nil
			}

		case "result":
			if evt.IsError && s.errCh != nil {
				s.errCh <- fmt.Errorf("claude returned error")
				close(s.errCh)
				s.errCh = nil
			}
		}
	}
}

// LastUsage returns token usage and stop reason from the most recent completion.
func (s *Session) LastUsage() (int, int, string) {
	return s.lastInputTokens, s.lastOutputTokens, s.lastStopReason
}

// ---- Permission / Choice handling ----

// needsPermission returns true for tools that require user approval.
func needsPermission(toolName string) bool {
	switch toolName {
	case "Bash", "Write", "Edit":
		return true
	default:
		return false // Read, Grep, Glob are safe
	}
}

// choiceResponse represents the user's decision for a permission prompt.
type choiceResponse struct {
	Behavior string // "allow" or "deny"
}

// Global registry: requestID → channel. Key is our own generated ID (not Claude's).
var choiceRegistry sync.Map // map[string] chan choiceResponse

// ClearChoiceRegistry closes all pending permission channels. Called on session switch.
func ClearChoiceRegistry() {
	choiceRegistry.Range(func(key, value interface{}) bool {
		if ch, ok := value.(chan choiceResponse); ok {
			close(ch)
		}
		choiceRegistry.Delete(key)
		return true
	})
}

// SubmitChoice resolves a pending permission prompt. Called from /api/choice HTTP handler.
func SubmitChoice(requestID string, behavior string) bool {
	ch, ok := choiceRegistry.Load(requestID)
	if !ok {
		return false
	}
	ch.(chan choiceResponse) <- choiceResponse{Behavior: behavior}
	return true
}

// requestPermission emits a choice_request to the phone and waits for user response.
// Returns true if allowed, false if denied or timed out.
func (s *Session) requestPermission(toolID, toolName string, input json.RawMessage) bool {
	requestID := toolID // reuse tool_use ID as request ID for correlation
	if len(requestID) > 40 {
		requestID = requestID[:40]
	}

	s.emitEvent("choice_request", map[string]any{
		"requestId": requestID,
		"toolName":  toolName,
		"toolUseId": toolID,
		"input":     input,
	})

	ch := make(chan choiceResponse, 1)
	choiceRegistry.Store(requestID, ch)
	defer choiceRegistry.Delete(requestID)

	log.Printf("[claude] permission prompt: %s (%s) — waiting indefinitely", toolName, requestID[:min(12, len(requestID))])

	// Wait for user response, context cancellation, or timeout.
	for {
		select {
		case <-s.ctx.Done():
			log.Printf("[claude] permission: %s → CANCELLED (session closed)", requestID[:min(12, len(requestID))])
			return false
		case <-time.After(60 * time.Second):
			log.Printf("[claude] permission: %s → TIMEOUT (auto-abort)", requestID[:min(12, len(requestID))])
			return false
		case resp := <-ch:
			switch resp.Behavior {
			case "allow":
				log.Printf("[claude] permission: %s → ALLOW", requestID[:min(12, len(requestID))])
				return true
			case "abort":
				log.Printf("[claude] permission: %s → ABORT (force-deny)", requestID[:min(12, len(requestID))])
				return false
			case "deny":
				// Pause: Claude keeps waiting. Replace the consumed channel.
				log.Printf("[claude] permission: %s → PAUSE", requestID[:min(12, len(requestID))])
				newCh := make(chan choiceResponse, 1)
				choiceRegistry.Store(requestID, newCh)
				ch = newCh
				// Continue waiting for allow/abort
			default:
				log.Printf("[claude] permission: %s → unknown behavior %q", requestID[:min(12, len(requestID))], resp.Behavior)
			}
		}
	}
}

// ---- Tool execution ----

// executeAndRespond runs a tool locally and sends the result back to Claude.
func (s *Session) executeAndRespond(toolID, toolName string, input json.RawMessage) {
	var params map[string]interface{}
	if err := json.Unmarshal(input, &params); err != nil {
		params = map[string]interface{}{}
	}

	// Check permission for dangerous tools
	if needsPermission(toolName) {
		if !s.requestPermission(toolID, toolName, input) {
			// Denied — send error result back to Claude
			errMsg := fmt.Sprintf("Permission denied for %s", toolName)
			log.Printf("[claude] tool %s(%s) → denied by user", toolName, toolID[:min(8, len(toolID))])
			s.sendToolResult(toolID, errMsg, true)
			s.emitEvent("tool_result", map[string]any{
				"id":      toolID,
				"name":    toolName,
				"output":  errMsg,
				"isError": true,
			})
			return
		}
	}

	output, isError := execTool(toolName, params)
	log.Printf("[claude] tool %s(%s) → %d bytes (error=%v)", toolName, toolID[:min(8, len(toolID))], len(output), isError)

	// Send result back to Claude's stdin (unblocks Claude)
	s.sendToolResult(toolID, output, isError)

	// Emit to phone
	s.emitEvent("tool_result", map[string]any{
		"id":      toolID,
		"name":    toolName,
		"output":  output,
		"isError": isError,
	})
}

// sendToolResult writes a tool_result user message to Claude's stdin.
func (s *Session) sendToolResult(toolID, output string, isError bool) {
	msg := userMsg{
		Type: "user",
		Message: userMsgInner{
			Role: "user",
			Content: []toolResultBlock{
				{
					Type:      "tool_result",
					ToolUseID: toolID,
					Content:   output,
					IsError:   isError,
				},
			},
		},
	}
	data, _ := json.Marshal(msg)
	if s.stdin != nil {
		if _, err := s.stdin.Write(append(data, '\n')); err != nil {
			log.Printf("[claude] sendToolResult write error: %v", err)
		}
	}
}

// execTool dispatches to the correct tool executor based on name.
func execTool(name string, params map[string]interface{}) (output string, isError bool) {
	switch name {
	case "Bash":
		return execBash(params)
	case "Read":
		return execRead(params)
	case "Write", "Edit":
		return execWrite(params)
	case "Grep":
		return execGrep(params)
	case "Glob":
		return execGlob(params)
	default:
		return fmt.Sprintf("Tool not implemented: %s", name), true
	}
}

func execBash(params map[string]interface{}) (string, bool) {
	cmdStr, _ := params["command"].(string)
	if cmdStr == "" {
		return "no command provided", true
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd", "/c", cmdStr)
		cmd.Env = os.Environ()
	} else {
		cmd = exec.CommandContext(ctx, "bash", "-c", cmdStr)
		cmd.Env = append(os.Environ(),
			"HOME=/root",
			"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if stderr.Len() > 0 {
		stdout.WriteString(stderr.String())
	}
	if err != nil {
		return stdout.String(), true
	}
	return stdout.String(), false
}

func execRead(params map[string]interface{}) (string, bool) {
	filePath, _ := params["file_path"].(string)
	if filePath == "" {
		return "no file_path provided", true
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Sprintf("read error: %v", err), true
	}
	return string(data), false
}

func execWrite(params map[string]interface{}) (string, bool) {
	filePath, _ := params["file_path"].(string)
	content, _ := params["content"].(string)
	if filePath == "" {
		return "no file_path provided", true
	}
	if err := os.MkdirAll(filepath.Dir(filePath), 0755); err != nil {
		return fmt.Sprintf("mkdir error: %v", err), true
	}
	if err := os.WriteFile(filePath, []byte(content), 0644); err != nil {
		return fmt.Sprintf("write error: %v", err), true
	}
	return fmt.Sprintf("wrote %d bytes to %s", len(content), filePath), false
}

func execGrep(params map[string]interface{}) (string, bool) {
	pattern, _ := params["pattern"].(string)
	path, _ := params["path"].(string)
	if path == "" {
		path = "."
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "cmd", "/c",
			fmt.Sprintf("findstr /s /n /i %s %s\\*.* 2>&1", pattern, path))
	} else {
		cmd = exec.CommandContext(ctx, "grep", "-rn",
			"--include=*.go", "--include=*.dart", "--include=*.py",
			"--include=*.js", "--include=*.ts", "--include=*.yaml",
			"--include=*.json", "--include=*.md",
			pattern, path)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if stderr.Len() > 0 {
		stdout.WriteString(stderr.String())
	}
	if err != nil {
		if stdout.Len() == 0 {
			return fmt.Sprintf("grep: no matches for %q", pattern), false
		}
	}
	return stdout.String(), false
}

func execGlob(params map[string]interface{}) (string, bool) {
	pattern, _ := params["pattern"].(string)
	if pattern == "" {
		pattern = "**/*"
	}
	matches, err := filepath.Glob(pattern)
	if err != nil || len(matches) == 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		var cmd *exec.Cmd
		if runtime.GOOS == "windows" {
			cleanPattern := strings.ReplaceAll(pattern, "**/", "")
			cleanPattern = strings.ReplaceAll(cleanPattern, "**", "*")
			cmd = exec.CommandContext(ctx, "cmd", "/c",
				fmt.Sprintf("dir /s /b %s 2>nul", cleanPattern))
		} else {
			cmd = exec.CommandContext(ctx, "find", ".", "-name", pattern)
		}
		out, _ := cmd.Output()
		if len(out) == 0 && len(matches) == 0 {
			return "no matches", false
		}
		return string(out), false
	}
	return strings.Join(matches, "\n"), false
}

func (s *Session) emitEvent(eventType string, payload any) {
	if s.eventCb == nil {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	s.eventCb(ollama.BackendEvent{
		Type: eventType,
		Data: data,
	})
}

func (s *Session) writeControl(params map[string]any) {
	ctrl := map[string]any{
		"type": "control",
	}
	for k, v := range params {
		ctrl[k] = v
	}
	data, _ := json.Marshal(ctrl)
	if s.stdin != nil {
		if _, err := s.stdin.Write(append(data, '\n')); err != nil {
			log.Printf("[claude] writeControl error: %v", err)
		}
	}
}

func (s *Session) watchProcess() {
	if s.cmd == nil {
		return
	}
	_ = s.cmd.Wait()
	log.Printf("[claude] process exited")

	s.mu.Lock()
	defer s.mu.Unlock()

	// Auto-reconnect up to 3 times
	if s.reconnectCount < 3 && s.ctx.Err() == nil {
		s.reconnectCount++
		log.Printf("[claude] reconnect attempt %d/3...", s.reconnectCount)
		time.Sleep(time.Duration(s.reconnectCount) * time.Second)
		if err := s.start(); err != nil {
			log.Printf("[claude] reconnect failed: %v", err)
			if s.errCh != nil {
				s.errCh <- fmt.Errorf("claude reconnect failed: %w", err)
				close(s.errCh)
				s.errCh = nil
			}
		}
	} else if s.errCh != nil {
		s.errCh <- fmt.Errorf("claude process died (reconnect exhausted)")
		close(s.errCh)
		s.errCh = nil
	}
}

func (s *Session) closeProcess() {
	if s.cmd != nil && s.cmd.Process != nil {
		s.cmd.Process.Kill()
		s.cmd = nil
	}
}

func defaultModels() []ollama.ModelInfo {
	return []ollama.ModelInfo{
		{Name: "sonnet", ParamSize: "Sonnet 4.6", Quant: "cloud"},
		{Name: "opus", ParamSize: "Opus 4.8", Quant: "cloud"},
		{Name: "haiku", ParamSize: "Haiku 4.5", Quant: "cloud"},
	}
}
