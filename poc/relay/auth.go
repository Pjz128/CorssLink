// auth.go — lightweight user auth, session management, and device ownership for CrossLink relay.
// Uses JSON files for persistence and in-memory sessions for minimal resource footprint.
// No new dependencies; bcrypt comes from golang.org/x/crypto (already in go.sum).

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// ---- Context key for session injection ----

type ctxKey string

const ctxSession ctxKey = "session"

// ---- Session ----

type session struct {
	SessionID string
	Username  string
	IsAdmin   bool
	CreatedAt time.Time
	ExpiresAt time.Time
}

// ---- SessionManager (in-memory only) ----

type sessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*session
	stopCh   chan struct{}
}

func newSessionManager() *sessionManager {
	sm := &sessionManager{
		sessions: make(map[string]*session),
		stopCh:   make(chan struct{}),
	}
	go sm.cleanupLoop()
	return sm
}

func (sm *sessionManager) create(username string, isAdmin bool) *session {
	id := randomHex(32)
	s := &session{
		SessionID: id,
		Username:  username,
		IsAdmin:   isAdmin,
		CreatedAt: time.Now(),
		ExpiresAt: time.Now().Add(24 * time.Hour),
	}
	sm.mu.Lock()
	sm.sessions[id] = s
	sm.mu.Unlock()
	return s
}

func (sm *sessionManager) validate(id string) (*session, bool) {
	sm.mu.RLock()
	s, ok := sm.sessions[id]
	sm.mu.RUnlock()
	if !ok {
		return nil, false
	}
	if time.Now().After(s.ExpiresAt) {
		sm.mu.Lock()
		delete(sm.sessions, id)
		sm.mu.Unlock()
		return nil, false
	}
	return s, true
}

func (sm *sessionManager) destroy(id string) {
	sm.mu.Lock()
	delete(sm.sessions, id)
	sm.mu.Unlock()
}

func (sm *sessionManager) cleanupLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			now := time.Now()
			sm.mu.Lock()
			for id, s := range sm.sessions {
				if now.After(s.ExpiresAt) {
					delete(sm.sessions, id)
				}
			}
			sm.mu.Unlock()
		case <-sm.stopCh:
			return
		}
	}
}

// ---- User persistence ----

type user struct {
	Username     string `json:"username"`
	PasswordHash string `json:"passwordHash"`
	IsAdmin      bool   `json:"isAdmin"`
	CreatedAt    string `json:"createdAt"`
	CreatedBy    string `json:"createdBy"`
}

type userRecord struct {
	Version int    `json:"version"`
	Users   []user `json:"users"`
}

type userStore struct {
	mu       sync.RWMutex
	filePath string
	records  *userRecord
}

func newUserStore(filePath string) (*userStore, error) {
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir %s: %w", dir, err)
	}
	us := &userStore{filePath: filePath}
	rec, err := us.load()
	if err != nil {
		return nil, err
	}
	us.records = rec
	return us, nil
}

func (us *userStore) initAdmin(password string) error {
	us.mu.Lock()
	defer us.mu.Unlock()

	if len(us.records.Users) > 0 {
		return nil // already initialized
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
	if err != nil {
		return fmt.Errorf("hash admin password: %w", err)
	}

	us.records.Users = append(us.records.Users, user{
		Username:     "admin",
		PasswordHash: string(hash),
		IsAdmin:      true,
		CreatedAt:    time.Now().UTC().Format(time.RFC3339),
		CreatedBy:    "system",
	})
	log.Printf("[auth] admin user created")
	return us.save()
}

func (us *userStore) authenticate(username, password string) (*user, error) {
	us.mu.RLock()
	defer us.mu.RUnlock()

	for i := range us.records.Users {
		u := &us.records.Users[i]
		if u.Username == username {
			if err := bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)); err != nil {
				return nil, fmt.Errorf("wrong password")
			}
			return &user{Username: u.Username, IsAdmin: u.IsAdmin}, nil
		}
	}
	return nil, fmt.Errorf("user not found")
}

func (us *userStore) createUser(username, password string, isAdmin bool, createdBy string) error {
	us.mu.Lock()
	defer us.mu.Unlock()

	for _, u := range us.records.Users {
		if u.Username == username {
			return fmt.Errorf("user %q already exists", username)
		}
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(password), 12)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	us.records.Users = append(us.records.Users, user{
		Username:     username,
		PasswordHash: string(hash),
		IsAdmin:      isAdmin,
		CreatedAt:    time.Now().UTC().Format(time.RFC3339),
		CreatedBy:    createdBy,
	})
	log.Printf("[auth] user %q created by %q (admin=%v)", username, createdBy, isAdmin)
	return us.save()
}

func (us *userStore) listUsers() []map[string]any {
	us.mu.RLock()
	defer us.mu.RUnlock()

	result := make([]map[string]any, len(us.records.Users))
	for i, u := range us.records.Users {
		result[i] = map[string]any{
			"username":  u.Username,
			"isAdmin":   u.IsAdmin,
			"createdAt": u.CreatedAt,
			"createdBy": u.CreatedBy,
		}
	}
	return result
}

func (us *userStore) deleteUser(username string) error {
	us.mu.Lock()
	defer us.mu.Unlock()

	for i, u := range us.records.Users {
		if u.Username == username {
			us.records.Users = append(us.records.Users[:i], us.records.Users[i+1:]...)
			log.Printf("[auth] user %q deleted", username)
			return us.save()
		}
	}
	return fmt.Errorf("user %q not found", username)
}

func (us *userStore) load() (*userRecord, error) {
	data, err := os.ReadFile(us.filePath)
	if os.IsNotExist(err) {
		return &userRecord{Version: 1}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read users file: %w", err)
	}
	var rec userRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("parse users file: %w", err)
	}
	if rec.Users == nil {
		rec.Users = []user{}
	}
	return &rec, nil
}

func (us *userStore) save() error {
	data, err := json.MarshalIndent(us.records, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal users: %w", err)
	}
	tmpPath := us.filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0600); err != nil {
		return fmt.Errorf("write users tmp: %w", err)
	}
	return os.Rename(tmpPath, us.filePath)
}

// ---- Ownership persistence ----

type ownershipRecord struct {
	Version          int               `json:"version"`
	AgentOwnership   map[string]string `json:"agentOwnership"`
	SessionOwnership map[string]string `json:"sessionOwnership"`
	DeployTokens     map[string]string `json:"deployTokens"`    // deployToken → username (one-time use)
	AgentVisibility  map[string]string `json:"agentVisibility"` // peerID → "public"|"private"
}

type ownershipManager struct {
	mu       sync.RWMutex
	filePath string
	records  *ownershipRecord
}

func newOwnershipManager(filePath string) (*ownershipManager, error) {
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir %s: %w", dir, err)
	}
	om := &ownershipManager{filePath: filePath}
	rec, err := om.load()
	if err != nil {
		return nil, err
	}
	om.records = rec
	return om, nil
}

func (om *ownershipManager) claimAgent(peerID, username string) error {
	om.mu.Lock()
	defer om.mu.Unlock()

	if current, ok := om.records.AgentOwnership[peerID]; ok && current != username {
		return fmt.Errorf("agent already claimed by %q", current)
	}
	if om.records.AgentOwnership[peerID] == username {
		return nil // idempotent
	}
	om.records.AgentOwnership[peerID] = username
	log.Printf("[ownership] agent %s claimed by %s", peerID, username)
	return om.save()
}

func (om *ownershipManager) unclaimAgent(peerID, username string, isAdmin bool) error {
	om.mu.Lock()
	defer om.mu.Unlock()

	current, ok := om.records.AgentOwnership[peerID]
	if !ok {
		return fmt.Errorf("agent not claimed")
	}
	if !isAdmin && current != username {
		return fmt.Errorf("not your agent")
	}
	delete(om.records.AgentOwnership, peerID)
	log.Printf("[ownership] agent %s unclaimed by %s", peerID, username)
	return om.save()
}

func (om *ownershipManager) getAgentOwner(peerID string) (string, bool) {
	om.mu.RLock()
	defer om.mu.RUnlock()
	owner, ok := om.records.AgentOwnership[peerID]
	return owner, ok
}

// ---- Agent visibility ----

func (om *ownershipManager) setAgentVisibility(peerID, visibility string) error {
	om.mu.Lock()
	defer om.mu.Unlock()
	if visibility != "public" && visibility != "private" {
		return fmt.Errorf("visibility must be 'public' or 'private', got %q", visibility)
	}
	om.records.AgentVisibility[peerID] = visibility
	log.Printf("[ownership] agent %s visibility set to %s", peerID, visibility)
	return om.save()
}

func (om *ownershipManager) getAgentVisibility(peerID string) string {
	om.mu.RLock()
	defer om.mu.RUnlock()
	v, ok := om.records.AgentVisibility[peerID]
	if !ok {
		return "private" // default: private
	}
	return v
}

// ---- Session ownership ----

func (om *ownershipManager) recordSession(sessionToken, username string) error {
	om.mu.Lock()
	defer om.mu.Unlock()
	om.records.SessionOwnership[sessionToken] = username
	return om.save()
}

func (om *ownershipManager) getSessionOwner(sessionToken string) (string, bool) {
	om.mu.RLock()
	defer om.mu.RUnlock()
	owner, ok := om.records.SessionOwnership[sessionToken]
	return owner, ok
}

func (om *ownershipManager) listSessionsForUser(username string) []string {
	om.mu.RLock()
	defer om.mu.RUnlock()
	var result []string
	for token, owner := range om.records.SessionOwnership {
		if owner == username {
			result = append(result, token)
		}
	}
	return result
}

func (om *ownershipManager) load() (*ownershipRecord, error) {
	data, err := os.ReadFile(om.filePath)
	if os.IsNotExist(err) {
		return &ownershipRecord{
			Version:          2,
			AgentOwnership:   make(map[string]string),
			SessionOwnership: make(map[string]string),
			DeployTokens:     make(map[string]string),
			AgentVisibility:  make(map[string]string),
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read ownership file: %w", err)
	}
	var rec ownershipRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("parse ownership file: %w", err)
	}
	if rec.AgentOwnership == nil {
		rec.AgentOwnership = make(map[string]string)
	}
	if rec.SessionOwnership == nil {
		rec.SessionOwnership = make(map[string]string)
	}
	if rec.DeployTokens == nil {
		rec.DeployTokens = make(map[string]string)
	}
	if rec.AgentVisibility == nil {
		rec.AgentVisibility = make(map[string]string)
	}
	return &rec, nil
}

// CreateDeployToken generates a one-time deploy token for a user.
func (om *ownershipManager) createDeployToken(username string) string {
	om.mu.Lock()
	defer om.mu.Unlock()
	token := randomHex(32)
	om.records.DeployTokens[token] = username
	om.save()
	log.Printf("[deploy] token created for %s: %s...", username, token[:16])
	return token
}

// ClaimByDeployToken attempts to claim an agent using a deploy token.
// Returns (username, true) on success, ("", false) if token invalid/expired.
func (om *ownershipManager) claimByDeployToken(deployToken, peerID string) (string, bool) {
	om.mu.Lock()
	defer om.mu.Unlock()

	username, ok := om.records.DeployTokens[deployToken]
	if !ok {
		return "", false
	}
	// One-time use: delete token after consumption
	delete(om.records.DeployTokens, deployToken)

	// Auto-claim the agent to this user
	om.records.AgentOwnership[peerID] = username
	om.save()
	log.Printf("[deploy] agent %s auto-claimed by %s (token consumed)", peerID, username)
	return username, true
}

func (om *ownershipManager) save() error {
	data, err := json.MarshalIndent(om.records, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal ownership: %w", err)
	}
	tmpPath := om.filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0600); err != nil {
		return fmt.Errorf("write ownership tmp: %w", err)
	}
	return os.Rename(tmpPath, om.filePath)
}

// ---- Auth middleware ----

type authMiddleware struct {
	SessionMgr *sessionManager
}

func newAuthMiddleware(sm *sessionManager) *authMiddleware {
	return &authMiddleware{SessionMgr: sm}
}

func (am *authMiddleware) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil {
			jsonError(w, http.StatusUnauthorized, "login required")
			return
		}
		s, ok := am.SessionMgr.validate(cookie.Value)
		if !ok {
			clearSessionCookie(w)
			jsonError(w, http.StatusUnauthorized, "session expired")
			return
		}
		ctx := context.WithValue(r.Context(), ctxSession, s)
		next(w, r.WithContext(ctx))
	}
}

func (am *authMiddleware) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return am.requireAuth(func(w http.ResponseWriter, r *http.Request) {
		s := getSession(r)
		if s == nil || !s.IsAdmin {
			jsonError(w, http.StatusForbidden, "admin required")
			return
		}
		next(w, r)
	})
}

// ---- Cookie helpers ----

func setSessionCookie(w http.ResponseWriter, sessionID string) {
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    sessionID,
		Path:     "/",
		MaxAge:   86400, // 24h
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
	})
}

// ---- Helper ----

func getSession(r *http.Request) *session {
	s, _ := r.Context().Value(ctxSession).(*session)
	return s
}

func newJSONEncoder(w http.ResponseWriter) *json.Encoder {
	w.Header().Set("Content-Type", "application/json")
	return json.NewEncoder(w)
}

func isAdminUser(s *session) bool { return s != nil && s.IsAdmin }
