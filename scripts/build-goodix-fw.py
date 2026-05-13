#!/usr/bin/env python3
"""
Construye /lib/firmware/goodix_911_cfg.bin desde la config capturada del chip
en Snapshot 1 (post Arduino-style reset). Esto le da al driver del kernel un
config conocido bueno que escribira al chip en cada bind, evitando que el chip
quede en estado degenerado tras el reset del kernel.

Formato esperado por el driver (goodix_check_cfg_8 en drivers/input/touchscreen/goodix.c):
  - bytes 0..183: config raw (lo que va a 0x8047..0x80FE del chip)
  - byte 184    : checksum = (~sum_of_bytes_0_to_183) + 1  (en 8 bits)
  - byte 185    : config_fresh flag = 0x01 (mandatorio)
"""
import sys
from pathlib import Path

# Config capturada de Snapshot 1 (post Arduino-style reset).
# Son los 184 bytes desde 0x8047 a 0x80FE del chip.
#
# NOTA: SITO (bit 2 de 0x804D) = "Single-side ITO panel" — este shield ES single-side
# por lo que SITO debe estar a 1. El "92Hz continuo" que veíamos NO era patológico,
# es la tasa de scan normal del chip para panels single-side. Por eso volvemos a 0x05.
CONFIG_HEX = """
41 e0 01 20 03 0a 05 00 01 08 28 05 50 32 03 05
00 00 00 00 00 00 00 00 00 00 00 86 26 07 17 15
31 0d 00 00 01 9b 03 1d 00 00 00 00 00 03 64 32
00 00 00 0f 4b 94 c5 02 07 00 00 04 9c 11 00 72
18 00 55 21 00 41 2e 00 32 40 00 32 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
12 10 0e 0c 0a 08 06 ff ff ff ff ff ff ff 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 22 21
20 1f 1e 1d 00 02 04 06 08 0a ff ff ff ff ff ff
ff ff ff ff ff ff ff ff 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00
"""

# Checksum esperado: previo (0xe0) menos el delta del byte modificado (-4) = 0xe4
# pero el checksum es complemento a 2 de la suma, asi que: suma cambia de 0x20
# a 0x20-0x04 = 0x1c, checksum nuevo = (~0x1c)+1 = 0xe4. Lo verificamos al run.
CHIP_CHECKSUM = None  # no comparable porque modificamos un byte


def main():
    cfg_bytes = bytes.fromhex(CONFIG_HEX.replace("\n", " "))
    assert len(cfg_bytes) == 184, f"esperaba 184 bytes, son {len(cfg_bytes)}"

    # Calcular checksum estilo Goodix: complemento a 2 de la suma
    s = sum(cfg_bytes) & 0xff
    checksum = ((~s) + 1) & 0xff
    print(f"sum bytes 0..183 = 0x{s:02x}")
    print(f"checksum calculado = 0x{checksum:02x}")
    if CHIP_CHECKSUM is not None:
        print(f"chip reporta checksum = 0x{CHIP_CHECKSUM:02x}")
        if checksum != CHIP_CHECKSUM:
            print("WARNING: checksum no coincide con el del chip — algo raro")
        else:
            print("OK: checksum coincide con el del chip — los 184 bytes son consistentes")
    else:
        print("(no se compara con chip porque config fue modificada deliberadamente)")

    # Archivo final: 184 cfg + checksum + 0x01 (config_fresh)
    fw = cfg_bytes + bytes([checksum, 0x01])
    assert len(fw) == 186

    out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/goodix_911_cfg.bin")
    out.write_bytes(fw)
    print(f"Escrito {out} ({len(fw)} bytes)")


if __name__ == "__main__":
    main()
