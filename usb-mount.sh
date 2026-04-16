#!/usr/bin/env bash
# ============================================================
#  usb-mount.sh — CoreConduit USB Mount Utility
#  Detects, mounts, and reports USB storage devices on Pi
# ============================================================

set -euo pipefail

# ── Config ───────────────────────────────────────────────────
MOUNT_BASE="/mnt/usb"          # Parent directory for all USB mounts
MOUNT_USER="${SUDO_USER:-pi}"  # Owner of mount point (falls back to 'pi')

# ── Colors ───────────────────────────────────────────────────
GRN='\033[0;32m'; YLW='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

header()  { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${RST}"; }
ok()      { echo -e "  ${GRN}✔${RST}  $*"; }
warn()    { echo -e "  ${YLW}⚠${RST}  $*"; }
err()     { echo -e "  ${RED}✘${RST}  $*"; }
info()    { echo -e "  ${CYN}→${RST}  $*"; }

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (use sudo).${RST}"
    exit 1
fi

header "USB Storage Mount Utility"

# ── Discover USB block devices ───────────────────────────────
# lsblk: find partitions whose transport is 'usb' or whose parent is usb
mapfile -t USB_DEVS < <(
    lsblk -J -o NAME,TRAN,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
def walk(nodes, parent_tran=''):
    for n in nodes:
        tran = n.get('tran') or parent_tran
        if n.get('type') == 'part' and tran == 'usb' and n.get('fstype'):
            results.append(json.dumps(n))
        walk(n.get('children') or [], tran)
walk(data.get('blockdevices', []))
print('\n'.join(results))
"
)

if [[ ${#USB_DEVS[@]} -eq 0 ]]; then
    warn "No USB storage partitions found."
    info "Make sure the device is plugged in and has a recognised filesystem."
    exit 0
fi

info "Found ${#USB_DEVS[@]} USB partition(s)."

# ── Process each partition ───────────────────────────────────
MOUNTED_COUNT=0
SKIPPED_COUNT=0

for dev_json in "${USB_DEVS[@]}"; do
    NAME=$(echo "$dev_json"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])")
    FSTYPE=$(echo "$dev_json"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fstype') or '')")
    LABEL=$(echo "$dev_json"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('label') or '')")
    SIZE=$(echo "$dev_json"     | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('size') or '')")
    EXISTING=$(echo "$dev_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mountpoint') or '')")

    DEV_PATH="/dev/${NAME}"

    # Use label as mount folder name, fall back to device name
    FOLDER="${LABEL:-$NAME}"
    # Sanitise: strip spaces and slashes
    FOLDER="${FOLDER// /_}"
    FOLDER="${FOLDER//\//_}"
    MOUNT_POINT="${MOUNT_BASE}/${FOLDER}"

    echo ""
    header "Device: ${DEV_PATH}  (${FSTYPE}, ${SIZE})"

    # Already mounted?
    if [[ -n "$EXISTING" ]]; then
        warn "Already mounted at: ${EXISTING}"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Unsupported / swap / LVM?
    case "$FSTYPE" in
        vfat|exfat|ntfs|ext4|ext3|ext2|btrfs|xfs|f2fs)
            info "Filesystem: ${FSTYPE}" ;;
        swap|LVM2_member|"")
            warn "Skipping ${DEV_PATH} — unsupported/no filesystem (${FSTYPE:-none})."
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue ;;
        *)
            warn "Filesystem '${FSTYPE}' may not be fully supported — attempting anyway." ;;
    esac

    # Create mount point
    mkdir -p "$MOUNT_POINT"
    chown "${MOUNT_USER}:${MOUNT_USER}" "$MOUNT_POINT" 2>/dev/null || true

    # Build mount options per filesystem
    MOUNT_OPTS=""
    case "$FSTYPE" in
        vfat|exfat)
            MOUNT_OPTS="-o uid=$(id -u "$MOUNT_USER"),gid=$(id -g "$MOUNT_USER"),umask=022,utf8" ;;
        ntfs)
            # ntfs-3g gives read/write on Pi
            if command -v ntfs-3g &>/dev/null; then
                MOUNT_OPTS="-t ntfs-3g -o uid=$(id -u "$MOUNT_USER"),gid=$(id -g "$MOUNT_USER"),umask=022"
            else
                warn "ntfs-3g not installed — mounting read-only. Run: sudo apt install ntfs-3g"
                MOUNT_OPTS="-o ro"
            fi ;;
        ext4|ext3|ext2)
            MOUNT_OPTS="" ;;   # kernel defaults are fine
        *)
            MOUNT_OPTS="" ;;
    esac

    # Mount
    # shellcheck disable=SC2086
    if mount $MOUNT_OPTS "$DEV_PATH" "$MOUNT_POINT" 2>/tmp/usb_mount_err; then
        DISPLAY_NAME="${LABEL:-${NAME}}"
        ok "Mounted:  ${BLD}${DISPLAY_NAME}${RST}"
        info "Device:   ${DEV_PATH}"
        info "Mount:    ${MOUNT_POINT}"
        info "Size:     ${SIZE}"
        MOUNTED_COUNT=$((MOUNTED_COUNT + 1))
    else
        ERR_MSG=$(cat /tmp/usb_mount_err)
        err "Failed to mount ${DEV_PATH}: ${ERR_MSG}"
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    fi
done

# ── Summary ──────────────────────────────────────────────────
echo ""
header "Summary"
ok "Mounted:  ${MOUNTED_COUNT} device(s)"
[[ $SKIPPED_COUNT -gt 0 ]] && warn "Skipped:  ${SKIPPED_COUNT} device(s)"
echo ""
info "To unmount later:  sudo umount ${MOUNT_BASE}/<name>"
info "Or unmount all:    sudo umount ${MOUNT_BASE}/*"
echo ""
