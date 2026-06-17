#!/usr/bin/env bash
# CrossLink Cloud — deploy signal server + TURN to remote host.
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
echo -e "${CYAN}CrossLink Cloud Deploy${NC}"
echo "Target: $USER@$HOST"
echo ""

# ---- 1. Build signal server ----
banner "Building signal server (linux/amd64)"
cd "$ROOT/poc/signal"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
GOOS=linux GOARCH=amd64 go build -o signal-server . 2>&1
ok "signal-server built"

# ---- 2. Upload signal server ----
banner "Uploading signal server"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=accept-new "$USER@${HOST%:*}" "mkdir -p /root/crosslink"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=accept-new \
  signal-server "$USER@${HOST%:*}:/root/crosslink/signal-server"
ok "signal-server uploaded"

# ---- 3. Install & configure coturn (if not present) ----
banner "Setting up TURN server"
run_ssh "
  if ! command -v turnserver &>/dev/null; then
    apt-get update -qq && apt-get install -y coturn
  fi
  cat > /etc/turnserver.conf << 'TURNCONF'
listening-port=3478
listening-ip=0.0.0.0
external-ip=${HOST%:*}
relay-ip=0.0.0.0
min-port=49152
max-port=65535
verbose
realm=crosslink.local
user=turnuser:crosslinkpass123
no-tlsv1
no-tlsv1_1
no-tlsv1_2
TURNCONF
  systemctl restart coturn
  systemctl enable coturn

  # Add Restart=always override via drop-in (vendor unit lacks it)
  mkdir -p /etc/systemd/system/coturn.service.d
  cat > /etc/systemd/system/coturn.service.d/restart.conf << 'OVERRIDE'
[Service]
Restart=always
RestartSec=10
OVERRIDE
  systemctl daemon-reload
"
ok "TURN server configured"

# ---- 4. Setup systemd for signal server ----
banner "Configuring systemd service"
run_ssh "
  cat > /etc/systemd/system/crosslink-signal.service << 'UNIT'
[Unit]
Description=CrossLink Signal Server
After=network.target

[Service]
Type=simple
ExecStart=/root/crosslink/signal-server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable crosslink-signal
  systemctl restart crosslink-signal

  # Create combined target for easy status check
  cat > /etc/systemd/system/crosslink.target << 'TARGET'
[Unit]
Description=CrossLink Cloud Services
Wants=crosslink-signal.service coturn.service
After=network.target

[Install]
WantedBy=multi-user.target
TARGET
  systemctl daemon-reload
  systemctl enable crosslink.target
"
ok "Signal server systemd unit installed"
ok "CrossLink cloud target installed (crosslink.target)"

# ---- 5. Health check ----
banner "Health check"
sleep 2
echo ""
echo "Signal server:"
if run_ssh "curl -s http://localhost:18080/health" 2>/dev/null; then
  ok "Signal server responding"
else
  echo "  [FAIL] Signal server not responding"
fi

echo ""
echo "TURN server:"
if run_ssh "ss -tuln | grep 3478" 2>/dev/null; then
  ok "TURN port 3478 listening"
else
  echo "  [FAIL] TURN not listening"
fi

echo ""
echo "Systemd status:"
run_ssh "systemctl status crosslink-signal --no-pager -l | head -5" 2>/dev/null || true

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
echo "  Signal:  ws://${HOST%:*}:18080"
echo "  TURN:    turn:${HOST%:*}:3478?transport=tcp"
echo ""
