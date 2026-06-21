// Package deepseek provides the DeepSeek cloud AgentPlugin.
// Stateless HTTP API proxy, no tools or thinking capabilities.
package deepseek

import (
	"crosslink-poc/cloud"
	"crosslink-poc/ollama"
	"crosslink-poc/plugin"
)

// DeepSeekPlugin wraps a DeepSeek cloud API client.
type DeepSeekPlugin struct {
	client *cloud.DeepSeekClient
	meta   plugin.AgentMeta
	model  string
}

// Config for creating a DeepSeekPlugin.
type Config struct {
	APIKey string
	Model  string
}

// New creates a DeepSeekPlugin. Always succeeds (stateless).
func New(cfg Config) *DeepSeekPlugin {
	if cfg.Model == "" {
		cfg.Model = "deepseek-chat"
	}
	return &DeepSeekPlugin{
		client: cloud.NewDeepSeek(cfg.APIKey, cfg.Model),
		model:  cfg.Model,
		meta: plugin.AgentMeta{
			Type:         "deepseek",
			Label:        "DeepSeek (云端)",
			Capabilities: []string{plugin.CapChat, plugin.CapStreaming},
		},
	}
}

func (p *DeepSeekPlugin) Metadata() plugin.AgentMeta { return p.meta }
func (p *DeepSeekPlugin) Init() error                 { return nil }
func (p *DeepSeekPlugin) Ping() (string, error)       { return p.client.Ping() }
func (p *DeepSeekPlugin) Close() error                { return nil }
func (p *DeepSeekPlugin) ChatStream(req ollama.ChatRequest) (<-chan string, <-chan error) {
	return p.client.ChatStream(req)
}
func (p *DeepSeekPlugin) ListModels() ([]ollama.ModelInfo, error) {
	return []ollama.ModelInfo{{Name: p.model, ParamSize: "unknown", Quant: "cloud"}}, nil
}

var _ plugin.AgentPlugin = (*DeepSeekPlugin)(nil)
