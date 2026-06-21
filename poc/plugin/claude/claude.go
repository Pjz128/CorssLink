// Package claude provides the Claude Code AgentPlugin with multi-session support.
// Uses Claude CLI's native session storage (~/.claude/projects/).
// Supports --resume for cross-device session sharing.
package claude

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"crosslink-poc/agent/claude"
	"crosslink-poc/ollama"
	"crosslink-poc/plugin"
)

// SessionInfo describes a Claude native session (a .jsonl file).
type SessionInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"createdAt"`
	Active    bool   `json:"active"`
}

// ClaudePlugin wraps Claude Code with multi-session support via --resume.
type ClaudePlugin struct {
	cfg           Config
	activeSession *claude.Session
	activeID      string
	meta          plugin.AgentMeta
	dataDir       string // Claude CLI's project data dir (~/.claude/projects/<project>)
	mu            sync.Mutex
	eventCb       func(ollama.BackendEvent)
}

// Config for creating a ClaudePlugin.
type Config struct {
	BinaryPath string
	Model      string
	DataDir    string // agent data dir (for backward compat, not used for sessions)
}

// New creates a ClaudePlugin. Activates the most recent session or creates default.
func New(cfg Config) (*ClaudePlugin, error) {
	if cfg.DataDir == "" {
		cfg.DataDir = "./data/claude"
	}
	os.MkdirAll(cfg.DataDir, 0700)

	p := &ClaudePlugin{
		cfg:     cfg,
		dataDir: claudeProjectDir(),
		meta: plugin.AgentMeta{
			Type:         "claude",
			Label:        "Claude Code",
			Capabilities: []string{plugin.CapChat, plugin.CapThinking, plugin.CapTools, plugin.CapStreaming},
		},
	}

	// Pick session to activate: first try most recent, else create default
	sessions := p.listSessions()
	if len(sessions) > 0 {
		// Activate most recent
		p.activateSession(sessions[0].ID)
	} else {
		p.activateSession("") // new session, no --resume
	}

	return p, nil
}

// claudeProjectDir finds Claude CLI's session storage.
// Set CLAUDE_PROJECT_DIR env var to override (e.g. "C--mySpace-CorssLink").
func claudeProjectDir() string {
	home, _ := os.UserHomeDir()
	// Explicit override: real path or pre-transformed project name
	if dir := os.Getenv("CLAUDE_PROJECT_DIR"); dir != "" {
		// If it looks like a real path, transform it like Claude CLI does
		if strings.Contains(dir, ":") || strings.Contains(dir, "\\") || strings.Contains(dir, "/") {
			name := strings.NewReplacer(
				":", "", "\\", "-", "/", "-", " ", "-",
			).Replace(dir)
			name = strings.TrimPrefix(name, "-")
			return filepath.Join(home, ".claude", "projects", name)
		}
		return filepath.Join(home, ".claude", "projects", dir)
	}
	cwd, _ := os.Getwd()
	// Claude CLI naming: replace path separators and special chars
	name := strings.NewReplacer(
		":", "", "\\", "-", "/", "-", " ", "-",
	).Replace(cwd)
	name = strings.TrimPrefix(name, "-")
	return filepath.Join(home, ".claude", "projects", name)
}

// ---- Session management ----

func (p *ClaudePlugin) Sessions() []SessionInfo {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.listSessions()
}

func (p *ClaudePlugin) listSessions() []SessionInfo {
	os.MkdirAll(p.dataDir, 0700) // ensure dir exists
	entries, err := os.ReadDir(p.dataDir)
	if err != nil {
		return []SessionInfo{}
	}

	var sessions []SessionInfo
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".jsonl")
		info, _ := e.Info()
		createdAt := ""
		if info != nil {
			createdAt = info.ModTime().UTC().Format(time.RFC3339)
		}
		// Extract first user message as session name
		name := extractSessionName(filepath.Join(p.dataDir, e.Name()))
		if name == "" {
			name = id[:8] + "…"
		}

		active := p.activeID == id
		sessions = append(sessions, SessionInfo{
			ID:        id,
			Name:      name,
			CreatedAt: createdAt,
			Active:    active,
		})
	}

	// Sort by modification time, newest first
	sort.Slice(sessions, func(i, j int) bool {
		return sessions[i].CreatedAt > sessions[j].CreatedAt
	})

	if sessions == nil {
		return []SessionInfo{}
	}
	return sessions
}

// extractSessionName reads the first user message from a .jsonl file as the session title.
func extractSessionName(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var msg map[string]any
		if err := json.Unmarshal(sc.Bytes(), &msg); err != nil {
			continue
		}
		if msg["role"] == "user" {
			if content, ok := msg["content"].(string); ok && content != "" {
				// Take first 40 chars as title
				content = strings.TrimSpace(content)
				if len(content) > 40 {
					content = content[:40] + "…"
				}
				return content
			}
		}
	}
	return ""
}

func (p *ClaudePlugin) CreateSession(name string) error {
	// Claude CLI auto-creates sessions. Just activate a new one.
	log.Printf("[claude] creating new session (name=%s)", name)
	return p.ActivateSession("")
}

func (p *ClaudePlugin) ActivateSession(id string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.activateSession(id)
}

func (p *ClaudePlugin) activateSession(id string) error {
	// Kill existing subprocess
	if p.activeSession != nil {
		p.activeSession.Close()
	}

	// Build config with optional --resume
	cfg := claude.Config{
		BinaryPath: p.cfg.BinaryPath,
		Model:      p.cfg.Model,
	}
	if id != "" {
		cfg.Args = []string{"--resume", id}
	}

	session, err := claude.NewSession(cfg)
	if err != nil {
		return fmt.Errorf("start claude session: %w", err)
	}
	if p.eventCb != nil {
		session.SetEventCallback(p.eventCb)
	}

	p.activeSession = session
	p.activeID = id
	log.Printf("[claude] activated session: %s", id)
	return nil
}

func (p *ClaudePlugin) DeleteSession(id string) error {
	if id == p.ActiveSessionID() {
		return fmt.Errorf("cannot delete active session")
	}
	path := filepath.Join(p.dataDir, id+".jsonl")
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("delete session file: %w", err)
	}
	// Also remove companion directory
	os.RemoveAll(filepath.Join(p.dataDir, id))
	log.Printf("[claude] session deleted: %s", id)
	return nil
}

func (p *ClaudePlugin) ActiveSessionName() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	sessions := p.listSessions()
	for _, s := range sessions {
		if s.ID == p.activeID {
			return s.Name
		}
	}
	return ""
}

func (p *ClaudePlugin) ActiveSessionID() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.activeID
}

// GetMessages reads the conversation history from a .jsonl session file.
func (p *ClaudePlugin) GetMessages(sessionID string) ([]ollama.Message, error) {
	path := filepath.Join(p.dataDir, sessionID+".jsonl")
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var msgs []ollama.Message
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var m struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		}
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			continue
		}
		if m.Role == "user" || m.Role == "assistant" {
			msgs = append(msgs, ollama.Message{Role: m.Role, Content: m.Content})
		}
	}
	return msgs, nil
}

// ---- AgentPlugin interface ----

func (p *ClaudePlugin) Metadata() plugin.AgentMeta { return p.meta }
func (p *ClaudePlugin) Init() error                { return nil }
func (p *ClaudePlugin) Ping() (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeSession == nil {
		return "", fmt.Errorf("no active session")
	}
	return p.activeSession.Ping()
}
func (p *ClaudePlugin) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeSession != nil {
		p.activeSession.Close()
		p.activeSession = nil
	}
	return nil
}
func (p *ClaudePlugin) ChatStream(req ollama.ChatRequest) (<-chan string, <-chan error) {
	p.mu.Lock()
	s := p.activeSession
	p.mu.Unlock()
	if s == nil {
		errCh := make(chan error, 1)
		errCh <- fmt.Errorf("no active claude session")
		return nil, errCh
	}
	return s.ChatStream(req)
}
func (p *ClaudePlugin) ListModels() ([]ollama.ModelInfo, error) {
	return []ollama.ModelInfo{
		{Name: "sonnet", ParamSize: "unknown"},
		{Name: "opus", ParamSize: "unknown"},
		{Name: "haiku", ParamSize: "unknown"},
	}, nil
}
func (p *ClaudePlugin) SetEventCallback(fn func(ollama.BackendEvent)) {
	p.eventCb = fn
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeSession != nil {
		p.activeSession.SetEventCallback(fn)
	}
}
func (p *ClaudePlugin) LastUsage() (int, int, string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeSession == nil {
		return 0, 0, ""
	}
	return p.activeSession.LastUsage()
}

var _ plugin.AgentPlugin = (*ClaudePlugin)(nil)
var _ plugin.EventPlugin = (*ClaudePlugin)(nil)
var _ plugin.UsagePlugin = (*ClaudePlugin)(nil)
