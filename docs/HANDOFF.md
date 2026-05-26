# Handoff — GT911 Touch en Arduino UNO Q + GIGA Display Shield

**Fecha:** 2026-05-13 (original) · **actualizado 2026-05-26**
**Sesión previa:** Claude Opus 4.7 (1M context)
**Estado:** Plan A completo y funcionando. Plan B (kernel patch) **CORREGIDO** — la hipótesis original de "T8 missing" se verificó FALSA. El bug real está sin localizar y requiere debug con osciloscopio.

> ⚠️ **Nota 2026-05-26:** Las secciones §5 y §6 de este documento contenían un diagnóstico equivocado del bug del kernel driver. **No se borraron** (quedan como contexto histórico) pero ver §11 al final para la versión corregida tras los experimentos de esta sesión.

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
│   ├── remote-ssh.sh                  # wrapper SSH al UNO Q (192.168.0.XXX)
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

- IP: `192.168.0.XXX`
- User: `arduino`
- Password: `***REDACTED***` (cambiará pronto — preguntar al usuario)
- Sudo: NOPASSWD configurado para `i2ctransfer, i2cdetect, gpiomon, gpioget, i2cset, i2cget, python3` en `/etc/sudoers.d/touch-debug`
- Grupos del user: `i2c`, `gpiod`, `input` (sin sudo para esas categorías de acceso)
- Imagen: Debian 13 trixie, kernel 6.16.7-g0dd6551ae96b

Wrapper local: `scripts/remote-ssh.sh` con `export SSHPASS='<password>'`.

---

## 9. Cómo verificar que A sigue funcionando

```bash
# Desde la máquina de desarrollo:
export SSHPASS='***REDACTED***'
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

Fin del handoff original (2026-05-13). Continúa abajo con la corrección de 2026-05-26.

---

## 11. Corrección 2026-05-26 — T8 NO es el bug, diagnóstico abierto

Sesión de retomar: Plan B intentado vía cross-compile en PC. Resumen de hallazgos que **corrigen las secciones §5 y §6 de este documento**.

### 11.1 T8 ya está en el árbol Arduino — la hipótesis original era incorrecta

El kernel `6.16.7-g0dd6551ae96b` corresponde al commit `0dd6551ae96b78024086e72339fefbef6fcc604b` en la rama `qcom-v6.16.7-unoq` del repo `arduino/linux-qcom`. En `drivers/input/touchscreen/goodix.c:771`:

```c
usleep_range(6000, 10000);		/* T4: > 5ms */
```

El kernel lo llama **T4** en su comentario pero es exactamente la ventana T8 (≥6 ms tras `RST=1` antes de bajar INT) que el HANDOFF original (§5) afirmaba que el kernel omitía. **Está, y desde hace mucho.** La cadena completa kernel → `goodix_reset()` → `goodix_reset_no_int_sync()` (deja RST high, hace el T8 wait) → `goodix_int_sync()` (INT=0, msleep(50)=T5, INT=input) coincide en estructura con la secuencia Arduino-style del datasheet.

### 11.2 Síntoma real observado

Con el driver kernel bound (original o parchado) y los GPIOs en posesión del kernel:
- Chip responde a I2C (lee `ID 911, version 1060`) ✓
- Sus registros de config `0x8047..0x80FE` quedan en **zeros** después del reset del kernel — el chip NO auto-carga su flash interna ✗
- Si el host (driver) escribe la config (vía `goodix_911_cfg.bin`), los bytes llegan a los registros, pero el flag `config_fresh` en `0x8100` **se queda en `0x01`** — el chip nunca procesa el reload ✗
- `/proc/interrupts` cuenta **0 IRQs** al tocar la pantalla ✗

Mientras tanto, el daemon Plan A (que hace el reset Arduino-style vía `libgpiod` directo sobre `/dev/gpiochip1`):
- Mismo timing nominal (T2, T7, T8, T5 dentro de spec en ambos paths)
- Después del reset, los registros del chip tienen config completa, `0x8100 = 0x00`, y el chip escanea normalmente

Comparado byte-a-byte el `notes/snapshot-20260513-105954-post-arduino-reset.txt` (estado tras reset del daemon, working) vs el `notes/snapshot-20260513-112301-with-firmware.txt` (estado tras reset del kernel + escritura de blob, no working): los **184 bytes de config son idénticos**, solo difiere `0x8100` (00 vs 01).

### 11.3 Patches intentados en esta sesión (todos fallidos)

Cross-compile en PC sobre el commit exacto del kernel running, vermagic ajustado, deploy via SCP a `/lib/modules/$(uname -r)/kernel/drivers/input/touchscreen/goodix_ts.ko`:

| Patch | Hipótesis | Resultado |
|---|---|---|
| v1 | Falta `goodix_irq_direction_output(ts, 0)` inmediatamente después de `RST=0` y antes del `msleep(20)` (forzar INT low durante T2 como hace explícitamente el daemon) | Chip sigue sin auto-cargar config; `config_fresh=1` se queda; 0 IRQs |
| v2 (sobre v1) | También skipear la rama `gpiod_direction_input(ts->gpiod_rst)` al final de `goodix_reset_no_int_sync` (mantener RST como OUTPUT HIGH, como hace el daemon antes de release) | **PEOR**: chip deja de responder a I2C (`-6 ENXIO`) |

Commit local con el patch v1 (para referencia): tag `e7189f57168c` en `arduino/linux-qcom` branch `qcom-v6.16.7-unoq`. El árbol cross-compile vive en mi PC en `~/Documents/electroniccats/linux-qcom-build/linux-qcom/`.

### 11.4 Estado del entendimiento (al cerrar esta sesión)

Empíricamente: existe una diferencia entre la secuencia GPIO ejecutada por `gpiod_direction_output()` desde el kernel (que pasa por `pinctrl-msm` + el driver de gpio del SoC) vs `libgpiod` desde userspace (`/dev/gpiochip1` → ioctls al mismo subsistema kernel). Ambos teóricamente deberían producir las mismas transiciones eléctricas, pero **empíricamente solo el path userspace logra que el chip GT911 entre en modo normal y auto-cargue su flash**.

Posibles causas todavía no descartadas (require osciloscopio o instrumentación más fina):
- Glitch transitorio en INT o RST entre operaciones GPIO consecutivas del kernel
- Algún paso del pinctrl-msm (mux/drive-strength/bias config) que reconfigura el pin de forma sutil cuando el kernel reclama el GPIO
- Una diferencia microsegundo-temprana en cuándo INT/RST cambian relativo a algún reloj interno del SoC

### 11.5 Verificación rápida de que Plan A sigue funcionando

```bash
export SSHPASS='***REDACTED***'
./scripts/remote-ssh.sh 'systemctl is-active gt911-touch.service'
./scripts/remote-ssh.sh 'timeout 5 evtest /dev/input/event2 | grep ABS_MT_POSITION'
```

Esperado: service `active`, eventos `ABS_MT_POSITION_X/Y` al tocar.

### 11.6 Calibración X11 corregida (también)

La matriz original de `scripts/install-touch-calibration.sh` (`0 5.98 -0.083 -11.0 0 1.081 0 0 1`) fue derivada en una etapa cuando el kernel driver con config inválida reportaba `abs_max=4095`. El daemon Plan A reporta `abs_max=479/799` (la resolución real del chip), así que los coeficientes deben ser ~5x/~8x más pequeños. Matriz **correcta** para el daemon:

```
TransformationMatrix "0 1.175 -0.103 -1.312 0 1.096 0 0 1"
```

`scripts/install-touch-calibration.sh` ya está actualizado.

### 11.7 Estado de los archivos en el UNO Q (tras esta sesión)

| Path | Estado | Notas |
|---|---|---|
| `/usr/local/bin/gt911-touch-daemon.py` | Original (sobrevivió reflash) | — |
| `/etc/systemd/system/gt911-touch.service` | Original (sobrevivió reflash), enabled+active | — |
| `/etc/modprobe.d/blacklist-goodix.conf` | **Re-creado** | Se había perdido en reflash |
| `/etc/X11/xorg.conf.d/20-goodix-touch.conf` | **Re-creado con matriz CORREGIDA** | — |
| `/lib/firmware/goodix_911_cfg.bin` | Presente | Inofensivo con blacklist; útil si se reintenta path kernel |
| `/lib/modules/.../goodix_ts.ko` | Original Arduino (md5 `f7dba424...`) | El parchado fue restaurado al backup tras experimentos |
| `/lib/modules/.../goodix_ts.ko.original` | Backup del original | Se puede borrar después de validar todo |
| `~arduino/kernel-source` (2 GB), `~arduino/compiling_goodix` (260 K) | Leftovers del equipo de soporte | No afectan runtime; borrar cuando se quiera liberar disco |

### 11.8 Cambios en este repo (commit de esta sesión)

- `scripts/install-touch-calibration.sh` — matriz corregida + comentario explicando la corrección
- `docs/HANDOFF.md` — esta sección §11 + nota de advertencia al inicio

### 11.9 Próximos pasos sugeridos para retomar Plan B

1. **Instrumentar con osciloscopio** RST + INT + SDA durante el reset del kernel-driver, comparar contra el reset del daemon. Buscar diferencia de timing del orden de microsegundos o niveles de voltaje transitorios.
2. Probar deshabilitando `pinctrl-msm` para los pines GPIO_18 / GPIO_98 antes de que el kernel driver intente reclamarlos.
3. Probar un patch que use directamente las APIs de bajo nivel `pinctrl_*` en vez de `gpiod_*` (esquiva la capa de abstracción).
4. Considerar reportar el bug a `linux-input@vger.kernel.org` con los datos empíricos como issue contra el driver `goodix` cuando se usa con boards que no tienen pull-up fuerte en RST y/o gpio controllers MSM.

El árbol cross-compile en `~/Documents/electroniccats/linux-qcom-build/linux-qcom/` ya tiene el commit `e7189f57168c` aplicado y vmlinux + Module.symvers construidos — recompilar el módulo es rápido para futuras iteraciones.
