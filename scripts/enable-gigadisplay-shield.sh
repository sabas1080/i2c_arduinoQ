#!/usr/bin/env bash
# enable-gigadisplay-shield.sh — habilita display + touch del Arduino GIGA
# Display Shield (ASX00039) en una Arduino UNO Q (ABX00162) con la imagen
# Arduino oficial, kernel 7.0.0-g122c2c22d838.
#
# === IMPORTANTE ===
# Este script se corre EN EL DEVICE (no en una PC remota). Asume que estás
# logueado en el UNO Q (via SSH propio, adb shell, terminal directa).
#
# Lo que hace (todo en el kernel 7.0.0 actual, sin downgrade):
#   1. Instala un módulo `panel-sitronix-st7701.ko` parchado que contiene el
#      descriptor del panel del GIGA shield (Arduino lo removió en 7.0.0 —
#      este parche lo retorna desde el branch 6.16.7).
#   2. Compila el overlay `gigadisplay-shield.dtso` con dtc.
#   3. Aplica el overlay con fdtoverlay sobre el DTB base de 7.0.0,
#      generando un DTB compuesto que activa el panel DSI + node gt911@14.
#   4. Edita la boot loader entry de 7.0.0 para cargar el DTB compuesto y
#      configurar video=DSI-1:480x800@60.
#   5. Instala xorg snippets: rotación landscape "right" + calibración touch.
#   6. Reboot.
#
# Después del reboot: el panel st7701 inicializa con el descriptor del GIGA,
# y el chip touch GT911 funciona con el kernel driver `goodix_ts.ko` original.
#
# Archivos requeridos junto al script (mismo directorio):
#   - panel-sitronix-st7701.ko    (módulo cross-compilado del kernel parchado)
#   - gigadisplay-shield.dtso     (overlay device-tree source)
#
# Requiere sudo. Pedirá password una vez al inicio.
# Es IDEMPOTENTE: se puede correr varias veces; skipea pasos ya hechos.
#
# Flags:
#   --no-reboot   no reiniciar al final
#   --revert      deshace TODO (restaura módulo original, quita DTB
#                 compuesto, limpia boot entry y xorg snippets, NO reinicia)
#   --help        muestra esta ayuda
#
# Soporte: ver docs/HANDOFF.md §12 / §14 para el análisis completo del bug
# del DTB GPIO flags y por qué se eliminó el descriptor del panel en 7.0.0.

set -euo pipefail

# -------------------- argumentos ---------------------------------------------
DO_REBOOT=1
DO_REVERT=0
for arg in "$@"; do
    case "$arg" in
        --no-reboot) DO_REBOOT=0 ;;
        --revert)    DO_REVERT=1; DO_REBOOT=0 ;;
        --help|-h)
            sed -n 's/^# \?//p' "$0" | sed -n '/^enable-gigadisplay/,/^Soporte:/p'
            exit 0
            ;;
        *)
            echo "ERROR: argumento desconocido: $arg" >&2
            echo "Usa --help para ver opciones." >&2
            exit 2
            ;;
    esac
done

# -------------------- constantes --------------------------------------------
KERNEL_TARGET="7.0.0-g122c2c22d838"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PATCHED_KO="${SCRIPT_DIR}/panel-sitronix-st7701.ko"
OVERLAY_DTSO="${SCRIPT_DIR}/gigadisplay-shield.dtso"

# Paths en el device
MODULES_DIR="/lib/modules/${KERNEL_TARGET}"
KO_TARGET="${MODULES_DIR}/kernel/drivers/gpu/drm/panel/panel-sitronix-st7701.ko"
KO_BACKUP="${KO_TARGET}.original"
BASE_DTB="/usr/lib/linux-image-${KERNEL_TARGET}/qcom/qrb2210-arduino-imola-base.dtb"
COMPOSED_DTB_NAME="qrb2210-arduino-imola-gigadisplay-shield.dtb"
COMPOSED_DTB="/boot/efi/${COMPOSED_DTB_NAME}"
ENTRIES_DIR="/boot/efi/loader/entries"
XORG_MONITOR="/etc/X11/xorg.conf.d/10-monitor.conf"
XORG_TOUCH="/etc/X11/xorg.conf.d/20-goodix-touch.conf"

# -------------------- helpers -----------------------------------------------
section() { echo; echo "==> $*"; echo "----------------------------------------------------------------"; }
info()    { echo "    $*"; }
fail()    { echo "ERROR: $*" >&2; exit 1; }

# -------------------- sanity checks -----------------------------------------
section "Verificación inicial"

if [ ! -f /proc/device-tree/model ] || ! grep -qi "arduino" /proc/device-tree/model 2>/dev/null; then
    fail "este script debe ejecutarse en un Arduino UNO Q (no detecté el board)."
fi
info "Board: $(tr -d '\0' < /proc/device-tree/model)"
KERNEL_RUNNING=$(uname -r)
info "Kernel running: ${KERNEL_RUNNING}"

if [ "$KERNEL_RUNNING" != "$KERNEL_TARGET" ]; then
    fail "kernel running '$KERNEL_RUNNING' ≠ target '$KERNEL_TARGET'. Asegúrate de bootear con el kernel correcto."
fi

if [ "$EUID" -eq 0 ]; then
    fail "no ejecutes como root. Corre como user normal; el script invoca sudo cuando necesite."
fi

info "Pidiendo privilegios sudo…"
sudo -v || fail "no se obtuvo sudo."
( while true; do sudo -nv 2>/dev/null; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT

# Localizar boot entry de 7.0.0
TARGET_ENTRY=$(ls "${ENTRIES_DIR}"/*${KERNEL_TARGET}*.conf 2>/dev/null | head -1) || true
[ -n "$TARGET_ENTRY" ] || fail "no encontré boot loader entry para $KERNEL_TARGET en $ENTRIES_DIR/"
info "Boot entry: $TARGET_ENTRY"

# -------------------- --revert: deshacer todo -------------------------------
if [ "$DO_REVERT" -eq 1 ]; then
    section "REVERT: deshaciendo cambios"

    # Restaurar módulo original
    if [ -f "$KO_BACKUP" ]; then
        sudo mv "$KO_BACKUP" "$KO_TARGET"
        sudo depmod -a
        info "Restaurado módulo original: $KO_TARGET"
    fi

    # Quitar líneas devicetree + video= del boot entry
    if [ -f "$TARGET_ENTRY" ]; then
        sudo sed -i "/^devicetree \/${COMPOSED_DTB_NAME}\$/d" "$TARGET_ENTRY"
        sudo sed -i "s| video=DSI-1:480x800@60 video=DP-1:d||" "$TARGET_ENTRY"
        info "Limpiado boot entry $TARGET_ENTRY"
    fi

    # Borrar DTB compuesto
    sudo rm -f "$COMPOSED_DTB"
    info "Removido $COMPOSED_DTB"

    # Borrar xorg snippets
    sudo rm -f "$XORG_MONITOR" "$XORG_TOUCH"
    info "Removidos xorg snippets"

    section "REVERT completo. Reinicia manualmente para volver al estado previo."
    exit 0
fi

# -------------------- prerequisitos para enable -----------------------------
[ -f "$PATCHED_KO" ] || fail "no encontré $PATCHED_KO — el módulo cross-compilado tiene que estar junto al script."
[ -f "$OVERLAY_DTSO" ] || fail "no encontré $OVERLAY_DTSO — el overlay source tiene que estar junto al script."
[ -f "$BASE_DTB" ] || fail "no encontré $BASE_DTB — el package linux-image-${KERNEL_TARGET} puede estar incompleto."

for cmd in dtc fdtoverlay fdtput fdtget; do
    command -v "$cmd" >/dev/null || fail "comando '$cmd' no encontrado en PATH"
done
info "Tools OK (dtc, fdtoverlay, fdtput, fdtget)"

# Backup automático de la boot entry
BACKUP_ENTRY="${TARGET_ENTRY}.backup-pre-gigadisplay"
if [ ! -f "$BACKUP_ENTRY" ]; then
    sudo cp "$TARGET_ENTRY" "$BACKUP_ENTRY"
    info "Backup de boot entry: $BACKUP_ENTRY"
fi

# -------------------- FASE 1: instalar módulo parchado ----------------------
section "FASE 1: instalar módulo panel-sitronix-st7701.ko parchado"

# Backup del .ko original (idempotente)
if [ ! -f "$KO_BACKUP" ] && [ -f "$KO_TARGET" ]; then
    sudo cp "$KO_TARGET" "$KO_BACKUP"
    info "1.1 Backup del .ko original: $KO_BACKUP"
fi

sudo cp "$PATCHED_KO" "$KO_TARGET"
sudo chown root:root "$KO_TARGET"
sudo chmod 644 "$KO_TARGET"
info "1.2 Instalado .ko parchado en $KO_TARGET"
info "    md5: $(md5sum "$KO_TARGET" | cut -d' ' -f1)"

sudo depmod -a
info "1.3 depmod -a OK"

# -------------------- FASE 2: compilar overlay y componer DTB ---------------
section "FASE 2: compilar overlay + componer DTB"

TMP_DTBO=$(mktemp --suffix=.dtbo)
TMP_OUT=$(mktemp --suffix=.dtb)
trap "rm -f '$TMP_DTBO' '$TMP_OUT'; kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT

# 2.1 compilar dtso → dtbo
dtc -I dts -O dtb -o "$TMP_DTBO" "$OVERLAY_DTSO" 2>&1 | grep -v "^$" || true
[ -s "$TMP_DTBO" ] || fail "dtc no produjo overlay binario"
info "2.1 Overlay compilado: $(stat -c%s "$TMP_DTBO") bytes"

# 2.2 aplicar overlay sobre base DTB
fdtoverlay -i "$BASE_DTB" -o "$TMP_OUT" "$TMP_DTBO" 2>&1 | grep -v "^$" || true
[ -s "$TMP_OUT" ] || fail "fdtoverlay falló al componer DTB"
info "2.2 DTB compuesto: $(stat -c%s "$TMP_OUT") bytes"

# 2.3 mover DTB compuesto a /boot/efi/
sudo install -m 0644 "$TMP_OUT" "$COMPOSED_DTB"
info "2.3 DTB compuesto instalado en $COMPOSED_DTB"

# 2.4 verificar que el gt911 node está en el DTB compuesto (path-agnóstico)
if sudo dtc -I dtb -O dts "$COMPOSED_DTB" 2>/dev/null | grep -qE "compatible[[:space:]]*=[[:space:]]*\"goodix,gt911\""; then
    info "    gt911 node OK en DTB compuesto"
else
    info "    WARNING: no encontré gt911 en el DTB compuesto (verificar manualmente con dtc -I dtb -O dts $COMPOSED_DTB)"
fi
if sudo dtc -I dtb -O dts "$COMPOSED_DTB" 2>/dev/null | grep -qE "compatible[[:space:]]*=[[:space:]]*\"arduino,giga-display\""; then
    info "    panel arduino,giga-display OK en DTB compuesto"
else
    info "    WARNING: panel arduino,giga-display no aparece en DTB"
fi

# -------------------- FASE 3: editar boot entry -----------------------------
section "FASE 3: editar boot entry de $KERNEL_TARGET"

if grep -q "^devicetree /${COMPOSED_DTB_NAME}\$" "$TARGET_ENTRY"; then
    info "3.1 'devicetree' ya está en boot entry (skip)"
else
    # Quitar primero cualquier línea devicetree previa que apunte a otro DTB
    sudo sed -i '/^devicetree /d' "$TARGET_ENTRY"
    echo "devicetree /${COMPOSED_DTB_NAME}" | sudo tee -a "$TARGET_ENTRY" >/dev/null
    info "3.1 'devicetree /${COMPOSED_DTB_NAME}' añadido a boot entry"
fi

if grep -q 'video=DSI-1' "$TARGET_ENTRY"; then
    info "3.2 'video=DSI-1' ya en options (skip)"
else
    sudo sed -i 's|^\(options[[:space:]].*\)$|\1 video=DSI-1:480x800@60 video=DP-1:d|' "$TARGET_ENTRY"
    info "3.2 'video=DSI-1:480x800@60 video=DP-1:d' añadido a options"
fi

# -------------------- FASE 4: instalar xorg snippets ------------------------
section "FASE 4: xorg snippets (rotación + calibración touch)"

sudo mkdir -p /etc/X11/xorg.conf.d/

sudo tee "$XORG_MONITOR" >/dev/null <<'XORG_MONITOR_EOF'
# Display del GIGA Display Shield rotado landscape "right".
# Para rotación contraria usar "left".
# Definimos ambos DSI-1 y DP-1 porque el kernel puede exponer el conector con
# distinto nombre según la versión del DRM driver.
Section "Monitor"
    Identifier "DSI-1"
    Option "Rotate" "right"
EndSection

Section "Monitor"
    Identifier "DP-1"
    Option "Rotate" "right"
EndSection

Section "Device"
    Identifier "Card0"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Card0"
EndSection
XORG_MONITOR_EOF
info "4.1 $XORG_MONITOR instalado"

sudo tee "$XORG_TOUCH" >/dev/null <<'XORG_TOUCH_EOF'
# Calibración del touch GT911 para el display DSI-1 rotado "right".
# Matriz derivada empíricamente capturando 4 esquinas con evtest, normalizada
# al abs_max=479/799 del chip GT911.
Section "InputClass"
    Identifier "Goodix Touch Calibration"
    MatchProduct "Goodix Capacitive TouchScreen"
    MatchIsTouchscreen "true"
    Option "TransformationMatrix" "0 1.175 -0.103 -1.312 0 1.096 0 0 1"
EndSection
XORG_TOUCH_EOF
info "4.2 $XORG_TOUCH instalado"

# -------------------- final -------------------------------------------------
section "Configuración completa"
info "Cambios aplicados:"
info "  ✓ módulo parchado panel-sitronix-st7701.ko en $KO_TARGET"
info "  ✓ DTB compuesto (base + overlay GIGA) en $COMPOSED_DTB"
info "  ✓ boot entry $TARGET_ENTRY editado (devicetree + video=DSI-1)"
info "  ✓ $XORG_MONITOR (rotación landscape)"
info "  ✓ $XORG_TOUCH (calibración)"
echo
info "Backup del boot entry original: $BACKUP_ENTRY"
info "Backup del módulo original:     $KO_BACKUP"
info "Para revertir TODO: $0 --revert"

if [ "$DO_REBOOT" -eq 1 ]; then
    echo
    info "Reiniciando en 5 segundos para que los cambios tomen efecto…"
    info "(Ctrl+C para cancelar; podrás reiniciar manualmente con 'sudo reboot')"
    sleep 5
    sudo reboot
else
    echo
    info "--no-reboot especificado. Reinicia manualmente con 'sudo reboot' para activar los cambios."
fi
