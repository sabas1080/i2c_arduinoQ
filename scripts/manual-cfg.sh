#!/usr/bin/env bash
# Configuracion MANUAL del GT911 via I2C. Sin tocar firmware files.
# Permite iterar bytes hasta encontrar la combinacion que hace que el chip
# emita INT solo en touches (no continuamente, no nunca).
#
# Uso:
#   ./manual-cfg.sh read           - lee config actual del chip
#   ./manual-cfg.sh write <file>   - escribe config desde archivo (186 bytes)
#   ./manual-cfg.sh poll <secs>    - monitor gpiomon INT con polling de touches
#   ./manual-cfg.sh unbind         - desbinda el driver para liberar I2C
#   ./manual-cfg.sh status         - estado del driver, IRQ, dmesg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-status}"

run_remote() {
  "$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s"
}

case "$CMD" in
  status)
    run_remote << 'REMOTE_EOF'
echo "$SSHPASS_REMOTE" | sudo -S -v
echo "=== bound? ==="; ls /sys/bus/i2c/devices/i2c-0/ | grep 0014 || echo "NO"
echo "=== driver ==="; readlink /sys/bus/i2c/devices/i2c-0/0-0014/driver 2>/dev/null || echo "N/A"
echo "=== IRQ ==="; cat /proc/interrupts | grep gt911 || echo "no IRQ"
echo "=== dmesg ==="; sudo dmesg | grep -iE 'goodix|0-0014|hwirq' | tail -8
REMOTE_EOF
    ;;
  unbind)
    run_remote << 'REMOTE_EOF'
echo "$SSHPASS_REMOTE" | sudo -S -v
echo "0-0014" | sudo tee /sys/bus/i2c/drivers/Goodix-TS/unbind 2>&1
sleep 0.5
/usr/sbin/i2cdetect -y -r 0 | head -5
REMOTE_EOF
    ;;
  read)
    run_remote << 'REMOTE_EOF'
echo "$SSHPASS_REMOTE" | sudo -S -v
echo "=== config 0x8047-0x80FE (184 bytes) ==="
for off in 0x47 0x67 0x87 0xa7 0xc7 0xe7; do
  printf "0x80%s: " "$off"
  /usr/sbin/i2ctransfer -y 0 w2@0x14 0x80 $off r32 2>&1
done
echo "checksum 0x80FF:"; /usr/sbin/i2ctransfer -y 0 w2@0x14 0x80 0xFF r1
echo "config_fresh 0x8100:"; /usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x00 r1
echo "version byte 0x8047:"; /usr/sbin/i2ctransfer -y 0 w2@0x14 0x80 0x47 r1
REMOTE_EOF
    ;;
  write)
    FILE="$2"
    sshpass -e scp -o StrictHostKeyChecking=accept-new "$FILE" arduino@192.168.0.XXX:/tmp/cfg.bin 2>&1
    run_remote << 'REMOTE_EOF'
echo "$SSHPASS_REMOTE" | sudo -S -v
# Construir los comandos i2ctransfer en shell, NO en Python (problema con TTY/sudo)
python3 << 'PYEOF' > /tmp/cfg-write.sh
import sys
with open("/tmp/cfg.bin", "rb") as f:
    data = f.read()
assert len(data) == 186

addr_base = 0x8047
cfg = data[:184]
print("#!/bin/bash")
print("set -e")
for off in range(0, 184, 32):
    chunk = cfg[off:off+32]
    reg = addr_base + off
    args = [f"0x{(reg>>8)&0xff:02x}", f"0x{reg&0xff:02x}"] + [f"0x{b:02x}" for b in chunk]
    print(f"sudo /usr/sbin/i2ctransfer -y 0 w{2+len(chunk)}@0x14 {' '.join(args)} || exit 1")
    print(f"echo '  ok 0x{reg:04x} ({len(chunk)} bytes)'")
print(f"sudo /usr/sbin/i2ctransfer -y 0 w3@0x14 0x80 0xff 0x{data[184]:02x}")
print(f"echo '  ok checksum 0x{data[184]:02x} -> 0x80FF'")
print(f"sudo /usr/sbin/i2ctransfer -y 0 w3@0x14 0x81 0x00 0x{data[185]:02x}")
print(f"echo '  ok config_fresh 0x{data[185]:02x} -> 0x8100'")
PYEOF
chmod +x /tmp/cfg-write.sh
bash /tmp/cfg-write.sh
echo "Config escrita."
REMOTE_EOF
    ;;
  poll)
    SECS="${2:-15}"
    run_remote << REMOTE_EOF
echo "\$SSHPASS_REMOTE" | sudo -S -v
echo "=== gpiomon INT $SECS s ==="
sudo timeout $SECS gpiomon -e falling --num-events 200 --chip gpiochip1 98 2>&1 | head -50
echo
echo "=== status reg cada 500ms durante $SECS s ==="
end=\$((\$(date +%s) + $SECS))
while [ \$(date +%s) -lt \$end ]; do
  s=\$(/usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x4e r1 2>&1)
  if [ "\$s" != "0x00" ]; then
    p=\$(/usr/sbin/i2ctransfer -y 0 w2@0x14 0x81 0x50 r5 2>&1)
    echo "\$(date +%T.%3N) status=\$s point1=\$p"
    # ack para liberar el buffer
    /usr/sbin/i2ctransfer -y 0 w3@0x14 0x81 0x4e 0x00 >/dev/null 2>&1
  fi
  sleep 0.2
done
REMOTE_EOF
    ;;
  *)
    echo "Uso: $0 {status|unbind|read|write <file>|poll [secs]}"
    exit 1
    ;;
esac
