package ollama

// ModelInfo represents a model available on the Ollama server.
type ModelInfo struct {
	Name       string `json:"name"`
	ModifiedAt string `json:"modifiedAt"`
	SizeBytes  int64  `json:"sizeBytes"`
	Digest     string `json:"digest"`
	Format     string `json:"format"`     // "gguf", "safetensors", etc.
	Family     string `json:"family"`     // "llama", "qwen2", etc.
	ParamSize  string `json:"paramSize"`  // "7B", "13B", etc.
	Quant      string `json:"quant"`      // "Q4_K_M", "F16", etc.
}

// Message is a single turn in a chat conversation.
type Message struct {
	Role    string `json:"role"`              // "user", "assistant", "system"
	Content string `json:"content"`           // Message text
	Images  []string `json:"images,omitempty"` // Base64-encoded images (multimodal models)
}

// ChatRequest is the payload sent to Ollama's /api/chat endpoint.
type ChatRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
	Stream   bool      `json:"stream,omitempty"`
	Options  *ModelOptions `json:"options,omitempty"`
	Format   string    `json:"format,omitempty"` // "json" to force JSON output
}

// ChatResponse is a non-streaming chat response from Ollama.
type ChatResponse struct {
	Model         string  `json:"model"`
	CreatedAt     string  `json:"created_at"`
	Message       Message `json:"message"`
	Done          bool    `json:"done"`
	TotalDuration int64   `json:"total_duration"`
	EvalCount     int     `json:"eval_count"`
	EvalDuration  int64   `json:"eval_duration"`
}

// ModelOptions sets inference parameters for a chat request.
type ModelOptions struct {
	Temperature float64 `json:"temperature,omitempty"`
	TopP        float64 `json:"top_p,omitempty"`
	TopK        int     `json:"top_k,omitempty"`
	NumPredict  int     `json:"num_predict,omitempty"`
	Seed        int     `json:"seed,omitempty"`
}
