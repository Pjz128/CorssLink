package plugin

import (
	"fmt"
	"log"
	"sync"
)

// AgentRegistry is the central plugin directory. Replaces pool.BackendPool.
type AgentRegistry struct {
	mu       sync.RWMutex
	plugins  map[string]AgentPlugin
	default_ string
}

// NewRegistry creates an empty registry.
func NewRegistry() *AgentRegistry {
	return &AgentRegistry{
		plugins: make(map[string]AgentPlugin),
	}
}

// Register adds a plugin. Calls p.Init() first.
func (r *AgentRegistry) Register(p AgentPlugin) error {
	meta := p.Metadata()
	if meta.Type == "" {
		return fmt.Errorf("plugin has empty type")
	}
	if err := p.Init(); err != nil {
		return fmt.Errorf("plugin %s init: %w", meta.Type, err)
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.plugins[meta.Type]; exists {
		return fmt.Errorf("plugin %s already registered", meta.Type)
	}
	r.plugins[meta.Type] = p
	if r.default_ == "" {
		r.default_ = meta.Type
	}
	log.Printf("[registry] registered: %s (%s)", meta.Type, meta.Label)
	return nil
}

// Get retrieves a plugin by agent type.
func (r *AgentRegistry) Get(agentType string) (AgentPlugin, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.plugins[agentType]
	return p, ok
}

// Default returns the first-registered plugin, or nil.
func (r *AgentRegistry) Default() AgentPlugin {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.default_ == "" {
		return nil
	}
	return r.plugins[r.default_]
}

// List returns metadata for every registered plugin.
func (r *AgentRegistry) List() []AgentMeta {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]AgentMeta, 0, len(r.plugins))
	for _, p := range r.plugins {
		out = append(out, p.Metadata())
	}
	return out
}

// CloseAll shuts down every plugin and clears the registry.
func (r *AgentRegistry) CloseAll() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for k, p := range r.plugins {
		if err := p.Close(); err != nil {
			log.Printf("[registry] close %s: %v", k, err)
		}
	}
	r.plugins = make(map[string]AgentPlugin)
	r.default_ = ""
	log.Printf("[registry] all plugins closed")
}

// Status returns a human-readable health summary.
func (r *AgentRegistry) Status() string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var s string
	for _, p := range r.plugins {
		meta := p.Metadata()
		ver, err := p.Ping()
		alive := "ok"
		if err != nil {
			alive = fmt.Sprintf("down(%v)", err)
		}
		s += fmt.Sprintf("  %s [%s] ver=%s status=%s\n", meta.Type, meta.Label, ver, alive)
	}
	return s
}
