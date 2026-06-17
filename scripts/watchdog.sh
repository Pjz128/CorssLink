#!/usr/bin/env bash
# CrossLink Agent Watchdog — keeps the agent running.
# Usage: bash scripts/watchdog.sh
#
# For automatic startup at Windows logon, run once:
#   powershell -ExecutionPolicy Bypass -File scripts/install-agent-service.ps1

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[watchdog] CrossLink Agent Watchdog started at $(date)"
echo "[watchdog] Agent will restart automatically if it exits."
echo "[watchdog] Press Ctrl+C twice within ${RESTART_DELAY:-5}s to stop."
echo ""

RESTART_DELAY=5
RESTART_COUNT=0

while true; do
  RESTART_COUNT=$((RESTART_COUNT + 1))
  echo "[watchdog] === Starting agent (run #$RESTART_COUNT) at $(date) ==="

  bash "$ROOT/scripts/start-agent.sh"
  EXIT_CODE=$?

  echo "[watchdog] Agent exited with code $EXIT_CODE at $(date)"

  # Exit codes that indicate intentional stop
  if [ $EXIT_CODE -eq 130 ] || [ $EXIT_CODE -eq 143 ]; then
    echo "[watchdog] Interrupted by user. Stopping watchdog."
    exit 0
  fi

  echo "[watchdog] Restarting in ${RESTART_DELAY}s..."
  sleep $RESTART_DELAY
done
