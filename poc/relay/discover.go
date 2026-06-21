// discover.go — Agent discovery, connection requests, and visibility management.
// Mobile users can browse online public agents and request to connect.
// Agent owners approve/reject requests via Dashboard.

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ---- Connection request persistence ----

type connectionRequest struct {
	ID         string `json:"id"`
	FromDevice string `json:"fromDevice"` // requester device name
	FromOwner  string `json:"fromOwner"`  // requester session owner (may be empty for anonymous)
	ToPeerID   string `json:"toPeerID"`
	ToOwner    string `json:"toOwner"`
	Status     string `json:"status"` // "pending" | "approved" | "rejected"
	CreatedAt  string `json:"createdAt"`
	ResolvedAt string `json:"resolvedAt,omitempty"`
	PairToken  string `json:"pairToken,omitempty"` // set when approved
}

type connectionRequestRecord struct {
	Version  int                          `json:"version"`
	Requests map[string]*connectionRequest `json:"requests"`
}

type connectionRequestStore struct {
	mu       sync.RWMutex
	filePath string
	records  *connectionRequestRecord
}

func newConnectionRequestStore(filePath string) (*connectionRequestStore, error) {
	dir := filepath.Dir(filePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, fmt.Errorf("create data dir %s: %w", dir, err)
	}
	cs := &connectionRequestStore{filePath: filePath}
	rec, err := cs.load()
	if err != nil {
		return nil, err
	}
	cs.records = rec
	return cs, nil
}

func (cs *connectionRequestStore) create(fromDevice, fromOwner, toPeerID, toOwner string) *connectionRequest {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	req := &connectionRequest{
		ID:         randomHex(16),
		FromDevice: fromDevice,
		FromOwner:  fromOwner,
		ToPeerID:   toPeerID,
		ToOwner:    toOwner,
		Status:     "pending",
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
	}
	cs.records.Requests[req.ID] = req
	cs.save()
	log.Printf("[discover] connection request %s: %q → agent %s (owner: %s)", req.ID, fromDevice, toPeerID, toOwner)
	return req
}

func (cs *connectionRequestStore) get(id string) *connectionRequest {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	return cs.records.Requests[id]
}

func (cs *connectionRequestStore) listOutgoing(fromOwner, fromDevice string) []*connectionRequest {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	var result []*connectionRequest
	for _, req := range cs.records.Requests {
		if req.FromOwner == fromOwner || (fromOwner == "" && req.FromDevice == fromDevice) {
			result = append(result, req)
		}
	}
	return result
}

func (cs *connectionRequestStore) listIncoming(toOwner string) []*connectionRequest {
	cs.mu.RLock()
	defer cs.mu.RUnlock()
	var result []*connectionRequest
	for _, req := range cs.records.Requests {
		if req.ToOwner == toOwner && req.Status == "pending" {
			result = append(result, req)
		}
	}
	return result
}

func (cs *connectionRequestStore) approve(id, username, pairToken string) (*connectionRequest, error) {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	req, ok := cs.records.Requests[id]
	if !ok {
		return nil, fmt.Errorf("request not found")
	}
	if req.Status != "pending" {
		return nil, fmt.Errorf("request already %s", req.Status)
	}
	if req.ToOwner != username {
		return nil, fmt.Errorf("not your agent")
	}
	req.Status = "approved"
	req.ResolvedAt = time.Now().UTC().Format(time.RFC3339)
	req.PairToken = pairToken
	cs.save()
	log.Printf("[discover] request %s approved by %s", id, username)
	return req, nil
}

func (cs *connectionRequestStore) reject(id, username string) (*connectionRequest, error) {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	req, ok := cs.records.Requests[id]
	if !ok {
		return nil, fmt.Errorf("request not found")
	}
	if req.Status != "pending" {
		return nil, fmt.Errorf("request already %s", req.Status)
	}
	if req.ToOwner != username {
		return nil, fmt.Errorf("not your agent")
	}
	req.Status = "rejected"
	req.ResolvedAt = time.Now().UTC().Format(time.RFC3339)
	cs.save()
	log.Printf("[discover] request %s rejected by %s", id, username)
	return req, nil
}

func (cs *connectionRequestStore) load() (*connectionRequestRecord, error) {
	data, err := os.ReadFile(cs.filePath)
	if os.IsNotExist(err) {
		return &connectionRequestRecord{
			Version:  1,
			Requests: make(map[string]*connectionRequest),
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read requests file: %w", err)
	}
	var rec connectionRequestRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("parse requests file: %w", err)
	}
	if rec.Requests == nil {
		rec.Requests = make(map[string]*connectionRequest)
	}
	return &rec, nil
}

func (cs *connectionRequestStore) save() error {
	data, err := json.MarshalIndent(cs.records, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal requests: %w", err)
	}
	tmpPath := cs.filePath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0600); err != nil {
		return fmt.Errorf("write requests tmp: %w", err)
	}
	return os.Rename(tmpPath, cs.filePath)
}

// ---- Discover handlers ----

// handleDiscoverAgents returns online agents that the current user can discover.
// GET /api/discover/agents — Bearer session token auth.
func (rs *relayServer) handleDiscoverAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Extract session token from Bearer header
	sessionToken := extractBearer(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}

	// Find which agent this session is bound to
	rs.hub.mu.RLock()
	ac, _ := rs.hub.findAgentBySessionTokenLocked(sessionToken)
	rs.hub.mu.RUnlock()

	// Determine current user's owner (may be empty for anonymous)
	var currentOwner string
	if ac != nil {
		currentOwner, _ = rs.ownership.getAgentOwner(ac.PeerID)
	}
	// Also try session ownership directly
	if currentOwner == "" {
		currentOwner, _ = rs.ownership.getSessionOwner(sessionToken)
	}

	// Collect discoverable agents
	rs.hub.mu.RLock()
	agents := make([]map[string]any, 0, len(rs.hub.agents))
	for _, a := range rs.hub.agents {
		owner, claimed := rs.ownership.getAgentOwner(a.PeerID)
		visibility := a.Visibility
		if visibility == "" {
			// Fall back to persisted visibility
			visibility = rs.ownership.getAgentVisibility(a.PeerID)
		}
		isOwn := (claimed && owner == currentOwner)

		// Filter: show public agents + user's own agents (regardless of visibility)
		if !isOwn && visibility != "public" {
			continue
		}

		canRequest := claimed && !isOwn && visibility == "public"

		agentData := map[string]any{
			"peerID":      a.PeerID,
			"connectedAt": a.ConnectedAt.UTC().Format(time.RFC3339),
			"online":      true,
			"owner":       owner,
			"claimed":     claimed,
			"visibility":  visibility,
			"isOwn":       isOwn,
			"canRequest":  canRequest,
		}

		// Attach metadata if available
		if a.Metadata != nil {
			agentData["metadata"] = map[string]any{
				"type":         a.Metadata.Type,
				"label":        a.Metadata.Label,
				"capabilities": a.Metadata.Capabilities,
			}
		}

		agents = append(agents, agentData)
	}
	rs.hub.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"agents": agents,
		"count":  len(agents),
	})
}

// handleDiscoverConnect initiates a connection request to another user's agent.
// POST /api/discover/connect — Bearer session token auth.
func (rs *relayServer) handleDiscoverConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	sessionToken := extractBearer(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}

	var body struct {
		PeerID string `json:"peerID"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.PeerID == "" {
		jsonError(w, http.StatusBadRequest, "missing peerID")
		return
	}

	// Get requester info
	rs.hub.mu.RLock()
	requesterAC, _ := rs.hub.findAgentBySessionTokenLocked(sessionToken)
	rs.hub.mu.RUnlock()

	fromDevice := "Unknown Device"
	fromOwner := ""
	if requesterAC != nil {
		fromOwner, _ = rs.ownership.getAgentOwner(requesterAC.PeerID)
	}
	if fromOwner == "" {
		fromOwner, _ = rs.ownership.getSessionOwner(sessionToken)
	}

	// Try to get device name from session
	rs.hub.mu.RLock()
	for _, a := range rs.hub.agents {
		if a.PeerID == requesterAC.PeerID {
			// Device name isn't stored in agentConn; try ownership
			break
		}
	}
	rs.hub.mu.RUnlock()

	// Get device name from header or use a placeholder
	if dn := r.Header.Get("X-Device-Name"); dn != "" {
		fromDevice = dn
	}

	// Find target agent
	rs.hub.mu.RLock()
	targetAC, targetOnline := rs.hub.agents[body.PeerID]
	rs.hub.mu.RUnlock()

	if !targetOnline {
		jsonError(w, http.StatusNotFound, "agent not found or offline")
		return
	}

	targetOwner, targetClaimed := rs.ownership.getAgentOwner(body.PeerID)

	// Case 1: Target is unclaimed → auto-claim and return pairToken
	if !targetClaimed {
		// Auto-claim: if requester has an owner, use it; otherwise anonymous
		claimUser := fromOwner
		if claimUser == "" {
			claimUser = fromDevice
		}
		if err := rs.ownership.claimAgent(body.PeerID, claimUser); err != nil {
			jsonError(w, http.StatusConflict, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"requestId": "",
			"status":    "approved",
			"pairToken": targetAC.PairToken,
			"message":   "agent claimed and ready for pairing",
		})
		return
	}

	// Case 2: Target is user's own → return pairToken directly
	if targetOwner == fromOwner && fromOwner != "" {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"requestId": "",
			"status":    "approved",
			"pairToken": targetAC.PairToken,
			"message":   "already your agent",
		})
		return
	}

	// Case 3: Target is someone else's → create connection request
	// Verify target is public
	vis := targetAC.Visibility
	if vis == "" {
		vis = rs.ownership.getAgentVisibility(body.PeerID)
	}
	if vis != "public" {
		jsonError(w, http.StatusForbidden, "agent is private")
		return
	}

	req := rs.connReqs.create(fromDevice, fromOwner, body.PeerID, targetOwner)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"requestId": req.ID,
		"status":    "pending",
		"message":   fmt.Sprintf("connection request sent to %s", targetOwner),
	})
}

// handleDiscoverRequests returns the current user's outgoing connection requests.
// GET /api/discover/requests — Bearer session token auth.
func (rs *relayServer) handleDiscoverRequests(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	sessionToken := extractBearer(r.Header.Get("Authorization"))
	if sessionToken == "" {
		jsonError(w, http.StatusUnauthorized, "missing authorization")
		return
	}

	fromOwner, _ := rs.ownership.getSessionOwner(sessionToken)
	fromDevice := r.Header.Get("X-Device-Name")
	if fromDevice == "" {
		fromDevice = "Unknown"
	}

	outgoing := rs.connReqs.listOutgoing(fromOwner, fromDevice)
	out := make([]map[string]any, 0, len(outgoing))
	for _, req := range outgoing {
		out = append(out, map[string]any{
			"requestId":  req.ID,
			"peerID":     req.ToPeerID,
			"toOwner":    req.ToOwner,
			"status":     req.Status,
			"createdAt":  req.CreatedAt,
			"pairToken":  req.PairToken,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"outgoing": out,
	})
}

// handleDashboardRequests returns incoming connection requests for Dashboard.
// GET /api/dashboard/requests — Dashboard cookie auth.
func (rs *relayServer) handleDashboardRequests(w http.ResponseWriter, r *http.Request) {
	session := getSession(r)
	if session == nil {
		jsonError(w, http.StatusUnauthorized, "login required")
		return
	}

	// GET: list incoming requests
	incoming := rs.connReqs.listIncoming(session.Username)
	in := make([]map[string]any, 0, len(incoming))
	for _, req := range incoming {
		in = append(in, map[string]any{
			"requestId":  req.ID,
			"fromDevice": req.FromDevice,
			"fromOwner":  req.FromOwner,
			"peerID":     req.ToPeerID,
			"status":     req.Status,
			"createdAt":  req.CreatedAt,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"incoming": in,
	})
}

// handleDashboardRequestAction handles approve/reject for a specific request.
// POST /api/dashboard/requests/{id}/approve or /reject
func (rs *relayServer) handleDashboardRequestAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	session := getSession(r)
	if session == nil {
		jsonError(w, http.StatusUnauthorized, "login required")
		return
	}

	// Parse path: /api/dashboard/requests/{id}/approve
	path := strings.TrimPrefix(r.URL.Path, "/api/dashboard/requests/")
	parts := strings.Split(path, "/")
	if len(parts) != 2 {
		jsonError(w, http.StatusBadRequest, "invalid path, expected /api/dashboard/requests/{id}/approve|reject")
		return
	}
	requestID := parts[0]
	action := parts[1]

	switch action {
	case "approve":
		// Get the target agent to grab pairToken
		req := rs.connReqs.get(requestID)
		if req == nil {
			jsonError(w, http.StatusNotFound, "request not found")
			return
		}

		rs.hub.mu.RLock()
		targetAC, ok := rs.hub.agents[req.ToPeerID]
		rs.hub.mu.RUnlock()
		if !ok {
			jsonError(w, http.StatusNotFound, "target agent offline")
			return
		}

		updated, err := rs.connReqs.approve(requestID, session.Username, targetAC.PairToken)
		if err != nil {
			jsonError(w, http.StatusConflict, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"status":  updated.Status,
			"message": fmt.Sprintf("request approved, %s can now pair", updated.FromDevice),
		})

	case "reject":
		updated, err := rs.connReqs.reject(requestID, session.Username)
		if err != nil {
			jsonError(w, http.StatusConflict, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"ok":      true,
			"status":  updated.Status,
			"message": "request rejected",
		})

	default:
		jsonError(w, http.StatusBadRequest, "unknown action: "+action)
	}
}

// handleDashboardVisibility toggles an agent's public/private visibility.
// PUT /api/dashboard/agents/{peerID}/visibility — Dashboard cookie auth.
func (rs *relayServer) handleDashboardVisibility(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		jsonError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	session := getSession(r)
	if session == nil {
		jsonError(w, http.StatusUnauthorized, "login required")
		return
	}

	peerID := strings.TrimPrefix(r.URL.Path, "/api/dashboard/agents/")
	peerID = strings.TrimSuffix(peerID, "/visibility")
	if peerID == "" {
		jsonError(w, http.StatusBadRequest, "missing peerID")
		return
	}

	// Verify ownership
	owner, claimed := rs.ownership.getAgentOwner(peerID)
	if !claimed || owner != session.Username {
		jsonError(w, http.StatusForbidden, "not your agent")
		return
	}

	var body struct {
		Visibility string `json:"visibility"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		jsonError(w, http.StatusBadRequest, "invalid body")
		return
	}

	if err := rs.ownership.setAgentVisibility(peerID, body.Visibility); err != nil {
		jsonError(w, http.StatusBadRequest, err.Error())
		return
	}

	// Also update in-memory agentConn
	rs.hub.mu.Lock()
	if ac, ok := rs.hub.agents[peerID]; ok {
		ac.Visibility = body.Visibility
	}
	rs.hub.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"ok":         true,
		"visibility": body.Visibility,
	})
}

// ---- Helpers ----

// extractBearer extracts the token from an "Authorization: Bearer <token>" header.
func extractBearer(auth string) string {
	const prefix = "Bearer "
	if len(auth) > len(prefix) && strings.EqualFold(auth[:len(prefix)], prefix) {
		return auth[len(prefix):]
	}
	return ""
}

// findAgentBySessionTokenLocked looks up an agent by session token.
// Caller must hold hub.mu.RLock.
func (h *hub) findAgentBySessionTokenLocked(sessionToken string) (*agentConn, bool) {
	peerID, ok := h.bySession[sessionToken]
	if !ok {
		return nil, false
	}
	ac, ok := h.agents[peerID]
	return ac, ok
}
