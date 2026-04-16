# Tech Stack Documentation

## Shell & Language

| Component | Version | Purpose |
|-----------|---------|---------|
| Bash | 5.0+ | Main scripting language |
| ShellCheck | Recommended | Linting (not included) |
| shfmt | Recommended | Formatting (not included) |

### Bash Features Used

- `set -euo pipefail` - Strict error handling
- `process substitution` - `< <(command)` for iteration
- `arrays` - `declare -a` for collections
- `parameter expansion` - `${var:-default}`, `${var// /_}`
- `arithmetic` - `(( expr ))` for math
- `here-documents` - `<< 'EOF'` for multi-line output

## Core Utilities

### System Information

| Tool | Package | Purpose |
|------|---------|---------|
| `/proc/device-tree/model` | - | Hardware model detection |
| `/proc/meminfo` | - | Memory information |
| `uname -r` | Coreutils | Kernel version |
| `hostname` | Coreutils | Hostname |
| `uptime -p` | Coreutils | System uptime |

### Hardware Monitoring

| Tool | Package | Purpose |
|------|---------|---------|
| `vcgencmd` | vcgencmd | Raspberry Pi firmware commands |
| `dmesg` | kmod | Kernel ring buffer |
| `journalctl` | systemd | System logs |

### Benchmarking Tools

| Tool | Package | Purpose |
|------|---------|---------|
| `sysbench` | sysbench | CPU, memory, thread benchmarks |
| `hdparm` | hdparm | Disk read benchmarks |
| `dd` | coreutils | Disk write tests |
| `mount` | util-linux | Mount management |
| `umount` | util-linux | Unmount management |

### Filesystem Tools

| Tool | Package | Purpose |
|------|---------|---------|
| `tune2fs` | e2fsprogs | ext4 filesystem parameters |
| `findmnt` | util-linux | Mount point lookup |
| `df` | coreutils | Disk usage |

## Filesystems Supported

### Read/Write Support

| Filesystem | Read | Write | Notes |
|------------|------|-------|-------|
| ext4 | Yes | Yes | Native Linux |
| ext3 | Yes | Yes | Legacy Linux |
| ext2 | Yes | Yes | No journal |
| xfs | Yes | Yes | Large file support |
| btrfs | Yes | Yes | Snapshot support |
| f2fs | Yes | Yes | Flash-optimized |
| ntfs | Yes | Yes | Requires ntfs-3g |
| exFAT | Yes | Yes | FAT with large file support |
| FAT32 | Yes | Yes | Max 4GB files |

### mount(8) Options

| Option | Filesystems | Purpose |
|--------|-------------|---------|
| `uid=` | vfat, exfat, ntfs | Owner for files |
| `gid=` | vfat, exfat, ntfs | Group for files |
| `umask=022` | vfat, exfat, ntfs | Permissions mask |
| `utf8` | vfat, exfat | UTF-8 filename encoding |
| `noatime` | ext4, xfs, btrfs | No access time updates |

## Raspberry Pi Specific Components

### Device Tree

```
/proc/device-tree/model      # Hardware model string
/proc/device-tree/memory@0   # Memory region info
```

### Firmware Commands (vcgencmd)

| Command | Output | Purpose |
|---------|--------|---------|
| `measure_temp` | `temp=XX.X°C` | CPU temperature |
| `measure_clock arm` | `frequencyXX=XXXXXXX` | CPU clock |
| `measure_volts core` | `volts=XX.XX` | Core voltage |
| `get_throttled` | `throttled=0xX` | Throttle status |
| `get_config int` | `arm_freq=X` | Config settings |

### System Files

| Path | Purpose |
|------|---------|
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | CPU frequency governor |
| `/sys/class/mmc_host/mmc0/mmc0:0001/name` | SD card model |
| `/sys/class/mmc_host/mmc0/mmc0:0001/speed_class` | SD card speed class |
| `/sys/block/mmcblk0/device/life_time` | SD card wear |
| `/sys/kernel/debug/mmc0/ios` | SD card clock settings |

## Package Dependencies

### Required (install if missing)

| Package | Purpose |
|---------|---------|
| `bc` | Floating-point calculations |
| `hdparm` | Disk read benchmarks |
| `sysbench` | CPU/memory benchmarks |

### Optional (improves functionality)

| Package | Purpose |
|---------|---------|
| `ntfs-3g` | Read/write NTFS filesystems |
| `zram-tools` | Compressed swap in RAM |
| `f2fs-tools` | F2FS filesystem support |

## Python Usage (indirect)

Python 3 is used for JSON parsing in `usb-mount.sh`:

```bash
lsblk -J -o NAME,TRAN,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT \
| python3 -c "import sys,json; # JSON filtering logic"
```

This enables structured parsing of `lsblk -J` output, which bash cannot natively parse.

## Version Tracking

```bash
# Check Bash version
bash --version | head -1

# Check sysbench
sysbench --version | head -1

# Check vcgencmd (on Pi)
vcgencmd version
```
