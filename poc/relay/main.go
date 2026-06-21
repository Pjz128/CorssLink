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
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image/png"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"crosslink-poc/pairing"

	"github.com/gorilla/websocket"
	qrcode "github.com/skip2/go-qrcode"
)

//go:embed dashboard.html
var dashboardHTML []byte

//go:embed dist/manifest.json
var manifestJSON []byte

//go:embed dist/windows/start.bat
var startBatTemplate []byte

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
	Metadata     *AgentMeta      `json:"metadata,omitempty"`     // agent-reported capabilities
	Visibility   string          `json:"visibility,omitempty"`   // agent default visibility
}

// ---- WebSocket upgrader ----

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ---- Agent connection ----

type agentConn struct {
	PeerID      string
	PairToken   string
	Conn        *websocket.Conn
	ConnectedAt time.Time
	Metadata    *AgentMeta `json:"metadata,omitempty"` // agent-reported capabilities
	Visibility  string     `json:"visibility,omitempty"` // "public" or "private" (default "private")
	mu          sync.Mutex // guards writes
}

// AgentMeta mirrors plugin.AgentMeta for relay-side storage.
type AgentMeta struct {
	Type         string   `json:"type"`
	Label        string   `json:"label"`
	Capabilities []string `json:"capabilities"`
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

func (h *hub) registerAgent(peerID, pairToken string, conn *websocket.Conn, metadata *AgentMeta, visibility string) *agentConn {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Replace old connection for same peer only if different conn (reconnect)
	if old, ok := h.agents[peerID]; ok && old.Conn != conn {
		old.Conn.Close()
	}
	// Clean up old pairToken → peerID mapping
	for pt, pid := range h.byPairToken {
		if pid == peerID {
			delete(h.byPairToken, pt)
		}
	}

	ac := &agentConn{PeerID: peerID, PairToken: pairToken, Conn: conn, ConnectedAt: time.Now(), Metadata: metadata, Visibility: visibility}
	h.agents[peerID] = ac
	h.byPairToken[pairToken] = peerID
	log.Printf("[hub] agent registered: %s (total: %d)", peerID, len(h.agents))
	return ac
}

func (h *hub) unregisterAgent(peerID string, conn *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Only remove if this is still the active connection for this peer
	// (prevent stale goroutine from removing a reconnected agent)
	if ac, ok := h.agents[peerID]; ok && ac.Conn == conn {
		ac.Conn.Close()
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
			close(ch)
			delete(h.pending, rid)
		}
		log.Printf("[hub] agent unregistered: %s (total: %d)", peerID, len(h.agents))
	}
}

func (h *hub) unregisterAgentByPeer(peerID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	ac, ok := h.agents[peerID]
	if !ok {
		return
	}
	ac.Conn.Close()
	delete(h.agents, peerID)

	for pt, pid := range h.byPairToken {
		if pid == peerID {
			delete(h.byPairToken, pt)
		}
	}
	for st, pid := range h.bySession {
		if pid == peerID {
			delete(h.bySession, st)
		}
	}
	for rid, ch := range h.pending {
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
	hub        *hub
	semaphore  chan struct{} // concurrency limiter
	auth       *authMiddleware
	userStore  *userStore
	ownership  *ownershipManager
	connReqs   *connectionRequestStore // connection request persistence
	distDir    string                  // filesystem path for large dist files
}

func newRelayServer(h *hub, us *userStore, sm *sessionManager, om *ownershipManager, cr *connectionRequestStore, distDir string) *relayServer {
	return &relayServer{
		hub:        h,
		semaphore:  make(chan struct{}, 256),
		auth:       newAuthMiddleware(sm),
		userStore:  us,
		ownership:  om,
		connReqs:   cr,
		distDir:    distDir,
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

	// Auto-claim via deploy token (one-time use)
	if deployToken := r.URL.Query().Get("deploy"); deployToken != "" {
		if username, ok := rs.ownership.claimByDeployToken(deployToken, peerID); ok {
			log.Printf("[ws] deploy token auto-claimed: %s → %s", peerID, username)
		} else {
			log.Printf("[ws] invalid/expired deploy token: %s...", deployToken[:16])
		}
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

	ac := rs.hub.registerAgent(peerID, pairToken, conn, nil, "")
	defer rs.hub.unregisterAgent(peerID, conn)

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
			// Re-registration (after reconnect) — update metadata & visibility
			vis := msg.Visibility
			if vis == "" {
				vis = "private" // default
			}
			ac = rs.hub.registerAgent(peerID, pairToken, conn, msg.Metadata, vis)
			ac.writeMsg(wireMsg{Type: msgRegistered, PeerID: peerID})

		case msgSessionBind:
			if msg.SessionToken != "" {
				rs.hub.bindSession(msg.SessionToken, peerID)
				// Record session ownership: if this agent is claimed, session belongs to that user
				if owner, ok := rs.ownership.getAgentOwner(peerID); ok {
					if err := rs.ownership.recordSession(msg.SessionToken, owner); err != nil {
						log.Printf("[ws] session ownership record failed: %v", err)
					}
				}
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

// ---- Dashboard handlers ----

func (rs *relayServer) handleDashboard(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.WriteHeader(http.StatusOK)
	w.Write(dashboardHTML)
}

func (rs *relayServer) handleDashboardAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	session := getSession(r)

	// Collect agents under hub lock
	rs.hub.mu.RLock()
	agents := make([]map[string]any, 0, len(rs.hub.agents))
	for _, ac := range rs.hub.agents {
		owner, claimed := rs.ownership.getAgentOwner(ac.PeerID)
		// Filter: admin sees all, users see unclaimed + their own
		if !session.IsAdmin && claimed && owner != session.Username {
			continue
		}
		agents = append(agents, map[string]any{
			"peerID":      ac.PeerID,
			"pairToken":   ac.PairToken,
			"connectedAt": ac.ConnectedAt.UTC().Format(time.RFC3339),
			"online":      true,
			"owner":       owner,
			"claimed":     claimed,
				"visibility":  rs.ownership.getAgentVisibility(ac.PeerID),
		})
	}
	rs.hub.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"agents": agents,
		"count":  len(agents),
	})
}

func (rs *relayServer) handleDashboardQR(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	peerID := r.URL.Query().Get("peer")
	if peerID == "" {
		jsonError(w, http.StatusBadRequest, "missing ?peer=<id>")
		return
	}

	rs.hub.mu.RLock()
	ac, ok := rs.hub.agents[peerID]
	rs.hub.mu.RUnlock()
	if !ok {
		jsonError(w, http.StatusNotFound, "agent not found or offline")
		return
	}

	serverURL := fmt.Sprintf("http://%s/pair?token=%s", r.Host, ac.PairToken)
	qrPayload := pairing.QRPayload{
		Version:   2,
		PublicKey: "",
		ServerURL: serverURL,
		PeerID:    ac.PeerID,
	}
	qrURI := pairing.EncodeQR(qrPayload)

	qr, err := qrcode.New(qrURI, qrcode.Medium)
	if err != nil {
		log.Printf("[dashboard] QR error for %s: %v", peerID, err)
		jsonError(w, http.StatusInternalServerError, "failed to generate QR code")
		return
	}

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.WriteHeader(http.StatusOK)
	if err := png.Encode(w, qr.Image(256)); err != nil {
		log.Printf("[dashboard] PNG encode error for %s: %v", peerID, err)
	}
}

// ---- Auth handlers ----

func (rs *relayServer) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	body, err := readLimitedBody(r, maxBodySize)
	if err != nil {
		jsonError(w, http.StatusBadRequest, "body too large")
		return
	}

	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		jsonError(w, http.StatusBadRequest, "invalid body")
		return
	}
	if req.Username == "" || req.Password == "" {
		jsonError(w, http.StatusBadRequest, "missing username or password")
		return
	}

	u, err := rs.userStore.authenticate(req.Username, req.Password)
	if err != nil {
		jsonError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	s := rs.auth.SessionMgr.create(u.Username, u.IsAdmin)
	setSessionCookie(w, s.SessionID)
	newJSONEncoder(w).Encode(map[string]any{
		"username": u.Username,
		"isAdmin":  u.IsAdmin,
	})
}

func (rs *relayServer) handleLogout(w http.ResponseWriter, r *http.Request) {
	cookie, _ := r.Cookie("session_id")
	if cookie != nil {
		rs.auth.SessionMgr.destroy(cookie.Value)
	}
	clearSessionCookie(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"ok":true}`))
}

func (rs *relayServer) handleAuthMe(w http.ResponseWriter, r *http.Request) {
	s := getSession(r)
	if s == nil {
		jsonError(w, http.StatusUnauthorized, "not logged in")
		return
	}
	newJSONEncoder(w).Encode(map[string]any{
		"username": s.Username,
		"isAdmin":  s.IsAdmin,
	})
}

// Admin: GET /api/admin/users (list), POST /api/admin/users (create)
func (rs *relayServer) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	s := getSession(r)
	if s == nil || !s.IsAdmin {
		jsonError(w, http.StatusForbidden, "admin required")
		return
	}

	switch r.Method {
	case http.MethodGet:
		newJSONEncoder(w).Encode(map[string]any{
			"users": rs.userStore.listUsers(),
		})

	case http.MethodPost:
		body, err := readLimitedBody(r, maxBodySize)
		if err != nil {
			jsonError(w, http.StatusBadRequest, "body too large")
			return
		}
		var req struct {
			Username string `json:"username"`
			Password string `json:"password"`
			IsAdmin  bool   `json:"isAdmin"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			jsonError(w, http.StatusBadRequest, "invalid body")
			return
		}
		if req.Username == "" || req.Password == "" {
			jsonError(w, http.StatusBadRequest, "missing username or password")
			return
		}
		if err := rs.userStore.createUser(req.Username, req.Password, req.IsAdmin, s.Username); err != nil {
			jsonError(w, http.StatusConflict, err.Error())
			return
		}
		newJSONEncoder(w).Encode(map[string]any{"ok": true})

	default:
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// Admin: DELETE /api/admin/users/{name}
func (rs *relayServer) handleAdminUserByName(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	s := getSession(r)
	username := strings.TrimPrefix(r.URL.Path, "/api/admin/users/")
	if username == "" {
		jsonError(w, http.StatusBadRequest, "missing username")
		return
	}
	if username == s.Username {
		jsonError(w, http.StatusBadRequest, "cannot delete yourself")
		return
	}
	if err := rs.userStore.deleteUser(username); err != nil {
		jsonError(w, http.StatusNotFound, err.Error())
		return
	}
	newJSONEncoder(w).Encode(map[string]any{"ok": true})
}

// Dashboard: POST /api/dashboard/claim?peer=<id>
func (rs *relayServer) handleDashboardClaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	s := getSession(r)
	peerID := r.URL.Query().Get("peer")
	if peerID == "" {
		jsonError(w, http.StatusBadRequest, "missing ?peer=<id>")
		return
	}

	// Verify agent exists
	rs.hub.mu.RLock()
	_, online := rs.hub.agents[peerID]
	rs.hub.mu.RUnlock()
	if !online {
		jsonError(w, http.StatusNotFound, "agent not found or offline")
		return
	}

	if err := rs.ownership.claimAgent(peerID, s.Username); err != nil {
		jsonError(w, http.StatusConflict, err.Error())
		return
	}
	newJSONEncoder(w).Encode(map[string]any{"ok": true})
}

// Dashboard: POST /api/dashboard/unclaim?peer=<id>
func (rs *relayServer) handleDashboardUnclaim(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	s := getSession(r)
	peerID := r.URL.Query().Get("peer")
	if peerID == "" {
		jsonError(w, http.StatusBadRequest, "missing ?peer=<id>")
		return
	}

	if err := rs.ownership.unclaimAgent(peerID, s.Username, s.IsAdmin); err != nil {
		jsonError(w, http.StatusConflict, err.Error())
		return
	}
	newJSONEncoder(w).Encode(map[string]any{"ok": true})
}

// forwardToAnyAgent forwards a request to any available agent.
// Used for agent-specific APIs (Claude sessions, etc.) that don't require a session token.
func (rs *relayServer) forwardToAnyAgent(w http.ResponseWriter, r *http.Request) {
	rs.hub.mu.RLock()
	var ac *agentConn
	for _, a := range rs.hub.agents {
		ac = a
		break
	}
	rs.hub.mu.RUnlock()

	if ac == nil {
		jsonError(w, http.StatusServiceUnavailable, "no agent online")
		return
	}

	// Read body for POST/PUT requests
	body, _ := readLimitedBody(r, maxBodySize)
	ch, rid, err := rs.hub.forwardToAgent(ac, r.Method, r.URL.Path, nil, body)
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
	}
}

// ---- Download handlers ----

func (rs *relayServer) handleDownloadsList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")

	// Try versioned manifest from dist/current/ first
	diskManifest := filepath.Join(rs.distDir, "current", "manifest.json")
	if data, err := os.ReadFile(diskManifest); err == nil {
		w.Write(data)
		return
	}
	// Try dist/manifest.json as fallback (copied on Windows/no-symlink systems)
	fallbackManifest := filepath.Join(rs.distDir, "manifest.json")
	if data, err := os.ReadFile(fallbackManifest); err == nil {
		w.Write(data)
		return
	}
	// Embedded fallback (last resort)
	w.Write(manifestJSON)
}

func (rs *relayServer) handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	// Path: /api/download/{platform}/{file}
	filePath := strings.TrimPrefix(r.URL.Path, "/api/download/")
	if filePath == "" || strings.Contains(filePath, "..") {
		jsonError(w, http.StatusBadRequest, "invalid path")
		return
	}

	// Serve from filesystem: try versioned (current/) first, then root dist
	fullPath := filepath.Join(rs.distDir, "current", filePath)
	if _, err := os.Stat(fullPath); err != nil {
		fullPath = filepath.Join(rs.distDir, filePath)
	}
	f, err := os.Open(fullPath)
	if err != nil {
		jsonError(w, http.StatusNotFound, "file not found")
		return
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		jsonError(w, http.StatusInternalServerError, "stat failed")
		return
	}

	filename := filepath.Base(filePath)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
	w.Header().Set("Cache-Control", "public, max-age=3600")
	http.ServeContent(w, r, filename, stat.ModTime(), f)
}

func (rs *relayServer) handleDashboardQRAPK(w http.ResponseWriter, r *http.Request) {
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	apkURL := fmt.Sprintf("%s://%s/api/download/android/crosslink.apk", scheme, r.Host)

	qr, err := qrcode.New(apkURL, qrcode.Medium)
	if err != nil {
		log.Printf("[dashboard] QR-APK error: %v", err)
		jsonError(w, http.StatusInternalServerError, "failed to generate QR code")
		return
	}

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	png.Encode(w, qr.Image(256))
}

// handleDeployDownload — personalized agent zip with auto-claim token.
func (rs *relayServer) handleDeployDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	session := getSession(r)
	if session == nil {
		jsonError(w, http.StatusUnauthorized, "login required")
		return
	}

	// Generate one-time deploy token
	deployToken := rs.ownership.createDeployToken(session.Username)

	// Customize start.bat with deploy token
	customBat := strings.Replace(string(startBatTemplate),
		"set RELAY_ADDR=ws://crosslink.cyou:18080/agent",
		"set RELAY_ADDR=ws://crosslink.cyou:18080/agent\nset DEPLOY_TOKEN="+deployToken,
		1)

	// Read ollama-agent.exe from filesystem dist
	agentPath := filepath.Join(rs.distDir, "windows", "ollama-agent.exe")
	agentData, err := os.ReadFile(agentPath)
	if err != nil {
		log.Printf("[deploy] agent binary not found at %s: %v", agentPath, err)
		jsonError(w, http.StatusServiceUnavailable, "agent binary not available")
		return
	}

	// Build zip in memory
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	// ollama-agent.exe
	f1, _ := zw.Create("ollama-agent.exe")
	f1.Write(agentData)

	// start.bat
	f2, _ := zw.Create("start.bat")
	f2.Write([]byte(customBat))

	zw.Close()

	// Serve
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="crosslink-agent-%s.zip"`, session.Username))
	w.Header().Set("Cache-Control", "no-cache, no-store, must-revalidate")
	w.Write(buf.Bytes())

	log.Printf("[deploy] served personalized zip for %s (token=%s...)", session.Username, deployToken[:16])
}

// ---- Main ----

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	// Data directory for JSON persistence
	dataDir := os.Getenv("CROSSLINK_DATA_DIR")
	if dataDir == "" {
		dataDir = "./data"
	}

	// Admin password: env or auto-generate
	adminPassword := os.Getenv("CROSSLINK_ADMIN_PASSWORD")
	if adminPassword == "" {
		adminPassword = randomHex(16)
		log.Printf("[auth] 🔑 No CROSSLINK_ADMIN_PASSWORD set — generated: %s", adminPassword)
		log.Printf("[auth] Set CROSSLINK_ADMIN_PASSWORD env var to use a fixed password.")
	}

	// Initialize stores
	us, err := newUserStore(filepath.Join(dataDir, "users.json"))
	if err != nil {
		log.Fatalf("user store: %v", err)
	}
	if err := us.initAdmin(adminPassword); err != nil {
		log.Fatalf("init admin: %v", err)
	}

	sm := newSessionManager()

	om, err := newOwnershipManager(filepath.Join(dataDir, "ownership.json"))
	if err != nil {
		log.Fatalf("ownership manager: %v", err)
	}

	cr, err := newConnectionRequestStore(filepath.Join(dataDir, "connection_requests.json"))
	if err != nil {
		log.Fatalf("connection request store: %v", err)
	}

	h := newHub()
	// Dist directory for large binary downloads (not embedded)
	distDir := os.Getenv("CROSSLINK_DIST_DIR")
	if distDir == "" {
		distDir = "./dist"
	}

	rs := newRelayServer(h, us, sm, om, cr, distDir)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", rs.handleHealth)
	mux.HandleFunc("/api/pair", rs.handlePair)
	mux.HandleFunc("/api/chat", rs.handleChat)
	mux.HandleFunc("/api/choice", rs.handleChoice)
	mux.HandleFunc("/api/agents", rs.handleAgents)
	mux.HandleFunc("/api/sessions", rs.handleSessions)
	mux.HandleFunc("/api/sessions/", rs.handleSessionByID)
	mux.HandleFunc("/agent", rs.handleAgentWS)
	// Claude session management — forward to agent
	mux.HandleFunc("/api/claude/sessions", rs.forwardToAnyAgent)
	mux.HandleFunc("/api/claude/sessions/", rs.forwardToAnyAgent)
	// Auth endpoints
	mux.HandleFunc("/api/auth/login", rs.handleLogin)
	mux.HandleFunc("/api/auth/logout", rs.auth.requireAuth(rs.handleLogout))
	mux.HandleFunc("/api/auth/me", rs.auth.requireAuth(rs.handleAuthMe))

	// Admin endpoints
	mux.HandleFunc("/api/admin/users", rs.auth.requireAdmin(rs.handleAdminUsers))
	mux.HandleFunc("/api/admin/users/", rs.auth.requireAdmin(rs.handleAdminUserByName))

	// Dashboard (HTML is public; JS handles login UI)
	mux.HandleFunc("/dashboard", rs.handleDashboard)

	// Dashboard API (auth required)
	mux.HandleFunc("/api/dashboard/agents", rs.auth.requireAuth(rs.handleDashboardAgents))
	mux.HandleFunc("/api/dashboard/qr", rs.auth.requireAuth(rs.handleDashboardQR))
	mux.HandleFunc("/api/dashboard/claim", rs.auth.requireAuth(rs.handleDashboardClaim))
	mux.HandleFunc("/api/dashboard/unclaim", rs.auth.requireAuth(rs.handleDashboardUnclaim))

	// Download API (public, for software distribution)
	mux.HandleFunc("/api/downloads", rs.handleDownloadsList)
	mux.HandleFunc("/api/download/", rs.handleDownload)
	mux.HandleFunc("/api/dashboard/qr-apk", rs.auth.requireAuth(rs.handleDashboardQRAPK))

	// Discover API (mobile, Bearer session token auth)
	mux.HandleFunc("/api/discover/agents", rs.handleDiscoverAgents)
	mux.HandleFunc("/api/discover/connect", rs.handleDiscoverConnect)
	mux.HandleFunc("/api/discover/requests", rs.handleDiscoverRequests)

	// Dashboard: connection request management (cookie auth)
	mux.HandleFunc("/api/dashboard/requests", rs.auth.requireAuth(rs.handleDashboardRequests))
	mux.HandleFunc("/api/dashboard/requests/", rs.auth.requireAuth(rs.handleDashboardRequestAction))

	// Dashboard: agent visibility toggle (cookie auth)
	mux.HandleFunc("/api/dashboard/agents/", rs.auth.requireAuth(rs.handleDashboardVisibility))

	// Deploy: personalized agent download with auto-claim token
	mux.HandleFunc("/api/deploy/windows", rs.auth.requireAuth(rs.handleDeployDownload))

	addr := ":18080"
	log.Printf("[relay] CrossLink Cloud Relay starting on %s", addr)
	log.Printf("[relay] Dashboard:   http://<host>%s/dashboard", addr)
	log.Printf("[relay] Phone API:   http://<host>%s/api/...", addr)
	log.Printf("[relay] Agent WS:    ws://<host>%s/agent?peer=<id>&token=<tok>", addr)

	lc := net.ListenConfig{KeepAlive: 15 * time.Second}
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Fatal(http.Serve(ln, corsMiddleware(mux)))
}

