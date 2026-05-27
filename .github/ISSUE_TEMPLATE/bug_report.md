---
name: Bug report
about: Something broke that used to work, or behaves unexpectedly.
title: "[bug] "
labels: bug
---

**Describe the bug**
A clear, concise description of what is wrong.

**To reproduce**
Steps to reproduce the behavior:
1. ...
2. ...
3. ...

**Expected behavior**
What you expected to happen.

**Hardware**
- Board: <output of `cat /proc/device-tree/model`>
- Kernel: <output of `uname -r`>
- Shield wiring: <stock or custom; if custom, attach photo>

**Diagnostic output**
```text
# Paste here:
i2cdetect -y 0
lsmod | grep -E '(goodix|st7701)'
dmesg | grep -iE '(goodix|st7701|gt911)' | tail -20
ls /boot/efi/loader/entries/
```

**Validation script output**
```text
# ./validate-gigadisplay-shield.sh
```

**Additional context**
Anything else relevant (recent reboots, package updates, kernel changes).
