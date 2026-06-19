// Package claude implements a Claude Code backend via the Claude CLI
// in long-running stdin/stdout stream-json mode.
package claude

import (
	"encoding/json"
	"os/exec"
)

// Config holds parameters for launching a Claude CLI subprocess.
type Config struct {
	BinaryPath string   // Path to claude executable
	Model      string   // Default model (sonnet, opus, haiku)
	Args       []string // Extra args passed to claude
}

// DefaultConfig returns a Config with sensible defaults.
func DefaultConfig() Config {
	path, _ := exec.LookPath("claude")
	if path == "" {
		path = "claude" // let exec.Command try PATH
	}
	return Config{
		BinaryPath: path,
		Model:      "sonnet",
	}
}

// ---- stream-json wire types (stdout) ----

// claudeMsg is a generic line from Claude's stream-json stdout.
type claudeMsg struct {
	Type      string          `json:"type"`
	Subtype   string          `json:"subtype,omitempty"`
	Event     json.RawMessage `json:"event,omitempty"`
	Message   json.RawMessage `json:"message,omitempty"`
	Result    string          `json:"result,omitempty"`
	IsError   bool            `json:"is_error"`
	SessionID string          `json:"session_id"`
	Model     string          `json:"model"`    // present on system/init
	Cwd       string          `json:"cwd"`      // present on system/init
}

// streamEvent is the inner "event" object for "stream_event" messages.
type streamEvent struct {
	Type  string `json:"type"`
	Index int    `json:"index"`
	Delta struct {
		Type         string `json:"type"`          // "text_delta", "thinking_delta", "input_json_delta", "signature_delta"
		Text         string `json:"text"`          // text_delta payload
		Thinking     string `json:"thinking"`      // thinking_delta payload
		PartialJSON  string `json:"partial_json"`  // input_json_delta payload
		Signature    string `json:"signature"`     // signature_delta payload
		StopReason   string `json:"stop_reason"`   // message_delta
		StopSequence *string `json:"stop_sequence"` // message_delta
	} `json:"delta"`
	ContentBlock *struct {
		Type string `json:"type"` // "thinking", "text", "tool_use"
		Name string `json:"name"` // tool name (for tool_use)
		ID   string `json:"id"`   // tool use ID
		Text string `json:"text"`
	} `json:"content_block"`
	Usage *struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

// systemInit is the "system" subtype "init" payload.
type systemInit struct {
	SessionID string `json:"session_id"`
	Model     string `json:"model"`
}

// ---- stdin wire types ----

// userMsg is the message written to claude's stdin.
type userMsg struct {
	Type    string       `json:"type"`
	Message userMsgInner `json:"message"`
}

type userMsgInner struct {
	Role    string      `json:"role"`
	Content interface{} `json:"content"` // string for plain text, []map for tool_result blocks
}

// toolResultBlock is a content block for tool results sent back to Claude.
type toolResultBlock struct {
	Type      string `json:"type"`       // "tool_result"
	ToolUseID string `json:"tool_use_id"`
	Content   string `json:"content"`
	IsError   bool   `json:"is_error,omitempty"`
}
