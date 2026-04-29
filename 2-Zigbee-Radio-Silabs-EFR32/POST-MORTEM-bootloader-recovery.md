# Post-mortem — EFR32 bootloader recovery without a cooperative app

**Status:** investigation closed, no shippable solution.
**Date:** 2026-04-26.
**Scope:** v3.1 plan to recover an unresponsive EFR32 (corrupted firmware,
J-Link halt, unknown image, etc.) without a physical power cycle and without
the running application's cooperation. Conclusion: not feasible on this
hardware.

## TL;DR

The Gecko Bootloader v2.4.2 shipped on the EFR32MG1B232F256GM48 inside the
TYZS4 module **only enters its UART menu** after one of:

- a software reset (`SYSREQ`) accompanied by a magic value pre-written to RAM
  by a cooperating application, or
- a `BTL_GPIO_ACTIVATION` pin held to the active level — **not enabled** in
  the bootloader build, **not wired** through the module to the SoC, and
- a missing/corrupt application slot (`pc == 0xFFFFFFFF` sanity-check fail).

A hardware `nRST` pin reset — the only inter-chip control line we can drive
from the RTL8196E — is treated as a normal power-on event and unconditionally
jumps to the application. There is no UART-character window after `nRST` that
can be exploited to enter the menu, because the bootloader's communication
loop does not run unless `enterBootloader()` returns true.

We confirmed this by reverse-engineering Tuya's stock firmware: their NCP
update path (`tyZ3Gw`/`debugtool -n`) relies entirely on
`ezspLaunchStandaloneBootloader` over EZSP — the same cooperative path our
v3.0.1 `flash_efr32.sh` already uses. Tuya, with full schematics and source
access, did not engineer any hardware recovery either.

**Outcome:** v3.1's pulse-based recovery scope is dropped. v3.0.1 remains the
production solution. The "EFR32 firmware corrupted while running" case
remains a power-cycle scenario, now documented as a known limitation rather
than an open bug.

Two untested-but-plausible improvements live on this hardware. They are
listed in increasing scope:

- **Alternative A** — recover the EFR32 by asserting its `nRST` line
  from the SoC. Phase-2 testing on 2026-04-26 found that **a plain
  `ssh root@gw reboot` already does this** — the EFR32 reports a PIN
  reset to `otbr-agent` on next boot (the SoC's chip-reset default for
  `PIN_MUX_SEL_2` happens to assert `nRST`). Remaining work is a
  non-disruptive `nrst_pulse` sysfs knob + a button handler on the
  existing front-panel key (RTL8196E GPIO 9, active LOW, originally
  Tuya's pairing/factory-reset key — confirmed empirically in
  Phase 1). No new wire, no bootloader change, no kernel reboot
  notifier needed. Closes the most common "stuck app" cases (crashed
  app, J-Link halt, corrupted-app `pc == 0xFFFFFFFF`) but does *not*
  help when the running firmware itself is unknown/uncooperative.
- **Alternative B** — rebuild the bootloader with `BTL_GPIO_ACTIVATION`
  reading `PA5` (the EFR32's CTS input, already driven by the SoC's
  RTS), plus a sysfs RTS knob in the kernel bridge. Heavier scope, one-
  time bootloader migration required, but covers the residual case
  Alternative A misses.

Neither is implemented; see the corresponding sections below.

## What we were trying to solve

After v3.0.1 (released 2026-04-25), the only paths into the Gecko Bootloader
on this gateway are:

1. **Cooperative**: USF probes the running app at its baud, sends an
   application-protocol "enter bootloader" command (EZSP
   `launchStandaloneBootloader`, CPC `system_reset_to_bootloader`, Spinel
   vendor frame). The app writes a magic value to RAM and issues
   `NVIC_SystemReset()`. Bootloader sees `RSTCAUSE_SYSREQ` + magic →
   enters menu.
2. **Power cycle**: physically disconnect/reconnect power. The EFR32 boots
   with no app context; bootloader still jumps to app, but a fresh chip
   state lets cooperative path #1 succeed reliably.

Path #1 fails when the running app is unresponsive — corrupted by a
half-flash, halted from a J-Link debug session, or an unknown image flashed
manually. In those cases v3.0.1 instructs the user to power-cycle the
gateway. v3.1 was an attempt to remove that physical-access requirement by
resetting the EFR32 from userland on the SoC.

## Initial design: userland nRST pulse via `devmem`

The EFR32's `nRST` pin is wired to a SoC pin whose mux function lives in
`PIN_MUX_SEL_2` at physical `0x18000044`. The kernel `rtl8196e-eth` driver
clears the four "non-LED" fields at probe to release `nRST`
(`32-Kernel/files-6.18/drivers/net/ethernet/rtl8196e-eth/rtl8196e_hw.c:298-326`).
Setting those bits drives `nRST` LOW; clearing releases it.

Empirically validated mask (read live from a running gateway):

| Phase | `PIN_MUX_SEL_2` | Effect |
|---|---|---|
| Kernel idle | `0x0000001A` | LED bits only; `nRST` released |
| Pulse asserted | `0x0000249A` | LED bits + bits {7,10,13} set; `nRST` LOW |
| Pulse released | `0x0000001A` | back to idle |

The pulse itself works exactly as designed. From SSH:

```bash
REG=0x18000044
BEFORE=$(devmem $REG 32)              # 0x1A
devmem $REG 32 $((BEFORE | 0x2480))   # assert: 0x249A
sleep 0.1                             # reset hold
devmem $REG 32 $BEFORE                # release
sleep 0.05                            # boot ROM
```

Validation gates passed:

- ✅ Register transitions cleanly (0x1A → 0x249A → 0x1A).
- ✅ SSH and Ethernet survive the pulse — no link flap in `dmesg`, the
  100 ms re-mux of MII pin `P0` is invisible at this hardware/PHY combo.
- ✅ The chip resets and boots its app: probing `spinel:460800` before AND
  after the pulse returns `SL-OPENTHREAD/2.4.7.0_GitHub-fb0446f53` — same
  firmware version, proving the chip rebooted successfully into OT-RCP.

What did **not** work:

- ❌ Streaming wake bytes through the bridge (CR, NL, zero bytes — separately
  and combined, up to 4 KB sustained at 115200) failed to land the chip in
  the bootloader menu. After every pulse-and-stream attempt, the chip was
  back in OT-RCP responding at 460800.

## Root cause: `enterBootloader()` semantics

From the SDK source (`silabs-tools/gecko_sdk/platform/bootloader/core/btl_main.c:525-545`):

```c
__STATIC_INLINE bool enterBootloader(void) {
  if (EMU->RSTCAUSE & EMU_RSTCAUSE_SYSREQ) {
    switch (reset_classifyReset()) {
      case BOOTLOADER_RESET_REASON_BOOTLOAD:
      case BOOTLOADER_RESET_REASON_FORCE:
      case BOOTLOADER_RESET_REASON_UPGRADE:
      case BOOTLOADER_RESET_REASON_BADAPP:
        return true;
      default: break;
    }
  }
#ifdef BTL_GPIO_ACTIVATION
  if (gpio_enterBootloader()) return true;
#endif
#ifdef BTL_EZSP_GPIO_ACTIVATION
  if (ezsp_gpio_enterBootloader()) return true;
#endif
  return false;
}
```

`SystemInit2()` (same file, lines 394-507) calls this **before `main()`
runs**. On `false`, the boot path does:

```c
SCB->VTOR = startOfAppSpace;
bootToApp(startOfAppSpace);   // never returns
```

For a hardware `nRST` pin reset, `EMU->RSTCAUSE` carries `RSTCAUSE_PIN`,
**not** `RSTCAUSE_SYSREQ`. The switch is skipped. `BTL_GPIO_ACTIVATION` is
not defined in our bootloader build (`23-Bootloader-UART-Xmodem/build/config/`
does not enable it). The app PC sanity check passes (`OT-RCP` is a valid
image). `enterBootloader()` returns false. `bootToApp()` jumps straight to
OT-RCP. **The bootloader's UART loop never runs.** No byte at any baud, in
any window, can rescue the chip.

The 4 KB stream we observed returning two corrupt bytes (`0x19 0xD0`) was
the OT-RCP firmware's startup HDLC frame, decoded at the wrong baud
(115200 instead of 460800) — proof that what answered us was the
*application*, not the bootloader.

The early v3.1 plan implicitly assumed "any UART byte during a post-reset
input window enters the menu." That assumption holds for *some* serial
bootloaders but not for Gecko Bootloader as configured here, where the
menu only opens after `enterBootloader() == true`.

Useful side finding: `BTL_XMODEM_IDLE_TIMEOUT = 0` in
`23-Bootloader-UART-Xmodem/build/config/btl_xmodem_config.h` means *once
in the menu, the bootloader stays forever*. That part of the plan was
sound — it's the entry to the menu that has no mechanism on this chip.

## Pivot attempt: rebuild the bootloader with `BTL_GPIO_ACTIVATION`

If the bootloader checked a wired GPIO at startup, the SoC could pull that
GPIO and pulse `nRST` to land the chip in the menu. This requires:

1. A bootloader build with `BTL_GPIO_ACTIVATION` enabled and a GPIO config
   pointing at a chosen pin.
2. A physical wire between that EFR32 GPIO and a SoC GPIO that we can drive.

Step 1 is straightforward — Silabs ships `bootloader_gpio_activation` as an
slc component (`silabs-tools/gecko_sdk/platform/bootloader/component/bootloader_gpio_activation.slcc`)
with a config template at
`silabs-tools/gecko_sdk/platform/bootloader/config/btl_gpio_activation_cfg.h`.

Step 2 is the blocker. The TYZS4 module exposes 16 pins (datasheet table 2-1):

| Pins | Function on this gateway |
|---|---|
| 1 (nRST), 15 (RXD), 16 (TXD) | Wired to RTL8196E UART1 + nRST |
| 10 (UART_RTS), 14 (UART_CTS) | Wired to RTL8196E for HW flow control |
| 8 (VCC), 9 (GND) | Power |
| 3,4,5 (SWDIO/SWCLK/SWO) | Routed to header J1 (unpopulated) |
| 2,11,12 (FRC_DCLK/DFRAME/DOUT) | PTI pins — likely NC on Lidl PCB |
| 6,7,13 (PWM1/PWM2/PWM3) | Generic GPIO — likely NC on Lidl PCB |

Tuya's datasheet does not document which EFR32 pin each of `PWM1/2/3` and
`FRC_*` maps to. We had a candidate (`PB11`, based on the file naming
convention in third-party NCP firmwares like
`NCP_UHW_MG1B232_678_PA0-PA1-PB11_PA5-PA4.gbl`, where the third position
is conventionally the BTL_GPIO pin). On the EFR32MG1B232F256GM48
specifically, `PB11` is a valid GPIO (used as USART0 CTS on Silabs ref
boards `brd4101a/b` — i.e. *not* an LFXTAL pin), so it is at least
electrically usable. But:

- We cannot verify from the Tuya datasheet whether `PB11` is one of the
  exposed module pins.
- Even if it is, we cannot verify whether that module pin is wired to a
  SoC GPIO on the Lidl PCB.

### Why we couldn't test it cheaply

The natural empirical test ("flash a small EFR32 firmware that toggles PB11
at 1 Hz, scan SoC GPIOs for one that follows") was blocked by a SoC-side
constraint we discovered while preparing it.

Sampling the SoC's GPIO `DATA` register (`0x18003500 + 0x0C`) at 200 Hz
during 700 ms of sustained UART TX traffic returned **a single unique
value** (`0x00000A08`). The DATA register on this Realtek GPIO controller
**does not reflect the physical level of pins that are in peripheral mode
via CNR**. To detect any inter-chip GPIO activity, we would have to switch
the candidate SoC pin to GPIO mode (clear its CNR bit) — and without a
schematic to identify which SoC pin to target, this becomes risky bisection
on a live gateway whose UART, MII, SPI, and GPIO LED pins are all in
peripheral mode and load-bearing.

The cost was: ~2-3 h of EFR32 firmware development + ~1 h of risky
SoC-side CNR scanning, with a high probability of being inconclusive.
We deferred until cheaper evidence ruled the question in or out.

## The smoking gun: Tuya stock firmware analysis

The 12 MB JFFS2 partition backed up before reflashing the gateway
(`/home/jnilo/Documents/Backup_Lidl/mtd4.bin`) holds the original Tuya
userland. Extracted with `jefferson`. Relevant artifacts:

| Path | Purpose |
|---|---|
| `tyZ3Gw` (3.5 MB) | Tuya Zigbee Gateway daemon |
| `tuya_user1/debugtool` (79 KB) | CLI invoked by `app_upgrade.sh -n` |
| `NcpUpgrade.ota` (186 KB) | EFR32 NCP firmware payload |
| `app_upgrade.sh` | Upgrade orchestrator |
| `def.cfg` | Platform config |

`app_upgrade.sh:102-107` calls `$target/debugtool -n` to do the actual NCP
update. `debugtool` is a thin client; the bootloader-entry logic lives in
`tyZ3Gw`.

`strings tyZ3Gw` for bootloader-entry references:

```
ezspLaunchStandaloneBootloader
EZSP_LAUNCH_STANDALONE_BOOTLOADER
emAfInitXmodemState
emAfSendXmodemData
Failed to get Xmodem start message from bootloader.
EZSP_SET_GPIO_CURRENT_CONFIGURATION       (these are EZSP frames the host
EZSP_SET_GPIO_POWER_UP_DOWN_CONFIGURATION  sends to query/set EFR32 GPIOs,
EZSP_SET_GPIO_RADIO_POWER_MASK             not SoC GPIO operations)
```

`strings tyZ3Gw | grep -iE "/sys/class/gpio|devmem|reset.*coo|coo.*reset|hardware.*reset"`:
**zero matches**.

`def.cfg`:

```json
{
  "serial_port": "/dev/ttyS1",
  "is_cts": true,
  ...
}
```

No GPIO pin configured anywhere. No `/sys/class/gpio` export. No `devmem`
calls. No nRST pulse mechanism. `tyZ3Gw` knows about exactly one I/O
channel to the EFR32: `/dev/ttyS1` with CTS flow control.

**Tuya's stock recovery path is identical to ours.** When the EFR32 is
running EZSP-NCP normally, Tuya sends `ezspLaunchStandaloneBootloader`
(EZSP frame `0x0033`), the running app writes the magic and resets via
`NVIC_SystemReset()`, the bootloader sees `RSTCAUSE_SYSREQ` + magic and
opens the menu, `tyZ3Gw` then drives Xmodem (`emAfSendXmodemData`) to
upload `NcpUpgrade.ota`. If the running app is unresponsive — the case
v3.1 was meant to address — Tuya's flow has no fallback either. They
power-cycle.

This is the strongest evidence we could realistically obtain that no
hardware recovery wire was designed into this gateway. The OEM had every
incentive (factory programming, RMA recovery, OTA failure fallback) and
the schematic in hand. They didn't engineer one because there is none to
engineer.

## Alternative A — `nRST` recovery (mostly free, partially validated)

**The question we missed asking:** does a `reboot` command on the SoC
already reset the EFR32 ?

**Empirically, YES.** Validated on 2026-04-26 on a dev gateway: an
`ssh root@gw reboot`, after `otbr-agent` came back up, produced the
following lines in `/var/log/messages`:

```
otbr-agent[78]: ... RCP => Platform: Reset info: 0x3 (EXT)
otbr-agent[78]: ... RCP => Platform: Extended Reset info: 0x301 (PIN)
```

That is the EFR32 itself reporting, via the Spinel `RESET_REASON`
property, that it had just experienced a **PIN reset** — i.e. its
`nRST` line was actually driven LOW long enough during the SoC reset
sequence to trip an external-pin reset on the radio chip.

The likely mechanism: the chip-reset default of `PIN_MUX_SEL_2` on the
RTL8196E includes one or more of bits {7, 10, 13} set. During the
window between the SoC CPU reset and `V2.5+ bootloader: swCore.c:442`
explicitly clearing the register, `nRST` is held LOW. That window is
on the order of milliseconds — comfortably above the EFR32 Series 1
minimum `nRST` hold time (a few µs) — which is why the reset is
reliable rather than flaky.

| Phase | `PIN_MUX_SEL_2` value | EFR32 `nRST` |
|---|---|---|
| Steady-state (kernel running) | `0x1A` (LED bits only) | released |
| Linux runs `reboot`, CPU resets | reverts to chip-reset default — empirically nRST-asserting | **LOW for several ms** |
| V2.5+ bootloader runs `swCore.c:442` | explicit `REG32(PIN_MUX_SEL2) = 0` | released → EFR32 boots fresh |
| Kernel boots, `rtl8196e-eth` probes | `0x1A` (LED bits added) | released, EFR32 already running new app |

So **a plain `reboot` from Linux is the recovery mechanism Alternative
A's design originally aimed at**. No kernel hook, no notifier, no
sysfs change is needed for the reboot path — it works today,
unintentionally, by virtue of the SoC's own pin-mux register defaults.

### What's left to add

The reboot path works for free. What we'd still want:

- **A `nrst_pulse` sysfs knob in the bridge driver (~30 LOC)** so
  userspace can reset the EFR32 *without* rebooting the whole SoC.
  Useful when only the radio is stuck and you don't want to interrupt
  Linux services.

  ```c
  // /sys/module/rtl8196e_uart_bridge/parameters/nrst_pulse
  // Write any value to trigger a 100 ms nRST assertion on the EFR32.
  static int nrst_pulse_set(const char *val, const struct kernel_param *kp) {
      regmap_update_bits(syscon, 0x44, 0x2480, 0x2480);  // assert
      msleep(100);                                        // hold
      regmap_update_bits(syscon, 0x44, 0x2480, 0x0000);   // release
      return 0;
  }
  ```

- **A `recover_efr32` userspace helper script** that wraps the sysfs
  knob with a friendly message and optionally restarts the radio
  daemon (`S70otbr restart` or equivalent for Zigbee mode).

**What this combination fixes:**

| EFR32 stuck cause | nRST pulse fix? |
|---|---|
| Application crashed / asserted | yes — fresh boot of a working app |
| Halted from J-Link debug session | yes — `nRST` overrides the halt |
| App OK but in stuck/livelock state | yes — fresh boot |
| App slot corrupted, `pc == 0xFFFFFFFF` | yes — `enterBootloader()` returns true via BADAPP, menu opens |
| Wrong/unknown firmware flashed manually | **no** — wrong firmware just restarts |
| Bootloader Stage 2 corrupted | no — J-Link required |

For a project shipping its own GBLs (NCP, RCP, OT-RCP, Router) — i.e.
all our users — the "wrong firmware" case is essentially absent. So
Alternative A alone closes effectively every realistic "stuck EFR32"
case in the field.

### Empirical validation log (2026-04-26, dev gateway)

- **Phase 1** — confirmed that the front-panel button (originally Tuya's
  pairing/factory-reset key) is wired to RTL8196E **GPIO 9 (port B,
  bit 1), active LOW**. Switched ports B-C to GPIO input mode, sampled
  `DATA` at 100 ms during a button press: only bit 9 toggled
  (`0x00000A08` released → `0x00000808` pressed). The historical
  bootloader's bit-5 reading (commit `992cfaf`) was generic for the
  Realtek RTL8196E reference design — Lidl rerouted the button.
- **Phase 2** — confirmed that an SSH `reboot` causes a PIN reset on
  the EFR32. `otbr-agent`'s startup log on the rebooted gateway
  contained `Reset info: 0x3 (EXT)` and `Extended Reset info: 0x301
  (PIN)`, both reported by the EFR32 itself via Spinel. No kernel
  change was needed for this — the RTL8196E's chip-reset default of
  `PIN_MUX_SEL_2` apparently already drives `nRST` LOW for long enough
  before the V2.5+ bootloader's `swCore.c:442` clears it.
- **Phase 3 (chip-reset default of `PIN_MUX_SEL_2`) — skipped on
  cost/benefit grounds.** Three routes considered:
  - kernel patch in `rtl8196e-eth` to log the value before clearing —
    only shows post-bootloader value (≈ 0 by `swCore.c:442`), not the
    chip default;
  - bootloader patch to capture the chip-default to a scratch RAM
    address before `swCore.c:442` runs — risk of bricking the SoC
    bootloader, which has **no SWD recovery path on this hardware**
    (J1 only exposes EFR32 SWD, not SoC SWD; a brick would require
    desoldering the GD25Q127 SPI flash and reprogramming externally);
  - solder J1 pins 3-4 + USB-UART → observe at the bootloader prompt
    via the ESC menu — clean but requires hardware work.

  Phase 2's empirical evidence (the EFR32 itself reporting `Extended
  Reset info: 0x301 (PIN)` to `otbr-agent` after `reboot`) is already
  sufficient to validate the recovery mechanism. The exact chip-default
  value is interesting but not load-bearing for any implementation
  decision. Documenting this trade-off so a future maintainer doesn't
  re-derive it.

### Hardware UI extension: repurpose the existing front-panel button

The gateway has a physical button on its case. We confirmed by analysing
the Tuya stock firmware (`tyZ3Gw` strings: `__ButtonKernelMonitor`,
`tuya_test_button`, `hal_rtl8196e_button_init`,
`emberAfHalButtonIsrCallback`, `NETLINK_SYS_BUTTON_MONITOR`, `def.cfg`'s
`"reset_key":"KEY0"`) and our own bootloader history (commit `992cfaf`
removed `power_on_led.c`'s `pollingPressedButton()` and
`rtl8196e_get_gpio_sw_in()`) that the button is:

- **Wired to GPIO 9 of the RTL8196E** (port B, bit 1 of the
  `PABCDDAT_REG` data register at `0x18003500 + 0x0C`), **confirmed
  empirically** on 2026-04-26 by switching ports B-C of the SoC to
  GPIO input mode and sampling `DATA` while the button was pressed:
  bit 9 was the only one toggling (`0x00000A08` released → `0x00000808`
  pressed). The historical bootloader code (commit `992cfaf` removed
  `power_on_led.c`'s `rtl8196e_get_gpio_sw_in()`) read **bit 5** —
  but that was for the generic Realtek RTL8196E reference design;
  the Lidl PCB routes the button differently. The polarity (`active
  LOW`) is the same.
- **Active LOW** (button pressed → bit 9 reads 0; released → bit 9
  reads 1).
- **Read by software** (Tuya: kernel module + netlink, surfaced to the
  `tyZ3Gw` daemon for app interactions — pairing entry, factory reset,
  etc.). Not wired to `nRST` of either chip; not wired to the power
  rail.
- **Dormant in our current firmware** — we shipped no handler. The pin
  is currently configured in peripheral mode by default (`CNR` bit 9 =
  1 in our live readout `0xFFFFF7FF`), so a press isn't even visible
  in the `DATA` register without first switching it to GPIO mode
  (clear `CNR` bit 9, ensure `DIR` bit 9 = 0).

(Note on naming: GPIO 9 of the RTL8196E is *not* the same pin as `PA5`
of the EFR32 mentioned in Alternative B below — different chips,
different roles, different polarities.)

Once Alternative A is in the kernel, exposing the recovery via a
**long-press of the existing button** is straightforward and ~50
additional lines:

1. Configure GPIO 9 as input (clear bit 9 of `CNR`, clear bit 9 of
   `DIR`) at boot. A new `S40button` init script or a small kernel
   handler.
2. Poll or interrupt-drive: detect press (bit 9 reads 0) → start timer.
3. On release before 5 s: short press, ignored.
4. On hold past 5 s: long press, fire the `nrst_pulse` sysfs knob.
   Optional: blink the status LED during the hold for user feedback.

What this gives us: the user has a **completely keyboard-and-network-
free** way to recover a stuck EFR32. They press and hold the button on
the case for 5 seconds, the gateway resets the radio chip, normal
operation resumes. For users who never touch SSH (or whose gateway
isn't reachable over the network because the radio failure also
broke a Thread/Zigbee path they were debugging through), this is the
right escape hatch.

This extension is purely cosmetic on top of Alternative A — the
kernel mechanism is identical, only the trigger surface widens.

### Cost vs. expected return

Now that Phase 2 confirmed `reboot` already does the heavy lifting,
the remaining implementation cost is small:

- Document existing behaviour (`reboot` resets the EFR32) in
  README/troubleshooting: ~1 hour.
- Add `nrst_pulse` sysfs knob to the bridge driver + a
  `recover_efr32` helper script that wraps it: ~half a day.
- Button handler extension (GPIO 9 init + long-press detection + LED
  feedback): ~half day.

Expected return: 90%+ of the "stuck EFR32" recovery cases handled
without a power cycle, and exposed via three escalating UIs:

1. `reboot` over SSH — already works.
2. `recover_efr32` over SSH — non-disruptive (no SoC reboot, only the
   radio chip resets).
3. Long-press the front-panel button — no SSH, no network, no
   keyboard. Useful when the network is precisely what's broken.

This is a strict subset of the full Alternative B and could be shipped
as a v3.1 patch release — much smaller scope, much less risk, and the
bulk of the user value.

## Untested alternative B — repurpose the existing CTS line (`PA5`) for `BTL_GPIO_ACTIVATION`

The "no spare wire" obstacle in the `BTL_GPIO_ACTIVATION` pivot above
only applies if the activation pin must be a *new*, dedicated wire.
There is in fact one EFR32 GPIO that the SoC already drives natively
over an existing trace: **`PA5`**, the EFR32's UART CTS *input*, fed
by the SoC's RTS *output* for hardware flow control. Electrically,
`PA5` is suitable as a `BTL_GPIO_ACTIVATION` input — no new trace,
no contention, no pin-direction reversal:

| EFR32 pin | EFR32 direction | SoC direction | Usable as BTL_GPIO input? |
|---|---|---|---|
| `PA0` (TXD) | output | input | no — EFR32 drives |
| `PA1` (RXD) | input | output | usable but in active use for data |
| `PA4` (RTS) | output | input | no — EFR32 drives |
| **`PA5` (CTS)** | **input** | **output** | **yes — SoC drives natively** |

`PA4` is the symmetric pair to `PA5` but goes the wrong way: the EFR32
drives it (as RTS-out), the SoC reads it. A bootloader read of `PA4`
would just see what the EFR32 itself drives — useless for activation.

### Sketch of a `PA5`-based recovery flow

1. **Bootloader rebuild** — enable the `bootloader_gpio_activation` slc
   component, set `BTL_GPIO_ACTIVATION_POLARITY = HIGH`,
   `BTL_GPIO_ACTIVATION_PORT = gpioPortA`, `BTL_GPIO_ACTIVATION_PIN = 5`.
   Polarity HIGH is critical: during normal operation the SoC asserts
   RTS (`PA5` = LOW) most of the time, so a `LOW = stay in bootloader`
   choice would trap every cold boot. With polarity HIGH, normal boots
   see `PA5` LOW and auto-jump to app; recovery requires the SoC to
   deassert RTS (drive `PA5` HIGH) *before* releasing `nRST`.
2. **Kernel bridge driver: add an `rts` sysfs knob** so userspace can
   force RTS to a known state (asserted/deasserted/driver-controlled).
   The default behaviour of the 8250 driver when `CRTSCTS` is off is not
   guaranteed across kernel versions; an explicit knob removes ambiguity.
3. **`flash_efr32.sh` recovery path**:

   ```bash
   # Force RTS deasserted: SoC RTS HIGH → EFR32 PA5 HIGH
   echo 1 > /sys/module/rtl8196e_uart_bridge/parameters/rts
   sleep 0.05

   # Pulse nRST while PA5 is held HIGH
   REG=0x18000044
   BEFORE=$(devmem $REG 32)
   devmem $REG 32 $((BEFORE | 0x2480))
   sleep 0.1
   devmem $REG 32 $BEFORE

   # Bootloader runs, reads PA5 = HIGH, enters menu, stays forever
   sleep 0.2

   # Restore driver-controlled RTS (back to normal flow control behaviour)
   echo -1 > /sys/module/rtl8196e_uart_bridge/parameters/rts

   # Probe Gecko Bootloader from host — should now succeed
   universal-silabs-flasher --device socket://${GW_IP}:8888 \
       --probe-methods bootloader:115200 ...
   ```

4. **Migration**: this approach requires a one-time bootloader upgrade on
   every existing gateway, performed via the v3.0.1 cooperative path.
   Until the upgrade is done the new behaviour is dormant and the gateway
   remains v3.0.1-equivalent.

### Open questions worth empirical answers before committing

- **Floating window at reset release**: between `nRST` release and the
  bootloader's first `PA5` read in `SystemInit2()`, the EFR32 pin starts
  in its reset default (input with weak internal pull-up enabled, per
  the EFR32 Series 1 reference manual). The SoC must be actively driving
  the line HIGH when the read happens — measure how long the bootloader
  takes to reach the GPIO read and ensure SoC drive is stable across
  that window.
- **Flow-control surprises during normal operation**: does forcing RTS
  deasserted ever happen accidentally (kernel bridge edge-cases, driver
  bugs, suspend/resume)? If yes, the next reboot would unintentionally
  land in the bootloader. The polarity-HIGH choice protects against the
  common case (RTS asserted = normal); the bridge driver still needs to
  be audited for paths that leave RTS deasserted at boot.
- **Bootloader USART claim on `PA5`**: the bootloader's UART is
  configured *without* flow control
  (`SL_SERIAL_UART_FLOW_CONTROL = 0` in `btl_uart_driver_cfg.h`), so
  `PA5` should not be claimed by the bootloader's USART hardware and
  can be read as plain GPIO. Confirm by reading the SDK source for the
  bootloader's UART init.
- **Bootloader-upgrade migration risk**: a Stage-2 reflash that gets
  interrupted (~30 s window) bricks the chip into requiring J-Link
  recovery — exactly the situation this feature is meant to remove.
  Quantify the per-user risk; consider whether the upgrade should be
  opt-in.

### What A misses that B catches

It is worth being precise about the residual cases, because the gap is
narrower than the "Alternative A vs. Alternative B" framing might
suggest.

Alternative A only enters the bootloader menu when the post-`nRST`
boot lands in one of `enterBootloader()`'s `true` branches — in
practice, the `BADAPP` sanity-check fail (`*(app_base + 4) ==
0xFFFFFFFF`). For any other state, the bootloader jumps to the app,
and recovery then depends on the running app being cooperative — the
v3.0.1 path. So A misses exactly the cases where:

- the app vector table looks valid (so the bootloader hands off to the
  app), **and**
- the running app does not respond to USF's standard probe sequence
  for EZSP / CPC / Spinel / Gecko Bootloader.

Concretely:

| Residual case | Why A fails | Frequency in our user base |
|---|---|---|
| User flashed a non-Zigbee Silabs firmware (Bluetooth NCP, Z-Wave, RAIL test app, custom Simplicity Studio sample) | Vector valid → app boots → speaks an unknown protocol → USF probe fails at every baud | very rare |
| User flashed a generic third-party firmware from another EFR32MG1 product | same | rare |
| Very old EmberZNet (≤ 6.x) with an EZSP frame layout USF cannot parse | USF's `version` frame goes unanswered or gets a malformed reply | possible, mostly during v2.x → v3.x migrations |
| Custom hardened build with `launchStandaloneBootloader` explicitly disabled | Cooperative path is *refused* even when the running firmware otherwise responds normally | extremely rare |
| OTA interrupted *after* the vector table is written but *before* `.text` is complete: bootloader's PC sanity check passes, app crashes silently in `init` before opening UART | Reset → same partially-written app → same silent crash → no UART traffic | possible after a botched flash; the only realistic case for a happy-path user |

For a project shipping its own standard firmwares (NCP-EZSP, RCP-CPC,
OT-RCP-Spinel, Z3 Router) and probing them with the patched USF that
v3.0.1 already ships, none of the rows above is reachable as a normal
user journey — they all require an explicit user action that took the
chip outside the project's supported firmware set.

Cases that *look* like they would need B but are actually handled by A:

- App crash with an exception handler that calls `NVIC_SystemReset()`
  → reboots cleanly, A covers it.
- App vector pointer corrupted to `0xFFFFFFFF` → BADAPP path,
  `enterBootloader()` returns true, A covers it.
- OTA interrupted *during* the vector-table write → bootloader detects
  `BADIMAGE` and resets via SYSREQ-with-magic, A covers it.
- EFR32 halted from a J-Link debug session → `nRST` overrides the halt
  unconditionally, A covers it.

The honest summary: A handles every realistic recovery case for users
running our shipped firmwares; the only common case that genuinely
needs B is "OTA interrupted after vector but before code", which is
also already mitigated by users having to repeat the flash from
scratch (the chip will eventually re-enter the SYSREQ-magic path the
next time they try, since the initial part of any flash sequence
brings the bootloader in cleanly).

### Cost vs. expected return

Implementation effort estimate: ~3-4 days end-to-end — bootloader rebuild
+ kernel sysfs knob + script changes + migration tooling + tests.
Expected return: closes the residual cases enumerated above that
Alternative A cannot reach.

This work is **not currently scheduled.** The post-mortem records the
approach so a future maintainer encountering the same recovery limitation
can pick it up without re-deriving the analysis. Alternative A above
should be shipped first; B is only worth the additional cost if one of
the residual cases above actually shows up in user reports — and even
then, "use a J-Link on header J1" is an acceptable answer for the
profile of user who got there in the first place (an explicit
non-standard flash). The migration risk of B (a botched bootloader
upgrade bricks the chip into requiring exactly that J-Link) means B
should be implemented only when there is a concrete failure to
validate against, not speculatively.

## Conclusion

There is no software-only path to enter the Gecko Bootloader on this
gateway from a non-cooperative EFR32 state with the **shipped** bootloader.
The hardware does, however, provide two viable improvements that were
not exercised in v3.1's original scope:

- The existing `reboot` already pulses `nRST` on the EFR32
  (Alternative A above) — confirmed empirically in Phase 2. A small
  patch to expose this through a non-disruptive `nrst_pulse` sysfs
  knob and a long-press of the existing front-panel button (RTL8196E
  GPIO 9) closes the user-experience gap without any bootloader
  change. Cheap; works without SSH or network at the button level.
- `BTL_GPIO_ACTIVATION` reading the existing `PA5`/CTS line
  (Alternative B above) recovers from any state including unknown
  firmwares. Heavier; requires a one-time bootloader upgrade.

What this means in practice:

- **Normal flashing** (running app reachable): v3.0.1's `flash_efr32.sh`
  works. The cooperative path via USF + EZSP/CPC/Spinel
  `launchStandaloneBootloader` is the only path, and it is reliable when
  the chip is responsive at any of the supported bauds.
- **Recovery from unresponsive state** (corrupted firmware, J-Link halt,
  unknown image at unknown baud): physical power cycle of the gateway is
  required. The newly-power-cycled chip starts in a clean state, the app
  responds, and the cooperative path succeeds.
- **Recovery from a flashed-but-broken bootloader**: requires SWD via
  header J1 and Simplicity Commander. Documented in `35-Migration/`.

For any future gateway hardware revision, the trivial fix is to wire one
spare SoC GPIO to one spare EFR32 GPIO (`PB11` is the conventional choice)
and ship a bootloader built with `BTL_GPIO_ACTIVATION` pointing at that
pin. Cost: one PCB trace + two component pins + one config line in the
bootloader slcp. None of *that specific* retrofit is possible on existing
Lidl hardware — the dedicated wire isn't there. The `PA5`/CTS-repurposing
variant described above does *not* require new hardware and is the path to
take if this recovery hole becomes worth closing.

## v3.1 disposition

The v3.1 plan as originally drafted (userland `nRST` pulse + USF
recovery + multi-baud GBL matrix) is dropped — the pulse cannot enter
the bootloader, and the matrix alone is low-value.

If a v3.1 ships, the most likely scope is **Alternative A** as now
revised: document that `reboot` already recovers a stuck EFR32, add a
`nrst_pulse` sysfs knob for non-disruptive radio-only recovery, plus
a button handler on the existing front-panel key (RTL8196E GPIO 9 in
input mode → 5 s long-press → `nrst_pulse`). The reboot path is free
(empirically validated 2026-04-26); only the sysfs knob and button
handler are new code. Total ~1 day of implementation; could be cut as
a patch release on top of v3.0.1.

Alternative B (PA5 / `BTL_GPIO_ACTIVATION`) is parked until either a
user reports the "wrong firmware" recovery case, or the project decides
to invest in a bootloader-upgrade migration for other reasons.

Until then, v3.0.1 remains the production solution; the README will be
updated to call out the "power cycle required if EFR32 unresponsive"
limitation with a brief pointer to this post-mortem.

## References

- `silabs-tools/gecko_sdk/platform/bootloader/core/btl_main.c:394-545` —
  `SystemInit2()` and `enterBootloader()` source of truth.
- `silabs-tools/gecko_sdk/platform/bootloader/component/bootloader_gpio_activation.slcc`
  and `…/config/btl_gpio_activation_cfg.h` — what we'd add to a future
  bootloader build if the hardware ever supported it.
- `23-Bootloader-UART-Xmodem/build/config/btl_xmodem_config.h:41` —
  `BTL_XMODEM_IDLE_TIMEOUT = 0` (once-in-menu, stay forever).
- `3-Main-SoC-Realtek-RTL8196E/32-Kernel/files-6.18/drivers/net/ethernet/rtl8196e-eth/rtl8196e_hw.c:298-326`
  — kernel-side `PIN_MUX_SEL_2` handling that establishes the `nRST` mask.
- `silabs-tools/lib/python3.12/site-packages/universal_silabs_flasher/gecko_bootloader.py:65,147`
  — USF's bootloader probe regex and the `\n`-as-wake-byte comment.
- `0-Hardware/datasheet/Tuya TYZS4 datasheet.pdf` — TYZS4 module pin
  table, used to bound which EFR32 GPIOs are even physically accessible.
- Tuya stock firmware: `/home/jnilo/Documents/Backup_Lidl/mtd4.bin`
  (extracted with `jefferson`); see `tyZ3Gw` strings and `def.cfg`.
- Historical bootloader button-detection code, removed in commit
  `992cfaf` ("bootloader: rewrite for x-tools toolchain, clean boot
  log") — see
  `git show 992cfaf^:3-Main-SoC-Realtek-RTL8196E/31-Bootloader/src/boot/monitor/power_on_led.c`
  (`rtl8196e_get_gpio_sw_in()` at line 414 of that file) for the
  active-LOW detection idiom. Note that the historical code reads
  bit 5; the empirical Lidl wiring is bit 9 (port B, bit 1) — bootloader
  was generic for the Realtek RTL8196E reference design, the Lidl PCB
  routes the button differently.
