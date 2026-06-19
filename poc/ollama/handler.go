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
	Backend Backend  // Default backend (backward compat, pool takes precedence)
	Pool    *PoolWrapper
	SendFn  func(msg string) error // Send a message back over the DataChannel
}

// PoolWrapper avoids a circular import. The real pool lives in agent/pool.
// Set this to route requests to different backends by agent type.
type PoolWrapper struct {
	Get          func(agentType string) (Backend, bool)
	Default      func() Backend
	ListAgents   func() []AgentInfo
	Models       func() []ModelInfo
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
	case MsgTypeListAgents:
		h.handleListAgents(wm)
	case MsgTypeSetModel:
		h.handleSetModel(wm)
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

	// Resolve backend: explicit agent, pool default, or direct backend
	backend := h.resolveBackend(req.Agent)
	if backend == nil {
		h.sendError(wm, 500, "no backend available")
		return
	}

	log.Printf("[ollama-handler] chat request: agent=%s, model=%s, messages=%d",
		req.Agent, req.Model, len(req.Messages))

	// Register event callback for ExtendedBackend
	if eb, ok := backend.(ExtendedBackend); ok {
		eb.SetEventCallback(func(evt BackendEvent) {
			h.forwardEvent(evt)
		})
	}

	// Start streaming
	tokens, errs := backend.ChatStream(ChatRequest{
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
		h.sendError(wm, 500, fmt.Sprintf("stream: %v", err))
		return
	}

	// Send completion (with usage if available)
	doneBody := ChatDoneBody{TotalTokens: index}
	if eb, ok := backend.(ExtendedBackend); ok {
		doneBody.InputTokens, doneBody.OutputTokens, doneBody.StopReason = eb.LastUsage()
	}
	msg, _ := NewMessage(MsgTypeChatDone, doneBody)
	data, _ := EncodeMessage(*msg)
	if err := h.SendFn(string(data)); err != nil {
		log.Printf("[ollama-handler] send done: %v", err)
	}
	log.Printf("[ollama-handler] chat complete: %d tokens sent", index)
}

// resolveBackend picks a backend: agent field → pool lookup → fallback.
func (h *Handler) resolveBackend(agentType string) Backend {
	if agentType != "" && h.Pool != nil && h.Pool.Get != nil {
		if b, ok := h.Pool.Get(agentType); ok {
			return b
		}
	}
	if h.Pool != nil && h.Pool.Default != nil {
		return h.Pool.Default()
	}
	return h.Backend
}

// forwardEvent sends an ExtendedBackend event as a DataChannel message.
func (h *Handler) forwardEvent(evt BackendEvent) {
	switch evt.Type {
	case "thinking":
		h.sendRaw(MsgTypeThinking, evt.Data)
	case "tool_use":
		h.sendRaw(MsgTypeToolUse, evt.Data)
	case "tool_input":
		h.sendRaw(MsgTypeToolInput, evt.Data)
	case "tool_result":
		h.sendRaw(MsgTypeToolResult, evt.Data)
	case "choice_request":
		h.sendRaw(MsgTypeChoiceReq, evt.Data)
	}
}

func (h *Handler) handleListModels(wm *WireMessage) {
	// Prefer pool aggregate if available
	if h.Pool != nil && h.Pool.Models != nil {
		models := h.Pool.Models()
		agents := []AgentInfo{}
		if h.Pool.ListAgents != nil {
			agents = h.Pool.ListAgents()
		}
		msg, _ := NewMessage(MsgTypeListResponse, ListResponseBody{Models: models, Agents: agents})
		data, _ := EncodeMessage(*msg)
		if err := h.SendFn(string(data)); err != nil {
			log.Printf("[ollama-handler] send model list: %v", err)
		}
		log.Printf("[ollama-handler] sent %d models from pool", len(models))
		return
	}

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

func (h *Handler) handleListAgents(wm *WireMessage) {
	agents := []AgentInfo{}
	if h.Pool != nil && h.Pool.ListAgents != nil {
		agents = h.Pool.ListAgents()
	}
	msg, _ := NewMessage(MsgTypeListAgents, ListAgentsResponseBody{Agents: agents})
	data, _ := EncodeMessage(*msg)
	if err := h.SendFn(string(data)); err != nil {
		log.Printf("[ollama-handler] send agent list: %v", err)
	}
	log.Printf("[ollama-handler] sent %d agents", len(agents))
}

func (h *Handler) handleSetModel(wm *WireMessage) {
	var req SetModelBody
	if err := json.Unmarshal(wm.Body, &req); err != nil {
		return
	}
	log.Printf("[ollama-handler] set model: agent=%s, model=%s", req.Agent, req.Model)
	// Model switching is handled at the start of the next ChatStream call.
	// This is a best-effort notification to the backend.
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

// sendRaw sends a WireMessage with an already-marshalled JSON body.
func (h *Handler) sendRaw(msgType string, body json.RawMessage) {
	msg, err := NewMessage(msgType, nil)
	if err != nil {
		return
	}
	msg.Body = body
	data, _ := EncodeMessage(*msg)
	_ = h.SendFn(string(data))
}
