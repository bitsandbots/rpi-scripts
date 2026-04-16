# Architecture Documentation

## High-Level Design

rpi-scripts follows a **utility-first** architecture pattern. Each script is:
- **Self-contained**: No external dependencies beyond standard Linux utilities
- **Stateless**: No persistent configuration (except when making system changes)
- **Idempotent**: Safe to run multiple times without side effects
- **ReadOnly-first**: Supports `--dry-run` mode for preview

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    User Layer                               │
│  (CLI: --help, --fix, --dry-run, positional arguments)      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                  Controller Layer                           │
│  - Argument parsing                                         │
│  - Root privilege check                                     │
│  - Dry-run mode flag                                        │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              Detection & Analysis Layer                     │
│  - Hardware model detection (/proc/device-tree)            │
│  - System capability checks                                 │
│  - Dependency detection                                     │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              Benchmark/Test Layer                           │
│  - sysbench (CPU, memory, threads)                         │
│  - hdparm (disk read)                                       │
│  - dd (disk write)                                          │
│  - vcgencmd (temp, clock, throttle)                         │
│  - journalctl/dmesg (log analysis)                          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              Remediation Layer                              │
│  - Auto-fix when --fix enabled                             │
│  - File modifications (config.txt, systemd, fstab)         │
│  - Service management (systemctl)                           │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                   Report Layer                              │
│  - Pass/Warn/Fail aggregation                              │
│  - Summary generation                                       │
│  - Recommended actions                                      │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow Details

### rpi-healthbench.sh Flow

```
Entry Point (line 724)
    ↓
[1] Hardware Identity
    - detect_model() → /proc/device-tree/model
    - Detect config.txt location
    - set_thresholds() → Model-specific baseline
    ↓
[2] Voltage & Throttle
    - vcgencmd get_throttled → decode bits
    - ACTIVE mask (0xFFFF) vs HISTORY mask
    ↓
[3] CPU Frequency
    - vcgencmd measure_clock arm
    - governor read from sysfs
    ↓
[4] CPU Benchmark
    - set_governor("performance")
    - sysbench --threads=4 cpu prime
    ↓
[5] Thread Benchmark
    - sysbench --threads=4 threads
    ↓
[6] Memory Bandwidth
    - sysbench --threads=4 memory seq 3G
    ↓
[7] Disk Tests
    - Detect primary block device (sda, nvme0n1, mmcblk0)
    - set_disk_thresholds() → Adjust for storage type
    - hdparm -tT → buffered read
    - dd if=/dev/zero → write test
    - dd if=file → read test (cache flushed)
    ↓
[8] Filesystem Health
    - df -h → usage per mount
    - df -i → inode usage
    - tune2fs -l → filesystem state
    - life_time/pre_eol_info → SD wear
    ↓
[9] Log Analysis
    - Scan journalctl -b 0 and -b -1
    - Pattern matching against LOG_PATTERNS
    - dmesg fallback for critical errors
    ↓
[10] Health Report
    - Aggregate PASS/WARN/FAIL counts
    - Generate summary
    - If ANY_ISSUE: remediation suggestions
```

### usb-mount.sh Flow

```
Entry Point (line 29)
    ↓
Root check (line 24)
    ↓
USB_DEVS=( lsblk -J | python3 filter )
    ↓
for each USB partition:
    ↓
    Parse JSON for: NAME, FSTYPE, LABEL, SIZE, MOUNTPOINT
    ↓
    If MOUNTPOINT is set → SKIP (already mounted)
    ↓
    Validate FSTYPE (vfat, exfat, ntfs, ext4, etc.)
    ↓
    Create /mnt/usb/<LABEL>
    ↓
    Mount with filesystem-specific options:
    - vfat/exfat: uid/gid, umask=022, utf8
    - ntfs: ntfs-3g or ro fallback
    - ext4: defaults
    ↓
    Update counters (MOUNTED_COUNT, SKIPPED_COUNT)
    ↓
Summary report
```

### ollama-pi5-optimize.sh Flow

```
Entry Point (line 36)
    ↓
RAM tier detection:
    - TOTAL_RAM_KB = MemTotal from /proc/meminfo
    - 4GB or less   → GPU_MEM=128
    - 8GB or less   → GPU_MEM=256
    - 16GB or more  → GPU_MEM=512
    ↓
Systemd Override (Step 1)
    - Create /etc/systemd/system/ollama.service.d/
    - pi5-performance.conf with:
      OLLAMA_NUM_PARALLEL=1
      OLLAMA_MAX_LOADED_MODELS=1
      OLLAMA_FLASH_ATTENTION=1
      OLLAMA_NUM_THREAD=4 (core count)
      OLLAMA_KEEP_ALIVE=5m
    - systemctl daemon-reload
    - systemctl restart ollama
    ↓
GPU Memory Split (Step 2)
    - /boot/firmware/config.txt (or /boot/config.txt)
    - gpu_mem= set or append
    ↓
CPU Governor (Step 3)
    - Create cpu-performance.service
    - systemctl enable --now
    - echo performance to sysfs
    ↓
Swap Optimization (Step 4)
    - Disable dphys-swapfile
    - Create zramswap config
    - sysctl vm.swappiness=10
    ↓
SSD Model Path (Step 5)
    - Detect USB SSD via lsblk
    - If found: OLLAMA_MODELS=/mnt/usb/<device>/ollama-models
    ↓
Optional Overclock (Step 6)
    - Prompt for arm_freq=2800
    - Update config.txt
    ↓
Report summary and reboot instruction
```

## Threshold Logic

### CPU Frequency Thresholds (by model)

| Model | Min Frequency | Notes |
|-------|---------------|-------|
| Pi 5 | 2400 MHz | 2.4 GHz base |
| Pi 4 | 1800 MHz | 1.8 GHz base |
| Pi 3B+ | 1400 MHz | 1.4 GHz base |
| Pi 3 | 1200 MHz | 1.2 GHz base |
| Pi 2 | 900 MHz | 900 MHz base |
| Zero 2 | 1000 MHz | 1.0 GHz base |
| Zero | 1000 MHz | 1.0 GHz base |

### Disk I/O Thresholds (by storage type)

| Storage | Read (MB/s) | Write (MB/s) |
|---------|-------------|--------------|
| NVMe SSD | 180 | 100 |
| USB Storage | 90 | 50 |
| SD Card | 40 | 15 |

### Temperature Thresholds

| Model | Warn | Critical |
|-------|------|----------|
| Pi 2-5 | 70°C | 80°C |
| Pi 3 | 68°C | 78°C |
| Pi Zero | 68°C | 78°C |

## Filesystem Detection

The health benchmark detects filesystem type and adjusts:
- Mount options (uid/gid/umask for FAT, defaults for ext4)
- Performance expectations (SD cards have lower thresholds)
- Wear calculations (life_time for eMMC/SD)
