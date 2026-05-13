#!/usr/bin/env python3
"""
Daemon userspace para el GT911 del GIGA Display Shield sobre el UNO Q.

Reemplaza al driver `goodix_ts` del kernel (que no maneja correctamente la
secuencia de reset del chip y lo deja en estado degenerado). En su lugar:

  1. Al arrancar hace Arduino-style reset (replica exacto del que usa la
     libreria Arduino_GigaDisplayTouch, secuencia GT911 Rev09 con T8 + T3
     low-pulse de INT que el driver kernel se salta)
  2. Polls al chip via I2C cada 10ms leyendo status + touch points
  3. Inyecta eventos multitouch a /dev/uinput como un touchscreen estandar
  4. Las apps (X11/Weston/LVGL) ven un /dev/input/eventN normal

Requiere:
- python3-smbus2  (I2C raw via /dev/i2c-0)
- python3-evdev   (UInput)
- python3-libgpiod (gpiochip access para reset)
- arduino user en grupos `i2c` y `gpiod`
- `goodix_ts` blacklisted (sino compite por el bus)
"""
import logging
import os
import signal
import sys
import time

import gpiod
from gpiod.line_settings import LineSettings, Direction, Value

from smbus2 import SMBus, i2c_msg

import evdev
from evdev import UInput, ecodes, AbsInfo

# ----- Hardware mapping -----
I2C_BUS = 0
CHIP_ADDR = 0x14  # GT911 address 28/29 (set by holding INT high during reset)
GPIOCHIP = "/dev/gpiochip1"
RST_LINE = 18     # JMEDIA pin 49
INT_LINE = 98     # JMEDIA pin 46
MAX_POINTS = 5    # GT911 supports up to 10 but Goodix recommends max 5 usable
POLL_INTERVAL_SEC = 0.010   # 10ms poll, matches chip's scan rate

# ----- GT911 registers (8-bit values) -----
REG_PRODUCT_ID = 0x8140
REG_FW_VER = 0x8144
REG_RESOLUTION = 0x8146
REG_CONFIG = 0x8047
REG_CONFIG_LEN = 184
REG_STATUS = 0x814E
# Layout en GT911: 0x814E status, 0x814F+ track_id de touch 0, 0x8150+ coords (LE)
# Cada touch es 8 bytes: track_id, x_lo, x_hi, y_lo, y_hi, area_lo, area_hi, reserved
REG_POINTS = 0x814F  # comenzar en track_id, no en X_lo


class GT911Daemon:
    def __init__(self, log):
        self.log = log
        self.bus = None
        self.ui = None
        self.x_max = 0
        self.y_max = 0
        self.active_slots = {}  # slot -> track_id

    # ---- I2C helpers ----
    def read(self, reg, n):
        write = i2c_msg.write(CHIP_ADDR, [(reg >> 8) & 0xFF, reg & 0xFF])
        read = i2c_msg.read(CHIP_ADDR, n)
        self.bus.i2c_rdwr(write, read)
        return list(read)

    def write(self, reg, data):
        payload = [(reg >> 8) & 0xFF, reg & 0xFF] + list(data)
        self.bus.i2c_rdwr(i2c_msg.write(CHIP_ADDR, payload))

    # ---- Arduino-style reset ----
    def arduino_reset(self):
        """Secuencia identica a Arduino_GigaDisplayTouch.begin():
            RST low + INT low
            wait 11ms (T1+T2)
            INT high (selecciona 0x14)
            wait 110us (T7)
            RST high (release)
            wait 6ms (T8)
            INT low
            wait 51ms (T3)
            INT input
        """
        self.log.info("Arduino-style reset...")
        with gpiod.Chip(GPIOCHIP) as chip:
            config = {
                RST_LINE: LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
                INT_LINE: LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
            }
            req = chip.request_lines(consumer="gt911-daemon", config=config)
            try:
                time.sleep(0.012)
                req.set_value(INT_LINE, Value.ACTIVE)  # for addr 0x14
                time.sleep(0.0003)
                req.set_value(RST_LINE, Value.ACTIVE)
                time.sleep(0.008)
                req.set_value(INT_LINE, Value.INACTIVE)
                time.sleep(0.060)
                req.reconfigure_lines({
                    RST_LINE: LineSettings(direction=Direction.OUTPUT, output_value=Value.ACTIVE),
                    INT_LINE: LineSettings(direction=Direction.INPUT),
                })
                time.sleep(0.050)
            finally:
                req.release()

    # ---- Chip discovery ----
    def verify_chip(self):
        product = self.read(REG_PRODUCT_ID, 4)
        product_str = bytes(product).decode(errors="replace").rstrip("\x00")
        fw = self.read(REG_FW_VER, 2)
        fw_ver = fw[0] | (fw[1] << 8)
        self.log.info(f"Chip Product ID: {product_str!r}, FW version: 0x{fw_ver:04X}")
        if product_str != "911":
            raise RuntimeError(f"Expected GT911, got {product_str!r}")

        # Lee resolucion desde config table (LE)
        cfg = self.read(REG_CONFIG + 1, 4)  # offsets 1-2 X, 3-4 Y
        self.x_max = cfg[0] | (cfg[1] << 8)
        self.y_max = cfg[2] | (cfg[3] << 8)
        if self.x_max == 0 or self.y_max == 0:
            self.log.warning("Config table parece vacia; usando 480x800 por defecto")
            self.x_max, self.y_max = 480, 800
        self.log.info(f"Resolution: {self.x_max} x {self.y_max}")

    # ---- uinput setup ----
    def setup_uinput(self):
        caps = {
            ecodes.EV_KEY: [ecodes.BTN_TOUCH],
            ecodes.EV_ABS: [
                (ecodes.ABS_X, AbsInfo(value=0, min=0, max=self.x_max - 1, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_Y, AbsInfo(value=0, min=0, max=self.y_max - 1, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_MT_SLOT, AbsInfo(value=0, min=0, max=MAX_POINTS - 1, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_MT_POSITION_X, AbsInfo(value=0, min=0, max=self.x_max - 1, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_MT_POSITION_Y, AbsInfo(value=0, min=0, max=self.y_max - 1, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_MT_TRACKING_ID, AbsInfo(value=0, min=0, max=65535, fuzz=0, flat=0, resolution=0)),
                (ecodes.ABS_MT_TOUCH_MAJOR, AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)),
            ],
        }
        self.ui = UInput(
            events=caps,
            name="Goodix Capacitive TouchScreen (userspace daemon)",
            vendor=0x0416,
            product=0x911,
            version=0x0100,
            input_props=[ecodes.INPUT_PROP_DIRECT],
        )
        self.log.info(f"uinput device created: {self.ui.device.path}")

    # ---- Touch poll loop ----
    def emit_touch(self, points):
        """points: list of (slot, track_id, x, y, area) for currently touching fingers."""
        current_slots = {p[0]: p for p in points}

        # New / updated slots
        for slot, (s, tid, x, y, area) in current_slots.items():
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_SLOT, slot)
            if slot not in self.active_slots:
                self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_TRACKING_ID, tid)
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_POSITION_X, x)
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_POSITION_Y, y)
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_TOUCH_MAJOR, min(255, area))

        # Released slots
        for slot in list(self.active_slots):
            if slot not in current_slots:
                self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_SLOT, slot)
                self.ui.write(ecodes.EV_ABS, ecodes.ABS_MT_TRACKING_ID, -1)

        # Single-touch emulation (legacy/desktop)
        if points:
            first = points[0]
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_X, first[2])
            self.ui.write(ecodes.EV_ABS, ecodes.ABS_Y, first[3])
            if not self.active_slots:
                self.ui.write(ecodes.EV_KEY, ecodes.BTN_TOUCH, 1)
        else:
            if self.active_slots:
                self.ui.write(ecodes.EV_KEY, ecodes.BTN_TOUCH, 0)

        self.ui.syn()
        self.active_slots = {s: t for s, (_, t, *_) in current_slots.items()}

    def poll_loop(self):
        self.log.info(f"Entering polling loop (every {POLL_INTERVAL_SEC*1000:.0f}ms)")
        while True:
            try:
                status = self.read(REG_STATUS, 1)[0]
            except OSError as e:
                self.log.error(f"I2C read failed: {e} — sleeping 1s and retrying")
                time.sleep(1.0)
                continue

            if status & 0x80:  # buffer status ready
                n = status & 0x0F
                points = []
                if n > 0:
                    n = min(n, MAX_POINTS)
                    try:
                        raw = self.read(REG_POINTS, 8 * n)
                    except OSError as e:
                        self.log.error(f"point read failed: {e}")
                        time.sleep(0.05)
                        continue
                    for i in range(n):
                        off = i * 8
                        tid = raw[off]
                        x = raw[off + 1] | (raw[off + 2] << 8)
                        y = raw[off + 3] | (raw[off + 4] << 8)
                        area = raw[off + 5] | (raw[off + 6] << 8)
                        points.append((i, tid, x, y, area))
                self.emit_touch(points)
                # ACK to let chip prepare next sample
                try:
                    self.write(REG_STATUS, [0])
                except OSError as e:
                    self.log.error(f"ack failed: {e}")
            time.sleep(POLL_INTERVAL_SEC)

    def run(self):
        self.arduino_reset()
        time.sleep(0.05)  # asentar
        self.bus = SMBus(I2C_BUS)
        self.verify_chip()
        self.setup_uinput()
        try:
            self.poll_loop()
        finally:
            if self.ui:
                self.ui.close()
            if self.bus:
                self.bus.close()


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s gt911-daemon[%(process)d] %(levelname)s %(message)s",
    )
    log = logging.getLogger("gt911")
    daemon = GT911Daemon(log)

    def shutdown(signum, frame):
        log.info(f"Recibido signal {signum}, saliendo")
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        daemon.run()
    except Exception as e:
        log.exception(f"Daemon crashed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
