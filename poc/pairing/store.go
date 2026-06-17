package pairing

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/crypto/nacl/secretbox"
)

// Store manages persistent pairing state on disk.
// Paired devices and their long-term tokens are stored encrypted
// with a key derived from the machine's hardware fingerprint.
type Store struct {
	mu       sync.RWMutex
	path     string
	masterKey [32]byte // Derived from hardware fingerprint
}

// DeviceRecord represents a paired mobile device.
type DeviceRecord struct {
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	Token      string `json:"token"`       // Encrypted long-term token
	PublicKey  string `json:"publicKey"`    // Device's Curve25519 public key
	PairedAt   int64  `json:"pairedAt"`     // Unix timestamp
	LastSeen   int64  `json:"lastSeen"`     // Last successful connection
}

// StoreFile is the on-disk format of the pairing store.
type StoreFile struct {
	Version int            `json:"version"`
	Devices []DeviceRecord `json:"devices"`
}

// NewStore creates or opens a pairing store.
// masterKey should be derived from the hardware fingerprint (e.g., via PBKDF2).
func NewStore(dir string, masterKey [32]byte) (*Store, error) {
	path := filepath.Join(dir, "devices.json")
	s := &Store{path: path, masterKey: masterKey}

	// Create directory if needed
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("create store dir: %w", err)
	}

	// Initialize empty store file if it doesn't exist
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if err := s.save(&StoreFile{Version: 1}); err != nil {
			return nil, fmt.Errorf("init store: %w", err)
		}
	}

	return s, nil
}

// List returns all paired devices.
func (s *Store) List() ([]DeviceRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sf, err := s.load()
	if err != nil {
		return nil, err
	}
	return sf.Devices, nil
}

// Add adds a new paired device to the store.
func (s *Store) Add(device DeviceRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sf, err := s.load()
	if err != nil {
		return err
	}

	// Replace if already exists
	for i, d := range sf.Devices {
		if d.DeviceID == device.DeviceID {
			sf.Devices[i] = device
			return s.save(sf)
		}
	}

	sf.Devices = append(sf.Devices, device)
	return s.save(sf)
}

// Remove removes a paired device from the store.
func (s *Store) Remove(deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sf, err := s.load()
	if err != nil {
		return err
	}

	for i, d := range sf.Devices {
		if d.DeviceID == deviceID {
			sf.Devices = append(sf.Devices[:i], sf.Devices[i+1:]...)
			return s.save(sf)
		}
	}
	return fmt.Errorf("device not found: %s", deviceID)
}

// Find looks up a device by ID.
func (s *Store) Find(deviceID string) (*DeviceRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sf, err := s.load()
	if err != nil {
		return nil, err
	}
	for _, d := range sf.Devices {
		if d.DeviceID == deviceID {
			return &d, nil
		}
	}
	return nil, fmt.Errorf("device not found: %s", deviceID)
}

// UpdateLastSeen updates the last connection timestamp for a device.
func (s *Store) UpdateLastSeen(deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sf, err := s.load()
	if err != nil {
		return err
	}
	for i, d := range sf.Devices {
		if d.DeviceID == deviceID {
			sf.Devices[i].LastSeen = time.Now().Unix()
			return s.save(sf)
		}
	}
	return fmt.Errorf("device not found: %s", deviceID)
}

// load reads and decrypts the store file.
func (s *Store) load() (*StoreFile, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, fmt.Errorf("read store: %w", err)
	}

	plaintext, ok := decrypt(data, &s.masterKey)
	if !ok {
		return nil, fmt.Errorf("decrypt store: invalid key or corrupted data")
	}

	var sf StoreFile
	if err := json.Unmarshal(plaintext, &sf); err != nil {
		return nil, fmt.Errorf("unmarshal store: %w", err)
	}
	return &sf, nil
}

// save encrypts and writes the store file.
func (s *Store) save(sf *StoreFile) error {
	data, err := json.MarshalIndent(sf, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal store: %w", err)
	}

	encrypted := encrypt(data, &s.masterKey)
	return os.WriteFile(s.path, encrypted, 0600)
}

// encrypt encrypts plaintext with NaCl secretbox.
// Format: [nonce(24) | ciphertext]
func encrypt(plaintext []byte, key *[32]byte) []byte {
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		panic(fmt.Sprintf("crypto/rand failed: %v", err))
	}
	out := make([]byte, 24, 24+len(plaintext)+secretbox.Overhead)
	copy(out, nonce[:])
	return secretbox.Seal(out, plaintext, &nonce, key)
}

// decrypt decrypts ciphertext encrypted with encrypt().
func decrypt(ciphertext []byte, key *[32]byte) ([]byte, bool) {
	if len(ciphertext) < 24+secretbox.Overhead {
		return nil, false
	}
	var nonce [24]byte
	copy(nonce[:], ciphertext[:24])
	return secretbox.Open(nil, ciphertext[24:], &nonce, key)
}

// EncodeToken encrypts a LongTermToken with the master key for storage.
func EncodeToken(token *LongTermToken, key *[32]byte) (string, error) {
	data, err := json.Marshal(token)
	if err != nil {
		return "", err
	}
	encrypted := encrypt(data, key)
	return base64.URLEncoding.EncodeToString(encrypted), nil
}

// DecodeToken decrypts a stored token.
func DecodeToken(encoded string, key *[32]byte) (*LongTermToken, error) {
	data, err := base64.URLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("decode token: %w", err)
	}
	plaintext, ok := decrypt(data, key)
	if !ok {
		return nil, fmt.Errorf("decrypt token: invalid key")
	}
	var token LongTermToken
	if err := json.Unmarshal(plaintext, &token); err != nil {
		return nil, fmt.Errorf("unmarshal token: %w", err)
	}
	return &token, nil
}
