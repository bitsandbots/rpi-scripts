# ollama-pi5-optimize.sh Component Documentation

## Overview

System optimizer for running Ollama LLM inference on Raspberry Pi 5. Detects RAM size and applies optimizations for memory, CPU, swap, and storage.

## Core Functions

### Dry-Run Wrapper

```bash
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && warn "Dry-run mode — no changes will be made."

run() {
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $*"
  else
    "$@"
  fi
}
```

**Pattern**: Consistent with healthbench.sh dry-run approach.

### RAM Tier Detection

```bash
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))

if   (( TOTAL_RAM_GB <= 4 ));  then RAM_TIER=4;  GPU_MEM=128
elif (( TOTAL_RAM_GB <= 8 ));  then RAM_TIER=8;  GPU_MEM=256
else                                RAM_TIER=16; GPU_MEM=512
fi
```

### Model Recommendations by RAM Tier

| RAM Tier | GPU Memory | Recommended Models |
|----------|------------|-------------------|
| 4GB | 128 MB | tinyllama:1.1b-q4_0, phi3:mini-4k-q4_K_M, gemma:2b-q4_0 |
| 8GB | 256 MB | llama3.2:3b-q4_K_M, mistral:7b-q4_0, phi3:medium-q4_K_M |
| 16GB | 512 MB | llama3.1:8b-q4_K_M, mistral:7b-q8_0, deepseek-r1:8b-q4_K_M |

## Step 1: Ollama Systemd Override

### Override File Location

```bash
OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/pi5-performance.conf"
```

### Configuration Applied

```ini
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_THREAD=4"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MODELS=/mnt/usb/SSD/ollama-models"  # if SSD detected
```

### Commands Executed

```bash
mkdir -p $OVERRIDE_DIR
cat > $OVERRIDE_FILE << 'EOF'
[Service]
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_THREAD=4"
Environment="OLLAMA_KEEP_ALIVE=5m"
EOF
systemctl daemon-reload
systemctl restart ollama
```

### Why These Settings

| Setting | Value | Rationale |
|---------|-------|-----------|
| `OLLAMA_NUM_PARALLEL` | 1 | Single concurrent request to avoid memory pressure |
| `OLLAMA_MAX_LOADED_MODELS` | 1 | Keep only one model in VRAM |
| `OLLAMA_FLASH_ATTENTION` | 1 | Enable GPU acceleration (if supported) |
| `OLLAMA_NUM_THREADS` | 4 | Match Pi 5 quad-core CPU |
| `OLLAMA_KEEP_ALIVE` | 5m | Balance between cold start and memory use |

## Step 2: GPU Memory Split

### Config File Detection

```bash
if [ -f /boot/firmware/config.txt ]; then
  CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
  CONFIG_FILE="/boot/config.txt"
else
  CONFIG_FILE=""
fi
```

### GPU Memory Settings

| RAM Tier | GPU Memory | Rationale |
|----------|------------|-----------|
| ≤4GB | 128 MB | Minimal GPU memory for non-AI tasks |
| ≤8GB | 256 MB | Balanced for occasional GPU work |
| >8GB | 512 MB | Reserve more for LLM inference |

### What It Does

Sets `gpu_mem=<value>` in config.txt, which:
- Allocates dedicated GPU RAM from system pool
- Required for vcgencmd and GPU-accelerated operations
- Reboot required to take effect

## Step 3: CPU Governor → Performance

### Service File Created

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

### Immediate Application

```bash
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### Persistence

The service runs on boot, ensuring performance mode persists.

### Why Performance Governor

| Governor | Behavior | Use Case |
|----------|----------|----------|
| `ondemand` | Scales with load | General purpose |
| `conservative` | Slow scaling | Battery powered |
| `userspace` | User controlled | Custom scripts |
| `powersave` | Minimum freq | Battery saving |
| **`performance`** | Maximum freq | **LLM inference (fixed max)** |

## Step 4: Swap Optimization

### Disable Legacy Swap

```bash
systemctl disable --now dphys-swapfile
```

**Why**: `dphys-swapfile` creates swap on SD card, which is slow and wears the card.

### Enable zram

zram creates compressed swap in RAM, which is faster and reduces SD writes.

```bash
# Create config if not exists
cat > /etc/default/zramswap << EOF
ALGO=lz4
PERCENT=50
EOF

systemctl enable --now zramswap 2>/dev/null || true
```

### Set Swappiness

```bash
sysctl -w vm.swappiness=10
echo 'vm.swappiness=10' > /etc/sysctl.d/99-ollama-swap.conf
```

**Why**: Low swappiness (default 60) tells kernel to avoid swapping. LLM workloads prefer RAM for speed.

## Step 5: SSD Model Path

### Detection Logic

```bash
SSD_MOUNT=$(lsblk -o MOUNTPOINT,TRAN | awk '$2=="usb" && $1!="" {print $1}' | head -1)
```

Finds first USB-mounted block device.

### If SSD Detected

```bash
MODEL_PATH="$SSD_MOUNT/ollama-models"
mkdir -p "$MODEL_PATH"

# Set in /etc/environment for all processes
if ! grep -qF "OLLAMA_MODELS" /etc/environment 2>/dev/null; then
  echo 'OLLAMA_MODELS=$MODEL_PATH' >> /etc/environment
fi

# Also add to systemd override
sed -i '/OLLAMA_MODELS/d' $OVERRIDE_FILE
echo 'Environment="OLLAMA_MODELS=$MODEL_PATH"' >> $OVERRIDE_FILE
systemctl daemon-reload && systemctl restart ollama
```

### Benefits

| Storage Type | Speed (typical) | Model Loading |
|--------------|-----------------|---------------|
| SD Card | 40-100 MB/s | Slow (minutes) |
| USB 2.0 HDD | 30-40 MB/s | Very slow |
| USB 3.0 SSD | 200-350 MB/s | Fast (seconds) |
| NVMe SSD | 600-1000 MB/s | Very fast |

## Optional Step: Overclock

### Configuration

```bash
over_voltage=6
arm_freq=2800
```

### Why 2800 MHz

- Stock Pi 5: 2400 MHz
- Overclock: +400 MHz (15% increase)
- Requires: Active cooling (fan or heatsink with fan)

### Safety Warning

Overclocking voids warranty on Pi 5 and may cause:
- Instability if cooling insufficient
- SD card corruption if power supply inadequate
- Reduced hardware lifespan

## Failure Detection Flags

```bash
FAIL_CPU_SLOW=false
FAIL_DISK_READ=false
FAIL_DISK_WRITE=false
FAIL_THROTTLE=false
FAIL_TEMP=false
FAIL_SD_CLOCK=false
FAIL_FS_USAGE=false
FAIL_INODE=false
FAIL_FS_ERRORS=false
FAIL_SD_WEAR=false
FAIL_LOG_CRITICAL=false
```

These flags are actually in healthbench.sh but referenced by the optimization suggestions.

## Key Paths

| Path | Purpose |
|------|---------|
| `/etc/systemd/system/ollama.service.d/` | Ollama service overrides |
| `/etc/systemd/system/ollama.service.d/pi5-performance.conf` | Performance tuning |
| `/etc/systemd/system/cpu-performance.service` | CPU governor service |
| `/boot/firmware/config.txt` | Pi firmware config (Bookworm+) |
| `/boot/config.txt` | Pi firmware config (older) |
| `/etc/default/zramswap` | zram configuration |
| `/etc/sysctl.d/99-ollama-swap.conf` | Swap settings persistence |
| `/etc/environment` | System-wide environment variables |
| `/etc/rc.local` | rc.local script (if created) |
| `/etc/udev/rules.d/60-sd-scheduler.rules` | I/O scheduler persistence |

## Testing

### Verify Ollama Config

```bash
# Check service overrides
cat /etc/systemd/system/ollama.service.d/pi5-performance.conf

# Check environment
grep OLLAMA /etc/environment

# Check systemd service
systemctl show ollama | grep Environment

# Check CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

### Verify GPU Memory

```bash
vcgencmd get_config int | grep gpu_mem
```

### Benchmark Before/After

```bash
# Before optimization
ollama run tinyllama:1.1b-q4_0 'Count from 1 to 10' 2>&1 | grep -i token

# After optimization
ollama run tinyllama:1.1b-q4_0 'Count from 1 to 10' 2>&1 | grep -i token
```

### Check Swap Usage

```bash
# Should show zram devices
zramctl

# Should show low swappiness
cat /proc/sys/vm/swappiness
```

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Ollama installed | `ollama` command |
| systemd | Service management |
| zram-tools | Compressed swap in RAM |
| lsblk | USB SSD detection |

### Install Prerequisites

```bash
# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# zram-tools
sudo apt-get install zram-tools
```

## Cleanup on Revert

To undo optimizations:

```bash
# Remove Ollama overrides
sudo rm -rf /etc/systemd/system/ollama.service.d

# Remove governor service
sudo rm -f /etc/systemd/system/cpu-performance.service
sudo systemctl daemon-reload

# Restore swap
sudo systemctl enable --now dphys-swapfile
sudo rm -f /etc/sysctl.d/99-ollama-swap.conf

# Reboot to restore GPU memory split
sudo reboot
```

## Troubleshooting

### Ollama won't start

```bash
# Check service status
sudo systemctl status ollama

# Check logs
sudo journalctl -u ollama -f
```

### Low token throughput

1. Check CPU governor: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
2. Check GPU memory: `vcgencmd get_config int \| grep gpu_mem`
3. Verify swap: `zramctl`
4. Check if running on SSD: `echo $OLLAMA_MODELS`

### Model loads slowly

- Move models to SSD: `OLLAMA_MODELS=/mnt/usb/SSD/ollama-models ollama serve`
- Check SSD mount point: `lsblk -o MOUNTPOINT,TRAN`
