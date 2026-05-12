#!/usr/bin/env bash
# Inyecta el nodo gt911@N bajo i2c@4a80000 del DTB activo del UNO Q usando fdtput.
# Idempotente: si el nodo ya existe lo sobreescribe.
#
# Args (opcionales):
#   $1 = direccion I2C en hex (default 0x14)
#   $2 = compatible string (default goodix,gt911)
#   $3 = GPIO num para IRQ (default 98)
#   $4 = GPIO num para RST (default 18)
set -euo pipefail

ADDR_HEX="${1:-0x14}"
COMPATIBLE="${2:-goodix,gt911}"
IRQ_GPIO_NUM="${3:-98}"
RST_GPIO_NUM="${4:-18}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR_HEX='$ADDR_HEX' COMPATIBLE='$COMPATIBLE' IRQ_GPIO='$IRQ_GPIO_NUM' RST_GPIO='$RST_GPIO_NUM' bash -s" << 'REMOTE_EOF'
set -euo pipefail
DTB=/boot/efi/qrb2210-arduino-imola-gigadisplay.dtb
ADDR_SUFFIX=$(echo $ADDR_HEX | sed 's/0x//')
NODE=/soc@0/geniqup@4ac0000/i2c@4a80000/gt911@${ADDR_SUFFIX}

# Cachear sudo
echo "$SSHPASS_REMOTE" | sudo -S -v

echo "=== TLMM phandle ==="
TLMM_PH_HEX=$(fdtget -t x $DTB /soc@0/pinctrl@500000 phandle)
TLMM_PH=$((16#$TLMM_PH_HEX))
echo "TLMM phandle hex: 0x$TLMM_PH_HEX (dec: $TLMM_PH)"

ADDR_INT=$((ADDR_HEX))
echo "Direccion I2C: $ADDR_HEX (dec: $ADDR_INT)"

# IRQ flag: IRQ_TYPE_EDGE_FALLING = 2
# GPIO flag: GPIO_ACTIVE_LOW = 1 (para RST que es active-low en GT911)
IRQ_FLAG=2
RST_FLAG=1

echo
echo "=== creando nodo $NODE (idempotente) ==="
sudo fdtput -c $DTB $NODE 2>/dev/null || echo "(nodo ya existe, OK)"

echo
echo "=== seteando propiedades ==="
sudo fdtput -t s  $DTB $NODE compatible "$COMPATIBLE"
sudo fdtput -t i  $DTB $NODE reg $ADDR_INT
# interrupts-extended <&tlmm IRQ_GPIO IRQ_TYPE_EDGE_FALLING> — necesario para que el
# kernel populate client->irq con un IRQ valido. Sin esto request_threaded_irq devuelve EINVAL.
sudo fdtput -t i  $DTB $NODE interrupts-extended $TLMM_PH $IRQ_GPIO $IRQ_FLAG
# irq-gpios sigue siendo necesario porque el driver lo manipula durante el reset
# (drive INT high/low para seleccionar la direccion I2C del chip)
sudo fdtput -t i  $DTB $NODE irq-gpios   $TLMM_PH $IRQ_GPIO $IRQ_FLAG
sudo fdtput -t i  $DTB $NODE reset-gpios $TLMM_PH $RST_GPIO $RST_FLAG
sudo fdtput -t s  $DTB $NODE status "okay"

echo
echo "=== verificacion (leer de vuelta) ==="
echo "compatible:           $(fdtget -t s $DTB $NODE compatible)"
echo "reg:                  $(fdtget -t i $DTB $NODE reg)"
echo "interrupts-extended:  $(fdtget -t i $DTB $NODE interrupts-extended)"
echo "irq-gpios:            $(fdtget -t i $DTB $NODE irq-gpios)"
echo "reset-gpios:          $(fdtget -t i $DTB $NODE reset-gpios)"
echo "status:               $(fdtget -t s $DTB $NODE status)"

echo
echo "DTB patch DONE. Necesario reboot para que el kernel cargue el cambio."
REMOTE_EOF
