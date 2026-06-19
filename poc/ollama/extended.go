package ollama

import "encoding/json"

// BackendEvent is a non-text event emitted by agentic backends (Claude, etc.).
// Pure-text backends (Ollama, DeepSeek) never emit these.
type BackendEvent struct {
	Type string          // "thinking", "tool_use", "tool_input", "tool_result"
	Data json.RawMessage // Event-specific JSON payload
}

// ExtendedBackend adds event streaming and lifecycle control on top of Backend.
// Agentic backends (Claude Code) implement this; simple LLM proxies do not.
type ExtendedBackend interface {
	Backend

	// SetEventCallback registers a handler for non-text events.
	// Thinking tokens and tool calls are delivered through this channel
	// rather than the main ChatStream token channel.
	SetEventCallback(fn func(evt BackendEvent))

	// Models returns the model list directly (no I/O needed).
	Models() []ModelInfo

	// Close releases backend resources (subprocess, connections, etc.).
	Close() error

	// LastUsage returns token usage and stop reason from the most recent completion.
	// Returns zeros / empty string if no completion has occurred.
	LastUsage() (inputTokens int, outputTokens int, stopReason string)
}
