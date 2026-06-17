// Package ollama provides a proxy for the Ollama REST API, designed to be
// called from the CrossLink Agent. It discovers local Ollama instances,
// lists models, and forwards chat requests — streaming responses back as
// chunked DataChannel messages.
package ollama

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const defaultBaseURL = "http://127.0.0.1:11434"

// Client wraps the Ollama REST API.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

// NewClient creates an Ollama API client. If baseURL is empty, the default
// localhost address is used.
func NewClient(baseURL string) *Client {
	if baseURL == "" {
		baseURL = defaultBaseURL
	}
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		HTTP:    &http.Client{Timeout: 10 * time.Second},
	}
}

// Ping checks whether Ollama is reachable. Returns the version string on success.
func (c *Client) Ping() (string, error) {
	resp, err := c.HTTP.Get(c.BaseURL + "/api/tags")
	if err != nil {
		return "", fmt.Errorf("ollama not reachable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("ollama returned %d", resp.StatusCode)
	}
	version := resp.Header.Get("X-Ollama-Version")
	if version == "" {
		version = "unknown"
	}
	return version, nil
}

// ListModels returns the models available on the local Ollama instance.
func (c *Client) ListModels() ([]ModelInfo, error) {
	resp, err := c.HTTP.Get(c.BaseURL + "/api/tags")
	if err != nil {
		return nil, fmt.Errorf("list models: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Models []struct {
			Name       string `json:"name"`
			ModifiedAt string `json:"modified_at"`
			Size       int64  `json:"size"`
			Digest     string `json:"digest"`
			Details    struct {
				Format            string `json:"format"`
				Family            string `json:"family"`
				ParameterSize     string `json:"parameter_size"`
				QuantizationLevel string `json:"quantization_level"`
			} `json:"details"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode models: %w", err)
	}

	models := make([]ModelInfo, len(result.Models))
	for i, m := range result.Models {
		models[i] = ModelInfo{
			Name:       m.Name,
			ModifiedAt: m.ModifiedAt,
			SizeBytes:  m.Size,
			Digest:     m.Digest,
			Format:     m.Details.Format,
			Family:     m.Details.Family,
			ParamSize:  m.Details.ParameterSize,
			Quant:      m.Details.QuantizationLevel,
		}
	}
	return models, nil
}

// Chat sends a chat request to Ollama and returns the complete response.
// For streaming, use ChatStream instead.
func (c *Client) Chat(req ChatRequest) (*ChatResponse, error) {
	if req.Stream {
		// Non-streaming: collect all chunks
		full := new(strings.Builder)
		chunks, errs := c.ChatStream(req)
		for chunk := range chunks {
			full.WriteString(chunk)
		}
		if err := <-errs; err != nil {
			return nil, err
		}
		return &ChatResponse{
			Model:     req.Model,
			Message:   Message{Role: "assistant", Content: full.String()},
			Done:      true,
			TotalDuration: 0,
		}, nil
	}

	// Non-streaming request
	req.Stream = false
	body, _ := json.Marshal(req)
	resp, err := c.HTTP.Post(c.BaseURL+"/api/chat", "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("chat: %w", err)
	}
	defer resp.Body.Close()

	var cr ChatResponse
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &cr, nil
}

// ChatStream sends a streaming chat request to Ollama.
// It returns a channel of token strings and an error channel.
// The error channel delivers any transport error (or nil on graceful completion).
// The token channel is closed when the stream ends.
func (c *Client) ChatStream(req ChatRequest) (<-chan string, <-chan error) {
	tokens := make(chan string, 64)
	errs := make(chan error, 1)

	// Force streaming regardless of caller's setting
	req.Stream = true

	go func() {
		defer close(tokens)
		defer close(errs)

		body, err := json.Marshal(req)
		if err != nil {
			errs <- fmt.Errorf("marshal request: %w", err)
			return
		}

		resp, err := c.HTTP.Post(c.BaseURL+"/api/chat", "application/json", bytes.NewReader(body))
		if err != nil {
			errs <- fmt.Errorf("chat stream: %w", err)
			return
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			msg, _ := io.ReadAll(resp.Body)
			errs <- fmt.Errorf("ollama error %d: %s", resp.StatusCode, string(msg))
			return
		}

		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				continue
			}

			var chunk struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
				Done bool `json:"done"`
			}
			if err := json.Unmarshal([]byte(line), &chunk); err != nil {
				continue // Skip malformed lines (keep reading)
			}

			if chunk.Message.Content != "" {
				tokens <- chunk.Message.Content
			}
			if chunk.Done {
				break
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
