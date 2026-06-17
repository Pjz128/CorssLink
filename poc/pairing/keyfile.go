package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"

	"golang.org/x/crypto/nacl/secretbox"
)

// keyFileData is the on-disk JSON format stored inside a secretbox.
type keyFileData struct {
	PublicKey string `json:"publicKey"` // base64 of [32]byte
	SecretKey string `json:"secretKey"` // base64 of [32]byte
}

// SaveKeyPair encrypts a KeyPair with secretbox and writes it to path.
func SaveKeyPair(kp *KeyPair, path string, masterKey *[32]byte) error {
	data := keyFileData{
		PublicKey: base64.RawURLEncoding.EncodeToString(kp.PublicKey[:]),
		SecretKey: base64.RawURLEncoding.EncodeToString(kp.SecretKey[:]),
	}
	plaintext, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("marshal keypair: %w", err)
	}

	encrypted := encryptBytes(plaintext, masterKey)
	return os.WriteFile(path, encrypted, 0600)
}

// LoadKeyPair reads and decrypts a KeyPair from path.
// Returns nil and an error if the file is missing, corrupted, or
// encrypted with a different key.
func LoadKeyPair(path string, masterKey *[32]byte) (*KeyPair, error) {
	ciphertext, err := os.ReadFile(path)
	if err != nil {
		return nil, err // os.IsNotExist handled by caller
	}

	plaintext, ok := decryptBytes(ciphertext, masterKey)
	if !ok {
		return nil, fmt.Errorf("decrypt keypair: invalid key or corrupted data")
	}

	var data keyFileData
	if err := json.Unmarshal(plaintext, &data); err != nil {
		return nil, fmt.Errorf("unmarshal keypair: %w", err)
	}

	pub, err := base64.RawURLEncoding.DecodeString(data.PublicKey)
	if err != nil || len(pub) != 32 {
		return nil, fmt.Errorf("invalid public key in keyfile")
	}
	priv, err := base64.RawURLEncoding.DecodeString(data.SecretKey)
	if err != nil || len(priv) != 32 {
		return nil, fmt.Errorf("invalid secret key in keyfile")
	}

	kp := &KeyPair{}
	copy(kp.PublicKey[:], pub)
	copy(kp.SecretKey[:], priv)
	return kp, nil
}

// encryptBytes encrypts plaintext with NaCl secretbox (same format as store.go).
func encryptBytes(plaintext []byte, key *[32]byte) []byte {
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		panic(fmt.Sprintf("crypto/rand failed: %v", err))
	}
	out := make([]byte, 24, 24+len(plaintext)+secretbox.Overhead)
	copy(out, nonce[:])
	return secretbox.Seal(out, plaintext, &nonce, key)
}

// decryptBytes decrypts ciphertext encrypted with encryptBytes.
func decryptBytes(ciphertext []byte, key *[32]byte) ([]byte, bool) {
	if len(ciphertext) < 24+secretbox.Overhead {
		return nil, false
	}
	var nonce [24]byte
	copy(nonce[:], ciphertext[:24])
	return secretbox.Open(nil, ciphertext[24:], &nonce, key)
}
