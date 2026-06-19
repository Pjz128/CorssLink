// CrossLink Agent: persistent agent with multi-backend pool (Ollama, Claude, DeepSeek).
//
// HTTP+SSE mode (v2):
//
//	crosslink-agent                    Run HTTP server on :18080 with SSE streaming
//
// Service mode (Windows):
//
//	crosslink-agent install            Install as Windows service (auto-start)
//	crosslink-agent uninstall          Remove Windows service
//
// Relay mode (cloud, set RELAY_ADDR):
//
//	crosslink-agent                    Connect to cloud relay via WebSocket
//
// The agent runs an HTTP server, displays a QR code for pairing,
// and streams AI responses via Server-Sent Events.
// In relay mode, it connects to a cloud relay server instead of listening locally.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"

	"crosslink-poc/agent"
	"crosslink-poc/agent/claude"
	"crosslink-poc/agent/pool"
	"crosslink-poc/cloud"
	"crosslink-poc/ollama"
	"crosslink-poc/pairing"
)

var (
	listenAddr = envOr("LISTEN_ADDR", ":18080")
	peerID     = envOr("PEER_ID", "agent-ollama-pc")
)

func main() {
	// Detect service mode
	if svc, err := isWindowsService(); err == nil && svc {
		setupLogging(false)
		if err := runService(); err != nil {
			log.Fatalf("service: %v", err)
		}
		return
	}

	// Parse commands
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "install":
			if err := installService(); err != nil {
				fmt.Fprintf(os.Stderr, "install failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "uninstall":
			if err := uninstallService(); err != nil {
				fmt.Fprintf(os.Stderr, "uninstall failed: %v\n", err)
				os.Exit(1)
			}
			return
		case "help", "-h", "--help":
			printUsage()
			return
		}
	}

	// Interactive mode
	setupLogging(true)
	log.Printf("=== CrossLink Agent v2 (HTTP+SSE) ===")
	log.Printf("  Use '%s install' to run as Windows service.", os.Args[0])

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Ctrl+C handler
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	go func() {
		<-sig
		log.Printf("[agent] received Ctrl+C, shutting down...")
		cancel()
	}()

	if err := runAgent(ctx); err != nil {
		log.Fatalf("agent: %v", err)
	}
	log.Printf("[agent] exited.")
}

func printUsage() {
	fmt.Printf(`CrossLink Agent v2 — 跨端 AI 代理 (HTTP+SSE)

Usage:
  %s                Run HTTP server in foreground
  %s install        Install as Windows service (auto-start on boot)
  %s uninstall      Remove Windows service

Service name: %s
`, os.Args[0], os.Args[0], os.Args[0], svcName)
}

func runAgent(ctx context.Context) error {
	// ---- Load or create persistent keypair (for future E2E encryption) ----
	agentKP := loadOrCreateKeypair()

	// ---- Detect LAN IP ----
	lanIP := detectLANIP()
	log.Printf("[agent] LAN IP: %s", lanIP)

	// ---- Build BackendPool ----
	backendPool := pool.NewBackendPool()

	// 1. Ollama (local, if available)
	ollamaClient := ollama.NewClient("")
	if version, err := ollamaClient.Ping(); err == nil {
		models, _ := ollamaClient.ListModels()
		if len(models) == 0 {
			models = []ollama.ModelInfo{{Name: "ollama"}}
		}
		backendPool.Register("ollama", ollamaClient, ollama.AgentInfo{
			Type: "ollama", Label: "Ollama (本地)", Models: models,
		})
		log.Printf("[agent] 🦙 Ollama ready: %s, %d models", version, len(models))
	} else {
		log.Printf("[agent] ⚠️  Ollama not available: %v (skipped)", err)
	}

	// 2. Claude Code (long-running subprocess)
	claudePath := envOr("CLAUDE_PATH",
		`C:\Users\22730\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`)
	claudeModel := envOr("CLAUDE_MODEL", "sonnet")
	claudeSession, err := claude.NewSession(claude.Config{
		BinaryPath: claudePath,
		Model:      claudeModel,
	})
	if err == nil {
		backendPool.Register("claude", claudeSession, ollama.AgentInfo{
			Type:   "claude",
			Label:  "Claude Code",
			Models: claudeSession.Models(),
		})
		log.Printf("[agent] 🤖 Claude Code ready (model=%s)", claudeModel)
	} else {
		log.Printf("[agent] ⚠️  Claude Code not available: %v (skipped)", err)
	}

	// 3. DeepSeek (cloud fallback)
	deepseekClient := cloud.NewDeepSeek("", "deepseek-v4-pro")
	backendPool.Register("deepseek", deepseekClient, ollama.AgentInfo{
		Type:   "deepseek",
		Label:  "DeepSeek (云端)",
		Models: []ollama.ModelInfo{{Name: "deepseek-chat", ParamSize: "V3", Quant: "cloud"}},
	})
	log.Printf("[agent] ☁️  DeepSeek ready")

	log.Printf("[agent] BackendPool:\n%s", backendPool.Status())

	// ---- Create HTTP server ----
	pairToken := envOr("PAIR_TOKEN", "")
	server, err := agent.NewServer(agent.Config{
		Addr:      listenAddr,
		Pool:      backendPool,
		PairToken: pairToken,
		LanIP:     lanIP,
	})
	if err != nil {
		return fmt.Errorf("create server: %w", err)
	}

	// ---- Relay or LAN mode ----
	relayAddr := os.Getenv("RELAY_ADDR")
	if relayAddr != "" {
		return runRelayMode(ctx, server, agentKP, relayAddr)
	}
	return runLANMode(ctx, server, agentKP, lanIP)
}

// runRelayMode connects to a cloud relay via WebSocket (reverse tunnel).
// The agent does NOT listen on a local HTTP port in this mode.
func runRelayMode(ctx context.Context, server *agent.Server, agentKP *pairing.KeyPair, relayAddr string) error {
	relayHTTP := relayAddrToHTTP(relayAddr)
	serverURL := fmt.Sprintf("%s/pair?token=%s", relayHTTP, server.PairToken())
	qrPayload := pairing.QRPayload{
		Version:   2,
		PublicKey: agentKP.PublicKeyBase64(),
		ServerURL: serverURL,
		PeerID:    peerID,
	}
	qrURI := pairing.EncodeQR(qrPayload)

	log.Printf("")
	log.Printf("┌─────────────────────────────────────────────────────┐")
	log.Printf("│  ☁️  Relay mode (cloud):                             │")
	log.Printf("│  📱 Scan to connect:                                │")
	log.Printf("│  %s", qrURI)
	log.Printf("└─────────────────────────────────────────────────────┘")
	log.Printf("")
	log.Printf("  Relay:   %s", relayAddr)
	log.Printf("  Pair URL: %s", serverURL)
	log.Printf("")

	// Auto-generate QR PNG
	qrPath := filepath.Join(os.TempDir(), "crosslink-qr.png")
	go generateAndOpenQR(qrURI, qrPath)

	// Cleanup on shutdown
	go func() {
		<-ctx.Done()
		log.Printf("[agent] shutting down relay bridge...")
		server.Shutdown(context.Background())
	}()

	// Connect to relay (blocks, auto-reconnects)
	bridge := agent.NewRelayBridge(agent.RelayConfig{
		RelayAddr: relayAddr,
		PeerID:    peerID,
		PairToken: server.PairToken(),
		Server:    server,
	})
	return bridge.Connect(ctx)
}

// runLANMode listens for direct HTTP connections on the local network (default).
func runLANMode(ctx context.Context, server *agent.Server, agentKP *pairing.KeyPair, lanIP string) error {
	serverURL := fmt.Sprintf("http://%s%s", lanIP, listenAddr)
	qrPayload := pairing.QRPayload{
		Version:   2,
		PublicKey: agentKP.PublicKeyBase64(),
		ServerURL: serverURL + "/pair?token=" + server.PairToken(),
		PeerID:    peerID,
	}
	qrURI := pairing.EncodeQR(qrPayload)

	log.Printf("")
	log.Printf("┌─────────────────────────────────────────────────────┐")
	log.Printf("│  📱 Scan to connect (LAN mode):                     │")
	log.Printf("│  %s", qrURI)
	log.Printf("└─────────────────────────────────────────────────────┘")
	log.Printf("")
	log.Printf("  Pair URL: %s/pair?token=%s", serverURL, server.PairToken())
	log.Printf("")

	// Auto-generate QR PNG and open it
	qrPath := filepath.Join(os.TempDir(), "crosslink-qr.png")
	go generateAndOpenQR(qrURI, qrPath)

	// Start server (blocks)
	go func() {
		<-ctx.Done()
		log.Printf("[agent] shutting down server...")
		server.Shutdown(context.Background())
	}()

	return server.ListenAndServe()
}

// relayAddrToHTTP converts a WebSocket relay address to an HTTP base URL.
// e.g. "ws://45.197.144.16:18080/agent" → "http://45.197.144.16:18080"
func relayAddrToHTTP(addr string) string {
	u, err := url.Parse(addr)
	if err != nil {
		// Fallback: simple string replacement
		s := strings.Replace(addr, "ws://", "http://", 1)
		s = strings.Replace(s, "wss://", "https://", 1)
		if idx := strings.Index(s, "/agent"); idx > 0 {
			s = s[:idx]
		}
		return s
	}
	switch u.Scheme {
	case "wss":
		u.Scheme = "https"
	default:
		u.Scheme = "http"
	}
	u.Path = ""
	u.RawQuery = ""
	u.Fragment = ""
	return u.String()
}

// generateAndOpenQR creates a QR code PNG and opens it.
// Uses Python (qrcode + PIL) which is available on the dev machine.
func generateAndOpenQR(qrURI, path string) error {
	// Use forward slashes to avoid Python unicode escape issues on Windows
	savePath := strings.ReplaceAll(path, `\`, `/`)
	script := fmt.Sprintf(`import qrcode
img = qrcode.make("%s")
img.save("%s")
`, qrURI, savePath)
	cmd := exec.Command("python3", "-c", script)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		// Try python (without 3) as fallback
		cmd2 := exec.Command("python", "-c", script)
		cmd2.Stderr = os.Stderr
		if err2 := cmd2.Run(); err2 != nil {
			return fmt.Errorf("qr generation failed (python3: %v, python: %v)", err, err2)
		}
	}
	log.Printf("[agent] QR saved to %s", path)
	return openFile(path)
}

// openFile opens a file with the default application on Windows.
func openFile(path string) error {
	return exec.Command("cmd", "/c", "start", "", path).Start()
}

// detectLANIP tries to find the local LAN IP address.
func detectLANIP() string {
	// Check env first
	if ip := os.Getenv("LAN_IP"); ip != "" {
		return ip
	}

	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
			// Prefer 192.168.x.x or 10.x.x.x
			s := ipnet.IP.String()
			if strings.HasPrefix(s, "192.168.") || strings.HasPrefix(s, "10.") || strings.HasPrefix(s, "172.") {
				return s
			}
		}
	}
	return "127.0.0.1"
}

// ---- Keypair (kept for future E2E encryption) ----

func loadOrCreateKeypair() *pairing.KeyPair {
	masterKey := deriveMasterKey(peerID)

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

	kp, err := pairing.LoadKeyPair(keyPath, &masterKey)
	if err == nil {
		log.Printf("[agent] loaded existing keypair from %s", keyPath)
		return kp
	}

	if !os.IsNotExist(err) {
		log.Printf("[agent] WARNING: failed to load keypair (%v), generating new one", err)
	}

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

func deriveMasterKey(peerID string) [32]byte {
	hostname, _ := os.Hostname()
	seed := fmt.Sprintf("%s:%s:crosslink-agent-key-v1", hostname, peerID)
	return sha256.Sum256([]byte(seed))
}

func base64Decode(s string) ([]byte, error) {
	return base64.URLEncoding.DecodeString(s)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Placeholder for old acceptPairing (no longer needed, kept for service compat)
func _() {
	_ = json.Marshal
}
