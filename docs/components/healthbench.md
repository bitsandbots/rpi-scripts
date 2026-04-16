# rpi-healthbench.sh Component Documentation

## Overview

Comprehensive system health benchmark with model-specific thresholds and auto-fix capabilities.

## Core Functions

### Output Functions

```bash
pass()  { ((++PASS));  REPORT_LINES+=("${GREEN}[PASS]${RESET} $1"); echo -e "  ${GREEN}[PASS]${RESET} $1"; }
warn()  { ((++WARN));  REPORT_LINES+=("${YELLOW}[WARN]${RESET} $1"); echo -e "  ${YELLOW}[WARN]${RESET} $1"; }
fail()  { ((++FAIL));  REPORT_LINES+=("${RED}[FAIL]${RESET} $1");  echo -e "  ${RED}[FAIL]${RESET} $1"; }
info()  { echo -e "  ${BLUE}[INFO]${RESET} $1"; }
fix()   { echo -e "  ${MAGENTA}[FIX ]${RESET} $1"; FIX_ACTIONS+=("$1"); }
suggest(){ echo -e "  ${YELLOW}[SUGGEST]${RESET} $1"; FIX_SUGGESTIONS+=("$1"); }
section(){ echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }
```

### Color Definitions

```bash
RED='\e[91m'; YELLOW='\e[93m'; GREEN='\e[92m'
CYAN='\e[96m'; WHITE='\e[97m'; BLUE='\e[94m'
MAGENTA='\e[95m'
BOLD='\e[1m'; RESET='\e[0m'
```

### Threshold Management

```bash
set_thresholds() {
  case "$MODEL" in
    *"Pi 5"*)   CPU_MIN=2400; TEMP_WARN=70; TEMP_FAIL=80 ;;
    *"Pi 4"*)   CPU_MIN=1800; TEMP_WARN=70; TEMP_FAIL=80 ;;
    *"Pi 3B+"*) CPU_MIN=1400; TEMP_WARN=68; TEMP_FAIL=78 ;;
    *)          CPU_MIN=1000; TEMP_WARN=70; TEMP_FAIL=80 ;;
  esac
}
```

### Hardware Detection

```bash
detect_model() {
  if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
  else
    model="Unknown"
  fi
  echo "$model"
}
```

## CPU Governor Management

```bash
set_governor() {
  local target="$1"
  local gov_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  if [ -f "$gov_path" ]; then
    ORIG_GOVERNOR=$(cat "$gov_path")
    if [ "$ORIG_GOVERNOR" != "$target" ]; then
      for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$target" > "$cpu_gov" 2>/dev/null
      done
    fi
  fi
}

restore_governor() {
  if [ -n "$ORIG_GOVERNOR" ]; then
    for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo "$ORIG_GOVERNOR" > "$cpu_gov" 2>/dev/null
    done
  fi
}
```

**Pattern**: Save original, set performance for benchmarks, restore on exit.

## Throttle Decoding

```bash
decode_throttle() {
  local v=$1
  local -a msgs=()
  (( v & 0x1  )) && msgs+=("Under-voltage detected")
  (( v & 0x2  )) && msgs+=("ARM frequency capped")
  (( v & 0x4  )) && msgs+=("Currently throttled")
  (( v & 0x8  )) && msgs+=("Soft temperature limit active")
  (( v & 0x10000 )) && msgs+=("[HISTORY] Under-voltage occurred")
  (( v & 0x20000 )) && msgs+=("[HISTORY] ARM freq capped")
  (( v & 0x40000 )) && msgs+=("[HISTORY] Throttling occurred")
  (( v & 0x80000 )) && msgs+=("[HISTORY] Soft temp limit hit")
  printf '%s\n' "${msgs[@]}"
}
```

**Bit layout**:
- Bits 0-3: Active status (current moment)
- Bits 16-19: Historical status (since boot)

## Temperature Check

```bash
get_temp_c() {
  local raw
  raw=$(vcgencmd measure_temp 2>/dev/null) || { echo ""; return; }
  echo "$raw" | grep -oP '[0-9]+\.[0-9]+' | cut -d. -f1 || echo ""
}

check_temp() {
  local label=$1
  local t; t=$(get_temp_c)
  if [ -z "$t" ]; then
    warn "$label temp: unable to read (vcgencmd failed)"
    return
  fi
  if   (( t >= TEMP_FAIL )); then fail "$label temp: ${t}°C — CRITICAL (limit ${TEMP_FAIL}°C)"
  elif (( t >= TEMP_WARN )); then warn "$label temp: ${t}°C — warm (warn ≥${TEMP_WARN}°C)"
  else pass "$label temp: ${t}°C — OK"
  fi
}
```

## Disk Detection

```bash
DISK=""
for candidate in /dev/sda /dev/nvme0n1 /dev/mmcblk0; do
  [ -b "$candidate" ] && { DISK="$candidate"; break; }
done

DISK_TYPE="SD/eMMC"
[[ "$DISK" == /dev/sd*   ]] && DISK_TYPE="USB Storage"
[[ "$DISK" == /dev/nvme* ]] && DISK_TYPE="NVMe SSD"
```

**Priority order**: NVMe > USB > SD/eMMC

## Log Analysis

```bash
LOG_PATTERNS=(
  "CRIT|Kernel panic|kernel panic"
  "CRIT|Out of memory killer|Out of memory: Kill"
  "CRIT|Filesystem remounted read-only|Remounting filesystem read-only"
  "CRIT|I/O error on block device|I/O error.*dev [sm]"
  "CRIT|ext4 filesystem error|EXT4-fs error"
  "CRIT|MMC/SD I/O error|mmc[0-9].*error"
  "WARN|Under-voltage detected|Under-voltage detected"
  "WARN|Kernel oops|Oops.*CPU"
  "WARN|USB device disconnect|USB disconnect"
  "WARN|Temperature throttling|kernel:.*throttled"
  "WARN|Task hung|task .* blocked for more than"
  "WARN|Kernel segfault|segfault at"
  "WARN|BTRFS error|BTRFS.*error"
  "WARN|Watchdog timeout|watchdog.*timeout"
)
```

**Scan locations**:
1. `journalctl -b 0` - Current boot
2. `journalctl -b -1` - Previous boot
3. `dmesg` - Kernel ring buffer (fallback)

## Auto-Fix Logic

### Fix Categories

| Issue | Fix | Persistence |
|-------|-----|-------------|
| Slow CPU | Governor → performance | rc.local |
| Throttle | Hardware check | Manual |
| High temp | Fan enable | config.txt |
| Slow SD | mq-deadline scheduler | udev rule |
| Full disk | Clean apt, journal, thumbnails | One-time |
| High inodes | Find large file dirs | Manual |
| FS errors | /forcefsck | Reboot |
| SD wear | noatime, reduced swappiness | fstab/sysctl |

### Fix Action Tracking

```bash
declare -a FIX_ACTIONS=()     # Applied fixes
declare -a FIX_SUGGESTIONS=() # Manual fixes needed
```

## Key Paths

| Path | Purpose |
|------|---------|
| `/proc/device-tree/model` | Hardware model |
| `/proc/meminfo` | Memory info |
| `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | CPU governor |
| `/sys/class/mmc_host/mmc0/mmc0:0001/` | SD card info |
| `/sys/block/mmcblk0/device/life_time` | SD wear level |
| `/boot/firmware/config.txt` | Pi config (Bookworm+) |
| `/boot/config.txt` | Pi config (older) |
| `/sys/kernel/debug/mmc0/ios` | SD clock settings |
| `/etc/rc.local` | Boot script for persistence |
| `/etc/udev/rules.d/60-sd-scheduler.rules` | Scheduler persistence |
| `/etc/sysctl.d/99-healthbench.conf` | sysctl persistence |

## Test Data

### Test CPU Benchmark
```bash
sysbench --threads=4 cpu --cpu-max-prime=5000 run
```

### Test Memory Bandwidth
```bash
sysbench --threads=4 memory --memory-block-size=1K \
       --memory-total-size=3G --memory-access-mode=seq run
```

### Test Disk Read
```bash
hdparm -tT /dev/mmcblk0
```

### Test Disk Write
```bash
dd if=/dev/zero of=/tmp/rpi_bench_XXXXXX.tmp bs=1M count=512 conv=fsync
```

## Output Summary Format

```
══════════════════════════════════════════════════════════════════════════════
  HEALTH REPORT SUMMARY  —  Raspberry Pi 5 Model B Rev 1.0
══════════════════════════════════════════════════════════════════════════════

  [PASS] Idle CPU temp: 45°C — OK
  [PASS] No active throttle or voltage issues
  [PASS] CPU running at 2400 MHz (expected ≥2400 MHz)
  ...
  
  ──────────────────────────────────────────────────────────────────────────────
  PASS: 24   WARN: 2   FAIL: 1   (of 27 checks)

⚠  OVERALL: DEGRADED — multiple warnings, investigate
```

## Cleanup Trap

```bash
TMPFILE=""
cleanup() {
  restore_governor
  [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
}
trap cleanup EXIT
```

Ensures governor restoration and temp file cleanup on exit.
