// Package peer provides the shared WebRTC peer logic used by both
// Agent (home PC) and Client (mobile app) in the POC.
package peer

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
)

// Config for a WebRTC peer that connects to the signaling server.
type Config struct {
	PeerID          string
	SignalAddr      string
	OnMessage       func(msg string) // Called for DataChannel messages
	OnSignalMessage func(msg string) // Called for non-WebRTC signal messages (pairing, etc.)
	TURNServer      string // e.g. "turn:crosslink.cyou:3478"
	TURNUser        string
	TURNPass        string
}

// Peer manages a single WebRTC + signaling connection.
type Peer struct {
	cfg               Config
	signalConn        *websocket.Conn
	signalWriteMu     sync.Mutex
	pc                *webrtc.PeerConnection
	dataChannel       *webrtc.DataChannel
	mu                sync.Mutex
	connected         bool
	onConnect         func()
	onConnectOnce     sync.Once
	remotePeerID      string
	pendingCandidates []webrtc.ICECandidateInit
}

func New(cfg Config) (*Peer, error) {
	p := &Peer{cfg: cfg}

	if err := p.connectSignal(-1); err != nil { // infinite retry
		return nil, err
	}

	if err := p.resetPC(); err != nil {
		p.signalConn.Close()
		return nil, fmt.Errorf("reset pc: %w", err)
	}

	go p.readSignalLoop()
	go p.keepaliveLoop()
	return p, nil
}

// keepaliveLoop prevents cloud firewall idle timeout.
// Sends TextMessage every 10s so firewall sees application traffic.
func (p *Peer) keepaliveLoop() {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		p.signalWriteMu.Lock()
		err := p.signalConn.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping","to":"hub"}`))
		p.signalWriteMu.Unlock()
		if err != nil {
			log.Printf("[%s] keepalive write failed: %v", p.cfg.PeerID, err)
			go p.reconnectSignal()
		}
	}
}

func (p *Peer) SetOnConnect(fn func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.onConnect = fn
	p.onConnectOnce = sync.Once{}
}

func (p *Peer) IsConnected() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.connected
}

func (p *Peer) Send(msg string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.dataChannel == nil || !p.connected {
		return fmt.Errorf("not connected")
	}
	return p.dataChannel.SendText(msg)
}

// SendSignal sends a message over the WebSocket signaling channel.
// msg should be a JSON string. It is written directly as a text message
// to the signaling WebSocket so the signal server can route it.
func (p *Peer) SendSignal(msg string) error {
	p.signalWriteMu.Lock()
	defer p.signalWriteMu.Unlock()
	return p.signalConn.WriteMessage(websocket.TextMessage, []byte(msg))
}

func (p *Peer) CreateOffer(targetID string) error {
	p.mu.Lock()
	p.remotePeerID = targetID
	p.mu.Unlock()

	dc, err := p.pc.CreateDataChannel("crosslink-poc", &webrtc.DataChannelInit{
		Ordered: boolPtr(true),
	})
	if err != nil {
		return fmt.Errorf("create data channel: %w", err)
	}
	p.dataChannel = dc
	p.setupDataChannel(dc)

	offer, err := p.pc.CreateOffer(nil)
	if err != nil {
		return fmt.Errorf("create offer: %w", err)
	}
	if err := p.pc.SetLocalDescription(offer); err != nil {
		return fmt.Errorf("set local desc: %w", err)
	}

	log.Printf("[%s] created offer, sending to %s", p.cfg.PeerID, targetID)

	return p.sendSignal(map[string]any{
		"type":    "offer",
		"to":      targetID,
		"sdp":     offer.SDP,
		"typeSdp": "offer",
	})
}

func (p *Peer) Close() {
	if p.dataChannel != nil {
		p.dataChannel.Close()
	}
	if p.pc != nil {
		p.pc.Close()
	}
	if p.signalConn != nil {
		p.signalConn.Close()
	}
}

// ---- internal helpers ----

func (p *Peer) setupDataChannel(dc *webrtc.DataChannel) {
	dc.OnOpen(func() {
		log.Printf("[%s] ===== DATA CHANNEL OPENED =====", p.cfg.PeerID)
		p.mu.Lock()
		p.connected = true
		cb := p.onConnect
		p.mu.Unlock()
		if cb != nil {
			log.Printf("[%s] firing onConnect callback", p.cfg.PeerID)
			p.onConnectOnce.Do(cb)
		} else {
			log.Printf("[%s] no onConnect callback set", p.cfg.PeerID)
		}
	})
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		log.Printf("[%s] <- data: %s", p.cfg.PeerID, string(msg.Data))
		if p.cfg.OnMessage != nil {
			p.cfg.OnMessage(string(msg.Data))
		}
	})
	dc.OnClose(func() {
		log.Printf("[%s] data channel closed", p.cfg.PeerID)
		p.mu.Lock()
		p.connected = false
		p.mu.Unlock()
	})
}

// tcpKeepAliveDialer returns a websocket.Dialer with TCP keepalive enabled.
var tcpKeepAliveDialer = &websocket.Dialer{
	NetDial: func(network, addr string) (net.Conn, error) {
		conn, err := net.Dial(network, addr)
		if err != nil {
			return nil, err
		}
		if tcp, ok := conn.(*net.TCPConn); ok {
			tcp.SetKeepAlive(true)
			tcp.SetKeepAlivePeriod(15 * time.Second)
		}
		return conn, nil
	},
}

// connectSignal dials the signaling WebSocket with retry.
// maxAttempts < 0 means infinite retry (used by New).
func (p *Peer) connectSignal(maxAttempts int) error {
	backoff := 1 * time.Second
	const maxBackoff = 60 * time.Second
	attempt := 0

	for maxAttempts < 0 || attempt < maxAttempts {
		attempt++
		wsURL := fmt.Sprintf("%s/ws?peer=%s", p.cfg.SignalAddr, p.cfg.PeerID)
		conn, _, err := tcpKeepAliveDialer.Dial(wsURL, nil)
		if err == nil {
			p.signalConn = conn
			// Reset read deadline when server sends WebSocket pings (every 30s).
			// Must also send Pong, otherwise server will close the connection.
			p.signalConn.SetPingHandler(func(appData string) error {
				p.signalConn.SetReadDeadline(time.Now().Add(90 * time.Second))
				p.signalConn.WriteMessage(websocket.PongMessage, []byte(appData))
				return nil
			})
			log.Printf("[%s] connected to signaling server", p.cfg.PeerID)
			return nil
		}
		label := fmt.Sprintf("attempt %d", attempt)
		if maxAttempts > 0 {
			label = fmt.Sprintf("attempt %d/%d", attempt, maxAttempts)
		}
		log.Printf("[%s] signal dial failed (%s): %v — retrying in %v...",
			p.cfg.PeerID, label, err, backoff)
		time.Sleep(backoff)
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
	return fmt.Errorf("signal dial: exhausted %d attempts", maxAttempts)
}

func (p *Peer) reconnectSignal() bool {
	log.Printf("[%s] signal lost, reconnecting (max 10 attempts)...", p.cfg.PeerID)
	if err := p.connectSignal(10); err != nil {
		log.Printf("[%s] signal reconnect exhausted: %v", p.cfg.PeerID, err)
		return false
	}

	// Rebuild WebRTC state for the new signal session
	p.mu.Lock()
	p.connected = false
	p.onConnectOnce = sync.Once{} // Allow onConnect to fire again
	p.mu.Unlock()
	if err := p.resetPC(); err != nil {
		log.Printf("[%s] reset PC after reconnect: %v", p.cfg.PeerID, err)
	} else {
		log.Printf("[%s] WebRTC state reset for new signal session", p.cfg.PeerID)
	}
	return true
}

func (p *Peer) readSignalLoop() {
	for {
		// Deadline must be longer than server's 30s WebSocket ping interval.
		// If no message arrives within 90s, the connection is dead → reconnect.
		p.signalConn.SetReadDeadline(time.Now().Add(90 * time.Second))
		_, raw, err := p.signalConn.ReadMessage()
		if err != nil {
			log.Printf("[%s] signal read error: %v", p.cfg.PeerID, err)
			if !p.reconnectSignal() {
				return
			}
			continue
		}

		var msg map[string]any
		if err := json.Unmarshal(raw, &msg); err != nil {
			log.Printf("[%s] bad signal msg: %v", p.cfg.PeerID, err)
			continue
		}

		msgType, _ := msg["type"].(string)
		from, _ := msg["from"].(string)

		switch msgType {
		case "peers":
			log.Printf("[%s] online peers: %v", p.cfg.PeerID, msg)
		case "offer":
			log.Printf("[%s] received offer from %s", p.cfg.PeerID, from)
			p.handleOffer(from, msg)
		case "answer":
			log.Printf("[%s] received answer from %s", p.cfg.PeerID, from)
			p.handleAnswer(msg)
		case "candidate":
			p.handleCandidate(msg)
		default:
			// Forward non-WebRTC messages (pairing, control) to the app
			if p.cfg.OnSignalMessage != nil {
				p.cfg.OnSignalMessage(string(raw))
			}
		}
	}
}

func (p *Peer) resetPC() error {
	if p.pc != nil {
		_ = p.pc.Close()
	}

	iceServers := []webrtc.ICEServer{}
	if p.cfg.TURNServer != "" {
		iceServers = append(iceServers, webrtc.ICEServer{
			URLs:       []string{p.cfg.TURNServer},
			Username:   p.cfg.TURNUser,
			Credential: p.cfg.TURNPass,
		})
	}
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: iceServers,
	})
	if err != nil {
		return fmt.Errorf("reset pc: %w", err)
	}
	p.pc = pc

	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		log.Printf("[%s] received data channel: %s", p.cfg.PeerID, dc.Label())
		p.dataChannel = dc
		p.setupDataChannel(dc)
	})

	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("[%s] ICE state: %s", p.cfg.PeerID, state)
		if state == webrtc.ICEConnectionStateFailed {
			p.mu.Lock()
			p.connected = false
			p.mu.Unlock()
		}
	})

	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil {
			return
		}
		cand := c.ToJSON()
		p.mu.Lock()
		defer p.mu.Unlock()

		if p.remotePeerID == "" || p.pc.RemoteDescription() == nil {
			p.pendingCandidates = append(p.pendingCandidates, cand)
			return
		}
		p.sendSignalLocked(map[string]any{
			"type":         "candidate",
			"to":           p.remotePeerID,
			"iceCandidate": cand,
		})
	})

	p.pendingCandidates = nil
	return nil
}

func (p *Peer) handleOffer(from string, msg map[string]any) {
	sdp, _ := msg["sdp"].(string)
	if sdp == "" {
		log.Printf("[%s] offer missing sdp", p.cfg.PeerID)
		return
	}

	// Always recreate PC for every new offer — avoids stale ICE state,
	// ensures DataChannel OnOpen fires onConnect callback for each connection.
	// NOTE: must release lock before resetPC() because pc.Close() triggers
	// ICE callbacks that also acquire p.mu.
	log.Printf("[%s] recreating PC for new offer from %s", p.cfg.PeerID, from)
	p.connected = false
	p.onConnectOnce = sync.Once{} // Allow onConnect to fire for this new session
	if err := p.resetPC(); err != nil {
		log.Printf("[%s] reset PC: %v", p.cfg.PeerID, err)
		return
	}

	p.mu.Lock()
	p.remotePeerID = from
	p.mu.Unlock()

	if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer, SDP: sdp,
	}); err != nil {
		log.Printf("[%s] set remote offer: %v", p.cfg.PeerID, err)
		return
	}

	answer, err := p.pc.CreateAnswer(nil)
	if err != nil {
		log.Printf("[%s] create answer: %v", p.cfg.PeerID, err)
		return
	}
	if err := p.pc.SetLocalDescription(answer); err != nil {
		log.Printf("[%s] set local answer: %v", p.cfg.PeerID, err)
		return
	}

	p.sendSignal(map[string]any{
		"type":    "answer",
		"to":      from,
		"sdp":     answer.SDP,
		"typeSdp": "answer",
	})

	p.mu.Lock()
	pending := p.pendingCandidates
	p.pendingCandidates = nil
	p.mu.Unlock()
	for _, c := range pending {
		p.sendSignal(map[string]any{
			"type":         "candidate",
			"to":           from,
			"iceCandidate": c,
		})
	}
}

func (p *Peer) handleAnswer(msg map[string]any) {
	sdp, _ := msg["sdp"].(string)
	if sdp == "" {
		return
	}
	if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer, SDP: sdp,
	}); err != nil {
		log.Printf("[%s] set remote answer: %v", p.cfg.PeerID, err)
		return
	}

	p.mu.Lock()
	pending := p.pendingCandidates
	p.pendingCandidates = nil
	remoteID := p.remotePeerID
	p.mu.Unlock()

	for _, c := range pending {
		p.sendSignal(map[string]any{
			"type":         "candidate",
			"to":           remoteID,
			"iceCandidate": c,
		})
	}
}

func (p *Peer) handleCandidate(msg map[string]any) {
	candidateJSON, ok := msg["iceCandidate"]
	if !ok {
		return
	}
	candBytes, _ := json.Marshal(candidateJSON)
	var cand webrtc.ICECandidateInit
	if err := json.Unmarshal(candBytes, &cand); err != nil {
		log.Printf("[%s] bad candidate: %v", p.cfg.PeerID, err)
		return
	}
	if err := p.pc.AddICECandidate(cand); err != nil {
		log.Printf("[%s] add ice candidate: %v", p.cfg.PeerID, err)
	}
}

func (p *Peer) sendSignal(data map[string]any) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sendSignalLocked(data)
}

func (p *Peer) sendSignalLocked(data map[string]any) error {
	if p.signalConn == nil {
		return fmt.Errorf("no signal connection")
	}
	p.signalWriteMu.Lock()
	defer p.signalWriteMu.Unlock()
	return p.signalConn.WriteJSON(data)
}

func boolPtr(b bool) *bool { return &b }
