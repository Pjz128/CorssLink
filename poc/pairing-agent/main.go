// Pairing Agent POC: Home PC with QR code pairing.
package main

import (
	"encoding/base64"
	"encoding/json"
	"log"
	"os"
	"os/signal"
	"time"

	"crosslink-poc/pairing"
	"crosslink-poc/peer"
)

const (
	signalAddr = "ws://192.168.1.116:18080"
	peerID     = "agent-home-pc"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink POC: Pairing Agent ===\n")

	// Step 1: Generate ephemeral keypair for pairing handshake
	agentKP, err := pairing.GenerateKeyPair()
	if err != nil {
		log.Fatalf("generate keypair: %v", err)
	}
	log.Printf("[agent] ephemeral keypair generated")

	// Step 2: Build QR code payload
	qrPayload := pairing.QRPayload{
		Version:   1,
		PublicKey: agentKP.PublicKeyBase64(),
		ServerURL: "ws://192.168.1.116:18080",
		PeerID:    peerID,
	}
	qrURI := pairing.EncodeQR(qrPayload)

	log.Printf("")
	log.Printf("┌─────────────────────────────────────────────────────┐")
	log.Printf("│  📱 Scan this QR code with CrossLink App:          │")
	log.Printf("│                                                     │")
	log.Printf("│  QR URI: %s", qrURI)
	log.Printf("│                                                     │")
	log.Printf("│  (In production, this would be a real QR image)     │")
	log.Printf("└─────────────────────────────────────────────────────┘")
	log.Printf("")

	// Step 3: Connect to signal server
	pairingDone := make(chan struct{})

	var p *peer.Peer
	p, err = peer.New(peer.Config{
		PeerID:     peerID,
		SignalAddr: signalAddr,
		OnSignalMessage: func(raw string) {
			var msg pairingMsg
			if err := json.Unmarshal([]byte(raw), &msg); err != nil {
				return
			}
			if msg.Type == "pairing-request" {
				log.Printf("[agent] 📱 Pairing request from %s (%s)", msg.From, msg.DeviceName)
				handlePairingRequest(p, agentKP, msg, pairingDone)
			}
		},
	})
	if err != nil {
		log.Fatalf("create agent peer: %v", err)
	}
	defer p.Close()

	log.Printf("[agent] connected to signal server, waiting for pairing requests...")

	// Step 4: Wait for pairing completion or Ctrl+C
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sig:
			log.Printf("[agent] shutting down...")
			return
		case <-pairingDone:
			log.Printf("[agent] ✅ Pairing complete!")
			select {
			case <-sig:
				log.Printf("[agent] shutting down...")
				return
			}
		case <-ticker.C:
			log.Printf("[agent] waiting for pairing request...")
		}
	}
}

type pairingMsg struct {
	Type       string `json:"type"`
	From       string `json:"from"`
	To         string `json:"to"`
	PublicKey  string `json:"publicKey"`
	DeviceName string `json:"deviceName"`
}

func handlePairingRequest(p *peer.Peer, agentKP *pairing.KeyPair, req pairingMsg, done chan struct{}) {
	// In production: show GUI dialog asking "Allow 'iPhone 15 Pro' to connect?"
	// For POC: auto-accept after a short delay
	log.Printf("[agent] Auto-accepting pairing from %s...", req.DeviceName)
	time.Sleep(500 * time.Millisecond)

	// Generate long-term token
	ltToken, err := pairing.GenerateLongTermToken()
	if err != nil {
		log.Printf("[agent] generate token error: %v", err)
		return
	}
	ltToken.AgentID = peerID
	ltToken.DeviceID = req.From
	ltToken.DeviceName = req.DeviceName
	ltToken.CreatedAt = time.Now().Unix()

	// Marshal the token to JSON
	tokenBytes, err := json.Marshal(ltToken)
	if err != nil {
		log.Printf("[agent] marshal token error: %v", err)
		return
	}

	// Decode client's public key
	clientPubKeyBytes, err := base64.URLEncoding.DecodeString(req.PublicKey)
	if err != nil {
		log.Printf("[agent] decode client public key error: %v", err)
		return
	}
	var clientPubKey [32]byte
	copy(clientPubKey[:], clientPubKeyBytes)

	// Encrypt token with NaCl box
	encToken, err := agentKP.EncryptToken(tokenBytes, clientPubKey)
	if err != nil {
		log.Printf("[agent] encrypt token error: %v", err)
		return
	}

	// Serialize the encrypted token
	encTokenJSON, _ := json.Marshal(encToken)

	// Send pairing-accepted with encrypted token
	reply := map[string]interface{}{
		"type":    "pairing-accepted",
		"from":    peerID,
		"to":      req.From,
		"allowed": true,
		"token":   string(encTokenJSON),
	}
	replyBytes, _ := json.Marshal(reply)
	if err := p.SendSignal(string(replyBytes)); err != nil {
		log.Printf("[agent] send pairing response error: %v", err)
		return
	}

	log.Printf("[agent] ✅ Pairing accepted! Encrypted token sent to %s", req.DeviceName)
	log.Printf("[agent] Token: %s...", ltToken.Token[:20])
	close(done)
}
