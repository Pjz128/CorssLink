// Relay: Cloud relay server that bridges phone HTTP clients with agent WebSocket tunnels.
//
// Architecture:
//
//	Phone ──HTTP/SSE──► Relay (:18080) ──WebSocket──► Agent (NAT-ed PC)
//
// The relay exposes the same HTTP API as the agent (health, pair, chat, agents, sessions).
// Phone requests are forwarded to the appropriate agent over a persistent WebSocket connection.
// SSE streaming responses from the agent are relayed back to the phone in real time.
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ---- Protocol messages (mirrors agent/relay_bridge.go) ----

const (
	msgRegister    = "register"
	msgRegistered  = "registered"
	msgSessionBind = "session-bind"
	msgReq         = "req"
	msgCancel      = "cancel"
	msgRes         = "res"
	msgResStart    = "res-start"
	msgResChunk    = "res-chunk"
	msgResEnd      = "res-end"
	msgErr         = "err"
)

type wireMsg struct {
	Type         string          `json:"type"`
	RID          string          `json:"rid,omitempty"`
	PeerID       string          `json:"peerId,omitempty"`
	PairToken    string          `json:"pairToken,omitempty"`
	SessionToken string          `json:"sessionToken,omitempty"`
	Method       string          `json:"method,omitempty"`
	Path         string          `json:"path,omitempty"`
	Headers      json.RawMessage `json:"headers,omitempty"`
	Body         string          `json:"body,omitempty"`
	Data         string          `json:"data,omitempty"`
	Status       int             `json:"status,omitempty"`
	Message      string          `json:"message,omitempty"`
}

// ---- WebSocket upgrader ----

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ---- Agent connection ----

type agentConn struct {
	PeerID    string
	PairToken string
	Conn      *websocket.Conn
	mu        sync.Mutex // guards writes
}

func (a *agentConn) writeMsg(m wireMsg) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.Conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return a.Conn.WriteJSON(m)
}

// ---- Hub ----

type hub struct {
	mu sync.RWMutex

	agents     map[string]*agentConn // peerID → agent
	byPairToken map[string]string    // pairToken → peerID
	bySession   map[string]string    // sessionToken → peerID
	pending     map[string]chan wireMsg // rid → response channel for phone requests
}

func newHub() *hub {
	return &hub{
		agents:      make(map[string]*agentConn),
		byPairToken: make(map[string]string),
		bySession:   make(map[string]string),
		pending:     make(map[string]chan wireMsg),
	}
}

func (h *hub) registerAgent(peerID, pairToken string, conn *websocket.Conn) *agentConn {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Replace old connection for same peer ONLY if it's a different connection
	if old, ok := h.agents[peerID]; ok && old.Conn != conn {
		old.Conn.Close()
	}
	// Clean up old pairToken → peerID mapping
	for pt, pid := range h.byPairToken {
		if pid == peerID {
			delete(h.byPairToken, pt)
		}
	}

	ac := &agentConn{PeerID: peerID, PairToken: pairToken, Conn: conn}
	h.agents[peerID] = ac
	h.byPairToken[pairToken] = peerID
	log.Printf("[hub] agent registered: %s (total: %d)", peerID, len(h.agents))
	return ac
}

func (h *hub) unregisterAgent(peerID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if ac, ok := h.agents[peerID]; ok {
		ac.Conn.Close()
	}
	delete(h.agents, peerID)

	// Clean pair token mapping
	for pt, pid := range h.byPairToken {
		if pid == peerID {
			delete(h.byPairToken, pt)
		}
	}
	// Clean session mappings
	for st, pid := range h.bySession {
		if pid == peerID {
			delete(h.bySession, st)
		}
	}
	// Fail all pending requests for this agent
	for rid, ch := range h.pending {
		// We need to check if this pending request belongs to this agent.
		// Since we don't track rid→agent, just close all pending channels
		// when any agent disconnects — they'll timeout anyway.
		close(ch)
		delete(h.pending, rid)
	}
	log.Printf("[hub] agent unregistered: %s (total: %d)", peerID, len(h.agents))
}

func (h *hub) bindSession(sessionToken, peerID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.bySession[sessionToken] = peerID
	log.Printf("[hub] session bound: %s... → %s", sessionToken[:16], peerID)
}

func (h *hub) findAgentByPairToken(token string) *agentConn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	peerID, ok := h.byPairToken[token]
	if !ok {
		return nil
	}
	return h.agents[peerID]
}

func (h *hub) findAgentBySessionToken(token string) *agentConn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	peerID, ok := h.bySession[token]
	if !ok {
		return nil
	}
	return h.agents[peerID]
}

func (h *hub) dispatchResponse(msg wireMsg) {
	h.mu.RLock()
	ch, ok := h.pending[msg.RID]
	h.mu.RUnlock()
	if !ok {
		return
	}

	// Terminal messages: close channel after sending
	isTerminal := msg.Type == msgRes || msg.Type == msgResEnd || msg.Type == msgErr

	select {
	case ch <- msg:
	default:
		// Channel full or closed — drop
	}

	if isTerminal {
		h.mu.Lock()
		delete(h.pending, msg.RID)
		h.mu.Unlock()
	}
}

func (h *hub) forwardToAgent(ac *agentConn, method, path string, headers map[string]string, body []byte) (<-chan wireMsg, string, error) {
	rid := randomHex(16)

	headersJSON, _ := json.Marshal(headers)
	reqMsg := wireMsg{
		Type:    msgReq,
		RID:     rid,
		Method:  method,
		Path:    path,
		Headers: headersJSON,
	}
	if len(body) > 0 {
		reqMsg.Body = base64.StdEncoding.EncodeToString(body)
	}

	ch := make(chan wireMsg, 64) // buffered for streaming

	h.mu.Lock()
	h.pending[rid] = ch
	h.mu.Unlock()

	if err := ac.writeMsg(reqMsg); err != nil {
		h.mu.Lock()
		delete(h.pending, rid)
		h.mu.Unlock()
		return nil, "", fmt.Errorf("send req: %w", err)
	}

	return ch, rid, nil
}

// ---- HTTP handlers ----

// maxBodySize limits request bodies to 1MB.
const maxBodySize = 1 << 20

type relayServer struct {
	hub       *hub
	semaphore chan struct{} // concurrency limiter
}

func newRelayServer(h *hub) *relayServer {
	return &relayServer{
		hub:       h,
		semaphore: make(chan struct{}, 256),
	}
}

func (rs *relayServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	rs.hub.mu.RLock()
	count := len(rs.hub.agents)
	rs.hub.mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":  "ok",
		"type":    "crosslink-relay",
		"agents":  count,
		"version": "3.0-relay",
	})
}

func (rs *relayServer) handlePair(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Read body (limited)
	body, err := readLimitedBody(r, maxBodySize)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "body too large")
		return
	}

	// Extract pair token from body
	var pairReq struct {
		Token      string `json:"token"`
		DeviceName string `json:"deviceName"`
	}
	if err := json.Unmarshal(body, &pairReq); err != nil {
		jsonError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if pairReq.Token == "" {
		jsonError(w, http.StatusBadRequest, "missing token")
		return
	}

	// Find agent
	ac := rs.hub.findAgentByPairToken(pairReq.Token)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	// Forward to agent
	headers := map[string]string{"Content-Type": "application/json"}
	ch, rid, err := rs.hub.forwardToAgent(ac, "POST", "/api/pair", headers, body)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	// Wait for response (non-streaming, 30s timeout)
	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		rs.writeNonStreamingResponse(w, msg)
	case <-time.After(30 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
	case <-r.Context().Done():
		// Phone disconnected — cancel
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
	}
}

func (rs *relayServer) handleChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Extract session token from Authorization header
	sessionToken := extractBearerToken(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}

	// Find agent
	ac := rs.hub.findAgentBySessionToken(sessionToken)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	// Read body
	body, err := readLimitedBody(r, maxBodySize)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "body too large")
		return
	}

	// Forward to agent
	headers := map[string]string{
		"Content-Type":  "application/json",
		"Authorization": "Bearer " + sessionToken,
	}
	ch, rid, err := rs.hub.forwardToAgent(ac, "POST", "/api/chat", headers, body)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	// Read first response message
	var firstMsg wireMsg
	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		firstMsg = msg
	case <-time.After(120 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
		return
	case <-r.Context().Done():
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
		return
	}

	// Handle based on first message type
	switch firstMsg.Type {
	case msgRes:
		rs.writeNonStreamingResponse(w, firstMsg)
		return
	case msgResStart:
		rs.streamSSE(w, r, ac, rid, ch, firstMsg)
		return
	case msgErr:
		jsonError(w, firstMsg.Status, firstMsg.Message)
		return
	default:
		jsonError(w, http.StatusBadGateway, "unexpected agent response")
	}
}

func (rs *relayServer) handleChoice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	sessionToken := extractBearerToken(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}

	ac := rs.hub.findAgentBySessionToken(sessionToken)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	body, err := readLimitedBody(r, maxBodySize)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "body too large")
		return
	}

	headers := map[string]string{
		"Content-Type":  "application/json",
		"Authorization": "Bearer " + sessionToken,
	}
	ch, rid, err := rs.hub.forwardToAgent(ac, "POST", "/api/choice", headers, body)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		rs.writeNonStreamingResponse(w, msg)
	case <-time.After(30 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
	case <-r.Context().Done():
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
	}
}

func (rs *relayServer) handleAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	rs.forwardSimpleGet(w, r, "/api/agents")
}

func (rs *relayServer) handleSessions(w http.ResponseWriter, r *http.Request) {
	sessionToken := extractBearerToken(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}
	ac := rs.hub.findAgentBySessionToken(sessionToken)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	headers := map[string]string{"Authorization": "Bearer " + sessionToken}
	ch, rid, err := rs.hub.forwardToAgent(ac, r.Method, "/api/sessions", headers, nil)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		rs.writeNonStreamingResponse(w, msg)
	case <-time.After(30 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
	case <-r.Context().Done():
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
	}
}

func (rs *relayServer) handleSessionByID(w http.ResponseWriter, r *http.Request) {
	sessionToken := extractBearerToken(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}
	ac := rs.hub.findAgentBySessionToken(sessionToken)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	// Forward to the correct path: /api/sessions/<id>
	path := r.URL.Path
	headers := map[string]string{"Authorization": "Bearer " + sessionToken}
	ch, rid, err := rs.hub.forwardToAgent(ac, r.Method, path, headers, nil)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		rs.writeNonStreamingResponse(w, msg)
	case <-time.After(30 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
	case <-r.Context().Done():
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
	}
}

// ---- Shared helpers ----

func (rs *relayServer) forwardSimpleGet(w http.ResponseWriter, r *http.Request, path string) {
	sessionToken := extractBearerToken(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}
	ac := rs.hub.findAgentBySessionToken(sessionToken)
	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "agent offline")
		return
	}

	headers := map[string]string{"Authorization": "Bearer " + sessionToken}
	ch, rid, err := rs.hub.forwardToAgent(ac, "GET", path, headers, nil)
	if err != nil {
		jsonError(w, http.StatusBadGateway, "agent unreachable")
		return
	}

	select {
	case msg, ok := <-ch:
		if !ok {
			jsonError(w, http.StatusBadGateway, "agent disconnected")
			return
		}
		rs.writeNonStreamingResponse(w, msg)
	case <-time.After(30 * time.Second):
		rs.hub.mu.Lock()
		delete(rs.hub.pending, rid)
		rs.hub.mu.Unlock()
		jsonError(w, http.StatusGatewayTimeout, "agent timeout")
	case <-r.Context().Done():
		ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
	}
}

func (rs *relayServer) writeNonStreamingResponse(w http.ResponseWriter, msg wireMsg) {
	// Set headers
	if len(msg.Headers) > 0 {
		var headers map[string]string
		if err := json.Unmarshal(msg.Headers, &headers); err == nil {
			for k, v := range headers {
				w.Header().Set(k, v)
			}
		}
	}

	status := msg.Status
	if status == 0 {
		status = http.StatusOK
	}
	w.WriteHeader(status)

	if msg.Body != "" {
		decoded, err := base64.StdEncoding.DecodeString(msg.Body)
		if err == nil {
			w.Write(decoded)
		}
	}
}

func (rs *relayServer) streamSSE(w http.ResponseWriter, r *http.Request, ac *agentConn, rid string, ch <-chan wireMsg, firstMsg wireMsg) {
	// Set SSE headers from first (res-start) message
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	// Forward custom headers from agent
	if len(firstMsg.Headers) > 0 {
		var headers map[string]string
		if err := json.Unmarshal(firstMsg.Headers, &headers); err == nil {
			for k, v := range headers {
				if k != "Content-Type" && k != "Cache-Control" && k != "Connection" {
					w.Header().Set(k, v)
				}
			}
		}
	}

	w.WriteHeader(firstMsg.Status)
	flusher, ok := w.(http.Flusher)
	if !ok {
		return
	}

	// Read and forward chunks
	timeout := time.After(120 * time.Second)
	for {
		select {
		case msg, ok := <-ch:
			if !ok {
				return // channel closed
			}
			switch msg.Type {
			case msgResChunk:
				if msg.Data != "" {
					decoded, err := base64.StdEncoding.DecodeString(msg.Data)
					if err == nil {
						w.Write(decoded)
						flusher.Flush()
					}
				}
			case msgResEnd:
				return
			case msgErr:
				// Error during streaming — write as SSE error event
				errBody, _ := json.Marshal(map[string]any{"code": msg.Status, "message": msg.Message})
				fmt.Fprintf(w, "event: chat-err\ndata: %s\n\n", string(errBody))
				flusher.Flush()
				return
			}
		case <-timeout:
			ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
			return
		case <-r.Context().Done():
			ac.writeMsg(wireMsg{Type: msgCancel, RID: rid})
			return
		}
	}
}

// ---- WebSocket handler for agents ----

func (rs *relayServer) handleAgentWS(w http.ResponseWriter, r *http.Request) {
	peerID := r.URL.Query().Get("peer")
	pairToken := r.URL.Query().Get("token")
	if peerID == "" || pairToken == "" {
		http.Error(w, "missing ?peer=<id>&token=<pair_token>", http.StatusBadRequest)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ws] upgrade error: %v", err)
		return
	}
	defer conn.Close()

	// Keepalive
	conn.SetReadDeadline(time.Now().Add(120 * time.Second))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(120 * time.Second))
		return nil
	})
	go func() {
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}()

	ac := rs.hub.registerAgent(peerID, pairToken, conn)
	defer rs.hub.unregisterAgent(peerID)

	// Send registered acknowledgment
	ac.writeMsg(wireMsg{Type: msgRegistered, PeerID: peerID})

	// Read loop
	for {
		var msg wireMsg
		if err := conn.ReadJSON(&msg); err != nil {
			log.Printf("[ws] %s disconnected: %v", peerID, err)
			return
		}
		conn.SetReadDeadline(time.Now().Add(120 * time.Second))

		switch msg.Type {
		case msgRegister:
			// Re-registration (after reconnect)
			rs.hub.registerAgent(peerID, pairToken, conn)
			ac.writeMsg(wireMsg{Type: msgRegistered, PeerID: peerID})

		case msgSessionBind:
			if msg.SessionToken != "" {
				rs.hub.bindSession(msg.SessionToken, peerID)
			}

		case msgRes, msgResStart, msgResChunk, msgResEnd, msgErr:
			rs.hub.dispatchResponse(msg)

		default:
			log.Printf("[ws] %s unknown type: %s", peerID, msg.Type)
		}
	}
}

// ---- Middleware ----

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

// ---- Utility functions ----

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func readLimitedBody(r *http.Request, limit int64) ([]byte, error) {
	defer r.Body.Close()
	return io.ReadAll(io.LimitReader(r.Body, limit))
}

func extractBearerToken(auth string) string {
	if auth == "" {
		return ""
	}
	return strings.TrimPrefix(auth, "Bearer ")
}

func jsonError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]any{"error": msg})
}

// ---- Main ----

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	h := newHub()
	rs := newRelayServer(h)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", rs.handleHealth)
	mux.HandleFunc("/api/pair", rs.handlePair)
	mux.HandleFunc("/api/chat", rs.handleChat)
	mux.HandleFunc("/api/choice", rs.handleChoice)
	mux.HandleFunc("/api/agents", rs.handleAgents)
	mux.HandleFunc("/api/sessions", rs.handleSessions)
	mux.HandleFunc("/api/sessions/", rs.handleSessionByID)
	mux.HandleFunc("/agent", rs.handleAgentWS)

	addr := ":18080"
	log.Printf("[relay] CrossLink Cloud Relay starting on %s", addr)
	log.Printf("[relay] Phone API:  http://<host>%s/api/...", addr)
	log.Printf("[relay] Agent WS:  ws://<host>%s/agent?peer=<id>&token=<tok>", addr)

	lc := net.ListenConfig{KeepAlive: 15 * time.Second}
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Fatal(http.Serve(ln, corsMiddleware(mux)))
}

