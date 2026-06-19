package ollama

import (
	"encoding/json"
	"fmt"
	"time"
)

// CrossLink message types sent over the WebRTC DataChannel.
const (
	MsgTypeChatRequest  = "chat-req"  // Client → Agent: ask a question
	MsgTypeChatToken    = "chat-tok"  // Agent → Client: streaming token
	MsgTypeChatDone     = "chat-done" // Agent → Client: stream complete
	MsgTypeChatError    = "chat-err"  // Agent → Client: error
	MsgTypeListModels   = "list-req"  // Client → Agent: request model list
	MsgTypeListResponse = "list-res"  // Agent → Client: model list
	MsgTypeStatus       = "status-req" // Client → Agent: ask for status
	MsgTypeStatusResp   = "status-res" // Agent → Client: status reply
	MsgTypePing         = "ping"
	MsgTypePong         = "pong"
	// Agentic extensions (Claude Code, etc.)
	MsgTypeThinking   = "thinking"    // Agent → Client: thinking token
	MsgTypeToolUse    = "tool-use"    // Agent → Client: tool call started
	MsgTypeToolInput  = "tool-input"  // Agent → Client: tool input streaming
	MsgTypeToolResult = "tool-result" // Agent → Client: tool result
	MsgTypeSetModel   = "set-model"   // Client → Agent: switch model/agent
	MsgTypeListAgents = "list-agents" // Client → Agent: list agent types
)

// WireMessage is the top-level envelope for all CrossLink DataChannel messages.
type WireMessage struct {
	ID   string          `json:"id"`   // Unique message ID (cuid2-style)
	Time int64           `json:"time"` // Unix milliseconds
	Type string          `json:"type"` // One of MsgType* constants
	Body json.RawMessage `json:"body"` // Type-specific payload
}

// AgentInfo describes an available agent backend and its models.
type AgentInfo struct {
	Type   string      `json:"type"`   // Backend key: "ollama", "claude", "deepseek"
	Label  string      `json:"label"`  // Human-readable name
	Models []ModelInfo `json:"models"` // Available models for this agent
}

// ChatRequestBody is the payload for MsgTypeChatRequest.
type ChatRequestBody struct {
	Agent    string    `json:"agent,omitempty"` // Backend selection (omit for default)
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
	Options  *ModelOptions `json:"options,omitempty"`
	Format   string    `json:"format,omitempty"`
}

// ChatTokenBody is the payload for MsgTypeChatToken (one token at a time).
type ChatTokenBody struct {
	Token  string `json:"token"`
	Index  int    `json:"i"` // Token index in the stream
}

// ChatDoneBody is the payload for MsgTypeChatDone.
type ChatDoneBody struct {
	TotalTokens   int    `json:"totalTokens"`
	TotalDuration int64  `json:"totalDuration"`
	InputTokens   int    `json:"inputTokens,omitempty"`
	OutputTokens  int    `json:"outputTokens,omitempty"`
	StopReason    string `json:"stopReason,omitempty"`
}

// ChatErrorBody is the payload for MsgTypeChatError.
type ChatErrorBody struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// ListResponseBody is the payload for MsgTypeListResponse.
type ListResponseBody struct {
	Agents []AgentInfo `json:"agents,omitempty"` // Agentic: per-agent model grouping
	Models []ModelInfo `json:"models"`           // Flat model list (backward compat)
}

// ListAgentsResponseBody is the payload for MsgTypeListAgents.
type ListAgentsResponseBody struct {
	Agents []AgentInfo `json:"agents"`
}

// StatusResponseBody is the payload for MsgTypeStatusResp.
type StatusResponseBody struct {
	PeerID      string `json:"peerId"`
	OllamaAlive bool   `json:"ollamaAlive"`
	Version     string `json:"version"`
}

// --- Agentic message bodies ---

// ThinkingBody is the payload for MsgTypeThinking.
type ThinkingBody struct {
	Token string `json:"token"`
}

// ToolUseBody is the payload for MsgTypeToolUse.
type ToolUseBody struct {
	Id    string          `json:"id"`
	Name  string          `json:"name"`
	Input json.RawMessage `json:"input"`
}

// ToolInputBody is the payload for MsgTypeToolInput.
type ToolInputBody struct {
	Id    string `json:"id"`
	Token string `json:"token"`
}

// ToolResultBody is the payload for MsgTypeToolResult.
type ToolResultBody struct {
	Id      string `json:"id"`
	Name    string `json:"name"`
	Output  string `json:"output"`
	IsError bool   `json:"isError"`
}

// SetModelBody is the payload for MsgTypeSetModel.
type SetModelBody struct {
	Agent string `json:"agent,omitempty"`
	Model string `json:"model"`
}

// EncodeMessage serializes a WireMessage to JSON bytes.
func EncodeMessage(wm WireMessage) ([]byte, error) {
	return json.Marshal(wm)
}

// DecodeMessage parses a JSON byte slice into a WireMessage.
func DecodeMessage(data []byte) (*WireMessage, error) {
	var wm WireMessage
	if err := json.Unmarshal(data, &wm); err != nil {
		return nil, fmt.Errorf("decode wire message: %w", err)
	}
	return &wm, nil
}

// NewMessage creates a WireMessage with a unique ID and current timestamp.
func NewMessage(msgType string, body interface{}) (*WireMessage, error) {
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal body: %w", err)
	}
	return &WireMessage{
		ID:   fmt.Sprintf("%d-%s", time.Now().UnixNano(), randomHex(6)),
		Time: time.Now().UnixMilli(),
		Type: msgType,
		Body: bodyBytes,
	}, nil
}

var msgCounter int64

// randomHex generates a short ID component from a counter and timestamp.
// Not cryptographically secure; used only for message correlation IDs.
func randomHex(n int) string {
	c := msgCounter
	msgCounter++
	ts := time.Now().UnixNano()
	v := ts ^ c
	const hexChars = "0123456789abcdef"
	b := make([]byte, n)
	for i := range b {
		b[i] = hexChars[v&0xf]
		v >>= 4
	}
	return string(b)
}
