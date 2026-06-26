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
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
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
	"crosslink-poc/pairing"
	"crosslink-poc/plugin"
	claudeplugin "crosslink-poc/plugin/claude"
	deepplugin "crosslink-poc/plugin/deepseek"
	ollamaplugin "crosslink-poc/plugin/ollama"
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

	// ---- Build Plugin Registry ----
	registry := plugin.NewRegistry()

	// 1. Ollama (local, auto-detects availability via Init)
	if err := registry.Register(ollamaplugin.New(ollamaplugin.Config{})); err != nil {
		log.Printf("[agent] ⚠️  Ollama not available: %v (skipped)", err)
	}

	// 2. Claude Code (long-running subprocess)
	claudePath := envOr("CLAUDE_PATH",
		`C:\Users\22730\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe`)
	claudeModel := envOr("CLAUDE_MODEL", "sonnet")
	agentDataDir := os.Getenv("CROSSLINK_DATA_DIR")
	if agentDataDir == "" {
		agentDataDir = filepath.Join(os.TempDir(), "crosslink-agent")
	}
	claudeDataDir := filepath.Join(agentDataDir, "claude")
	if p, err := claudeplugin.New(claudeplugin.Config{
		BinaryPath: claudePath,
		Model:      claudeModel,
		DataDir:    claudeDataDir,
	}); err == nil {
		if err := registry.Register(p); err != nil {
			log.Printf("[agent] ⚠️  Claude registration failed: %v", err)
		}
	} else {
		log.Printf("[agent] ⚠️  Claude Code not available: %v (skipped)", err)
	}

	// 3. DeepSeek (cloud, always available)
	deepseekAPIKey := os.Getenv("DEEPSEEK_API_KEY")
	if err := registry.Register(deepplugin.New(deepplugin.Config{APIKey: deepseekAPIKey, Model: "deepseek-v4-pro"})); err != nil {
		log.Printf("[agent] ⚠️  DeepSeek registration failed: %v", err)
	}

	log.Printf("[agent] Registry:\n%s", registry.Status())

	// ---- Create HTTP server ----
	pairToken := envOr("PAIR_TOKEN", "")
	if pairToken == "" {
		pairToken = persistentPairToken()
	}
	server, err := agent.NewServer(agent.Config{
		Addr:      listenAddr,
		Registry:  registry,
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

	qrPath := filepath.Join(os.TempDir(), "crosslink-qr.png")
	go generateAndOpenQR(qrURI, qrPath)

	// Cleanup on shutdown
	go func() {
		<-ctx.Done()
		log.Printf("[agent] shutting down relay bridge...")
		server.Shutdown(context.Background())
	}()

	// Connect to relay (blocks, auto-reconnects)
	deployToken := os.Getenv("DEPLOY_TOKEN")

	bridge := agent.NewRelayBridge(agent.RelayConfig{
		RelayAddr:   relayAddr,
		PeerID:      peerID,
		PairToken:   server.PairToken(),
		DeployToken: deployToken,
		Server:      server,
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
// e.g. "ws://crosslink.cyou:18080/agent" → "http://crosslink.cyou:18080"
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
// persistentPairToken loads or creates a pair token that survives agent restarts.
// Uses same config directory as the keypair.
func persistentPairToken() string {
	configDir, err := os.UserConfigDir()
	if err != nil {
		home, _ := os.UserHomeDir()
		configDir = filepath.Join(home, ".crosslink")
	} else {
		configDir = filepath.Join(configDir, "crosslink")
	}
	os.MkdirAll(configDir, 0700)

	tokenPath := filepath.Join(configDir, "agent_pair_token")
	if data, err := os.ReadFile(tokenPath); err == nil && len(data) >= 16 {
		token := strings.TrimSpace(string(data))
		log.Printf("[agent] loaded persistent pair token from %s", tokenPath)
		return token
	}

	b := make([]byte, 16)
	rand.Read(b)
	token := hex.EncodeToString(b)
	if err := os.WriteFile(tokenPath, []byte(token), 0600); err != nil {
		log.Printf("[agent] WARNING: failed to save pair token: %v", err)
	} else {
		log.Printf("[agent] saved persistent pair token to %s", tokenPath)
	}
	return token
}

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
