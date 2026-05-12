# Diseño: Touch I2C del GIGA Display Shield sobre Arduino UNO Q (lado Linux)

**Fecha:** 2026-05-12
**Hardware:** Arduino UNO Q (ABX00162) + Arduino GIGA Display Shield (ASX00039)
**Sistema:** Debian 13 trixie, kernel 6.16.7-g0dd6551ae96b, board "wallis", DTB `qrb2210-arduino-imola-gigadisplay.dtb`
**Objetivo del usuario:** que el GT911 del shield aparezca como `/dev/input/eventN` evdev nativo del kernel, consumible por apps Linux (LVGL, Qt, Weston, evtest) sin código adicional.

## 1. Contexto

El display (DSI-1, 480x800) ya funciona desde Linux gracias al DTB que Arduino publica para esta combinación de placas. Falta el panel táctil: el GT911 nunca ha sido detectado por I2C. Un intento previo del equipo soldó las líneas SDA/SCL del shield a los pines JMEDIA **GPIO_22/23 (CCI_I2C_SDA0/SCL0)** del SoC, sin éxito — los pines miden ~1.9V flotantes y el osciloscopio no muestra oscilación.

La causa, confirmada por inspección directa del dispositivo: **GPIO_22/23 pertenecen al bloque CCI (Camera Control Interface)** del QRB2210, un I2C especializado para sensores de cámara que no se expone como `/dev/i2c-N` genérico ni acepta clientes arbitrarios. Su driver (`i2c-qcom-cci`) no está bound porque no hay cámara, así que el bus físicamente no oscila.

Sin embargo, el SoC sí expone un I2C QUP normal libre: **`/dev/i2c-0` = `4a80000.i2c` = controlador qup0**, con `status="okay"` en el DTB activo, pinmux ya configurado, y sin clientes. Físicamente sale por **JMEDIA pin 37 (SOC_GPIO_0_SE0 = SDA)** y **JMEDIA pin 39 (SOC_GPIO_1_SE0 = SCL)** a **1.8V**. El driver `goodix_ts.ko` está disponible como módulo en `/lib/modules/$(uname -r)/kernel/drivers/input/touchscreen/`.

## 2. Goals y no-goals

**Goals:**
- GT911 detectado por `i2cdetect -y 0` en dirección 0x5D (o 0x14 según boot timing).
- Driver `goodix_ts` bound, exponiendo `/dev/input/eventN` con eventos multitouch ABS estándar.
- Persistencia tras reboot.
- Apps Linux que ya usan evdev (LVGL/Qt/Weston/evtest) reciben toques sin cambios.

**Non-goals (esta iteración):**
- Soporte simultáneo desde sketches Arduino (lado MCU). El touch queda exclusivamente en lado Linux.
- Calibración / inversión de ejes para coincidir con la rotación visual del display (xorg `Rotate "right"`). Se trata como follow-up.
- Optimización de latencia de polling vs IRQ más allá de "funciona con INT".
- Soporte de gestos avanzados o firmware custom del GT911.

## 3. Arquitectura

```
┌─────────────────────┐         JMEDIA          ┌──────────────────────┐
│ GIGA Display Shield │  ←─── level shifter ───→ │  Arduino UNO Q       │
│                     │       1.8V ↔ 3.3V       │                      │
│  GT911 @ 0x5D       │                          │  QRB2210 SoC         │
│   SDA ─────┐        │                          │       gpio0 (qup0)   │
│   SCL ─────┤        │  pin 37/39/49/46         │       gpio1 (qup0)   │
│   RST ─────┤        │                          │       gpio18         │
│   INT ─────┘        │                          │       gpio98         │
│   3V3, GND          │  pin 58/60, varios       │       (+3V3, GND)    │
│                     │                          │                      │
│  + pull-ups a 3V3   │                          │  /dev/i2c-0          │
│    en SDA/SCL/INT   │                          │     ↓ goodix_ts.ko   │
│    (ya en PCB)      │                          │  /dev/input/eventN   │
└─────────────────────┘                          └──────────────────────┘
                                                            ↓
                                                  apps Linux (LVGL/Qt/...)
```

El SoC habla I2C estándar sobre `i2c-0` (qup0, GENI). El level shifter traduce 1.8V↔3.3V en las 4 líneas relevantes. El driver `goodix_ts` (mainline, ya en el kernel) hace todo el trabajo: detecta el chip, lee firmware/dimensiones, configura touchscreen multitouch, emite eventos evdev.

## 4. Plan de hardware

### 4.1. Mapa de pines

| Señal en shield | Conector shield | JMEDIA pin UNO Q | Señal SoC | Voltaje SoC |
|---|---|---|---|---|
| SDA touch (D102) | display touch connector | **37** | GPIO_0 (qup0 SDA) | 1.8V |
| SCL touch (D101) | display touch connector | **39** | GPIO_1 (qup0 SCL) | 1.8V |
| RST touch | display touch connector | **49** | GPIO_18 | 1.8V |
| INT touch | display touch connector | **46** | GPIO_98 | 1.8V |
| 3V3 (alimentación shield) | display connector pin 1 | **58** o **60** | +3V3 | — |
| GND | display connector | varios JMEDIA GND | — | — |
| 1V8 (referencia level shifter LV) | n/a (solo level shifter) | **57** | +1V8 | — |

**Pre-trabajo:** desoldar las conexiones actuales a GPIO_22 (pin 53) y GPIO_23 (pin 51) — los pines CCI que no sirven.

### 4.2. Level shifter (decisión abierta)

Necesario en las 4 líneas (SDA, SCL bidireccionales; RST salida; INT entrada). Dos opciones equivalentes funcionales:

**Opción A — TXS0108E** (módulo prefabricado de 8 canales con OE). VCCA = JMEDIA pin 57 (1V8), VCCB = JMEDIA pin 58 (3V3), OE a VCCA vía 10k. SDA/SCL/RST/INT usan 4 de los 8 canales.

**Opción B — 2x BSS138 + 4x 10k** para SDA/SCL (esquema clásico Philips AN10441), más un par adicional para RST/INT. Componentes discretos, montaje en protoboard.

Se decide al momento de armar; ambos producen el mismo comportamiento eléctrico para I2C ≤ 400 kHz (modo Standard/Fast del GT911).

**No-opción:** alimentar el shield a 1.8V para evitar el shifter. Descartado por (a) GT911 requiere VDD ≥ 2.6V, (b) los pull-ups del shield están fijados a 3V3 por diseño, (c) otros componentes del shield (LCD driver, RGB LED) están dimensionados para 3V3.

## 5. Plan de software

Cuatro fases con criterios de éxito verificables. Cada fase es prerequisito de la siguiente; si una falla, la siguiente no se intenta.

### Fase 1 — Pre-cableado (sin tocar hardware)

Propósito: dejar Linux preparado para que cuando el cable llegue, todo funcione sin obstáculos administrativos.

- Añadir `arduino` al grupo `i2c`: `sudo usermod -aG i2c arduino` + relogin. Verificar con `id`.
- Confirmar `i2cdetect -y 0` corre y devuelve bus vacío (control negativo). Esto descarta dudas posteriores sobre si "el bus" o "el cable" es el problema.
- Capturar dmesg de boot relacionado con i2c-0: `dmesg | grep 4a80000` — para comparar luego.

**Criterio de éxito:** `arduino` puede correr `i2cdetect -y 0` sin sudo y el bus reporta vacío.

### Fase 2 — Validación cruda (post-soldar y montar level shifter)

Propósito: confirmar comunicación eléctrica con el GT911 antes de tocar drivers.

- Con todo conectado y alimentado: `i2cdetect -y 0` debe mostrar `5d` (o `14`).
- Si nada aparece: medir con multímetro nivel idle en SDA/SCL en lado HV del shifter (debe ser 3.3V) y lado LV (1.8V). Si lado LV no llega a 1.8V → shifter no conduce o pull-ups del shield no funcionan. Si lado HV no llega a 3.3V → mala alimentación del shield.
- Lectura de Product ID confirmando comunicación bidireccional:
  ```
  i2ctransfer -y 0 w2@0x5d 0x81 0x40 r4
  ```
  Resultado esperado: `0x39 0x31 0x31 0x00` ("911\0"). Si llega: el chip responde y el bus está sano.
- (Opcional) Leer firmware version (0x8144–45) y resolución configurada (0x8146–49) para registrar baseline.

**Criterio de éxito:** Product ID `911\0` leído correctamente.

### Fase 3 — Bind manual del driver (no persistente)

Propósito: confirmar que el driver del kernel se enlaza al chip y emite eventos, antes de invertir trabajo en persistencia.

- Cargar módulo si hace falta: `sudo modprobe goodix_ts`. Verificar con `lsmod | grep goodix`.
- Lanzar `sudo dmesg -w` en otra terminal para ver el bind en tiempo real.
- Instanciar:
  ```
  echo gt911 0x5d | sudo tee /sys/bus/i2c/devices/i2c-0/new_device
  ```
- Esperar en dmesg algo equivalente a `goodix i2c-0-005d: Goodix-TS Product id: GT911` y la creación de un nodo input.
- Confirmar nodo evdev:
  ```
  cat /proc/bus/input/devices | grep -A4 -i goodix
  ls /dev/input/event*
  ```
- Probar toques con `sudo evtest /dev/input/eventX`. Tocar pantalla → eventos `ABS_MT_POSITION_X`, `ABS_MT_POSITION_Y`, `BTN_TOUCH`.

**Limitaciones conocidas de esta fase:** sin RST/INT declarados al driver, opera en polling y dependiendo del estado de power-on del chip puede requerir replug ocasional. Es comportamiento esperado.

**Criterio de éxito:** `evtest` muestra coordenadas X/Y variando al deslizar el dedo.

### Fase 4 — Persistencia vía DTB

Propósito: que el bind ocurra automáticamente al boot, con RST/INT correctamente gestionados.

Dos rutas posibles según viabilidad técnica:

**Ruta 4a (preferida) — Modificar DTB binario con `fdtput`.** Como `dtc` aborta al hacer roundtrip del DTB de Arduino (assertion en `propval_cell`), no se puede recompilar desde un DTS recompuesto. Pero `fdtput` permite inyectar nodos binariamente sin pasar por DTS. Trabajo:
1. Backup: `cp /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb ~/dtb.backup`
2. Añadir nodo bajo `/soc@0/geniqup@4ac0000/i2c@4a80000/`:
   - `compatible = "goodix,gt911"` (verificar el string exacto que el driver `goodix_ts` busca en su tabla `of_match`)
   - `reg = <0x5d>`
   - `irq-gpios = <&tlmm 98 IRQ_TYPE_EDGE_FALLING>` (GPIO_98 = JMEDIA pin 46)
   - `reset-gpios = <&tlmm 18 GPIO_ACTIVE_HIGH>` (GPIO_18 = JMEDIA pin 49)
3. Reescribir DTB en `/boot/efi/` (necesita `sudo`).
4. Reboot y verificar bind automático.

**Ruta 4b (fallback) — systemd unit.** Si modificar el DTB binario resulta inviable o frágil, crear `/etc/systemd/system/giga-touch-bind.service` que ejecute al boot el `echo gt911 0x5d > /sys/bus/i2c/devices/i2c-0/new_device`. Funciona pero pierde la gestión de RST/INT por el driver (queda en polling). Se acepta como solución pragmática si 4a no progresa.

**Criterio de éxito:** tras reboot, `evtest` sigue funcionando sin intervención manual.

## 6. Validación end-to-end

Una vez completada la Fase 4:

1. Arrancar el sistema en frío.
2. Sin intervención, `ls /dev/input/event*` lista el dispositivo Goodix.
3. `evtest` sobre ese device muestra eventos al tocar.
4. Una app de prueba (puede ser un visor X o un binario LVGL mínimo) responde a toques.
5. Tras 50+ toques continuos, sin "stuck touches" ni cuelgues de bus.

## 7. Riesgos y mitigaciones

| ID | Riesgo | Probabilidad | Mitigación |
|---|---|---|---|
| R1 | GT911 aparece en 0x14 en vez de 0x5D según timing de RST/INT en boot | Media | Script de bind detecta dirección antes de instanciar; el DTB usa la dirección observada |
| R2 | `dtc` no recompila el DTB de Arduino (assert en propval_cell) | **Confirmado** | Fase 4a usa `fdtput` binario; fallback Ruta 4b con systemd |
| R3 | Pinmux de qup0 podría desactivarse en futuras imágenes Arduino | Baja | El cambio al DTB lo fija; documentar pinning como parte del overlay |
| R4 | El driver `goodix_ts` espera un nombre `compatible` específico ("goodix,gt911" o variantes) que no haya en su tabla | Baja | Antes de Fase 4, leer `/lib/modules/.../goodix_ts.ko` con `modinfo` para ver alias soportados |
| R5 | Falsos positivos en `i2cdetect` por pull-up flotante mal | Baja | Verificar siempre con `i2ctransfer` leyendo Product ID, no confiar solo en scanner |
| R6 | Soldadura intermitente en JMEDIA (pads finos) | Media (riesgo manual) | Después de soldar, test de continuidad antes de alimentar; pull-test mecánico suave |
| R7 | Coexistencia futura con cámara CCI rompe el setup | Baja (no hay cámara hoy) | Documentado: GPIO_22/23/29/30 quedan libres y no se usan |

## 8. Decisiones abiertas (para resolver durante implementación)

- **Level shifter específico:** TXS0108E vs BSS138-based. Cualquiera funciona; decisión al armar.
- **`compatible` string exacto** en el nodo del DTB: requiere inspección de `goodix_ts.ko` (`modinfo` + posible lectura del source) para escoger entre "goodix,gt911", "goodix,gt9271", etc.
- **GPIO_98 vs alternativos para INT:** GPIO_98 funciona pero hay otros libres (99, 100). Si durante soldadura uno es más cómodo físicamente, ajustar.

## 9. Siguiente paso

Tras aprobación de este spec: invocar `writing-plans` para escribir el plan de implementación detallado (cada fase descompuesta en pasos ejecutables con verificación).
