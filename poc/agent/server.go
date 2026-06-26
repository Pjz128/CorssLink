// Package agent provides the HTTP+SSE server for the CrossLink agent.
// It replaces the old WebRTC+WebSocket signaling architecture with
// simple HTTP endpoints and Server-Sent Events for token streaming.
package agent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"crosslink-poc/agent/claude"
	"crosslink-poc/agent/pool"
	"crosslink-poc/ollama"
	"crosslink-poc/plugin"
	claudeplugin "crosslink-poc/plugin/claude"
)

// Config holds parameters for the HTTP agent server.
type Config struct {
	Addr      string               // listen address, e.g. ":18080"
	Pool      *pool.BackendPool    // DEPRECATED: use Registry
	Registry  *plugin.AgentRegistry // plugin-based agent loading
	PairToken string               // pre-generated pairing token (empty = auto-generate)
	LanIP     string               // LAN IP for QR code display
}

// SessionContext holds conversation state for one paired device.
type SessionContext struct {
	ID            string
	Token         string
	DeviceName    string
	CreatedAt     time.Time
	Messages      []ollama.Message
	SelectedAgent string // DEPRECATED: use AgentType
	SelectedModel string
	AgentType     string // agent type bound at pairing (immutable)
}

// Server is the CrossLink agent HTTP server.
type Server struct {
	cfg              Config
	handler          *ollama.Handler
	sessions         map[string]*SessionContext // token → session
	mu               sync.RWMutex
	srv              *http.Server
	OnSessionCreated func(session *SessionContext) // called after pairing creates a session
}

// NewServer creates and configures the agent HTTP server.
func NewServer(cfg Config) (*Server, error) {
	if cfg.Registry == nil && cfg.Pool == nil {
		return nil, fmt.Errorf("registry or pool is required")
	}
	// Backward compat: if only Pool is set, wrap it
	if cfg.Registry == nil && cfg.Pool != nil {
		cfg.Registry = &plugin.AgentRegistry{}
		// Pool will be used via resolveBackend() fallback
	}
	if cfg.PairToken == "" {
		cfg.PairToken = randomToken()
	}
	if cfg.Addr == "" {
		cfg.Addr = ":18080"
	}

	s := &Server{
		cfg:      cfg,
		sessions: make(map[string]*SessionContext),
	}

	// Create handler (WebRTC legacy path, only if Pool is set)
	if cfg.Pool != nil {
		s.handler = ollama.NewHandler(cfg.Pool.Default(), nil)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/pair", s.handlePair)
	mux.HandleFunc("/api/chat", s.handleChat)
	mux.HandleFunc("/api/choice", s.handleChoice)
	mux.HandleFunc("/api/agents", s.handleAgents)
	mux.HandleFunc("/api/sessions", s.handleSessions)
	mux.HandleFunc("/api/sessions/", s.handleSessionByID)

	// Claude session management (plugin-specific, not coupled to other agents)
	mux.HandleFunc("/api/claude/sessions", s.handleClaudeSessions)
	mux.HandleFunc("/api/claude/sessions/", s.handleClaudeSessionByID)
	mux.HandleFunc("/api/claude/permission-mode", s.handleClaudePermissionMode)

	s.srv = &http.Server{Addr: cfg.Addr, Handler: corsMiddleware(mux)}
	return s, nil
}

// ListenAndServe starts the HTTP server (blocks).
func (s *Server) ListenAndServe() error {
	log.Printf("[server] HTTP agent listening on %s", s.cfg.Addr)
	log.Printf("[server] Pair token: %s", s.cfg.PairToken)
	if s.cfg.LanIP != "" {
		log.Printf("[server] QR URL: http://%s%s/pair?token=%s", s.cfg.LanIP, s.cfg.Addr, s.cfg.PairToken)
	}
	return s.srv.ListenAndServe()
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	if s.cfg.Pool != nil {
		s.cfg.Pool.CloseAll()
	}
	return s.srv.Shutdown(ctx)
}

// Handler returns the HTTP handler (mux with CORS middleware).
// Used by relay_bridge to forward relayed requests without starting a listener.
func (s *Server) Handler() http.Handler { return s.srv.Handler }

// GetSession returns a session by token (thread-safe).
func (s *Server) GetSession(token string) *SessionContext {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.sessions[token]
}

// PairToken returns the current pairing token.
func (s *Server) PairToken() string { return s.cfg.PairToken }

// CollectMetadata aggregates metadata from all registered plugins.
// Returns nil if no registry is configured.
func (s *Server) CollectMetadata() *plugin.AgentMeta {
	if s.cfg.Registry == nil {
		return nil
	}
	metaList := s.cfg.Registry.List()
	if len(metaList) == 0 {
		return nil
	}
	// Aggregate: use first plugin's type as primary, merge capabilities
	primary := metaList[0]
	capSet := make(map[string]bool)
	for _, m := range metaList {
		for _, c := range m.Capabilities {
			capSet[c] = true
		}
	}
	caps := make([]string, 0, len(capSet))
	for c := range capSet {
		caps = append(caps, c)
	}
	return &plugin.AgentMeta{
		Type:         primary.Type,
		Label:        primary.Label,
		Capabilities: caps,
	}
}

// ---- HTTP Handlers ----

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	agents := s.cfg.Pool.ListAgents()
	jsonOK(w, map[string]any{
		"status":  "ok",
		"agents":  len(agents),
		"version": "2.0-http",
	})
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonErr(w, 405, "method not allowed")
		return
	}

	var req struct {
		Token      string `json:"token"`
		DeviceName string `json:"deviceName"`
		Agent      string `json:"agent"` // optional: bind session to a specific agent
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, 400, "invalid body")
		return
	}

	if req.Token != s.cfg.PairToken {
		jsonErr(w, 403, "invalid pairing token")
		return
	}
	if req.DeviceName == "" {
		req.DeviceName = "Unknown Device"
	}

	// Create session (bind agent if specified)
	agentType := req.Agent
	if agentType == "" && s.cfg.Registry != nil {
		if def := s.cfg.Registry.Default(); def != nil {
			agentType = def.Metadata().Type
		}
	}
	session := &SessionContext{
		ID:         randomToken()[:16],
		Token:      randomToken(),
		DeviceName: req.DeviceName,
		CreatedAt:  time.Now(),
		AgentType:  agentType,
	}

	s.mu.Lock()
	s.sessions[session.Token] = session
	s.mu.Unlock()

	if s.OnSessionCreated != nil {
		s.OnSessionCreated(session)
	}

	log.Printf("[server] 📱 paired: %s (session=%s)", req.DeviceName, session.ID)

	jsonOK(w, map[string]any{
		"sessionId":    session.ID,
		"sessionToken": session.Token,
		"deviceName":   session.DeviceName,
	})
}

func (s *Server) handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonErr(w, 405, "method not allowed")
		return
	}

	// Authenticate
	session := s.authenticate(r)
	if session == nil {
		jsonErr(w, 401, "unauthorized")
		return
	}

	// Parse request
	var req ollama.ChatRequestBody
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, 400, "invalid chat body")
		return
	}

	// Reject empty messages
	if len(req.Messages) == 0 || strings.TrimSpace(req.Messages[len(req.Messages)-1].Content) == "" {
		jsonErr(w, 400, "empty message")
		return
	}

	// Enforce session-agent binding: reject cross-agent requests
	if session.AgentType != "" && req.Agent != "" && req.Agent != session.AgentType {
		jsonErr(w, 400, fmt.Sprintf(
			"agent mismatch: session bound to %q, request wants %q. Create a new session to switch agents.",
			session.AgentType, req.Agent))
		return
	}
	agentType := session.AgentType
	if agentType == "" {
		agentType = req.Agent // fallback for legacy sessions without AgentType
	}

	// Resolve backend via plugin registry (preferred) or pool (fallback)
	var backend ollama.Backend
	if p := s.resolvePlugin(agentType); p != nil {
		backend = p
	} else {
		backend = s.resolveBackend(agentType)
	}
	if backend == nil {
		jsonErr(w, 500, "no backend available")
		return
	}

	log.Printf("[server] chat: agent=%s model=%s msglen=%d", agentType, req.Model, len(req.Messages))

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, ok := w.(http.Flusher)
	if !ok {
		jsonErr(w, 500, "streaming not supported")
		return
	}
	sse := &sseWriter{w: w, flusher: flusher}

	// Register event callback (plugin.EventPlugin preferred, ExtendedBackend fallback)
	if ep, ok := backend.(plugin.EventPlugin); ok {
		ep.SetEventCallback(func(evt ollama.BackendEvent) {
			eventType := ""
			switch evt.Type {
			case "thinking":
				eventType = ollama.MsgTypeThinking
			case "tool_use":
				eventType = ollama.MsgTypeToolUse
			case "tool_input":
				eventType = ollama.MsgTypeToolInput
			case "tool_result":
				eventType = ollama.MsgTypeToolResult
			case "choice_request":
				eventType = ollama.MsgTypeChoiceReq
			default:
				return
			}
			if err := sse.writeEvent(eventType, evt.Data); err != nil {
				log.Printf("[server] sse write event(%s): %v", eventType, err)
			}
		})
	} else if eb, ok := backend.(ollama.ExtendedBackend); ok {
		eb.SetEventCallback(func(evt ollama.BackendEvent) {
			eventType := ""
			switch evt.Type {
			case "thinking":
				eventType = ollama.MsgTypeThinking
			case "tool_use":
				eventType = ollama.MsgTypeToolUse
			case "tool_input":
				eventType = ollama.MsgTypeToolInput
			case "tool_result":
				eventType = ollama.MsgTypeToolResult
			case "choice_request":
				eventType = ollama.MsgTypeChoiceReq
			default:
				return
			}
			if err := sse.writeEvent(eventType, evt.Data); err != nil {
				log.Printf("[server] sse write event(%s): %v", eventType, err)
			}
		})
	}

	// Start streaming
	modelName := req.Model
	if modelName == "" {
		modelName = "default"
	}
	tokens, errs := backend.ChatStream(ollama.ChatRequest{
		Model:    modelName,
		Messages: req.Messages,
		Options:  req.Options,
		Format:   req.Format,
	})

	// Read tokens → SSE, accumulate full response
	index := 0
	var fullResponse strings.Builder
	for token := range tokens {
		fullResponse.WriteString(token)
		body, _ := json.Marshal(ollama.ChatTokenBody{Token: token, Index: index})
		if err := sse.writeEvent(ollama.MsgTypeChatToken, body); err != nil {
			log.Printf("[server] sse write token: %v", err)
			return
		}
		index++
	}

	// Check for stream error
	if err := <-errs; err != nil {
		errBody, _ := json.Marshal(ollama.ChatErrorBody{Code: 500, Message: err.Error()})
		sse.writeEvent(ollama.MsgTypeChatError, errBody)
		flusher.Flush()
		return
	}

	// Done (with usage: plugin.UsagePlugin preferred, ExtendedBackend fallback)
	doneResp := ollama.ChatDoneBody{TotalTokens: index}
	if up, ok := backend.(plugin.UsagePlugin); ok {
		doneResp.InputTokens, doneResp.OutputTokens, doneResp.StopReason = up.LastUsage()
	} else if eb, ok := backend.(ollama.ExtendedBackend); ok {
		doneResp.InputTokens, doneResp.OutputTokens, doneResp.StopReason = eb.LastUsage()
	}
	doneBody, _ := json.Marshal(doneResp)
	sse.writeEvent(ollama.MsgTypeChatDone, doneBody)
	flusher.Flush()
	log.Printf("[server] chat done: %d tokens", index)
}

func (s *Server) handleAgents(w http.ResponseWriter, r *http.Request) {
	// Registry-first: use plugin metadata
	if s.cfg.Registry != nil {
		metaList := s.cfg.Registry.List()
		agents := make([]ollama.AgentInfo, 0, len(metaList))
		for _, m := range metaList {
			agents = append(agents, ollama.AgentInfo{
				Type:  m.Type,
				Label: m.Label,
				// Models filled by a separate per-agent API
			})
		}
		jsonOK(w, map[string]any{"agents": agents})
		return
	}
	// Pool fallback
	agents := s.cfg.Pool.ListAgents()
	if agents == nil {
		agents = []ollama.AgentInfo{}
	}
	jsonOK(w, map[string]any{"agents": agents})
}

func (s *Server) handleChoice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonErr(w, 405, "method not allowed")
		return
	}

	session := s.authenticate(r)
	if session == nil {
		jsonErr(w, 401, "unauthorized")
		return
	}

	var req struct {
		RequestID string `json:"requestId"`
		Behavior  string `json:"behavior"` // "allow" or "deny"
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, 400, "invalid body")
		return
	}
	if req.RequestID == "" || (req.Behavior != "allow" && req.Behavior != "deny") {
		jsonErr(w, 400, "missing requestId or invalid behavior")
		return
	}

	if !claude.SubmitChoice(req.RequestID, req.Behavior) {
		jsonErr(w, 404, "unknown or expired permission request")
		return
	}

	log.Printf("[server] choice: %s → %s (session=%s)", req.RequestID, req.Behavior, session.ID)
	jsonOK(w, map[string]any{"ok": true})
}

func (s *Server) handleSessions(w http.ResponseWriter, r *http.Request) {
	session := s.authenticate(r)
	if session == nil {
		jsonErr(w, 401, "unauthorized")
		return
	}

	if r.Method == http.MethodPost {
		// Create new session
		jsonOK(w, map[string]any{"id": session.ID, "created": true})
		return
	}

	// List sessions (single-session per token for now)
	list := []map[string]any{{
		"id":        session.ID,
		"device":    session.DeviceName,
		"createdAt": session.CreatedAt.Format(time.RFC3339),
		"messages":  len(session.Messages),
	}}
	jsonOK(w, list)
}

func (s *Server) handleSessionByID(w http.ResponseWriter, r *http.Request) {
	session := s.authenticate(r)
	if session == nil {
		jsonErr(w, 401, "unauthorized")
		return
	}

	// Extract session ID from URL path: /api/sessions/<id>
	_ = strings.TrimPrefix(r.URL.Path, "/api/sessions/")

	if r.Method == http.MethodDelete {
		s.mu.Lock()
		delete(s.sessions, session.Token)
		s.mu.Unlock()
		jsonOK(w, map[string]any{"deleted": true})
		return
	}

	// GET: return messages
	type msgJSON struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}
	msgs := make([]msgJSON, len(session.Messages))
	for i, m := range session.Messages {
		msgs[i] = msgJSON{Role: m.Role, Content: m.Content}
	}
	jsonOK(w, map[string]any{"id": session.ID, "messages": msgs})
}

// ---- Claude session management (plugin-specific) ----

func (s *Server) getClaudePlugin() (*claudeplugin.ClaudePlugin, bool) {
	if s.cfg.Registry == nil {
		return nil, false
	}
	p, ok := s.cfg.Registry.Get("claude")
	if !ok {
		return nil, false
	}
	cp, ok := p.(*claudeplugin.ClaudePlugin)
	return cp, ok
}

func (s *Server) handleClaudeSessions(w http.ResponseWriter, r *http.Request) {
	cp, ok := s.getClaudePlugin()
	if !ok {
		jsonErr(w, 503, "claude agent not available")
		return
	}

	switch r.Method {
	case http.MethodGet:
		jsonOK(w, cp.Sessions())

	case http.MethodPost:
		var req struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
			jsonErr(w, 400, "missing name")
			return
		}
		if err := cp.CreateSession(req.Name); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOK(w, map[string]any{"ok": true})

	default:
		jsonErr(w, 405, "method not allowed")
	}
}

func (s *Server) handleClaudeSessionByID(w http.ResponseWriter, r *http.Request) {
	cp, ok := s.getClaudePlugin()
	if !ok {
		jsonErr(w, 503, "claude agent not available")
		return
	}

	id := strings.TrimPrefix(r.URL.Path, "/api/claude/sessions/")
	if id == "" {
		jsonErr(w, 400, "missing session id")
		return
	}

	// Check for /api/claude/sessions/{id}/messages
	if strings.HasSuffix(id, "/messages") {
		sessionID := strings.TrimSuffix(id, "/messages")
		if r.Method == http.MethodGet {
			msgs, err := cp.GetMessages(sessionID)
			if err != nil {
				jsonErr(w, 500, err.Error())
				return
			}
			if msgs == nil {
				msgs = []ollama.Message{}
			}
			jsonOK(w, map[string]any{"sessionId": sessionID, "messages": msgs})
			return
		}
		jsonErr(w, 405, "method not allowed")
		return
	}

	switch r.Method {
	case http.MethodPost:
		// Activate session
		if err := cp.ActivateSession(id); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOK(w, map[string]any{"ok": true, "active": cp.ActiveSessionName()})

	case http.MethodDelete:
		if err := cp.DeleteSession(id); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOK(w, map[string]any{"ok": true})

	default:
		jsonErr(w, 405, "method not allowed")
	}
}

// ---- helpers ----

func (s *Server) handleClaudePermissionMode(w http.ResponseWriter, r *http.Request) {
	cp, ok := s.getClaudePlugin()
	if !ok {
		jsonErr(w, 503, "claude agent not available")
		return
	}
	if r.Method == http.MethodGet {
		jsonOK(w, map[string]any{"mode": cp.PermissionMode()})
		return
	}
	if r.Method != http.MethodPost {
		jsonErr(w, 405, "method not allowed")
		return
	}
	var req struct {
		Mode string `json:"mode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Mode == "" {
		jsonErr(w, 400, "missing mode")
		return
	}
	if err := cp.SetPermissionMode(req.Mode); err != nil {
		jsonErr(w, 400, err.Error())
		return
	}
	jsonOK(w, map[string]any{"mode": cp.PermissionMode()})
}

func (s *Server) resolveBackend(agentType string) ollama.Backend {
	if s.cfg.Pool == nil {
		return nil
	}
	if agentType != "" {
		if b, ok := s.cfg.Pool.Get(agentType); ok {
			return b
		}
	}
	return s.cfg.Pool.Default()
}

// resolvePlugin returns the AgentPlugin for an agent type.
// Registry-first: uses AgentRegistry if available, falls back to Pool.
func (s *Server) resolvePlugin(agentType string) plugin.AgentPlugin {
	if s.cfg.Registry != nil {
		if agentType != "" {
			if p, ok := s.cfg.Registry.Get(agentType); ok {
				return p
			}
		}
		return s.cfg.Registry.Default()
	}
	return nil
}

func (s *Server) authenticate(r *http.Request) *SessionContext {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return nil
	}
	token := strings.TrimPrefix(auth, "Bearer ")
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.sessions[token]
}

// ---- SSE Writer ----

type sseWriter struct {
	w       http.ResponseWriter
	flusher http.Flusher
	mu      sync.Mutex
}

func (s *sseWriter) writeEvent(event string, data json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// SSE format: "event: <type>\ndata: <json>\n\n"
	// Use explicit []byte write to avoid any Fprintf encoding quirks.
	buf := make([]byte, 0, len(event)+len(data)+20)
	buf = append(buf, "event: "...)
	buf = append(buf, event...)
	buf = append(buf, "\ndata: "...)
	buf = append(buf, data...)
	buf = append(buf, "\n\n"...)
	if _, err := s.w.Write(buf); err != nil {
		return err
	}
	s.flusher.Flush()
	return nil
}

// ---- JSON response helpers ----

func jsonOK(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func jsonErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"error": msg})
}

// ---- CORS ----

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- Crypto ----

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// Ensure interface compliance.
var _ = (*Server)(nil)
