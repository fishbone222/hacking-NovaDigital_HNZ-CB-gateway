# Release v3.2.0 — April 28, 2026

Two reliability fixes in core boot infrastructure: `boothold && reboot` becomes 100 % reliable on Linux 6.18, and the front-panel button handler is hardened against spurious long-press detection.

> ⚠️ **Fullflash required.** The bootloader's HOLD-flag address changed in this release (V2.5 → V2.6). Bootloader and `boothold` must be upgraded together, so per-partition upgrades across the v3.1.x → v3.2.0 boundary will not work. Use `flash_install_rtl8196e.sh` (full image) — *not* `flash_remote.sh`.

### `boothold && reboot` — 100 % reliability on Linux 6.18

In v3.0 / v3.1, `boothold && reboot` from SSH or the serial console only reached the `<RealTek>` prompt about 73-87 % of the time on Linux 6.18. On Linux 5.10 (v2.x) the same code worked 30/30. Root cause: the kernel was scribbling low DRAM during early boot or shutdown, before its `reserved-memory no-map` declaration is honored — and the v2.x HOLD address sat right in that scribble zone.

The fix moves the HOLD flag to high DRAM (`0x01FFEFFC`, 8 KB below the top), reserves the page in the device tree, and bumps the bootloader to **V2.6**.

Validated: **30 / 30 = 100 %** `boothold && reboot` cycles enter download mode on v3.2.0 (vs 22/30 = 73 % on v3.1.1).

How to upgrade safely:

```bash
./flash_install_rtl8196e.sh -y <gateway-IP>
```

The full regression analysis (bisection across v2.1.6 / v3.0.0 / v3.1.1, address rationale, alternatives considered) lives in [`3-Main-SoC-Realtek-RTL8196E/31-Bootloader/doc/REBOOT_TO_BOOTLOADER.md`](3-Main-SoC-Realtek-RTL8196E/31-Bootloader/doc/REBOOT_TO_BOOTLOADER.md).

### Front-panel button — defense-in-depth against spurious long-press

`S40button` polls GPIO 9 every 100 ms and fires `recover_efr32` on a 5 s sustained press. The original loop trusted the GPIO data register without checking that the line had ever been observed HIGH, that a single LOW reading could be a noise sample, or that the pin mux was still in GPIO mode — any of which could synthesise a phantom long-press.

Four independent guards now harden the path:

- **Edge detection** — disarmed at boot, only counts LOWs after observing a HIGH (guards against a stuck-low pin / wrong pin mux at startup).
- **Debounce** — 3 consecutive LOW polls (~300 ms) required before counting (filters noise).
- **Mux re-verification** — re-read `CNR` before counting; if GPIO 9 reverted to peripheral mode, restore and disarm.
- **Logging** — every state transition is tagged via `logger -t S40button` for post-mortem.

A real 5 s long-press still triggers `recover_efr32 -q`. Spurious paths now stay silent and leave a syslog trace.

> Originally suspected as the cause of [discussion #89](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/89) (EFR32 dropping out after ~1 h on an OT-RCP gateway), `S40button` has since been exonerated by @olivluca's A/B test — no `S40button` or `nrst_pulse` log entries before the failure. The hardening still lands because the path was relying on too many implicit assumptions; the actual #89 failure (HDLC parse errors → Spinel timeout) remains under investigation.

### Flash scripts — SSH works without an SSH key (issue #90)

In v3.1.x, the `flash_*.sh` scripts silently failed for users who hadn't set up an SSH key — including users who *had* a key but with a passphrase and no `ssh-agent` running. Reported by @skinkie hitting "Permission denied" with a perfectly valid encrypted RSA key.

`BatchMode=yes` is gone from the hardened SSH options. The protective `ConnectTimeout` + `ServerAliveInterval` already cover the transport hang that `BatchMode` was originally added to defuse, so dropping it costs nothing and unlocks two new auth paths:

- **Encrypted key without agent** — passphrase prompted **once** at the start of each script.
- **Root password only** — password prompted **once** at the start of each script.

The "once" comes from a centralized SSH ControlMaster in `lib/ssh.sh`: every script's back-to-back SSH calls now ride a single multiplexed channel — no re-auth, no re-handshake, faster on slow links.

Non-interactive automation with password only (CI, no tty) is supported via the new `SSH_PASSWORD` env var — the scripts feed it to `sshpass` for the first ssh call, then ControlMaster takes over:

```sh
SSH_PASSWORD=root ./flash_efr32.sh -y -g 192.168.1.88 ncp
```

`sshpass` is checked as a hard dependency only when `SSH_PASSWORD` is set; interactive runs without it remain prompt-driven and don't need it installed. README's "What You Need" documents the four modes (key in agent / encrypted key / interactive password / non-interactive `SSH_PASSWORD`).

### `flash_install_rtl8196e.sh` — post-install hints show your real IP (issue #90)

If you typed a static IP other than the default during the install prompt, the four hint lines at the end (`SSH: root@…`, `Flash with: ./flash_efr32.sh …`) used to fall back to the hardcoded `192.168.1.88` because the IP was set in a subshell that never made it back to the parent. The final `flash_efr32.sh` hint also still printed the v3.0 positional CLI shape, which v3.1.0+ rejects. Both fixed: hints now show the IP you actually picked, and the EFR32 flash command uses the current `-g IP <firmware>` shape.

### `flash_efr32.sh` — always uses the pinned `universal-silabs-flasher` (issue #92)

If your host already had `universal-silabs-flasher` in `$PATH` (e.g. installed in `~/.local/bin`), `flash_efr32.sh` would short-circuit the venv install and call your system version. Older USF releases use `--probe-method` (singular) instead of `--probe-methods` (plural, comma-list) and don't carry our extra-baud patch — so the call would fail with `No such option: --probe-methods`.

The script now always uses its pinned venv (USF 1.0.3 + patch); your system USF is ignored. If you really need to override (rare), set `USF_ALLOW_SYSTEM=1`.

---

Full technical changelog: [`3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md`](3-Main-SoC-Realtek-RTL8196E/CHANGELOG.md#320---2026-04-28).
