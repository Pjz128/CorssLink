// Package agent — RelayBridge: Agent-side WebSocket client that connects to the
// cloud relay server and bridges relayed HTTP requests into the local agent.Server.
//
// The relay bridge replaces the need for a local HTTP listener in relay mode.
// Instead, the agent connects OUTBOUND to the relay via WebSocket (reverse tunnel),
// receives forwarded phone requests, dispatches them to the agent's HTTP handler,
// and sends responses back over the same WebSocket.
package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// ---- Relay protocol message types ----

const (
	relayMsgRegister    = "register"
	relayMsgRegistered  = "registered"
	relayMsgSessionBind = "session-bind"
	relayMsgReq         = "req"
	relayMsgCancel      = "cancel"
	relayMsgRes         = "res"
	relayMsgResStart    = "res-start"
	relayMsgResChunk    = "res-chunk"
	relayMsgResEnd      = "res-end"
	relayMsgErr         = "err"
)

// relayMsg is a generic relay protocol message.
type relayMsg struct {
	Type         string          `json:"type"`
	RID          string          `json:"rid,omitempty"`
	PeerID       string          `json:"peerId,omitempty"`
	PairToken    string          `json:"pairToken,omitempty"`
	SessionToken string          `json:"sessionToken,omitempty"`
	Method       string          `json:"method,omitempty"`
	Path         string          `json:"path,omitempty"`
	Headers      json.RawMessage `json:"headers,omitempty"`
	Body         string          `json:"body,omitempty"`    // base64-encoded for req/res
	Data         string          `json:"data,omitempty"`    // base64-encoded for res-chunk
	Status       int             `json:"status,omitempty"`
	Message      string          `json:"message,omitempty"`
	Metadata     *relayAgentMeta `json:"metadata,omitempty"`   // agent capabilities
	Visibility   string          `json:"visibility,omitempty"` // "public"|"private"
}

// relayAgentMeta mirrors the relay's AgentMeta for JSON serialization.
type relayAgentMeta struct {
	Type         string   `json:"type"`
	Label        string   `json:"label"`
	Capabilities []string `json:"capabilities"`
}

// ---- RelayConfig ----

// RelayConfig holds parameters for connecting to the cloud relay.
type RelayConfig struct {
	RelayAddr   string // WebSocket URL, e.g. "ws://crosslink.cyou:18080/agent"
	PeerID      string
	PairToken   string
	DeployToken string // one-time deploy token for auto-claim
	Server      *Server // the agent HTTP server (provides Handler())
}

// ---- RelayBridge ----

// RelayBridge maintains a persistent WebSocket connection to the cloud relay,
// handles reconnection, and dispatches relayed requests to the agent's HTTP handler.
type RelayBridge struct {
	cfg    RelayConfig
	conn   *websocket.Conn
	mu     sync.Mutex // guards conn writes

	// Active request contexts for cancellation
	activeReqs   map[string]context.CancelFunc // rid → cancel
	activeReqsMu sync.Mutex

	// Known session tokens (re-bound after reconnect)
	sessionTokens   []string
	sessionTokensMu sync.Mutex

	// Reconnect backoff
	reconnectDelay time.Duration
}

// NewRelayBridge creates a RelayBridge.
func NewRelayBridge(cfg RelayConfig) *RelayBridge {
	if cfg.Server == nil {
		panic("RelayBridge: Server is required")
	}
	return &RelayBridge{
		cfg:         cfg,
		activeReqs:  make(map[string]context.CancelFunc),
	}
}

// Connect dials the relay and starts the message loop. Blocks until ctx is cancelled.
// Automatically reconnects on disconnect with exponential backoff.
func (b *RelayBridge) Connect(ctx context.Context) error {
	b.reconnectDelay = 1 * time.Second

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if err := b.connectAndServe(ctx); err != nil {
			log.Printf("[relay-bridge] connection error: %v — reconnecting in %v", err, b.reconnectDelay)
		}

		// Wait before reconnecting
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(b.reconnectDelay):
		}

		// Exponential backoff: 1s, 2s, 4s, 8s, 16s, max 30s
		b.reconnectDelay *= 2
		if b.reconnectDelay > 30*time.Second {
			b.reconnectDelay = 30 * time.Second
		}
	}
}

func (b *RelayBridge) connectAndServe(ctx context.Context) error {
	// Build URL with query params
	u, err := url.Parse(b.cfg.RelayAddr)
	if err != nil {
		return fmt.Errorf("parse relay addr: %w", err)
	}
	q := u.Query()
	q.Set("peer", b.cfg.PeerID)
	q.Set("token", b.cfg.PairToken)
	if b.cfg.DeployToken != "" {
		q.Set("deploy", b.cfg.DeployToken)
	}
	u.RawQuery = q.Encode()

	log.Printf("[relay-bridge] connecting to %s", u.String())
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, u.String(), nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	b.conn = conn
	b.reconnectDelay = 1 * time.Second // reset backoff on successful connection

	// Collect agent metadata from plugin registry
	var meta *relayAgentMeta
	if m := b.cfg.Server.CollectMetadata(); m != nil {
		meta = &relayAgentMeta{
			Type:         m.Type,
			Label:        m.Label,
			Capabilities: m.Capabilities,
		}
	}
	// Read default visibility from env
	visibility := os.Getenv("AGENT_VISIBILITY")
	if visibility == "" {
		visibility = "private"
	}

	// Send registration with metadata
	if err := b.writeMsg(relayMsg{
		Type:       relayMsgRegister,
		PeerID:     b.cfg.PeerID,
		PairToken:  b.cfg.PairToken,
		Metadata:   meta,
		Visibility: visibility,
	}); err != nil {
		conn.Close()
		return fmt.Errorf("register: %w", err)
	}
	log.Printf("[relay-bridge] registered as %s (visibility=%s)", b.cfg.PeerID, visibility)

	// Re-bind any existing session tokens
	b.sessionTokensMu.Lock()
	tokens := make([]string, len(b.sessionTokens))
	copy(tokens, b.sessionTokens)
	b.sessionTokensMu.Unlock()
	for _, st := range tokens {
		if err := b.writeMsg(relayMsg{
			Type:         relayMsgSessionBind,
			SessionToken: st,
		}); err != nil {
			conn.Close()
			return fmt.Errorf("re-bind session: %w", err)
		}
	}
	if len(tokens) > 0 {
		log.Printf("[relay-bridge] re-bound %d session token(s)", len(tokens))
	}

	// Message loop
	return b.handleMessages(ctx)
}

func (b *RelayBridge) handleMessages(ctx context.Context) error {
	defer b.conn.Close()

	// Read loop with context cancellation
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			b.conn.Close()
		case <-done:
		}
	}()

	for {
		var msg relayMsg
		if err := b.conn.ReadJSON(&msg); err != nil {
			close(done)
			// Cancel all active requests
			b.activeReqsMu.Lock()
			for rid, cancel := range b.activeReqs {
				cancel()
				delete(b.activeReqs, rid)
			}
			b.activeReqsMu.Unlock()
			return fmt.Errorf("read: %w", err)
		}

		switch msg.Type {
		case relayMsgRegistered:
			log.Printf("[relay-bridge] relay confirmed registration")

		case relayMsgReq:
			go b.handleRequest(ctx, &msg)

		case relayMsgCancel:
			b.activeReqsMu.Lock()
			if cancel, ok := b.activeReqs[msg.RID]; ok {
				cancel()
				delete(b.activeReqs, msg.RID)
			}
			b.activeReqsMu.Unlock()

		default:
			log.Printf("[relay-bridge] unknown message type: %s", msg.Type)
		}
	}
}

func (b *RelayBridge) handleRequest(parentCtx context.Context, msg *relayMsg) {
	// Create cancellable context for this request
	reqCtx, cancel := context.WithCancel(parentCtx)
	b.activeReqsMu.Lock()
	b.activeReqs[msg.RID] = cancel
	b.activeReqsMu.Unlock()
	defer func() {
		b.activeReqsMu.Lock()
		delete(b.activeReqs, msg.RID)
		b.activeReqsMu.Unlock()
		cancel()
	}()

	// Build http.Request
	httpReq, err := b.buildHTTPRequest(reqCtx, msg)
	if err != nil {
		b.writeMsg(relayMsg{
			Type:    relayMsgErr,
			RID:     msg.RID,
			Status:  400,
			Message: fmt.Sprintf("bad request: %v", err),
		})
		return
	}

	// Create relay response writer
	w := &relayResponseWriter{
		header:    make(http.Header),
		relayConn: b.conn,
		rid:       msg.RID,
		bridge:    b,
	}

	// Dispatch to the agent's HTTP handler
	b.cfg.Server.Handler().ServeHTTP(w, httpReq)

	// After handler returns, finalize the response
	w.finalize()

	// If this was a successful /api/pair, extract and bind the session token
	if msg.Path == "/api/pair" && w.statusCode == 200 {
		b.bindSession(w.rid, w.body.Bytes())
	}
}

func (b *RelayBridge) buildHTTPRequest(ctx context.Context, msg *relayMsg) (*http.Request, error) {
	// Decode body
	var bodyReader io.Reader
	if msg.Body != "" {
		decoded, err := base64.StdEncoding.DecodeString(msg.Body)
		if err != nil {
			return nil, fmt.Errorf("decode body: %w", err)
		}
		bodyReader = bytes.NewReader(decoded)
	}

	req, err := http.NewRequestWithContext(ctx, msg.Method, "http://localhost"+msg.Path, bodyReader)
	if err != nil {
		return nil, err
	}

	// Set headers from relayed request
	if len(msg.Headers) > 0 {
		var headers map[string]string
		if err := json.Unmarshal(msg.Headers, &headers); err != nil {
			return nil, fmt.Errorf("decode headers: %w", err)
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
	}

	// Ensure Content-Type is set if we have a body
	if msg.Body != "" && req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}

	return req, nil
}

// bindSession extracts the sessionToken from a pairing response and sends it to the relay.
func (b *RelayBridge) bindSession(rid string, body []byte) {
	var resp struct {
		SessionToken string `json:"sessionToken"`
	}
	if err := json.Unmarshal(body, &resp); err != nil || resp.SessionToken == "" {
		log.Printf("[relay-bridge] pair response missing sessionToken, rid=%s", rid)
		return
	}

	if err := b.writeMsg(relayMsg{
		Type:         relayMsgSessionBind,
		RID:          rid,
		SessionToken: resp.SessionToken,
	}); err != nil {
		log.Printf("[relay-bridge] session-bind failed: %v", err)
		return
	}

	b.sessionTokensMu.Lock()
	b.sessionTokens = append(b.sessionTokens, resp.SessionToken)
	b.sessionTokensMu.Unlock()
	log.Printf("[relay-bridge] session bound: %s...", resp.SessionToken[:16])
}

func (b *RelayBridge) writeMsg(msg relayMsg) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	return b.conn.WriteJSON(msg)
}

// ---- relayResponseWriter ----

// relayResponseWriter implements http.ResponseWriter and http.Flusher.
// It captures handler output and sends it back to the relay as structured messages.
type relayResponseWriter struct {
	header      http.Header
	statusCode  int
	body        bytes.Buffer
	flushed     bool   // true if Flush() was ever called (SSE mode)
	headerSent  bool   // true if res-start was already sent (SSE mode)
	relayConn   *websocket.Conn
	rid         string
	bridge      *RelayBridge
}

func (w *relayResponseWriter) Header() http.Header { return w.header }

func (w *relayResponseWriter) WriteHeader(statusCode int) {
	if w.statusCode != 0 {
		return // headers already sent
	}
	w.statusCode = statusCode
}

func (w *relayResponseWriter) Write(b []byte) (int, error) {
	if w.statusCode == 0 {
		w.WriteHeader(http.StatusOK)
	}
	w.body.Write(b)
	return len(b), nil // report full write to caller (data is buffered)
}

// Flush sends the buffered body as a res-chunk message to the relay.
// On first flush, it sends res-start with headers. This is called by the SSE writer.
func (w *relayResponseWriter) Flush() {
	if w.body.Len() == 0 && w.headerSent {
		return
	}

	if !w.headerSent {
		// First flush: send headers
		headers := make(map[string]string)
		for k := range w.header {
			headers[k] = w.header.Get(k)
		}
		headersJSON, _ := json.Marshal(headers)

		status := w.statusCode
		if status == 0 {
			status = http.StatusOK
		}

		w.bridge.writeMsg(relayMsg{
			Type:    relayMsgResStart,
			RID:     w.rid,
			Status:  status,
			Headers: headersJSON,
		})
		w.headerSent = true
		w.flushed = true
	}

	if w.body.Len() > 0 {
		data := base64.StdEncoding.EncodeToString(w.body.Bytes())
		w.body.Reset()
		w.bridge.writeMsg(relayMsg{
			Type: relayMsgResChunk,
			RID:  w.rid,
			Data: data,
		})
	}
}

// finalize sends the remaining buffered data and ends the response stream.
// Called by the bridge after the HTTP handler returns.
func (w *relayResponseWriter) finalize() {
	if w.flushed {
		// Streaming mode: send remaining buffer, then end
		if w.body.Len() > 0 {
			data := base64.StdEncoding.EncodeToString(w.body.Bytes())
			w.bridge.writeMsg(relayMsg{
				Type: relayMsgResChunk,
				RID:  w.rid,
				Data: data,
			})
		}
		w.bridge.writeMsg(relayMsg{
			Type: relayMsgResEnd,
			RID:  w.rid,
		})
	} else {
		// Non-streaming mode: send single response with headers + body
		headers := make(map[string]string)
		for k := range w.header {
			headers[k] = w.header.Get(k)
		}
		headersJSON, _ := json.Marshal(headers)

		status := w.statusCode
		if status == 0 {
			status = http.StatusOK
		}

		w.bridge.writeMsg(relayMsg{
			Type:    relayMsgRes,
			RID:     w.rid,
			Status:  status,
			Headers: headersJSON,
			Body:    base64.StdEncoding.EncodeToString(w.body.Bytes()),
		})
	}
}

// Ensure interface compliance.
var _ http.Flusher = (*relayResponseWriter)(nil)
