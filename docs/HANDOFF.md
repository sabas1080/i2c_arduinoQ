# Handoff — GT911 Touch en Arduino UNO Q + GIGA Display Shield

**Fecha:** 2026-05-13
**Sesión previa:** Claude Opus 4.7 (1M context)
**Estado:** Plan A completo y funcionando. Plan B (kernel patch) pendiente.

---

## 1. Qué se construyó (TL;DR)

Touch del **Goodix GT911** del Arduino GIGA Display Shield (ASX00039) funcionando end-to-end sobre el **Arduino UNO Q (ABX00162)** desde el lado Linux (Qualcomm QRB2210 SoC), con cursor X11 siguiendo el dedo correctamente sobre el display DSI-1 rotado a landscape.

Hardware: UNO Q + shield + cableado manual entre el "display touch connector" del shield y los pines JMEDIA del UNO Q (ver tabla en §4). Sin level shifter — el bus opera a 1.8V/3.3V marginal, funciona empíricamente.

Software: **daemon userspace en Python** que reemplaza al driver kernel `goodix_ts` (que tiene un bug de timing en el reset). Daemon hace I2C polling + uinput injection.

---

## 2. Componentes finales instalados en el UNO Q

| Path | Contenido | Origen en este repo |
|---|---|---|
| `/usr/local/bin/gt911-touch-daemon.py` | Daemon principal | `scripts/gt911-touch-daemon.py` |
| `/etc/systemd/system/gt911-touch.service` | systemd unit (enabled, started) | `scripts/gt911-touch.service` |
| `/etc/modprobe.d/blacklist-goodix.conf` | `blacklist goodix_ts` | inline |
| `/etc/X11/xorg.conf.d/20-goodix-touch.conf` | Matriz de calibración X11 | (replicado en `scripts/install-touch-calibration.sh`) |
| `/boot/efi/qrb2210-arduino-imola-gigadisplay.dtb` | DTB con nodo `gt911@14` añadido | parche via `scripts/patch-dtb.sh` (legado del intento kernel-driver; no afecta al daemon) |

**Importante:** el DTB modificado declara `gt911@14` bajo `i2c@4a80000` con `interrupts-extended`, `irq-gpios`, `reset-gpios`. Con el módulo `goodix_ts` blacklisted, este nodo simplemente queda sin driver — no hace daño y permite volver al camino kernel si en el futuro el bug se patcha. **No revertir el DTB.**

---

## 3. Cómo opera el daemon (resumen técnico)

1. **Reset del chip (Arduino-style)**: replica exacta de la secuencia documentada en GT911 Rev09 y usada por `Arduino_GigaDisplayTouch`:
   ```
   RST=0 + INT=0
   delay 11 ms                  (T1+T2)
   INT=1 (selecciona 0x14)
   delay 110 µs                 (T7)
   RST=1                        release reset
   delay 6 ms                   (T8 — el paso clave que omite el kernel driver)
   INT=0
   delay 51 ms                  (T3)
   INT input
   ```
   Vía `python3-libgpiod` sobre `/dev/gpiochip1` líneas 18 (RST) y 98 (INT).

2. **Polling cada 10 ms** del registro `0x814E` del chip vía `python3-smbus2` sobre `/dev/i2c-0` (controlador qup0 GENI del SoC). Si bit 7 = data ready:
   - Lee `0x814F + 8*N` bytes (track_id, X_lo, X_hi, Y_lo, Y_hi, area_lo, area_hi, reserved) por cada touch
   - Importante: **el track_id está en 0x814F, las coords arrancan en 0x8150**. Off-by-one bug que cometimos en versiones tempranas.

3. **Inyecta eventos** a `/dev/uinput` vía `python3-evdev` como device multitouch con name "Goodix Capacitive TouchScreen (userspace daemon)", ABS_MAX=479 (X) y 799 (Y), 5 slots, BTN_TOUCH + ABS_MT_*.

4. **systemd** reinicia el daemon ante crash, hace `ExecStartPre` para desbindear el driver kernel si por algún motivo se había quedado bound.

---

## 4. Cableado físico (no tocar)

| Señal shield | JMEDIA pin UNO Q | Función SoC | Voltaje |
|---|---|---|---|
| SDA touch (D102) | **39** | GPIO_1 = qup0 SDA | 1.8V |
| SCL touch (D101) | **37** | GPIO_0 = qup0 SCL | 1.8V |
| RST touch | **49** | GPIO_18 | 1.8V |
| INT touch | **46** | GPIO_98 | 1.8V |
| 3V3 shield | **58** o **60** | +3V3 | — |
| GND | varios | — | — |

**Sutileza:** la asignación SDA/SCL dentro del grupo qup0 va **al revés** de lo que sugiere el orden de pinmux. Verificado empíricamente con osciloscopio: GPIO_0 es el reloj (SCL), GPIO_1 son los datos (SDA). Si alguien intercambia los pines en una nueva placa, intercambiarlos también aquí.

---

## 5. Por qué NO usamos el driver kernel `goodix_ts`

El driver mainline `drivers/input/touchscreen/goodix.c` implementa la secuencia de reset así:
```c
gpiod_direction_output(rst, 0);     // RST low
msleep(20);                          // T2
goodix_irq_direction_output(int, X); // INT high/low
usleep_range(100, 2000);             // T3 (corto)
gpiod_direction_output(rst, 1);      // RST high
usleep_range(6000, 10000);           // T4
gpiod_direction_input(rst);
goodix_int_sync():
    INT=0
    msleep(50)                       // T5
    INT input
```

vs la secuencia que el chip espera (GT911 Rev09):
```
RST=0 + INT=0
delay 11 ms
INT = address_select
delay 110 µs
RST=1
delay 6 ms       ← KERNEL OMITE ESTE PASO INTERMEDIO
INT=0
delay 51 ms
INT input
```

Sin esos 6 ms entre `RST=1` y `INT=0`, el chip no completa la carga interna de su config table desde flash. La config queda en zeros → el chip no escanea → no genera INTs.

Verificado snapshots de `0x8047..0x80FE` del chip:
- post-Arduino-reset: config llena con valores válidos para el panel
- post-kernel-reset: todo zeros

Intentamos también pasar `goodix_911_cfg.bin` como firmware file al driver. El driver lo carga y lo escribe al chip, pero el chip **sigue sin activar INT** porque el problema no es solo "no tengo bytes de config", es "no recibí el handshake T8+T3 que dice 'arranca a escanear'". El firmware blob no es suficiente — el chip necesita el timing correcto en RST/INT.

---

## 6. Plan B: parchar el kernel driver

El siguiente trabajo (no hecho) es parchar `drivers/input/touchscreen/goodix.c` para añadir la ventana T8 + INT-low-51ms, así el driver kernel deja al chip en estado funcional y se puede volver a usar el path estándar de Linux (chip → IRQ → driver → evdev).

### 6.1 Cambios mínimos al driver

En `goodix.c`, en la función `goodix_reset_no_int_sync()` (~línea 749) y/o `goodix_int_sync()` (~línea 723), añadir la ventana T8:

```c
// dentro de goodix_int_sync(), antes de bajar INT:
+ usleep_range(6000, 10000);  /* T8: > 5 ms — esperar a que el chip cargue config */

  error = goodix_irq_direction_output(ts, 0);
  // ... ya estaba
  msleep(50);                  /* T5: 50ms */
  error = goodix_irq_direction_input(ts);
```

Justificación detallada en `docs/superpowers/specs/2026-05-12-uno-q-giga-touch-i2c-design.md` §10.

### 6.2 Pasos para implementar B

1. **Identificar versión del kernel** del UNO Q: `uname -r` → `6.16.7-g0dd6551ae96b`. Necesitamos el árbol de fuentes Arduino o equivalente.
2. **Obtener fuentes**: probablemente Arduino publica un repo del kernel custom; alternativa es buscar la "linux-image-6.16.7-g0dd6551ae96b" source package en su image.
3. **Compilar solo el módulo** `goodix_ts.ko` con el patch aplicado (no recompilar todo el kernel).
4. **Instalar via DKMS** (preferido) o copy a `/lib/modules/$(uname -r)/.../`.
5. **Quitar blacklist**: borrar `/etc/modprobe.d/blacklist-goodix.conf`.
6. **Deshabilitar el daemon**: `sudo systemctl disable --now gt911-touch.service`.
7. **Borrar xorg snippet de calibración del daemon** (la matriz era para ABS_MAX=479/799; el driver kernel con config válida reporta esos mismos rangos, así que misma matriz aplica — pero validar con `evtest`).
8. **Reboot y validar**: `i2cdetect -y 0` debe mostrar `UU` en 0x14, `/proc/interrupts` debe contar IRQs subiendo cuando toques, `evtest` debe emitir eventos.

### 6.3 Pitfall conocido: rebind manual rompe IRQ mapping

Al hacer `echo 0-0014 > .../unbind` seguido de `... > .../bind`, el kernel falla con `irq: type mismatch, failed to map hwirq-98 for pinctrl@500000!`. Es un bug separado del kernel mainline (cleanup del IRQ desc no limpia el trigger type). **No relevante si la inicialización al boot funciona** — solo afecta a quien intente unbind+rebind manualmente. Se puede ignorar para el patch del driver.

### 6.4 Submission upstream

Una vez verificado, el patch tiene valor para enviar a:
- `linux-input@vger.kernel.org` (maintainer de touchscreen drivers)
- Goodix driver actual maintainer (ver `MAINTAINERS` file: `INPUT (KEYSPAN TIMECODE READER...) ` o similar)

Antes de submit, leer:
- `Documentation/devicetree/bindings/input/touchscreen/goodix.yaml`
- Datasheet GT911 Rev09 (en este repo: `GT911_Datasheet.pdf`) — sección "Power-on Timing"
- Library Arduino de referencia: https://github.com/arduino-libraries/Arduino_GigaDisplayTouch (Arduino_GigaDisplayTouchMbed.cpp función `begin()`)

---

## 7. Estructura del repo

```
i2c_arduinoQ/
├── docs/
│   ├── HANDOFF.md                                  # este archivo
│   └── superpowers/
│       ├── specs/2026-05-12-uno-q-giga-touch-i2c-design.md
│       └── plans/2026-05-12-uno-q-giga-touch-i2c-plan.md
├── scripts/
│   ├── remote-ssh.sh                  # wrapper SSH al UNO Q (192.168.0.105)
│   ├── diagnose-i2c.sh                # diagnóstico estado I2C
│   ├── verify-gt911.sh                # detecta + lee Product ID
│   ├── bind-gt911.sh + unbind-gt911.sh
│   ├── patch-dtb.sh                   # añade nodo gt911 al DTB (legado kernel-driver)
│   ├── arduino-style-reset.py         # reset GT911 vía gpiod
│   ├── snapshot-gt911.sh              # captura estado completo del chip
│   ├── manual-cfg.sh                  # CLI multi-comando (read/write/poll)
│   ├── build-goodix-fw.py             # construye goodix_911_cfg.bin (intento legado)
│   ├── install-touch-calibration.sh   # snippet xorg.conf.d con matriz
│   ├── gt911-touch-daemon.py          # ← EL DAEMON
│   └── gt911-touch.service            # ← SYSTEMD UNIT
├── notes/                             # snapshots y logs por timestamp
│   ├── baseline-*.txt
│   ├── fase2-detect-*.txt
│   ├── snapshot-*-{post-arduino-reset,fresh-boot,with-firmware}.txt
│   ├── calibration-corners-*-{UL,UR,LR,LL}.txt
│   ├── e2e-cold-boot-*.md
│   └── ...
├── ABX00162-{datasheet,full-pinout,schematics}.pdf  # UNO Q
├── ASX00039-{datasheet,full-pinout,schematics}.pdf  # GIGA Display Shield
├── GT911_Datasheet.pdf                              # chip touch
└── Test Shield-Adapter.docx                         # notas del equipo previo
```

---

## 8. Acceso al UNO Q

- IP: `192.168.0.105`
- User: `arduino`
- Password: `arduino1334` (cambiará pronto — preguntar al usuario)
- Sudo: NOPASSWD configurado para `i2ctransfer, i2cdetect, gpiomon, gpioget, i2cset, i2cget, python3` en `/etc/sudoers.d/touch-debug`
- Grupos del user: `i2c`, `gpiod`, `input` (sin sudo para esas categorías de acceso)
- Imagen: Debian 13 trixie, kernel 6.16.7-g0dd6551ae96b

Wrapper local: `scripts/remote-ssh.sh` con `export SSHPASS='<password>'`.

---

## 9. Cómo verificar que A sigue funcionando

```bash
# Desde la máquina de desarrollo:
export SSHPASS='arduino1334'
./scripts/remote-ssh.sh 'systemctl status gt911-touch.service'
./scripts/remote-ssh.sh 'cat /proc/bus/input/devices | grep -A4 Goodix'
./scripts/remote-ssh.sh 'timeout 10 evtest /dev/input/event2' # tocar pantalla → eventos
```

Resultado esperado:
- Service activo (running)
- Device `Goodix Capacitive TouchScreen (userspace daemon)` en `event2`
- evtest reporta `ABS_MT_POSITION_X/Y` y `BTN_TOUCH` al tocar

---

## 10. Known issues / observaciones

- **1.9V swing marginal**: sin level shifter el bus opera al límite. Funciona empíricamente con cables cortos, pero podría fallar con cables más largos o EMI alto. Capacitor 22-47pF a GND en INT, o level shifter TXS0108E/BSS138, mejorarían robustez.
- **Cursor "salta a esquina"**: si pasa, es porque `evtest` muestra coords fuera del rango ABS_MAX. Probable bug del daemon en parsing de bytes (verificar `REG_POINTS = 0x814F` no `0x8150`). Ya resuelto, pero si vuelve a aparecer, ahí está.
- **Daemon CPU usage**: ~0.5% en idle (polling 10ms con sleep). Aceptable. Si se quiere I/O bound (gpiomon en INT en vez de polling), es ~30 líneas de cambio al daemon.
- **No probamos cold boot completo** (poweroff + replug USB-C). El warm reboot SÍ se probó: daemon arranca solo desde systemd y funciona inmediatamente. Cold boot debería ser idéntico pero queda como verificación pendiente para B también.

---

Fin del handoff. Cualquier pregunta de continuación queda en el repo git (commits anteriores tienen el razonamiento completo de cada paso).
