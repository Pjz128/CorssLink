// Pairing Client POC: Mobile app simulator.
// Demonstrates the client side of the pairing flow:
//   1. "Scans" QR code (receives QR URI as argument)
//   2. Generates its own ephemeral keypair
//   3. Connects to signal server, sends pairing request to agent
//   4. Waits for agent's response
//   5. Decrypts long-term token via NaCl box
//   6. Stores token for future connections
package main

import (
	"encoding/json"
	"log"
	"os"
	"os/signal"

	"crosslink-poc/pairing"
	"crosslink-poc/peer"
)

const (
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.Printf("=== CrossLink POC: Pairing Client (Mobile Simulator) ===\n")

	// Parse QR URI from command line or use default
	qrURI := "crosslink://pair?%7B%22v%22%3A1%2C%22pk%22%3A%22default%22%2C%22srv%22%3A%22ws%3A%2F%2Flocalhost%3A18080%2Fws%22%2C%22pid%22%3A%22agent-home-pc%22%7D"
	if len(os.Args) > 1 {
		qrURI = os.Args[1]
	}

	// Step 1: Decode QR code
	qr, err := pairing.DecodeQR(qrURI)
	if err != nil {
		log.Fatalf("decode QR: %v", err)
	}
	log.Printf("[client] QR decoded: agent=%s server=%s", qr.PeerID, qr.ServerURL)

	// Step 2: Generate our own ephemeral keypair
	clientKP, err := pairing.GenerateKeyPair()
	if err != nil {
		log.Fatalf("generate keypair: %v", err)
	}
	clientID := "mobile-001"
	log.Printf("[client] ephemeral keypair generated, clientID=%s", clientID)

	// Step 3: Connect to signal server
	pairingDone := make(chan struct{})
	var longTermToken *pairing.LongTermToken

	p, err := peer.New(peer.Config{
		PeerID:     clientID,
		SignalAddr: qr.ServerURL,
		OnSignalMessage: func(msg string) {
			var sigMsg struct {
				Type    string `json:"type"`
				From    string `json:"from"`
				To      string `json:"to"`
				Allowed bool   `json:"allowed"`
				Token   string `json:"token"`
			}
			if err := json.Unmarshal([]byte(msg), &sigMsg); err == nil {
				switch sigMsg.Type {
				case "pairing-accepted":
					log.Printf("[client] ✅ Pairing accepted by agent!")
					handlePairingAccepted(clientKP, sigMsg.Token, pairingDone, &longTermToken)
					return
				case "pairing-rejected":
					log.Printf("[client] ❌ Pairing rejected by agent")
					close(pairingDone)
					return
				}
			}
			log.Printf("[client] <- message: %s", msg)
		},
	})
	if err != nil {
		log.Fatalf("create client peer: %v", err)
	}
	defer p.Close()

	log.Printf("[client] connected to signal server")

	// Step 4: Send pairing request
	req := map[string]interface{}{
		"type":       "pairing-request",
		"from":       clientID,
		"to":         qr.PeerID,
		"publicKey":  clientKP.PublicKeyBase64(),
		"deviceName": "iPhone 15 Pro (POC)",
	}
	reqBytes, _ := json.Marshal(req)
	if err := p.SendSignal(string(reqBytes)); err != nil {
		log.Fatalf("send pairing request: %v", err)
	}
	log.Printf("[client] 📤 Pairing request sent to %s", qr.PeerID)

	// Step 5: Wait for result
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)

	select {
	case <-sig:
		log.Printf("[client] interrupted")
		return
	case <-pairingDone:
		if longTermToken != nil {
			log.Printf("")
			log.Printf("┌─────────────────────────────────────────────────────┐")
			log.Printf("│  ✅ PAIRING SUCCESSFUL                             │")
			log.Printf("│                                                     │")
			log.Printf("│  Agent:   %s", longTermToken.AgentID)
			log.Printf("│  Device:  %s (%s)", longTermToken.DeviceID, longTermToken.DeviceName)
			log.Printf("│  Token:   %s...", longTermToken.Token[:20])
			log.Printf("│                                                     │")
			log.Printf("│  In production, this token is stored encrypted      │")
			log.Printf("│  and used for automatic reconnection.              │")
			log.Printf("└─────────────────────────────────────────────────────┘")
			log.Printf("")
		}
	}
}

func handlePairingAccepted(clientKP *pairing.KeyPair, tokenJSON string, done chan struct{}, out **pairing.LongTermToken) {
	defer close(done)

	// Parse the encrypted token
	var encToken pairing.EncryptedToken
	if err := json.Unmarshal([]byte(tokenJSON), &encToken); err != nil {
		log.Printf("[client] parse encrypted token: %v", err)
		return
	}

	// Decrypt with our secret key
	tokenBytes, err := clientKP.DecryptToken(&encToken)
	if err != nil {
		log.Printf("[client] ❌ decrypt token failed: %v", err)
		return
	}

	// Parse the long-term token
	var ltToken pairing.LongTermToken
	if err := json.Unmarshal(tokenBytes, &ltToken); err != nil {
		log.Printf("[client] parse long-term token: %v", err)
		return
	}

	log.Printf("[client] 🔓 Token decrypted successfully")
	*out = &ltToken

	// In production: store encrypted to device keychain
	// encoded, _ := pairing.EncodeToken(&ltToken, &storageKey)
	// keychain.Save("crosslink-pairing", encoded)
}
