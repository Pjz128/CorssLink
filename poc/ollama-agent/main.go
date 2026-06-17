// Ollama Agent POC: full Agent with pairing + cloud LLM proxy.
//
// Flow:
//   1. Connect to signal server, display QR for pairing
//   2. Wait for mobile client to pair and establish WebRTC DataChannel
//   3. Once DataChannel is open, forward LLM requests through it
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"

	"crosslink-poc/cloud"
	"crosslink-poc/ollama"
	"crosslink-poc/pairing"
	"crosslink-poc/peer"
)

const (
	signalAddr = "ws://45.197.144.16:18080"
	peerID     = "agent-ollama-pc"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink POC: Cloud Agent ===\n")

	// ---- Load or create persistent keypair ----
	agentKP := loadOrCreateKeypair()

	// Display QR code
	qrPayload := pairing.QRPayload{
		Version:   1,
		PublicKey: agentKP.PublicKeyBase64(),
		ServerURL: signalAddr,
		PeerID:    peerID,
	}
	qrURI := pairing.EncodeQR(qrPayload)

	log.Printf("")
	log.Printf("┌─────────────────────────────────────────────────────┐")
	log.Printf("│  📱 Scan to connect to Cloud Agent:                │")
	log.Printf("│  %s", qrURI)
	log.Printf("└─────────────────────────────────────────────────────┘")
	log.Printf("")

	// Create the handler (sendFn will be set once DataChannel is open)
	var ollamaHandler *ollama.Handler
	dataChannelReady := make(chan struct{})
	var setupOnce sync.Once

	// Connect to signal + set up WebRTC
	var p *peer.Peer
	turnServer := os.Getenv("TURN_SERVER")
	if turnServer == "" {
		turnServer = "turn:45.197.144.16:3478?transport=tcp"
	}
	turnUser := os.Getenv("TURN_USER")
	if turnUser == "" {
		turnUser = "turnuser"
	}
	turnPass := os.Getenv("TURN_PASS")
	if turnPass == "" {
		turnPass = "crosslinkpass123"
	}

	p, err := peer.New(peer.Config{
		PeerID:     peerID,
		SignalAddr: signalAddr,
		TURNServer: turnServer,
		TURNUser:   turnUser,
		TURNPass:   turnPass,
		OnMessage: func(raw string) {
			if ollamaHandler != nil {
				ollamaHandler.HandleMessage(raw)
			} else {
				log.Printf("[agent] received message before handler ready: %s", raw)
			}
		},
		OnSignalMessage: func(raw string) {
			var msg struct {
				Type       string `json:"type"`
				From       string `json:"from"`
				To         string `json:"to"`
				PublicKey  string `json:"publicKey"`
				DeviceName string `json:"deviceName"`
			}
			if err := json.Unmarshal([]byte(raw), &msg); err != nil {
				return
			}
			if msg.Type == "pairing-request" {
				log.Printf("[agent] 📱 Pairing request from %s (%s)", msg.From, msg.DeviceName)
				acceptPairing(p, agentKP, msg)
			}
		},
	})
	if err != nil {
		log.Fatalf("create peer: %v", err)
	}
	defer p.Close()

	log.Printf("[agent] connected to signal, waiting for connections...")

	// Set up connect callback — idempotent, safe to fire on reconnection.
	p.SetOnConnect(func() {
		log.Printf("[agent] ✅ DataChannel established!")

		// Initialize cloud LLM backend (DeepSeek)
		backend := cloud.NewDeepSeek("", "deepseek-chat")
		ollamaHandler = ollama.NewHandler(backend, p.Send)
		log.Printf("[agent] LLM handler ready (DeepSeek cloud)")

		// Check connectivity
		version, err := backend.Ping()
		if err != nil {
			log.Printf("[agent] ⚠️  Cloud API not reachable: %v", err)
		} else {
			log.Printf("[agent] ☁️  Cloud backend: %s", version)
		}

		setupOnce.Do(func() {
			close(dataChannelReady)
		})
	})

	// Wait for data channel or Ctrl+C
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	select {
	case <-sig:
		log.Printf("[agent] shutting down...")
	case <-dataChannelReady:
		log.Printf("[agent] Cloud proxy active. Press Ctrl+C to stop.")
		<-sig
		log.Printf("[agent] shutting down...")
	}
}

// loadOrCreateKeypair returns the agent's keypair, loading from disk if available.
func loadOrCreateKeypair() *pairing.KeyPair {
	// Derive machine-bound master key from hostname + peerID
	masterKey := deriveMasterKey(peerID)

	// Determine config directory
	configDir, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		configDir = filepath.Join(home, ".crosslink")
	} else {
		configDir = filepath.Join(configDir, "crosslink")
	}

	if err := os.MkdirAll(configDir, 0700); err != nil {
		log.Printf("[agent] WARNING: cannot create config dir %s: %v", configDir, err)
	}

	keyPath := filepath.Join(configDir, "agent_key.json")

	// Try loading existing keypair
	kp, err := pairing.LoadKeyPair(keyPath, &masterKey)
	if err == nil {
		log.Printf("[agent] loaded existing keypair from %s", keyPath)
		return kp
	}

	if !os.IsNotExist(err) {
		log.Printf("[agent] WARNING: failed to load keypair (%v), generating new one", err)
	}

	// Generate new keypair and save
	kp, err = pairing.GenerateKeyPair()
	if err != nil {
		log.Fatalf("generate keypair: %v", err)
	}
	if err := pairing.SaveKeyPair(kp, keyPath, &masterKey); err != nil {
		log.Printf("[agent] WARNING: failed to save keypair: %v", err)
	} else {
		log.Printf("[agent] generated new keypair, saved to %s", keyPath)
	}
	return kp
}

// deriveMasterKey creates a machine-bound 32-byte key.
func deriveMasterKey(peerID string) [32]byte {
	hostname, _ := os.Hostname()
	seed := fmt.Sprintf("%s:%s:crosslink-agent-key-v1", hostname, peerID)
	return sha256.Sum256([]byte(seed))
}

func acceptPairing(p *peer.Peer, agentKP *pairing.KeyPair, req struct {
	Type       string `json:"type"`
	From       string `json:"from"`
	To         string `json:"to"`
	PublicKey  string `json:"publicKey"`
	DeviceName string `json:"deviceName"`
}) {
	log.Printf("[agent] Accepting pairing from %s...", req.DeviceName)

	ltToken, err := pairing.GenerateLongTermToken()
	if err != nil {
		log.Printf("[agent] generate token error: %v", err)
		return
	}
	ltToken.AgentID = peerID
	ltToken.DeviceID = req.From
	ltToken.DeviceName = req.DeviceName

	tokenBytes, _ := json.Marshal(ltToken)

	// Decode client's public key
	var clientPubKey [32]byte
	decoded, _ := base64Decode(req.PublicKey)
	copy(clientPubKey[:], decoded)

	encToken, err := agentKP.EncryptToken(tokenBytes, clientPubKey)
	if err != nil {
		log.Printf("[agent] encrypt token: %v", err)
		return
	}

	encTokenJSON, _ := json.Marshal(encToken)

	reply := map[string]interface{}{
		"type":    "pairing-accepted",
		"from":    peerID,
		"to":      req.From,
		"allowed": true,
		"token":   string(encTokenJSON),
	}
	replyBytes, _ := json.Marshal(reply)
	_ = p.SendSignal(string(replyBytes))

	log.Printf("[agent] ✅ Pairing accepted")
}

func base64Decode(s string) ([]byte, error) {
	return base64.URLEncoding.DecodeString(s)
}
