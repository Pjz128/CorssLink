#!/usr/bin/env bash
# CrossLink POC: WebRTC connectivity test
# Requires: Go 1.22+ installed
# Usage:
#   ./run.sh signal    Start the signaling server
#   ./run.sh agent     Start the home PC agent
#   ./run.sh client    Start the mobile client
#   ./run.sh all       Run all three in separate terminals (recommended)
#
# Recommended test flow:
#   1. Terminal 1: ./run.sh signal
#   2. Terminal 2: ./run.sh agent
#   3. Terminal 3: ./run.sh client
#
# Expected output:
#   - Signal server shows peer registrations and message routing
#   - Agent shows "data channel opened" after client connects
#   - Client shows ping-pong RTT measurements (should be < 50ms on LAN)
#   - ICE state progression: checking -> connected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export GOPATH="${GOPATH:-$HOME/go}"
export PATH="${HOME}/.local/go/bin:$GOPATH/bin:/usr/local/go/bin:$PATH"

# Download dependencies if needed
if [ ! -f "go.sum" ]; then
	echo "[setup] downloading dependencies..."
	go mod tidy
fi

case "${1:-all}" in
	signal)
		echo "[poc] starting signaling server on :8080"
		go run ./signal/main.go
		;;
	agent)
		echo "[poc] starting agent (home PC)"
		go run ./agent/main.go
		;;
	client)
		echo "[poc] starting client (mobile app)"
		go run ./client/main.go
		;;
	all)
		echo "[poc] starting all three components..."
		echo ""
		echo "  ╔═══════════════════════════════════════════════════╗"
		echo "  ║  CrossLink WebRTC POC                             ║"
		echo "  ║                                                   ║"
		echo "  ║  Signal server  : ws://localhost:8080             ║"
		echo "  ║  Agent (home PC): agent-home-pc                   ║"
		echo "  ║  Client (mobile): client-mobile                   ║"
		echo "  ║                                                   ║"
		echo "  ║  Expected:                                        ║"
		echo "  ║  - Agent & Client register with signal            ║"
		echo "  ║  - Client sends WebRTC offer to agent             ║"
		echo "  ║  - DataChannel established                        ║"
		echo "  ║  - Ping/pong with RTT < 50ms (local)              ║"
		echo "  ╚═══════════════════════════════════════════════════╝"
		echo ""

		# Start signal in background
		go run ./signal/main.go &
		SIGNAL_PID=$!
		sleep 1

		# Start agent in background
		go run ./agent/main.go &
		AGENT_PID=$!
		sleep 0.5

		# Start client in foreground
		go run ./client/main.go
		CLIENT_EXIT=$?

		# Cleanup
		kill $AGENT_PID $SIGNAL_PID 2>/dev/null || true
		exit $CLIENT_EXIT
		;;
	*)
		echo "Usage: $0 {signal|agent|client|all}"
		exit 1
		;;
esac
