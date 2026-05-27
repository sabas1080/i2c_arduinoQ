---
name: Replication help
about: Following the README but it does not work on my setup.
title: "[help] "
labels: help-wanted, replication
---

**What I did**
1. Flashed Arduino UNO Q image: <version / date>
2. Wired the shield according to `docs/wiring.md`: <attach photo>
3. Ran: `./enable-gigadisplay-shield.sh` — completed successfully? yes/no
4. Rebooted
5. Ran: `./validate-gigadisplay-shield.sh`

**Where it broke**
- [ ] Install script failed (paste output)
- [ ] Install completed but display stays black after reboot
- [ ] Display works but touch does not register
- [ ] Touch registers (`evtest` shows events) but X11 cursor doesn't follow
- [ ] Validate script reports failures (paste output)
- [ ] Other (describe)

**Diagnostic output (paste the full output of these)**
```text
uname -r
cat /proc/device-tree/model
ls /boot/efi/loader/entries/
cat /boot/efi/loader/entries/*7.0.0*.conf
ls /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/panel/
md5sum /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/panel/panel-sitronix-st7701.ko
i2cdetect -y 0
lsmod | grep -E '(goodix|st7701)'
dmesg | grep -iE '(goodix|st7701|gt911|dsi)' | tail -30
```

**Wiring photo**
Attach a clear, in-focus photo of the jumpers between the shield and the UNO Q JMEDIA connector.
