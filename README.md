# Arduino UNO Q + GIGA Display Shield — soporte completo

Soporte del **Arduino GIGA Display Shield** (ASX00039) — panel DSI 480×800 + touch GT911 — sobre el **Arduino UNO Q** (ABX00162, Qualcomm QRB2210) en Linux.

## Estado actual

| | Kernel 6.16.7 | Kernel 7.0.0 |
|---|---|---|
| Display DSI 480×800 | ✓ funciona con DTB del paquete oficial + GPIO flags corregidos | ✓ funciona con módulo `panel-sitronix-st7701.ko` parchado |
| Touch GT911 (I2C 0x14) | ✓ funciona con `goodix_ts.ko` original + DT con flags GPIO correctos | ✓ idem |
| Cursor X11 calibrado | ✓ rotación landscape "right" + matriz de calibración | ✓ idem |

Solo se necesita correr **un script** en el device para habilitar todo.

## Uso rápido (community)

En una UNO Q virgen con la imagen Arduino oficial (kernel 7.0.0 default; 6.16.7 también pre-instalado):

```bash
# Copiar el package al device (via SSH propio, adb push, o USB stick):
scp scripts/{enable-gigadisplay-shield.sh,gigadisplay-shield.dtso,panel-sitronix-st7701.ko} arduino@<IP>:/tmp/

# En el device, ejecutar:
ssh arduino@<IP>
cd /tmp
chmod +x enable-gigadisplay-shield.sh
./enable-gigadisplay-shield.sh
```

Pide sudo una vez al inicio. Hace todo automáticamente (~1 minuto + reboot). Después del reboot, el display muestra el escritorio y el touch funciona en X11.

Para revertir todo: `./enable-gigadisplay-shield.sh --revert`.

Para verificar que todo está activo tras el reboot:
```bash
./validate-gigadisplay-shield.sh
```
Imprime un reporte por componente (kernel, módulos, DSI panel, GT911 touch, IRQs, X11) con ✓ / ✗ por cada check.

## Cómo funciona

El script `enable-gigadisplay-shield.sh`:
1. Instala un módulo `panel-sitronix-st7701.ko` parchado que reintroduce el descriptor del panel del GIGA shield (Arduino lo removió del driver en kernel 7.0.0).
2. Compila el overlay `gigadisplay-shield.dtso` con `dtc` y lo aplica con `fdtoverlay` sobre el DTB base del kernel 7.0.0. El overlay declara el panel y el chip touch GT911 con los GPIO flags correctos.
3. Edita el boot loader entry de systemd-boot para cargar el DTB compuesto.
4. Instala xorg snippets (`/etc/X11/xorg.conf.d/`) para rotación landscape y calibración del touch.
5. Reinicia.

Para entender el porqué del módulo parchado y los detalles del bug original de los GPIO flags, ver [`docs/HANDOFF.md`](docs/HANDOFF.md) §12 y §13.

## Para developers

Si Arduino actualiza el kernel 7.0.0 y la imagen pre-instalada cambia de commit SHA, el vermagic del `.ko` shipped en el repo dejará de matchear. Para regenerar:

```bash
# En la PC dev (necesita gcc-aarch64-linux-gnu, libelf-dev, etc.):
export SSHPASS='<password-del-uno-q>'
export UNOQ_IP='<IP-del-uno-q>'
./scripts/build-st7701-patched-ko.sh
```

Tarda 20-40 minutos. Output: `scripts/panel-sitronix-st7701.ko` actualizado.

## Archivos importantes

- `scripts/enable-gigadisplay-shield.sh` — bootstrap principal (corre on-device)
- `scripts/gigadisplay-shield.dtso` — device-tree overlay para el shield
- `scripts/panel-sitronix-st7701.ko` — módulo kernel parchado (binario)
- `scripts/validate-gigadisplay-shield.sh` — diagnóstico post-bootstrap
- `scripts/build-st7701-patched-ko.sh` — helper para devs (rebuild del módulo)
- `docs/HANDOFF.md` — documento técnico extenso con el análisis completo del bug, los caminos que probamos, y por qué hay un módulo parchado

## Hardware

- **Arduino UNO Q** (ABX00162) — Qualcomm QRB2210, 2GB RAM, eMMC, Debian 13
- **Arduino GIGA Display Shield** (ASX00039) — DSI 480×800 panel ST7701 + touch GT911 + IMU + audio + microSD

Sin level shifter — el bus I2C opera a 1.9V swing marginal pero empíricamente funciona con cableado corto. Conexión manual entre el shield y los pines JMEDIA del UNO Q (ver §4 del HANDOFF.md para tabla de cableado).

## Licencia

Patches al kernel: GPL-2.0+ OR BSD-3-Clause (igual al driver original).
Scripts: ver headers individuales.
