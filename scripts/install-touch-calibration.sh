#!/usr/bin/env bash
# Instala el snippet xorg.conf.d que calibra el touch GT911 para el display
# DSI-1 rotado "right" en el UNO Q. Matriz derivada empiricamente capturando
# las 4 esquinas con evtest (ver notes/calibration-corners-*.txt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF'
set -e
echo "$SSHPASS_REMOTE" | sudo -S -v

TMP=$(mktemp)
cat > "$TMP" <<XORGEOF
# Calibracion empirica del touch GT911 sobre display DSI-1 rotado "right"
# Derivada de capturar las 4 esquinas con evtest (notes/calibration-corners-*.txt):
#   UL raw(400,70)  UR raw(405,750)  LR raw(25,735)  LL raw(35,45)
#
# IMPORTANTE: estos coeficientes son los CORRECTOS para el daemon Plan A
# (abs_max=479/799, resolucion real del chip). La version anterior usaba
# 5.98 y -11.0 porque fue calibrada cuando el kernel driver reportaba
# abs_max=4095 (default cuando la config era invalida). Esa version causa
# que el cursor solo se mueva en una franja pequena si se aplica al daemon.
#
# Mapeo panel rotado "right":
#   screen_x_norm =  1.175 * (raw_y / 799) - 0.103
#   screen_y_norm = -1.312 * (raw_x / 479) + 1.096
Section "InputClass"
    Identifier "Goodix Touch Calibration"
    MatchProduct "Goodix Capacitive TouchScreen"
    MatchIsTouchscreen "true"
    Option "TransformationMatrix" "0 1.175 -0.103 -1.312 0 1.096 0 0 1"
EndSection
XORGEOF

sudo install -m 0644 "$TMP" /etc/X11/xorg.conf.d/20-goodix-touch.conf
rm -f "$TMP"

echo "=== snippet escrito ==="
cat /etc/X11/xorg.conf.d/20-goodix-touch.conf

echo
echo "=== restart lightdm para que X recargue la config ==="
sudo systemctl restart lightdm
echo "DONE"
REMOTE_EOF
