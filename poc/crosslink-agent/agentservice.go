package main

// AgentService provides backend methods callable from the frontend.
type AgentService struct{}

// Status returns the current agent status.
func (a *AgentService) Status() map[string]any {
	return map[string]any{
		"version":    "0.1.0",
		"peerID":     "agent-local",
		"connected":  false,
		"ollamaAlive": false,
	}
}

// Greet is kept from the template for testing bindings.
func (a *AgentService) Greet(name string) string {
	return "Hello " + name + " from CrossLink Agent!"
}
