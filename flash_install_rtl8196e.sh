#!/bin/bash
# flash_install_rtl8196e.sh — Install custom firmware on Lidl Silvercrest Gateway
#
# Builds a fullflash.bin image (via build_fullflash.sh) and flashes it to the
# gateway via TFTP.
#
# Two modes of operation, chosen by one capability test — is `boothold`
# runnable over SSH:
#   - Upgrade: pass LINUX_IP — the script connects via SSH, saves user config,
#     and (if boothold is present) reboots straight into the bootloader. If
#     boothold is absent (Tuya / very old firmware), it guides you to serial.
#   - First flash: no argument — the gateway must already be in bootloader mode
#     (<RealTek> prompt via serial ESC).
#
# Interactive vs non-interactive:
#   By default the script is interactive: it prompts for backup, flash
#   confirmation, and (on first flash) network/radio configuration.
#   Pass -y (or CONFIRM=y) for non-interactive mode — all prompts are skipped.
#   This enables unattended remote upgrades over SSH.
#   Note: if auto-flash fails and falls back to manual FLW, a terminal (tty)
#   is still required for serial console guidance.
#
# The flash step is the same regardless of firmware version — no version parsing.
# Auto-flash vs manual FLW is decided behaviourally, in two cheap observations:
#   - Pre-upload ICMP: Tuya / pre-ICMP stock bootloaders never answer ping and
#     have no auto-flash → go straight to guided FLW (no wait). Every custom
#     bootloader answers ping, so this alone can't tell auto-flash from not.
#   - Post-upload ICMP: a bootloader WITH auto-flash starts writing 16 MiB the
#     instant the upload lands and, being single-threaded, stops answering ping
#     for the duration; one WITHOUT keeps answering at its idle prompt. So "ping
#     was up and goes silent" = auto-flash in progress → wait for the UDP:9999 OK.
#     "Stays up" = no auto-flash → guided FLW. Decided in seconds, not minutes.
#
# Prerequisites:
#   - Ethernet cable between host and gateway
#   - tftp-hpa client installed (sudo apt install tftp-hpa)
#   - Serial console (3.3V UART, 38400 8N1, line wrap ON) — needed to enter
#     bootloader mode (first flash / Tuya) and for older bootloaders that
#     require manual flash commands (the script will guide you)
#
# Usage: ./flash_install_rtl8196e.sh [-y] [LINUX_IP] [--help]
#
# Arguments:
#   LINUX_IP        Gateway IP when running Linux (for upgrade with config save)
#                   Omit for first-time flash (gateway must be in bootloader mode)
#
# Options:
#   -y, --yes       Non-interactive mode: skip all confirmation prompts
#   --boot-ip <IP>  Bootloader-mode / TFTP server IP. Overrides the BOOT_IP
#                   env var (precedence: flag > env > default 192.168.1.6).
#
# Environment variables:
#   BOOT_IP      - Gateway IP in bootloader (default: 192.168.1.6). On the
#                  boothold path it is handed to the bootloader (V2.7+) so the
#                  gateway comes up on this address in download mode.
#                  The --boot-ip flag takes precedence when both are given.
#   SSH_TIMEOUT  - TCP probe timeout in seconds (default: 2)
#   SSH_PASSWORD - Root password for non-interactive auth (CI / no tty).
#                  When set, the first ssh call is fed via sshpass and the
#                  ControlMaster takes over for the rest. Requires sshpass
#                  (sudo apt install sshpass).
#   NET_MODE     - "static" or "dhcp" (skip network prompt)
#   IPADDR       - Static IP address (default: 192.168.1.88)
#   NETMASK      - Netmask (default: 255.255.255.0)
#   GATEWAY      - Default gateway (default: 192.168.1.1)
#   RADIO_MODE   - "zigbee" or "thread" (skip radio prompt)
#   CONFIRM      - Set to "y" to skip confirmation prompts (same as -y)
#
# J. Nilo - March 2026

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Hardened SSH helpers — see lib/ssh.sh.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/ssh.sh"
LINUX_IP=""
FW_VERSION=""
# Default entry mode. Overridden to "auto" only when a running Linux exposes
# boothold over SSH; stays "manual" for the already-at-bootloader-prompt path
# (no LINUX_IP), where LINUX_RUNNING is empty and the block below is skipped.
ENTRY="manual"
# Set to 1 once the running gateway's user config has been saved for
# re-injection into the new image (upgrade path). Drives the flash-warning
# wording so we don't claim "all data will be replaced" when it is preserved.
CONFIG_SAVED=""
# BOOT_IP precedence: --boot-ip flag > BOOT_IP env > default. The flag is
# captured into BOOT_IP_FLAG during parsing and applied after the loop.
BOOT_IP="${BOOT_IP:-192.168.1.6}"
BOOT_IP_FLAG=""
SSH_TIMEOUT="${SSH_TIMEOUT:-2}"

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) CONFIRM="y" ;;
        --help|-h)
            echo "Usage: $0 [-y] [--boot-ip <IP|host>] [LINUX_IP]"
            echo ""
            echo "Installs custom firmware on the Lidl Silvercrest Gateway."
            echo ""
            echo "Arguments:"
            echo "  LINUX_IP         Gateway IP when running Linux (upgrade with config save)"
            echo "                   Omit for first-time flash (gateway must be in bootloader)"
            echo ""
            echo "Options:"
            echo "  -y, --yes        Non-interactive mode (skip all prompts)"
            echo "  --boot-ip <IP|host>  Bootloader-mode / TFTP server IP (overrides BOOT_IP"
            echo "                   env; default: 192.168.1.6). A hostname is resolved host-side."
            echo ""
            echo "Environment: BOOT_IP (default: 192.168.1.6), SSH_TIMEOUT,"
            echo "  SSH_PASSWORD (sshpass), NET_MODE, RADIO_MODE, CONFIRM,"
            echo "  IPADDR, NETMASK, GATEWAY (network default gateway)"
            exit 0
            ;;
        --boot-ip)
            shift
            [ $# -gt 0 ] || { echo "Error: --boot-ip requires an argument." >&2; exit 1; }
            BOOT_IP_FLAG="$1"
            ;;
        --boot-ip=*) BOOT_IP_FLAG="${1#*=}" ;;
        --*) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
        *)
            if [ -n "$LINUX_IP" ]; then
                echo "Error: unexpected argument '$1' (LINUX_IP already set to '$LINUX_IP')." >&2
                exit 1
            fi
            LINUX_IP="$1"
            ;;
    esac
    shift
done

# Apply --boot-ip override (flag > env > default), resolving a hostname if one
# was given (the on-device boothold/bootloader need a literal IPv4 — resolve
# host-side). A dotted-quad passes through unchanged.
[ -n "$BOOT_IP_FLAG" ] && BOOT_IP="$BOOT_IP_FLAG"
if BOOT_IP_RESOLVED="$(resolve_ipv4 "$BOOT_IP")"; then
    [ "$BOOT_IP_RESOLVED" != "$BOOT_IP" ] && echo "Resolved BOOT_IP '$BOOT_IP' -> $BOOT_IP_RESOLVED"
    BOOT_IP="$BOOT_IP_RESOLVED"
else
    echo "Error: invalid BOOT_IP '$BOOT_IP' (not a dotted-quad IPv4, and could" >&2
    echo "not be resolved as a hostname)." >&2
    exit 1
fi

# --- prerequisites -----------------------------------------------------------
# Fail fast with a single actionable message before building or touching the
# gateway. Users who didn't go through 1-Build-Environment/install_deps.sh
# would otherwise hit silent failures deep in the build (issue #84).

missing_pkgs=()
check_cmd() {
    # $1 = command to probe, $2 = apt package to install if missing
    command -v "$1" >/dev/null 2>&1 || missing_pkgs+=("$2")
}

check_cmd fakeroot     fakeroot
check_cmd gcc          gcc
check_cmd mkfs.jffs2   mtd-utils
check_cmd mksquashfs   squashfs-tools

# sshpass is only required when SSH_PASSWORD is set (non-interactive
# password auth — see lib/ssh.sh:ssh_prime_with_password).
[ -n "${SSH_PASSWORD:-}" ] && check_cmd sshpass sshpass

# tftp-hpa: the BSD tftp client is also called "tftp" but lacks the -c flag.
# Capture --help output first — tftp-hpa exits 64 on --help, which under
# `set -o pipefail` would make the piped grep inherit that non-zero code
# even on a successful match.
tftp_help="$(tftp --help 2>&1 || true)"
if ! command -v tftp >/dev/null 2>&1 \
   || ! echo "$tftp_help" | grep -q -- '-c'; then
    missing_pkgs+=("tftp-hpa")
fi

if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    echo "Error: missing build/flash prerequisites: ${missing_pkgs[*]}" >&2
    echo "Install them with:" >&2
    echo "  sudo apt install ${missing_pkgs[*]}" >&2
    exit 1
fi

# Resolve IFACE for BOOT_IP and require L2 reachability — the bootloader's TFTP
# server only answers on the same L2 segment. Sets IFACE on success; exits with
# an actionable hint when the host has no interface in the bootloader's subnet.
require_boot_l2() {
    IFACE="$(ip route get "$BOOT_IP" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [ -z "${IFACE:-}" ]; then
        echo "Error: cannot determine outgoing interface to ${BOOT_IP}." >&2
        exit 1
    fi
    if ip route get "$BOOT_IP" 2>/dev/null | grep -qE '\svia\s'; then
        echo "Error: ${BOOT_IP} is reached via a gateway (routed). The bootloader's" >&2
        echo "TFTP server only answers on the same L2 segment." >&2
        echo "" >&2
        echo "Add a secondary address on the interface that faces the gateway, e.g.:" >&2
        echo "    sudo ip addr add 192.168.1.10/24 dev <iface>" >&2
        echo "" >&2
        echo "Then re-run this script. Remove the address afterwards with 'ip addr del'." >&2
        exit 1
    fi
}

# Build fullflash.bin, sanity-check it, and ask the final confirmation.
# On the upgrade (auto) path this runs while Linux is still up — BEFORE boothold —
# so the slow image build does not happen with the gateway stranded in the
# bootloader, and an abort (or a build failure) leaves Linux untouched. On a
# first flash / manual entry it runs at the convergence point (gateway already in
# the bootloader), where build_fullflash.sh prompts interactively for IP/radio.
# Sets GW_HINT_IP, FULLFLASH and the IMAGE_READY guard so the convergence point
# does not build a second time.
build_image_and_confirm() {
    # In the upgrade path SKELETON_DIR is already exported (with saved config
    # from the running gateway). On a first flash the parent has no SKEL_WORK
    # yet, but build_fullflash.sh will prompt for IP/radio and write into
    # whatever SKELETON_DIR points to. We pre-create one here so the parent
    # can read back the chosen IPADDR for the post-install hint, instead of
    # losing it when build_fullflash's own mktemp dir is reaped.
    if [ -z "${SKELETON_DIR:-}" ]; then
        USERDATA_SKEL="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton"
        SKEL_WORK=$(mktemp -d)
        cp -a "$USERDATA_SKEL/." "$SKEL_WORK/"
        trap 'rm -rf "$SKEL_WORK"; ssh_cleanup_multiplex' EXIT
        export SKELETON_DIR="$SKEL_WORK"
    fi

    # Called with -q (quiet): only config → lines, errors, and a summary are
    # shown. Run build_fullflash.sh without -q for full verbose output.
    "${SCRIPT_DIR}/build_fullflash.sh" -q

    # Read back the IP the user picked (or kept) so the post-install hints
    # show the right address. Fall back to LINUX_IP (upgrade path) or the
    # default for first-time installs that chose DHCP / left the default.
    if [ -z "${IPADDR:-}" ] && [ -f "${SKELETON_DIR}/etc/eth0.conf" ]; then
        IPADDR=$(awk -F= '$1=="IPADDR"{print $2; exit}' "${SKELETON_DIR}/etc/eth0.conf" 2>/dev/null || true)
    fi
    GW_HINT_IP="${LINUX_IP:-${IPADDR:-192.168.1.88}}"

    FULLFLASH="${SCRIPT_DIR}/fullflash.bin"
    if [ ! -f "$FULLFLASH" ]; then
        echo "Error: fullflash.bin not found after build." >&2
        exit 1
    fi

    FLASH_SIZE=$((16 * 1024 * 1024))
    ff_size=$(stat -c%s "$FULLFLASH")
    if [ "$ff_size" -ne "$FLASH_SIZE" ]; then
        echo "Error: fullflash.bin is ${ff_size} bytes (expected ${FLASH_SIZE})." >&2
        exit 1
    fi

    # --- confirm: last chance to abort. Skipped in non-interactive mode. ------
    echo ""
    echo "WARNING: This will overwrite the ENTIRE flash chip (16 MiB)."
    if [ "$CONFIG_SAVED" = "1" ]; then
        echo "Your saved config (network, password, SSH keys, radio, Thread"
        echo "credentials) will be re-injected; everything else is replaced."
    else
        echo "All data on the gateway will be replaced."
    fi
    echo ""
    echo "  Image:  fullflash.bin ($(md5sum "$FULLFLASH" | awk '{print $1}'))"
    echo "  Target: ${BOOT_IP}"
    echo ""

    if [ "${CONFIRM:-}" != "y" ]; then
        read -r -p "Proceed? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "Aborted."; exit 0; fi
    fi

    IMAGE_READY=1
}


# --- detect gateway state (early — fail fast before building) ----------------
# If LINUX_IP is provided, probe SSH to determine firmware type and save config.
# Otherwise, check if bootloader is already reachable at BOOT_IP.

echo ""
echo "========================================="
echo "  FIRMWARE INSTALLATION"
echo "========================================="
echo ""

# Detect gateway state based on whether LINUX_IP was provided.
# BOOT_IP L2 reachability is enforced lazily — at boothold time on the upgrade
# path, immediately on the bootloader path — so backup-via-SSH still works
# from a routed network where the host has no 192.168.1.0/24 interface yet.
LINUX_RUNNING=""
if [ -n "$LINUX_IP" ]; then
    echo "Probing SSH on ${LINUX_IP}..."
    if timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/22" 2>/dev/null; then
        LINUX_RUNNING="${LINUX_IP}:22"
    elif timeout "$SSH_TIMEOUT" bash -c "echo >/dev/tcp/$LINUX_IP/2333" 2>/dev/null; then
        LINUX_RUNNING="${LINUX_IP}:2333"
    else
        echo "Error: cannot reach gateway at ${LINUX_IP} (no SSH on port 22 or 2333)." >&2
        echo "Check the Ethernet cable, or if the gateway is already in bootloader mode" >&2
        echo "re-run without argument:  $0" >&2
        exit 1
    fi
fi

if [ -n "$LINUX_RUNNING" ]; then
    fw_host="${LINUX_RUNNING%%:*}"
    fw_port="${LINUX_RUNNING##*:}"
    echo "Linux detected at ${fw_host}:${fw_port}."

    if [ "$fw_port" = "2333" ]; then
        # Port 2333 is exclusively Tuya/Lidl stock — no boothold, no SSH needed.
        ENTRY="manual"
    else
        # Port 22 — could be custom or Tuya. SSH in and test the one capability
        # that decides automated entry: can we run `boothold`?
        # StrictHostKeyChecking=no + /dev/null known_hosts is intentional:
        # this workflow installs custom firmware over Tuya stock, so the
        # gateway's host key changes legitimately mid-flow. ControlMaster
        # comes from lib/ssh.sh — first call prompts for password/passphrase
        # at most once, the rest of the back-to-back commands ride the
        # same channel.
        FI_SSH_OPTS=(
            "${SSH_HARDEN_OPTS[@]}"
            -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null
            -p "$fw_port"
        )
        FI_SSH_TARGET="root@${fw_host}"

        # Open the ControlMaster up-front using SSH_PASSWORD if provided
        # (no-op when SSH_PASSWORD is unset — ssh's tty prompt handles it).
        if ! ssh_prime_with_password "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET"; then
            exit 1
        fi

        # Verify SSH access before proceeding
        if ! ssh_retry "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET" "true" 2>/dev/null; then
            echo "Error: SSH authentication failed." >&2
            exit 1
        fi

        # boothold present = custom firmware we can warm-reboot into the
        # bootloader. Absent = Tuya, or custom too old to have boothold
        # (pre-v1.1.0) — either way, automated entry is impossible.
        if ssh_retry "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET" "command -v boothold" >/dev/null 2>&1; then
            ENTRY="auto"
        else
            ENTRY="manual"
        fi
    fi
    echo "Entry mode: ${ENTRY}"

    # Read firmware version early — used ONLY for the v2→v3 radio.conf pre-seed
    # decision below (no longer gates the flash). Requires the SSH channel, so
    # only meaningful on the automated (boothold) path.
    if [ "$ENTRY" = "auto" ]; then
        fw_ver_line=$(ssh_retry "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET" "head -1 /userdata/etc/version" 2>/dev/null || true)
        if [[ "$fw_ver_line" =~ v([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            FW_VERSION="${BASH_REMATCH[1]}"
            echo "Firmware version: v${FW_VERSION}"
        fi
    fi

    # --- propose backup (while Linux is still running) -----------------------
    # Skipped in non-interactive mode (-y / CONFIRM=y)
    if [ "${CONFIRM:-}" != "y" ]; then
        echo ""
        echo "It is recommended to back up the flash before installing."
        read -r -p "Run backup_gateway.sh now? [y/N] " do_backup
        if [[ "$do_backup" =~ ^[yY]$ ]]; then
            "${SCRIPT_DIR}/backup_gateway.sh" --linux-ip "$fw_host" --boot-ip "$BOOT_IP"
            echo ""
        fi
    fi

    if [ "$ENTRY" = "auto" ]; then
        # Save user config before reboot (will be injected into userdata)
        # Only user-configurable files — not init scripts or system files
        # Work on a temporary copy of the skeleton — never modify the original
        USERDATA_SKEL="${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton"
        SKEL_WORK=$(mktemp -d)
        cp -a "$USERDATA_SKEL/." "$SKEL_WORK/"
        trap 'rm -rf "$SKEL_WORK"; ssh_cleanup_multiplex' EXIT
        export SKELETON_DIR="$SKEL_WORK"

        SAVE_TAR=$(mktemp)
        SAVE_FILES="etc/eth0.conf etc/mac_address etc/radio.conf etc/leds.conf etc/passwd etc/TZ etc/hostname etc/dropbear ssh thread"
        ssh_retry "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET" \
            "tar cf - -C /userdata $SAVE_FILES 2>/dev/null" > "$SAVE_TAR" 2>/dev/null || true
        if [ -s "$SAVE_TAR" ]; then
            tar xf "$SAVE_TAR" -C "$SKEL_WORK" 2>/dev/null || true
            echo "Gateway config saved."
            CONFIG_SAVED=1
            export NET_MODE="skip"
            export RADIO_MODE="skip"
        fi
        rm -f "$SAVE_TAR"

        # v2 → v3 migration: pre-v3.0 firmware shipped serialgateway and
        # had no /userdata/etc/radio.conf — the EFR32-side baud was hard-
        # coded to 115200 (NCP-UART-HW @ 115200 was the v2.x default). The
        # v3.x in-kernel UART bridge defaults to 460800 when radio.conf is
        # missing, which leaves the host bridge mismatched against the
        # still-115200 chip until either the chip is reflashed or
        # radio.conf is created. Pre-seed the full v3.x radio.conf
        # describing the known v2.x state (NCP @ 115200) so the new
        # userdata boots into a working state AND a future reader can
        # tell what's on the chip without probing.
        if [ -n "${FW_VERSION:-}" ] && [ "${FW_VERSION%%.*}" -lt 3 ] \
           && [ ! -f "${SKEL_WORK}/etc/radio.conf" ]; then
            echo "Pre-seeding radio.conf for v${FW_VERSION} → v3.x migration (FIRMWARE=ncp @ 115200)."
            echo "  ↑ Default v2.x assumption. Cancel now (Ctrl-C) and run on the gateway:"
            echo "      cat > /userdata/etc/radio.conf  (with FIRMWARE=otrcp/rcp/... if non-default),"
            echo "    then re-run this script — your radio.conf will be preserved."
            echo "  See 3-Main-SoC-Realtek-RTL8196E/35-Migration/README.md for the recipes."
            cat > "${SKEL_WORK}/etc/radio.conf" <<EOF
FIRMWARE=ncp
FIRMWARE_BAUD=115200
EOF
        fi

        # Confirm the host can TFTP to the bootloader before tipping the
        # gateway into bootloader mode — failing after boothold leaves the
        # gateway stranded at ${BOOT_IP} with the user scrambling to fix
        # their network mid-flow.
        require_boot_l2

        # Build the image (and take the final confirmation) NOW, while Linux is
        # still up. The saved config is already in SKELETON_DIR, so the image
        # has everything it needs — no bootloader state is required. Doing it
        # here means the slow build no longer runs with the gateway stranded in
        # the bootloader; only the TFTP upload + flash write block the gateway.
        # An abort at the confirmation (or a build failure) leaves Linux intact.
        build_image_and_confirm

        # Pass BOOT_IP to boothold (V2.7+): the bootloader comes up on that
        # address in download mode, so a non-default BOOT_IP needs no serial
        # IPCONFIG. Older boothold ignores the argument (stays at 192.168.1.6).
        echo "Sending boothold + reboot..."
        ssh_retry "${FI_SSH_OPTS[@]}" "$FI_SSH_TARGET" "boothold \"$BOOT_IP\" && reboot" 2>/dev/null || true
        # Close ControlMaster socket — gateway is rebooting, no point waiting
        # for ControlPersist to expire on a connection that's already dead.
        ssh_cleanup_multiplex
    else
        echo ""
        echo "No boothold on this firmware (Tuya stock, or custom older than v1.1.0)."
        echo "Cannot enter the bootloader automatically. To enter bootloader mode:"
        echo "  - Connect serial console (3.3V UART, 38400 8N1, line wrap ON)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0"
        echo ""
        exit 1
    fi

    # --- wait for bootloader after boothold + reboot -------------------------
    # Two-phase wait to avoid ARP false positives (Linux responds to ARP for
    # BOOT_IP via ARP flux while still shutting down).

    # Phase 1: wait for SSH to go down (Linux is shutting down)
    echo "Waiting for shutdown..."
    tries=0
    while [ $tries -lt 15 ]; do
        if ! timeout 1 bash -c "echo >/dev/tcp/$fw_host/$fw_port" 2>/dev/null; then
            break
        fi
        sleep 1
        tries=$((tries + 1))
    done

    # Phase 2: wait for bootloader ARP
    echo "Waiting for bootloader at ${BOOT_IP}..."
    tries=0
    while [ $tries -lt 30 ]; do
        ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
        bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
        sleep 1
        nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
        if echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
            break
        fi
        tries=$((tries + 1))
    done

    if [ $tries -ge 30 ]; then
        echo "Error: bootloader not detected after boothold." >&2
        exit 1
    fi
else
    # No LINUX_IP given — check if bootloader is reachable via ARP
    echo "Checking for bootloader at ${BOOT_IP}..."
    require_boot_l2
    ip neigh del "$BOOT_IP" dev "$IFACE" 2>/dev/null || true
    bash -c "echo -n X >/dev/udp/$BOOT_IP/69" 2>/dev/null || true
    sleep 0.3

    nei="$(ip neigh show "$BOOT_IP" dev "$IFACE" 2>/dev/null || true)"
    if ! echo "$nei" | grep -Eqi 'lladdr [0-9a-f]{2}(:[0-9a-f]{2}){5}'; then
        echo "Gateway not detected at ${BOOT_IP}."
        echo ""
        echo "For first-time flash:"
        echo "  - Connect serial console (3.3V UART, 38400 8N1, line wrap ON)"
        echo "  - Power cycle the gateway"
        echo "  - Press ESC repeatedly during boot to get the <RealTek> prompt"
        echo "  - Then re-run:  $0"
        echo ""
        echo "For upgrade (with config save):"
        echo "  - Run:  $0 <LINUX_IP>   (e.g. $0 192.168.1.88)"
        echo ""
        exit 1
    fi

    # ARP resolved — but is it really bootloader? Probe TFTP to confirm.
    # Use PUT (not GET): bootloader ACKs a WRQ immediately, but silently drops
    # RRQ (prints error on serial only, no UDP response → tftp-hpa hangs).
    # timeout returns 124 when no TFTP server responds; 0 when bootloader ACKs.
    probe_file=$(mktemp)
    echo -n X > "$probe_file"
    probe_rc=0
    timeout 3 tftp -m binary "$BOOT_IP" -c put "$probe_file" >/dev/null 2>&1 || probe_rc=$?
    rm -f "$probe_file"
    if [ $probe_rc -eq 124 ]; then
        echo "Device at ${BOOT_IP} is not in bootloader mode (no TFTP server)."
        echo "If the gateway is running Linux, run:  $0 <LINUX_IP>"
        exit 1
    fi

    # ARP resolved + TFTP responding = bootloader.
    echo ""
    echo "Bootloader detected. No config files/variables will be imported"
    echo "You will be prompted for network and radio settings."
    if [ "${CONFIRM:-}" != "y" ]; then
        read -r -p "Proceed? [y/N] " r
        if [[ ! "$r" =~ ^[yY]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

echo "Bootloader detected at ${BOOT_IP}."

# If we reached bootloader without going through Linux (no backup opportunity),
# warn the user.
if [ -z "$LINUX_RUNNING" ] && [ "${CONFIRM:-}" != "y" ]; then
    echo ""
    echo "WARNING: No backup was made. To back up first, boot the gateway"
    echo "into Linux and run:  ./backup_gateway.sh"
    echo ""
    read -r -p "Continue without backup? [y/N] " do_continue
    if [[ ! "$do_continue" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# --- build fullflash.bin + final confirmation --------------------------------
# On the upgrade (auto) path this already ran before boothold, while Linux was
# still up — IMAGE_READY is set, so we skip it here. On a first flash / manual
# entry the gateway is already in the bootloader and nothing was built yet:
# build now (build_fullflash.sh prompts interactively for IP/radio).
[ "${IMAGE_READY:-}" = "1" ] || build_image_and_confirm

# --- flash --------------------------------------------------------------------
# One shared routine, no firmware-version logic. We always upload the image (both
# auto-flash and manual FLW need it in RAM), then decide behaviourally — never by
# version, and independent of how we entered (ENTRY):
#   - pre-upload ICMP silent  → Tuya / pre-v2 stock, no auto-flash → guided FLW.
#   - pre-upload ICMP up, then goes silent post-upload → auto-flash is writing the
#     16 MiB (single-threaded, can't answer ICMP) → wait for the UDP:9999 OK.
#   - pre-upload ICMP up, stays up post-upload → custom bootloader without
#     auto-flash (e.g. old v1.x) → guided FLW. Decided in seconds, no dead wait.

check_tftp_error() {
    echo "$1" | grep -qiE \
        "error|timeout|timed out|refused|failed|unknown host|access denied|disk full|illegal|not connected|unknown transfer"
}

# Manual FLW guidance — the uploaded image is already in RAM at 0x80500000; the
# user finishes on the serial console. Interactive by design: show the FLW step,
# WAIT for the user to confirm it completed, then propose the reboot. On "no" we
# exit non-zero so the caller never prints "INSTALLATION COMPLETE" for a flash
# that did not happen. Requires an interactive terminal.
manual_flw_guidance() {
    if [ ! -t 0 ]; then
        echo "Error: manual flash requires an interactive terminal (serial console guidance)." >&2
        exit 1
    fi
    echo ""
    echo "NOTE: a custom (V2.x) bootloader may auto-flash the uploaded image on its"
    echo "own even when this script could not detect it. If the gateway reboots and"
    echo "comes back on SSH within ~2 min (ssh root@${GW_HINT_IP:-<gateway>}), the"
    echo "flash already succeeded — you are done and can ignore the steps below."
    echo "The steps below are only for stock/older bootloaders that need a manual FLW."
    echo ""
    echo "The image is in the gateway's RAM at 0x80500000. On the serial console"
    echo "(38400 8N1, line wrap ON), type:"
    echo ""
    echo "    FLW 0 80500000 01000000"
    echo ""
    echo "Answer (Y)es when prompted, then wait ~2 min until the <RealTek> prompt returns."
    echo ""
    read -r -p "Has the flash completed (FLW back at the <RealTek> prompt)? [y/N] " flw_done
    if [[ ! "$flw_done" =~ ^[yY]$ ]]; then
        echo ""
        echo "Manual FLW not confirmed. Before doing anything else, check whether the"
        echo "gateway auto-flashed on its own (custom V2.x bootloaders often do, even"
        echo "when this script could not detect it):"
        echo ""
        echo "    ping ${GW_HINT_IP:-<gateway>}      # wait up to ~2 min for the reboot"
        echo "    ssh root@${GW_HINT_IP:-<gateway>}"
        echo ""
        echo "If it answers, the flash already succeeded — you are done."
        echo "If it stays unreachable, nothing was written: the image is still in RAM"
        echo "at 0x80500000 — run the FLW above and reboot manually (J BFC00000), or"
        echo "re-run this script to upload again."
        exit 1
    fi
    echo ""
    echo "Reboot into the new firmware — on the serial console type:"
    echo ""
    echo "    J BFC00000"
    echo ""
    echo "(or do a hard reset / power cycle)."
}

# Listen for the bootloader's UDP:9999 OK/FAIL notification, echoing the result
# (empty on timeout or when nc is absent). The flash write takes ~2 min, so the
# ceiling is 180s — but the listener breaks the instant data arrives, so a real
# auto-flash is never penalised by the full timeout.
wait_for_autoflash_result() {
    command -v nc >/dev/null 2>&1 || return 0
    local notify_file nc_pid
    notify_file=$(mktemp)
    (timeout 180 nc -u -l -p 9999 > "$notify_file" 2>/dev/null) &
    nc_pid=$!
    while kill -0 "$nc_pid" 2>/dev/null; do
        [ -s "$notify_file" ] && { kill "$nc_pid" 2>/dev/null; break; }
        sleep 0.5
    done
    wait "$nc_pid" 2>/dev/null || true
    tr -d '\0' < "$notify_file" 2>/dev/null || true
    rm -f "$notify_file"
}

# Behavioural auto-flash probe (call right after the upload). An auto-flash
# bootloader is now busy writing 16 MiB to SPI NOR and stops answering ICMP; one
# without auto-flash is idle at its prompt and keeps answering. Poll ICMP for a
# short window: two consecutive misses = it went silent = auto-flash in progress
# (return 0). If it stays reachable for the whole window, there is no auto-flash
# (return 1). Window ~15s — long enough to clear any brief post-upload checksum
# pause before the write, short enough to not be a "dead wait".
autoflash_in_progress() {
    local fails=0 i
    for i in $(seq 1 15); do
        if ping -c 1 -W 1 "$BOOT_IP" >/dev/null 2>&1; then
            fails=0
            sleep 1
        else
            fails=$((fails + 1))
            [ "$fails" -ge 2 ] && return 0
        fi
    done
    return 1
}

print_complete() {
    echo ""
    echo "========================================="
    echo "  INSTALLATION COMPLETE"
    echo "========================================="
    echo ""
    echo "SSH: root@${GW_HINT_IP}:22 (no password) in ~30 seconds."
}

# Pre-upload capability probe (see note at top of file): Tuya / pre-ICMP stock
# bootloaders never answer ping and have no auto-flash.
#
# Poll instead of a single probe: the custom V2.5 bootloader can take a second
# or two after ARP resolves before its ICMP responder is up. Now that the image
# is built *before* boothold, this runs immediately after bootloader detection
# with no multi-minute build to mask that settle window — a single ping flaked
# to "no" and wrongly picked the manual path even though auto-flash worked
# (issue: gateway re-flashed fine but the script printed manual FLW guidance).
# A genuine Tuya / pre-v2 bootloader never answers, so the window is exhausted
# (~10 s, only on the already-manual path) and we correctly fall through.
PING_BEFORE=no
for _i in $(seq 1 10); do
    if ping -c 1 -W 1 "$BOOT_IP" >/dev/null 2>&1; then
        PING_BEFORE=yes
        break
    fi
done

echo ""
echo "Uploading fullflash.bin via TFTP (16 MiB)..."
cd "$SCRIPT_DIR"
out=$(timeout 300 tftp -m binary "$BOOT_IP" -c put fullflash.bin 2>&1) || true
if check_tftp_error "$out"; then
    echo "Error: TFTP transfer failed: $out" >&2
    exit 1
fi
echo "Upload OK."

if [ "$PING_BEFORE" = "no" ]; then
    echo "Bootloader does not answer ICMP (Tuya / pre-v2) — manual flash required."
    manual_flw_guidance
    print_complete
elif autoflash_in_progress; then
    echo "Auto-flash detected (bootloader is writing flash). Waiting for confirmation..."
    result="$(wait_for_autoflash_result)"
    if [ "$result" = "OK" ]; then
        echo ""
        echo "Flash write succeeded. The gateway will reboot automatically."
        print_complete
    else
        if [ "$result" = "FAIL" ]; then
            echo "Auto-flash reported FAIL. Falling back to manual flash."
        else
            echo "No auto-flash confirmation. Falling back to manual flash."
        fi
        manual_flw_guidance
        print_complete
    fi
else
    echo "Bootloader stayed responsive after upload — no auto-flash. Manual flash required."
    manual_flw_guidance
    print_complete
fi

# --- Restore skeleton if we injected gateway config -------------------------
# --- EFR32 radio firmware info -----------------------------------------------
if [ "${CONFIRM:-}" != "y" ] && [ -t 0 ]; then
    RADIO="${NET_MODE:+${RADIO_MODE}}"
    # Determine radio mode from radio.conf if not set by env
    if [ -z "$RADIO" ]; then
        RADIO_CONF="${SKEL_WORK:-${SCRIPT_DIR}/3-Main-SoC-Realtek-RTL8196E/34-Userdata/skeleton}/etc/radio.conf"
        if [ -f "$RADIO_CONF" ] && grep -q '^MODE=otbr' "$RADIO_CONF" 2>/dev/null; then
            RADIO="thread"
        else
            RADIO="zigbee"
        fi
    fi

    echo ""
    echo "Make sure the EFR32 radio firmware matches your configuration."
    echo "Compatible firmware(s):"
    echo ""
    if [ "$RADIO" = "thread" ]; then
        echo "  ot-rcp.gbl             — OpenThread RCP (required for OTBR)"
        echo ""
        echo "Flash with:  ./flash_efr32.sh -g ${GW_HINT_IP} otrcp"
    else
        echo "  ncp-uart-hw-7.5.1.gbl  — Zigbee NCP for in-kernel UART bridge + Z2M"
        echo "  rcp-uart-802154.gbl    — Zigbee RCP for cpcd + zigbeed (Docker)"
        echo "  z3-router-7.5.1.gbl    — Zigbee 3.0 Router (standalone, no coordinator)"
        echo ""
        echo "Flash with:  ./flash_efr32.sh -g ${GW_HINT_IP} ncp   (or rcp / router)"
    fi
fi
