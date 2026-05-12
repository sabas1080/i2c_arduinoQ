#!/usr/bin/env bash
# Remueve el GT911 instanciado via sysfs.
set -euo pipefail

ADDR="${1:-0x5d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR='$ADDR' bash -s" << 'REMOTE_EOF'
set -e
echo "$SSHPASS_REMOTE" | sudo -S -v
echo "$ADDR" | sudo tee /sys/bus/i2c/devices/i2c-0/delete_device
echo "Unbind OK para $ADDR"
REMOTE_EOF
