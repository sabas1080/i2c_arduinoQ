# Public Release — Design Spec

**Date:** 2026-05-26
**Author:** Sabas Jimenez (with Claude)
**Status:** Draft for review

> **Note:** This spec is an internal working document. The `docs/superpowers/` tree is **not** shipped in the public release — it is gitignored and removed before the rewrite.

---

## 1. Goal

Turn `sabas1080/i2c_arduinoQ` into a public, replicable repository so that any member of the Electronic Cats / Arduino community with the same hardware (Arduino UNO Q + GIGA Display Shield + manual touch wiring) can clone the repo, run **one on-device script**, and end up with a working DSI display + GT911 touch + calibrated X11 cursor.

## 2. Audience & language

- **Primary audience:** Electronic Cats community + Arduino official users. Mixed skill level — some makers, some embedded/Linux devs.
- **Tone:** Showcase + technical reference. Friendly quick-start; deep dive available for those who want it.
- **Language:** English only for all public-facing files (README, docs, scripts comments, commit messages going forward).

## 3. Scope of replication

End-to-end one-shot script that runs **on the UNO Q** (not via SSH from a host). User flashes the official Arduino image, wires the touch lines manually following the documented pinout, copies the release bundle to the device (scp / adb push / USB stick), and runs `./enable-gigadisplay-shield.sh`. After a reboot the display lights up and touch works in X11.

Out of scope: automating the physical wiring, hosting the kernel source, supporting non-Arduino UNO Q boards.

## 4. License

**MIT.** Copyright "2026 Sabas Jimenez / Electronic Cats". Standard MIT text in `LICENSE`. No dual-licensing for docs.

## 5. Repository layout (post-cleanup)

```
i2c_arduinoQ/
├── README.md                          # English quick-start hero
├── LICENSE                            # MIT
├── CONTRIBUTING.md                    # How to report bugs / PR policy
├── CHANGELOG.md                       # Keep-a-Changelog
├── .gitignore                         # Strict: .env, *.ko, .claude/, notes/, docs/superpowers/
├── .gitleaks.toml                     # Optional pre-commit secret scanning config
├── .github/
│   ├── workflows/
│   │   ├── build-panel-module.yml     # Cross-compile .ko on tag, attach to Release
│   │   └── shellcheck.yml             # Lint scripts/*.sh on PRs
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── replication_help.md
│   └── PULL_REQUEST_TEMPLATE.md
├── docs/
│   ├── how-it-works.md                # The anatomy of the fix
│   ├── troubleshooting.md             # Symptom → cause → fix
│   ├── wiring.md                      # Pinout table + photos
│   └── images/                        # Wiring photo, evtest screenshot, X11 cursor demo
├── scripts/
│   ├── enable-gigadisplay-shield.sh   # The entry point (idempotent, --revert)
│   └── gigadisplay-shield.dtso        # Device-tree overlay source
├── kernel/
│   ├── panel-sitronix-st7701.patch    # Patch reintroducing arduino_giga_display_desc
│   ├── configs/
│   │   └── uno-q-7.0.0.config         # Snapshot of running kernel config used by CI
│   └── README.md                      # How to cross-compile manually
└── tools/dev/
    └── build-panel-module.sh          # Local reproduction of the CI build (maintainer only)
```

### Files removed (from working tree AND git history)

- `ABX00162-*.pdf`, `ASX00039-*.pdf`, `GT911_Datasheet.pdf` — Arduino proprietary, link to docs.arduino.cc instead.
- `Test Shield-Adapter.docx` — same.
- `docs/HANDOFF.md` — Spanish bitácora with obsolete diagnostics.
- `docs/superpowers/` — internal planning artifacts.
- `notes/` — measurement logs; not useful for public audience.
- `scripts/patch-dtb.sh`, `bind-gt911.sh`, `unbind-gt911.sh`, `diagnose-i2c.sh`, `arduino-style-reset.py`, `build-goodix-fw.py`, `manual-cfg.sh`, `snapshot-gt911.sh`, `verify-gt911.sh`, `gt911-touch-daemon.py`, `gt911-touch.service`, `install-touch-calibration.sh`, `remote-ssh.sh` — superseded by `enable-gigadisplay-shield.sh`.

### Files relocated

- `scripts/build-st7701-patched-ko.sh` → `tools/dev/build-panel-module.sh`, defaults scrubbed (no hardcoded password/IP), purely a maintainer convenience that mirrors the CI workflow.

## 6. Secrets & data scrubbing

### What was found

| Item | Where | Severity |
|---|---|---|
| `arduino1334` / `Arduino1334` (UNO Q SSH password) | `HANDOFF.md`, `docs/superpowers/plans/...md`, `build-st7701-patched-ko.sh`, **git history** | High |
| `192.168.0.105`, `.149`, `.184` (private LAN IPs) | Same files | Low (not routable) |
| `/home/sabas/...` (personal paths) | Plans, snapshot script | Low |
| `sabasjimenez@gmail.com` (commit author email) | Git author of every commit | Accepted (public identity) |

### Strategy

1. **Change the UNO Q password** (defense in depth — leaked password becomes invalid).
2. **Scrub working tree** before rewrite: remove hardcoded defaults from `tools/dev/build-panel-module.sh`; delete the files in §5 ("Files removed").
3. **Rewrite history** with `git filter-repo` using a replacements file:
   ```
   regex:arduino1334==>***REDACTED***
   regex:Arduino1334==>***REDACTED***
   regex:192\.168\.0\.(105|149|184)==>192.168.0.XXX
   regex:/home/sabas/==>/path/to/repo/
   ```
4. **Force-push** with `--force-with-lease` to `origin main`. Acceptable because there are no known external forks/clones.
5. **Reinforce `.gitignore`** to prevent re-leaks (see §5).
6. **Optional follow-up:** add `gitleaks` pre-commit hook (config in `.gitleaks.toml`).

## 7. `enable-gigadisplay-shield.sh` — entry point

Already exists in the working tree. Stays as-is functionally, with these polish edits before release:

- Translate inline comments and section banners to English.
- `--help` output enriched: explicit prerequisites, what each phase does, examples.
- Prerequisites check expanded: verify `dtc`, `fdtoverlay`, `fdtput`, `fdtget` (already done), plus warn if the user isn't in the `i2c` / `gpiod` / `input` groups.
- Companion file existence check: clear error if `panel-sitronix-st7701.ko` or `gigadisplay-shield.dtso` missing, with link to the latest Release download URL.
- Already idempotent and supports `--revert` and `--no-reboot`. Keep.

## 8. README structure (English)

```
# Arduino UNO Q + GIGA Display Shield — Full Linux Support

[Hero image: wired UNO Q + shield with X11 desktop visible]
[Badges: MIT · Kernel 7.0.0 · CI status]

## What this does
One paragraph: DSI panel + GT911 touch + X11 calibration end-to-end.

## Status matrix
| | Kernel 6.16.7 | Kernel 7.0.0 |
| Display | ✓ | ✓ (patched module) |
| Touch   | ✓ | ✓ |
| X11     | ✓ | ✓ |

## Quick start
1. Flash official Arduino UNO Q image.
2. Wire touch lines → docs/wiring.md.
3. Download latest Release bundle (script + dtso + .ko).
4. On-device: ./enable-gigadisplay-shield.sh
5. Reboot. Done.

## Verification
evtest + xinput commands.

## How it works (1-2 paragraphs + link)
→ docs/how-it-works.md

## Troubleshooting → docs/troubleshooting.md

## Reverting
./enable-gigadisplay-shield.sh --revert

## Credits
Electronic Cats, Arduino, Goodix datasheet, Linux drm-misc, contributors.

## License
MIT.
```

## 9. Documentation pages (`docs/`)

### `docs/wiring.md`
- Pinout table (shield ↔ UNO Q JMEDIA), already in memory.
- Photo of the wiring (`docs/images/wiring.jpg`).
- Note about SDA/SCL swap inside qup0 (verified empirically).
- Voltage note: 1.8V/3.3V marginal, works empirically without level shifter for short wires.

### `docs/how-it-works.md`
Four sections:
1. **The panel descriptor problem (kernel 7.0.0):** Arduino removed `arduino_giga_display_desc` from `panel-sitronix-st7701` in 7.0.0. The patched module reintroduces it.
2. **The device-tree overlay:** what `gigadisplay-shield.dtso` adds (the gt911@14 node, the panel hookup) and how `fdtoverlay` composes it onto the base DTB.
3. **The boot loader entry:** why we add `devicetree /...` and `video=DSI-1:480x800@60` to `/boot/efi/loader/entries/`.
4. **X11 calibration:** what the TransformationMatrix means and how it was derived (4-corner capture with evtest, normalized to abs_max=479/799).

### `docs/troubleshooting.md`
Table-driven: Symptom → likely cause → diagnostic command → fix. Examples:
- "Touch not detected by i2cdetect" → wiring or 3V3 not connected → `i2cdetect -y 0` → recheck pinout.
- "evtest shows events but X11 cursor doesn't move" → missing X11 calibration snippet → check `/etc/X11/xorg.conf.d/`.
- "Display black after reboot" → boot entry edit missed → check `/boot/efi/loader/entries/*.conf`.
- "Coordinates inverted / rotated wrong" → rotation = "right" vs "left" → swap value in `10-monitor.conf`.

## 10. CI workflow

### `.github/workflows/build-panel-module.yml`

Trigger: tags matching `v*`.

Steps:
1. Checkout this repo.
2. Setup Ubuntu runner, install `gcc-aarch64-linux-gnu libelf-dev libssl-dev flex bison bc cpio`.
3. Shallow clone `arduino/linux-qcom@qcom-v7.0.0-unoq`.
4. Apply `kernel/panel-sitronix-st7701.patch`.
5. Configure kernel using `kernel/configs/uno-q-7.0.0.config`.
6. Build the single module: `make M=drivers/gpu/drm/panel`.
7. Strip and copy `panel-sitronix-st7701.ko` to `./artifacts/`.
8. Compute SHA256, write `SHA256SUMS`.
9. Create / update GitHub Release for the tag, attach `panel-sitronix-st7701-<kernel>.ko` and `SHA256SUMS`.

### `.github/workflows/shellcheck.yml`

Trigger: pull_request, push to main. Runs `shellcheck scripts/**/*.sh tools/**/*.sh`.

## 11. Community files

- **`LICENSE`** — MIT.
- **`CONTRIBUTING.md`** — issue policy (include kernel running, `dmesg | grep goodix`, evtest output), PR policy (feature branch, shellcheck must pass, no secrets, no committed `.ko`).
- **`CHANGELOG.md`** — Keep-a-Changelog format. First entry: `0.1.0 — initial public release`.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — generic bug template.
- **`.github/ISSUE_TEMPLATE/replication_help.md`** — checklist for "doesn't work for me" reports: exact hardware, kernel running (`uname -r`), wiring photo, output of `i2cdetect -y 0`, output of `evtest`.
- **`.github/PULL_REQUEST_TEMPLATE.md`** — checklist: tested on real hardware, shellcheck passes, no secrets, no `.ko` committed.

## 12. Release plan (chronological)

1. Change UNO Q password.
2. Translate `enable-gigadisplay-shield.sh` comments + polish `--help`.
3. Write English README, `docs/how-it-works.md`, `docs/troubleshooting.md`, `docs/wiring.md`.
4. Add `LICENSE`, `CONTRIBUTING.md`, `CHANGELOG.md`, issue/PR templates.
5. Add CI workflows.
6. Move `build-st7701-patched-ko.sh` → `tools/dev/build-panel-module.sh`, scrub defaults.
7. Extract the panel module diff into `kernel/panel-sitronix-st7701.patch`. Capture the running kernel `.config` into `kernel/configs/uno-q-7.0.0.config`.
8. Delete obsolete scripts, PDFs, docx, notes/, HANDOFF.md, docs/superpowers/.
9. Local commit of all the above as "chore: prepare for public release".
10. Run `git filter-repo` with the replacements file from §6.
11. Force-push to `origin main`.
12. Create first GitHub Release `v0.1.0` to trigger the CI workflow that builds + attaches the `.ko`.
13. Verify replication: on a freshly-flashed UNO Q, download the Release bundle and run the script — confirm display + touch + X11 all work.

## 13. Out-of-scope (deliberate exclusions)

- **Userspace daemon (`gt911-touch-daemon.py`)**: was Plan A fallback; superseded by Plan B (kernel driver). Removed from the public repo to keep the surface focused. If needed it can be revived from `git log` of the rewritten history.
- **Cross-compile docs at end-user level:** the `.ko` ships pre-built; only maintainers need to rebuild.
- **SSH-from-host tooling (`remote-ssh.sh`, `snapshot-gt911.sh`):** maintainer-only flow; not relevant to end users.

## 14. Success criteria

- A new community member with the documented hardware can go from clean Arduino image → working touch + display in < 30 minutes, following only the README.
- `git log -p` on the public repo returns zero hits for `arduino1334`, `Arduino1334`, `/home/sabas`, and the three specific private IPs.
- CI workflow produces an identical `.ko` (matching SHA256) on each tag build.
- `shellcheck` passes clean on all shipped scripts.
