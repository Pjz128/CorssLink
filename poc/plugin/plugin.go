// Package plugin defines the AgentPlugin interface and registry for CrossLink's
// multi-backend architecture. Each AI provider (Claude, DeepSeek, Ollama, etc.)
// implements AgentPlugin and is loaded independently through the AgentRegistry.
package plugin

import "crosslink-poc/ollama"

// AgentPlugin is the core interface every agent backend must implement.
// It embeds ollama.Backend for backward compatibility with all existing consumers.
type AgentPlugin interface {
	ollama.Backend // ChatStream, ListModels, Ping

	// Metadata returns static identity and capabilities.
	// Must be safe to call before Init() and after Close().
	Metadata() AgentMeta

	// Init performs one-time setup. Called exactly once by the registry.
	Init() error

	// Close releases all resources. Idempotent.
	Close() error
}

// EventPlugin is an optional interface for agents that emit structured
// events (thinking, tool_use, tool_input, tool_result, choice_request).
type EventPlugin interface {
	AgentPlugin
	SetEventCallback(fn func(ollama.BackendEvent))
}

// UsagePlugin is an optional interface for agents that report token
// consumption after a completion.
type UsagePlugin interface {
	AgentPlugin
	LastUsage() (inputTokens int, outputTokens int, stopReason string)
}

// AgentMeta describes an agent's static identity and capabilities.
type AgentMeta struct {
	Type         string   `json:"type"`
	Label        string   `json:"label"`
	Capabilities []string `json:"capabilities"`
}

// Well-known capability strings.
const (
	CapChat      = "chat"
	CapThinking  = "thinking"
	CapTools     = "tools"
	CapVision    = "vision"
	CapStreaming = "streaming"
)
