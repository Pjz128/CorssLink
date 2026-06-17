package ollama

import (
	"encoding/json"
	"fmt"
	"log"
)

// Handler processes CrossLink DataChannel messages by forwarding
// chat requests to an LLM backend and streaming tokens back.
// It is the bridge between the WebRTC DataChannel and the LLM API.
type Handler struct {
	Backend Backend
	SendFn  func(msg string) error // Send a message back over the DataChannel
}

// NewHandler creates a Handler with the given LLM backend.
func NewHandler(backend Backend, sendFn func(string) error) *Handler {
	return &Handler{
		Backend: backend,
		SendFn:  sendFn,
	}
}

// HandleMessage processes an incoming CrossLink wire message.
// It dispatches based on message type and sends responses back via SendFn.
func (h *Handler) HandleMessage(raw string) {
	wm, err := DecodeMessage([]byte(raw))
	if err != nil {
		log.Printf("[ollama-handler] decode error: %v", err)
		return
	}

	switch wm.Type {
	case MsgTypeChatRequest:
		h.handleChatRequest(wm)
	case MsgTypeListModels:
		h.handleListModels(wm)
	case MsgTypeStatus:
		h.handleStatus(wm)
	case MsgTypePing:
		h.handlePing(wm)
	default:
		log.Printf("[ollama-handler] unknown message type: %s", wm.Type)
	}
}

func (h *Handler) handleChatRequest(wm *WireMessage) {
	var req ChatRequestBody
	if err := json.Unmarshal(wm.Body, &req); err != nil {
		h.sendError(wm, 400, "invalid chat request body")
		return
	}

	log.Printf("[ollama-handler] chat request: model=%s, messages=%d", req.Model, len(req.Messages))

	// Start streaming from Ollama
	tokens, errs := h.Backend.ChatStream(ChatRequest{
		Model:    req.Model,
		Messages: req.Messages,
		Options:  req.Options,
		Format:   req.Format,
	})

	// Read tokens and send them one by one
	index := 0
	for token := range tokens {
		msg, err := NewMessage(MsgTypeChatToken, ChatTokenBody{
			Token: token,
			Index: index,
		})
		if err != nil {
			log.Printf("[ollama-handler] encode token msg: %v", err)
			continue
		}
		data, _ := EncodeMessage(*msg)
		if err := h.SendFn(string(data)); err != nil {
			log.Printf("[ollama-handler] send token: %v", err)
			return // Client disconnected, stop streaming
		}
		index++
	}

	// Check for stream error
	if err := <-errs; err != nil {
		h.sendError(wm, 500, fmt.Sprintf("ollama stream: %v", err))
		return
	}

	// Send completion
	msg, _ := NewMessage(MsgTypeChatDone, ChatDoneBody{
		TotalTokens: index,
	})
	data, _ := EncodeMessage(*msg)
	if err := h.SendFn(string(data)); err != nil {
		log.Printf("[ollama-handler] send done: %v", err)
	}
	log.Printf("[ollama-handler] chat complete: %d tokens sent", index)
}

func (h *Handler) handleListModels(wm *WireMessage) {
	models, err := h.Backend.ListModels()
	if err != nil {
		h.sendError(wm, 500, fmt.Sprintf("list models: %v", err))
		return
	}

	msg, _ := NewMessage(MsgTypeListResponse, ListResponseBody{Models: models})
	data, _ := EncodeMessage(*msg)
	if err := h.SendFn(string(data)); err != nil {
		log.Printf("[ollama-handler] send model list: %v", err)
	}
	log.Printf("[ollama-handler] sent %d models", len(models))
}

func (h *Handler) handleStatus(wm *WireMessage) {
	version, err := h.Backend.Ping()
	alive := err == nil

	msg, _ := NewMessage(MsgTypeStatusResp, StatusResponseBody{
		PeerID:      "agent",
		OllamaAlive: alive,
		Version:     version,
	})
	data, _ := EncodeMessage(*msg)
	_ = h.SendFn(string(data))
}

func (h *Handler) handlePing(wm *WireMessage) {
	msg, _ := NewMessage(MsgTypePong, map[string]string{"echo": "pong"})
	data, _ := EncodeMessage(*msg)
	_ = h.SendFn(string(data))
}

func (h *Handler) sendError(wm *WireMessage, code int, message string) {
	log.Printf("[ollama-handler] error: %s", message)
	msg, _ := NewMessage(MsgTypeChatError, ChatErrorBody{
		Code:    code,
		Message: message,
	})
	data, _ := EncodeMessage(*msg)
	_ = h.SendFn(string(data))
}
