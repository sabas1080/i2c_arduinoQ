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
# Derivada de capturar las 4 esquinas con evtest:
#   UL raw(400,70)  UR raw(405,750)  LR raw(25,735)  LL raw(35,45)
# Mapeo: norm_screen_X =  5.98 * norm_in_y - 0.083
#        norm_screen_Y = -11.0 * norm_in_x + 1.081
# Los coeficientes son grandes porque el driver reporta abs-max 4095 pero el
# chip solo usa hasta ~480 X / ~800 Y.
Section "InputClass"
    Identifier "Goodix Touch Calibration"
    MatchProduct "Goodix Capacitive TouchScreen"
    MatchIsTouchscreen "true"
    Option "TransformationMatrix" "0 5.98 -0.083 -11.0 0 1.081 0 0 1"
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
