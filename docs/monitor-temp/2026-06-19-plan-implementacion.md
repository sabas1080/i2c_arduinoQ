# Monitor de temperatura en kiosko — Plan de implementación

> **Para trabajadores agénticos:** SUB-SKILL REQUERIDA: usar `superpowers:subagent-driven-development` (recomendado) o `superpowers:executing-plans` para implementar este plan tarea por tarea. Los pasos usan checkbox (`- [ ]`) para seguimiento.

**Goal:** App en Arduino UNO Q que lee un sensor I2C, lo muestra a pantalla completa en el GIGA Display Shield con número grande + estado por color, permite ajustar el umbral de alerta por touch y registra a CSV, arrancando en modo kiosko sin login.

**Architecture:** App híbrida de Arduino App Lab. Un sketch en el STM32 lee el sensor por `Wire1` (Qwiic) y lo expone por el bridge RPC. Un servicio Python en Linux hace poll del bridge, aplica lógica de umbral/histéresis, registra a CSV y sirve un mini HTTP local (`/api/state`, `/api/action`) consumido por una UI estática. Chromium en `--kiosk` muestra la UI en el panel DSI; el touch GT911 actúa como mouse en X. Autologin de LightDM + autostart eliminan el login.

**Tech Stack:** Arduino sketch (C++, `Wire1`, bridge App Lab), Python 3 (solo stdlib: `http.server`, `json`, `csv`, `threading`), HTML/CSS/JS estático, Chromium kiosko, LightDM, App Lab CLI.

## Global Constraints

- Python **solo stdlib** — sin dependencias externas (`http.server`, `socketserver`, `json`, `csv`, `threading`, `datetime`). Salvo el módulo bridge que provee el entorno de App Lab.
- Device destino: Arduino UNO Q, Debian 13 trixie, kernel 7.0.0, usuario `arduino`.
- El I2C del header/Qwiic está cableado al **STM32**: el sensor se lee desde el sketch, **nunca** desde Linux directo.
- Sensor de referencia en el código: **MCP9808** (dir `0x18`). Las líneas específicas del sensor están marcadas `// SENSOR-ESPECÍFICO` para sustituir por el chip real.
- Puerto del servidor local: **8080**, escuchando en `127.0.0.1`.
- Ruta CSV por defecto: `~/monitor-temp/lecturas.csv`.
- Tests unitarios de Python corren en la **máquina de desarrollo** (lógica pura, sin hardware) con `pytest`.

---

### Task 1: Activar DSI + touch en el device (prerrequisito)

No hay código nuevo. Deja el device destino con pantalla y touch operativos; sin esto nada de lo demás se puede ver/tocar.

**Files:**
- Usa: `scripts/enable-gigadisplay-shield.sh` (ya en el repo)

**Interfaces:**
- Produces: device con `card0-DSI-1 = connected`, módulos `goodix` + `st7701` cargados, un `/dev/input/eventN` con eventos `ABS_MT_*`.

- [ ] **Step 1: Copiar el bootstrap al device**

```bash
scp scripts/enable-gigadisplay-shield.sh scripts/gigadisplay-shield.dtso arduino@<IP>:~/
```

- [ ] **Step 2: Ejecutar el bootstrap en el device**

```bash
ssh arduino@<IP> 'sudo bash ~/enable-gigadisplay-shield.sh'
ssh arduino@<IP> 'sudo reboot'
```

- [ ] **Step 3: Verificar pantalla + módulos**

```bash
ssh arduino@<IP> 'cat /sys/class/drm/card0-DSI-1/status; lsmod | grep -E "goodix|st7701"'
```
Expected: `connected` y ambos módulos listados.

- [ ] **Step 4: Verificar touch**

```bash
ssh arduino@<IP> 'cat /proc/bus/input/devices | grep -iA5 goodix'
```
Expected: un device con `Handlers=... eventN`. Tocar la pantalla durante `evtest /dev/input/eventN` muestra eventos `ABS_MT_POSITION_X/Y`.

*(No hay commit: es configuración del device, no del repo.)*

---

### Task 2: Esqueleto de la app en App Lab

Crear la estructura de la app y confirmar que App Lab la reconoce, compila el sketch vacío y arranca el Python vacío. Aquí se **confirma el API del bridge** contra la plantilla real de App Lab.

**Files:**
- Create: `apps/monitor-temp/app.yaml`
- Create: `apps/monitor-temp/sketch/sensor.ino`
- Create: `apps/monitor-temp/python/main.py`

**Interfaces:**
- Produces: app `monitor-temp` listable por `arduino-app-cli`, con un sketch y un `main.py` mínimos que arrancan sin error.

- [ ] **Step 1: Crear `app.yaml`**

Crear una app vacía desde App Lab (UI: "Create new app +") o CLI, y ajustar `app.yaml` para declarar el sketch y el python. Estructura mínima esperada (confirmar campos exactos contra la app generada por App Lab):

```yaml
name: monitor-temp
sketches:
  - sketch/sensor.ino
python:
  - python/main.py
```

- [ ] **Step 2: Sketch mínimo que compila**

`apps/monitor-temp/sketch/sensor.ino`:
```cpp
#include <Wire.h>
// El objeto Bridge lo provee la plantilla de App Lab (confirmar include exacto).

void setup() {
  Wire1.begin();            // Qwiic = Wire1 en UNO Q
}

void loop() {
  delay(1000);
}
```

- [ ] **Step 3: Python mínimo que arranca**

`apps/monitor-temp/python/main.py`:
```python
def main():
    print("monitor-temp: arranque OK")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Correr la app desde App Lab**

Run en App Lab (o `arduino-app-cli run monitor-temp` — confirmar subcomando). 
Expected: el sketch compila/flashea y el log Python muestra `monitor-temp: arranque OK`.

- [ ] **Step 5: Confirmar y anotar el API del bridge**

Revisar en la app generada / docs de App Lab los nombres exactos de:
- include del bridge en el sketch,
- `Bridge.provide("nombre", func)` (firma del callback),
- módulo/clase Python y `Bridge.call("nombre")`.
Anotarlos en un comentario al inicio de `sensor.ino` y `main.py`. (Las Tasks 3 y 5 dependen de esto.)

- [ ] **Step 6: Commit**

```bash
git add apps/monitor-temp/
git commit -m "feat(monitor): esqueleto de app App Lab (sketch+python+yaml)"
```

---

### Task 3: Sketch — leer sensor por Wire1 y exponer por bridge

**Files:**
- Modify: `apps/monitor-temp/sketch/sensor.ino`

**Interfaces:**
- Produces: función bridge `read_temp` → `float` grados °C. Devuelve `NaN` si el sensor no responde.

- [ ] **Step 1: Implementar lectura del sensor (MCP9808) + bridge**

Reemplazar el contenido de `sensor.ino`:
```cpp
#include <Wire.h>
// Bridge: include según plantilla App Lab (ver comentario de Task 2 Step 5).

const uint8_t SENSOR_ADDR = 0x18;   // SENSOR-ESPECÍFICO (MCP9808)

// Lee °C del sensor. Devuelve NAN si no responde.
float leerTemp() {
  // SENSOR-ESPECÍFICO: MCP9808 registro 0x05 (temperatura ambiente)
  Wire1.beginTransmission(SENSOR_ADDR);
  Wire1.write(0x05);
  if (Wire1.endTransmission() != 0) return NAN;
  if (Wire1.requestFrom((int)SENSOR_ADDR, 2) != 2) return NAN;
  uint8_t upper = Wire1.read();
  uint8_t lower = Wire1.read();
  upper &= 0x1F;
  float t;
  if (upper & 0x10) {            // bandera de negativo
    upper &= 0x0F;
    t = 256.0 - (upper * 16.0 + lower / 16.0);
  } else {
    t = upper * 16.0 + lower / 16.0;
  }
  return t;
}

// Callback expuesto al lado Linux por el bridge.
float read_temp() {
  return leerTemp();
}

void setup() {
  Wire1.begin();
  Bridge.provide("read_temp", read_temp);   // confirmar firma exacta (Task 2 Step 5)
}

void loop() {
  Bridge.update();   // o equivalente del bridge; confirmar nombre
  delay(50);
}
```

- [ ] **Step 2: Flashear y verificar lectura plausible**

Run en App Lab. Con el sensor conectado al Qwiic, agregar temporalmente en `loop()` un `Serial.println(leerTemp())` y observar el monitor serie.
Expected: valor entre ~15 y ~35 °C a temperatura ambiente; sube al tocar/calentar el sensor; `nan` si se desconecta. Quitar el `Serial.println` temporal tras verificar.

- [ ] **Step 3: Commit**

```bash
git add apps/monitor-temp/sketch/sensor.ino
git commit -m "feat(monitor): sketch lee MCP9808 por Wire1 y expone read_temp por bridge"
```

---

### Task 4: Lógica pura de estado y umbral (TDD)

Lógica sin hardware ni red: evaluación de estado con histéresis y ajuste de umbral. Totalmente testeable con pytest en la máquina de desarrollo.

**Files:**
- Create: `apps/monitor-temp/python/monitor/__init__.py` (vacío)
- Create: `apps/monitor-temp/python/monitor/estado.py`
- Test: `apps/monitor-temp/python/tests/test_estado.py`

**Interfaces:**
- Produces:
  - `evaluar_estado(temp: float | None, umbral: float, estado_prev: str, hist: float = 0.5) -> str` → `"ok" | "alerta" | "sin_dato"`.
  - `ajustar_umbral(umbral: float, paso: float, direccion: str) -> float` (`direccion` ∈ `"subir"|"bajar"`).

- [ ] **Step 1: Escribir los tests que fallan**

`apps/monitor-temp/python/tests/test_estado.py`:
```python
import math
from monitor.estado import evaluar_estado, ajustar_umbral


def test_temp_bajo_umbral_es_ok():
    assert evaluar_estado(20.0, 30.0, "ok") == "ok"


def test_temp_sobre_umbral_es_alerta():
    assert evaluar_estado(31.0, 30.0, "ok") == "alerta"


def test_histeresis_mantiene_alerta_en_zona_muerta():
    # entre (umbral - hist) y umbral, si ya estaba en alerta, sigue en alerta
    assert evaluar_estado(29.7, 30.0, "alerta", hist=0.5) == "alerta"


def test_histeresis_baja_a_ok_bajo_umbral_menos_hist():
    assert evaluar_estado(29.4, 30.0, "alerta", hist=0.5) == "ok"


def test_temp_none_es_sin_dato():
    assert evaluar_estado(None, 30.0, "ok") == "sin_dato"


def test_temp_nan_es_sin_dato():
    assert evaluar_estado(math.nan, 30.0, "ok") == "sin_dato"


def test_ajustar_umbral_sube_y_baja():
    assert ajustar_umbral(30.0, 0.5, "subir") == 30.5
    assert ajustar_umbral(30.0, 0.5, "bajar") == 29.5
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_estado.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'monitor.estado'`.

- [ ] **Step 3: Implementar la lógica mínima**

`apps/monitor-temp/python/monitor/estado.py`:
```python
import math


def evaluar_estado(temp, umbral, estado_prev, hist=0.5):
    """Devuelve 'ok', 'alerta' o 'sin_dato' aplicando histéresis."""
    if temp is None or (isinstance(temp, float) and math.isnan(temp)):
        return "sin_dato"
    if temp >= umbral:
        return "alerta"
    if estado_prev == "alerta" and temp >= umbral - hist:
        return "alerta"  # zona muerta: no soltar la alerta todavía
    return "ok"


def ajustar_umbral(umbral, paso, direccion):
    if direccion == "subir":
        return umbral + paso
    if direccion == "bajar":
        return umbral - paso
    raise ValueError(f"direccion inválida: {direccion}")
```

Crear también `apps/monitor-temp/python/monitor/__init__.py` vacío.

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_estado.py -v`
Expected: PASS (7 passed).

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/python/monitor/ apps/monitor-temp/python/tests/test_estado.py
git commit -m "feat(monitor): lógica de estado con histéresis y ajuste de umbral (TDD)"
```

---

### Task 5: Registro a CSV (TDD)

**Files:**
- Create: `apps/monitor-temp/python/monitor/registro.py`
- Test: `apps/monitor-temp/python/tests/test_registro.py`

**Interfaces:**
- Consumes: nada de tareas previas.
- Produces: `registrar(ruta: str, ts: str, temp, umbral: float, estado: str) -> None` — crea el archivo con header `ts,temp,umbral,estado` si no existe y hace append de una fila. `temp` puede ser `None` (escribe celda vacía).

- [ ] **Step 1: Escribir los tests que fallan**

`apps/monitor-temp/python/tests/test_registro.py`:
```python
import csv
from monitor.registro import registrar


def test_crea_header_y_fila(tmp_path):
    ruta = tmp_path / "lecturas.csv"
    registrar(str(ruta), "2026-06-19T10:00:00", 22.5, 30.0, "ok")
    filas = list(csv.reader(ruta.open()))
    assert filas[0] == ["ts", "temp", "umbral", "estado"]
    assert filas[1] == ["2026-06-19T10:00:00", "22.5", "30.0", "ok"]


def test_append_no_duplica_header(tmp_path):
    ruta = tmp_path / "lecturas.csv"
    registrar(str(ruta), "t1", 20.0, 30.0, "ok")
    registrar(str(ruta), "t2", 31.0, 30.0, "alerta")
    filas = list(csv.reader(ruta.open()))
    assert len(filas) == 3          # header + 2 filas
    assert filas[0][0] == "ts"


def test_temp_none_escribe_celda_vacia(tmp_path):
    ruta = tmp_path / "lecturas.csv"
    registrar(str(ruta), "t1", None, 30.0, "sin_dato")
    filas = list(csv.reader(ruta.open()))
    assert filas[1] == ["t1", "", "30.0", "sin_dato"]
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_registro.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'monitor.registro'`.

- [ ] **Step 3: Implementar el registro**

`apps/monitor-temp/python/monitor/registro.py`:
```python
import csv
import os

HEADER = ["ts", "temp", "umbral", "estado"]


def registrar(ruta, ts, temp, umbral, estado):
    nuevo = not os.path.exists(ruta)
    os.makedirs(os.path.dirname(ruta) or ".", exist_ok=True)
    with open(ruta, "a", newline="") as f:
        w = csv.writer(f)
        if nuevo:
            w.writerow(HEADER)
        temp_celda = "" if temp is None else temp
        w.writerow([ts, temp_celda, umbral, estado])
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_registro.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/python/monitor/registro.py apps/monitor-temp/python/tests/test_registro.py
git commit -m "feat(monitor): registro a CSV con header y append (TDD)"
```

---

### Task 6: Estado compartido seguro entre hilos (TDD)

El poll loop y el servidor HTTP corren en hilos distintos y comparten estado. Encapsularlo evita condiciones de carrera.

**Files:**
- Create: `apps/monitor-temp/python/monitor/almacen.py`
- Test: `apps/monitor-temp/python/tests/test_almacen.py`

**Interfaces:**
- Consumes: `ajustar_umbral` de `monitor.estado`.
- Produces: clase `Almacen(umbral_inicial: float, paso: float)` con:
  - `.snapshot() -> dict` → `{"temp","umbral","estado","alarma_reconocida","ts"}`
  - `.actualizar_lectura(temp, estado, ts) -> None`
  - `.accion(nombre: str) -> dict` (`"subir"|"bajar"|"reconocer"`), devuelve snapshot nuevo.

- [ ] **Step 1: Escribir los tests que fallan**

`apps/monitor-temp/python/tests/test_almacen.py`:
```python
from monitor.almacen import Almacen


def test_snapshot_inicial():
    a = Almacen(umbral_inicial=30.0, paso=0.5)
    s = a.snapshot()
    assert s["umbral"] == 30.0
    assert s["estado"] == "sin_dato"
    assert s["alarma_reconocida"] is False


def test_actualizar_lectura():
    a = Almacen(30.0, 0.5)
    a.actualizar_lectura(22.0, "ok", "t1")
    s = a.snapshot()
    assert s["temp"] == 22.0
    assert s["estado"] == "ok"
    assert s["ts"] == "t1"


def test_accion_subir_y_bajar_umbral():
    a = Almacen(30.0, 0.5)
    assert a.accion("subir")["umbral"] == 30.5
    assert a.accion("bajar")["umbral"] == 30.0


def test_reconocer_marca_alarma():
    a = Almacen(30.0, 0.5)
    assert a.accion("reconocer")["alarma_reconocida"] is True


def test_nueva_lectura_ok_limpia_reconocimiento():
    a = Almacen(30.0, 0.5)
    a.accion("reconocer")
    a.actualizar_lectura(20.0, "ok", "t2")
    assert a.snapshot()["alarma_reconocida"] is False
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_almacen.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'monitor.almacen'`.

- [ ] **Step 3: Implementar el almacén**

`apps/monitor-temp/python/monitor/almacen.py`:
```python
import threading
from monitor.estado import ajustar_umbral


class Almacen:
    def __init__(self, umbral_inicial, paso):
        self._lock = threading.Lock()
        self._paso = paso
        self._estado = {
            "temp": None,
            "umbral": umbral_inicial,
            "estado": "sin_dato",
            "alarma_reconocida": False,
            "ts": None,
        }

    def snapshot(self):
        with self._lock:
            return dict(self._estado)

    def actualizar_lectura(self, temp, estado, ts):
        with self._lock:
            self._estado["temp"] = temp
            self._estado["estado"] = estado
            self._estado["ts"] = ts
            if estado == "ok":
                self._estado["alarma_reconocida"] = False

    def accion(self, nombre):
        with self._lock:
            if nombre in ("subir", "bajar"):
                self._estado["umbral"] = ajustar_umbral(
                    self._estado["umbral"], self._paso, nombre
                )
            elif nombre == "reconocer":
                self._estado["alarma_reconocida"] = True
            else:
                raise ValueError(f"acción inválida: {nombre}")
            return dict(self._estado)
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_almacen.py -v`
Expected: PASS (5 passed).

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/python/monitor/almacen.py apps/monitor-temp/python/tests/test_almacen.py
git commit -m "feat(monitor): almacén de estado thread-safe (TDD)"
```

---

### Task 7: Servidor HTTP local (TDD)

Sirve la UI estática y la API JSON que la UI consume. Stdlib only. Testeable arrancándolo en un hilo y haciendo requests con `urllib`.

**Files:**
- Create: `apps/monitor-temp/python/monitor/servidor.py`
- Test: `apps/monitor-temp/python/tests/test_servidor.py`

**Interfaces:**
- Consumes: `Almacen` de `monitor.almacen`.
- Produces: `crear_servidor(almacen: Almacen, web_dir: str, host="127.0.0.1", port=8080) -> ThreadingHTTPServer`.
  - `GET /api/state` → JSON del snapshot.
  - `POST /api/action` body `{"action": "..."}` → JSON snapshot nuevo (400 si acción inválida).
  - `GET /` y `GET /<archivo>` → sirve `web_dir`.

- [ ] **Step 1: Escribir los tests que fallan**

`apps/monitor-temp/python/tests/test_servidor.py`:
```python
import json
import threading
import urllib.request
from monitor.almacen import Almacen
from monitor.servidor import crear_servidor


def _arrancar(tmp_path):
    (tmp_path / "index.html").write_text("<h1>ok</h1>")
    a = Almacen(30.0, 0.5)
    srv = crear_servidor(a, str(tmp_path), port=0)  # port=0 = puerto libre
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    return a, srv, f"http://127.0.0.1:{port}"


def test_get_state_devuelve_json(tmp_path):
    a, srv, base = _arrancar(tmp_path)
    try:
        body = urllib.request.urlopen(base + "/api/state").read()
        data = json.loads(body)
        assert data["umbral"] == 30.0
        assert data["estado"] == "sin_dato"
    finally:
        srv.shutdown()


def test_post_action_subir_umbral(tmp_path):
    a, srv, base = _arrancar(tmp_path)
    try:
        req = urllib.request.Request(
            base + "/api/action",
            data=json.dumps({"action": "subir"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        data = json.loads(urllib.request.urlopen(req).read())
        assert data["umbral"] == 30.5
    finally:
        srv.shutdown()


def test_sirve_index(tmp_path):
    a, srv, base = _arrancar(tmp_path)
    try:
        body = urllib.request.urlopen(base + "/").read().decode()
        assert "ok" in body
    finally:
        srv.shutdown()
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_servidor.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'monitor.servidor'`.

- [ ] **Step 3: Implementar el servidor**

`apps/monitor-temp/python/monitor/servidor.py`:
```python
import json
import os
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class _Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, almacen=None, web_dir=None, **kwargs):
        self._almacen = almacen
        super().__init__(*args, directory=web_dir, **kwargs)

    def _json(self, code, obj):
        cuerpo = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        if self.path == "/api/state":
            return self._json(200, self._almacen.snapshot())
        return super().do_GET()  # sirve estáticos desde web_dir

    def do_POST(self):
        if self.path == "/api/action":
            n = int(self.headers.get("Content-Length", 0))
            try:
                accion = json.loads(self.rfile.read(n) or b"{}").get("action")
                return self._json(200, self._almacen.accion(accion))
            except ValueError:
                return self._json(400, {"error": "accion invalida"})
        self.send_error(404)

    def log_message(self, *a):
        pass  # silencioso


def crear_servidor(almacen, web_dir, host="127.0.0.1", port=8080):
    handler = partial(_Handler, almacen=almacen, web_dir=web_dir)
    return ThreadingHTTPServer((host, port), handler)
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_servidor.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/python/monitor/servidor.py apps/monitor-temp/python/tests/test_servidor.py
git commit -m "feat(monitor): servidor HTTP local /api/state y /api/action (TDD)"
```

---

### Task 8: Cliente bridge con mock (TDD)

Aísla la llamada al bridge (cuyo API exacto se confirmó en Task 2) tras una interfaz, para poder testear y para degradar a `None` ante fallo.

**Files:**
- Create: `apps/monitor-temp/python/monitor/bridge_client.py`
- Test: `apps/monitor-temp/python/tests/test_bridge_client.py`

**Interfaces:**
- Produces: `leer_temp(caller) -> float | None`. `caller` es un callable que devuelve la temp cruda (en producción envuelve `Bridge.call("read_temp")`); si lanza excepción o devuelve NaN, `leer_temp` devuelve `None`.

- [ ] **Step 1: Escribir los tests que fallan**

`apps/monitor-temp/python/tests/test_bridge_client.py`:
```python
import math
from monitor.bridge_client import leer_temp


def test_devuelve_valor_normal():
    assert leer_temp(lambda: 23.5) == 23.5


def test_nan_se_vuelve_none():
    assert leer_temp(lambda: math.nan) is None


def test_excepcion_se_vuelve_none():
    def boom():
        raise RuntimeError("bridge caido")
    assert leer_temp(boom) is None
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_bridge_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'monitor.bridge_client'`.

- [ ] **Step 3: Implementar el cliente**

`apps/monitor-temp/python/monitor/bridge_client.py`:
```python
import math


def leer_temp(caller):
    """Llama a `caller()` y normaliza fallos a None."""
    try:
        v = caller()
    except Exception:
        return None
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    return float(v)
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `cd apps/monitor-temp/python && python -m pytest tests/test_bridge_client.py -v`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/python/monitor/bridge_client.py apps/monitor-temp/python/tests/test_bridge_client.py
git commit -m "feat(monitor): cliente bridge con normalización de fallos (TDD)"
```

---

### Task 9: Orquestación en `main.py`

Une todo: arranca el servidor en un hilo, corre el poll loop (bridge → estado → almacén → CSV). Sin lógica nueva testeable (ya cubierta); verificación manual con bridge simulado.

**Files:**
- Modify: `apps/monitor-temp/python/main.py`

**Interfaces:**
- Consumes: `leer_temp`, `evaluar_estado`, `registrar`, `Almacen`, `crear_servidor`.

- [ ] **Step 1: Escribir `main.py`**

`apps/monitor-temp/python/main.py`:
```python
import os
import time
import threading
from datetime import datetime, timezone

from monitor.almacen import Almacen
from monitor.estado import evaluar_estado
from monitor.registro import registrar
from monitor.servidor import crear_servidor
from monitor.bridge_client import leer_temp

# Bridge de App Lab: import según plantilla confirmada en Task 2 Step 5.
# from arduino.app_bridge import Bridge   # <- ajustar al nombre real

POLL_SEG = 1.0
UMBRAL_INICIAL = 30.0
PASO_UMBRAL = 0.5
HIST = 0.5
WEB_DIR = os.path.join(os.path.dirname(__file__), "..", "web_ui")
CSV_PATH = os.path.expanduser("~/monitor-temp/lecturas.csv")
PORT = 8080


def _caller():
    # return Bridge.call("read_temp")   # <- producción
    raise NotImplementedError("conectar Bridge.call('read_temp')")


def poll_loop(almacen, caller):
    csv_ok = True
    while True:
        temp = leer_temp(caller)
        prev = almacen.snapshot()
        estado = evaluar_estado(temp, prev["umbral"], prev["estado"], HIST)
        ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
        almacen.actualizar_lectura(temp, estado, ts)
        if csv_ok:
            try:
                registrar(CSV_PATH, ts, temp, prev["umbral"], estado)
            except OSError as e:
                print(f"[monitor] CSV no escribible, sigo sin registrar: {e}")
                csv_ok = False
        time.sleep(POLL_SEG)


def main():
    almacen = Almacen(UMBRAL_INICIAL, PASO_UMBRAL)
    srv = crear_servidor(almacen, os.path.abspath(WEB_DIR), port=PORT)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"[monitor] sirviendo en http://127.0.0.1:{PORT}")
    poll_loop(almacen, _caller)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verificar con bridge simulado (sin hardware)**

Temporalmente cambiar `poll_loop(almacen, _caller)` por `poll_loop(almacen, lambda: 28.0)` y correr `python main.py` en la máquina de desarrollo. En otra terminal:
```bash
curl -s http://127.0.0.1:8080/api/state
# Bajar el umbral 5 veces (0.5 c/u) lo lleva de 30.0 a 27.5, por debajo de la temp 28.0:
for i in 1 2 3 4 5; do curl -s -X POST http://127.0.0.1:8080/api/action -d '{"action":"bajar"}'; echo; done
curl -s http://127.0.0.1:8080/api/state
```
Expected: el primer `/api/state` muestra `temp:28.0` y `estado:"ok"`; tras bajar el umbral por debajo de 28, el segundo muestra `estado:"alerta"`. Revertir el cambio temporal tras verificar.

- [ ] **Step 3: Commit**

```bash
git add apps/monitor-temp/python/main.py
git commit -m "feat(monitor): orquestación poll loop + servidor en main.py"
```

---

### Task 10: UI estática (web_ui)

Pantalla táctil: número grande, color de estado, botones grandes.

**Files:**
- Create: `apps/monitor-temp/web_ui/index.html`
- Create: `apps/monitor-temp/web_ui/style.css`
- Create: `apps/monitor-temp/web_ui/app.js`

**Interfaces:**
- Consumes: `GET /api/state`, `POST /api/action` del servidor (Task 7).

- [ ] **Step 1: HTML**

`apps/monitor-temp/web_ui/index.html`:
```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
  <title>Monitor de temperatura</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <main id="app" class="estado-sin_dato">
    <div id="temp">--</div>
    <div id="unidad">°C</div>
    <div id="estado-txt">sin dato</div>
    <div id="umbral">Umbral: -- °C</div>
    <div id="controles">
      <button data-accion="bajar">−</button>
      <button data-accion="reconocer">Reconocer</button>
      <button data-accion="subir">+</button>
    </div>
  </main>
  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: CSS**

`apps/monitor-temp/web_ui/style.css` (panel 480×800 vertical, botones grandes para dedo):
```css
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%; }
#app {
  height: 100vh; display: flex; flex-direction: column;
  align-items: center; justify-content: center;
  font-family: sans-serif; color: #fff; transition: background .3s;
}
.estado-ok       { background: #1e8e3e; }
.estado-alerta   { background: #d93025; }
.estado-sin_dato { background: #5f6368; }
#temp { font-size: 38vw; font-weight: 700; line-height: 1; }
#unidad { font-size: 8vw; }
#estado-txt { font-size: 7vw; margin: 2vh 0; text-transform: uppercase; }
#umbral { font-size: 5vw; margin-bottom: 4vh; }
#controles { display: flex; gap: 4vw; }
#controles button {
  font-size: 8vw; padding: 3vh 6vw; border: none; border-radius: 12px;
  background: rgba(255,255,255,.25); color: #fff;
}
#controles button:active { background: rgba(255,255,255,.5); }
.parpadeo { animation: blink 1s step-start infinite; }
@keyframes blink { 50% { opacity: .4; } }
```

- [ ] **Step 3: JS**

`apps/monitor-temp/web_ui/app.js`:
```javascript
const app = document.getElementById("app");
const $temp = document.getElementById("temp");
const $estado = document.getElementById("estado-txt");
const $umbral = document.getElementById("umbral");

async function refrescar() {
  try {
    const s = await (await fetch("/api/state")).json();
    pintar(s);
  } catch (e) { /* reintenta en el próximo tick */ }
}

function pintar(s) {
  $temp.textContent = (s.temp === null || s.temp === undefined) ? "--" : s.temp.toFixed(1);
  $umbral.textContent = `Umbral: ${s.umbral.toFixed(1)} °C`;
  app.className = `estado-${s.estado}`;
  $estado.textContent = s.estado.replace("_", " ");
  // parpadeo solo en alerta no reconocida
  app.classList.toggle("parpadeo", s.estado === "alerta" && !s.alarma_reconocida);
}

async function accion(nombre) {
  try {
    const s = await (await fetch("/api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: nombre }),
    })).json();
    pintar(s);
  } catch (e) { /* ignora */ }
}

document.querySelectorAll("#controles button").forEach((b) =>
  b.addEventListener("click", () => accion(b.dataset.accion))
);

refrescar();
setInterval(refrescar, 1000);
```

- [ ] **Step 4: Verificar en navegador de escritorio**

Con `main.py` corriendo (bridge simulado de Task 9), abrir `http://127.0.0.1:8080/` en Chromium de escritorio.
Expected: número y umbral se actualizan cada segundo; +/− cambian el umbral; el fondo cambia verde/rojo/gris; rojo parpadea hasta tocar "Reconocer".

- [ ] **Step 5: Commit**

```bash
git add apps/monitor-temp/web_ui/
git commit -m "feat(monitor): UI táctil estática (número grande, estado por color, controles)"
```

---

### Task 11: Modo kiosko — autologin + autostart de Chromium

Configuración del device para que arranque solo a la app, sin login ni teclado.

**Files:**
- Create (en el device): `/etc/lightdm/lightdm.conf.d/50-autologin.conf`
- Create (en el device): `~/.config/autostart/monitor-kiosko.desktop`
- Create (en el repo, para versionar): `apps/monitor-temp/kiosko/50-autologin.conf`
- Create (en el repo): `apps/monitor-temp/kiosko/monitor-kiosko.desktop`
- Create (en el repo): `apps/monitor-temp/kiosko/instalar-kiosko.sh`

**Interfaces:**
- Consumes: la app corriendo y sirviendo en `http://127.0.0.1:8080`.

- [ ] **Step 1: Archivo de autologin de LightDM**

`apps/monitor-temp/kiosko/50-autologin.conf`:
```ini
[Seat:*]
autologin-user=arduino
autologin-user-timeout=0
```

- [ ] **Step 2: Autostart de Chromium en kiosko**

`apps/monitor-temp/kiosko/monitor-kiosko.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=Monitor Kiosko
Exec=/bin/bash -c 'sleep 8; chromium --kiosk --noerrdialogs --disable-infobars --incognito --check-for-update-interval=31536000 http://127.0.0.1:8080'
X-GNOME-Autostart-enabled=true
```
> El `sleep 8` da margen a que el backend Python (App Lab "Run at startup") levante el puerto 8080 antes de cargar la URL.

- [ ] **Step 3: Script instalador (idempotente)**

`apps/monitor-temp/kiosko/instalar-kiosko.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo install -D -m 644 "$DIR/50-autologin.conf" /etc/lightdm/lightdm.conf.d/50-autologin.conf
install -D -m 644 "$DIR/monitor-kiosko.desktop" "$HOME/.config/autostart/monitor-kiosko.desktop"

echo "Kiosko instalado. Falta marcar la app 'Run at startup' en App Lab:"
echo "  arduino-app-cli properties set default user:monitor-temp"
echo "Reinicia para probar: sudo reboot"
```

- [ ] **Step 4: Instalar en el device y marcar autostart de la app**

```bash
scp -r apps/monitor-temp/kiosko arduino@<IP>:~/monitor-temp-kiosko
ssh arduino@<IP> 'bash ~/monitor-temp-kiosko/instalar-kiosko.sh'
ssh arduino@<IP> 'arduino-app-cli properties set default user:monitor-temp'   # confirmar sintaxis exacta
```

- [ ] **Step 5: Verificación end-to-end**

```bash
ssh arduino@<IP> 'sudo reboot'
```
Expected (mirando la pantalla del shield): arranca **sin login**, a los ~8 s aparece la app a pantalla completa; la temperatura se actualiza; los botones +/−/Reconocer responden al **touch**.

- [ ] **Step 6: Commit**

```bash
git add apps/monitor-temp/kiosko/
git commit -m "feat(monitor): modo kiosko (autologin LightDM + autostart Chromium)"
```

---

### Task 12: README de la app + suite de tests verde

**Files:**
- Create: `apps/monitor-temp/README.md`

- [ ] **Step 1: Correr toda la suite de tests**

Run: `cd apps/monitor-temp/python && python -m pytest -v`
Expected: PASS — todos los tests de Tasks 4–8 verdes.

- [ ] **Step 2: Escribir el README**

`apps/monitor-temp/README.md` con: descripción, prerrequisito (Task 1), cómo correr en App Lab, sensor de referencia (MCP9808) y cómo cambiarlo (líneas `SENSOR-ESPECÍFICO`), cómo instalar kiosko (`kiosko/instalar-kiosko.sh`), ruta del CSV, y los puntos abiertos del §9 del diseño (API del brick `web_ui`, sensor real).

- [ ] **Step 3: Commit**

```bash
git add apps/monitor-temp/README.md
git commit -m "docs(monitor): README de la app de monitoreo"
```

---

## Notas de verificación cruzada (spec → plan)

- Lectura grande + estado por color → Tasks 4, 10.
- Umbrales ajustables por touch + reconocer alarma → Tasks 6, 7, 10.
- Registro/exportar CSV → Task 5, integrado en Task 9.
- Saltar login sin teclado → Task 11 (autologin).
- Navegador en pantalla del shield → Task 11 (Chromium kiosko) sobre Task 1 (DSI+touch).
- Sensor I2C vía bridge → Tasks 2, 3, 8.
- Errores (sensor caído, CSV no escribible, bridge falla) → Tasks 8, 9, 4 (`sin_dato`).

## Puntos que el colaborador debe confirmar al arrancar (no bloquean el diseño)

1. **API exacto del bridge** de App Lab (include C++, firma de `Bridge.provide`, módulo/clase Python de `Bridge.call`) — Task 2 Step 5.
2. **Sintaxis exacta** de `arduino-app-cli` para correr y para "run at startup" — Tasks 2 y 11.
3. **Sensor real** y su conversión (el plan usa MCP9808 como referencia) — Task 3.
4. **Nombre del campo** en `app.yaml` para sketch/python según la app que genere App Lab — Task 2.
