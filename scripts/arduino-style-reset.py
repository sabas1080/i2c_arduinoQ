#!/usr/bin/env python3
"""
Reset del GT911 siguiendo EXACTAMENTE la secuencia del Arduino_GigaDisplayTouch
library (GT911 Power-on timing procedure Ref. pg10 GT911 Rev09).

Diferencia vs el reset del kernel goodix.c: orden y duraciones puntuales
ligeramente distintas; en particular Arduino mete pinMode(_intPin, OUTPUT) +
LOW al comienzo (kernel pone INT directamente al valor de address-select).

Requiere:
- gpiochip1 (TLMM 500000.pinctrl)
- linea 18 = RST  (JMEDIA pin 49)
- linea 98 = INT  (JMEDIA pin 46)
- Driver goodix_ts UNBOUND antes de correr este script.
"""
import gpiod
import time
import sys
from gpiod.line_settings import LineSettings, Direction, Value

CHIP = "/dev/gpiochip1"
LINE_RST = 18
LINE_INT = 98
ADDR_28_29 = True  # True para chip address 0x14, False para 0x5D


def main():
    print(f"Abriendo {CHIP}")
    with gpiod.Chip(CHIP) as chip:
        # T0: ambas salidas en LOW
        config = {
            LINE_RST: LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
            LINE_INT: LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
        }
        req = chip.request_lines(consumer="arduino-gt911-reset", config=config)
        print("RST=0, INT=0 (T0)")

        # T1+T2: > 10ms
        time.sleep(0.012)

        # Address selection: INT HIGH para 0x14, LOW para 0x5D
        int_val = Value.ACTIVE if ADDR_28_29 else Value.INACTIVE
        req.set_value(LINE_INT, int_val)
        print(f"INT={'HIGH' if ADDR_28_29 else 'LOW'} (selecciona address {0x14 if ADDR_28_29 else 0x5D})")

        # T7: > 100us
        time.sleep(0.0003)

        # Release RST
        req.set_value(LINE_RST, Value.ACTIVE)
        print("RST=1 (release reset)")

        # T8: > 5ms
        time.sleep(0.008)

        # INT LOW (paso clave Arduino: pulso bajo de INT despues de liberar RST)
        req.set_value(LINE_INT, Value.INACTIVE)
        print("INT=0 (T8 pulse low)")

        # T3: > 50ms
        time.sleep(0.060)

        # Reconfigurar INT a INPUT
        req.reconfigure_lines({
            LINE_RST: LineSettings(direction=Direction.OUTPUT, output_value=Value.ACTIVE),
            LINE_INT: LineSettings(direction=Direction.INPUT),
        })
        print("INT -> INPUT, RST se queda en HIGH como output")

        # Esperar un poco mas para que el chip se establezca
        time.sleep(0.050)
        print("Reset secuencia completa.")

        req.release()


if __name__ == "__main__":
    main()
