// Package cloud provides LLM backends that implement ollama.Backend
// using cloud APIs (DeepSeek, OpenAI, etc.) instead of local Ollama.
package cloud

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"crosslink-poc/ollama"
)

// DeepSeekClient implements ollama.Backend using the DeepSeek API.
// DeepSeek is OpenAI-compatible, so this can be adapted for any
// OpenAI-compatible endpoint.
type DeepSeekClient struct {
	APIKey  string
	BaseURL string
	Model   string
	HTTP    *http.Client
}

// NewDeepSeek creates a DeepSeek client. API key is read from the
// DEEPSEEK_API_KEY env var if not provided.
func NewDeepSeek(apiKey, model string) *DeepSeekClient {
	if apiKey == "" {
		apiKey = os.Getenv("DEEPSEEK_API_KEY")
	}
	if model == "" {
		model = "deepseek-chat"
	}
	return &DeepSeekClient{
		APIKey:  apiKey,
		BaseURL: "https://api.deepseek.com",
		Model:   model,
		HTTP:    &http.Client{},
	}
}

// Ping checks connectivity. Not applicable for cloud — always returns ok.
func (c *DeepSeekClient) Ping() (string, error) {
	return "deepseek-cloud", nil
}

// ListModels returns the configured model as the only available model.
func (c *DeepSeekClient) ListModels() ([]ollama.ModelInfo, error) {
	return []ollama.ModelInfo{
		{Name: c.Model, ParamSize: "unknown", Quant: "cloud"},
	}, nil
}

// ChatStream sends a streaming chat request to DeepSeek.
// Returns token channel and error channel matching ollama.Client.ChatStream.
func (c *DeepSeekClient) ChatStream(req ollama.ChatRequest) (<-chan string, <-chan error) {
	tokens := make(chan string, 64)
	errs := make(chan error, 1)

	go func() {
		defer close(tokens)
		defer close(errs)

		// Convert CrossLink messages to OpenAI/DeepSeek format
		msgs := make([]map[string]string, len(req.Messages))
		for i, m := range req.Messages {
			msgs[i] = map[string]string{
				"role":    m.Role,
				"content": m.Content,
			}
		}

		model := req.Model
		if model == "" {
			model = c.Model
		}

		body := map[string]interface{}{
			"model":    model,
			"messages": msgs,
			"stream":   true,
		}
		bodyBytes, err := json.Marshal(body)
		if err != nil {
			errs <- fmt.Errorf("marshal: %w", err)
			return
		}

		httpReq, err := http.NewRequest("POST", c.BaseURL+"/v1/chat/completions",
			bytes.NewReader(bodyBytes))
		if err != nil {
			errs <- fmt.Errorf("create request: %w", err)
			return
		}
		httpReq.Header.Set("Content-Type", "application/json")
		httpReq.Header.Set("Authorization", "Bearer "+c.APIKey)

		resp, err := c.HTTP.Do(httpReq)
		if err != nil {
			errs <- fmt.Errorf("api call: %w", err)
			return
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			msg, _ := io.ReadAll(resp.Body)
			errs <- fmt.Errorf("deepseek error %d: %s", resp.StatusCode, string(msg))
			return
		}

		// Parse SSE stream
		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || line == "data: [DONE]" {
				continue
			}
			if !strings.HasPrefix(line, "data: ") {
				continue
			}

			payload := strings.TrimPrefix(line, "data: ")

			var chunk struct {
				Choices []struct {
					Delta struct {
						Content string `json:"content"`
					} `json:"delta"`
				} `json:"choices"`
			}
			if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
				continue
			}

			if len(chunk.Choices) > 0 && chunk.Choices[0].Delta.Content != "" {
				tokens <- chunk.Choices[0].Delta.Content
			}
		}

		if err := scanner.Err(); err != nil {
			errs <- fmt.Errorf("read stream: %w", err)
			return
		}
		errs <- nil
	}()

	return tokens, errs
}

// Ensure interface compliance.
var _ ollama.Backend = (*DeepSeekClient)(nil)
