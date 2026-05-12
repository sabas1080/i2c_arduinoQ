#!/usr/bin/env bash
# Bind manual del GT911 via sysfs. Imprime el evdev creado.
# Argumento opcional: direccion I2C (default 0x5d).
set -euo pipefail

ADDR="${1:-0x5d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR='$ADDR' bash -s" << 'REMOTE_EOF'
set -e
echo "=== cargar modulo goodix_ts ==="
echo "$SSHPASS_REMOTE" | sudo -S modprobe goodix_ts
lsmod | grep -E '^goodix' || true

# Cachear credenciales de sudo para los siguientes comandos
echo "$SSHPASS_REMOTE" | sudo -S -v

echo
echo "=== sysfs new_device gt911 $ADDR ==="
echo "gt911 $ADDR" | sudo tee /sys/bus/i2c/devices/i2c-0/new_device

# wait for bind
sleep 1

echo
echo "=== dmesg last 30 lines ==="
sudo dmesg | tail -30 | grep -iE 'goodix|input|i2c' || true

echo
echo "=== input devices con 'Goodix' ==="
grep -A4 -i goodix /proc/bus/input/devices || echo "NO encontrado"

echo
echo "=== /dev/input/event* ==="
ls -l /dev/input/event* 2>&1
REMOTE_EOF
