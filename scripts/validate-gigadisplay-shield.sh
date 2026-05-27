#!/usr/bin/env bash
# validate-gigadisplay-shield.sh — verifica que el setup del GIGA Display
# Shield en el UNO Q está activo y funcionando.
#
# Se corre EN EL DEVICE después de un reboot tras correr
# enable-gigadisplay-shield.sh. Imprime un reporte de cada componente:
# kernel, módulo del panel, DSI panel detection, gt911 driver, IRQs, X11.
#
# Uso: ./validate-gigadisplay-shield.sh
# No requiere sudo para los checks read-only; sí lo pide para dmesg/journalctl.

set -u

PASS=0
FAIL=0

ok()    { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()   { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
warn()  { echo "  ⚠ $*"; }
info()  { echo "    $*"; }
hdr()   { echo; echo "==> $*"; }

# ------------------------- 1. board + kernel --------------------------------
hdr "1. Identificación del board y kernel"

if [ -f /proc/device-tree/model ]; then
    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    case "$MODEL" in
        *Arduino*) ok "Board: $MODEL" ;;
        *) bad "Board NO es Arduino: $MODEL" ;;
    esac
else
    bad "/proc/device-tree/model no existe"
fi

KERNEL=$(uname -r)
info "Kernel: $KERNEL"
case "$KERNEL" in
    6.16.7-g0dd6551ae96b) ok "kernel 6.16.7 reconocido" ;;
    7.0.0-g122c2c22d838) ok "kernel 7.0.0 reconocido" ;;
    *) warn "kernel '$KERNEL' no es uno conocido (¿Arduino actualizó la imagen?)" ;;
esac

# ------------------------- 2. módulos del kernel ----------------------------
hdr "2. Módulos del kernel"

if lsmod | grep -q "^panel_sitronix_st7701"; then
    ok "panel-sitronix-st7701 cargado"
else
    bad "panel-sitronix-st7701 NO cargado"
fi

if lsmod | grep -q "^goodix_ts"; then
    ok "goodix_ts cargado"
else
    bad "goodix_ts NO cargado (touch driver)"
fi

# ------------------------- 3. DSI panel detection ---------------------------
hdr "3. DSI panel"

if [ -d /sys/class/drm/card0-DSI-1 ]; then
    STATUS=$(cat /sys/class/drm/card0-DSI-1/status 2>/dev/null)
    if [ "$STATUS" = "connected" ]; then
        ok "card0-DSI-1: connected"
        MODES=$(cat /sys/class/drm/card0-DSI-1/modes 2>/dev/null | head -1)
        info "Modo activo: $MODES"
    else
        bad "card0-DSI-1 existe pero status='$STATUS'"
    fi
elif [ -d /sys/class/drm/card0-DP-1 ]; then
    STATUS=$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null)
    warn "Connector aparece como DP-1 (no DSI-1) — status='$STATUS'"
    info "Si el display funciona, ajustar 10-monitor.conf para usar DP-1"
else
    bad "Ningún connector DSI-1 ni DP-1 en /sys/class/drm/"
    info "Conectores presentes: $(ls /sys/class/drm/ 2>/dev/null | grep card | head)"
fi

# ------------------------- 4. touch chip GT911 ------------------------------
hdr "4. Touch chip GT911"

if [ -L /sys/bus/i2c/devices/0-0014/driver ]; then
    DRV=$(basename "$(readlink /sys/bus/i2c/devices/0-0014/driver)")
    ok "Chip 0x14 bound a driver: $DRV"
else
    bad "Chip 0x14 en bus i2c-0 NO está bound a ningún driver"
fi

if grep -q gt911 /proc/interrupts 2>/dev/null; then
    IRQS=$(awk '/gt911/ {sum=$2+$3+$4+$5; print sum}' /proc/interrupts)
    ok "/proc/interrupts gt911 registrado, count = $IRQS"
    [ "$IRQS" -eq 0 ] 2>/dev/null && info "(0 IRQs aún — toca la pantalla para subir el contador)"
else
    bad "Sin entry 'gt911' en /proc/interrupts"
fi

if [ -e /dev/input/event2 ]; then
    NAME=$(cat /sys/class/input/event2/device/name 2>/dev/null)
    case "$NAME" in
        Goodix*) ok "Input device event2: $NAME" ;;
        *) warn "event2 existe pero no es Goodix: $NAME" ;;
    esac
fi

# ------------------------- 5. config files instalados -----------------------
hdr "5. Configuración instalada"

[ -f /etc/X11/xorg.conf.d/10-monitor.conf ] && ok "10-monitor.conf instalado" || warn "10-monitor.conf NO instalado (rotación X11 puede no estar)"
[ -f /etc/X11/xorg.conf.d/20-goodix-touch.conf ] && ok "20-goodix-touch.conf instalado" || warn "20-goodix-touch.conf NO instalado (calibración X11 ausente)"

ENTRY=$(ls /boot/efi/loader/entries/*${KERNEL}*.conf 2>/dev/null | head -1)
if [ -n "$ENTRY" ] && grep -q "^devicetree " "$ENTRY"; then
    DTB=$(grep "^devicetree " "$ENTRY" | awk '{print $2}')
    ok "Boot entry tiene devicetree: $DTB"
    [ -f "/boot/efi${DTB}" ] && ok "DTB existe en /boot/efi" || bad "DTB referenciado no existe: /boot/efi${DTB}"
else
    warn "Boot entry NO tiene 'devicetree' line — display puede no inicializar"
fi

# ------------------------- 6. X11 -------------------------------------------
hdr "6. X11"

if systemctl is-active lightdm >/dev/null 2>&1; then
    ok "lightdm activo"
else
    warn "lightdm NO activo (puede que estés en consola)"
fi

if pgrep -x Xorg >/dev/null; then
    ok "Xorg corriendo"
else
    warn "Xorg NO corriendo"
fi

# ------------------------- resumen ------------------------------------------
hdr "Resumen"
echo "  PASS: $PASS    FAIL: $FAIL"
echo
if [ "$FAIL" -eq 0 ]; then
    echo "  Todo OK. Toca la pantalla y verifica visualmente que el cursor sigue al dedo."
    exit 0
else
    echo "  Hay errores. Revisa la salida arriba y consulta docs/HANDOFF.md §13."
    exit 1
fi
