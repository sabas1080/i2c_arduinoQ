# UNO Q + GIGA Display Shield Touch I2C — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GT911 del GIGA Display Shield aparece como `/dev/input/eventN` evdev nativo al boot del UNO Q, sin intervención manual, usando el driver `goodix_ts` del kernel sobre `/dev/i2c-0` (qup0).

**Architecture:** Soldadura directa de SDA/SCL/RST/INT del shield a JMEDIA del UNO Q (GPIO_0, GPIO_1, GPIO_18, GPIO_98) con level shifter 1.8V↔3.3V. Bind del driver `goodix_ts` vía sysfs para validación; persistencia mediante inyección binaria del nodo `gt911@5d` en el DTB activo con `fdtput`. Validación end-to-end con `evtest`.

**Tech Stack:** Bash + sshpass para automatización remota; `i2c-tools` y `evtest` en el UNO Q; `fdtput` (paquete `device-tree-compiler`) para edición DTB; `goodix_ts.ko` módulo del kernel. Spec: `docs/superpowers/specs/2026-05-12-uno-q-giga-touch-i2c-design.md`.

**Convenciones repetidas en todas las tareas:**
- IP UNO Q: `192.168.0.XXX`, user: `arduino`.
- Para autenticación SSH se asume variable de entorno `SSHPASS` ya exportada en la shell local (no en scripts). Comando base: `sshpass -e ssh arduino@192.168.0.XXX`.
- Comandos remotos con `sudo` usan `echo "$SSHPASS" | sudo -S` (la password sudo coincide con la SSH en esta imagen).
- Todos los outputs de comandos remotos se guardan localmente en `notes/` con timestamp, vía `tee`, para tener trazabilidad sin contar con git remoto.
- Después de cada tarea: `git add -A && git commit -m "..."`. No commits acumulados.

**File structure:**

```
i2c_arduinoQ/
├── docs/superpowers/
│   ├── specs/2026-05-12-uno-q-giga-touch-i2c-design.md   (existe)
│   └── plans/2026-05-12-uno-q-giga-touch-i2c-plan.md     (este archivo)
├── scripts/
│   ├── remote-ssh.sh           wrapper sshpass + check
│   ├── diagnose-i2c.sh         volcado de buses I2C + pinctrl
│   ├── verify-gt911.sh         i2cdetect + lectura Product ID
│   ├── bind-gt911.sh           sysfs new_device
│   ├── unbind-gt911.sh         sysfs delete_device (cleanup)
│   └── patch-dtb.sh            fdtput nodo gt911
├── notes/
│   ├── baseline-<ts>.txt       capturas pre-trabajo
│   ├── fase2-detect-<ts>.txt   resultados post-soldadura
│   └── fase3-evtest-<ts>.txt   captura evtest funcionando
└── (PDFs ya en la raíz)
```

---

## Task 0: Inicializar repositorio git

**Files:**
- Create: `.gitignore`
- Modify: working dir → git init

- [ ] **Step 1: Inicializar repo y configurar identidad si hace falta**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
git init -b main
git config user.email "sabasjimenez@gmail.com"
git config user.name "Sabas Jimenez"
```

Expected: `Initialized empty Git repository in /path/to/repo/Documents/electroniccats/i2c_arduinoQ/.git/`

- [ ] **Step 2: Crear .gitignore para excluir notas con timestamps si crecen mucho y backups DTB binarios**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/.gitignore` con contenido:

```
# Backups binarios grandes
*.dtb.backup
*.dtb.bak

# Pero SI queremos versionar las notas de medición
!notes/
```

- [ ] **Step 3: Commit inicial con los PDFs, spec y plan**

```bash
git add .gitignore docs/ ABX00162-datasheet.pdf ABX00162-full-pinout.pdf ABX00162-schematics.pdf ASX00039-datasheet.pdf ASX00039-full-pinout.pdf ASX00039-schematics.pdf "Test Shield-Adapter.docx" GT911_Datasheet.pdf
git commit -m "chore: bootstrap repo with spec, plan, and source datasheets"
```

Expected: commit creado con todos los PDFs + spec + plan rastreados.

---

## Task 1: Crear wrapper SSH reutilizable

**Files:**
- Create: `scripts/remote-ssh.sh`

- [ ] **Step 1: Definir comportamiento esperado del wrapper**

Debe:
1. Verificar que `$SSHPASS` está exportada; salir con error explicativo si no.
2. Verificar que `sshpass` está instalado localmente; salir con error si no.
3. Aceptar comandos como argumentos (o desde stdin si no hay argumentos) y ejecutarlos remotamente.
4. Imprimir cualquier salida del remoto en stdout local sin modificar.
5. Salir con el código de salida del comando remoto.

- [ ] **Step 2: Escribir el script**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/remote-ssh.sh`:

```bash
#!/usr/bin/env bash
# Wrapper SSH para UNO Q. Requiere SSHPASS exportada en el shell del caller.
# Uso:
#   scripts/remote-ssh.sh 'comando remoto'
#   echo 'script multi-linea' | scripts/remote-ssh.sh

set -euo pipefail

if [[ -z "${SSHPASS:-}" ]]; then
  echo "ERROR: export SSHPASS='<password>' antes de usar este wrapper." >&2
  exit 2
fi

if ! command -v sshpass >/dev/null; then
  echo "ERROR: 'sshpass' no instalado (sudo apt-get install sshpass)." >&2
  exit 2
fi

HOST="arduino@192.168.0.XXX"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

if [[ $# -gt 0 ]]; then
  # comando como argumento
  sshpass -e ssh $SSH_OPTS "$HOST" "$@"
else
  # comando vía stdin
  sshpass -e ssh $SSH_OPTS "$HOST" bash -s
fi
```

Hacer ejecutable:

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/remote-ssh.sh
```

- [ ] **Step 3: Verificar que funciona**

```bash
export SSHPASS='***REDACTED***'
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
./scripts/remote-ssh.sh 'echo PONG; uname -n'
```

Expected: `PONG` seguido de `wallis`.

- [ ] **Step 4: Verificar que falla con mensaje claro si SSHPASS no está**

```bash
unset SSHPASS
./scripts/remote-ssh.sh 'echo hola'
echo "exit code: $?"
export SSHPASS='***REDACTED***'  # restaurar
```

Expected: `ERROR: export SSHPASS=...`, exit code 2.

- [ ] **Step 5: Commit**

```bash
git add scripts/remote-ssh.sh
git commit -m "feat(scripts): add reusable SSH wrapper for UNO Q"
```

---

## Task 2: Confirmar `compatible` string del driver goodix_ts

Necesario antes de la Fase 4 (DTB) para evitar adivinar. Verifica también que el módulo del kernel del UNO Q realmente conoce el GT911 (no solo el Berlin / GT9xx variants).

**Files:**
- Create: `notes/goodix-compatibles-<ts>.txt`

- [ ] **Step 1: Definir qué buscamos**

El driver `goodix_ts.ko` declara una tabla `MODULE_DEVICE_TABLE(of, goodix_acpi_match)` o equivalente. Queremos la lista de compatibles soportados (típicamente `"goodix,gt911"`, `"goodix,gt9271"`, `"goodix,gt5688"`, etc.). Esta lista la imprime `modinfo` en el campo `alias=of:...T...Cgoodix,gtXXXX*`.

- [ ] **Step 2: Capturar compatibles del módulo en el UNO Q**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
TS=$(date +%Y%m%d-%H%M%S)
./scripts/remote-ssh.sh 'modinfo goodix_ts 2>&1' | tee notes/goodix-compatibles-${TS}.txt
```

Expected: salida con líneas como
```
alias:          of:N*T*Cgoodix,gt911C*
alias:          of:N*T*Cgoodix,gt911
alias:          of:N*T*Cgoodix,gt9271C*
...
```

- [ ] **Step 3: Verificar que existe al menos `goodix,gt911` o variante GT911**

```bash
grep -E 'gt(911|928|927|9271|9110)' notes/goodix-compatibles-*.txt | head -5
```

Expected: al menos una línea coincide. Si NO aparece ningún GT911-family alias, **bloqueador** — habría que compilar driver externamente. (En la inspección preliminar el módulo estaba; esta tarea solo lo formaliza.)

- [ ] **Step 4: Anotar el compatible elegido al final del archivo de notas**

Editar `notes/goodix-compatibles-<ts>.txt` añadiendo al final:

```
CHOSEN_COMPATIBLE=goodix,gt911
```

(O el alias preferente si la lista muestra mejor candidato — pero `goodix,gt911` es el genérico documentado.)

- [ ] **Step 5: Commit**

```bash
git add notes/
git commit -m "chore(notes): record goodix_ts compatible strings from UNO Q kernel"
```

---

## Task 3: Fase 1 — Setup Linux pre-cableado

**Files:**
- Create: `scripts/diagnose-i2c.sh`, `notes/baseline-<ts>.txt`

- [ ] **Step 1: Crear script de diagnóstico reutilizable**

El script local lanza `remote-ssh.sh` exportando la password como variable de entorno remota (`SSHPASS_REMOTE`), para que el bash remoto pueda usarla con `sudo -S`. Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/diagnose-i2c.sh`:

```bash
#!/usr/bin/env bash
# Volcado de estado I2C del UNO Q. Se ejecuta local; usa remote-ssh.sh.
# Uso: ./scripts/diagnose-i2c.sh [archivo_salida]
set -euo pipefail

OUT="${1:-/dev/stdout}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Exportar la password al shell remoto vía env-var en la línea de comando.
# Usamos heredoc UNquoted ('REMOTE_EOF' sin comillas) en la línea de invocación
# del wrapper, para que las comillas dobles capturen $SSHPASS localmente y se
# inyecte como literal en el comando que llega al servidor remoto.
"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF' | tee "$OUT"
echo "=== uname ==="; uname -a
echo
echo "=== /dev/i2c-* ==="; ls -l /dev/i2c-* 2>&1
echo
echo "=== i2cdetect -l ==="; /usr/sbin/i2cdetect -l 2>&1 || true
echo
echo "=== i2c-0 (libre, candidato) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 0 2>&1 || true
echo
echo "=== i2c-1 (display, referencia) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 1 2>&1 || true
echo
echo "=== pinmux activo (GPIO 0..30, 82, 86, 98..100) ==="
echo "$SSHPASS_REMOTE" | sudo -S cat /sys/kernel/debug/pinctrl/500000.pinctrl/pinmux-pins 2>/dev/null \
  | grep -E "^pin (0|1|2|3|18|22|23|29|30|82|86|98|99|100) "
echo
echo "=== goodix module ==="
modinfo goodix_ts 2>&1 | head -5
echo
echo "=== /dev/input/event* ==="; ls -l /dev/input/event* 2>&1 || true
REMOTE_EOF
```

Hacer ejecutable:

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/diagnose-i2c.sh
```

- [ ] **Step 2: Capturar baseline**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
TS=$(date +%Y%m%d-%H%M%S)
./scripts/diagnose-i2c.sh notes/baseline-${TS}.txt
```

Expected (resumido):
- `/dev/i2c-0` y `/dev/i2c-1` presentes.
- `i2cdetect -y 0` → fila vacía (sin direcciones detectadas).
- `i2cdetect -y 1` → varias direcciones en uso ("UU") incluyendo `0x58` (ANX7625).
- Pinmux: `pin 0` y `pin 1` con función `qup0`, claimed por `4a80000.i2c`.

- [ ] **Step 3: Añadir usuario `arduino` al grupo `i2c`**

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S usermod -aG i2c arduino && id arduino"
```

Expected: salida de `id` incluyendo `,995(i2c)` (o el GID que tenga el grupo i2c).

- [ ] **Step 4: Verificar acceso sin sudo tras relogin**

El cambio de grupo requiere nueva sesión SSH (sshpass abre sesión nueva en cada invocación, así que basta con re-ejecutar):

```bash
./scripts/remote-ssh.sh 'id; /usr/sbin/i2cdetect -y 0 2>&1 | head -3'
```

Expected: `id` muestra grupo `i2c`, `i2cdetect` corre sin pedir sudo (puede que `i2cdetect` siga necesitando privilegios para algunos modos — si falla, usar `-y` solo y verificar permiso sobre `/dev/i2c-0`).

Si `i2cdetect` sigue requiriendo sudo: aceptar y documentar en notas que las invocaciones futuras llevan `sudo` explícito. No bloqueante.

- [ ] **Step 5: Commit**

```bash
git add scripts/diagnose-i2c.sh notes/
git commit -m "feat(scripts): add I2C diagnostic + capture pre-wiring baseline"
```

---

## Task 4: Pre-soldadura — checklist mecánico y de continuidad

Esta tarea es **mayormente física** (multímetro, lupa, soldador). No hay código que correr. Documenta el procedimiento como checklist.

**Files:**
- Create: `notes/soldadura-checklist-<ts>.md`

- [ ] **Step 1: Identificar los pads/pines a soldar en ambos lados**

Lado **shield** (GIGA Display Shield ASX00039) — display touch connector:
- D101 (SCL touch) — ver `ASX00039-full-pinout.pdf` página 1
- D102 (SDA touch)
- Touch RST
- Touch INT
- 3V3 (alimentación, ya conectada si el display funciona)
- GND

Lado **UNO Q** (ABX00162) — JMEDIA connector:
- Pin **37**: SOC_GPIO_0_SE0 (SDA)
- Pin **39**: SOC_GPIO_1_SE0 (SCL)
- Pin **49**: SOC_GPIO_18 (RST)
- Pin **46**: SOC_GPIO_98 (INT)
- Pin **57**: +1V8 (referencia LV del level shifter)
- Pin **58** o **60**: +3V3 (referencia HV del level shifter; opcional si shield ya alimentado)
- Cualquier pin GND par (2, 8, 14, 20, 26, 32, 38, 44, 50, 56)

Si el equipo previo soldó a GPIO_22 (pin 53) y GPIO_23 (pin 51), **desoldar primero esos hilos**.

- [ ] **Step 2: Crear checklist de soldadura**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/notes/soldadura-checklist-<ts>.md` (con timestamp en el nombre) con el siguiente template, e ir tildando físicamente lo que se completa:

```markdown
# Checklist de soldadura — UNO Q ↔ GIGA Display Shield touch

Fecha: ____________

## Pre-trabajo
- [ ] UNO Q apagado (USB-C desconectado).
- [ ] Shield desmontado del UNO Q.
- [ ] Hilos cortos preparados (4 señales + 3 alimentación/GND).
- [ ] Level shifter listo (modelo elegido: ____________).

## Desoldar (si aplica)
- [ ] Hilo de GPIO_22 (JMEDIA pin 53) retirado.
- [ ] Hilo de GPIO_23 (JMEDIA pin 51) retirado.
- [ ] Inspección visual: pads limpios sin restos.

## Soldadura level shifter ↔ UNO Q (lado LV, 1.8V)
- [ ] JMEDIA pin 37 → shifter LV1 (SDA_LV)
- [ ] JMEDIA pin 39 → shifter LV2 (SCL_LV)
- [ ] JMEDIA pin 49 → shifter LV3 (RST_LV)
- [ ] JMEDIA pin 46 → shifter LV4 (INT_LV)
- [ ] JMEDIA pin 57 → shifter VCCA (1V8)
- [ ] JMEDIA GND → shifter GND

## Soldadura level shifter ↔ Shield (lado HV, 3.3V)
- [ ] Shifter HV1 → Shield D102 (SDA touch)
- [ ] Shifter HV2 → Shield D101 (SCL touch)
- [ ] Shifter HV3 → Shield touch RST
- [ ] Shifter HV4 → Shield touch INT
- [ ] Shifter VCCB → Shield 3V3 (o JMEDIA pin 58)
- [ ] Shifter OE → VCCA vía 10k (si es TXS0108E)

## Continuidad sin alimentar (multímetro en modo continuidad/Ohmios)
- [ ] JMEDIA pin 37 ↔ shifter LV1: continuo (<1 Ω)
- [ ] JMEDIA pin 39 ↔ shifter LV2: continuo
- [ ] JMEDIA pin 49 ↔ shifter LV3: continuo
- [ ] JMEDIA pin 46 ↔ shifter LV4: continuo
- [ ] Shifter HV1 ↔ Shield D102: continuo
- [ ] Shifter HV2 ↔ Shield D101: continuo
- [ ] Shifter HV3 ↔ Shield RST: continuo
- [ ] Shifter HV4 ↔ Shield INT: continuo
- [ ] JMEDIA pin 37 ↔ pin 39: **NO** continuo (no hay cortos SDA↔SCL)
- [ ] JMEDIA pin 37 ↔ GND: **NO** continuo
- [ ] JMEDIA pin 39 ↔ GND: **NO** continuo
- [ ] JMEDIA pin 37 ↔ pin 58 (+3V3): **NO** continuo
- [ ] JMEDIA pin 37 ↔ pin 57 (+1V8): **NO** continuo

## Inspección visual
- [ ] Sin soldaduras frías (mate, granuladas)
- [ ] Sin puentes de estaño entre pines vecinos
- [ ] Lupa: pads sin fisuras, alivio mecánico del hilo OK

## Listo para alimentar
- [ ] Todos los puntos anteriores tildados.
- [ ] Foto del cableado guardada en notes/ para referencia futura.

Notas / observaciones:
```

- [ ] **Step 3: Ejecutar el checklist y guardarlo tildado**

Una vez completada la soldadura y verificadas todas las casillas, guardar el archivo y, si es posible, una foto del cableado en `notes/soldadura-foto-<ts>.jpg`.

- [ ] **Step 4: Commit del estado de la soldadura**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
git add notes/
git commit -m "docs(hw): record soldering checklist and wiring photo"
```

---

## Task 5: Fase 2 — Detectar GT911 en bus 0 y leer Product ID

**Files:**
- Create: `scripts/verify-gt911.sh`, `notes/fase2-detect-<ts>.txt`

- [ ] **Step 1: Crear script de verificación**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/verify-gt911.sh`:

```bash
#!/usr/bin/env bash
# Verifica que el GT911 responde en i2c-0. Lee Product ID (debe ser "911\0").
set -euo pipefail

OUT="${1:-/dev/stdout}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF' | tee "$OUT"
set -e
echo "=== i2cdetect -y 0 ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 0

echo
echo "=== buscar 0x5d o 0x14 ==="
SCAN=$(echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2cdetect -y -r 0)
if echo "$SCAN" | grep -qE '\b5d\b'; then
  ADDR=0x5d
elif echo "$SCAN" | grep -qE '\b14\b'; then
  ADDR=0x14
else
  echo "ERROR: GT911 no detectado en 0x5d ni 0x14."
  exit 1
fi
echo "GT911 detectado en $ADDR"

echo
echo "=== leer Product ID (regs 0x8140-0x8143, esperado '911\\0') ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x40 r4

echo
echo "=== leer Firmware Version (0x8144-0x8145) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x44 r2

echo
echo "=== leer Resolution (0x8146-0x8149) ==="
echo "$SSHPASS_REMOTE" | sudo -S /usr/sbin/i2ctransfer -y 0 w2@${ADDR} 0x81 0x46 r4

echo "DONE_OK ADDR=$ADDR"
REMOTE_EOF
```

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/verify-gt911.sh
```

- [ ] **Step 2: Alimentar el UNO Q con el shield conectado y level shifter armado**

Acción física: conectar USB-C, esperar boot (~30s), confirmar que aparece la pantalla de login como antes.

- [ ] **Step 3: Esperar arranque y ejecutar verificación**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
TS=$(date +%Y%m%d-%H%M%S)
./scripts/verify-gt911.sh notes/fase2-detect-${TS}.txt
echo "exit code: $?"
```

Expected (caso éxito):
- `i2cdetect -y 0` muestra una dirección no vacía en 0x5d o 0x14.
- Product ID lee `0x39 0x31 0x31 0x00` (ASCII "911\0").
- Firmware version y resolución muestran bytes válidos (no `0xff 0xff` ni timeout).
- Línea final: `DONE_OK ADDR=0x5d` (o 0x14), exit code 0.

- [ ] **Step 4: Si falla en Step 3, diagnóstico eléctrico**

**Si i2cdetect NO muestra nada:**

1. Medir con multímetro en lado LV del shifter:
   - SDA idle: debería ser ~1.8V.
   - SCL idle: debería ser ~1.8V.
   - Si NO llega a 1.8V → shifter no recibe alimentación, o pull-ups del shield no atraviesan; revisar VCCA del shifter (debe ser 1V8) y continuidad con JMEDIA pin 57.
2. Medir en lado HV del shifter:
   - SDA idle: debería ser ~3.3V.
   - SCL idle: debería ser ~3.3V.
   - Si NO llega a 3.3V → VCCB del shifter mal conectado, o shield sin alimentación.
3. Si todas las tensiones idle son correctas pero scanner vacío → osciloscopio en SDA durante `i2cdetect`: debe ver pulsos. Si no hay pulsos → el SoC no está driving (problema de driver o pinmux); volver a Task 3 Step 2 para reconfirmar pinmux.
4. Si hay pulsos pero el GT911 no responde → revisar RST: con multímetro, ¿RST está en 3.3V (no flotante)? Si está bajo, el chip está en reset permanente. Si está alto, ¿está conectado a GPIO_18 del UNO Q?
5. Registrar todas las mediciones en `notes/fase2-detect-${TS}.txt` (apéndice manual al archivo).

**Si i2cdetect ve 0x14 en vez de 0x5d:**
Es normal — indica que INT estaba alto durante boot. Continuar; el `ADDR` queda registrado y la Fase 4 usará la dirección observada.

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-gt911.sh notes/
git commit -m "feat(scripts): verify GT911 on i2c-0 + record Product ID readout"
```

---

## Task 6: Fase 3 — Bind manual del driver `goodix_ts` y validar evtest

**Files:**
- Create: `scripts/bind-gt911.sh`, `scripts/unbind-gt911.sh`, `notes/fase3-evtest-<ts>.txt`

- [ ] **Step 1: Crear script de bind**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/bind-gt911.sh`:

```bash
#!/usr/bin/env bash
# Bind manual del GT911 vía sysfs. Imprime el evdev creado.
# Argumento opcional: dirección I2C (default 0x5d).
set -euo pipefail

ADDR="${1:-0x5d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR='$ADDR' bash -s" << 'REMOTE_EOF'
set -e
echo "=== cargar modulo goodix_ts ==="
echo "$SSHPASS_REMOTE" | sudo -S modprobe goodix_ts
lsmod | grep -E '^goodix' || true

# Cachear credenciales de sudo para los siguientes comandos
echo "$SSHPASS_REMOTE" | sudo -S -v

echo
echo "=== sysfs new_device gt911 $ADDR ==="
# NOTA: no se puede usar 'echo X | sudo -S tee' porque sudo -S consume todo
# stdin como password. Cachear sudo arriba y luego usar tee normal.
echo "gt911 $ADDR" | sudo tee /sys/bus/i2c/devices/i2c-0/new_device

# wait for bind
sleep 1

echo
echo "=== dmesg last 30 lines ==="
sudo dmesg | tail -30 | grep -iE 'goodix|input|i2c' || true

echo
echo "=== input devices con 'Goodix' ==="
grep -A4 -i goodix /proc/bus/input/devices || echo "NO encontrado"

echo
echo "=== /dev/input/event* ==="
ls -l /dev/input/event* 2>&1
REMOTE_EOF
```

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/bind-gt911.sh
```

- [ ] **Step 2: Crear script de unbind (cleanup)**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/unbind-gt911.sh`:

```bash
#!/usr/bin/env bash
# Remueve el GT911 instanciado vía sysfs.
set -euo pipefail

ADDR="${1:-0x5d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR='$ADDR' bash -s" << 'REMOTE_EOF'
set -e
echo "$SSHPASS_REMOTE" | sudo -S -v
echo "$ADDR" | sudo tee /sys/bus/i2c/devices/i2c-0/delete_device
echo "Unbind OK para $ADDR"
REMOTE_EOF
```

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/unbind-gt911.sh
```

- [ ] **Step 3: Ejecutar bind con la dirección detectada en Task 5**

Usar la dirección reportada por `verify-gt911.sh` (típicamente `0x5d`).

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
./scripts/bind-gt911.sh 0x5d
```

Expected:
- `lsmod` muestra `goodix_ts`.
- `tee /sys/bus/i2c/devices/i2c-0/new_device` succeeds (eco de "gt911 0x5d").
- dmesg incluye una línea tipo `goodix i2c-0-005d: Goodix-TS Product id: GT911` (texto exacto depende de la versión del driver).
- `/proc/bus/input/devices` muestra un dispositivo "Goodix Capacitive TouchScreen".
- `/dev/input/event*` lista un evento nuevo respecto al baseline.

**Si falla con "Resource busy" o "no such device":** ya fue instanciado en una iteración previa — ejecutar primero `./scripts/unbind-gt911.sh 0x5d` y reintentar.

- [ ] **Step 4: Capturar evtest en vivo y guardarlo**

```bash
TS=$(date +%Y%m%d-%H%M%S)
# Identificar el event device del touch (último creado)
EVENT_DEV=$(./scripts/remote-ssh.sh 'grep -B1 -i goodix /proc/bus/input/devices | grep -oE "event[0-9]+" | head -1')
echo "Touch device: /dev/input/$EVENT_DEV"

# Capturar 20 segundos de evtest, durante los cuales el usuario debe tocar la pantalla
./scripts/remote-ssh.sh "SSHPASS_REMOTE='$SSHPASS' bash -s" << REMOTE_EOF | tee notes/fase3-evtest-${TS}.txt
echo "$SSHPASS_REMOTE" | sudo -S timeout 20 evtest /dev/input/$EVENT_DEV
REMOTE_EOF
```

Durante los 20 segundos: tocar la pantalla con un dedo, hacer un par de slides, soltar.

Expected en la salida:
- Cabecera con `Input device name: "Goodix Capacitive TouchScreen"`.
- Lista de capabilities con `ABS_MT_POSITION_X`, `ABS_MT_POSITION_Y`, `ABS_MT_TRACKING_ID`, `BTN_TOUCH`.
- Eventos en tiempo real al tocar: líneas tipo `Event: time XXX, type 3 (EV_ABS), code 53 (ABS_MT_POSITION_X), value NNNN`.

**Si NO se ven eventos al tocar:**
1. El driver está bound pero el chip no genera datos. Causa probable: INT no conectado correctamente, el driver está en polling y falla. Volver al Task 4 (continuidad de INT) y al Task 5 (lectura cruda de touch points: `i2ctransfer -y 0 w2@0x5d 0x81 0x4e r1` debe cambiar al tocar).
2. Si la lectura cruda funciona pero evtest no → bug del driver o mismatch entre dirección y compatible. Probar unbind + bind con `gt928` u otra variante.

- [ ] **Step 5: Commit**

```bash
git add scripts/bind-gt911.sh scripts/unbind-gt911.sh notes/
git commit -m "feat(scripts): GT911 sysfs bind/unbind + capture working evtest output"
```

---

## Task 7: Fase 4a — Persistencia vía edición binaria del DTB con `fdtput`

**Files:**
- Create: `scripts/patch-dtb.sh`, `notes/dtb-patch-<ts>.txt`

- [ ] **Step 1: Confirmar que `fdtput` está disponible en el UNO Q**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
./scripts/remote-ssh.sh 'which fdtput fdtget; fdtput --help 2>&1 | head -10'
```

Expected: `/usr/bin/fdtput` presente. Ya lo confirmamos en diagnóstico previo.

- [ ] **Step 2: Backup del DTB activo en el dispositivo y traer copia local**

```bash
TS=$(date +%Y%m%d-%H%M%S)
./scripts/remote-ssh.sh "SSHPASS_REMOTE='$SSHPASS' bash -s" << 'REMOTE_EOF'
echo "$SSHPASS_REMOTE" | sudo -S cp /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb.backup
ls -l /boot/efi/*.dtb*
REMOTE_EOF

# traer copia local también
sshpass -e scp arduino@192.168.0.XXX:/boot/efi/qrb2210-arduino-imola-gigadisplay.dtb /tmp/uno-q-dtb-${TS}.dtb
ls -l /tmp/uno-q-dtb-${TS}.dtb
```

Expected: archivo `.dtb.backup` creado en `/boot/efi`, copia local en `/tmp` (no commiteamos el DTB binario al repo por tamaño).

- [ ] **Step 3: Listar nodos hijos actuales de `i2c@4a80000` (debe estar vacío)**

```bash
./scripts/remote-ssh.sh 'fdtget -l /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb /soc@0/geniqup@4ac0000/i2c@4a80000 2>&1'
```

Expected: lista vacía (sin hijos). Si ya hay un `gt911@5d` u otro nodo, **detenerse y revisar** — significa que alguien más ya patcheó el DTB.

- [ ] **Step 4: Crear script `patch-dtb.sh` que añade el nodo gt911**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/patch-dtb.sh`:

```bash
#!/usr/bin/env bash
# Inyecta el nodo gt911@5d bajo i2c@4a80000 del DTB activo del UNO Q usando fdtput.
# Idempotente: si el nodo ya existe lo sobreescribe.
#
# IMPORTANTE: las propiedades irq-gpios y reset-gpios necesitan referenciar el
# phandle del controlador TLMM. Este script lo descubre en runtime.
set -euo pipefail

ADDR_HEX="${1:-0x5d}"
COMPATIBLE="${2:-goodix,gt911}"
IRQ_GPIO_NUM="${3:-98}"
RST_GPIO_NUM="${4:-18}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR_HEX='$ADDR_HEX' COMPATIBLE='$COMPATIBLE' IRQ_GPIO='$IRQ_GPIO_NUM' RST_GPIO='$RST_GPIO_NUM' bash -s" << 'REMOTE_EOF'
set -euo pipefail
DTB=/boot/efi/qrb2210-arduino-imola-gigadisplay.dtb
NODE=/soc@0/geniqup@4ac0000/i2c@4a80000/gt911@$(echo $ADDR_HEX | sed 's/0x//')

echo "=== descubrir phandle del TLMM (pinctrl@500000) ==="
TLMM_PH=$(fdtget -t x $DTB /soc@0/pinctrl@500000 phandle)
echo "TLMM phandle: $TLMM_PH"

if [[ -z "$TLMM_PH" ]]; then
  echo "ERROR: no se pudo leer phandle del TLMM"; exit 1
fi

ADDR_INT=$((ADDR_HEX))

echo
echo "=== añadir nodo $NODE ==="
# Crear el nodo y todas sus props
echo "$SSHPASS_REMOTE" | sudo -S fdtput -t s  $DTB $NODE compatible "$COMPATIBLE"
echo "$SSHPASS_REMOTE" | sudo -S fdtput -t x  $DTB $NODE reg $ADDR_INT
# irq-gpios = <&tlmm IRQ_GPIO IRQ_TYPE_EDGE_FALLING>;  -> 3 celdas
# IRQ_TYPE_EDGE_FALLING = 2
echo "$SSHPASS_REMOTE" | sudo -S fdtput -t x  $DTB $NODE irq-gpios $TLMM_PH $IRQ_GPIO 2
# reset-gpios = <&tlmm RST_GPIO GPIO_ACTIVE_HIGH>;  GPIO_ACTIVE_HIGH = 0
echo "$SSHPASS_REMOTE" | sudo -S fdtput -t x  $DTB $NODE reset-gpios $TLMM_PH $RST_GPIO 0
echo "$SSHPASS_REMOTE" | sudo -S fdtput -t s  $DTB $NODE status "okay"

echo
echo "=== verificar nodo creado ==="
fdtget -p $DTB $NODE
echo "compatible: $(fdtget -t s $DTB $NODE compatible)"
echo "reg: $(fdtget -t x $DTB $NODE reg)"
echo "irq-gpios: $(fdtget -t x $DTB $NODE irq-gpios)"
echo "reset-gpios: $(fdtget -t x $DTB $NODE reset-gpios)"
echo "status: $(fdtget -t s $DTB $NODE status)"
echo
echo "DTB patch DONE. Reboot needed."
REMOTE_EOF
```

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/patch-dtb.sh
```

**Nota importante sobre `fdtput`:** no soporta directamente strings como `IRQ_TYPE_EDGE_FALLING` ni `GPIO_ACTIVE_HIGH`; usamos los valores enteros (2 y 0). Tampoco soporta `#address-cells`/`#size-cells` automáticos para crear nodos con direcciones unit — el nodo se llama `gt911@5d` (el `@5d` es convención, no propiedad). `fdtput` lo crea como nodo simple, lo cual es válido para el driver porque el binding usa `reg`, no el nombre.

- [ ] **Step 5: Ejecutar el patch**

Primero, **unbind del cliente sysfs activo** para evitar conflicto con el nuevo bind automático tras reboot:

```bash
./scripts/unbind-gt911.sh 0x5d
```

Después:

```bash
TS=$(date +%Y%m%d-%H%M%S)
./scripts/patch-dtb.sh 0x5d goodix,gt911 98 18 | tee notes/dtb-patch-${TS}.txt
```

Expected:
- Phandle del TLMM impreso (valor hexadecimal cualquiera, no cero).
- Nodo `gt911@5d` creado con todas las props leídas de vuelta correctamente.
- Línea final `DTB patch DONE. Reboot needed.`.

**Si `fdtput` falla con "FDT_ERR_NOSPACE":** el DTB binario no tiene padding suficiente. Solución:

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S fdtput -s 8192 /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb"
```

Y reintentar el patch.

- [ ] **Step 6: Reboot y verificar bind automático**

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S reboot" || true
echo "Esperando 45s para reboot..."
sleep 45

# Reintentar conexión cada 5s hasta tener éxito
for i in 1 2 3 4 5 6; do
  if ./scripts/remote-ssh.sh 'echo UP' 2>/dev/null; then break; fi
  echo "retry $i..."; sleep 5
done

# Verificar bind sin intervención manual
./scripts/diagnose-i2c.sh notes/post-reboot-${TS}.txt
./scripts/remote-ssh.sh 'grep -A4 -i goodix /proc/bus/input/devices'
```

Expected: aparece el dispositivo Goodix en `/proc/bus/input/devices` y un nuevo `/dev/input/event*` sin haber ejecutado bind manual.

- [ ] **Step 7: Validar funcional con evtest tras reboot**

```bash
EVENT_DEV=$(./scripts/remote-ssh.sh 'grep -B1 -i goodix /proc/bus/input/devices | grep -oE "event[0-9]+" | head -1')
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S timeout 15 evtest /dev/input/$EVENT_DEV" | tee notes/post-reboot-evtest-${TS}.txt
```

Durante los 15s, tocar pantalla. Expected: eventos `ABS_MT_*` y `BTN_TOUCH`.

- [ ] **Step 8: Commit**

```bash
git add scripts/patch-dtb.sh notes/
git commit -m "feat(scripts): patch DTB to persist gt911 child of i2c-0 via fdtput"
```

- [ ] **Step 9: Si TODO el Task 7 falla irreversiblemente, restaurar backup y saltar a Task 9 (fallback systemd)**

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S cp /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb.backup /boot/efi/qrb2210-arduino-imola-gigadisplay.dtb"
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S reboot" || true
sleep 45
```

Luego ir al Task 9.

---

## Task 8: Validación end-to-end y stress

**Files:**
- Create: `notes/e2e-validation-<ts>.md`

- [ ] **Step 1: Cold-boot test**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S poweroff" || true
echo "Espera 30s y vuelve a conectar USB-C manualmente (poweroff completo)."
read -p "Presiona enter cuando hayas vuelto a conectar USB-C..."
sleep 60
# verificar que vuelve solo
for i in 1 2 3 4 5 6 7 8; do
  if ./scripts/remote-ssh.sh 'echo UP' 2>/dev/null; then break; fi
  echo "retry $i..."; sleep 10
done
```

- [ ] **Step 2: Verificar device evdev presente sin intervención**

```bash
TS=$(date +%Y%m%d-%H%M%S)
./scripts/remote-ssh.sh 'ls /dev/input/event*; grep -A4 -i goodix /proc/bus/input/devices' | tee notes/e2e-validation-${TS}.md
```

Expected: device Goodix listado.

- [ ] **Step 3: 50 toques continuos sin stuck**

Capturar 60s de eventos durante uso intensivo:

```bash
EVENT_DEV=$(./scripts/remote-ssh.sh 'grep -B1 -i goodix /proc/bus/input/devices | grep -oE "event[0-9]+" | head -1')
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S timeout 60 evtest /dev/input/$EVENT_DEV" | tee -a notes/e2e-validation-${TS}.md
```

Durante 60s, hacer al menos 50 toques + 10 slides. Expected: cada toque genera `BTN_TOUCH=1` + coords + `BTN_TOUCH=0`. Sin coordenadas trabadas a un valor fijo entre toques.

- [ ] **Step 4: Verificar dmesg limpio (sin errores de driver)**

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S dmesg | grep -iE 'goodix|error|fail|i2c' | tail -30" | tee -a notes/e2e-validation-${TS}.md
```

Expected: ninguna línea con "error" o "fail" relacionada al touch. Solo info de bind.

- [ ] **Step 5: Documentar resultado final**

Editar `notes/e2e-validation-<ts>.md` añadiendo al final:

```markdown
## Resultado E2E

- [ ] Cold boot OK
- [ ] evdev presente sin intervención
- [ ] 50+ toques sin stuck
- [ ] dmesg sin errores

Fecha: ____________
Notas: ____________
```

- [ ] **Step 6: Commit**

```bash
git add notes/
git commit -m "docs(validation): end-to-end test results — touch fully functional"
```

---

## Task 9: (Contingency) Fase 4b — Fallback systemd unit

**Solo ejecutar si Task 7 falló irreversiblemente y se restauró el DTB original.**

**Files:**
- Create: `scripts/install-systemd-bind.sh`, `notes/systemd-bind-<ts>.txt`

- [ ] **Step 1: Crear script que instala unit systemd remotamente**

Crear `/path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/install-systemd-bind.sh`:

```bash
#!/usr/bin/env bash
# Instala un systemd unit que hace bind del GT911 vía sysfs al boot.
# Limitación: el driver opera en polling (sin INT/RST gestionados por DT).
set -euo pipefail

ADDR="${1:-0x5d}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/remote-ssh.sh" "SSHPASS_REMOTE='$SSHPASS' ADDR='$ADDR' bash -s" << 'REMOTE_EOF'
set -e
UNIT=/etc/systemd/system/giga-touch-bind.service

# Cachear sudo para los pasos siguientes
echo "$SSHPASS_REMOTE" | sudo -S -v

echo "=== escribir unit (vía archivo temporal para no chocar con sudo -S) ==="
TMP=$(mktemp)
cat > "$TMP" <<UNITEOF
[Unit]
Description=Bind GT911 touch on i2c-0 at boot
After=systemd-modules-load.service
Before=graphical.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'modprobe goodix_ts; echo gt911 $ADDR > /sys/bus/i2c/devices/i2c-0/new_device'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
sudo install -m 0644 "$TMP" "$UNIT"
rm -f "$TMP"

echo "=== enable & start ==="
sudo systemctl daemon-reload
sudo systemctl enable giga-touch-bind.service
sudo systemctl start giga-touch-bind.service

echo
echo "=== status ==="
sudo systemctl status giga-touch-bind.service --no-pager || true
REMOTE_EOF
```

```bash
chmod +x /path/to/repo/Documents/electroniccats/i2c_arduinoQ/scripts/install-systemd-bind.sh
```

- [ ] **Step 2: Ejecutar instalación**

```bash
cd /path/to/repo/Documents/electroniccats/i2c_arduinoQ
TS=$(date +%Y%m%d-%H%M%S)
./scripts/install-systemd-bind.sh 0x5d | tee notes/systemd-bind-${TS}.txt
```

Expected: unit creado, enabled, active. `systemctl status` muestra Active: active (exited).

- [ ] **Step 3: Verificar que el bind ocurrió**

```bash
./scripts/remote-ssh.sh 'grep -A4 -i goodix /proc/bus/input/devices; ls /dev/input/event*'
```

Expected: device Goodix presente.

- [ ] **Step 4: Reboot y validar persistencia**

```bash
./scripts/remote-ssh.sh "echo '$SSHPASS' | sudo -S reboot" || true
sleep 60
for i in 1 2 3 4 5; do
  if ./scripts/remote-ssh.sh 'echo UP' 2>/dev/null; then break; fi
  sleep 10
done
./scripts/remote-ssh.sh 'systemctl status giga-touch-bind.service --no-pager; grep -A4 -i goodix /proc/bus/input/devices'
```

Expected: tras reboot, unit activo y device Goodix presente.

- [ ] **Step 5: Saltar a Task 8 (validación E2E) con esta configuración**

- [ ] **Step 6: Commit**

```bash
git add scripts/install-systemd-bind.sh notes/
git commit -m "feat(scripts): systemd unit fallback for sysfs bind at boot"
```

---

## Self-review notes (interno del autor del plan)

Cobertura del spec:
- Spec §4 (hardware) → Task 4 (checklist).
- Spec §5 Fase 1 → Task 3.
- Spec §5 Fase 2 → Task 5.
- Spec §5 Fase 3 → Task 6.
- Spec §5 Fase 4a → Task 7.
- Spec §5 Fase 4b → Task 9.
- Spec §6 (validación E2E) → Task 8.
- Spec §7 (riesgos) → reflejados en pasos de diagnóstico de Tasks 5/6/7.
- Spec §8 (decisiones abiertas) → resueltas: compatible string en Task 2, level shifter como variable de Task 4, GPIOs RST/INT parametrizados en Task 7.

Sin placeholders TBD. Cada tarea tiene archivos exactos, comandos exactos, outputs esperados, y un commit al final.
