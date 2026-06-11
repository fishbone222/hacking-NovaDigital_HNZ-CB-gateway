# RTL8196E Ethernet driver — Security / robustness / perf audit

Target: Linux 6.18 port of the `rtl8196e-eth` driver for the Realtek
RTL8196E SoC (Lexra RLX4181, single-core MIPS-I BE, non-coherent
writeback L1, 32-byte cache lines, no LWL/LWR, no hardware divide).

Audit date: 2026-04-23. Driver version at audit time: `2.2`.
Second-pass audit: 2026-05-01 (driver `2.3` → `2.4`) and third-pass
audit: 2026-05-03 (driver `2.4` → `2.5`); see end of file. The later
driver `2.6` hardening (shadow-skb lookup by hardware mbuf index,
TX/RX pool-bounds validators) came out of the issue #99 synthesis
work, not an audit pass — its perf confirmation is in
`PERFORMANCE.md` (v3.8.0 run).
Baseline throughput on the Lidl Silvercrest gateway: **~94 Mbit/s RX,
~71 Mbit/s TX**.

The driver was already carefully written: `__iram` placement for hot
paths, NAPI with GRO defer tuning, KSEG1 (uncached) rings, explicit
`dma_cache_*` discipline for non-coherent DMA, single-producer /
single-consumer TX ring with `READ_ONCE` / `WRITE_ONCE`. The audit did
**not** find an exploitable security vulnerability or a certain memory
corruption in nominal operation. What follows is focused on the
remaining rough edges and their fixes.

## Summary of findings

17 findings total. 10 were fixed in **batch 1**; 1 (F8) was applied as
a follow-up refactor; 1 (F6) was tested and rejected; 3 (F11/F13/F15)
were bundled, tested and rejected (major regression); 3 are
informational and intentionally left as-is.

| ID | Type | Severity | Confidence | Status | One-liner |
|----|------|----------|------------|--------|-----------|
| F1 | ROBUSTNESS | high | certain | **fixed** | `tx_timeout` didn't synchronise with NAPI → ring corruption race |
| F2 | ROBUSTNESS | high | certain | **fixed** | MAC change in UP was silently broken (NETIF / L2 not reprogrammed) |
| F3 | PLATFORM | high | certain | **fixed** | 650 ms of `mdelay` in process context during `ndo_open` |
| F4 | ROBUSTNESS | high | certain | **fixed** | Poll-ready loops used `udelay` where `usleep_range` is schedulable |
| F5 | ROBUSTNESS | medium | certain | **fixed** | RX drop / bad-length paths didn't update `rx_errors` / `rx_dropped` |
| F6 | PERF | medium | probable | **tested, rejected** | Descriptor pools in KSEG1: TCP TX -1.2 Mb/s, gain only on UDP bidir |
| F7 | API | medium | certain | **fixed** | ISR acked bits then returned `IRQ_NONE` (spurious-count risk) |
| F8 | ROBUSTNESS | medium | certain | **fixed** | `device_create_file` replaced by `attribute_group` via `sysfs_groups[]` |
| F9 | ROBUSTNESS | medium | probable | **fixed** | `kick_tx` bypassed the `readl/writel` helpers |
| F10 | ROBUSTNESS | medium | probable | **fixed** | `table_write` proceeded when `tlu_start` timed out |
| F11 | PERF | low | probable | **tested, rejected** | bundled with F13/F15 — major regression on hardware |
| F12 | ROBUSTNESS | low | certain | **fixed** | `mb = ph->ph_mbuf` dereferenced without pool bound check |
| F13 | PERF | low | probable | **tested, rejected** | bundled with F11/F15 — major regression on hardware |
| F14 | ROBUSTNESS | low | certain | **fixed** | `stop()` didn't W1C latched status bits in `CPUIISR` |
| F15 | API | low | certain | **tested, rejected** | bundled with F11/F13 — major regression on hardware |
| F16 | STYLE | info | certain | intentional | `(void)hw` in functions that never use `hw` (vestigial API) |
| F17 | PLATFORM | info | hypothesis | documented | HW DMA registers are programmed with KSEG1 virtual addresses |

## Batch 1 — applied fixes

All changes live in the three C files of this directory.

### F1 — synchronise NAPI around `tx_timeout`

File: `rtl8196e_main.c` in `rtl8196e_tx_timeout()`.

Why: in 6.x, `ndo_tx_timeout` runs in the watchdog workqueue (process
context). NAPI poll runs in softirq and can also be driven by the GRO
hrtimer (`gro_flush_timeout = 2 ms`), so masking the hardware IRQ is
no longer enough to freeze NAPI. While `tx_reset()` `memset`s the
descriptor pool and resets `tx_cons = 0`, NAPI could be concurrently
reading `tx_ring[tx_cons]` and dereferencing the `mb`/skb behind it →
use-after-free or index desynchronisation. Rare (needs a TX timeout
during live traffic) but certain to exist.

```diff
 	netif_stop_queue(ndev);
+	napi_disable(&priv->napi);
 	rtl8196e_hw_disable_irqs(&priv->hw);
 	rtl8196e_hw_stop(&priv->hw);
 	rtl8196e_ring_tx_reclaim(priv->ring, &pkts, &bytes, 0);
 	rtl8196e_ring_tx_reset(priv->ring);
 	rtl8196e_hw_set_tx_ring(&priv->hw, rtl8196e_ring_tx_desc_base(priv->ring));
 	rtl8196e_hw_start(&priv->hw);
+	napi_enable(&priv->napi);
 	rtl8196e_hw_enable_irqs(&priv->hw);
 	netif_wake_queue(ndev);
```

### F2 — refuse MAC change while the interface is UP

File: `rtl8196e_main.c`, new `rtl8196e_set_mac_address()` replacing the
default `eth_mac_addr` in `rtl8196e_netdev_ops`.

Why: the vanilla `eth_mac_addr` updates `ndev->dev_addr` but does not
touch the hardware NETIF table (48-bit MAC embedded in `word0`/`word1`)
nor the hashed "toCPU" L2 entry. A live `ip link set eth0 address ...`
would silently break all unicast reception. Cleanest minimal fix:
refuse it while UP; the next `open()` reprograms both tables from
`ndev->dev_addr`.

```c
static int rtl8196e_set_mac_address(struct net_device *ndev, void *p)
{
	if (netif_running(ndev))
		return -EBUSY;
	return eth_mac_addr(ndev, p);
}
```

### F3 — `mdelay` → `msleep` in `rtl8196e_hw_init`

File: `rtl8196e_hw.c`. Three occurrences (two `mdelay(300)` + one
`mdelay(50)`).

Why: `hw_init` is called from `ndo_open`, process context. Six hundred
fifty milliseconds of busy-wait on a single-core 400 MHz MIPS blocks
ksoftirqd and every other task during every `ifconfig up`. `msleep` is
schedulable.

### F4 — `udelay(10)` → `usleep_range(10, 20)` in poll-ready loops

File: `rtl8196e_hw.c` in `rtl8196e_mdio_wait_ready`,
`rtl8196e_table_wait_ready`, `rtl8196e_tlu_start`.

Why: each loop bounds to 1000 × 10 µs = 10 ms worst case. Called
repeatedly from `rtl8196e_l2_clear_table` (1024 iterations of
`rtl8196e_l2_write_entry`, each doing two or three of these waits), so
the cumulative worst-case can reach several seconds of busy-wait in
`open()`. Schedulable sleep lets the rest of userland progress under
silicon stress.

### F5 — RX error counters

File: `rtl8196e_ring.c` in `rtl8196e_ring_rx_poll`.

Why: three paths recycled the descriptor silently:

- `rxb->skb == NULL` (defensive — shouldn't happen)
- `napi_alloc_skb()` returned NULL (OOM)
- `ph->ph_len` out of `[ETH_ZLEN, buf_size]`

None of these updated `rx_errors` / `rx_dropped`, so field debug via
`ip -s link` or `ethtool -S` showed nothing. Added a dedicated
`rearm_drop` label for the first two (OOM-ish) and
`rx_errors`+`rx_length_errors` on `rearm_bad`.

### F7 — ISR: mask before W1C

File: `rtl8196e_main.c` in `rtl8196e_isr`.

Why: the old sequence `read → W1C → mask → return IRQ_NONE on zero`
could clear bits we didn't actually process (not armed in CPUIIMR)
before returning `IRQ_NONE`. Kernel treats consistent `IRQ_NONE` as
spurious → disables the IRQ line after enough "unhandled" counts. New
sequence reads both `CPUIISR` and `CPUIIMR`, intersects them, returns
`IRQ_NONE` **without** clearing if nothing is ours, otherwise W1Cs
only our bits.

### F9 — `kick_tx` via the MMIO helpers

File: `rtl8196e_ring.c` in `rtl8196e_ring_kick_tx`.

Why: every other MMIO in the driver goes through `rtl8196e_readl /
writel`. `kick_tx` open-coded `*(volatile u32 *)CPUICR` which is
functionally equivalent today but diverges silently if the helpers are
ever moved behind `ioremap`. Also added a comment on the posting-read
pattern used to make the TXFD pulse visible to hardware.

### F10 — abort `table_write` / `l2_write_entry` on TLU failure

File: `rtl8196e_hw.c` in `rtl8196e_table_write`,
`rtl8196e_l2_write_entry`.

Why: the old code set `tlu_ok = false` and proceeded with the table
write. Depending on silicon revision, writes to `TBL_ACCESS_CTRL`
without the Table Lookup Unit engaged may not be latched into the ASIC
RAM, giving silently-empty entries with no verification for VLAN /
NETIF / broadcast rows. Now returns `-EIO` with a rate-limited warning
and lets the caller decide (`open()` already has a fallback path via
`rtl8196e_hw_l2_trap_enable`).

### F12 — bound-check `ph->ph_mbuf` in RX poll

File: `rtl8196e_ring.c` in `rtl8196e_ring_rx_poll`.

Why: after the CPU invalidates the pkthdr, `mb = ph->ph_mbuf` reads a
value that hardware has been able to touch. The driver only ever
assigns `ph_mbuf` to valid pool pointers at ring creation, but a
silicon bug or DRAM corruption could plant a wild pointer → oops on
dereference. Added a pool-bound check with fallback to the
index-derived mapping (`ring->rx_mbuf_base[rx_idx]`) on failure.
Defense in depth; expected to be a no-op in the field.

### F14 — clear CPUIISR on `stop()`

File: `rtl8196e_main.c` in `rtl8196e_stop`.

Why: after disabling IRQs and stopping hardware, `CPUIISR` can still
carry latched status bits (unacked RX_DONE, runout). A subsequent
`open()` starts with stale status. One `writel(readl(CPUIISR),
CPUIISR)` at shutdown guarantees a clean slate.

## Tested and rejected

### F6 — descriptor pools in KSEG1 (perf, experimental)

**Status: tested on hardware 2026-04-23, rejected.** Branch
`audit-batch2-f6` (now deleted) implemented this on top of batch 1,
with a one-shot `dma_cache_wback_inv` over each pool before aliasing
it to KSEG1 via `rtl8196e_uncached_addr`. All per-descriptor
`dma_cache_*` calls in `tx_submit` / `tx_reclaim` / `rx_poll` /
`tx_reset` / `dbg_timer_fn` were removed since `ph`, `mb` and their
derived pointers ended up in KSEG1 too. Kernel built and booted
cleanly, IRQ 31 `spurious` stayed at 0.

Hypothesis was that trading ~4 per-packet cache ops for uncached
loads/stores on small descriptors would win on hot paths. Measurement
says otherwise:

| Test | Batch 1 | F6 | Δ |
|------|---------|----|---|
| TCP Ubuntu→RTL (RX) | 93.9 Mb/s | 93.9 Mb/s | = |
| **TCP RTL→Ubuntu (TX)** | **72.2 Mb/s** | **71.0 Mb/s** | **−1.2** |
| TCP Parallel ×4 | 95.0 Mb/s | 95.3 Mb/s | +0.3 |
| TCP Parallel ×8 | 96.1 Mb/s | 95.5 Mb/s | −0.6 |
| TCP stress 300 s | 93.9 Mb/s | 94.0 Mb/s | +0.1 |
| UDP 10M / 50M | 10.5 / 52.4, 0% | 10.5 / 52.4, 0% | = |
| UDP 100M (CPU-bound) | 42.3, 56% loss | 42.3, 56% loss | = |
| **UDP bidir to-rtl** | **29.4 Mb/s, 44% loss** | **31.5 Mb/s, 40% loss** | **+2.1** |
| UDP bidir from-rtl | 13.2 Mb/s, 0% | 13.2 Mb/s, 0% | = |

TCP TX regresses by −1.2 Mb/s (≈1.7 %), above the 1 Mb/s "worth
investigating" noise floor from `32-Kernel/CLAUDE.md`. Likely cause:
`tx_submit` does ~10 stores to `ph`/`mb` fields. In KSEG0 these hit
the cache (cheap) and get batched by a single `dma_cache_wback_inv`.
In KSEG1 each store is a direct bus access, which beats the single
cache op only when the descriptor is touched once or twice — not
when it is touched ten times. Conversely, RX-dominant workloads win,
hence the +2.1 Mb/s on UDP bidir.

Decision: net loss on the production workload (TCP TX already being
the slower direction). Not merged.

If this is revisited, try a hybrid: keep the pools in KSEG0 but
touch them via a KSEG1 alias only for the handover word (`tx_ring`
entry, which is already KSEG1), avoiding both the full per-descriptor
wback on TX and the cache ops during reclaim/poll. Or: batch
descriptor fields so the store count drops (currently `tx_submit`
writes `ph_len`, `ph_vlanId`, `ph_portlist`, `ph_srcExtPortNum`,
`ph_flags` separately, with bit-field RMWs on two of them).

### F11 + F13 + F15 — descriptor-ring micro-optimisations (bundled)

**Status: tested on hardware 2026-04-23, rejected.** Branch
`audit-micro-opts` (now deleted) implemented the three items as a
single commit on top of F8 (main at `5eaca40`). Kernel built and
booted fine, IRQ 31 `spurious` stayed at 0, but the iperf suite
regressed massively on the very first tests:

| Test | Batch 1 baseline | F11+F13+F15 | Δ |
|------|------------------|-------------|---|
| TCP Ubuntu→RTL (RX) | 93.9 Mb/s | 46.5 Mb/s | **−47 Mb/s (−50 %)** |
| TCP RTL→Ubuntu (TX) | 72.2 Mb/s | 49.4 Mb/s | **−23 Mb/s (−30 %)** |

The suite was interrupted after the second test — the regression is
obvious and the remaining tests were skipped.

Likely culprits (not bisected — commit was reverted in one step):

- **F13** (`wback_inv → inv` on the RX rearm buffer). In theory
  equivalent on clean cache lines and semantically safe because HW is
  about to overwrite the buffer, but Lexra cache behaviour may differ
  from the assumption. Possible interaction with the cached data lines
  that hold `mb`/`ph` in the same region, or a subtle timing effect on
  the `hit_invalidate_d` instruction when lines are still held by
  a previous stack consumer.
- **F15** (compute WRAP from the ring index instead of RMW). The
  transformation looks algebraically equivalent — initial WRAP bits
  live only on the last slot of each ring, the driver never moves them
  — but the original RMW may have a side effect we are not modelling
  (e.g. ordering guarantee through the uncached read) that the straight
  write does not provide.
- **F11** (remove `dma_cache_inv` on a KSEG1 tx_ring entry). On paper a
  no-op; unlikely to cause regression by itself, but could amplify
  reordering if paired with F15's change to the following store.

Decision: keep batch 1 + F8 as the shipping configuration. Revisit
micro-opts only individually, each in its own branch with the full iperf
suite as gate. The expected gain per item is small (under the noise
floor of the baseline) so the upside does not justify the risk of
another bundle-level regression.

If revisited, start with F11 alone (lowest risk, least interesting
gain), then F13 alone with special attention to per-test retransmission
rate, then F15 alone with a double-check of the WRAP-bit transition
under back-to-back submit+reclaim (e.g. instrument the descriptor state
via the debug timer).

## Deferred items

_None remaining. All 17 findings have been either applied, rejected
after testing, or documented as intentionally left as-is._

## Non-issues verified

- **`napi_alloc_skb` reserves `NET_SKB_PAD + NET_IP_ALIGN` in 6.18**
  (verified in `net/core/skbuff.c:804,845`). The RX rearm path does
  preserve IP alignment; the existing code comment is correct.
- **TX submission memory ordering**: `wback → wmb → handover → wmb` is
  correct; both barriers surround the ownership flip.
- **TX concurrency**: `start_xmit` is serialised by the netdev queue
  lock (no `NETIF_F_LLTX`). NAPI only reads `tx_prod` via `READ_ONCE`
  and writes `tx_cons` via `WRITE_ONCE`. Clean SP/SC.
- **Descriptor alignment vs ownership bits**: `sizeof(struct
  rtl_pktHdr) == 20` and `sizeof(struct rtl_mBuf) == 32` — both
  multiples of 4, so bits 0 and 1 of `&pool[i]` are always zero and
  the OR with OWNED / WRAP never corrupts the address.
- **SKB length trust**: `ph->ph_len` is bound-checked to
  `[ETH_ZLEN, buf_size = 1700]`. `skb_put(skb, len)` never overruns.
- **6.x API**: `timer_container_of`, `timer_setup`, `timer_delete_sync`,
  `netif_napi_add` without weight, `of_get_mac_address` new signature,
  `eth_hw_addr_set`, `eth_hw_addr_random` — all correct for 6.x.
- **OF node refcounts in `dt.c`**: `for_each_child_of_node` handles the
  ref; returned node is paired with a `of_node_put` in the caller.
- **Stack usage**: `u32 a[8] + u32 b[8]` in `l2_read_entry` is 64 bytes
  — well within the 8 KB MIPS kernel stack.

## Validation results (batch 1)

Full `scripts/test_rtl8196e_eth.sh` suite, #4 (pre-batch1) vs
#5 (post-batch1):

| Test | Before | After | Δ |
|------|--------|-------|---|
| TCP Ubuntu→RTL (RX) | 93.9 Mb/s, retrans 10 | 93.9 Mb/s, retrans 1 | = / better |
| TCP RTL→Ubuntu (TX) | 71.2 Mb/s, retrans 3 | 72.2 Mb/s, retrans 0 | +1.0 |
| TCP parallel ×4 | 95.4 Mb/s, 0.17 % retx | 95.0 Mb/s, **0.04 % retx** | -0.4, 4× fewer |
| TCP parallel ×8 | 95.5 Mb/s, 0.13 % retx | 96.1 Mb/s, 0.15 % retx | +0.6 |
| TCP 300 s stress | 94.1 Mb/s, retrans 11 | 93.9 Mb/s, retrans 12 | noise |
| UDP 10 M (non-sat.) | 10.5 Mb/s, 0 loss | 10.5 Mb/s, 0 loss | = |
| UDP 50 M (non-sat.) | 52.4 Mb/s, 0 loss | 52.4 Mb/s, 0 loss | = |
| UDP 100 M (saturating) | 41.4 Mb/s, 57 % loss | 42.3 Mb/s, 56 % loss | CPU-bound |
| UDP bidir to-rtl | 30.9 Mb/s, 41 % loss | 29.4 Mb/s, 44 % loss | noise (saturating) |
| UDP bidir from-rtl | 13.1 Mb/s, 0 loss | 13.2 Mb/s, 0 loss | = |
| `rx_errors` | 0 | 0 | = |
| `tx_errors` | 0 | 0 | = |

Spot checks:

- **F7 / F14**: `/proc/irq/31/spurious` shows `count 0 / unhandled 0 /
  last_unhandled 0 ms` both after the full test suite and after a
  cold reboot.
- **F2**: `ip link set dev eth0 address 02:...` while UP returns
  `ioctl 0x8924 failed: Resource busy` (EBUSY, exit 2). Confirmed on
  hardware.

No regression on any measured metric. TCP TX gained +1 Mb/s and the
4-stream retransmission rate dropped by roughly 4×, consistent with
F7/F14 stabilising the IRQ path.

## How to retest end-to-end

```bash
# Rebuild
cd 3-Main-SoC-Realtek-RTL8196E/32-Kernel/
./build_kernel.sh

# Flash over SSH (gateway already on custom firmware)
../flash_remote.sh -y kernel 192.168.1.88

# Confirm build counter
ssh root@192.168.1.88 'uname -a'

# Regression suite (takes ~10 min)
./scripts/test_rtl8196e_eth.sh "some-label"

# Quick IRQ sanity
ssh root@192.168.1.88 'cat /proc/irq/31/spurious'

# F2 validation — DO NOT run this over SSH on the tested interface;
# use a serial console or a second network path.
#   # (refusal in UP)
#   ip link set dev eth0 address 02:de:ad:be:ef:42   # → -EBUSY
#   # (change in DOWN)
#   ip link set eth0 down
#   ip link set dev eth0 address 02:de:ad:be:ef:42
#   ip link set eth0 up
#   /etc/init.d/S10network restart
```

## Overlay-sync reminder

No manual copy is needed anymore: `build_kernel.sh` rsyncs this
overlay tree into `../../linux-6.18-rtl8196e/` on **every** run
(mtime-preserving, so make's incremental rebuild only recompiles what
actually changed). The historical gotcha — sources copied only on
fresh extraction, stale tree silently rebuilt — applied to the old
5.10 flow. `./build_kernel.sh clean` still forces a from-scratch
re-extract + patch + overlay (~5 minutes) when tree corruption is
suspected.

## Second-pass audit (2026-05-01) — driver 2.3 → 2.4

A second independent audit was run against the same source tree (driver
at `2.3`, post-batch1+F8). It produced 8 findings labelled
`RTL8196E-ETH-001..008`. Cross-referenced against the F1-F17 history
above:

| New ID | Status | Notes |
|--------|--------|-------|
| ETH-001 | **fixed in 2.4** | New finding — short TX frames not zero-padded (`skb_put_padto`). Security. Not covered by F1-F17. |
| ETH-002 | **fixed in 2.4** | F1 had fixed tx_timeout/NAPI sync and F14 had W1C'd CPUIISR on stop, but stop() still did not reset rings. New `rtl8196e_ring_rx_reset()` + both resets called in stop(). |
| ETH-003 | deferred | RX `CHECKSUM_UNNECESSARY` blanket assumption. Audit itself recommends "no patch without HW test of bad-checksum drop semantics". Not addressed in this pass. |
| ETH-004 | **fixed in 2.4** | Added `BUILD_BUG_ON` guards on descriptor sizes / offsets in `rtl8196e_ring.c`. Verified non-issue list above already noted size assertions; this pass formalises them at compile time. |
| ETH-005 | **already documented** | Same as F17 ("HW DMA registers programmed with KSEG1 virtual addresses"). Intentional — no refactor. |
| ETH-006 | **fixed in 2.4** | DT `member-ports` / `untag-ports` now bounded to the 9-port HW window (`0x1ff`) and `untag ⊆ member` enforced. |
| ETH-007 | not fixed | `rtl8196e_debug` is opt-in via module param (off by default). No driver-side change needed. |
| ETH-008 | **already rejected** | Same proposal as F13 (`wback_inv → inv` on RX rearm). F13 was tested on HW 2026-04-23 in the F11+F13+F15 bundle and **rejected** (-47 Mb/s RX, -23 Mb/s TX). Re-test only F13 alone in a dedicated branch with the iperf suite as gate, per the F11+F13+F15 section above. |

Net result: 4 patches (A/C/D/B) shipped in driver `2.4` (commits
`7705b70`, `420fb6c`, `518daae`, `9cbb34c`). 2 findings rejected by
construction (ETH-005, ETH-008 — already covered above), 2 deferred
(ETH-003 needs HW characterisation, ETH-007 is intentional opt-in).

## Third-pass audit (2026-05-03) — driver 2.4 → 2.5

A third independent audit was run against driver `2.4`. It produced 6
findings labelled `ETHDRV-001..006`. Each was validated against the
current source before action.

| New ID | Severity | Status | Notes |
|--------|----------|--------|-------|
| ETHDRV-001 | high | **fixed in 2.5** | `realtek,syscon` lookup in `rtl8196e_probe()` previously masked all errors (including `-EPROBE_DEFER`) by setting `priv->hw.syscon = NULL`. Now propagates `-EPROBE_DEFER` and fails with `dev_err()` on any other error. Prevents a partially-muxed `eth0` from being created when the syscon node is missing or not yet ready. |
| ETHDRV-002 | medium | **fixed in 2.5** | RX `rearm_drop` and `rearm_bad` paths handed descriptors back to the ASIC without resetting `ph_len`, `ph_flags`, `mb->m_*`. Field reset moved out of the nominal path into the shared `rearm:` label so all three exits (nominal, drop, bad-length) leave HW a canonical descriptor view. |
| ETHDRV-003 | medium | **case D — deferred, no software fix without bench regression** | HW characterisation done 2026-05-03 (see "ETHDRV-003 characterisation" below): bad UDP csums DO reach userland under the blanket scheme. Three patch variants tried in a follow-up session (see "ETHDRV-003 follow-up — case D conclusion" below); all regress vs baseline once otbr-agent is stopped (the real bench-noise source). SDK V3.4.7.3 reading confirmed there is no HW-only fix: CSCR bits 1-2 gate port-to-port forwarding, not the CPU trap path; only AcceptL2Err exists at the CPU port. The legacy SDK ships an equivalent CPU-side software drop in its `rx_poll`; our 6.18 rewrite omitted it. Re-opening ETHDRV-003 would require accepting a measurable single-stream TCP TX cost (case-B variant: -13 Mbit/s) — judged not worth it for v3.4.1 given the limited UDP-IPv4 attack surface on this gateway (DHCP client only). Driver version stays at 2.5. |
| ETHDRV-004 | medium | **mitigated in 2.5** | C bitfields in `rtl_pktHdr` / `rtl_mBuf` are endianness-sensitive. No refactor (large risk on a HW-validated driver), but added a compile-time `#error` in `rtl8196e_desc.h` that fires unless `__BIG_ENDIAN_BITFIELD` is defined. Blocks accidental LE builds. |
| ETHDRV-005 | low | intentional | Module params `0644` and runtime-tunable `kick_threshold` are root-only debug knobs by design. |
| ETHDRV-006 | informational | intentional | Same as ETH-005 / F17 — KSEG1 virtual addresses programmed into HW DMA registers. Required by this SoC. |

Net result for v3.4.1: 2 functional patches (ETHDRV-001, ETHDRV-002)
plus one compile-time guard (ETHDRV-004 mitigation), all shipped in
driver `2.5`. ETHDRV-003 was characterised in this cycle, the gated-csum
patch attempted then reverted before commit after the standard bench
showed a -22 Mbit/s TCP RX regression — the production driver retains
the v3.4.0 csum behaviour (blanket `CHECKSUM_UNNECESSARY`) until a
finer fix is benched. Driver version stays at 2.5 across the cycle
(convention: one bump per release, not per patch). Validation gate:
`scripts/test_rtl8196e_eth.sh` baselines (TCP RX ~93.9 Mbit/s, TCP TX
~71 Mbit/s, retrans ~0) — regression threshold >1 Mbit/s sustained.

### ETHDRV-003 characterisation (2026-05-03)

The audit V2 deferred ETHDRV-003 pending an empirical answer to a
single question: *does the switch ASIC silently drop frames with bad
TCP/UDP checksums before they reach the CPU ring, or does it forward
them?* If the answer is "drop", the blanket `CHECKSUM_UNNECESSARY`
is safe; if "forward", corrupted L4 payloads reach userland sockets.

**Test design** — exploit the kernel's ICMP port-unreachable response
to a UDP packet sent to a closed port: ICMP is emitted only if the
packet is processed by the IP+UDP stack. If the driver wrongly says
`CHECKSUM_UNNECESSARY` for a bad-csum frame, the UDP layer skips
verification and replies with ICMP. The ICMP body conveniently
contains the inner IP+UDP header as it was on the RX wire, which lets
us verify whether the switch rewrote the checksum.

Test script `/tmp/test_rx_checksum.py` (committed only as a session
artefact, not shipped in-tree) sends 4 × 5 packets:

| Test | IP csum | UDP csum | Result |
|------|---------|----------|--------|
| 1    | good    | good     | 5/5 ICMP back, inner_udp_csum=0xbc45 (control) |
| 2    | bad     | good     | 4/5 ICMP back, **inner_ip_csum=0x2b33** — host kernel re-summed IP despite IP_HDRINCL |
| 3    | good    | **bad**  | 3/5 ICMP back, **inner_udp_csum=0xdead preserved** |
| 4    | bad     | bad      | 4/5 ICMP back, inner_udp_csum=0xdead preserved |

Gateway `/proc/net/snmp` deltas: `Udp.NoPorts +20`, `Udp.InCsumErrors
+0`. All 20 frames reached the UDP layer; none were rejected by csum
verification.

**Conclusion** — the switch ASIC forwards bad-UDP-csum frames as-is
to the CPU ring. It does not rewrite the checksum (the `0xdead` value
sent on the wire arrived embedded in the ICMP response unchanged), so
it must be marking `ph_flags & CSUM_TCPUDP_OK = 0` for these frames.
The driver was ignoring this bit and unconditionally claiming the
csum was good.

**Patch attempt (during this release cycle) — gated CHECKSUM_UNNECESSARY** —
`CHECKSUM_UNNECESSARY` only when `ph_flags & CSUM_TCPUDP_OK`; fall
back to `CHECKSUM_NONE` otherwise. The patch validated correctly on
the synthetic test (test 3 went from 3/5 ICMP to 0/5, `InCsumErrors`
incremented as expected) but the standard regression bench showed a
**-22 Mbit/s TCP RX regression** (93.8 → 71.8) plus 3407 RX errors on
eth0 over the 9-test suite. Working hypothesis: the HW switch ASIC
sets `CSUM_TCPUDP_OK` only for *some* L4 frames — likely UDP only,
despite the bit's name — so the gated form pushed *all* TCP RX
traffic through software csum verify and saturated the single CPU
core.

**Patch reverted before commit.** The blanket `CHECKSUM_UNNECESSARY`
remains in v3.4.1 (driver 2.5), preserving the 93.8 Mbit/s TCP RX
baseline. The underlying L4-csum exposure remains; pursuing a robust
fix needs:

1. Per-frame instrumentation of `ph_flags` on a real TCP RX bench
   (e.g. `pr_info` for the first N TCP-IPv4 RX packets after a
   sysfs trigger), to confirm whether `CSUM_TCPUDP_OK` is ever set
   for TCP frames on this ASIC.
2. If only UDP triggers the bit: a finer driver split (`ip_summed
   = CHECKSUM_NONE` only for `skb->protocol == htons(ETH_P_IP)` and
   `ip_hdr->protocol == IPPROTO_UDP` and bit clear; `CHECKSUM_UNNECESSARY`
   everywhere else). Cost confined to bad-UDP path only.
3. Re-run the synthetic bad-csum test plus the standard bench before
   merging.

Tracking: re-open ETHDRV-003 in a follow-up session with the
instrumentation patch as the first deliverable.

### ETHDRV-003 follow-up — case D conclusion (2026-05-03)

The follow-up session ran the per-frame instrumentation called for above
(`/sys/class/net/eth0/rx_csum_dbg` writable counter + per-RX
`netdev_info` log of `ph_flags / iph_proto / ip_ok / tcpudp_ok`),
captured 100 packets of mixed traffic, then bench-walked three patch
variants. None pass the v3.4.0 baseline (TCP RX 93.9 Mbit/s, TCP TX 70.9
Mbit/s, eth0 errors 0) so ETHDRV-003 stays unfixed in v3.4.1, classified
**case D** in the brief's taxonomy.

**Instrumentation snapshot (low-rate, mixed traffic).** Of 100 RX
frames captured: 81 UDP, 17 TCP, 2 ARP. Every frame had
`CSUM_TCPUDP_OK = 1` and `CSUM_IP_OK = 1`. Initial reading: case A
("bit reliable for everything"). This turned out to be a sampling
artefact at low rate — at sustained line rate the bit clears for some
frames (see simple-gate bench below).

**Bench matrix (clean kernel, OTBR stopped, full
`scripts/test_rtl8196e_eth.sh` suite, single port direct cable):**

| Variant | TCP RX | TCP TX | Stress 5 min | rx_errors |
|---|---:|---:|---:|---:|
| HEAD baseline (blanket UNNECESSARY) | 93.9 | 70.9 | 94.0 | 0 |
| case-B: gate UDP-IPv4 only on bit, read iph->protocol | 93.0 | 58.2 | 91.7 | 386 |
| case-B reordered: ph_flags-first, skip iph for bit-set | 60.9 | 56.6 | 62.5 | ~3300 |
| simple gate: ph_flags only, no iph (drv-2.6 equivalent) | 72.2 | 73.4 | 68.3 | 1778 |

Per-variant cost analysis:

  * **case-B (UDP-IPv4 narrowing).** The closest analogue to the legacy
    SDK behaviour, but narrowed to UDP-IPv4 to leave the TCP hot path
    untouched. The unconditional `iph->protocol` read after
    `dma_cache_inv(skb->data, len)` adds a cache miss on every IP
    packet's RX and slows ACK turnaround during single-stream TCP TX
    enough to lose 13 Mbit/s. The +386 rx_errors are HW-FIFO-overflow
    `len=0` descriptors during the UDP_100M overload test only;
    sustainable rates produce 0.
  * **case-B reordered (ph_flags first, then iph).** Theoretically
    strictly better because TCP good (bit set) short-circuits before
    `iph` is touched. Empirically much worse single-stream
    (-33 RX, -32 Stress); multi-stream TCP unaffected (94+). Working
    hypothesis: the unconditional `iph->protocol` read in the un-reordered
    variant acts as an implicit cacheline prefetch that helps
    `napi_gro_receive` and the IP/TCP routing layer downstream;
    skipping it leaves a cache miss for the next consumer. This
    platform has no `pref` instruction (MIPS-1) so the prefetch cannot
    be expressed explicitly. Discarded.
  * **simple gate (ph_flags only, no iph read).** Identical in spirit
    to the originally-attempted driver-2.6 patch. Reproduces the same
    -22 Mbit/s TCP RX regression with OTBR stopped (so OTBR was not
    the root cause back then either) plus 1778 rx_errors. This
    confirms the brief's case A reading was an under-sampling artefact:
    under sustained line-rate TCP RX, `CSUM_TCPUDP_OK` is not always
    set on TCP frames; the simple gate then routes them through
    `CHECKSUM_NONE` and the kernel's software csum verify saturates
    the CPU. `CSUM_TCPUDP_OK` is reliable for UDP good, not for TCP
    good under load.

**Root cause and SDK reading.** Reading the official Realtek SDK
V3.4.7.3 (`rtl819x/linux-2.6.30/include/asm-rlx/rtl865x/rtl865xc_asicregs.h:1098-1106`)
gives the canonical RTL8196E CSCR layout:

```
bit 0  L2CRCErrAllow    (port-to-port L2 CRC error allow)
bit 1  L3ChkSErrAllow   (port-to-port L3 csum error allow)
bit 2  L4ChkSErrAllow   (port-to-port L4 csum error allow)
bit 3  AcceptL2Err      (CPU port L2 CRC error allow, default 1) [RTL_8196C/8198/819XD/8196E only]
bit 4  EnL3ChkCal       (enable L3 csum recalculation on forward)
bit 5  EnL4ChkCal       (enable L4 csum recalculation on forward)
```

Two findings:

  1. **The "ALLOW_L3/L4" bits we already clear in `rtl8196e_hw_init()`
     gate port-to-port forwarding only.** There is no equivalent
     "Accept-to-CPU L3/L4" bit on RTL8196E — only `AcceptL2Err` is
     exposed at bit 3, and only for L2. The CPU rx ring therefore
     receives bad-csum L3/L4 frames regardless of CSCR. The legacy
     SDK is aware of this: `rtl819x/.../rtl865xc_swNic.c:517-518`
     drops bad-csum frames in software at rx_poll time, before
     handing skb up the stack:

     ```c
     if ((pPkthdr->ph_flags & (CSUM_TCPUDP_OK | CSUM_IP_OK)) !=
         (CSUM_TCPUDP_OK | CSUM_IP_OK)) {
         RTL_ETH_NIC_DROP_RX_PKT_RESTART;
         goto get_next;
     }
     ```

     Our 6.18 rewrite omitted this drop. That is the structural cause
     of ETHDRV-003. Adding it back is what every patch variant above
     attempts, and pays the bench cost of the extra read in the hot
     path.
  2. **Our `rtl8196e_regs.h` inherited the wrong bit positions for the
     recalc bits** from the legacy `rtl819x/.../AsicDriver/rtl865x_asicL2.c`
     defines (`EN_ETHER_L3/L4_CHKSUM_REC` at bits 3-4). On RTL8196E
     these positions are `AcceptL2Err` and `EnL3ChkCal` per the SDK.
     Our driver does not set the recalc bits, so this is doc errata
     only — fixed in the same commit by aligning the names and
     positions in `rtl8196e_regs.h` to the SDK V3.4.7.3 truth, with
     compatibility aliases kept for the unchanged `rtl8196e_hw.c`
     clear path.

**Bench-environment finding (operational).** Through the seven bench
iterations of this session, results were unstable until otbr-agent
(the on-device Thread Border Router, listening on eth0 for IPv6
border routing and mDNS) was stopped. With OTBR running:

  - bench results varied by ±5-15 Mbit/s on TCP TX between consecutive
    runs of the *same* kernel,
  - rx_errors counts swung wildly per run.

With `/userdata/etc/init.d/S70otbr stop` issued before each bench:

  - results stabilise to within ~1 Mbit/s,
  - rx_errors becomes deterministic per kernel binary.

This is now the canonical procedure for `scripts/test_rtl8196e_eth.sh`
on a gateway with OTBR enabled (i.e. v3.4.x default). Stop OTBR
before benching; re-arm with `/userdata/etc/init.d/S70otbr start` after.
The bench script itself is unchanged.

**Threat surface review.** The exposure ETHDRV-003 documents — bad
UDP-csum frames reaching userland sockets — has limited reach on
this gateway:

  - `otbr-agent` is the dominant UDP listener but speaks UDP/IPv6
    (CoAP, Thread mesh signalling); the case-B fix only catches
    UDP-IPv4. Out of scope.
  - DHCP client receives UDP-IPv4 from the DHCP server: this is the
    only path where a bad-csum UDP frame would reach a kernel-side
    handler. DHCP has its own transaction-ID/lease-time validation
    on top, and the attacker must be on-link.
  - No other UDP-IPv4 listening service in the stock rootfs (no
    SNMP, no syslog/UDP, no mDNS/Avahi).

The single-stream TCP TX scenario where the case-B fix costs
13 Mbit/s does not match this gateway's actual workload (Zigbee
gateway: TCP TX ≪ 5 Mbit/s in normal use). The benchmark is more
adversarial than the production load.

Net result: the brief's case-D conclusion is the right call for
v3.4.1. ETHDRV-003 stays documented and re-openable. The
follow-up session leaves four artefacts in the tree:

  * this AUDIT.md section,
  * the matching CHANGELOG.md v3.4.1 entry,
  * the `rtl8196e_regs.h` CSCR doc errata + compatibility aliases,
  * a memory note in `MEMORY.md` flagging "stop OTBR before
    `test_rtl8196e_eth.sh`" as a benching gotcha.

