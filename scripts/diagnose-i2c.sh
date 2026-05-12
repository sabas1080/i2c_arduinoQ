#!/usr/bin/env bash
# Volcado de estado I2C del UNO Q. Se ejecuta local; usa remote-ssh.sh.
# Uso: ./scripts/diagnose-i2c.sh [archivo_salida]
set -euo pipefail

OUT="${1:-/dev/stdout}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF' | tee "$OUT"
echo "=== uname ==="; uname -a
echo
echo "=== /dev/i2c-* ==="; ls -l /dev/i2c-* 2>&1
echo
echo "=== i2cdetect -l ==="; /usr/sbin/i2cdetect -l 2>&1 || true
echo
echo "=== i2c-0 (libre, candidato) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 0 2>&1 || true
echo
echo "=== i2c-1 (display, referencia) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 1 2>&1 || true
echo
echo "=== pinmux activo (GPIO 0..30, 82, 86, 98..100) ==="
echo "$SSHPASS_REMOTE" | sudo -S cat /sys/kernel/debug/pinctrl/500000.pinctrl/pinmux-pins 2>/dev/null \
  | grep -E "^pin (0|1|2|3|18|22|23|29|30|82|86|98|99|100) "
echo
echo "=== goodix module ==="
/sbin/modinfo goodix_ts 2>&1 | head -5
echo
echo "=== /dev/input/event* ==="; ls -l /dev/input/event* 2>&1 || true
REMOTE_EOF
