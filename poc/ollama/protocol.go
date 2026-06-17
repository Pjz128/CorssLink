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
)

// WireMessage is the top-level envelope for all CrossLink DataChannel messages.
type WireMessage struct {
	ID   string          `json:"id"`   // Unique message ID (cuid2-style)
	Time int64           `json:"time"` // Unix milliseconds
	Type string          `json:"type"` // One of MsgType* constants
	Body json.RawMessage `json:"body"` // Type-specific payload
}

// ChatRequestBody is the payload for MsgTypeChatRequest.
type ChatRequestBody struct {
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
	TotalTokens   int   `json:"totalTokens"`
	TotalDuration int64 `json:"totalDuration"`
}

// ChatErrorBody is the payload for MsgTypeChatError.
type ChatErrorBody struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// ListResponseBody is the payload for MsgTypeListResponse.
type ListResponseBody struct {
	Models []ModelInfo `json:"models"`
}

// StatusResponseBody is the payload for MsgTypeStatusResp.
type StatusResponseBody struct {
	PeerID      string `json:"peerId"`
	OllamaAlive bool   `json:"ollamaAlive"`
	Version     string `json:"version"`
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
