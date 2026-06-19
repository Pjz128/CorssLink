// Package pool provides a BackendPool that lets the Handler route
// chat requests to different LLM backends based on an agent type string.
package pool

import (
	"fmt"
	"log"
	"sync"

	"crosslink-poc/ollama"
)

// BackendPool holds a map of named backends and can route requests by agent type.
type BackendPool struct {
	mu       sync.RWMutex
	backends map[string]*entry
	default_ string // agent type to use when none specified
}

type entry struct {
	backend ollama.Backend
	info    ollama.AgentInfo
}

// NewBackendPool creates an empty pool.
func NewBackendPool() *BackendPool {
	return &BackendPool{
		backends: make(map[string]*entry),
	}
}

// Register adds a backend with the given agent type and metadata.
// If agentType already exists, it is replaced.
func (p *BackendPool) Register(agentType string, backend ollama.Backend, info ollama.AgentInfo) {
	p.mu.Lock()
	defer p.mu.Unlock()
	info.Type = agentType
	p.backends[agentType] = &entry{backend: backend, info: info}
	if p.default_ == "" {
		p.default_ = agentType
	}
	log.Printf("[pool] registered backend: %s (%s) — %d models", agentType, info.Label, len(info.Models))
}

// Get returns the backend for the given agent type.
func (p *BackendPool) Get(agentType string) (ollama.Backend, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	e, ok := p.backends[agentType]
	if !ok {
		return nil, false
	}
	return e.backend, true
}

// Default returns the first-registered backend, or nil if pool is empty.
func (p *BackendPool) Default() ollama.Backend {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.default_ == "" {
		return nil
	}
	e, ok := p.backends[p.default_]
	if !ok {
		return nil
	}
	return e.backend
}

// ListAgents returns metadata for all registered backends.
func (p *BackendPool) ListAgents() []ollama.AgentInfo {
	p.mu.RLock()
	defer p.mu.RUnlock()
	list := make([]ollama.AgentInfo, 0, len(p.backends))
	for _, e := range p.backends {
		list = append(list, e.info)
	}
	return list
}

// AggregateModels collects models from all backends for backward-compatible list-res.
func (p *BackendPool) AggregateModels() []ollama.ModelInfo {
	p.mu.RLock()
	defer p.mu.RUnlock()
	seen := make(map[string]bool)
	var all []ollama.ModelInfo
	for _, e := range p.backends {
		for _, m := range e.info.Models {
			key := e.info.Type + ":" + m.Name
			if !seen[key] {
				seen[key] = true
				all = append(all, m)
			}
		}
	}
	return all
}

// CloseAll calls Close on every ExtendedBackend in the pool.
func (p *BackendPool) CloseAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, e := range p.backends {
		if eb, ok := e.backend.(ollama.ExtendedBackend); ok {
			eb.Close()
		}
	}
	log.Printf("[pool] all backends closed")
}

// Status returns a summary string for all backends.
func (p *BackendPool) Status() string {
	p.mu.RLock()
	defer p.mu.RUnlock()
	status := ""
	for _, e := range p.backends {
		version, err := e.backend.Ping()
		alive := "✓"
		if err != nil {
			alive = fmt.Sprintf("✗ (%v)", err)
		}
		status += fmt.Sprintf("  %s (%s): %s %s\n", e.info.Type, e.info.Label, alive, version)
	}
	return status
}
