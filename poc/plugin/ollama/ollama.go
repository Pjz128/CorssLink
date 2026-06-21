// Package ollama provides the Ollama local AgentPlugin.
// Stateless HTTP proxy to a local Ollama instance.
package ollama

import (
	"crosslink-poc/ollama"
	"crosslink-poc/plugin"
)

// OllamaPlugin wraps a local Ollama HTTP client.
type OllamaPlugin struct {
	client *ollama.Client
	meta   plugin.AgentMeta
}

// Config for creating an OllamaPlugin.
type Config struct {
	BaseURL string // empty = default "http://127.0.0.1:11434"
}

// New creates an OllamaPlugin. Does not connect yet.
func New(cfg Config) *OllamaPlugin {
	return &OllamaPlugin{
		client: ollama.NewClient(cfg.BaseURL),
		meta: plugin.AgentMeta{
			Type:         "ollama",
			Label:        "Ollama (本地)",
			Capabilities: []string{plugin.CapChat, plugin.CapVision, plugin.CapStreaming},
		},
	}
}

func (p *OllamaPlugin) Metadata() plugin.AgentMeta { return p.meta }
func (p *OllamaPlugin) Init() error {
	// Verify reachability before registering
	_, err := p.client.Ping()
	return err
}
func (p *OllamaPlugin) Ping() (string, error)               { return p.client.Ping() }
func (p *OllamaPlugin) Close() error                        { return nil }
func (p *OllamaPlugin) ChatStream(req ollama.ChatRequest) (<-chan string, <-chan error) {
	return p.client.ChatStream(req)
}
func (p *OllamaPlugin) ListModels() ([]ollama.ModelInfo, error) {
	return p.client.ListModels()
}

var _ plugin.AgentPlugin = (*OllamaPlugin)(nil)
