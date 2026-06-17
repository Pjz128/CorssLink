package pairing

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateKeyPair(t *testing.T) {
	kp, err := GenerateKeyPair()
	if err != nil {
		t.Fatalf("GenerateKeyPair failed: %v", err)
	}

	// Verify public key is non-zero
	var zero [32]byte
	if kp.PublicKey == zero {
		t.Error("public key is all zeros")
	}
	if kp.SecretKey == zero {
		t.Error("secret key is all zeros")
	}

	// Verify encoding round-trip
	encoded := kp.PublicKeyBase64()
	decoded, err := base64.URLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode public key: %v", err)
	}
	if len(decoded) != 32 {
		t.Errorf("decoded key length = %d, want 32", len(decoded))
	}

	// Verify uniqueness
	kp2, _ := GenerateKeyPair()
	if kp.PublicKeyBase64() == kp2.PublicKeyBase64() {
		t.Error("two generated keys are identical (astronomically unlikely)")
	}
}

func TestQRCodeRoundTrip(t *testing.T) {
	payload := QRPayload{
		Version:   1,
		PublicKey: "test-public-key-base64",
		ServerURL: "ws://localhost:18080/ws",
		PeerID:    "agent-001",
	}

	uri := EncodeQR(payload)
	t.Logf("QR URI: %s", uri)

	decoded, err := DecodeQR(uri)
	if err != nil {
		t.Fatalf("DecodeQR failed: %v", err)
	}

	if decoded.Version != payload.Version {
		t.Errorf("version = %d, want %d", decoded.Version, payload.Version)
	}
	if decoded.PublicKey != payload.PublicKey {
		t.Errorf("public key = %s, want %s", decoded.PublicKey, payload.PublicKey)
	}
	if decoded.ServerURL != payload.ServerURL {
		t.Errorf("server URL = %s, want %s", decoded.ServerURL, payload.ServerURL)
	}
	if decoded.PeerID != payload.PeerID {
		t.Errorf("peer ID = %s, want %s", decoded.PeerID, payload.PeerID)
	}
}

func TestEncryptDecryptToken(t *testing.T) {
	// Agent generates keypair
	agent, _ := GenerateKeyPair()

	// Mobile generates keypair
	mobile, _ := GenerateKeyPair()

	// Agent encrypts a token for mobile
	token := []byte("this-is-a-256-bit-long-term-pairing-token!")
	encrypted, err := agent.EncryptToken(token, mobile.PublicKey)
	if err != nil {
		t.Fatalf("EncryptToken failed: %v", err)
	}

	// Verify encrypted token has all required fields
	if encrypted.SenderPublicKey == "" {
		t.Error("sender public key is empty")
	}
	if encrypted.Nonce == "" {
		t.Error("nonce is empty")
	}
	if encrypted.Ciphertext == "" {
		t.Error("ciphertext is empty")
	}

	// Verify ciphertext is different from plaintext
	if encrypted.Ciphertext == string(token) {
		t.Error("ciphertext equals plaintext")
	}

	// Mobile decrypts
	decrypted, err := mobile.DecryptToken(encrypted)
	if err != nil {
		t.Fatalf("DecryptToken failed: %v", err)
	}

	if string(decrypted) != string(token) {
		t.Errorf("decrypted = %q, want %q", string(decrypted), string(token))
	}

	// Verify wrong key cannot decrypt
	wrongKP, _ := GenerateKeyPair()
	_, err = wrongKP.DecryptToken(encrypted)
	if err == nil {
		t.Error("decryption with wrong key should fail")
	}
}

func TestGenerateLongTermToken(t *testing.T) {
	token, err := GenerateLongTermToken()
	if err != nil {
		t.Fatalf("GenerateLongTermToken failed: %v", err)
	}

	decoded, err := base64.URLEncoding.DecodeString(token.Token)
	if err != nil {
		t.Fatalf("token is not valid base64: %v", err)
	}
	if len(decoded) != 32 {
		t.Errorf("token length = %d bytes, want 32", len(decoded))
	}

	// Verify uniqueness
	token2, _ := GenerateLongTermToken()
	if token.Token == token2.Token {
		t.Error("two generated tokens are identical")
	}
}

func TestStore(t *testing.T) {
	dir := t.TempDir()

	// Create a master key (in production, derived from hardware fingerprint)
	var masterKey [32]byte
	copy(masterKey[:], []byte("test-master-key-32-bytes!!!!!!"))

	store, err := NewStore(dir, masterKey)
	if err != nil {
		t.Fatalf("NewStore failed: %v", err)
	}

	// Verify store file was created
	if _, err := os.Stat(filepath.Join(dir, "devices.json")); err != nil {
		t.Errorf("store file not created: %v", err)
	}

	// Add a device
	device := DeviceRecord{
		DeviceID:   "device-001",
		DeviceName: "iPhone 15 Pro",
		Token:      "encrypted-token-data",
		PublicKey:  "device-public-key",
		PairedAt:   1700000000,
	}
	if err := store.Add(device); err != nil {
		t.Fatalf("Add device failed: %v", err)
	}

	// List devices
	devices, err := store.List()
	if err != nil {
		t.Fatalf("List failed: %v", err)
	}
	if len(devices) != 1 {
		t.Fatalf("device count = %d, want 1", len(devices))
	}
	if devices[0].DeviceID != "device-001" {
		t.Errorf("device ID = %s, want device-001", devices[0].DeviceID)
	}

	// Find device
	found, err := store.Find("device-001")
	if err != nil {
		t.Fatalf("Find failed: %v", err)
	}
	if found.DeviceName != "iPhone 15 Pro" {
		t.Errorf("device name = %s, want iPhone 15 Pro", found.DeviceName)
	}

	// Update last seen
	if err := store.UpdateLastSeen("device-001"); err != nil {
		t.Fatalf("UpdateLastSeen failed: %v", err)
	}
	found, _ = store.Find("device-001")
	if found.LastSeen == 0 {
		t.Error("LastSeen not updated")
	}

	// Remove device
	if err := store.Remove("device-001"); err != nil {
		t.Fatalf("Remove failed: %v", err)
	}
	devices, _ = store.List()
	if len(devices) != 0 {
		t.Errorf("device count = %d, want 0 after remove", len(devices))
	}

	// Non-existent device
	_, err = store.Find("device-001")
	if err == nil {
		t.Error("Find should fail for removed device")
	}
}

func TestStorePersistence(t *testing.T) {
	dir := t.TempDir()
	var masterKey [32]byte
	copy(masterKey[:], []byte("test-master-key-32-bytes!!!!!!"))

	// Create store and add device
	store1, _ := NewStore(dir, masterKey)
	store1.Add(DeviceRecord{
		DeviceID:   "persist-001",
		DeviceName: "Test Phone",
		Token:      "some-token",
		PublicKey:  "some-key",
		PairedAt:   1700000000,
	})

	// Open new store from same file
	store2, err := NewStore(dir, masterKey)
	if err != nil {
		t.Fatalf("NewStore (2nd) failed: %v", err)
	}

	devices, _ := store2.List()
	if len(devices) != 1 {
		t.Fatalf("persisted device count = %d, want 1", len(devices))
	}
	if devices[0].DeviceID != "persist-001" {
		t.Errorf("persisted device ID = %s, want persist-001", devices[0].DeviceID)
	}
}

func TestStoreWrongKey(t *testing.T) {
	dir := t.TempDir()
	var key1, key2 [32]byte
	copy(key1[:], []byte("test-master-key-32-bytes!!!!!!"))
	copy(key2[:], []byte("wrong-master-key-32-bytes!!!!!"))

	store1, _ := NewStore(dir, key1)
	store1.Add(DeviceRecord{DeviceID: "d1", DeviceName: "Phone", PairedAt: 1700000000})

	// Try to open with wrong key — should fail because can't decrypt
	store2, err := NewStore(dir, key2)
	if err == nil {
		// Even if NewStore doesn't error (it inits empty), List should
		// either fail or return empty because decryption failed.
		// Let's check: if store was initialized as empty with wrong key,
		// listing should return empty or error.
		devices, listErr := store2.List()
		if listErr == nil && len(devices) > 0 {
			t.Error("Store opened with wrong key should not return devices")
		}
	}
}

func TestEncodeDecodeToken(t *testing.T) {
	var masterKey [32]byte
	copy(masterKey[:], []byte("test-master-key-32-bytes!!!!!!"))

	original := &LongTermToken{
		Token:      "base64-encoded-random-token-data",
		AgentID:    "agent-001",
		DeviceID:   "device-001",
		DeviceName: "My Phone",
		CreatedAt:  1700000000,
	}

	encoded, err := EncodeToken(original, &masterKey)
	if err != nil {
		t.Fatalf("EncodeToken failed: %v", err)
	}

	decoded, err := DecodeToken(encoded, &masterKey)
	if err != nil {
		t.Fatalf("DecodeToken failed: %v", err)
	}

	if decoded.Token != original.Token {
		t.Errorf("token mismatch")
	}
	if decoded.AgentID != original.AgentID {
		t.Errorf("agent ID mismatch")
	}
	if decoded.DeviceName != original.DeviceName {
		t.Errorf("device name mismatch")
	}

	// Wrong key should fail
	var wrongKey [32]byte
	copy(wrongKey[:], []byte("wrong-master-key-32-bytes!!!!!"))
	_, err = DecodeToken(encoded, &wrongKey)
	if err == nil {
		t.Error("DecodeToken with wrong key should fail")
	}
}
