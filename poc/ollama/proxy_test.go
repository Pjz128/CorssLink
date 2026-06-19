package ollama

import (
	"encoding/json"
	"testing"
)

func TestWireMessageRoundTrip(t *testing.T) {
	body := ChatRequestBody{
		Model:    "qwen2.5:7b",
		Messages: []Message{{Role: "user", Content: "Hello"}},
	}

	wm1, err := NewMessage(MsgTypeChatRequest, body)
	if err != nil {
		t.Fatalf("NewMessage: %v", err)
	}

	data, err := EncodeMessage(*wm1)
	if err != nil {
		t.Fatalf("EncodeMessage: %v", err)
	}

	wm2, err := DecodeMessage(data)
	if err != nil {
		t.Fatalf("DecodeMessage: %v", err)
	}

	if wm2.Type != MsgTypeChatRequest {
		t.Errorf("type = %s, want %s", wm2.Type, MsgTypeChatRequest)
	}
	if wm2.ID != wm1.ID {
		t.Errorf("id changed: %s -> %s", wm1.ID, wm2.ID)
	}

	var decodedBody ChatRequestBody
	if err := json.Unmarshal(wm2.Body, &decodedBody); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if decodedBody.Model != "qwen2.5:7b" {
		t.Errorf("model = %s, want qwen2.5:7b", decodedBody.Model)
	}
}

func TestAllMessageTypes(t *testing.T) {
	tests := []struct {
		msgType string
		body    interface{}
	}{
		{MsgTypeChatRequest, ChatRequestBody{Model: "llama3"}},
		{MsgTypeChatToken, ChatTokenBody{Token: "hello", Index: 0}},
		{MsgTypeChatDone, ChatDoneBody{TotalTokens: 42}},
		{MsgTypeChatError, ChatErrorBody{Code: 500, Message: "oops"}},
		{MsgTypeListResponse, ListResponseBody{Models: []ModelInfo{{Name: "test"}}}},
		{MsgTypeStatusResp, StatusResponseBody{PeerID: "a", OllamaAlive: true}},
		{MsgTypePing, map[string]string{}},
		{MsgTypePong, map[string]string{"echo": "pong"}},
	}

	for _, tt := range tests {
		t.Run(tt.msgType, func(t *testing.T) {
			wm, err := NewMessage(tt.msgType, tt.body)
			if err != nil {
				t.Fatalf("NewMessage: %v", err)
			}
			if wm.Type != tt.msgType {
				t.Errorf("type = %s, want %s", wm.Type, tt.msgType)
			}
			if wm.ID == "" {
				t.Error("id is empty")
			}
			if wm.Time == 0 {
				t.Error("time is zero")
			}
			if wm.Body == nil {
				t.Error("body is nil")
			}
		})
	}
}

func TestNewClient(t *testing.T) {
	c := NewClient("")
	if c.BaseURL != "http://127.0.0.1:11434" {
		t.Errorf("default URL = %s, want http://127.0.0.1:11434", c.BaseURL)
	}

	c2 := NewClient("http://localhost:12345/")
	if c2.BaseURL != "http://localhost:12345" {
		t.Errorf("custom URL = %s, want http://localhost:12345", c2.BaseURL)
	}
}

func TestHandlerCreation(t *testing.T) {
	sent := make([]string, 0)
	sendFn := func(msg string) error {
		sent = append(sent, msg)
		return nil
	}

	c := NewClient("")
	h := NewHandler(c, sendFn)
	if h.Backend == nil {
		t.Error("backend is nil")
	}
	if h.SendFn == nil {
		t.Error("send fn is nil")
	}
}

func TestModelInfo(t *testing.T) {
	m := ModelInfo{
		Name:      "qwen2.5:7b",
		SizeBytes: 4_500_000_000,
		Format:    "gguf",
		Family:    "qwen2",
		ParamSize: "7B",
		Quant:     "Q4_K_M",
	}

	data, _ := json.Marshal(m)
	var m2 ModelInfo
	json.Unmarshal(data, &m2)

	if m2.Name != "qwen2.5:7b" {
		t.Errorf("name = %s, want qwen2.5:7b", m2.Name)
	}
	if m2.Family != "qwen2" {
		t.Errorf("family = %s, want qwen2", m2.Family)
	}
}
