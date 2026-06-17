package ollama

// Backend abstracts an LLM backend (local Ollama or cloud API).
// Both *Client (local) and cloud.DeepSeekClient implement this interface.
type Backend interface {
	ChatStream(req ChatRequest) (<-chan string, <-chan error)
	ListModels() ([]ModelInfo, error)
	Ping() (string, error)
}
