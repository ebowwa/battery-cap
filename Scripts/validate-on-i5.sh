#!/bin/bash
# validate.sh v2 - runs on i5. Fixes from v1:
#   - Cap target clamped to >=50 (binary rejects <50)
#   - AC preflight: refuses to run if not on AC Power
#   - pmset -g battlimit wrapped (Ventura doesn't support it)
#   - disablesleep verified via pmset -g assertions (not visible in pmset -g)
# Expects NOPASSWD to be set; otherwise falls back to prompting.
set -uo pipefail
BIN="$HOME/BatteryCap"

if [ ! -x "$BIN" ]; then
  chmod +x "$BIN" 2>/dev/null || { echo "ERR: $BIN missing"; exit 1; }
fi

# Pre-flight: must be on AC power for EC behavior test to be meaningful.
AC_LINE=$(pmset -g batt | head -1)
if ! echo "$AC_LINE" | grep -q "AC Power"; then
  echo "ABORT: i5 is not on AC power. Current state:"
  echo "  $AC_LINE"
  echo "Plug in the USB-C charger, wait ~30s for 'AC Power; charging', re-run."
  exit 1
fi

# sudo setup: try non-interactive (NOPASSWD), fall back to interactive prompt.
if ! sudo -n true 2>/dev/null; then
  echo "NOPASSWD not set; prompting for password (cached 5min)..."
  sudo -v || { echo "sudo auth failed"; exit 1; }
fi

# Cap target: clamp to binary's [50, 100] range.
BATT_PCT=$("$BIN" get charge 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ -z "$BATT_PCT" ]; then BATT_PCT=60; fi
CAP_TARGET=$((BATT_PCT - 10))
if [ "$CAP_TARGET" -lt 50 ]; then CAP_TARGET=50; fi
if [ "$CAP_TARGET" -gt 95 ]; then CAP_TARGET=95; fi

echo "Battery at ${BATT_PCT}%, will test cap=${CAP_TARGET}"

echo ""
echo "=== baseline: batterycap status ==="
"$BIN" status

echo ""
echo "=== baseline: batterycap get cap ==="
"$BIN" get cap

echo ""
echo "=== baseline: pmset -g batt ==="
pmset -g batt

echo ""
echo "=== starting non-persistent test: cap=${CAP_TARGET} ==="
sudo "$BIN" test start --value "$CAP_TARGET"
echo "exit: $?"

echo "=== sleeping 8s for EC to react (was 6s, giving more margin) ==="
sleep 8

echo ""
echo "=== readback: batterycap get cap (should match ${CAP_TARGET}) ==="
"$BIN" get cap

echo ""
echo "=== pmset -g batt (look for 'not charging') ==="
pmset -g batt

echo ""
echo "=== pmset -g battlimit (Ventura may not support; tolerate error) ==="
pmset -g battlimit 2>&1 || echo "(expected on Ventura; macOS 14+ only)"

echo ""
echo "=== batterycap test status ==="
"$BIN" test status

echo ""
echo "=== ending test (auto-restores previous cap) ==="
sudo "$BIN" test end
echo "exit: $?"

echo ""
echo "=== final: batterycap status ==="
"$BIN" status

echo ""
echo "=== final: pmset -g batt ==="
pmset -g batt

echo ""
echo "=== CLAMSHELL SETUP ==="
echo "before (assertions for sleep prevention):"
pmset -g assertions | grep -E "PreventSystemSleep|PreventUserIdleSystemSleep" || echo "(none)"

sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 0
sudo pmset -a disablesleep 1
sudo pmset -a lidwake 1
sudo pmset -a ttyskeepawake 1

echo "after (assertions):"
pmset -g assertions | grep -E "PreventSystemSleep|PreventUserIdleSystemSleep" || echo "(none)"

echo ""
echo "custom pmset settings:"
pmset -g custom | grep -E "sleep|disablesleep|lidwake|ttyskeepawake|displaysleep|disksleep"

echo ""
echo "=== DONE ==="
date
