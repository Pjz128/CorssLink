#!/usr/bin/env bash
# CrossLink Cloud — deploy relay server to remote host.
# Usage: bash scripts/deploy-cloud.sh [host] [user]
#
# Prerequisites:
#   CL_PASS env var must be set (or pass via stdin)
#   Go toolchain installed locally for cross-compilation

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOST="${1:-45.197.144.16:22}"
USER="${2:-root}"
PASS="${CL_PASS:-}"

if [ -z "$PASS" ]; then
  echo "CL_PASS not set. Usage: CL_PASS=xxx bash scripts/deploy-cloud.sh"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() { echo -e "${CYAN}=== $1 ===${NC}"; }
ok()     { echo -e "  ${GREEN}[OK]${NC} $1"; }

run_ssh() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=accept-new "$USER@${HOST%:*}" "$@"
}

echo ""
echo -e "${CYAN}CrossLink Cloud Deploy (Relay)${NC}"
echo "Target: $USER@$HOST"
echo ""

# ---- 1. Build relay server ----
banner "Building relay server (linux/amd64)"
cd "$ROOT/poc"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
GOOS=linux GOARCH=amd64 go build -o relay-server ./relay/ 2>&1
ok "relay-server built"

# ---- 2. Upload relay server ----
banner "Uploading relay server"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=accept-new "$USER@${HOST%:*}" "mkdir -p /root/crosslink"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=accept-new \
  relay-server "$USER@${HOST%:*}:/root/crosslink/relay-server"
ok "relay-server uploaded"

# ---- 3. Stop old signal server (if running) ----
banner "Stopping old signal server (if any)"
run_ssh "
  systemctl stop crosslink-signal 2>/dev/null || true
  systemctl disable crosslink-signal 2>/dev/null || true
  rm -f /etc/systemd/system/crosslink-signal.service
"
ok "old signal server cleaned up"

# ---- 4. Setup systemd for relay server ----
banner "Configuring systemd service"
run_ssh "
  cat > /etc/systemd/system/crosslink-relay.service << 'UNIT'
[Unit]
Description=CrossLink Cloud Relay Server
After=network.target

[Service]
Type=simple
ExecStart=/root/crosslink/relay-server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable crosslink-relay
  systemctl restart crosslink-relay

  # Create combined target for easy status check
  cat > /etc/systemd/system/crosslink.target << 'TARGET'
[Unit]
Description=CrossLink Cloud Services
Wants=crosslink-relay.service
After=network.target

[Install]
WantedBy=multi-user.target
TARGET
  systemctl daemon-reload
  systemctl enable crosslink.target
"
ok "Relay server systemd unit installed"
ok "CrossLink cloud target installed (crosslink.target)"

# ---- 5. Health check ----
banner "Health check"
sleep 2
echo ""
echo "Relay server:"
if run_ssh "curl -s http://localhost:18080/health" 2>/dev/null; then
  ok "Relay server responding"
else
  echo "  [FAIL] Relay server not responding"
fi

echo ""
echo "Systemd status:"
run_ssh "systemctl status crosslink-relay --no-pager -l | head -5" 2>/dev/null || true

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
echo "  Relay (Agent WS):  ws://${HOST%:*}:18080/agent"
echo "  Relay (Phone HTTP): http://${HOST%:*}:18080"
echo ""
