# usb-mount.sh Component Documentation

## Overview

Detects USB storage partitions and mounts them with filesystem-appropriate options.

## Core Functions

### `header()`
```bash
header()  { echo -e "\n${BLD}${CYN}━━━  $*  ━━━${RST}"; }
```
Prints section headers with colored decoration.

### `ok()`, `warn()`, `err()`, `info()`
Message level functions with color coding:
- `ok()` - Green checkmark (✔)
- `warn()` - Yellow warning (⚠)
- `err()` - Red X (✘)
- `info()` - Cyan arrow (→)

### `mapfile -t USB_DEVS < <(...)`

JSON parsing pipeline using Python:
```bash
lsblk -J -o NAME,TRAN,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT \
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
```

**Logic**:
1. Parse `lsblk -J` JSON output
2. Walk device tree recursively
3. Track transport type through parent chain
4. Filter for partitions with transport='usb' and fstype set
5. Output JSON per matching partition

### `run()`

Dry-run wrapper (from ollama-pi5-optimize.sh, similar pattern):
```bash
run() {
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $*"
  else
    "$@"
  fi
}
```

## Data Structures

### USB_DEVS Array
Each element is a JSON string with fields:
- `name` - Device/partition name (e.g., "sda1")
- `tran` - Transport type ("usb")
- `type` - "part" (partition) or "disk"
- `fstype` - Filesystem type (vfat, ext4, etc.)
- `label` - Partition label (may be empty)
- `size` - Size string (e.g., "465.8G")
- `mountpoint` - Existing mount (if any)

### FSTYPE Handling

| FSTYPE | Action | Mount Options |
|--------|--------|---------------|
| vfat, exfat | Mount | `uid=,gid=,umask=022,utf8` |
| ntfs | Mount (try ntfs-3g, fallback ro) | -t ntfs-3g or `ro` |
| ext4, ext3, ext2 | Mount | defaults |
| btrfs, xfs, f2fs | Mount | defaults |
| swap, LVM2_member | Skip | - |
| (empty) | Skip | - |

## Key Paths

| Path | Purpose |
|------|---------|
| `/mnt/usb/` | Base mount directory |
| `/mnt/usb/<label>` | Per-device mount point |
| `/proc/partitions` | Block device info (indirect) |

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Not root | Exit with error, suggest `sudo` |
| No USB devices | Warn, exit 0 |
| Unsupported FSTYPE | Warn, attempt mount anyway |
| Mount failure | Error message, show `/tmp/usb_mount_err`, rmdir mount point |
| Already mounted | Skip, increment SKIPPED_COUNT |

## Output Format

```
━━━  Device: /dev/sda1  (ntfs, 465.8G)  ━━━
  → Filesystem: ntfs
  ✔ Mounted:  My Passport
  → Device:   /dev/sda1
  → Mount:    /mnt/usb/My_Passport
  → Size:     465.8G
```

## Testing

```bash
# Simulate USB device (requires loop device setup)
sudo losetup -fP /path/to/usb-image.img
sudo ./usb-mount.sh
```

## Integration Points

- **config.txt**: None (no modifications)
- **systemd**: None (no services)
- **Persistent state**: None (all mounts in /tmp/usb_mount_err if fails)

## Limitations

1. Requires `lsblk -J` (util-linux ≥2.27)
2. Python 3 required for JSON parsing
3. NTFS write requires ntfs-3g package
4. Doesn't handle LUKS-encrypted partitions
