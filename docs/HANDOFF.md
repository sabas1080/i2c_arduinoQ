# Handoff — GT911 Touch en Arduino UNO Q + GIGA Display Shield

**Fecha:** 2026-05-13 (original) · **actualizado 2026-05-26 (DOS VECES)**
**Sesión previa:** Claude Opus 4.7 (1M context)
**Estado:** **PLAN B RESUELTO.** El kernel driver Arduino-original funciona correctamente con el DTB CORREGIDO. No se necesita ningún patch al código C. Plan A daemon queda como fallback opcional.

> ⚠️ **Nota IMPORTANTE 2026-05-26:** Las secciones §5, §6 y §11 contienen diagnósticos PARCIALMENTE INCORRECTOS (no fueron borrados — quedan como contexto histórico). **El bug real está documentado en §12 al final**. Resumen ejecutivo: el bug NO era T8 (§5/§6) NI un problema de pinctrl-msm (§11) — eran simplemente los **GPIO flags del DTB invertidos** que el script `patch-dtb.sh` setea. Una vez corregidos, el driver kernel `goodix_ts` upstream funciona out-of-the-box.

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

---

## 12. Resolución 2026-05-26 (segunda parte) — Plan B funciona: el bug era el DTB

Después de descartar T8 (§11) y de fracasar con patches v1/v2 al código C, una comparación con DTs upstream reveló el problema real. **No es ningún bug en el código kernel — es un bug en `scripts/patch-dtb.sh` que inyectó los GPIO flags al revés.**

### 12.1 El bug

`scripts/patch-dtb.sh` (versión original) asignaba estos flags:

```
RST_FLAG=1    # GPIO_ACTIVE_LOW
IRQ_FLAG=2    # OOPS: este era IRQ_TYPE_EDGE_FALLING para interrupts-extended
              # pero se REUTILIZÓ para irq-gpios donde 2 significa GPIO_OPEN_DRAIN
```

Y el script aplicaba `RST_FLAG=1` (`GPIO_ACTIVE_LOW`) a `reset-gpios` y `IRQ_FLAG=2` (`GPIO_OPEN_DRAIN`) a `irq-gpios`.

**Verificación contra árbol upstream:** los tres DTs upstream con `goodix,gt911` usan `GPIO_ACTIVE_HIGH` (=0) para ambos:
- `arch/arm/boot/dts/nxp/imx/imx6q-kp.dtsi`: `reset-gpios = <&gpio5 2 GPIO_ACTIVE_HIGH>; irq-gpios = <&gpio1 9 GPIO_ACTIVE_HIGH>;`
- `arch/arm64/boot/dts/rockchip/rk3399-rockpro64.dtsi`: idem ambos `GPIO_ACTIVE_HIGH`
- `arch/arm/boot/dts/st/stm32mp135f-dk.dts`: idem

El driver `goodix.c` ejecuta `gpiod_direction_output(rst, 0)` esperando que se traduzca a **físico LOW** (chip en reset). Con `GPIO_ACTIVE_HIGH` (convención upstream), eso es lo que pasa. Con nuestro `GPIO_ACTIVE_LOW`, la API de gpiod inverte la polaridad y `(rst, 0)` resulta en **físico HIGH** — chip NO entra en reset.

Resultado de la secuencia con DT mal:
1. `gpiod_direction_output(rst, 0)` → RST físico HIGH (no reset)
2. `msleep(20)` con RST HIGH (chip está corriendo normalmente, no en reset)
3. INT manipulation con chip ya corriendo (no entra en boot-mode select)
4. `gpiod_direction_output(rst, 1)` → RST físico LOW (chip recién ahora entra en reset)
5. `usleep_range(6000, 10000)` chip está reseteado solo 6-10ms (datasheet pide ≥11ms inicial)
6. `gpiod_direction_input(rst)` → RST se suelta a high-Z, sube → chip arranca

El chip queda en estado raro: sí responde a I2C, pero su engine de scan nunca arrancó porque la secuencia de address-select via INT pasó cuando el chip ya estaba corriendo (no en boot).

`irq-gpios` con `GPIO_OPEN_DRAIN` también contribuye: cuando el driver hace `goodix_irq_direction_output(int, 1)` para drive HIGH, con OPEN_DRAIN solo "libera" el pin (relies on pull-up externo) en vez de drive activo HIGH.

### 12.2 Por qué el daemon Plan A sí funcionaba

`libgpiod` desde userspace NO lee los flags del Device Tree. Toma sus propias decisiones de polaridad y drive mode basado en `LineSettings`. El daemon especificaba `Direction.OUTPUT` y `Value.ACTIVE/INACTIVE` sin flag de inversión → control directo físico:
- `Value.INACTIVE` = físico LOW
- `Value.ACTIVE` = físico HIGH

Por eso el daemon "sabía" lo que estaba haciendo a nivel hardware mientras el kernel driver se comía la mentira del DT.

### 12.3 El fix

`scripts/patch-dtb.sh` ahora separa el IRQ trigger flag (para `interrupts-extended`) del GPIO polarity flag (para `irq-gpios`/`reset-gpios`):

```
IRQ_TRIGGER_FLAG=2   # IRQ_TYPE_EDGE_FALLING (cell de interrupts)
GPIO_FLAG=0          # GPIO_ACTIVE_HIGH (cell de gpios) ← convención upstream
```

Aplicar `bash scripts/patch-dtb.sh` regenera el DTB con los flags correctos.

### 12.4 Estado final del sistema

| Componente | Estado actual | Notas |
|---|---|---|
| `/boot/efi/qrb2210-arduino-imola-gigadisplay.dtb` | **Patched con flags corregidos** | `reset-gpios <26 18 0>`, `irq-gpios <26 98 0>` |
| `/etc/modprobe.d/blacklist-goodix.conf` | **REMOVIDO** | Ya no hace falta — kernel driver funciona |
| `gt911-touch.service` | **disabled** | Plan A ya no es necesario; queda como respaldo si se desinstala |
| `/usr/local/bin/gt911-touch-daemon.py` | Presente (desactivado) | Disponible si en el futuro se quiere volver a Plan A |
| `/lib/modules/.../goodix_ts.ko` | Original Arduino sin patch | `md5: f7dba424...` |
| `/lib/modules/.../goodix_ts.ko.original` | Backup redundante | Puede borrarse |
| `/lib/firmware/goodix_911_cfg.bin` | Presente pero opcional | Driver lo carga; si no estuviera, chip usaría su flash interna que también tiene config válida (ahora que el reset es correcto) |
| `/etc/X11/xorg.conf.d/20-goodix-touch.conf` | Calibración instalada | Matriz funciona igual para daemon y kernel driver (mismos abs_max=479/799) |

### 12.5 Verificación de Plan B

```bash
export SSHPASS='***REDACTED***'
./scripts/remote-ssh.sh 'lsmod | grep goodix_ts'   # esperado: goodix_ts cargado
./scripts/remote-ssh.sh 'cat /proc/interrupts | grep gt911'  # IRQ count > 0
./scripts/remote-ssh.sh 'cat /proc/bus/input/devices | grep Goodix'  # device sin sufijo "(userspace daemon)"
./scripts/remote-ssh.sh 'timeout 5 evtest /dev/input/event2 | grep ABS_MT_POSITION'  # eventos al tocar
```

### 12.6 Lecciones para futuros DTBs

- **Los DT flags GPIO no son intuitivos.** `GPIO_ACTIVE_LOW` aplicado a un pin físicamente "active-low" (como un reset asserted-low) **NO compensa la polaridad para el código** — al revés, INVIERTE lo que el código pide vía `gpiod_set_value()`. La convención correcta para drivers como `goodix.c` es ALMOST SIEMPRE `GPIO_ACTIVE_HIGH=0`, dejando que el código del driver maneje la lógica.
- **Antes de inventar un patch de driver, verificar contra árbol upstream.** En este caso, 30 minutos de comparación con `imx6q-kp.dtsi` y similares habrían encontrado el bug inmediatamente, ahorrando varias horas de cacería incorrecta de un bug que no existía.
- **`libgpiod` userspace evita los flags del DT.** Por eso un Plan A daemon-userspace puede funcionar incluso con un DTB malo — y eso enmascara que el problema real es el DTB, no el kernel driver.

### 12.7 Próximos pasos (opcionales)

- Borrar `/lib/modules/.../goodix_ts.ko.original` del device (backup ya no necesario)
- Borrar `~/kernel-source` y `~/compiling_goodix` del device (leftovers del intento del equipo de soporte, ~2 GB)
- Borrar `~/Documents/electroniccats/linux-qcom-build/` del PC (cross-compile ya no necesario, ~5-7 GB)
- Considerar reportar a Arduino/upstream: el DTS de UNO Q que viene de fábrica podría incluir el nodo gt911 con flags correctos así nadie más cae en esto.

---

## 13. Soporte para kernel 7.0.0 (2026-05-26 ~tarde)

Las secciones §11 y §12 documentan el trabajo en kernel **6.16.7**. La imagen Arduino oficial publicada después de mayo 2026 viene con **kernel 7.0.0-g122c2c22d838** como default y 6.16.7 como respaldo. Esta sección documenta el soporte para correr el GIGA Display Shield en 7.0.0.

### 13.1 El problema en 7.0.0

Al portar el árbol del kernel desde la rama `qcom-v6.16.7-unoq` a `qcom-v7.0.0-unoq`, Arduino **eliminó el descriptor del panel del GIGA shield** del driver `drivers/gpu/drm/panel/panel-sitronix-st7701.c`. Verificación directa del source en GitHub:

| | qcom-v6.16.7-unoq | qcom-v7.0.0-unoq |
|---|---|---|
| Función `arduino_giga_display_gip_sequence` | ✓ presente (L523) | ✗ removida |
| Struct `arduino_giga_display_mode` (480×800) | ✓ presente (L665) | ✗ removido (reemplazado por `wf40eswaa6mnn0_mode` 480×480) |
| Struct `arduino_giga_display_desc` | ✓ presente (L684) | ✗ removido |
| Entry en `st7701_dsi_of_match[]` con `arduino_giga_display_desc` | ✓ presente (L1340) | ✗ removida |

Sin el descriptor, el driver `panel-sitronix-st7701.ko` NO sabe cómo configurar el panel (timings, gamma, init sequence, voltages). El boot del kernel 7.0.0 con un DTB que declara el panel del GIGA shield resulta en panel no inicializado.

Adicionalmente, el ecosistema 7.0.0:
- Nuevo modelo de DTB modular: `qrb2210-arduino-imola-base.dtb` + overlays `.dtbo`
- Nueva herramienta `arduino-linux-config carrier enable` para activar overlays
- Carriers disponibles: `5-dsi-touch-a`, `8-dsi-touch-a`, `10-dsi-touch-a` (todos Waveshare, NO el GIGA shield)

### 13.2 El fix

Dos cambios complementarios:

**(a) Backport del descriptor al módulo del kernel:**
Re-añadir `arduino_giga_display_*` (function + mode + desc + entries en of_match) al `panel-sitronix-st7701.c` del branch 7.0.0. La struct `st7701_panel_desc` es byte-compatible entre branches, así que el descriptor del 6.16.7 funciona literal en 7.0.0 sin traducción.

**(b) Overlay device-tree custom:**
Escribir un `.dtso` que active `mdss_dsi0` con el panel `arduino,giga-display` + añada el node `gt911@14` al bus i2c0 con los GPIO flags correctos (`GPIO_ACTIVE_HIGH=0`). Componer con `fdtoverlay` sobre el `qrb2210-arduino-imola-base.dtb`.

### 13.3 Componentes del fix (en este repo)

| Archivo | Propósito |
|---|---|
| `scripts/enable-gigadisplay-shield.sh` | Bootstrap. Se corre ON-DEVICE en el UNO Q. Instala módulo, compone DTB, edita boot entry, instala xorg snippets, reboot. |
| `scripts/gigadisplay-shield.dtso` | Overlay device-tree source. Compila a `.dtbo` en device con `dtc` y se aplica con `fdtoverlay`. |
| `scripts/panel-sitronix-st7701.ko` | Módulo cross-compilado con el descriptor backportado (binario). |
| `scripts/build-st7701-patched-ko.sh` | Helper para devs: clona arduino/linux-qcom@qcom-v7.0.0-unoq, aplica el patch al st7701 driver, cross-compila el módulo. Solo necesario cuando Arduino actualice el kernel 7.0.0. |

### 13.4 Uso para usuarios finales

Copiar `scripts/{enable-gigadisplay-shield.sh, gigadisplay-shield.dtso, panel-sitronix-st7701.ko}` al UNO Q (via SSH, adb push, USB stick, etc.) y ejecutar:

```bash
chmod +x enable-gigadisplay-shield.sh
./enable-gigadisplay-shield.sh
```

El script pide sudo una vez al inicio, hace todo lo demás automáticamente, y reinicia. Después del reboot el display + touch funcionan con el kernel driver original (más nuestro módulo `st7701` parchado).

Para revertir: `./enable-gigadisplay-shield.sh --revert`.

### 13.5 Rebuild del módulo cuando Arduino actualice 7.0.0

El módulo `panel-sitronix-st7701.ko` shipped en el repo está cross-compilado contra el kernel 7.0.0-g122c2c22d838 actual. Si Arduino publica una actualización del paquete `linux-image-7.0.0` con un commit SHA distinto, el vermagic del módulo dejará de matchear y modprobe rechazará la carga.

Para regenerar el módulo contra el kernel actualizado:

```bash
# En la PC dev:
export SSHPASS='***REDACTED***'   # password SSH del UNO Q
export UNOQ_IP='192.168.0.XXX'
./scripts/build-st7701-patched-ko.sh
```

El script clona arduino/linux-qcom rama qcom-v7.0.0-unoq, aplica nuestro patch al st7701 driver, baja el .config del kernel running del device, cross-compila, ajusta el vermagic via binary patch, y deja el nuevo `.ko` listo en `scripts/`.

### 13.6 Contribución upstream (TODO)

El fix lógico de largo plazo es contribuir el descriptor del GIGA shield al árbol oficial de Arduino:

- PR a [`arduino/linux-qcom`](https://github.com/arduino/linux-qcom) rama `qcom-v7.0.0-unoq`: cherry-pick del commit que añadió `arduino_giga_display_desc` en 6.16.7
- PR a [`arduino/arduino-linux-config`](https://github.com/arduino/arduino-linux-config): añadir un carrier `gigadisplay-shield` que aplique nuestro overlay

Una vez ambos PRs mergeados y la imagen Arduino actualizada, el bootstrap se reducirá a `arduino-linux-config carrier enable media-carrier display=gigadisplay-shield` y el reinstalable manual desaparece.
