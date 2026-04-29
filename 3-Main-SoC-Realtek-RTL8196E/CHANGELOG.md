# Changelog — RTL8196E Platform (Lidl Silvercrest Gateway)

All notable changes to the RTL8196E firmware distribution are documented here.
A version covers the complete set of components: bootloader (31-), kernel (32-),
rootfs (33-), and userdata (34-).

---

## [3.2.0] - 2026-04-28

Two reliability fixes that touch core boot infrastructure: the
`boothold && reboot` mechanism becomes 100 % reliable on Linux 6.18,
and the front-panel button handler is hardened against spurious
long-press detection. Because the bootloader's HOLD address changed,
**this release requires a fullflash** when upgrading from v3.1.x or
earlier — per-partition upgrade across this boundary is unsupported.

### Bootloader V2.6 + `boothold` — move HOLD flag to high DRAM (0x01FFEFFC)

The boot-hold mechanism (Linux writes a magic word to a fixed DRAM
address; bootloader reads it after watchdog reset and stops at the
`<RealTek>` prompt) regressed on Linux 6.18: at the v2.x address
`0x003FFFFC` it hit ~73-87 % reliability instead of the 100 % we got
on Linux 5.10. The kernel was scribbling low DRAM during early init
or shutdown, before the `reserved-memory no-map` declaration is
enforced — independent of `boothold` itself (the helper binary is
bit-identical between v3.0.1 and v3.1.1).

Bisection across v2.1.6 / v3.0.0 / v3.1.1 with mixed kernel/userland
combinations pinned the regression to the 5.10 → 6.18 transition (and
its toolchain refresh). Mitigations attempted at the original address
(`mmap` + `O_SYNC`, `__sync_synchronize`, `usleep` between write and
reboot) did not break 80 % reliability — the conflict is in the
kernel's memory access patterns, not the cache path.

The fix moves HOLD to the page just below the btcode stack
(`0x01FFEFFC` — high DRAM, 32 MB − 8 KB) and reserves it in the device
tree as `reserved-memory` with `no-map`:

* `31-Bootloader/boot/main.c` — read `BOOTHOLD_RAM = 0xA1FFEFFC` (KSEG1
  uncached), clear it before `goToDownMode()`. Bootloader bumps to
  **V2.6** (was V2.5).
* `34-Userdata/boothold/boothold.c` — `pwrite(/dev/mem, ..., 0x01FFEFFC)`.
  Helper itself is simpler than v3.1.1 — no cache flushes, no
  `O_SYNC` dance: the new address is in a `no-map` page, the kernel
  never touches it, and KSEG1 from the bootloader bypasses cache.
* `32-Kernel/files-6.18/arch/mips/boot/dts/realtek/rtl8196e.dts` —
  new `boothold@1ffe000` reserved-memory node (4 KB, `no-map`).
* `31-Bootloader/doc/REBOOT_TO_BOOTLOADER.md` — full rewrite with
  the regression analysis, address-safety map, and upgrade path.

Validated at the new address: **30 / 30 = 100 %** of `boothold &&
reboot` cycles enter download mode on v3.2.0 (vs 22 / 30 = 73 % on
v3.1.1 at the old address).

**Upgrade path: fullflash required.** A bootloader V2.5 + boothold
v3.2.0 mismatch (or vice versa) leaves `boothold && reboot`
non-functional, since they read/write different addresses. Use:

```
./flash_install_rtl8196e.sh -y <gateway-IP>
```

(`flash_remote.sh` per-partition upgrades across the v3.1.1 →
v3.2.0 boundary will not work.)

### `S40button` — defense-in-depth against spurious long-press

`S40button` polls GPIO 9 every 100 ms and fires `recover_efr32` on a
5 s sustained press. The poll loop trusted the GPIO data register
without checking that the line had ever been observed HIGH, that a
single LOW reading could be a noise sample, or that the pin mux was
still in GPIO mode. Any of those could in principle synthesise a
phantom long-press and reset the EFR32 from thin air.

Four mitigations land together as defense-in-depth, none of them
trusting the others:

1. **Edge detection** — start disarmed; only count LOWs after observing
   a HIGH on GPIO 9. Guards against a stuck-low pin or wrong pin mux at
   startup.
2. **Debounce** — require 3 consecutive LOW polls (~300 ms) before
   treating it as a real press. Filters single-sample noise.
3. **Mux re-verification** — before counting a press, re-read CNR. If
   GPIO 9 was flipped back to peripheral mode at runtime, restore GPIO
   mode, log it, and require re-arming via HIGH.
4. **Logging** — every state transition (armed, press, release, mux
   flip, long-press fire) goes through `logger -t S40button` for
   post-mortem diagnostics.

Behaviour on a healthy board is unchanged — a real 5 s long-press
still triggers `recover_efr32 -q`. Edge cases that previously could
fire spuriously now stay silent and leave a syslog trace.

> **Note on [discussion #89](https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/89).**
> An early hypothesis suggested `S40button` misfiring might be
> behind the EFR32 dropping out after ~1 h on @olivluca's OT-RCP
> gateway (`Reset info: 0x301 (PIN)` traces). The A/B test
> (`/userdata/etc/init.d/S40button stop` for several hours) showed
> no `S40button` or `nrst_pulse` log entries before the failure,
> and the `PIN` reset was confirmed to be the normal pulse from
> `recover_efr32` during `S70otbr` startup. **`S40button` is
> exonerated** for #89; the actual failure (HDLC parse errors →
> Spinel timeout) is still being investigated. The hardening above
> ships anyway as defensive cleanup of a path that was relying on
> too many implicit assumptions.

### Flash scripts — SSH auth UX (issue #90)

`lib/ssh.sh` carried `BatchMode=yes` since v3.1.0 to defuse a 17-min
hang seen during the 5-baud NCP loop test. Side effect: silently
fails on encrypted private keys not loaded in `ssh-agent`, and
forbids password prompts entirely — leaving users without a key with
no path forward (reported by @skinkie).

The original hang was at the transport layer (`ssh root@gw 'true'`
stuck on a half-broken TCP), not at auth. `ConnectTimeout=5` +
`ServerAliveInterval=3` + `ServerAliveCountMax=2` already cover that.
`BatchMode=yes` was a redundant belt-and-braces that turned out to
bite users.

* **Drop `BatchMode=yes`** — auth-time prompts now go through (once).
* **Centralise SSH ControlMaster in `lib/ssh.sh`** — was previously
  duplicated in `flash_install_rtl8196e.sh` and `flash_remote.sh`,
  absent from `flash_efr32.sh`. Per-script `mktemp -d` socket dir
  (mode 0700, `${UID}-$$`-keyed) avoids collisions between concurrent
  runs and between users on a shared host.
* **`ssh_cleanup_multiplex` helper** — sends `-O exit` to every live
  master, drops the tmpdir. Idempotent; callers chain it into their
  existing EXIT trap.

User-visible result:

| Setup | Before | After |
|---|---|---|
| Key in agent (or no passphrase) | works | works (unchanged) |
| Encrypted key, no agent | silent "Permission denied" | passphrase prompted **once** |
| Root password only | silent "Permission denied" | password prompted **once** |
| stdin closed (CI) | silent fail | fails immediately after timeout |

The "once" comes from ControlMaster — every script does N back-to-back
SSH calls, all of which now ride a single multiplexed channel.

For full **non-interactive automation with password only** (CI, scripted
runs without a tty), a new `SSH_PASSWORD` env var feeds the password to
ssh via `sshpass`. The new `ssh_prime_with_password` helper in
`lib/ssh.sh` opens the ControlMaster up-front using `sshpass -e`;
subsequent ssh calls ride the multiplexed channel as usual. `sshpass`
is checked as a hard dependency only when `SSH_PASSWORD` is set;
interactive runs without it remain prompt-driven and don't need
`sshpass` installed.

```sh
# Interactive (default): ssh prompts, you type once
./flash_efr32.sh -y -g 192.168.1.88 ncp

# Non-interactive (no tty): SSH_PASSWORD is fed via sshpass
SSH_PASSWORD=root ./flash_efr32.sh -y -g 192.168.1.88 ncp
```

README's "What You Need" gains an explicit SSH access section
documenting the four modes (key in agent / encrypted key / interactive
password / non-interactive `SSH_PASSWORD`).

### `flash_install_rtl8196e.sh` — show user-chosen IP in post-install hints (issue #90)

The IP prompted at first-flash (default `192.168.1.88`, but @skinkie
typed `192.168.5.252`) was set inside `build_fullflash.sh`'s subshell
and never propagated back to the parent. The four post-install hint
lines fell through to the hardcoded default — telling users to
`ssh root@192.168.1.88` for a gateway that lives at `.5.252`. The
final `Flash with: ./flash_efr32.sh <IP>` hint additionally used the
v3.0 positional syntax dropped in v3.1.0 — that command now errors.

* Pre-create `SKEL_WORK` in the parent on first-flash too, so
  `build_fullflash.sh` writes `eth0.conf` into a dir the parent owns.
* Read `IPADDR` back from the generated `eth0.conf` after the build
  returns; introduce `GW_HINT_IP` resolved from `LINUX_IP` (upgrade)
  or `IPADDR` (first-flash) or the default.
* Rewrite the final hint to the current CLI shape:
  `./flash_efr32.sh -g <IP> ncp` (or `otrcp` when MODE=otbr).

### `flash_efr32.sh` — always use the pinned venv USF (issue #92)

Reported by @skinkie: `universal-silabs-flasher` exits with
`Error: No such option: --probe-methods Did you mean
--probe-method?` on a host that already has USF installed in
`~/.local/bin`.

The script's USF resolution preferred `command -v
universal-silabs-flasher` over the venv install — so any USF in
`$PATH` short-circuited the install path. Older USF releases use
`--probe-method` (singular, no comma-list) and none of them carry
our `DEFAULT_PROBE_METHODS` patch (extra bauds for EZSP / SPINEL /
CPC at 230400 / 691200 / 892857). The script then called the system
binary with the new CLI shape and patched bauds it didn't have.

Fix:

* Always use the pinned venv (USF 1.0.3 + our probe-methods patch).
  The system USF is ignored even when present.
* New `USF_ALLOW_SYSTEM=1` env var as an explicit escape hatch for
  operators who really want to point at a system install — with a
  warning that probe results may differ.

### Documentation

- `31-Bootloader/doc/REBOOT_TO_BOOTLOADER.md` — full rewrite
  (mechanism, address rationale, regression analysis table,
  upgrade-path note for the v3.1.1 → v3.2.0 fullflash boundary).
- `boothold.c` header — English narrative of the regression and
  why the new address is reliable.
- README "What You Need" — three SSH access modes (key / encrypted
  key / password), default password reminder.
- Per-version banners (`/etc/version`, `/etc/motd`, bootloader
  print) updated to v3.2.0 / V2.6.

---

## [3.1.1] - 2026-04-27

Hardening pass on the kernel UART bridge and a few operator-facing
rough edges sanded off the flash tooling. No new features; one config
simplification (`radio.conf` collapses two redundant baud keys into
one). Upgrade is in-place — no user action needed for legacy configs.

### Kernel — `rtl8196e-uart-bridge` hardening

Four correctness fixes landed together; one image rebuild covers
them all (`kernel-6.18.img` refreshed once at the end of the batch).
No operator-visible behaviour change in the normal path.

* **Drop `bridge_lock` across `nrst_pulse`'s `msleep(100)`.**
  `param_set_nrst_pulse()` used to hold the global mutex from the
  lazy syscon init through the full assert/sleep/release sequence,
  so the UART → TCP hot path stalled for ~100 ms on every EFR32
  reset. Real-world impact is minimal (the protocol asks operators
  to stop the radio daemon before pulsing), but holding a global
  mutex across `msleep` on a single-core CPU is sloppy. Narrowed
  `bridge_lock` to the syscon lookup; the assert/sleep/release runs
  under a new dedicated `nrst_pulse_lock` so concurrent pulses still
  serialize on the syscon bits.
* **Drop the stale IRAM promise from Kconfig and the
  `late_initcall` comment.** Both claimed the hot path lives in
  IRAM; in practice the IRAM placement was shelved after measurement
  showed plain `.text` was sufficient at 892857 baud (see
  `DESIGN.md` "Options considered and dropped"). Doc-only — keeps
  the built-in requirement, justifies it via `late_initcall`
  ordering and the no-unload contract instead.
* **Tighten `status_led_brightness` lock discipline.** The
  brightness param was wired through `module_param_named` with a
  direct write to the int variable; the worker thread read the same
  variable unlocked when firing the LED trigger on client connect.
  Real-world impact minimal (32-bit aligned int, RLX4181 won't
  tear), but it was the only live-tunable param bypassing the lock
  and KCSAN would flag the data race. Converted to `module_param_cb`
  with locked setter/getter (same pattern as `baud`, `port`,
  `bind_addr`, `flow_control`); the worker now snapshots the
  clamped value into a local under `bridge_lock` so
  `led_trigger_event` runs lockless without racing the setter.
* **Save and restore tty `client_ops` verbatim across arm/disarm.**
  `bridge_arm_locked()` replaced `tty->port->client_ops` with our
  hook, but disarm/err paths always wrote
  `tty_port_default_client_ops` back. Today that's the same pointer
  (ttyS1 carries the default at boot) so the bug is purely latent —
  but if the port ever gets a `serdev` or other layered consumer
  ahead of us, disarm would silently overwrite it. Now stashes the
  previous pointer in `state.saved_client_ops` at arm time and
  restores it from there.

### `flash_efr32.sh` — refuse to flash when the bridge is in use

Reads `/proc/net/tcp` on the gateway in the existing detection
heredoc; emits `PEER=IP:PORT` (or empty) alongside the other
`KEY=VALUE` lines. If non-empty, abort with the peer's IP so the
operator knows which host to silence. Otherwise the kernel bridge
would silently replace the existing client (`"replacing previous
client"` in `dmesg`) and let Z2M / ZHA / `otbr-agent` fight USF for
the socket. Covers Z2M wherever it lives — gateway, the host
running the script, or any third box (Pi/NAS) — `/proc/net/tcp` on
the gateway sees them all uniformly. No `--force` escape hatch:
stop the right process on the right machine.

### `backup_gateway.sh` + `flash_install_rtl8196e.sh` — defer the `BOOT_IP` L2 check (issue #88)

Both scripts ran an unconditional pre-flight check that `BOOT_IP`
(default `192.168.1.6`, the bootloader's hard-coded TFTP IP) was on
the same L2 segment. SSH backup and SSH-based firmware detection
don't need that — they only need `LINUX_IP` — so users on a routed
network were blocked before the script could do anything useful.

* `backup_gateway.sh` — drop the unconditional check and the
  now-unused `check_tftp` / `resolve_iface` helpers. SSH backup
  runs from any routable subnet.
* `flash_install_rtl8196e.sh` — new `require_boot_l2` helper
  (resolves `IFACE`, enforces L2, prints a `sudo ip addr add
  192.168.1.10/24 dev <iface>` hint). Called lazily — just before
  `boothold && reboot` on the upgrade path, immediately on the
  bootloader-only path. Backup proposal and config save still work
  from a routed network; failure now surfaces *before* the gateway
  is tipped into bootloader mode rather than after.

Reported by @skinkie on a v2.x → v3.1 migration with the gateway at
`192.168.5.252` and the host on the same routed subnet.

### `radio.conf` — single baud key

Pre-v3.1.1 `radio.conf` carried two redundant baud keys: a chip-
side `FIRMWARE_BAUD` (set at flash time, "what's on the chip") and
a host-side `BRIDGE_BAUD` (Zigbee path) or `OTBR_BAUD` (OTBR path)
read by the init scripts. Both ends of a UART link must agree, so
in practice the keys were always written and read at the same
value — duplication that only created room for divergence and
confusion.

Single source of truth: `FIRMWARE_BAUD`. Both `S50uart_bridge` and
`S70otbr` read this same key now.

* `flash_efr32.sh` stops emitting `BRIDGE_BAUD` / `OTBR_BAUD`
  entirely; the existing `sed` cleanup in the persist path strips
  legacy keys so old configs converge on every flash.
* `flash_install_rtl8196e.sh`'s v2 → v3 migration heredoc only
  writes `FIRMWARE_BAUD` now.
* Backwards compat: `S50uart_bridge` / `S70otbr` fall back to the
  legacy host-side keys when `FIRMWARE_BAUD` is absent, so a v3.0.x
  install upgrading to v3.1.1+ keeps working until the next
  `flash_efr32.sh` run strips them. **No user action needed.**

OT-RCP three-case switching (1/2 ↔ 3) becomes simpler too: just
add or remove `MODE=otbr` — no baud key to flip — see
[`26-OT-RCP/docker/README.md`](../2-Zigbee-Radio-Silabs-EFR32/26-OT-RCP/docker/README.md#switching-radio-mode-no-efr32-reflash-needed).

### Documentation

- ~14 README files swept to drop `BRIDGE_BAUD` / `OTBR_BAUD` from
  user-facing reference (canonical `radio.conf` reference in
  [`34-Userdata/README.md`](34-Userdata/README.md#radioconf-keys-full-reference);
  per-firmware READMEs in `24-NCP`, `25-RCP`, `26-OT-RCP`,
  `27-Router`; kernel-driver `README.md` / `DESIGN.md` /
  `SECURITY.md`; migration guide).
- `23-Bootloader-UART-Xmodem/firmware/README.md` — drop the dead
  link to the unshipped Stage-2-only `.s37` (`*.s37` is gitignored
  except the `-combined.s37` artefact); restored a green
  `mkdocs --strict` CI build.

---

## [3.1.0] - 2026-04-26

EFR32 radio recovery and a rock-solid `flash_efr32.sh`. The kernel
gains a write-only sysfs knob to chip-reset the EFR32 without touching
the SoC; userland gets a mode-aware recovery helper and a long-press
front-panel button handler that wires it all together. The companion
flash script is rewritten with proper CLI ergonomics, hardened SSH,
and ~120 lines of scan-baud heuristics removed (the kernel pulse
makes them obsolete). The `etc/version` component table is also
refreshed to reflect what v3.0 actually shipped.

### Kernel — `nrst_pulse` sysfs knob in `rtl8196e-uart-bridge`

- Write-only kernel param at
  `/sys/module/rtl8196e_uart_bridge/parameters/nrst_pulse`: writing
  `1` asserts the EFR32 `nRST` line via `PIN_MUX_SEL_2` bits {7,10,13}
  (sysc reg 0x44, mask 0x2480), holds 100 ms, releases. Recovers a
  stuck EFR32 (crashed app, J-Link halt, `pc==0xFFFFFFFF`) without
  rebooting the SoC.
- Implementation uses `syscon_regmap_lookup_by_compatible()` against
  `"realtek,rtl819x-sysc"` (same syscon used by `rtl8196e-eth`),
  looked up lazily on first pulse. Pulse is taken under `bridge_lock`,
  in-flight UART bytes during the reset are lost (expected).

### Userdata — front-panel button + recovery helper

- `skeleton/usr/sbin/recover_efr32` (new) — mode-aware. Reads
  `/userdata/etc/radio.conf`, stops the matching radio daemon
  (`S70otbr` for `MODE=otbr`, otherwise leaves `S50uart_bridge` up),
  pulses `nrst_pulse`, restarts the daemon. `-q` for quiet mode.
- `skeleton/etc/init.d/S40button` (new) — long-press handler on the
  front-panel button, GPIO 9 (port B bit 1, active LOW) — confirmed
  empirically on the v3.0 board. Holding ≥ 5 s invokes
  `recover_efr32 -q`; shorter presses ignored.
- `skeleton/etc/init.d/S70otbr` — `RCP_URL` now reads `OTBR_BAUD=`
  from `/userdata/etc/radio.conf` (default 460800). Lets
  `flash_efr32.sh otrcp` install a non-default-baud OT-RCP image and
  have `S70otbr` pick the matching baud on next boot.

### `flash_efr32.sh` — top-to-bottom rewrite

Motivated by a 5-baud NCP loop test that pinned the script for ~17
min on a stuck `ssh root@gw 'true'` (no `ConnectTimeout`, no
`ServerAliveInterval`). Parallel goal: real CLI ergonomics — flags,
`--help`, validation before any SSH.

- **CLI** —
  `flash_efr32.sh [OPTIONS] FIRMWARE [BAUD]`
  with positional `FIRMWARE` (`bootloader|ncp|rcp|otrcp|router`,
  numeric `1..5` also accepted) and optional `BAUD` (defaults
  per-firmware). Options: `-g/--gateway IP`, `-y/--yes`,
  `--no-reboot`, `-h/--help`. Env vars `FW_CHOICE` / `BAUD_CHOICE` /
  `CONFIRM` still honoured for one release with a deprecation warning.
- **`ssh_gw` wrapper** — every SSH call uses `ConnectTimeout=5`,
  `ServerAliveInterval=3`, `ServerAliveCountMax=2`, `BatchMode=yes`,
  three retries with 2 s/4 s backoff on transport failure (`rc=255`).
  No more silent infinite hangs after a gateway reboot.
- **Detection rewrite** — remote probe step returns a structured
  `KEY=VALUE` block (`STATUS`, `MODE`, `ARMED`, `BRIDGE_BAUD`) parsed
  with `awk`. Probes ALL four protocols (`ezsp+cpc+spinel+bootloader`)
  at the bridge baud regardless of `RADIO_MODE` — needed for
  bridge-mode OT-RCP that speaks Spinel under `MODE=zigbee`.
- **Pre-flight bootloader check** — first probe at bridge=115200 /
  `flow=0` with `bootloader:115200` covers the "previous flash left
  the chip in the Gecko Bootloader" case (empty app slot after a
  fresh bootloader install). Case-insensitive `grep -qi` catches
  `Detected.*BOOTLOADER` / `bootloader` USF variants.
- **Drop scan-baud (~120 LOC)** — the kernel `nrst_pulse` knob means
  the chip is always at the `radio.conf` baud after a pulse. The
  "stale `radio.conf`" failure path now prints a clear
  "power-cycle and retry" message instead of looping.
- **GBL resolution by glob** — `resolve_firmware()` `ls -1t` the
  `firmware/` dir for the right pattern and picks the most recent
  match. Removes the EmberZNet SDK lookup — the script now runs on a
  host without any Silabs tools.
- **Cleanup is non-rebooting** — `cleanup()` restores bridge state
  and prints "reboot manually if needed". The gateway reboot only
  happens at the end of the success path (suppressible with
  `--no-reboot` for chained flashes).
- **Z3-Router CLI fallback symmetric** — earlier draft fired the
  router-specific `bootloader reboot` CLI hack unconditionally when
  the target was the router, breaking every "non-router → router"
  path (CLI bytes hit a chip that doesn't speak CLI, bridge ends up
  at 115200, downstream probe fails). Now the standard probe runs
  first (so NCP/RCP/OT-RCP/bootloader paths are unaffected) and the
  CLI fallback fires whenever the standard probe fails — handles
  both `router → router` AND `router → ncp/rcp/otrcp` migrations
  (the symmetric case where the chip is already running the router
  firmware and doesn't speak EZSP/CPC/Spinel/Gecko-BTL at all).
- **115200 baud fallback** — when the standard probe at the
  `radio.conf` baud fails, try `ezsp+cpc+spinel+bootloader@115200`
  before giving up. Covers three real-world cases that the v3.1
  nrst_pulse-only design didn't handle on its own (because nrst_pulse
  resets the chip but doesn't change its firmware-baked-in baud):
  * **Tuya stock NCP** — the original Tuya factory firmware runs at
    115200; `flash_efr32.sh` can now upgrade straight from a fresh
    Tuya → custom-Linux install without manually editing `radio.conf`
    first. Validated end-to-end on hardware: chip detected as `EZSP
    6.5.0.0 build 188` running on Tuya bootloader `1.8.0`, then
    cleanly upgraded to NCP 7.5.1 @ 460800 + the new
    `BOOTLOADER_VERSION=1.8.0` (the Tuya bootloader survives — no
    Stage 2 reflash needed) recorded in `radio.conf`.
  * **Stale `radio.conf`** — user manually flashed the EFR32 outside
    this script (Simplicity Commander / J-Link) or the file carries
    a value from a previous firmware no longer on the chip.
  * **Factory state / cold-boot at 115200** — any chip booting at
    the Gecko default after a reset.

  Skipped when `radio.conf` already says 115200 (the standard probe
  just tried that, no point re-trying). The 115200 fallback runs
  before the Z3-Router CLI fallback, so the worst-case slow path is:
  standard probe (~23 s) → 115200 fallback (~23 s if no match) →
  router CLI (~8 s) → final error.

End-to-end validated on hardware (Z2M+cpcd-zigbeed back online with
EmberZNet 8.2.2 / EZSP v18 between every transition):

| Source firmware | Target | Path |
|---|---|---|
| RCP @ 460800 | router | standard probe (CPC → BTL) |
| router | router | CLI fallback |
| router | NCP @ 460800 | CLI fallback |
| OT-RCP @ 460800 | router | standard probe (Spinel → BTL) |
| router | RCP @ 460800 | CLI fallback |
| NCP @ 460800 | RCP @ 460800 | standard probe (EZSP → BTL) |

Plus the original 5-baud NCP sweep (115200..892857), 3 OT-RCP use
cases (ZoH, OTBR-host, OTBR-gateway), and chained bootloader→RCP
flash.

### SSH helpers — `lib/ssh.sh`

The v3.1 ssh-hang fix (the one that turned a 17-min loop test into a
2-min one) was originally inline in `flash_efr32.sh`. Promoted to a
sourceable lib so the same hardening protects the other flash
scripts that talk to the gateway over SSH.

* `lib/ssh.sh` (new) exports:
  - `SSH_HARDEN_OPTS` (bash array) — `ConnectTimeout=5`,
    `ServerAliveInterval=3`, `ServerAliveCountMax=2`, `BatchMode=yes`.
  - `ssh_retry` — `ssh` wrapper that retries only on `rc=255`
    (transport failure) up to 3 times with 2 s/4 s backoff. Real
    remote-command exit codes pass through unchanged.
  - `wait_for_port` — TCP-port-ready poll helper.
* `flash_efr32.sh`, `flash_remote.sh`, and `flash_install_rtl8196e.sh`
  all source `lib/ssh.sh`. The latter two had been re-implementing the
  v3.0-era SSH option string (no `ServerAliveInterval`, no retry on
  `rc=255`) and shared the v3.1 ssh-hang failure mode unfixed —
  validated on a real v2.1.2 → v3.1.0 production migration that
  involved several back-to-back SSH commands plus a mid-session
  reboot, all of which used to be hang candidates.

### `flash_install_rtl8196e.sh` — v2 → v3 migration

Pre-v3.0 firmware (which ran `serialgateway`) had no
`/userdata/etc/radio.conf` — the EFR32 baud was hard-coded to 115200
(NCP-UART-HW @ 115200, the v2.x default). The v3.x in-kernel UART
bridge defaults to 460800 when `radio.conf` is missing, which left
v2 → v3 upgrades with the host bridge mismatched against a chip still
running at 115200. Z2M / ZHA could not reach the coordinator until
the user manually wrote `radio.conf` or reflashed the EFR32.

`flash_install_rtl8196e.sh` now detects the v2 → v3 case (saved
`FW_VERSION` major < 3 AND no `radio.conf` in the restored skeleton)
and pre-seeds the new `userdata.bin` with the known v2.x state:

```
FIRMWARE=ncp
FIRMWARE_BAUD=115200
BRIDGE_BAUD=115200
```

so the gateway boots into a working state out of the box. Caught on
the maintainer's prod gateway during a real v2.1.2 → v3.1.0 upgrade.

### `radio.conf` — chip-identity keys

Until now `radio.conf` told you the bridge baud and the daemon stack
to use, but not which app firmware was on the EFR32. A
`BRIDGE_BAUD=460800` could mean NCP@460800, RCP@460800, or OT-RCP in
bridge mode @460800 — only a `universal-silabs-flasher probe` could
disambiguate. `flash_efr32.sh` now also writes four informational
keys at every successful flash:

```
FIRMWARE=ncp             # ncp | rcp | otrcp | router  (CLI alias vocab)
FIRMWARE_VERSION=7.5.1   # only when GBL filename embeds it (NCP, Router)
FIRMWARE_BAUD=460800     # the chip's UART baud at flash time
BOOTLOADER_VERSION=2.4.2 # Gecko Bootloader Stage 2 — refreshed on every flash
```

There is no `FIRMWARE=bootloader` value: the Gecko Bootloader is a
runtime mode (chip stuck on empty/corrupt app slot), not an
application. A bootloader-only flash leaves `FIRMWARE`/`FIRMWARE_BAUD`
untouched (the existing app stays valid) but DOES update
`BOOTLOADER_VERSION` (since that's the one piece of state it changed).
For app flashes, USF transits the bootloader on its way to upload the
GBL and logs the bootloader version in passing — `flash_efr32.sh`
parses that line and persists it.

The `flash_install_rtl8196e.sh` v2 → v3 pre-seed (above) writes the
chip-identity keys describing the known v2.x state; `BOOTLOADER_VERSION`
is left absent until the next `flash_efr32.sh` invocation populates it.

### `etc/version` — component table refreshed

The component list had been frozen at the v2.x line since the v3.0
bump. Updated to reflect what v3.0 actually shipped:

| Component | was | now |
|---|---|---|
| crosstool-NG | 1.28.0.3_a3fef85 (gcc 8.5.0 + binutils 2.34) | 1.28.0 (gcc 15.2.0 + binutils 2.45.1) |
| musl | 1.2.5 | 1.2.6 |
| linux | 5.10.252 | 6.18.24 |
| busybox | 1.37 | 1.37.0 |
| dropbear | 2025.89 (incorrect) | 2025.88 |
| serialgateway | 3.0 | *(removed — replaced by in-kernel uart-bridge)* |
| otbr-agent | *(absent)* | thread-reference-20250612+ commit 111e78d0 |

### Documentation

- ~24 README files swept for v3.1 reality across two passes: first
  the new `flash_efr32.sh` CLI / baud-aware GBL filenames / `OTBR_BAUD`
  key / three OT-RCP deployment patterns (ZoH host, OTBR-in-docker,
  OTBR-on-gateway); second the new `radio.conf` chip-identity keys
  (`FIRMWARE`, `FIRMWARE_VERSION`, `FIRMWARE_BAUD`) — canonical full
  reference in [`34-Userdata/README.md`](34-Userdata/README.md#radioconf-keys-full-reference),
  per-firmware READMEs link to it instead of duplicating.
- `2-Zigbee-Radio-Silabs-EFR32/POST-MORTEM-bootloader-recovery.md`
  (new) — documents why a hardware `nRST` pulse can't enter the Gecko
  Bootloader on this board (PIN reset always boots the app slot;
  `BTL_GPIO_ACTIVATION` pin not wired; Tuya stock confirms no
  hardware recovery), and traces the empirical evidence behind the
  `nrst_pulse` design.
- `25-RCP` and `26-OT-RCP` Z2M `configuration.yaml` examples now
  externalise the device list (`devices: devices.yaml`) like 24-NCP
  does — keeps personal IEEE addresses out of git.

---

## [3.0.1] - 2026-04-25

Point release fixing `flash_efr32.sh` recovery paths reported on day 1
of v3.0.0 (GH discussion #86, @olivluca). No kernel/rootfs/bootloader
change.

### `flash_efr32.sh`

- **Self-arm bridge in `MODE=otbr`** (commit `ebd4199`): script now
  stops `S70otbr`, arms the bridge at `BRIDGE_BAUD=` (default 460800),
  keeps `flow_control=1` for the Spinel probe, drops it to 0 only when
  USF enters the Gecko Bootloader.
- **Targeted probe uses `RADIO_MODE` only**, not baud-AND-mode — Spinel
  is picked whenever `MODE=otbr`, at whatever `CURRENT_BAUD` was
  self-armed. Fixes 2.1.6 → 3.0 migration where `BRIDGE_BAUD=` is
  missing.
- **Scan-baud no longer skips `CURRENT_BAUD`** — handles the case where
  the targeted probe failed for protocol reasons (wrong `MODE`), not
  baud reasons. End-to-end validated on a deliberate RCP→OT-RCP flash
  with `MODE=otbr` mismatch.

### Documentation

- `34-Userdata/README.md` § 8 documents `/userdata/etc/radio.conf`
  (`MODE=`, `BRIDGE_BAUD=`, `BRIDGE_BIND=`).

---

## [3.0.0]

Platform-level overhaul: single kernel line, UART↔TCP bridge moves
in-kernel, **the rewritten `rtl8196e-eth` driver becomes the only ethernet
path and delivers +47 % TCP TX / +8.5 % TCP RX over the legacy Realtek SDK
driver** (see the perf table below), all native binaries rebuilt against
the Alpine-rebased Lexra cross-toolchain (GCC 15.2 / binutils 2.45 /
musl 1.2.6). See `../1-Build-Environment/CHANGELOG.md` for the toolchain
side.

### Kernel — Linux 5.10 dropped, 6.18.24 becomes mainstream

- 5.10 tree, patches, config and pre-built `kernel.img` removed. 6.18
  is the single supported line, vanilla 6.18.24 + `patches-6.18/` +
  `files-6.18/`.
- `build_kernel.sh`: `KERNEL_VERSION` (6.18.24) decoupled from
  `KERNEL_MAJOR_MINOR` (6.18) so future point-release bumps are a
  one-line edit; `-v`/`--version` flag dropped. Overlay re-synced every
  run via `rsync -a`, closing the "edited files-6.18/X but build was a
  no-op" footgun.
- Output `kernel.img` renamed to `kernel-6.18.img` across scripts,
  docs and `.gitignore` exception.
- `build_rtl8196e.sh kernel` passes `clean` so the tree is always built
  from scratch against the current toolchain (make alone is
  toolchain-unaware).

### Kernel — in-kernel UART↔TCP bridge replaces userspace `serialgateway`

New kernel driver `rtl8196e-uart-bridge` (built-in,
`CONFIG_RTL8196E_UART_BRIDGE=y`) shuttles bytes between UART1 (Zigbee
radio) and TCP:8888.
- Module parameters for live reconfig (`baud`, `port`, `bind_addr`,
  `flow_control`, `enable`), mirrored by `/userdata/etc/radio.conf`
  (`BRIDGE_BAUD=`, `BRIDGE_BIND=`).
- STATUS LED tied to the `uart-bridge-client` LED trigger (on when a
  TCP client is connected, off on disarm).
- Security + robustness audit pass (batch F1–F9): accept/disarm race,
  short-write retry, sendmsg-shutdown, enable-lock, license tag,
  disarm-path UAF, lock-scope, IRAM hot-path mutex cost review.
  Hardening recipes co-located with the source in `SECURITY.md`.
- Userspace `serialgateway` daemon and `S50serialgateway` removed;
  `S50uart_bridge` replaces them.

### Kernel — rtl8196e-eth becomes the sole ethernet driver (v2.3)

The from-scratch `rtl8196e-eth` replaces the legacy Realtek SDK driver
(`rtl819x`, ~7000 LOC, dropped with Linux 5.10) and is now the only
ethernet path shipped. Benchmarked on the gateway's ~380 MHz single-core
Lexra against the legacy SDK driver it replaces:

| Test | `rtl819x` (legacy SDK) | **`rtl8196e-eth` v2.3** | Delta |
|---|:---:|:---:|:---:|
| TCP RX (host → gw) | 86.6 Mbit/s | **94.0 Mbit/s** | **+8.5 %** |
| TCP TX (gw → host) | 48.1 Mbit/s | **70.6 Mbit/s** | **+47 %** |
| TCP parallel 4/8 streams | — | 95.1 / 95.9 Mbit/s | line-saturating |
| TCP 5-min stress | — | 94.1 Mbit/s, 11 retrans on 2.46 M (0.00 %) | — |
| UDP 10/50 Mbit RX | — | 0 % loss | — |

Code size: **~1 900 LOC total** across the rewritten driver, a **5.2×
reduction** from the legacy SDK blob, with modern Linux networking
idioms (NAPI, phylib, devicetree, regmap/syscon, DMA coherency handled
explicitly for the non-coherent L1 cache).

Hardening since v2.2 (2026-04-16):

- RX: double-reserve on the initial pool fixed, `NET_IP_ALIGN` reserved
  on pool init, `wback_inv` ordered before handover to `SWCORE_OWNED`.
- `led_mode` sysfs migrated to `attribute_group` (F8 refactor).
- NAPI deferral tuned for slow Lexra CPU.
- Audit findings F6 and F11+F13+F15 tested on hardware and **rejected**
  — each introduced measurable perf regressions; see
  `POST-MORTEM-driver-perf.md`.

### Kernel — UART baud ceiling raised from 230400 to 892857 (N+1 divisor fix)

Root cause was not userspace latency (as long believed) but an
off-by-one in the RTL8196E UART divisor: the hardware interprets
DLL/DLM as (N+1), not N. The fix is a `port->set_divisor` hook that
programs `quot - 1`. Max achievable is **892857 baud**
(200 MHz / (16 × 14), 0 % error); 921600 is unreachable on this silicon.

| Baud | Divisor | Wire baud | Error | Status |
|------|---------|-----------|-------|--------|
| 115200 | 108 | 115741 | +0.47% | Default |
| 460800 | 27 | 462963 | +0.47% | 8 h soak OK |
| 691200 | 18 | 694444 | +0.47% | Tested |
| 892857 | 14 | 892857 | 0.00% | 2 h soak OK |

Also under `8250_rtl819x`: batch-1 audit (IRQ errno, flow-ctrl MCR
alias, probe defer), `devm_platform_get_and_ioremap_resource`
migration, hardened probe observability.

### Kernel — driver metadata + GCC 15 hygiene

- `rtl8196e-eth` v2.2 → v2.3; first explicit version 1.0 for
  `8250_rtl819x` and `rtl8196e-uart-bridge`. `MODULE_VERSION` set,
  `<driver> v<version> (J. Nilo)` boot banner on probe, visible via
  `/sys/module/*/version`.
- `-Warray-compare` silenced in `plat_mem_setup`
  (`__dtb_start != __dtb_end` → `&__dtb_start[0] != &__dtb_end[0]`).

### Rootfs — BusyBox on Alpine edge patches, binaries rebuilt

- BusyBox 1.37.0 adopts Alpine-edge's downstream patch set
  (see `33-Rootfs/busybox/ALPINE-PORT.md`). Same version, same applet
  set, fewer project-local patches.
- `busybox` and `dropbearmulti` rebuilt against the Alpine-rebased
  Lexra toolchain.

### Userdata — bridge-aware, image-first flow

- `build_userdata.sh` packages the JFFS2 image from the
  already-committed skeleton binaries by default — a fresh clone no
  longer rebuilds nano (~2 min saved, no binary churn in git). Opt into
  full source rebuild with `--rebuild-components` (boothold + nano +
  otbr-agent + ot-ctl); `--components-only` used by
  `build_rtl8196e.sh`. `--jffs2-only` kept as alias for backward compat.
- Init-script echoes no longer interleave with the kernel log.
- LED fixes: residual glow on boot, STATUS LED off until a service
  lights it.
- `S50uart_bridge` + `S70otbr` aligned on the in-kernel bridge path;
  otbr-agent uses `spinel+hdlc+uart:///dev/ttyS1` — `CONFIG_IEEE802154`
  is explicitly NOT required (wpan0 is a TUN; 802.15.4 stack lives in
  userspace + the EFR32 RCP firmware).

### Bootloader

- `boot.bin` rebuilt with the new toolchain (22 946 → 22 362 B).
- README's "Modern toolchain" blurb made version-agnostic.

### Flash helpers

- `flash_install_rtl8196e.sh` prereq check: capture `tftp --help`
  output before grepping, so `set -o pipefail` + tftp-hpa's exit=64
  don't falsely flag tftp-hpa as missing.
- `flash_remote.sh kernel` no longer needs `-v` or `KERNEL_VERSION=…`;
  `flash_kernel.sh` targets `kernel-6.18.img` directly.
- `build_fullflash.sh` / `create_fullflash.sh` updated to the new image
  name.

### Documentation

- `POST-MORTEM-6.18.md`: 5.10 → 6.18 arch port (CP0, atomics, cache,
  clocksource), UART bridge hardening, N+1 divisor investigation.
- `POST-MORTEM-driver-perf.md`: rtl8196e-eth RX regression hunt.
- UART bridge source ships with `DESIGN.md`, `README.md`, `SECURITY.md`.
- `PORT-6.18-STATUS.md` removed — port done.
- Top-level + 3-Main-SoC + 32-Kernel + ot-br-posix READMEs/CLAUDE.md:
  single kernel line, `kernel-6.18.img` everywhere, legacy rtl819x
  reference driver note corrected (dropped with 5.10).

---

## [2.2.0] - 2026-04-10

### Kernel — upgrade to 5.10.252

- **Linux 5.10.246 → 5.10.252**: 6 stable point releases with minor fixes.
  All 47 custom patches regenerated cleanly against 5.10.252 (4 with trivial
  line offset changes). Binary size unchanged (+80 bytes on vmlinuz).
  No relevant CVE for RTL8196E hardware in this range.

### Kernel — RLX4181 patch set cleanup

Audit triggered by the experimental Linux 6.18 port (branch `kernel-6.18`)
revealed that 3 of our long-standing Lexra patches were either no-ops or
hitting the wrong file. The 5.10 patch set is reduced from 47 to 45 patches
with **zero functional change**, and the remaining patches are now
structurally aligned with what is needed in 6.18.

- **`arch-mips-include-asm-pgtable-32.h.patch` removed**: the wrapper
  `#if CPU_R3000 || CPU_TX39XX || CPU_RLX4181` it added was a no-op for our
  build (always-true with `CONFIG_CPU_RLX4181=y`, and the inner branches were
  identical to the vanilla `#if CONFIG_CPU_R3K_TLB` path). The patch had been
  carried since the original 3.10 SDK without ever being functionally needed.
- **`arch-mips-mm-tlbex.c.patch` removed**: it replaced the vanilla
  `if (cpu_has_3kex)` branch with a `switch (current_cpu_type())` that added
  an explicit `CPU_RLX4181` case. Because `cpu_has_3kex` is defined as
  `!cpu_has_4kex` and our `cpu-feature-overrides.h` already forces
  `cpu_has_4kex=0`, the vanilla path automatically routes RLX4181 to
  `build_r3000_tlb_refill_handler()`. Same end result, less code.
- **`arch-mips-kernel-cpu-probe.c.patch` removed and replaced by
  `arch-mips-kernel-cpu-r3k-probe.c.patch`**: with `select CPU_R3K_TLB`
  added to the `CPU_RLX4181` Kconfig block (see below), the build now
  compiles `arch/mips/kernel/cpu-r3k-probe.c` (151 lines, R3K-class CPUs)
  instead of the much larger `cpu-probe.c` (~1900 lines, all CPUs). The
  `case PRID_IMP_LX4380` initializing `cputype`, `tlbsize`, `options`, and
  calling `lexra_cache_init()` moved to `cpu-r3k-probe.c`.
- **`arch-mips-Kconfig.patch` updated**: `config CPU_RLX4181` now includes
  `select CPU_R3K_TLB`. This activates the R3K TLB code paths in mainline
  (TLB exception generator, swap entry format, dump_tlb), which is what we
  want for the Lexra and which removes the need for the two patches above.

**Result**: 45 patches (was 47), `kernel.img` shrinks by ~4 KiB
(1 060 864 → 1 056 768 bytes), all vendor drivers and userland behavior
identical, boot tested on hardware (login prompt, eth0, OTBR).

### Userdata — component upgrades

- **nano 8.3 → 9.0**: text editor update. Binary grows 542 KB → 549 KB (+7 KB)
  with ncurses 6.6 (was 6.5). No functional impact — nano is a convenience tool
  for on-device config editing.
- **ncurses 6.5 → 6.6**: robustness fixes (null pointer checks, bounds checking).
  No security CVEs.
- **`build_otbr.sh`**: pinned default to commit `111e78d0` (thread-reference-20250612
  +327 commits, 2026-04-09) for reproducible builds. Previously defaulted to
  `main` branch. Script now installs binaries to skeleton automatically,
  restores working directory on exit, and uses `--single-branch` for faster clone.

### Build — BusyBox build script improvements

- **`build_busybox.sh`**: rewrote argument parsing with proper `case` statement.
  Added `clean` (remove build tree) and `--help` options. Version argument now
  validated with regex instead of being treated as default fallback.

### Security — BusyBox hardening

- **Compiler hardening**: added `-D_FORTIFY_SOURCE=2`, `-fstack-protector-strong`,
  and full RELRO (`-Wl,-z,relro,-z,now`) to BusyBox build. Binary grows +20 KB
  (714 KB -> 734 KB).
- **CVE-2023-39810**: enabled `FEATURE_PATH_TRAVERSAL_PROTECTION` to prevent
  archive extraction outside the target directory (cpio, ar, rpm).
- **CVE-2025-46394**: sanitize terminal escape sequences in `tar -t` output to
  prevent filename concealment attacks.
- **CVE-2026-26157 / CVE-2026-26158**: fix tar hardlink path traversal and
  incomplete prefix sanitization. Hardlink targets are now stripped like regular
  filenames (matching GNU tar 1.34 behavior).
- **CONFIG_LFS=y**: enable Large File Support to match musl's 64-bit `off_t`,
  fixing 7 format-string warnings and potential truncation of file sizes > 2 GB.

---

## [2.1.6] - 2026-04-10

### Fixes
- **DHCP resilience**: udhcpc now uses `-b` instead of `-n`, so if the DHCP
  server is unavailable at boot the client keeps retrying in the background
  and configures the gateway automatically once a lease is obtained. Previously
  the gateway stayed without an IP until rebooted. (S10network — [#82])
- **`/var/hosts` updated on late DHCP lease**: `udhcpc.script` now regenerates
  `/var/hosts` in the `bound` handler, so the hostname→IP mapping is corrected
  when a lease arrives after initial failure. (udhcpc.script — [#82])
- **Hostname fallback uses `127.0.1.1`**: S15hostname now falls back to
  `127.0.1.1` (Debian convention) instead of `192.168.1.254` when no IP is
  assigned at boot. (S15hostname — [#82])

[#82]: https://github.com/jnilo1/hacking-lidl-silvercrest-gateway/discussions/82

---

## [2.1.5] - 2026-04-04

### OTBR REST API — PascalCase kept

The PascalCase REST API patch is **kept**. `python-otbr-api` 2.9.0
(HA 2026.4) accepts camelCase in GET responses but still sends PascalCase
in PUT requests — upstream `otbr-agent` (camelCase) rejects them.
PascalCase `otbr-agent` works with all HA versions.
See [python-otbr-api#238](https://github.com/home-assistant-libs/python-otbr-api/issues/238).

### New features
- **Dropbear SCP & SSH client**: `scp` and `dbclient` (SSH client) added to
  the dropbear multi-call binary. Enables `scp` file transfers to/from the
  gateway and outbound SSH connections via `dbclient`. Progress bar included
  (`SCPPROGRESS`). Binary size: 473 KB → 555 KB (+82 KB).

### Fixes
- **rootfs.bin always rebuilt**: `build_fullflash.sh` and `flash_rootfs.sh`
  now always rebuild `rootfs.bin` from the skeleton, like `userdata.bin`.
  Prevents stale images from being flashed after an upgrade.
- **version/motd bumped** to v2.1.5.

---

## [2.1.4] - 2026-04-02

### New features
- **LED off mode**: `MODE=off` in `leds.conf` completely disables both LEDs
  (LAN + STATUS). The LAN LED is turned off via the `DIRECTLCR` register
  (0xBB804314) which controls the switch ASIC LED output scale — setting it
  to 0 fully disables the LED output with no residual glow.
- **`led_mode` sysfs**: now supports `bright`, `dim`, and `off`.
  `serialgateway` v2.2 and `S70otbr` respect `off` mode (STATUS LED stays
  at 0 even when the radio is connected).

### Changes
- **rtl8196e-eth v2.2**: added `DIRECTLCR` register support for true LED off.
- **serialgateway v2.2**: respects `led_mode=off` (keeps STATUS LED at 0).

---

## [2.1.3] - 2026-04-01

### New features
- **LED dual brightness mode**: new `led_mode` sysfs attribute
  (`/sys/class/net/eth0/led_mode`) allows switching between `bright`
  (default) and `dim` modes. In `dim` mode, both LEDs run at reduced
  intensity for nighttime use.
- **`leds-gpio-pwm` driver**: new GPIO LED driver with software PWM
  brightness control (0-255) via kernel timer_list (250 Hz). Replaces
  `gpio-leds` for the STATUS LED. At brightness 0 or 255 the timer is
  stopped (zero CPU overhead). Designed for SoCs without hardware PWM.
- **`S11leds` init script**: persistent LED mode via `/userdata/etc/leds.conf`.
  Set `MODE=dim` or `MODE=bright` (default). Applied at boot right after
  network init, before serialgateway/otbr-agent start.
- **`flash_efr32.sh` PWM guard**: disables status LED PWM before Xmodem
  transfer to avoid bus contention between GPIO writes and UART on the
  shared LX bus. Brightness is restored on reboot via S11leds.
- **Config preservation**: `leds.conf` added to `SAVE_FILES` in
  `flash_install_rtl8196e.sh` and `flash_remote.sh` — LED preference
  survives firmware upgrades.

### Bug fixes
- **LAN LED dim after Linux 5.10 port**: the LAN LED is hardwired to
  the switch ASIC LED_PORT0 output, not to the GPIO pad. GPIO control
  had no physical effect. Fixed: Ethernet driver now configures LEDCREG
  in LEDMODE_DIRECT after FULL_RST, restoring full-brightness
  link/activity indication as in the stock firmware.
- **STATUS LED invisible with serialgateway**: `_set_status_led()` wrote
  `"1\n"` to brightness. With `gpio-leds` (max=1) this was full-on, but
  with `leds-gpio-pwm` (max=255) it was 0.4% duty cycle — invisible.
  Fixed: serialgateway v2.1 reads `led_mode` and writes 255 (bright) or
  60 (dim). Same fix applied to S70otbr LED daemon.

### Technical notes
- **Hardware discovery**: PIN_MUX_SEL_2 bits [1:0] = 11 (GPIO mode)
  has no effect on the LAN LED — the PCB routes it directly to the
  switch ASIC LED output, bypassing the pin mux. Confirmed by register
  analysis: GPIO DATA register toggles correctly but LED does not
  respond; LEDCREG changes immediately affect the LED.
- Ethernet driver bumped to v2.1, serialgateway bumped to v2.1.

---

## [2.1.2] - 2026-03-23

### Bug fixes
- **Skeleton pollution / cross-contamination after flash**: `flash_remote.sh`,
  `flash_install_rtl8196e.sh`, `build_fullflash.sh`, and `create_fullflash.sh`
  injected gateway config into the skeleton directory, leaving residual files
  (dropbear keys, radio.conf, thread/) between runs. Flashing one device in
  OTBR mode then another in Zigbee mode leaked radio.conf. Refactored: all
  scripts now work on a temporary copy of the skeleton via `SKELETON_DIR`;
  the original is never modified. Credit: olivluca (#73).
- **S70otbr redundant flash writes**: sync daemon wrote to flash on first poll
  (seeded with empty `last_dataset`) and unconditionally on shutdown. Fixed:
  `last_dataset` seeded from REST API before entering the loop; trap and stop
  no longer copy — the daemon syncs on dataset change only. Frame counters
  are ephemeral (OpenThread recovers by jumping ahead). Credit: olivluca (#66).
- **Serial console backspace**: replaced `askfirst` + `login` with
  `getty -L 38400 ttyS0 vt100` in rootfs inittab — backspace now works
  at the login prompt.

---

## [2.1.1] - 2026-03-22

### Bug fixes
- **`boothold` unreliable via SSH**: BusyBox `devmem` writes through KSEG0
  (cached, write-back) — the HOLD flag could stay in L1 D-cache and be lost
  on watchdog reset. Replaced with a C binary (`boothold`) that uses
  `pwrite()` + `O_SYNC` on `/dev/mem` to force the write to DRAM.
- **JFFS2 decompression errors on fresh userdata flash**: `mkfs.jffs2 -X zlib`
  enables zlib but does not disable rtime (enabled by default). Added
  `-x rtime -x lzo` to force zlib-only compression — matches the kernel
  config (`CONFIG_JFFS2_ZLIB=y`, no rtime/lzo).
- **Skeleton pollution after flash**: `flash_remote.sh` and
  `flash_install_rtl8196e.sh` injected gateway config (passwd, eth0.conf,
  etc.) into the skeleton without cleanup. Added `rsync --delete` restore
  via EXIT trap — skeleton is always restored to its original state.

### Improvements
- **Bootloader V2.5**: auto-reboot after flashing all partition types
  (rootfs, bootloader — was only kernel).
- **`flash_remote.sh`**: two-phase bootloader detection (wait SSH down,
  then ARP) prevents false positives during shutdown. ControlMaster socket
  closed after boothold. Skip redundant boot mode check via
  `BOOTLOADER_CONFIRMED`. Quiet build mode via `BUILD_QUIET`.
- **`flash_install_rtl8196e.sh`**: firmware version displayed early (v2.1.0
  format). EFR32 compatible firmware list shown at end (depends on radio mode).
  Same two-phase detection and ControlMaster fix.
- **`build_rootfs.sh`**: quiet mode (`-q`) for auto-build from flash scripts.
- **S70otbr**: sync daemon uses REST API instead of `ot-ctl` (eliminates
  broken pipe warnings). Fast poll (5s) until Thread is up, then 30s.

---

## [2.1.0] - 2026-03-21

### Bug fixes
- **`boothold` fails on running system**: the kernel's page allocator actively
  uses the page at physical `0x003FFFFC` (KSEG0 cached), overwriting the HOLD
  magic written by `devmem` (KSEG1 uncached) within milliseconds. Fixed by
  declaring the page as `reserved-memory` with `no-map` in the device tree —
  the kernel never allocates it, eliminating the cache coherency conflict.
  Address kept at `0x003FFFFC` (top of DRAM is unsafe: btcode stack).
  Bootloader V2.4: BOOTHOLD_RAM uses KSEG1 (`0xA03FFFFC`) so the clear
  bypasses the write-back cache and reaches DRAM — prevents false boot-hold
  after power cycle.
- **Thread dataset lost on reboot**: S70otbr sync loop only ran 60s after boot —
  networks created later were never persisted. Replaced with a persistent daemon
  that polls `ot-ctl dataset active -x` every 30s and syncs to flash only when
  the dataset changes. Traps SIGTERM for a final sync on shutdown.
- **No shutdown hooks**: added `::shutdown:` entry to rootfs inittab, calling a
  new `rcK` script that stops all services in reverse order on reboot — ensures
  clean `stop` for otbr-agent and all other init scripts.

### New features
- **OTBR status LED**: S70otbr sync daemon polls `ot-ctl state` every 30s —
  LED on when Thread network is formed (child/router/leader), off otherwise.
  Replaces netdev trigger on wpan0 which did not reflect Thread network state.

### Improvements
- **Auto-flash on first flash**: `flash_install_rtl8196e.sh` now attempts auto-flash
  when `BOOTLOADER_TYPE=v2` even without SSH (first flash, `FW_VERSION` unknown).
  Worst case (old V2.3 without auto-flash): 3-min timeout then fallback to manual FLW.
- **EFR32 flash prompt**: at the end of `flash_install_rtl8196e.sh`, interactive mode
  now offers to launch `flash_efr32.sh` to flash the Zigbee/Thread radio firmware.
- **`userdata.bin` and `rootfs.bin` removed from git**: both binaries are now
  rebuilt on the fly by the build/flash scripts (skeletons and build tools are
  in git). `build_fullflash.sh` and `create_fullflash.sh` auto-rebuild
  `rootfs.bin` if missing. Skeleton backup/restore traps simplified.
- **`create_fullflash.sh` aligned**: now prompts for network/radio configuration
  and rebuilds userdata via `build_userdata.sh --jffs2-only` before assembly,
  matching `build_fullflash.sh` behavior.
- **Dropbear 2025.89**: updated from 2025.88.
- **EFR32 build scripts**: all firmware build scripts (bootloader, NCP, RCP,
  OT-RCP, Router) now consistently output exactly two files in `firmware/`:
  `.gbl` (for UART/Xmodem flashing) and `.s37` (for J-Link). Removed `.hex`,
  `.bin`, and intermediate `.s37` variants.

---

## [2.0.1] - 2026-03-17

### Bug fixes
- **DHCP wipes IPv6**: `udhcpc.script` uses `ip -4 addr flush` to preserve IPv6 link-local
- **Thread dataset not persisted**: S70otbr syncs to flash once Thread is up (was daily)
- **`tr: not found` in S70otbr**: replaced with shell parameter expansion
- **`/root` permissions**: fixed to 750 in rootfs skeleton (read-only squashfs)
- **SSH probe timeout**: `SSH_TIMEOUT` env var (default 2s) for slow networks
- **Auto-flash timeout**: 10s → 180s (flash write takes ~2 min)
- **`resolv.conf` overwritten by S15hostname**: removed, handled by S10network
- **Kernel .config warnings**: removed duplicate config entries
- **motd/version sync**: motd now shows the same version and date as `/etc/version`

### Improvements
- **`flash_install_rtl8196e.sh` refactored**: two distinct modes of operation:
  - **First flash** (no argument): gateway must be in bootloader mode, prompts
    for network/radio config, TFTP probe confirms bootloader presence
  - **Upgrade** (`LINUX_IP`): connects via SSH, saves user config (eth0.conf,
    mac_address, radio.conf, passwd, TZ, hostname, dropbear keys, SSH keys,
    Thread credentials), boothold + reboot, then flash. Prompts skipped
  - **`-y` / `--yes` flag**: non-interactive mode for fully automated upgrades
    (firmware >= v2.0.0 with auto-flash support)
- **Firmware detection via `devmem`**: distinguishes custom firmware from Tuya
  (even if Tuya SSH port was changed to 22) by checking `devmem` presence
- **TFTP bootloader probe**: ARP + TFTP PUT distinguishes bootloader from Linux
  running on `BOOT_IP` — prevents false positive detection
- **Auto-flash skip for firmware < v2.0.0**: reads `/etc/version` before boothold
  to skip the 3-minute nc listener on older bootloaders that lack UDP notification
- **Quiet build mode** (`-q`): `build_fullflash.sh` and `build_userdata.sh`
  suppress non-essential output (banners, cvimg details, image sizes) when
  called from `flash_install_rtl8196e.sh`
- **Removed `--boot-ip` parameter**: `BOOT_IP` is env-var only (always 192.168.1.6)
- **Config preservation on reflash**: prompts skipped when config is preserved
- **DNS/domain in eth0.conf**: S10network reads optional `DNS` and `DOMAIN` fields
- **SSH ControlMaster**: single password prompt instead of two
- **SSH auth check**: fail fast on bad password
- **Clean git checkout after flash**: `build_fullflash.sh` and `flash_userdata.sh`
  restore skeleton after build so `git pull` is not blocked
- **`flash_remote.sh` refactored** (renamed from `remote_flash.sh`):
  - `LINUX_IP` is now required (no more hardcoded default)
  - Dual-port SSH probe: port 2333 → Tuya error with redirect to `flash_install_rtl8196e.sh`
  - `devmem` check after SSH: absent = Tuya/v1.0 → same error
  - Boothold via `devmem` directly (no dependency on `boothold` binary)
  - Bootloader wait confirms SSH is down before declaring ready
  - Removed bootloader-already-up path (use individual flash scripts directly)
  - Added `-y`/`--yes` flag, `SSH_TIMEOUT` env var, `StrictHostKeyChecking=no`
  - Renamed to `flash_remote.sh` to match `flash_*.sh` naming convention

---

## [2.0.0] - 2026-03-13

### 30-Backup-Restore
- **`backup_gateway.sh`** (new, at repository root): unified backup script that auto-detects
  gateway state (custom Linux SSH:22, Tuya Linux SSH:2333, or bootloader) and chooses the
  best backup method. Outputs `fullflash.bin` + individual partition files + `backup.log`
  to `backups/YYYYMMDD-HHMM/`. Replaces `backup_mtd_via_ssh.sh` and `backup_rtl8196e.sh`.
- **`restore_gateway.sh`** (new, at repository root): restore a `fullflash.bin` backup to the
  gateway. Verifies 16 MiB size, detects bootloader type (V2 auto-flash vs V1.2/Tuya guided
  LOADADDR + FLW on serial console). Symmetric counterpart to `backup_gateway.sh`.
- Removed `backup_mtd_via_ssh.sh` (superseded by unified script SSH path)
- Removed `backup_rtl8196e.sh` (superseded by unified script bootloader path)

### 31-Bootloader
- **UDP notification after flash** (port 9999): bootloader sends "OK" or "FAIL" to the
  TFTP client after `checkAutoFlashing()` completes, enabling fully automated remote
  flashing without serial console confirmation
- **Raw fullflash auto-flash**: V2.3+ bootloader detects raw 16 MiB images by verifying
  magic bytes at partition offsets (bootloader at 0x0, cs6c at 0x20000, hsqs at 0x200000)
  and writes the entire image to flash — enables fully automatic install via TFTP
- Notification sent before `autoreboot()` so it arrives even for kernel images

### 32-Kernel
- **GPIO 11 / status LED fix**: Ethernet driver no longer clears PIN_MUX_SEL2 bits [4:3]
  that control GPIO 11 (Port B3), fixing the gpio-leds regression introduced in the
  procfs-to-gpio-leds migration
- **Ethernet driver v2.0** — optimized for OTBR/NCP-UART workloads:
  - TX IRQ mitigation: TX_ALL_DONE interrupt disabled, descriptors reclaimed in start_xmit and NAPI poll (eliminates 1 IRQ per TX packet)
  - Ring buffers reduced from 600/500 to 128/128 — saves ~780 KB RAM (3.8% of free memory)
  - TX stop/wake thresholds scaled proportionally (16→4, 64→16)
  - UDP TX throughput +28% vs conditional reclaim approach
  - OTBR use case validated: CoAP/mDNS traffic has 88× headroom vs UART bottleneck
  - 29 hot-path functions placed in 16 KB on-chip I-MEM (SRAM) via `__iram` section
- Syscon/regmap: PIN_MUX_SEL/SEL2 access coordinated via shared regmap (GPIO, UART, Ethernet)
- Interrupt controller: chained_irq_enter/exit, GIMR enabled after handler install, raw_spinlock on GIMR
- Ethernet: IRQ_NONE on spurious, tx_dropped accounting, napi_enable after HW init
- CONFIG_MIPS_L1_CACHE_SHIFT corrected from 5 (32 B) to 4 (16 B) to match actual RLX4181 cache line size
- Timer: bus clock from DT (busclk fixed-clock), max_delta_ticks capped to 28-bit, clk_prepare_enable
- SPI: unaligned access safety (get/put_unaligned), devm_clk_get_optional, double-disable prevention
- UART1: devm_clk_get_optional, dev_warn/err/dbg, PIN_MUX via syscon
- GPIO: spinlock on get_direction, pinmux via syscon/regmap
- LED: replaced custom /proc/led1 driver with standard gpio-leds DT binding (/sys/class/leds/status/)
- DT: syscon on system-controller, busclk fixed-clock, gpio-leds node
- Kconfig: CONFIG_MFD_SYSCON=y, CONFIG_LEDS_GPIO=y, CONFIG_LEDS_TRIGGERS=y
- IPv6 stack integrated into base config (+135 KB kernel, zero overhead when unused)
- CONFIG_FILE_LOCKING=y (required by otbr-agent flock())
- CONFIG_TUN=y (required for wpan0 Thread interface)
- Kconfig size reduction (-298 KB text, -106 KB compressed = -9.2%):
  - Stripped unused subsystems: MTD_CFI/JEDECPROBE, PHYLIB/MDIO, MSDOS/EFI_PARTITION,
    NLS, IKCONFIG, INET_DIAG, IPV6_SIT/TUNNEL, MIPS_FP_SUPPORT, IEEE802154, SHMEM
  - CRC32_SLICEBY8 → SLICEBY4 (-4 KB tables, better D-cache fit)
  - Disabled SYN_COOKIES (unnecessary behind NAT), NETFILTER (incompatible with
    RTL8196E Ethernet driver)
- Kernel size: 1.0 MB → 1.03 MB (net, after IPv6 addition and kconfig stripping)

### 33-Rootfs
- BusyBox: IPv6 support (ping6, traceroute6, ip route)
- Migrated all scripts from ifconfig/route to ip commands
- Removed ifconfig, route, microcom applets (replaced by ip, no longer needed)

### 34-Userdata
- serialgateway: LED control migrated from /proc/led1 to /sys/class/leds/status/brightness
- otbr-agent and ot-ctl binaries in /userdata/usr/bin/
- S70otbr init script: IPv6 forwarding, UART 115200, REST on :8081
- Build script: `ot-br-posix/build_otbr.sh` for cross-compilation

### Flash scripts
- **`flash_install_rtl8196e.sh`** (new): unified firmware installation script —
  builds `fullflash.bin`, auto-detects gateway state (custom Linux → boothold,
  V2 bootloader → auto-flash, old bootloader → guided FLW), handles Tuya and
  custom firmware. Replaces `flash_rtl8196e.sh` as the recommended install method.
- **`build_fullflash.sh`** (new): assembles bootloader + kernel + rootfs + userdata
  into a verified 16 MiB flash image with correct header stripping per partition
- **`flash_remote.sh`** (new): fully automated remote flash via SSH — connects to the
  gateway, sends `boothold`, waits for bootloader, runs the appropriate flash script.
  Supports all 4 components: `./flash_remote.sh <bootloader|kernel|rootfs|userdata>`
- All individual flash scripts (`flash_bootloader.sh`, `flash_kernel.sh`, `flash_rootfs.sh`,
  `flash_userdata.sh`) now wait for bootloader UDP notification ("OK"/"FAIL") instead of
  returning immediately after TFTP upload
- All build scripts (`build_kernel.sh`, `build_rootfs.sh`, `build_userdata.sh`) check
  for gcc before attempting to compile cvimg
- Non-interactive mode via environment variables: `CONFIRM=y` skips "Proceed?" prompt,
  `NET_MODE=static|dhcp` and `RADIO_MODE=zigbee|thread` skip userdata config prompts.
- Removed `flash_rtl8196e.sh` (superseded by `flash_install_rtl8196e.sh` and `flash_remote.sh`)

### Thread Border Router — OTBR on-device
- OpenThread Border Router runs natively on the RTL8196E gateway (no Docker, no PC)
- otbr-agent 0.3.0 (Thread 1.4) cross-compiled for MIPS Lexra, static binary (4.3 MB)
- ot-ctl CLI for Thread network management (57 KB)
- REST API on port 8081 — compatible with Home Assistant OTBR integration
- mDNS/DNS-SD (OpenThread built-in), SRP Advertising Proxy, Border Routing
- Tested: IKEA TIMMERFLOTTE commissioned via HA Companion App, 20 MB RAM free

### Unified Zigbee/Thread distribution
- Single kernel, rootfs, and userdata image for both Zigbee and Thread modes
- `flash_userdata.sh`: new "Radio mode" prompt selects Zigbee or Thread at flash time
- `/userdata/etc/radio.conf` (MODE=otbr) gates init scripts at boot
- S60serialgateway: skips when radio mode is OTBR
- S70otbr: starts only when radio mode is OTBR

### Build fixes (ot-br-posix)
- `-Wno-error=maybe-uninitialized` for GCC 8.5 false positive
- Socket path redirected to /tmp (rootfs is read-only, no /run)
- `--vendor-name` / `--model-name` required by latest ot-br-posix

---

## [1.2.0] - 2026-03-02

### 30-Backup-Restore
- Added custom firmware partition map (4 partitions) alongside the original Lidl/Tuya map
- Added FLR/FLW quick reference table for the custom layout (mtd3 = 12 MiB JFFS2 userdata)

### 32-Kernel
- Updated README: build process now describes zboot (in-tree `arch/mips/boot/compressed/`), corrected image size (~1 MB)
- PIN_MUX_SEL fix: UART1 TX/RX pins correctly muxed in both `rtl8196e-eth` and legacy `rtl819x` drivers — fixes EFR32 communication after Ethernet init
- PIN_MUX_SEL2: nRST clearing preserved for EFR32 reset control

### 33-Rootfs
- Fixed Dropbear pubkey auth by correcting `/root` permissions at startup

### 34-Userdata
- NTP: retry connectivity check in `S20time` for reliable time sync
- Dropbear: unified stop emoji, fixed restart logic
- `flash_userdata.sh`: network configuration (static IP or DHCP) asked at flash time

### Flash scripts (root level)
- New `flash_rtl8196e.sh` at repository root — flashes all RTL8196E partitions in one command
- New `flash_efr32.sh` at repository root — OTA flash of EFR32 via SSH + universal-silabs-flasher
  - Firmware selection menu (bootloader, NCP, RCP, OT-RCP, Z3-Router)
  - SSH retry (3 attempts, ConnectTimeout=10) for unreliable networks
  - Progress bar visible for normal firmware flash
  - Bootloader flash chains application firmware automatically
- Prerequisite checks: tftp-hpa (flash_rtl8196e.sh), python3 + venv (flash_efr32.sh)
- Deleted unused `clean_part1.sh`, `clean_part2.sh`, `clean_part3.sh`

### Documentation
- All EFR32 firmware READMEs (23-Bootloader, 24-NCP, 25-RCP, 26-OT-RCP, 27-Router) updated to reference `flash_efr32.sh`
- Root README rewritten: user-oriented intro, single quick start flow, firmware selection table
- `35-Migration` README rewritten to describe the two root-level flash scripts
- Fixed Z2M port syntax to `tcp://` across all READMEs
- `3-Main-SoC-Realtek-RTL8196E/README.md`: clarified flash script paths (root vs subdirectory)

---

## [1.1.0] - 2026-02-24

### 30-Backup-Restore (new)
- `backup_mtd_via_ssh.sh` / `restore_mtd_via_ssh.sh`: per-partition SSH backup and restore, original firmware only (5 partitions, port 2333); 4-partition layout rejected with FLR/FLW guidance
- README: method comparison table (SSH / FLR/FLW / SPI programmer), full FLR/FLW backup and restore procedure

### 31-Bootloader
- Fully rewritten from [Sourceforge V3.4.7.3 SDK](https://sourceforge.net/projects/rtl819x/files/) source code and adapted to the new lexra toolchain
- V2.3: ICMP ping support — `ping 192.168.1.6` works from download mode
- Boothold mechanism: reboot-to-bootloader from Linux via DRAM magic flag
  (`devmem 0x003FFFFC 32 0x484F4C44 && reboot`), RAM flag at 0x803FFFFC
- Download progress shown as percentage instead of endless `.` / `#`
- `flash_bootloader.sh`: ARP-based boot mode detection (rootless, no arping),
  `set -euo pipefail`, helper functions, background UDP ARP trigger with proper
  cleanup, `ip neigh del` flush before probing, `timeout 15` on tftp,
  `TRIES`/`PORT`/`SLEEP_BETWEEN` env-var overrides, clean error reporting

### 32-Kernel
- **New driver**: `rtl8196e-eth` — clean-room Ethernet driver (1 855 pure LOC
  vs 9 664 for legacy rtl819x, 5.2× reduction)
  - TCP RX: **91.2 Mbps** (+6.4% vs legacy 85.7 Mbps)
  - TCP TX: **46.9 Mbps** (+8.1% vs legacy 43.4 Mbps)
  - TCP stress 300s: 92.0 Mbps, 0 errors, 0 retransmissions (SoC side)
  - Architecture: NAPI, zero-copy RX (`napi_alloc_skb`), no spinlock, no BQL,
    devicetree-based configuration
- **New build system**: unified `build_kernel.sh` supporting both drivers
  (`./build_kernel.sh` for rtl8196e-eth, `./build_kernel.sh legacy` for rtl819x)
- **New decompressor**: zboot (`arch/mips/boot/compressed/`) replaces the
  external lzma-loader from the Realtek SDK — no external tool dependency
- Legacy `rtl819x` driver from initial release 1.0.0 remains available as a reference build

### 34-Userdata
- `/etc/version` updated to include firmware version
- `boothold` script installed in `usr/bin/`: one-command reboot-to-bootloader
  from Linux SSH, wraps `devmem 0x003FFFFC 32 0x484F4C44 && reboot` with a root check
- `flash_userdata.sh`: asks for network configuration (static IP or DHCP) before
  flashing; generates `skeleton/etc/eth0.conf` temporarily, rebuilds JFFS2, then
  flashes — `eth0.conf` is removed after flash (trap EXIT), skeleton stays clean

### Flash scripts
- Fixed invalid `-timeout` tftp flag in all scripts — replaced by `timeout N tftp` wrapper
- `flash_rtl8196e.sh`: fixed `set -e` silent exit, improved UX messages
- `flash_rtl8196e.sh`: optional FLR full flash backup before flashing, saved as `YYMMJJ-HH.MM-Gw-Backup.bin`
- `flash_rtl8196e.sh`: asks for network configuration (static IP or DHCP) before
  flashing, rebuilds userdata with the chosen config

---

## [1.0.0] - 2025-12-18

Initial release.

### 31-Bootloader
- Lidl/Tuya/Realtek original bootloader

### 32-Kernel
- Linux 5.10.246, legacy `rtl819x` Ethernet driver developed from original 2.6 code, lzma-loader decompressor

### 33-Rootfs
- musl 1.2.5, busybox 1.37, dropbear 2025.88

### 34-Userdata
- Init scripts: S20time (NTP), S30dropbear (SSH), hostname, eth0 config
