// Signal: WebSocket signaling server for WebRTC POC.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type SignalMsg struct {
	Type         string          `json:"type"`
	From         string          `json:"from,omitempty"`
	To           string          `json:"to,omitempty"`
	SDP          string          `json:"sdp,omitempty"`
	TypeSDP      string          `json:"typeSdp,omitempty"`
	ICECandidate json.RawMessage `json:"iceCandidate,omitempty"`
	PublicKey    string          `json:"publicKey,omitempty"`
	DeviceName   string          `json:"deviceName,omitempty"`
	Allowed      bool            `json:"allowed,omitempty"`
	Token        string          `json:"token,omitempty"`
}

type PeerKind string

const (
	KindAgent  PeerKind = "agent"
	KindClient PeerKind = "client"
)

type Peer struct {
	ID   string
	Kind PeerKind
	Conn *websocket.Conn
	mu   sync.Mutex
}

type Hub struct {
	mu    sync.RWMutex
	peers map[string]*Peer
}

func newHub() *Hub { return &Hub{peers: make(map[string]*Peer)} }

func (h *Hub) register(id string, kind PeerKind, conn *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.peers[id]; ok {
		old.Conn.Close()
	}
	h.peers[id] = &Peer{ID: id, Kind: kind, Conn: conn}
	log.Printf("[hub] peer registered: %s (%s) (total: %d)", id, kind, len(h.peers))
}

func (h *Hub) unregister(id string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.peers, id)
	log.Printf("[hub] peer gone: %s (total: %d)", id, len(h.peers))
}

func (h *Hub) send(fromID, toID string, msg SignalMsg) error {
	h.mu.RLock()
	peer, ok := h.peers[toID]
	h.mu.RUnlock()
	if !ok {
		log.Printf("[hub] peer %s not found, dropping message from %s", toID, fromID)
		return nil
	}
	peer.mu.Lock()
	defer peer.mu.Unlock()
	return peer.Conn.WriteJSON(msg)
}

func (h *Hub) listAgents() []Peer {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var agents []Peer
	for _, p := range h.peers {
		if p.Kind == KindAgent {
			agents = append(agents, *p)
		}
	}
	return agents
}

func (h *Hub) listPeers(excludeID string) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var ids []string
	for id := range h.peers {
		if id != excludeID {
			ids = append(ids, id)
		}
	}
	return ids
}

type AgentInfo struct {
	PeerID    string `json:"peerId"`
	PublicKey string `json:"publicKey"`
}

func handleWS(hub *Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		peerID := r.URL.Query().Get("peer")
		if peerID == "" {
			http.Error(w, "missing ?peer=<id>", http.StatusBadRequest)
			return
		}

		kindStr := r.URL.Query().Get("kind")
		kind := KindClient
		if kindStr == "agent" || strings.HasPrefix(peerID, "agent-") {
			kind = KindAgent
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("websocket upgrade error: %v", err)
			return
		}
		defer conn.Close()

		// Keepalive: ping every 30s, read deadline 60s
		conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		conn.SetPongHandler(func(string) error {
			conn.SetReadDeadline(time.Now().Add(60 * time.Second))
			return nil
		})
		go func() {
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}()

		hub.register(peerID, kind, conn)
		defer hub.unregister(peerID)

		existingPeers := hub.listPeers(peerID)
		if err := conn.WriteJSON(SignalMsg{
			Type: "peers",
			From: "hub",
			To:   peerID,
		}); err != nil {
			log.Printf("[hub] write peers to %s failed: %v", peerID, err)
			return
		}
		log.Printf("[hub] sent peer list to %s: %v", peerID, existingPeers)

		for {
			var msg SignalMsg
			if err := conn.ReadJSON(&msg); err != nil {
				log.Printf("[hub] %s disconnected: %v", peerID, err)
				return
			}
			msg.From = peerID

			if msg.To == "" || msg.To == "hub" {
				if msg.Type == "list" {
					conn.WriteJSON(SignalMsg{Type: "peers", From: "hub", To: peerID})
				}
				continue
			}

			log.Printf("[hub] routing %s from %s -> %s", msg.Type, peerID, msg.To)
			hub.send(peerID, msg.To, msg)
		}
	}
}

func handlePairingAgents(hub *Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		agents := hub.listAgents()
		infos := make([]AgentInfo, len(agents))
		for i, a := range agents {
			infos[i] = AgentInfo{PeerID: a.ID}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"agents": infos})
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	hub := newHub()
	http.HandleFunc("/ws", handleWS(hub))
	http.HandleFunc("/pairing/agents", handlePairingAgents(hub))
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		hub.mu.RLock()
		count := len(hub.peers)
		hub.mu.RUnlock()
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]any{"status": "ok", "peers": count})
	})

	addr := ":18080"
	log.Printf("[signal] listening on %s", addr)
	log.Printf("[signal] WebSocket: ws://localhost%s/ws?peer=<id>", addr)
	log.Printf("[signal] Pairing:   http://localhost%s/pairing/agents", addr)

	lc := net.ListenConfig{KeepAlive: 15 * time.Second}
	ln, err := lc.Listen(context.Background(), "tcp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Fatal(http.Serve(ln, nil))
}
