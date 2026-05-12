#!/usr/bin/env bash
# Verifica que el GT911 responde en i2c-0. Lee Product ID (debe ser "911\0").
# Si i2cdetect ve mas direcciones (BMI270 IMU, IS31FL3197 LED driver), tambien
# las lista — eso confirma que el shield tiene bus I2C compartido.
set -euo pipefail

OUT="${1:-/dev/stdout}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF' | tee "$OUT"
set -e
echo "=== i2cdetect -y 0 (todas las direcciones detectadas) ==="
SCAN=$(/usr/sbin/i2cdetect -y -r 0 2>&1)
echo "$SCAN"

echo
echo "=== resumen detectado ==="
echo "$SCAN" | awk 'NR>1 { for(i=2; i<=NF; i++) if($i ~ /^[0-9a-f][0-9a-f]$/) print "  0x"$i }'

echo
echo "=== identificar GT911 ==="
if echo "$SCAN" | grep -qE '\b5d\b'; then
  ADDR=0x5d
elif echo "$SCAN" | grep -qE '\b14\b'; then
  ADDR=0x14
else
  echo "ERROR: GT911 no detectado en 0x5d ni 0x14."
  exit 1
fi
echo "GT911 detectado en $ADDR"

echo
echo "=== Product ID (regs 0x8140-0x8143, esperado '911\\0') ==="
/usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x40 r4

echo
echo "=== Firmware Version (0x8144-0x8145) ==="
/usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x44 r2

echo
echo "=== Resolution X/Y (0x8146-0x8149, little-endian uint16) ==="
/usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x46 r4

echo
echo "DONE_OK ADDR=$ADDR"
REMOTE_EOF
