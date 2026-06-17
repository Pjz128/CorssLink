// Package pairing implements QR code device pairing for CrossLink.
//
// Protocol overview (inspired by Happy Coder's auth flow):
//
//	Agent (desktop)          Signal Server            Mobile App
//	   │                         │                       │
//	   │ 1. Generate NaCl keypair                       │
//	   │ 2. Display QR(public key + signal addr)        │
//	   │                         │       3. Scan QR ───→│
//	   │                         │ 4. POST pairing req →│
//	   │ ←─ 5. Forward request ──│                       │
//	   │ 6. Show "Allow pairing?" │                       │
//	   │ 7. Encrypt token ──────→│──→ 8. Deliver ──────→│
//	   │                         │                       │
//	   │ ←══════ 9. WebRTC DataChannel (P2P) ═════════→│
//
// The QR code contains only the agent's ephemeral public key and signal
// server address. No secrets are ever in the QR code. The long-term
// pairing token is delivered encrypted via NaCl box through the signal
// server (which cannot decrypt it).
package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"

	"golang.org/x/crypto/nacl/box"
)

// KeyPair is an ephemeral Curve25519 keypair used for pairing handshake.
type KeyPair struct {
	PublicKey [32]byte
	SecretKey [32]byte
}

// GenerateKeyPair creates a new random Curve25519 keypair.
func GenerateKeyPair() (*KeyPair, error) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate keypair: %w", err)
	}
	return &KeyPair{
		PublicKey: *pub,
		SecretKey: *priv,
	}, nil
}

// PublicKeyBase64 returns the base64-encoded public key.
func (kp *KeyPair) PublicKeyBase64() string {
	return base64.URLEncoding.EncodeToString(kp.PublicKey[:])
}

// QRPayload is the data encoded in the pairing QR code.
type QRPayload struct {
	Version   int    `json:"v"`        // Protocol version
	PublicKey string `json:"pk"`       // Agent's ephemeral public key (base64)
	ServerURL string `json:"srv"`      // Signal server WebSocket URL
	PeerID    string `json:"pid"`      // Agent's peer ID (for display)
}

// EncodeQR generates the QR code content as a crosslink:// deep link URL.
func EncodeQR(payload QRPayload) string {
	data, _ := json.Marshal(payload)
	return "crosslink://pair?" + url.QueryEscape(string(data))
}

// DecodeQR parses a crosslink://pair? URI back into a QRPayload.
func DecodeQR(uri string) (*QRPayload, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("parse URI: %w", err)
	}
	if u.Scheme != "crosslink" || u.Host != "pair" {
		return nil, fmt.Errorf("not a crosslink pairing URI: %s", uri)
	}
	// The raw query is the URL-escaped JSON payload
	raw, err := url.QueryUnescape(u.RawQuery)
	if err != nil {
		return nil, fmt.Errorf("unescape query: %w", err)
	}
	var p QRPayload
	if err := json.Unmarshal([]byte(raw), &p); err != nil {
		return nil, fmt.Errorf("decode payload: %w", err)
	}
	if p.Version != 1 {
		return nil, fmt.Errorf("unsupported protocol version: %d", p.Version)
	}
	return &p, nil
}

// PairingMessage types for signal server relay.
const (
	MsgTypePairingRequest  = "pairing-request"
	MsgTypePairingAccepted = "pairing-accepted"
	MsgTypePairingRejected = "pairing-rejected"
	MsgTypePairingToken    = "pairing-token"
)

// PairingRequest is sent from mobile app to agent via signal server.
type PairingRequest struct {
	Type      string `json:"type"`                // MsgTypePairingRequest
	From      string `json:"from"`                // Mobile peer ID
	To        string `json:"to"`                  // Agent peer ID
	PublicKey string `json:"publicKey"`           // Mobile's ephemeral public key (base64)
	DeviceName string `json:"deviceName"`         // Human-readable device name
}

// PairingResponse is sent from agent to mobile app.
type PairingResponse struct {
	Type    string `json:"type"`                   // MsgTypePairingAccepted or MsgTypePairingRejected
	From    string `json:"from"`                   // Agent peer ID
	To      string `json:"to"`                     // Mobile peer ID
	Allowed bool   `json:"allowed"`                // Whether user approved
	Token   string `json:"token,omitempty"`        // Encrypted long-term token (if allowed)
}

// EncryptedToken contains the long-term pairing token encrypted with NaCl box.
type EncryptedToken struct {
	SenderPublicKey string `json:"spk"` // Ephemeral sender public key (base64)
	Nonce           string `json:"n"`   // Nonce (base64)
	Ciphertext      string `json:"c"`   // Encrypted payload (base64)
}

// EncryptToken encrypts a long-term token for delivery to a specific recipient.
func (kp *KeyPair) EncryptToken(token []byte, recipientPubKey [32]byte) (*EncryptedToken, error) {
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, fmt.Errorf("generate nonce: %w", err)
	}

	encrypted := box.Seal(nil, token, &nonce, &recipientPubKey, &kp.SecretKey)

	return &EncryptedToken{
		SenderPublicKey: base64.URLEncoding.EncodeToString(kp.PublicKey[:]),
		Nonce:           base64.URLEncoding.EncodeToString(nonce[:]),
		Ciphertext:      base64.URLEncoding.EncodeToString(encrypted),
	}, nil
}

// DecryptToken decrypts a token received from a sender.
func (kp *KeyPair) DecryptToken(et *EncryptedToken) ([]byte, error) {
	senderPubKey, err := base64.URLEncoding.DecodeString(et.SenderPublicKey)
	if err != nil {
		return nil, fmt.Errorf("decode sender public key: %w", err)
	}
	nonce, err := base64.URLEncoding.DecodeString(et.Nonce)
	if err != nil {
		return nil, fmt.Errorf("decode nonce: %w", err)
	}
	ciphertext, err := base64.URLEncoding.DecodeString(et.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("decode ciphertext: %w", err)
	}

	var pk [32]byte
	var n [24]byte
	copy(pk[:], senderPubKey)
	copy(n[:], nonce)

	decrypted, ok := box.Open(nil, ciphertext, &n, &pk, &kp.SecretKey)
	if !ok {
		return nil, fmt.Errorf("decryption failed: invalid key or corrupted data")
	}
	return decrypted, nil
}

// LongTermToken is the persistent credential established after pairing.
// It is stored encrypted on disk and used for future reconnection.
type LongTermToken struct {
	Token     string `json:"token"`     // Random 256-bit token (base64)
	AgentID   string `json:"agentId"`   // Agent peer ID
	DeviceID  string `json:"deviceId"`  // Mobile device ID
	DeviceName string `json:"deviceName"` // Human-readable name
	CreatedAt int64  `json:"createdAt"` // Unix timestamp
}

// GenerateLongTermToken creates a new random token for persistent pairing.
func GenerateLongTermToken() (*LongTermToken, error) {
	token := make([]byte, 32) // 256 bits
	if _, err := rand.Read(token); err != nil {
		return nil, fmt.Errorf("generate token: %w", err)
	}
	return &LongTermToken{
		Token: base64.URLEncoding.EncodeToString(token),
	}, nil
}
