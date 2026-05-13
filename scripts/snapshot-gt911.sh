#!/usr/bin/env bash
# Captura estado completo del GT911 + driver + IRQ para comparar entre momentos.
# Uso: ./snapshot-gt911.sh <etiqueta>   (ej. "post-cold-boot", "working", "broken")
#
# IMPORTANTE: hace unbind del driver para poder leer I2C raw. El rebind manual
# tras esto suele fallar con "irq type mismatch" — se necesita reboot completo
# para volver al estado driver-bound funcional.
set -euo pipefail

LABEL="${1:-snapshot}"
TS=$(date +%Y%m%d-%H%M%S)
REMOTE_OUT="/tmp/snapshot-${TS}-${LABEL}.txt"
LOCAL_OUT="/home/sabas/Documents/electroniccats/i2c_arduinoQ/notes/snapshot-${TS}-${LABEL}.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Snapshot $LABEL ($TS) ==="

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' LABEL='$LABEL' TS='$TS' bash -s" << 'REMOTE_EOF'
set +e  # no abortar en errores
OUT=/tmp/snapshot-${TS}-${LABEL}.txt
echo "$SSHPASS_REMOTE" | sudo -S -v 2>/dev/null

{
  echo "==== SNAPSHOT: $LABEL ===="
  echo "Timestamp: $(date -Iseconds)"
  echo "Uptime: $(uptime)"
  echo
  echo "==== [1] DRIVER STATE ===="
  echo "i2c-0 children:"
  ls /sys/bus/i2c/devices/i2c-0/ | head
  echo
  echo "Driver bound al cliente 0-0014:"
  readlink /sys/bus/i2c/devices/i2c-0/0-0014/driver 2>&1
  echo
  echo "i2cdetect bus 0:"
  /usr/sbin/i2cdetect -y -r 0 2>&1 | head -10

  echo
  echo "==== [2] /proc/interrupts ===="
  cat /proc/interrupts | grep gt911 || echo "NO gt911 IRQ"

  echo
  echo "==== [3] dmesg (goodix/0-0014/hwirq) ===="
  sudo dmesg | grep -iE "goodix|0-0014|hwirq-98" | tail -20

  echo
  echo "==== [4] xorg.conf.d ===="
  ls -la /etc/X11/xorg.conf.d/
  cat /etc/X11/xorg.conf.d/20-goodix-touch.conf 2>/dev/null || echo "no calibration snippet"

  echo
  echo "==== [5] UNBIND para leer chip raw ===="
  echo "0-0014" | sudo tee /sys/bus/i2c/drivers/Goodix-TS/unbind 2>&1
  sleep 0.5
  echo "i2cdetect bus 0 tras unbind:"
  /usr/sbin/i2cdetect -y -r 0 2>&1 | head -10

  echo
  echo "==== [6] Chip Product ID (0x8140-0x8146) ===="
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x40 r7 2>&1

  echo
  echo "==== [7] Status 0x814E ===="
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x4e r1 2>&1

  echo
  echo "==== [8] Touch point 1 (0x8150-0x8157) ===="
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x50 r8 2>&1

  echo
  echo "==== [9] Config table COMPLETA 0x8047-0x80FE ===="
  # Leer en chunks de 32 bytes
  for offset in 0x47 0x67 0x87 0xa7 0xc7 0xe7; do
    printf "  0x80%s: " "$offset"
    /usr/sbin/i2ctransfer -y 0 w2@0x14 0x80 $offset r32 2>&1
  done
  echo "  Checksum byte (0x80FF):"
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x80 0xFF r1 2>&1
  echo "  Config update flag (0x8100):"
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x00 r1 2>&1

  echo
  echo "==== [10] gpiomon GPIO_98 (5s) ===="
  echo "Capturando flancos descendentes en INT durante 5s (no toques pantalla):"
  sudo timeout 5 gpiomon -e falling --num-events 200 --chip gpiochip1 98 2>&1 | head -25
  echo
  echo "Total flancos en 5s:"
  sudo timeout 5 gpiomon -e falling --num-events 1000 --chip gpiochip1 98 2>&1 | grep -c falling || echo 0

  echo
  echo "==== [11] Intentar rebind ===="
  echo "0-0014" | sudo tee /sys/bus/i2c/drivers/Goodix-TS/bind 2>&1
  sleep 1
  echo "Resultado dmesg:"
  sudo dmesg | tail -5

  echo
  echo "==== FIN SNAPSHOT ===="
} > $OUT 2>&1

echo "Snapshot guardado en $OUT"
cat $OUT | head -100
REMOTE_EOF

echo
echo "=== Pulling snapshot a $LOCAL_OUT ==="
sshpass -e scp -o StrictHostKeyChecking=accept-new arduino@192.168.0.105:$REMOTE_OUT $LOCAL_OUT 2>&1
echo "Local: $LOCAL_OUT"
