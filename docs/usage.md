# Usage Guide

## Quick Start

```bash
# Mount USB drives
sudo ./usb-mount.sh

# Check system health
sudo ./rpi-healthbench.sh

# Optimize Ollama for Pi 5
sudo ./ollama-pi5-optimize.sh
```

---

## usb-mount.sh

### Purpose
Automatically detect and mount all USB storage devices with appropriate filesystem-specific options.

### Usage

```bash
sudo ./usb-mount.sh
```

### Output

```
━━━  USB Storage Mount Utility  ━━━

  →  Found 2 USB partition(s).

━━━  Device: /dev/sda1  (ntfs, 465.8G)  ━━━

  →  Filesystem: ntfs
  ✔  Mounted:  My Passport
  →  Device:   /dev/sda1
  →  Mount:    /mnt/usb/My_Passport
  →  Size:     465.8G

━━━  Summary  ━━━
  ✔  Mounted:  2 device(s)
  →  To unmount later:  sudo umount /mnt/usb/<name>
  →  Or unmount all:    sudo umount /mnt/usb/*
```

### mount Points

All USB devices are mounted under `/mnt/usb/<label>` where `<label>` is:
- The partition's label (if set)
- The device name (if no label)
- Sanitized (spaces→underscores, slashes removed)

### Filesystem Handling

| Filesystem | Mount Options | Notes |
|------------|---------------|-------|
| vfat | `uid=,gid=,umask=022,utf8` | Windows compatible |
| exfat | `uid=,gid=,umask=022,utf8` | Large file support |
| ntfs | `ntfs-3g` or `ro` | Requires ntfs-3g for write |
| ext4 | defaults | Native Linux |
| ext3/ext2 | defaults | Legacy Linux |
| btrfs/xfs/f2fs | defaults | Modern Linux filesystems |

### Error Cases

| Error | Message | Solution |
|-------|---------|----------|
| Not root | "This script must be run as root" | Use `sudo` |
| No devices | "No USB storage partitions found" | Plug in USB device |
| Mount fail | "Failed to mount: <error>" | Check filesystem integrity |
| Unsupported | "may not be fully supported" | May need additional packages |

### Unmounting

```bash
# Unmount single device
sudo umount /mnt/usb/My_Passport

# Unmount all
sudo umount /mnt/usb/*

# Clean mount directory
sudo rmdir /mnt/usb/*
```

---

## rpi-healthbench.sh

### Purpose
Comprehensive Raspberry Pi health benchmark with automatic remediation suggestions.

### Usage

```bash
# Normal check (read-only)
sudo ./rpi-healthbench.sh

# Preview fixes
sudo ./rpi-healthbench.sh --dry-run

# Apply fixes automatically
sudo ./rpi-healthbench.sh --fix
```

### Check Categories

#### 1. Hardware Identity
- Model detection (Pi 2/3/4/5/Zero)
- OS version
- Kernel version
- Uptime
- RAM total

#### 2. Voltage & Throttle Status
Decodes throttle register bits:

| Bit | Meaning |
|-----|---------|
| 0 | Under-voltage detected |
| 1 | ARM frequency capped |
| 2 | Currently throttled |
| 3 | Soft temperature limit active |
| 16 | [HISTORY] Under-voltage occurred |
| 17 | [HISTORY] ARM freq capped |
| 18 | [HISTORY] Throttling occurred |
| 19 | [HISTORY] Soft temp limit hit |

#### 3. CPU Frequency
- Current clock speed
- Configured limit
- Governor status

#### 4. CPU Benchmark
4-thread sysbench with prime numbers (max 5000):

```bash
sysbench --threads=4 cpu --cpu-max-prime=5000 run
```

#### 5. Thread Benchmark
4-thread context switching test:

```bash
sysbench --threads=4 threads --thread-yields=4000 --thread-locks=6 run
```

#### 6. Memory Bandwidth
Sequential memory access (3GB):

```bash
sysbench --threads=4 memory --memory-block-size=1K \
       --memory-total-size=3G --memory-access-mode=seq run
```

#### 7. Disk Detection & Tests

**Detection** checks in order:
1. `/dev/nvme0n1` (NVMe SSD)
2. `/dev/sda` (USB SSD/HDD)
3. `/dev/mmcblk0` (SD card/eMMC)

**hdparm read** measures cached + buffered reads

**dd write** measures write speed (512MB):

```bash
dd if=/dev/zero of=/tmp/rpi_bench_XXXXXX.tmp bs=1M count=512 conv=fsync
```

**dd read** measures read speed (cache flushed):

```bash
echo 3 > /proc/sys/vm/drop_caches
dd if=/tmp/rpi_bench_XXXXXX.tmp of=/dev/null bs=1M
```

#### 8. SD Card Clock
Checks if SD card is running at optimal speed:
- SDR104/UHS: 100+ MHz
- High Speed: 50+ MHz
- Normal Speed: 25 MHz
- Low Speed: <25 MHz

#### 9. Filesystem Health
- Disk usage per mount (warn at 85%, fail at 95%)
- Inode usage per mount (warn at 80%, fail at 95%)
- Filesystem state (clean/dirty)
- Mount count vs max
- Last fsck date
- SD card wear level (life_time/pre_eol_info)

#### 10. Log Analysis
Scans for patterns:
- Kernel panic
- OOM killer
- Filesystem remounted RO
- I/O errors
- ext4 errors
- MMC/SD errors
- Under-voltage warnings
- Kernel oops
- USB disconnects
- Temperature throttling
- Task hung
- Segfaults
- BTRFS errors
- Watchdog timeouts

### Thresholds (by Model)

| Model | CPU Min | Temp Warn | Temp Fail |
|-------|---------|-----------|-----------|
| Pi 5 | 2400 MHz | 70°C | 80°C |
| Pi 4 | 1800 MHz | 70°C | 80°C |
| Pi 3B+ | 1400 MHz | 68°C | 78°C |
| Pi 3 | 1200 MHz | 68°C | 78°C |
| Pi 2 | 900 MHz | 68°C | 78°C |
| Zero 2 | 1000 MHz | 68°C | 78°C |
| Zero | 1000 MHz | 68°C | 78°C |

### Disk Thresholds (by Storage)

| Storage | Read MB/s | Write MB/s |
|---------|-----------|------------|
| NVMe SSD | 180 | 100 |
| USB Storage | 90 | 50 |
| SD Card | 40 | 15 |

### Output Format

```
▶ HARDWARE IDENTITY
──────────────────────────────────────────────────────────────────────────────
  Model   : Raspberry Pi 5 Model B Rev 1.0
  Hostname: pi5
  OS      : Debian GNU/Linux 12 (bookworm)
  Kernel  : 6.1.21-v8+
  Uptime  : up 2 days, 4 hours, 32 minutes
  RAM     : 8192 MB

▶ VOLTAGE & THROTTLE STATUS
──────────────────────────────────────────────────────────────────────────────
  [INFO] Raw throttled value: 0x0
  [PASS] No active throttle or voltage issues
...
```

### Remediation Suggestions

If issues detected:

```bash
# Preview without applying
sudo ./rpi-healthbench.sh --dry-run

# Apply fixes
sudo ./rpi-healthbench.sh --fix
```

Fixes may include:
- Set CPU governor to performance (persist)
- Enable active fan control in config.txt
- Switch I/O scheduler to mq-deadline (SD cards)
- Increase SD read-ahead buffer
- Reduce swappiness
- Add noatime to mounts (SD wear reduction)
- Increase swap size
- Clean apt cache, journal logs, thumbnails
- Schedule filesystem check on next reboot

---

## ollama-pi5-optimize.sh

### Purpose
Optimize system configuration for running Ollama LLM inference on Raspberry Pi 5.

### Usage

```bash
# Preview changes
sudo ./ollama-pi5-optimize.sh --dry-run

# Apply optimizations
sudo ./post install --fix ollama-pi5-optimize.sh
sudo ./ollama-pi5-optimize.sh
```

### RAM Tier Detection

| RAM | GPU Memory | Recommended Models |
|-----|------------|-------------------|
| ≤4GB | 128 MB | tinyllama:1.1b, phi3:mini-4k, gemma:2b |
| ≤8GB | 256 MB | llama3.2:3b, mistral:7b, phi3:medium-4k |
| >8GB | 512 MB | llama3.1:8b, mistral:7b-q8, deepseek-r1:8b |

### Optimizations Applied

#### 1. Ollama Systemd Override

Creates `/etc/systemd/system/ollama.service.d/pi5-performance.conf`:

```ini
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_THREADS=4"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MODELS=/mnt/usb/SSD/ollama-models"  # if SSD detected
```

Then runs:
```bash
systemctl daemon-reload
systemctl restart ollama
```

#### 2. GPU Memory Split

Sets `gpu_mem=` in `/boot/firmware/config.txt` (or `/boot/config.txt` on older systems).

| RAM | GPU Memory |
|-----|------------|
| ≤4GB | 128 MB |
| ≤8GB | 256 MB |
| >8GB | 512 MB |

Requires reboot to take effect.

#### 3. CPU Governor

Creates `/etc/systemd/system/cpu-performance.service`:

```ini
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Also sets immediately and writes to rc.local for persistence.

#### 4. Swap Optimization

- Disables `dphys-swapfile` (disk swap hurts LLM performance)
- Configures `zramswap` with:
  - Algorithm: lz4
  - Size: 50% of RAM
- Sets `vm.swappiness=10` via sysctl

#### 5. SSD Model Path (if detected)

If USB SSD detected, sets `OLLAMA_MODELS` to SSD mount point for faster model loading.

### Optional Overclock

Prompt:
```
Enable overclock (2800 MHz)? Requires reboot + active cooling [y/N]:
```

If enabled, adds to config.txt:
```
over_voltage=6
arm_freq=2800
```

**Warning**: Requires active cooling (fan) on Pi 5.

### Post-Run Steps

After running the script:
1. **Reboot** to apply GPU memory split
2. **Verify Ollama**: `ollama run tinyllama 'Hello!'`
3. **Check models**: `ollama list`

### Expected Results

| Configuration | Token Throughput |
|---------------|------------------|
| Default | 5-10 tokens/sec |
| With optimizations | 20-40 tokens/sec |
| With overclock + SSD | 40-60 tokens/sec |

---

## Common Tasks

### Set up new Pi for LLM inference

```bash
# 1. Run health check
sudo ./rpi-healthbench.sh --fix

# 2. Optimize for Ollama
sudo ./ollama-pi5-optimize.sh

# 3. Reboot
sudo reboot

# 4. Verify and load model
ollama run tinyllama:1.1b-q4_0
```

### Daily health monitoring

```bash
# Quick health check (10 minutes)
sudo ./rpi-healthbench.sh
```

### Mount USB backup drive

```bash
sudo ./usb-mount.sh
# Backups now at /mnt/usb/<label>/
```
