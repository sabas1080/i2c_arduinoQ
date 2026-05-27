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

**Project license: MIT.** Copyright "2026 Sabas Jimenez / Electronic Cats". Standard MIT text in `LICENSE`. Covers the userspace scripts and original documentation.

### License attribution per file

The repository ships three categories of artifact with different licensing constraints:

| File / category | License | Rationale |
|---|---|---|
| `LICENSE`, `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/**`, `.github/**`, `scripts/enable-gigadisplay-shield.sh`, `tools/dev/build-panel-module.sh` | MIT | Original work for this project. |
| `scripts/gigadisplay-shield.dtso` | `GPL-2.0+ OR BSD-3-Clause` | Kernel device-tree source; already carries SPDX header following the standard kernel DTS convention. |
| `kernel/panel-sitronix-st7701.patch` | `GPL-2.0+ OR BSD-3-Clause` | Derived from the upstream `panel-sitronix-st7701.c` driver. SPDX header in the patch's added lines must match the original file. |
| `panel-sitronix-st7701.ko` (Release asset, never in git) | GPL-2.0 | Compiled from GPL kernel sources; redistribution follows kernel GPL terms. |

**README "Licensing" section** spells this out in plain English so reusers know which pieces they can lift under MIT and which carry GPL obligations. No dual-licensing in the top-level `LICENSE` file — SPDX headers per-file do the work cleanly.

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
│   ├── enable-gigadisplay-shield.sh   # The install entry point (idempotent, --revert)
│   ├── validate-gigadisplay-shield.sh # Post-reboot verifier — 14 checks, exit 0 on PASS
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
- `Test Shield-Adapter.docx` — Arduino internal support note, tracked since the initial commit `e969770`; remove with `git rm` (it does not appear in any other extension). Possibly proprietary; do not republish without explicit permission.
- `docs/HANDOFF.md` — Spanish bitácora with obsolete diagnostics.
- `docs/superpowers/` — internal planning artifacts.
- `notes/` — measurement logs; not useful for public audience.
- `scripts/patch-dtb.sh`, `bind-gt911.sh`, `unbind-gt911.sh`, `diagnose-i2c.sh`, `arduino-style-reset.py`, `build-goodix-fw.py`, `manual-cfg.sh`, `snapshot-gt911.sh`, `verify-gt911.sh`, `gt911-touch-daemon.py`, `gt911-touch.service`, `install-touch-calibration.sh`, `remote-ssh.sh` — superseded by `enable-gigadisplay-shield.sh`.

### Files relocated

- `scripts/build-st7701-patched-ko.sh` → `tools/dev/build-panel-module.sh`, defaults scrubbed (no hardcoded password/IP), purely a maintainer convenience that mirrors the CI workflow.

### Files untracked (moved out of git, kept as Release artifacts)

- `scripts/panel-sitronix-st7701.ko` — currently tracked in commit `85805fa` (~130KB binary). In Phase A we `git rm` it and add `*.ko` to `.gitignore`. The canonical distribution channel becomes the GitHub Release attached by CI, with verifiable SHA256. Rationale: avoid binary bloat in clones; GPL obligations are satisfied by shipping `kernel/panel-sitronix-st7701.patch` + the public CI recipe that anyone can re-run.

## 6. Secrets & data scrubbing

### What was found

| Item | Where | Severity |
|---|---|---|
| `***REDACTED***` / `***REDACTED***` (UNO Q SSH password) | `HANDOFF.md`, `docs/superpowers/plans/...md`, `build-st7701-patched-ko.sh`, **git history** | High |
| `192.168.0.XXX`, `.149`, `.184` (private LAN IPs) | Same files | Low (not routable) |
| `/path/to/repo/...` (personal paths) | Plans, snapshot script | Low |
| `sabasjimenez@gmail.com` (commit author email) | Git author of every commit | Accepted (public identity) |

### Strategy

1. **Change the UNO Q password** (defense in depth — leaked password becomes invalid).
2. **Scrub working tree** before rewrite: remove hardcoded defaults from `tools/dev/build-panel-module.sh`; delete the files in §5 ("Files removed").
3. **Rewrite history** with `git filter-repo` using a replacements file:
   ```
   regex:***REDACTED***==>***REDACTED***
   regex:***REDACTED***==>***REDACTED***
   regex:192\.168\.0\.(105|149|184)==>192.168.0.XXX
   regex:/path/to/repo/==>/path/to/repo/
   ```
   This only redacts blob *content* across all commits. File-level history of the deleted obsolete files (PDFs, old scripts, HANDOFF.md, etc.) remains in the rewritten log — that's intentional, the deletions show as normal commits and don't carry any secrets. We do not use `--invert-paths` because the goal is scrubbing leaks, not erasing the project's evolution.
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
| Feature | Kernel 7.0.0-g122c2c22d838 |
| Display DSI 480×800 | ✓ (patched panel-sitronix-st7701 module) |
| Touch GT911 (I2C 0x14) | ✓ (kernel goodix_ts via DT overlay) |
| X11 cursor (calibrated, landscape) | ✓ |

> Kernel 6.16.7 is **not** supported by the current release script; it was the original development target and remains visible in git history if you need to retrace the journey. See `docs/how-it-works.md` → "Project history".

## Quick start
1. Flash official Arduino UNO Q image.
2. Wire touch lines → docs/wiring.md.
3. Download latest Release bundle (script + dtso + .ko).
4. On-device: ./enable-gigadisplay-shield.sh
5. Reboot. Done.

## Verification
```bash
./validate-gigadisplay-shield.sh
```
Prints a 14-check report (board id, kernel, panel module, DSI panel, goodix_ts binding, IRQs, X11 device). Exit 0 means everything is up. Manual deep-dive: `evtest /dev/input/event*` and `xinput list`.

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
Five sections:
1. **The panel descriptor problem (kernel 7.0.0):** Arduino removed `arduino_giga_display_desc` from `panel-sitronix-st7701` in 7.0.0. The patched module reintroduces it.
2. **The device-tree overlay:** what `gigadisplay-shield.dtso` adds (the gt911@14 node, the panel hookup) and how `fdtoverlay` composes it onto the base DTB.
3. **The boot loader entry:** why we add `devicetree /...` and `video=DSI-1:480x800@60` to `/boot/efi/loader/entries/`.
4. **X11 calibration:** what the TransformationMatrix means and how it was derived (4-corner capture with evtest, normalized to abs_max=479/799).
5. **Project history:** the 6.16.7 path, the GPIO-flags-in-DTB bug (red herrings: T8 timing, pinctrl-msm), and why the kernel-7.0.0 + overlay + patched-module approach is now canonical. Honors the work but doesn't confuse the user about what to actually run.

### `docs/troubleshooting.md`
Table-driven: Symptom → likely cause → diagnostic command → fix. Examples:
- "Touch not detected by i2cdetect" → wiring or 3V3 not connected → `i2cdetect -y 0` → recheck pinout.
- "evtest shows events but X11 cursor doesn't move" → missing X11 calibration snippet → check `/etc/X11/xorg.conf.d/`.
- "Display black after reboot" → boot entry edit missed → check `/boot/efi/loader/entries/*.conf`.
- "Coordinates inverted / rotated wrong" → rotation = "right" vs "left" → swap value in `10-monitor.conf`.

## 10. CI workflow

### `.github/workflows/build-panel-module.yml`

Trigger: tags matching `v*`.

**Important constraint:** an out-of-tree `make M=drivers/gpu/drm/panel` build fails with "unresolved symbols" because `modules_prepare` does not produce `Module.symvers`; only a full kernel build does. The workflow therefore performs a full `make modules` (which builds `vmlinux` as a dependency and writes `Module.symvers`) and extracts only the panel `.ko` afterward. Verified empirically by Sabas on local cross-build.

Steps:
1. Checkout this repo.
2. Restore caches (see "Caching" below). Cache miss falls through to steps 3-6; cache hit jumps to step 7.
3. Install host packages: `gcc-aarch64-linux-gnu libelf-dev libssl-dev flex bison bc cpio ccache`.
4. Clone `arduino/linux-qcom@qcom-v7.0.0-unoq` (full clone — shallow misses tag refs needed for the kernel's own version computation).
5. Apply `kernel/panel-sitronix-st7701.patch` and copy `kernel/configs/uno-q-7.0.0.config` to the kernel tree as `.config`. Run `make olddefconfig` to absorb any new symbols.
6. Build: `make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache aarch64-linux-gnu-gcc" modules`.
7. Extract: `aarch64-linux-gnu-strip --strip-debug drivers/gpu/drm/panel/panel-sitronix-st7701.ko` and copy to `./artifacts/panel-sitronix-st7701-<kernel-release>.ko`.
8. Compute SHA256, write `SHA256SUMS`.
9. Create / update GitHub Release for the tag, attach the `.ko` and `SHA256SUMS`.

**Caching strategy** (keep first build under ~40 min, subsequent under ~5 min):
- Cache key: `kernel-tree-${{ hashFiles('kernel/panel-sitronix-st7701.patch', 'kernel/configs/uno-q-7.0.0.config') }}-${{ env.KERNEL_BRANCH_SHA }}`.
- Cache paths: the cloned kernel tree (post-build), `~/.ccache`.
- On cache hit, skip the clone+patch+config steps and re-link from cached `.o` files (kernel's incremental build catches what changed).
- `KERNEL_BRANCH_SHA` resolved at runtime via a small step that does `git ls-remote arduino/linux-qcom qcom-v7.0.0-unoq` and stashes the SHA into `$GITHUB_ENV` — this invalidates the cache when Arduino force-pushes the branch.

### `.github/workflows/shellcheck.yml`

Trigger: pull_request, push to main. Runs `shellcheck scripts/**/*.sh tools/**/*.sh`.

## 11. Community files

- **`LICENSE`** — MIT.
- **`CONTRIBUTING.md`** — issue policy (include kernel running, `dmesg | grep goodix`, evtest output), PR policy (feature branch, shellcheck must pass, no secrets, no committed `.ko`).
- **`CHANGELOG.md`** — Keep-a-Changelog format. First entry: `0.1.0 — initial public release`.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — generic bug template.
- **`.github/ISSUE_TEMPLATE/replication_help.md`** — checklist for "doesn't work for me" reports: exact hardware, kernel running (`uname -r`), wiring photo, output of `i2cdetect -y 0`, output of `evtest`.
- **`.github/PULL_REQUEST_TEMPLATE.md`** — checklist: tested on real hardware, shellcheck passes, no secrets, no `.ko` committed.

## 12. Release plan (two-phase)

The plan is intentionally split into a **Phase A** of normal-history commits to the working tree, and a **Phase B** of destructive history-rewrite operations. If anything in Phase A fails or needs to be rolled back, nothing destructive has happened to the remote yet. Phase B only fires once Phase A is fully committed and visually reviewed.

### Phase A — working-tree preparation (normal commits)

A1. **Change the UNO Q password.** Defense in depth — the leaked password becomes invalid regardless of what happens next.

A2. **Polish `enable-gigadisplay-shield.sh`:** translate inline comments + section banners to English, enrich `--help`, expand prerequisites check (warn if user not in `i2c`/`gpiod`/`input` groups), add clear error + Release-URL hint when `.ko`/`.dtso` companions are missing.

A3. **Write English documentation:** `README.md`, `docs/how-it-works.md`, `docs/troubleshooting.md`, `docs/wiring.md`, `docs/images/`.

A4. **Add community files:** `LICENSE` (MIT), `CONTRIBUTING.md`, `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/{bug_report,replication_help}.md`, `.github/PULL_REQUEST_TEMPLATE.md`.

A5. **Add CI workflows:** `.github/workflows/build-panel-module.yml` and `.github/workflows/shellcheck.yml`.

A6. **Relocate maintainer tooling:** `scripts/build-st7701-patched-ko.sh` → `tools/dev/build-panel-module.sh`; remove hardcoded `***REDACTED***` / `192.168.0.XXX` defaults (require env vars or fail clearly).

A7. **Extract the panel patch to a self-contained unified diff** (`kernel/panel-sitronix-st7701.patch`). Concrete recipe, reproducible from scratch:
   ```bash
   # In a scratch directory, NOT the public repo:
   git clone --branch qcom-v7.0.0-unoq --depth 200 \
     https://github.com/arduino/linux-qcom.git kbuild
   cd kbuild
   # Apply the inline patch from the legacy build script (one-time bootstrap):
   ../i2c_arduinoQ/tools/dev/build-panel-module.sh --apply-patch-only
   git add drivers/gpu/drm/panel/panel-sitronix-st7701.c
   git commit -m "panel: reintroduce arduino_giga_display_desc for GIGA shield"
   git format-patch -1 HEAD --stdout > ../i2c_arduinoQ/kernel/panel-sitronix-st7701.patch
   ```
   Then verify: `cd kbuild-fresh && git apply --check ../i2c_arduinoQ/kernel/panel-sitronix-st7701.patch`. The implementation plan will decide whether `--apply-patch-only` needs to be added to the build script as a non-destructive mode, or whether the heredoc gets inlined into the patch generation directly.

A8. **Capture the running kernel `.config`** from a UNO Q at the target kernel into `kernel/configs/uno-q-7.0.0.config` (used by CI).

A9. **Delete obsolete tree and untrack the .ko:** `git rm` the PDFs, `Test Shield-Adapter.docx` (tracked since `e969770`), `docs/HANDOFF.md`, `docs/superpowers/`, `notes/`, the 12 superseded scripts listed in §5, **and `scripts/panel-sitronix-st7701.ko`** (currently tracked in `85805fa`, ~130KB binary; moves to Release-only distribution). Update `.gitignore` to include `*.ko`.

A10. **Commit Phase A.** Single or grouped commits as appropriate, ending with a `chore: prepare for public release` head commit.

A11. **Visual review on GitHub.** Push Phase A to a feature branch (e.g. `prep/v0.1.0`) and open a draft PR against `main` so you can review the diff in the GitHub UI before merging or proceeding to Phase B. **Do not push to `main` yet.**

### Phase B — destructive history rewrite (only after A is green)

B1. **Backup branch.** Locally and on the remote:
   ```bash
   git branch backup/pre-filter-repo-$(date -I) main
   git push origin backup/pre-filter-repo-$(date -I)
   ```
   This is the safety net. If the rewrite goes wrong, restore from this branch.

B2. **Merge `prep/v0.1.0` → `main`** so `main` has the clean Phase A state. This is the last non-destructive operation.

B3. **Run `git filter-repo`** with the replacements file from §6 on the local clone of `main`.

B4. **Verify scrubbing locally** before pushing: `git log -p | grep -E '(***REDACTED***|***REDACTED***|/path/to/repo|192\.168\.0\.(105|149|184))'` must return zero hits.

B5. **Force-push** with `--force-with-lease origin main`.

B6. **Tag `v0.1.0`** and push the tag → triggers the CI workflow that builds and attaches the `.ko` to a fresh GitHub Release.

B7. **End-to-end replication test:** on a freshly-flashed UNO Q, download the Release bundle (`enable-gigadisplay-shield.sh` + `validate-gigadisplay-shield.sh` + `gigadisplay-shield.dtso` + `.ko`) and run the install script. After reboot, run `./validate-gigadisplay-shield.sh` and confirm 14/14 PASS. Verify the only references are to the public repo and its Release — no leftover dependencies on your local workstation.

## 13. Out-of-scope (deliberate exclusions)

- **Userspace daemon (`gt911-touch-daemon.py`)**: was Plan A fallback; superseded by Plan B (kernel driver). Removed from the public repo to keep the surface focused. If needed it can be revived from `git log` of the rewritten history.
- **Cross-compile docs at end-user level:** the `.ko` ships pre-built; only maintainers need to rebuild.
- **SSH-from-host tooling (`remote-ssh.sh`, `snapshot-gt911.sh`):** maintainer-only flow; not relevant to end users.

## 14. Success criteria

- A new community member with the documented hardware can go from clean Arduino image → working touch + display in < 30 minutes, following only the README.
- `git log -p` on the public repo returns zero hits for `***REDACTED***`, `***REDACTED***`, `/path/to/repo`, and the three specific private IPs.
- CI workflow produces an identical `.ko` (matching SHA256) on each tag build.
- `shellcheck` passes clean on all shipped scripts.
