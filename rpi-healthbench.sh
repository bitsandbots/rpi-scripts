#!/bin/bash
set -euo pipefail
# =============================================================================
# rpi-healthbench.sh — Raspberry Pi Health Benchmark
# Based on aikoncwd/rpi-benchmark, extended with model detection,
# spec-aware thresholds, auto-fix remediation, and a final health report.
# Author: CoreConduit / coreconduit.com
# =============================================================================

[ "$(whoami)" == "root" ] || { echo "Must be run as sudo!"; exit 1; }

# ── CLI flags ────────────────────────────────────────────────────────────────
AUTO_FIX=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --fix)     AUTO_FIX=true ;;
    --dry-run) AUTO_FIX=true; DRY_RUN=true ;;
    --help|-h)
      echo "Usage: sudo ./rpi-healthbench.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --fix       Attempt automatic fixes for detected issues"
      echo "  --dry-run   Show what --fix would do, without applying changes"
      echo "  --help      Show this help message"
      exit 0 ;;
  esac
done

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\e[91m'; YELLOW='\e[93m'; GREEN='\e[92m'
CYAN='\e[96m'; WHITE='\e[97m'; BLUE='\e[94m'
MAGENTA='\e[95m'
BOLD='\e[1m'; RESET='\e[0m'

# ── Result tracking ──────────────────────────────────────────────────────────
PASS=0; WARN=0; FAIL=0
declare -a REPORT_LINES=()
declare -a FIX_ACTIONS=()     # Descriptions of fixes applied
declare -a FIX_SUGGESTIONS=() # Things we can't auto-fix

pass()  { ((++PASS));  REPORT_LINES+=("${GREEN}[PASS]${RESET} $1"); echo -e "  ${GREEN}[PASS]${RESET} $1"; }
warn()  { ((++WARN));  REPORT_LINES+=("${YELLOW}[WARN]${RESET} $1"); echo -e "  ${YELLOW}[WARN]${RESET} $1"; }
fail()  { ((++FAIL));  REPORT_LINES+=("${RED}[FAIL]${RESET} $1");  echo -e "  ${RED}[FAIL]${RESET} $1"; }
info()  { echo -e "  ${BLUE}[INFO]${RESET} $1"; }
fix()   { echo -e "  ${MAGENTA}[FIX ]${RESET} $1"; FIX_ACTIONS+=("$1"); }
suggest(){ echo -e "  ${YELLOW}[SUGGEST]${RESET} $1"; FIX_SUGGESTIONS+=("$1"); }
section(){ echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

# ── Failure flags (for targeted fixes) ───────────────────────────────────────
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

# ── Dependency installer ──────────────────────────────────────────────────────
need() {
  local pkg=$1 bin=${2:-$1}
  command -v "$bin" &>/dev/null || {
    echo -e "  ${YELLOW}Installing $pkg...${RESET}"
    apt-get install -y "$pkg" -qq 2>/dev/null \
      || echo -e "  ${YELLOW}[WARN]${RESET} Failed to install $pkg — some tests may be skipped"
  }
}

need hdparm
need sysbench
need bc

# ── Model detection ──────────────────────────────────────────────────────────
detect_model() {
  local model
  if [ -f /proc/device-tree/model ]; then
    model=$(tr -d '\0' < /proc/device-tree/model)
  else
    model="Unknown"
  fi
  echo "$model"
}

MODEL=$(detect_model)

# ── Config file detection ─────────────────────────────────────────────────────
# Pi 5 / Bookworm+ uses /boot/firmware/config.txt; older Pis use /boot/config.txt
if [ -f /boot/firmware/config.txt ]; then
  CONFIG_TXT="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
  CONFIG_TXT="/boot/config.txt"
else
  CONFIG_TXT=""
fi

# ── Thresholds (set per model, then adjusted by storage type) ─────────────────
# Base CPU/temp/memory thresholds are model-dependent.
# Disk thresholds are set later once we detect the actual storage medium.
set_thresholds() {
  case "$MODEL" in
    *"Pi 5"*)
      CPU_MIN=2400; TEMP_WARN=70; TEMP_FAIL=80
      MEM_BW_WARN=3500; CPU_SCORE_WARN=6
      DISK_R_NVME=180;  DISK_W_NVME=100
      DISK_R_USB=90;    DISK_W_USB=50
      DISK_R_SD=40;     DISK_W_SD=15 ;;
    *"Pi 4"*)
      CPU_MIN=1800; TEMP_WARN=70; TEMP_FAIL=80
      MEM_BW_WARN=2500; CPU_SCORE_WARN=15
      DISK_R_NVME=150;  DISK_W_NVME=80
      DISK_R_USB=90;    DISK_W_USB=40
      DISK_R_SD=40;     DISK_W_SD=15 ;;
    *"Pi 3 Model B Plus"*|*"Pi 3B+"*)
      CPU_MIN=1400; TEMP_WARN=68; TEMP_FAIL=78
      MEM_BW_WARN=800; CPU_SCORE_WARN=45
      DISK_R_NVME=0;    DISK_W_NVME=0
      DISK_R_USB=25;    DISK_W_USB=10
      DISK_R_SD=20;     DISK_W_SD=8 ;;
    *"Pi 3"*)
      CPU_MIN=1200; TEMP_WARN=68; TEMP_FAIL=78
      MEM_BW_WARN=700; CPU_SCORE_WARN=55
      DISK_R_NVME=0;    DISK_W_NVME=0
      DISK_R_USB=20;    DISK_W_USB=8
      DISK_R_SD=18;     DISK_W_SD=8 ;;
    *"Pi 2"*)
      CPU_MIN=900;  TEMP_WARN=68; TEMP_FAIL=78
      MEM_BW_WARN=400; CPU_SCORE_WARN=90
      DISK_R_NVME=0;    DISK_W_NVME=0
      DISK_R_USB=18;    DISK_W_USB=8
      DISK_R_SD=15;     DISK_W_SD=6 ;;
    *"Zero 2"*)
      CPU_MIN=1000; TEMP_WARN=68; TEMP_FAIL=78
      MEM_BW_WARN=600; CPU_SCORE_WARN=60
      DISK_R_NVME=0;    DISK_W_NVME=0
      DISK_R_USB=18;    DISK_W_USB=8
      DISK_R_SD=15;     DISK_W_SD=6 ;;
    *"Zero"*)
      CPU_MIN=1000; TEMP_WARN=68; TEMP_FAIL=78
      MEM_BW_WARN=200; CPU_SCORE_WARN=200
      DISK_R_NVME=0;    DISK_W_NVME=0
      DISK_R_USB=12;    DISK_W_USB=5
      DISK_R_SD=12;     DISK_W_SD=4 ;;
    *)
      CPU_MIN=1000; TEMP_WARN=70; TEMP_FAIL=80
      MEM_BW_WARN=400; CPU_SCORE_WARN=120
      DISK_R_NVME=100;  DISK_W_NVME=50
      DISK_R_USB=15;    DISK_W_USB=8
      DISK_R_SD=12;     DISK_W_SD=5 ;;
  esac
}

set_thresholds

# Assign disk thresholds based on detected storage type
set_disk_thresholds() {
  local dtype="$1"
  case "$dtype" in
    "NVMe SSD")    DISK_R_WARN=$DISK_R_NVME;  DISK_W_WARN=$DISK_W_NVME ;;
    "USB Storage") DISK_R_WARN=$DISK_R_USB;    DISK_W_WARN=$DISK_W_USB  ;;
    *)             DISK_R_WARN=$DISK_R_SD;     DISK_W_WARN=$DISK_W_SD   ;;
  esac
}

# ── Helpers ──────────────────────────────────────────────────────────────────
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
  if   (( t >= TEMP_FAIL )); then
    fail "$label temp: ${t}°C — CRITICAL (limit ${TEMP_FAIL}°C)"
    FAIL_TEMP=true
  elif (( t >= TEMP_WARN )); then
    warn "$label temp: ${t}°C — warm (warn ≥${TEMP_WARN}°C)"
  else
    pass "$label temp: ${t}°C — OK"
  fi
}

bc_cmp() { echo "$1" | bc -l 2>/dev/null | awk 'NR==1{print ($1>0)?1:0} END{if(!NR)print 0}'; }

# ── CPU governor management ──────────────────────────────────────────────────
ORIG_GOVERNOR=""

set_governor() {
  local target="$1"
  local gov_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
  if [ -f "$gov_path" ]; then
    ORIG_GOVERNOR=$(cat "$gov_path")
    if [ "$ORIG_GOVERNOR" != "$target" ]; then
      info "Setting CPU governor: ${ORIG_GOVERNOR} → ${target} (for benchmark)"
      for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$target" > "$cpu_gov" 2>/dev/null
      done
    fi
  fi
}

restore_governor() {
  if [ -n "$ORIG_GOVERNOR" ]; then
    local current
    current=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    if [ "$current" != "$ORIG_GOVERNOR" ]; then
      info "Restoring CPU governor: ${current} → ${ORIG_GOVERNOR}"
      for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$ORIG_GOVERNOR" > "$cpu_gov" 2>/dev/null
      done
    fi
  fi
}

TMPFILE=""
cleanup() {
  restore_governor
  [ -n "$TMPFILE" ] && rm -f "$TMPFILE"
}
trap cleanup EXIT

# ── Identify SD card details ─────────────────────────────────────────────────
get_sd_info() {
  local mmc_path="/sys/class/mmc_host/mmc0/mmc0:0001"
  if [ -d "$mmc_path" ]; then
    local name speed_class
    name=$(cat "$mmc_path/name" 2>/dev/null || echo "unknown")
    speed_class=$(cat "$mmc_path/speed_class" 2>/dev/null || echo "?")
    echo "name=$name class=$speed_class"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ██████╗ ██████╗ ██╗    ██╗  ██╗███████╗ █████╗ ██╗  ████████╗██╗  ██╗"
echo "  ██╔══██╗██╔══██╗██║    ██║  ██║██╔════╝██╔══██╗██║  ╚══██╔══╝██║  ██║"
echo "  ██████╔╝██████╔╝██║    ███████║█████╗  ███████║██║     ██║   ███████║"
echo "  ██╔══██╗██╔═══╝ ██║    ██╔══██║██╔══╝  ██╔══██║██║     ██║   ██╔══██║"
echo "  ██║  ██║██║     ██║    ██║  ██║███████╗██║  ██║███████╗██║   ██║  ██║"
echo "  ╚═╝  ╚═╝╚═╝     ╚═╝    ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝  ╚═╝"
echo -e "${WHITE}         Raspberry Pi Health Benchmark  •  CoreConduit${RESET}"
if $AUTO_FIX && $DRY_RUN; then
  echo -e "${MAGENTA}${BOLD}         MODE: DRY-RUN (will show fixes without applying)${RESET}"
elif $AUTO_FIX; then
  echo -e "${MAGENTA}${BOLD}         MODE: AUTO-FIX ENABLED${RESET}"
fi
echo -e "${CYAN}$(printf '═%.0s' {1..70})${RESET}"

# ── 1. Hardware identity ──────────────────────────────────────────────────────
section "HARDWARE IDENTITY"
echo -e "  ${WHITE}Model   :${RESET} $MODEL"
echo -e "  ${WHITE}Hostname:${RESET} $(hostname)"
echo -e "  ${WHITE}OS      :${RESET} $(. /etc/os-release && echo "$PRETTY_NAME")"
echo -e "  ${WHITE}Kernel  :${RESET} $(uname -r)"
echo -e "  ${WHITE}Uptime  :${RESET} $(uptime -p)"

RAM_TOTAL=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
echo -e "  ${WHITE}RAM     :${RESET} ${RAM_TOTAL} MB"

[ -n "$CONFIG_TXT" ] && echo -e "  ${WHITE}Config  :${RESET} $CONFIG_TXT"

# ── 2. Throttle / voltage status ─────────────────────────────────────────────
section "VOLTAGE & THROTTLE STATUS"
THROTTLED_HEX=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "0x0")
THROTTLED_DEC=$(printf '%d' "$THROTTLED_HEX" 2>/dev/null || echo 0)

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

info "Raw throttled value: $THROTTLED_HEX"

ACTIVE=$(( THROTTLED_DEC & 0xFFFF ))
if (( ACTIVE == 0 )); then
  pass "No active throttle or voltage issues"
else
  FAIL_THROTTLE=true
  while IFS= read -r line; do
    [[ "$line" == \[HISTORY\]* ]] && warn "$line" || fail "$line"
  done < <(decode_throttle "$THROTTLED_DEC" | grep -v '^\[HISTORY\]')
fi

HIST=$(( (THROTTLED_DEC >> 16) & 0xFFFF ))
if (( HIST != 0 )); then
  while IFS= read -r line; do
    [[ "$line" == \[HISTORY\]* ]] && warn "${line#\[HISTORY\] }"
  done < <(decode_throttle "$THROTTLED_DEC")
fi

# ── 3. CPU frequency ──────────────────────────────────────────────────────────
section "CPU FREQUENCY"
ARM_FREQ=$(vcgencmd measure_clock arm 2>/dev/null | grep -oP '\d+' | tail -1 || echo "0")
ARM_FREQ=${ARM_FREQ:-0}
ARM_MHZ=$(( ARM_FREQ / 1000000 ))
CORE_FREQ=$(vcgencmd get_config int 2>/dev/null | grep arm_freq | grep -oP '\d+' | head -1 || echo "")
CORE_FREQ=${CORE_FREQ:-"(config unset)"}

info "Current ARM clock : ${ARM_MHZ} MHz"
info "Config arm_freq   : ${CORE_FREQ}"
info "Minimum expected  : ${CPU_MIN} MHz"

CURRENT_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
info "CPU governor      : ${CURRENT_GOVERNOR}"

if (( ARM_MHZ == 0 )); then
  warn "CPU frequency: unable to read (vcgencmd failed)"
elif (( ARM_MHZ >= CPU_MIN )); then
  pass "CPU running at ${ARM_MHZ} MHz (expected ≥${CPU_MIN} MHz)"
elif (( ARM_MHZ >= CPU_MIN * 75 / 100 )); then
  warn "CPU at ${ARM_MHZ} MHz — below spec ${CPU_MIN} MHz (possible throttle)"
else
  fail "CPU at ${ARM_MHZ} MHz — severely under spec ${CPU_MIN} MHz"
fi

check_temp "Idle CPU"

# ── 4. CPU benchmark ─────────────────────────────────────────────────────────
section "CPU BENCHMARK  (sysbench prime, 4 threads)"

# FIX: Force performance governor for accurate benchmark results
set_governor "performance"
sleep 1  # Let frequency ramp

CPU_OUTPUT=$(sysbench --threads=4 cpu --cpu-max-prime=5000 run 2>&1)
CPU_TIME=$(echo "$CPU_OUTPUT" | grep 'total time:' | grep -oP '[0-9]+\.[0-9]+' || echo "")
echo "$CPU_OUTPUT" | grep 'total time:\|min:\|avg:\|max:' | tr -s '[:space:]' | sed 's/^/  /' || true

if [ -n "$CPU_TIME" ]; then
  if (( $(bc_cmp "$CPU_TIME <= $CPU_SCORE_WARN") )); then
    pass "CPU time ${CPU_TIME}s — within expected range (≤${CPU_SCORE_WARN}s)"
  elif (( $(bc_cmp "$CPU_TIME <= $CPU_SCORE_WARN * 1.5") )); then
    warn "CPU time ${CPU_TIME}s — slower than expected (warn >${CPU_SCORE_WARN}s)"
    FAIL_CPU_SLOW=true
  else
    fail "CPU time ${CPU_TIME}s — significantly slower than expected ${CPU_SCORE_WARN}s"
    FAIL_CPU_SLOW=true
  fi
fi
check_temp "Post-CPU"

# ── 5. Thread benchmark ───────────────────────────────────────────────────────
section "THREAD BENCHMARK  (sysbench, 4 threads)"
THREAD_OUTPUT=$(sysbench --threads=4 threads --thread-yields=4000 --thread-locks=6 run 2>&1)
echo "$THREAD_OUTPUT" | grep 'total time:\|min:\|avg:\|max:' | tr -s '[:space:]' | sed 's/^/  /' || true
check_temp "Post-thread"

# Restore governor after CPU-intensive benchmarks
restore_governor

# ── 6. Memory bandwidth ───────────────────────────────────────────────────────
section "MEMORY BANDWIDTH  (sysbench, 3 GB sequential)"
MEM_OUTPUT=$(sysbench --threads=4 memory --memory-block-size=1K \
             --memory-total-size=3G --memory-access-mode=seq run 2>&1)
echo "$MEM_OUTPUT" | grep 'Operations\|transferred\|total time:\|min:\|avg:\|max:' \
  | tr -s '[:space:]' | sed 's/^/  /' || true

MEM_BW=$(echo "$MEM_OUTPUT" | grep -oP '[0-9]+\.[0-9]+ MiB/sec' | grep -oP '[0-9]+\.[0-9]+' || echo "")
if [ -n "$MEM_BW" ]; then
  MEM_BW_INT=${MEM_BW%.*}
  if (( MEM_BW_INT >= MEM_BW_WARN )); then
    pass "Memory bandwidth ${MEM_BW} MiB/s — OK (expected ≥${MEM_BW_WARN} MiB/s)"
  elif (( MEM_BW_INT >= MEM_BW_WARN * 70 / 100 )); then
    warn "Memory bandwidth ${MEM_BW} MiB/s — below expected ≥${MEM_BW_WARN} MiB/s"
  else
    fail "Memory bandwidth ${MEM_BW} MiB/s — poor (expected ≥${MEM_BW_WARN} MiB/s)"
  fi
fi
check_temp "Post-memory"

# ── 7. Disk — detect primary block device ────────────────────────────────────
section "DISK DETECTION"
DISK=""
for candidate in /dev/sda /dev/nvme0n1 /dev/mmcblk0; do
  [ -b "$candidate" ] && { DISK="$candidate"; break; }
done

if [ -z "$DISK" ]; then
  warn "No block device found — skipping disk tests"
else
  info "Primary block device: $DISK"
  DISK_TYPE="SD/eMMC"
  [[ "$DISK" == /dev/sd*   ]] && DISK_TYPE="USB Storage"
  [[ "$DISK" == /dev/nvme* ]] && DISK_TYPE="NVMe SSD"
  info "Detected type: $DISK_TYPE"

  # Set storage-type-appropriate thresholds
  set_disk_thresholds "$DISK_TYPE"
  info "Disk read threshold : ≥${DISK_R_WARN} MB/s (for $DISK_TYPE)"
  info "Disk write threshold: ≥${DISK_W_WARN} MB/s (for $DISK_TYPE)"

  # Show SD card info if on SD
  if [[ "$DISK" == /dev/mmcblk* ]]; then
    SD_INFO=$(get_sd_info)
    [ -n "$SD_INFO" ] && info "SD card: $SD_INFO"
  fi

  # ── 7a. hdparm read ───────────────────────────────────────────────────────
  section "DISK READ  (hdparm cached + buffered)"
  HDPARM_OUT=$(hdparm -tT "$DISK" 2>&1)
  echo "$HDPARM_OUT" | grep -i timing | sed 's/^/  /' || true

  HDPARM_MB=$(echo "$HDPARM_OUT" | grep 'buffered' | grep -oP '[0-9]+\.[0-9]+ MB/sec' \
              | grep -oP '[0-9]+\.[0-9]+' | head -1 || echo "")
  if [ -n "$HDPARM_MB" ]; then
    HDPARM_INT=${HDPARM_MB%.*}
    if (( HDPARM_INT >= DISK_R_WARN )); then
      pass "hdparm buffered read ${HDPARM_MB} MB/s — OK (expected ≥${DISK_R_WARN} MB/s)"
    elif (( HDPARM_INT >= DISK_R_WARN * 70 / 100 )); then
      warn "hdparm buffered read ${HDPARM_MB} MB/s — below expected ≥${DISK_R_WARN} MB/s"
      FAIL_DISK_READ=true
    else
      fail "hdparm buffered read ${HDPARM_MB} MB/s — poor (expected ≥${DISK_R_WARN} MB/s)"
      FAIL_DISK_READ=true
    fi
  fi
  check_temp "Post-hdparm"

  # ── 7b. DD write ─────────────────────────────────────────────────────────
  section "DISK WRITE  (dd 512 MB)"
  TMPFILE=$(mktemp /tmp/rpi_bench_XXXXXX.tmp)
  DD_WRITE=$(sync && \
             dd if=/dev/zero of="$TMPFILE" bs=1M count=512 conv=fsync 2>&1 | tail -1)
  echo "  $DD_WRITE"
  DD_W_MB=$(echo "$DD_WRITE" | grep -oP '[0-9]+(\.[0-9]+)? [MG]B/s' | head -1 || echo "")
  DD_W_VAL=$(echo "$DD_W_MB" | grep -oP '[0-9]+(\.[0-9]+)?' || echo "")
  DD_W_UNIT=$(echo "$DD_W_MB" | grep -oP '[MG]B/s' || echo "")
  [ "$DD_W_UNIT" = "GB/s" ] && DD_W_VAL=$(echo "$DD_W_VAL * 1024" | bc | cut -d. -f1)
  DD_W_VAL=${DD_W_VAL%.*}
  if [ -n "$DD_W_VAL" ]; then
    if (( DD_W_VAL >= DISK_W_WARN )); then
      pass "Write speed ~${DD_W_VAL} MB/s — OK (expected ≥${DISK_W_WARN} MB/s)"
    elif (( DD_W_VAL >= DISK_W_WARN * 70 / 100 )); then
      warn "Write speed ~${DD_W_VAL} MB/s — below expected ≥${DISK_W_WARN} MB/s"
      FAIL_DISK_WRITE=true
    else
      fail "Write speed ~${DD_W_VAL} MB/s — poor (expected ≥${DISK_W_WARN} MB/s)"
      FAIL_DISK_WRITE=true
    fi
  fi
  check_temp "Post-write"

  # ── 7c. DD read ──────────────────────────────────────────────────────────
  section "DISK READ  (dd 512 MB, cache flushed)"
  echo 3 > /proc/sys/vm/drop_caches && sync
  DD_READ=$(dd if="$TMPFILE" of=/dev/null bs=1M 2>&1 | tail -1)
  echo "  $DD_READ"
  DD_R_MB=$(echo "$DD_READ" | grep -oP '[0-9]+(\.[0-9]+)? [MG]B/s' | head -1 || echo "")
  DD_R_VAL=$(echo "$DD_R_MB" | grep -oP '[0-9]+(\.[0-9]+)?' || echo "")
  DD_R_UNIT=$(echo "$DD_R_MB" | grep -oP '[MG]B/s' || echo "")
  [ "$DD_R_UNIT" = "GB/s" ] && DD_R_VAL=$(echo "$DD_R_VAL * 1024" | bc | cut -d. -f1)
  DD_R_VAL=${DD_R_VAL%.*}
  if [ -n "$DD_R_VAL" ]; then
    if (( DD_R_VAL >= DISK_R_WARN )); then
      pass "Read speed ~${DD_R_VAL} MB/s — OK (expected ≥${DISK_R_WARN} MB/s)"
    elif (( DD_R_VAL >= DISK_R_WARN * 70 / 100 )); then
      warn "Read speed ~${DD_R_VAL} MB/s — below expected ≥${DISK_R_WARN} MB/s"
      FAIL_DISK_READ=true
    else
      fail "Read speed ~${DD_R_VAL} MB/s — poor (expected ≥${DISK_R_WARN} MB/s)"
      FAIL_DISK_READ=true
    fi
  fi
  rm -f "$TMPFILE"
  check_temp "Post-read"
fi

# ── 8. SD card clock (if present) ────────────────────────────────────────────
if [ -f /sys/kernel/debug/mmc0/ios ]; then
  section "SD CARD CLOCK"
  SD_CLOCK=$(grep "actual clock" /sys/kernel/debug/mmc0/ios 2>/dev/null \
             | awk '{printf("%.1f MHz", $3/1000000)}' || echo "unknown")
  info "SD clock: $SD_CLOCK"
  SD_MHZ=$(grep "actual clock" /sys/kernel/debug/mmc0/ios 2>/dev/null \
           | awk '{printf("%.0f", $3/1000000)}' || echo "0")
  SD_MHZ=${SD_MHZ:-0}
  if (( SD_MHZ >= 100 )); then
    pass "SD running in SDR104/UHS mode (${SD_CLOCK})"
  elif (( SD_MHZ >= 50 )); then
    pass "SD running in high-speed mode (${SD_CLOCK})"
    # On Pi 4/5, SDR104 at 100+ MHz is possible and preferred
    if [[ "$MODEL" == *"Pi 5"* ]] || [[ "$MODEL" == *"Pi 4"* ]]; then
      FAIL_SD_CLOCK=true
    fi
  elif (( SD_MHZ >= 25 )); then
    warn "SD in normal mode (${SD_CLOCK}) — may support high-speed"
    FAIL_SD_CLOCK=true
  else
    fail "SD clock very low (${SD_CLOCK}) — possible compatibility issue"
    FAIL_SD_CLOCK=true
  fi
fi

# ── 9. Filesystem health ─────────────────────────────────────────────────────
section "FILESYSTEM HEALTH"

# ── 9a. Disk usage per mount ─────────────────────────────────────────────────
FS_USAGE_WARN=85
FS_USAGE_FAIL=95
INODE_USAGE_WARN=80
INODE_USAGE_FAIL=95

declare -a FS_CRIT_MOUNTS=()    # Mounts that crossed the fail threshold
declare -a FS_WARN_MOUNTS=()    # Mounts that crossed the warn threshold

while IFS= read -r line; do
  mount_pt=$(echo "$line" | awk '{print $NF}')
  pct_used=$(echo "$line" | awk '{print $(NF-1)}' | tr -d '%')
  [ -z "$pct_used" ] && continue
  if (( pct_used >= FS_USAGE_FAIL )); then
    fail "Disk usage on ${mount_pt}: ${pct_used}% — CRITICAL (limit ${FS_USAGE_FAIL}%)"
    FAIL_FS_USAGE=true
    FS_CRIT_MOUNTS+=("$mount_pt")
  elif (( pct_used >= FS_USAGE_WARN )); then
    warn "Disk usage on ${mount_pt}: ${pct_used}% — high (warn ≥${FS_USAGE_WARN}%)"
    FAIL_FS_USAGE=true
    FS_WARN_MOUNTS+=("$mount_pt")
  else
    pass "Disk usage on ${mount_pt}: ${pct_used}% — OK"
  fi
done < <(df -h --output=pcent,target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2)

# ── 9b. Inode usage per mount ────────────────────────────────────────────────
while IFS= read -r line; do
  mount_pt=$(echo "$line" | awk '{print $NF}')
  pct_used=$(echo "$line" | awk '{print $(NF-1)}' | tr -d '%')
  [ -z "$pct_used" ] || [ "$pct_used" = "-" ] && continue
  if (( pct_used >= INODE_USAGE_FAIL )); then
    fail "Inode usage on ${mount_pt}: ${pct_used}% — CRITICAL"
    FAIL_INODE=true
  elif (( pct_used >= INODE_USAGE_WARN )); then
    warn "Inode usage on ${mount_pt}: ${pct_used}% — high"
    FAIL_INODE=true
  else
    pass "Inode usage on ${mount_pt}: ${pct_used}% — OK"
  fi
done < <(df -i --output=ipcent,target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2)

# ── 9c. Filesystem error check (read-only) ──────────────────────────────────
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
if [ -n "$ROOT_DEV" ] && command -v tune2fs &>/dev/null; then
  FS_STATE=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep 'Filesystem state' | awk -F: '{print $2}' | tr -d ' ')
  FS_ERRORS=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep 'Filesystem errors' | head -1)
  FS_MOUNT_COUNT=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep 'Mount count' | awk -F: '{print $2}' | tr -d ' ')
  FS_MAX_MOUNT=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep 'Maximum mount count' | awk -F: '{print $2}' | tr -d ' ')
  FS_LAST_CHECK=$(tune2fs -l "$ROOT_DEV" 2>/dev/null | grep 'Last checked' | awk -F: '{print $2}' | sed 's/^ *//')

  info "Root device: $ROOT_DEV"
  info "Filesystem state: ${FS_STATE:-unknown}"
  info "Mount count: ${FS_MOUNT_COUNT:-?} / max ${FS_MAX_MOUNT:--1}"
  [ -n "$FS_LAST_CHECK" ] && info "Last fsck: $FS_LAST_CHECK"

  if [ "$FS_STATE" = "clean" ]; then
    pass "Root filesystem state: clean"
  else
    fail "Root filesystem state: ${FS_STATE} — needs fsck"
    FAIL_FS_ERRORS=true
  fi

  # Check if mount count exceeds max (when max is set)
  if [ -n "$FS_MOUNT_COUNT" ] && [ -n "$FS_MAX_MOUNT" ] && [ "$FS_MAX_MOUNT" != "-1" ]; then
    if (( FS_MOUNT_COUNT >= FS_MAX_MOUNT )); then
      warn "Mount count (${FS_MOUNT_COUNT}) reached max (${FS_MAX_MOUNT}) — fsck due"
      FAIL_FS_ERRORS=true
    fi
  fi

  # Check for read-only remount (a sign of prior fs errors)
  if grep -qs '\sro[\s,]' /proc/mounts 2>/dev/null | grep -q "^${ROOT_DEV}"; then
    fail "Root filesystem is mounted read-only — corruption likely"
    FAIL_FS_ERRORS=true
  fi
else
  info "Skipping filesystem state check (tune2fs not available or root device not found)"
fi

# ── 9d. SD card wear / lifetime estimate ─────────────────────────────────────
if [[ "${DISK:-none}" == /dev/mmcblk* ]]; then
  LIFE_TIME_A=""
  LIFE_TIME_B=""
  # Try sysfs path for eMMC/SD life_time (reports wear as 0x01–0x0B)
  LT_PATH="/sys/block/mmcblk0/device/life_time"
  if [ -f "$LT_PATH" ]; then
    LIFE_TIME_A=$(awk '{print $1}' "$LT_PATH" 2>/dev/null)
    LIFE_TIME_B=$(awk '{print $2}' "$LT_PATH" 2>/dev/null)
  fi

  # Some cards expose pre_eol_info instead
  EOL_PATH="/sys/block/mmcblk0/device/pre_eol_info"
  PRE_EOL=""
  [ -f "$EOL_PATH" ] && PRE_EOL=$(cat "$EOL_PATH" 2>/dev/null)

  if [ -n "$LIFE_TIME_A" ] && [ "$LIFE_TIME_A" != "0x00" ]; then
    LT_DEC=$(printf '%d' "$LIFE_TIME_A" 2>/dev/null || echo 0)
    # Values: 0x01=0-10% used, 0x02=10-20%, ..., 0x0B=90-100%
    LT_PCT_LOW=$(( (LT_DEC - 1) * 10 ))
    LT_PCT_HIGH=$(( LT_DEC * 10 ))
    info "SD wear level (Type A): ${LIFE_TIME_A} → ${LT_PCT_LOW}–${LT_PCT_HIGH}% life used"

    if (( LT_DEC >= 9 )); then
      fail "SD card nearing end of life (${LT_PCT_LOW}–${LT_PCT_HIGH}% worn) — replace soon"
      FAIL_SD_WEAR=true
    elif (( LT_DEC >= 7 )); then
      warn "SD card wear elevated (${LT_PCT_LOW}–${LT_PCT_HIGH}% worn)"
      FAIL_SD_WEAR=true
    else
      pass "SD card wear: ${LT_PCT_LOW}–${LT_PCT_HIGH}% life used — OK"
    fi
  elif [ -n "$PRE_EOL" ] && [ "$PRE_EOL" != "0x00" ]; then
    PRE_EOL_DEC=$(printf '%d' "$PRE_EOL" 2>/dev/null || echo 0)
    case $PRE_EOL_DEC in
      1) pass "SD pre-EOL status: normal" ;;
      2) warn "SD pre-EOL status: warning — card is aging"
         FAIL_SD_WEAR=true ;;
      3) fail "SD pre-EOL status: urgent — replace card immediately"
         FAIL_SD_WEAR=true ;;
      *) info "SD pre-EOL status: ${PRE_EOL} (unrecognized value)" ;;
    esac
  else
    info "SD wear data not exposed by this card (no life_time or pre_eol_info)"
  fi
fi

# ── 10. Log analysis ────────────────────────────────────────────────────────
section "LOG ANALYSIS  (current + previous boot)"

declare -a LOG_FINDINGS=()
LOG_SCAN_FAIL=false

# Patterns to scan for, grouped by severity
# Format: "severity|pattern_label|grep_pattern"
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

# Scan both current boot and previous boot via journalctl, plus dmesg
scan_logs() {
  local severity="$1" label="$2" pattern="$3"
  local count=0
  local sample=""

  # journalctl current boot
  local jc; jc=$(journalctl -b 0 --no-pager -q 2>/dev/null | grep -ciE "$pattern" 2>/dev/null || echo 0)
  count=$((count + jc))

  # journalctl previous boot (if available)
  local jp; jp=$(journalctl -b -1 --no-pager -q 2>/dev/null | grep -ciE "$pattern" 2>/dev/null || echo 0)
  count=$((count + jp))

  # dmesg as fallback / supplement
  local dm; dm=$(dmesg 2>/dev/null | grep -ciE "$pattern" 2>/dev/null || echo 0)
  # Only add dmesg count if journalctl returned 0 (avoid double-counting current boot)
  if (( jc == 0 )); then
    count=$((count + dm))
  fi

  if (( count > 0 )); then
    # Grab a sample line for context
    sample=$(journalctl -b 0 --no-pager -q 2>/dev/null | grep -iE "$pattern" 2>/dev/null | tail -1)
    [ -z "$sample" ] && sample=$(dmesg 2>/dev/null | grep -iE "$pattern" 2>/dev/null | tail -1)
    # Truncate long lines
    sample="${sample:0:120}"

    if [ "$severity" = "CRIT" ]; then
      fail "${label}: ${count} occurrence(s) in logs"
      LOG_SCAN_FAIL=true
    else
      warn "${label}: ${count} occurrence(s) in logs"
    fi
    [ -n "$sample" ] && info "  Latest: ${sample}"
    LOG_FINDINGS+=("${severity}|${label}|${count}")
  fi
}

info "Scanning kernel and system logs for known problem signatures..."
echo ""

FOUND_ANY=false
for entry in "${LOG_PATTERNS[@]}"; do
  IFS='|' read -r sev lbl pat <<< "$entry"
  scan_logs "$sev" "$lbl" "$pat"
  # Check if anything was found
  if (( ${#LOG_FINDINGS[@]} > 0 )) && [ "$FOUND_ANY" = false ]; then
    FOUND_ANY=true
  fi
done

# Set the failure flag if any CRIT-level findings
if $LOG_SCAN_FAIL; then
  FAIL_LOG_CRITICAL=true
fi

if (( ${#LOG_FINDINGS[@]} == 0 )); then
  pass "No critical or warning patterns found in recent logs"
fi

# ── 10a. OOM detail if found ─────────────────────────────────────────────────
OOM_COUNT=$(journalctl -b 0 -b -1 --no-pager -q 2>/dev/null | grep -c "Out of memory: Kill" 2>/dev/null || echo 0)
if (( OOM_COUNT > 0 )); then
  info "Last OOM-killed process:"
  journalctl -b 0 --no-pager -q 2>/dev/null | grep "Out of memory: Kill" | tail -1 \
    | sed 's/^/    /' || true
  # Show current memory pressure
  MEM_AVAIL=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
  MEM_TOTAL_MB=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
  SWAP_USED=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{printf "%.0f", (t-f)/1024}' /proc/meminfo 2>/dev/null)
  SWAP_TOTAL=$(awk '/SwapTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
  info "Current memory: ${MEM_AVAIL:-?} MB available / ${MEM_TOTAL_MB:-?} MB total"
  info "Current swap: ${SWAP_USED:-?} MB used / ${SWAP_TOTAL:-?} MB total"
fi

# ── 10b. Recent kernel/systemd errors summary ───────────────────────────────
FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if (( FAILED_UNITS > 0 )); then
  warn "Failed systemd units: ${FAILED_UNITS}"
  systemctl --failed --no-legend 2>/dev/null | sed 's/^/    /' | head -10
else
  pass "No failed systemd units"
fi

# Zombie process check
ZOMBIES=$(ps aux 2>/dev/null | awk '$8=="Z"' | wc -l)
if (( ZOMBIES > 0 )); then
  warn "Zombie processes: ${ZOMBIES}"
  ps aux 2>/dev/null | awk '$8=="Z"' | head -5 | sed 's/^/    /'
else
  pass "No zombie processes"
fi

# ── 11. Final temperature ────────────────────────────────────────────────────
section "FINAL TEMPERATURE"
check_temp "Final idle"

# ── 12. Health summary ───────────────────────────────────────────────────────
TOTAL=$(( PASS + WARN + FAIL ))

echo -e "\n${CYAN}${BOLD}$(printf '═%.0s' {1..70})${RESET}"
echo -e "${CYAN}${BOLD}  HEALTH REPORT SUMMARY  —  $MODEL${RESET}"
echo -e "${CYAN}${BOLD}$(printf '═%.0s' {1..70})${RESET}"

for line in "${REPORT_LINES[@]}"; do
  echo -e "  $line"
done

echo -e "\n${CYAN}$(printf '─%.0s' {1..70})${RESET}"
echo -e "  ${GREEN}${BOLD}PASS: $PASS${RESET}   ${YELLOW}${BOLD}WARN: $WARN${RESET}   ${RED}${BOLD}FAIL: $FAIL${RESET}   (of $TOTAL checks)"

if (( FAIL > 0 )); then
  echo -e "\n  ${RED}${BOLD}⚠  OVERALL: UNHEALTHY — hardware issues detected${RESET}"
elif (( WARN >= 3 )); then
  echo -e "\n  ${YELLOW}${BOLD}⚠  OVERALL: DEGRADED — multiple warnings, investigate${RESET}"
elif (( WARN > 0 )); then
  echo -e "\n  ${YELLOW}${BOLD}~  OVERALL: ACCEPTABLE — minor warnings present${RESET}"
else
  echo -e "\n  ${GREEN}${BOLD}✓  OVERALL: HEALTHY — all checks passed${RESET}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# ── 13. AUTO-FIX / REMEDIATION ───────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

ANY_ISSUE=false
if [[ "$FAIL_CPU_SLOW"   == true || "$FAIL_DISK_READ"    == true || \
      "$FAIL_DISK_WRITE" == true || "$FAIL_THROTTLE"     == true || \
      "$FAIL_TEMP"       == true || "$FAIL_SD_CLOCK"     == true || \
      "$FAIL_FS_USAGE"   == true || "$FAIL_INODE"        == true || \
      "$FAIL_FS_ERRORS"  == true || "$FAIL_SD_WEAR"      == true || \
      "$FAIL_LOG_CRITICAL" == true ]]; then
  ANY_ISSUE=true
fi

if $ANY_ISSUE; then
  echo ""
  echo -e "${CYAN}${BOLD}$(printf '═%.0s' {1..70})${RESET}"
  if $AUTO_FIX; then
    if $DRY_RUN; then
      echo -e "${MAGENTA}${BOLD}  REMEDIATION (DRY-RUN — no changes applied)${RESET}"
    else
      echo -e "${MAGENTA}${BOLD}  REMEDIATION — APPLYING FIXES${RESET}"
    fi
  else
    echo -e "${MAGENTA}${BOLD}  REMEDIATION — RECOMMENDED FIXES${RESET}"
    echo -e "${WHITE}  Run with ${BOLD}--fix${RESET}${WHITE} to apply automatically, or ${BOLD}--dry-run${RESET}${WHITE} to preview${RESET}"
  fi
  echo -e "${CYAN}${BOLD}$(printf '═%.0s' {1..70})${RESET}"

  # ── FIX: CPU governor persistence ─────────────────────────────────────────
  if $FAIL_CPU_SLOW; then
    section "FIX: CPU PERFORMANCE"
    CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")

    if [ "$CURRENT_GOV" != "performance" ]; then
      if $AUTO_FIX && ! $DRY_RUN; then
        # Set governor now
        for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
          echo "performance" > "$cpu_gov" 2>/dev/null
        done
        fix "Set CPU governor to 'performance' (was '${CURRENT_GOV}')"

        # Make persistent via rc.local
        if ! grep -q 'scaling_governor' /etc/rc.local 2>/dev/null; then
          if [ ! -f /etc/rc.local ]; then
            cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
# Set CPU governor to performance on boot — added by rpi-healthbench
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo "performance" > "$gov" 2>/dev/null
done
exit 0
RCEOF
            chmod +x /etc/rc.local
            fix "Created /etc/rc.local with performance governor on boot"
          else
            sed -i '/^exit 0/i # Set CPU governor to performance — added by rpi-healthbench\nfor gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "performance" > "$gov" 2>/dev/null; done' /etc/rc.local
            fix "Added performance governor to existing /etc/rc.local"
          fi
        else
          info "Governor persistence already configured in /etc/rc.local"
        fi
      else
        suggest "Set CPU governor to 'performance' (currently '${CURRENT_GOV}')"
        info "  → echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
        info "  → Add to /etc/rc.local for persistence across reboots"
      fi
    else
      info "CPU governor already set to 'performance'"
      suggest "CPU still slow at performance governor — check for thermal throttling or background load"
      info "  → Run: top -bn1 | head -20   (check for CPU-hungry processes)"
    fi
  fi

  # ── FIX: Throttle / under-voltage ─────────────────────────────────────────
  if $FAIL_THROTTLE; then
    section "FIX: VOLTAGE / THROTTLE"
    suggest "Under-voltage or throttling detected — hardware issue"
    info "  → Use the official Raspberry Pi USB-C power supply (5V 5A for Pi 5)"
    info "  → Disconnect power-hungry USB peripherals"
    info "  → Check cable quality — thin/cheap cables cause voltage drop"
    if [[ "$MODEL" == *"Pi 5"* ]]; then
      info "  → Pi 5 requires USB-PD supply for full 25W; 5V/3A triggers warnings"
    fi
  fi

  # ── FIX: Temperature ──────────────────────────────────────────────────────
  if $FAIL_TEMP; then
    section "FIX: TEMPERATURE"
    suggest "High temperature detected — cooling needed"
    info "  → Install a heatsink (critical for Pi 4/5)"
    info "  → Use the official active cooler or a fan HAT"
    info "  → Ensure case has adequate ventilation"
    if [ -n "$CONFIG_TXT" ]; then
      if ! grep -q 'dtoverlay=gpio-fan\|cooling_fan' "$CONFIG_TXT" 2>/dev/null; then
        if $AUTO_FIX && ! $DRY_RUN && [[ "$MODEL" == *"Pi 5"* ]]; then
          echo "" >> "$CONFIG_TXT"
          echo "# Active cooling — auto-added by rpi-healthbench" >> "$CONFIG_TXT"
          echo "dtparam=fan_temp0=50000,fan_temp0_hyst=5000" >> "$CONFIG_TXT"
          fix "Enabled active fan at 50°C threshold in config.txt (reboot to apply)"
        else
          suggest "Add fan control to $CONFIG_TXT if fan hardware is installed"
        fi
      fi
    fi
  fi

  # ── FIX: Slow SD card ─────────────────────────────────────────────────────
  if ($FAIL_DISK_READ || $FAIL_DISK_WRITE) && [[ "${DISK:-none}" == /dev/mmcblk* ]]; then
    section "FIX: SLOW SD CARD I/O"

    # Schedule filesystem check on next reboot
    ROOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [ -n "$ROOT_PART" ]; then
      info "Root partition: $ROOT_PART"
      if $AUTO_FIX && ! $DRY_RUN; then
        touch /forcefsck 2>/dev/null && fix "Created /forcefsck — filesystem check on next reboot"
      else
        suggest "Schedule filesystem check on next reboot"
        info "  → sudo touch /forcefsck   (then reboot)"
      fi
    fi

    # Check for I/O-heavy background processes
    info "Checking for I/O-heavy background processes..."
    if command -v iotop &>/dev/null; then
      IO_HOGS=$(iotop -b -n1 -qqq -o 2>/dev/null | head -5)
    else
      IO_HOGS=$(ps aux --sort=-%mem | awk 'NR<=6{print}')
    fi
    [ -n "$IO_HOGS" ] && { info "Top I/O consumers:"; echo "$IO_HOGS" | sed 's/^/    /'; }

    # Tune I/O scheduler for SD cards
    SCHED_PATH="/sys/block/mmcblk0/queue/scheduler"
    if [ -f "$SCHED_PATH" ]; then
      CURRENT_SCHED=$(grep -oP '\[\K[^\]]+' "$SCHED_PATH" || echo "")
      CURRENT_SCHED=${CURRENT_SCHED:-unknown}
      info "Current I/O scheduler: $CURRENT_SCHED"
      if [ "$CURRENT_SCHED" != "deadline" ] && [ "$CURRENT_SCHED" != "mq-deadline" ]; then
        if $AUTO_FIX && ! $DRY_RUN; then
          echo "mq-deadline" > "$SCHED_PATH" 2>/dev/null || echo "deadline" > "$SCHED_PATH" 2>/dev/null
          NEW_SCHED=$(grep -oP '\[\K[^\]]+' "$SCHED_PATH" || echo "")
          NEW_SCHED=${NEW_SCHED:-unknown}
          fix "Changed I/O scheduler: ${CURRENT_SCHED} → ${NEW_SCHED}"
          # Persist via udev rule
          UDEV_RULE="/etc/udev/rules.d/60-sd-scheduler.rules"
          if [ ! -f "$UDEV_RULE" ]; then
            echo 'ACTION=="add|change", KERNEL=="mmcblk*", ATTR{queue/scheduler}="mq-deadline"' > "$UDEV_RULE"
            fix "Created udev rule for persistent mq-deadline scheduler"
          fi
        else
          suggest "Switch I/O scheduler to mq-deadline (better for SD cards)"
          info "  → echo mq-deadline | sudo tee $SCHED_PATH"
        fi
      else
        info "I/O scheduler already optimal ($CURRENT_SCHED)"
      fi
    fi

    # Increase SD read-ahead buffer
    RA_PATH="/sys/block/mmcblk0/queue/read_ahead_kb"
    if [ -f "$RA_PATH" ]; then
      CURRENT_RA=$(cat "$RA_PATH")
      if (( CURRENT_RA < 1024 )); then
        if $AUTO_FIX && ! $DRY_RUN; then
          echo 2048 > "$RA_PATH" 2>/dev/null
          fix "Increased SD read-ahead buffer: ${CURRENT_RA} KB → 2048 KB"
        else
          suggest "Increase SD read-ahead buffer from ${CURRENT_RA} KB to 2048 KB"
          info "  → echo 2048 | sudo tee $RA_PATH"
        fi
      fi
    fi

    # Disable SD card polling in config.txt
    if [ -n "$CONFIG_TXT" ]; then
      if ! grep -qP '^\s*dtparam=sd_poll_once' "$CONFIG_TXT" 2>/dev/null; then
        if $AUTO_FIX && ! $DRY_RUN; then
          echo "" >> "$CONFIG_TXT"
          echo "# SD card optimization — auto-added by rpi-healthbench" >> "$CONFIG_TXT"
          echo "dtparam=sd_poll_once" >> "$CONFIG_TXT"
          fix "Added dtparam=sd_poll_once to config.txt (reboot to apply)"
        else
          suggest "Add dtparam=sd_poll_once to $CONFIG_TXT (reduces SD overhead)"
        fi
      fi
    fi

    # Hardware upgrade suggestion
    echo ""
    suggest "SD card is a bottleneck — consider upgrading storage:"
    if [[ "$MODEL" == *"Pi 5"* ]]; then
      info "  → NVMe SSD via M.2 HAT (expect 800+ MB/s read, 600+ MB/s write)"
      info "  → USB 3.0 SSD via UASP enclosure (expect 350+ MB/s)"
    elif [[ "$MODEL" == *"Pi 4"* ]]; then
      info "  → USB 3.0 SSD via UASP enclosure (expect 350+ MB/s)"
    fi
    info "  → At minimum, use a UHS-I A2 class SD card (expect 40+ MB/s read)"
  fi

  # ── FIX: SD clock not optimal ──────────────────────────────────────────────
  if $FAIL_SD_CLOCK && [[ "${DISK:-none}" == /dev/mmcblk* ]]; then
    section "FIX: SD BUS SPEED"
    info "SD card not running at maximum bus speed"
    suggest "Ensure your SD card supports UHS-I / SDR104 mode"
    info "  → A2-rated cards generally support SDR104 (100+ MHz)"
    info "  → Check dmesg | grep mmc0 for negotiation details"
  fi

  # ── FIX: Filesystem usage ──────────────────────────────────────────────────
  if $FAIL_FS_USAGE; then
    section "FIX: DISK SPACE"

    # Quantify reclaimable space from common safe targets
    APT_CACHE_MB=$(du -sm /var/cache/apt/archives 2>/dev/null | awk '{print $1}')
    APT_CACHE_MB=${APT_CACHE_MB:-0}
    JOURNAL_MB=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9]+(\.[0-9]+)?\s*[MG]' | head -1 || echo "")
    THUMB_MB=$(du -sm /home/*/.cache/thumbnails 2>/dev/null | awk '{s+=$1} END{printf "%d",s}')
    THUMB_MB=${THUMB_MB:-0}

    info "Reclaimable space estimates:"
    info "  apt cache    : ~${APT_CACHE_MB} MB"
    info "  journal logs : ${JOURNAL_MB:-unknown}"
    info "  thumbnails   : ~${THUMB_MB} MB"

    if $AUTO_FIX && ! $DRY_RUN; then
      # Clean apt caches
      apt-get clean -qq 2>/dev/null
      fix "Cleaned apt package cache"

      # Remove orphaned packages
      ORPHANS=$(apt-get autoremove --dry-run 2>/dev/null | grep -c "^Remv" || echo 0)
      if (( ORPHANS > 0 )); then
        apt-get autoremove -y -qq 2>/dev/null
        fix "Removed ${ORPHANS} orphaned package(s)"
      fi

      # Vacuum journal to 50 MB
      journalctl --vacuum-size=50M 2>/dev/null
      fix "Vacuumed systemd journal to 50 MB"

      # Clean thumbnail caches
      if (( THUMB_MB > 10 )); then
        rm -rf /home/*/.cache/thumbnails/* 2>/dev/null
        fix "Cleared thumbnail caches (~${THUMB_MB} MB)"
      fi

      # Clean old tmp files (>7 days)
      TMPCLEAN=$(find /tmp -type f -mtime +7 2>/dev/null | wc -l)
      if (( TMPCLEAN > 0 )); then
        find /tmp -type f -mtime +7 -delete 2>/dev/null
        fix "Removed ${TMPCLEAN} old temp files from /tmp"
      fi
    else
      suggest "Clean apt cache: sudo apt-get clean"
      suggest "Remove orphaned packages: sudo apt-get autoremove -y"
      suggest "Vacuum journal logs: sudo journalctl --vacuum-size=50M"
      if (( THUMB_MB > 10 )); then
        suggest "Clear thumbnail caches (~${THUMB_MB} MB)"
      fi
      info "  → Run with --fix to apply these automatically"
    fi

    # Flag critical mounts for manual attention
    if (( ${#FS_CRIT_MOUNTS[@]} > 0 )); then
      echo ""
      suggest "Critical mounts need manual attention:"
      for m in "${FS_CRIT_MOUNTS[@]}"; do
        info "  → ${m}: identify and remove large files"
        info "    du -ah ${m} | sort -rh | head -20   (find largest files)"
      done
    fi
  fi

  # ── FIX: Inode exhaustion ──────────────────────────────────────────────────
  if $FAIL_INODE; then
    section "FIX: INODE USAGE"
    suggest "Inode usage is high — many small files consuming directory entries"
    info "  → Find directories with excessive file counts:"
    info "    find / -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head -20"
    info "  → Common culprits: /tmp, mail spools, PHP sessions, log rotation"
  fi

  # ── FIX: Filesystem errors ────────────────────────────────────────────────
  if $FAIL_FS_ERRORS; then
    section "FIX: FILESYSTEM ERRORS"
    if $AUTO_FIX && ! $DRY_RUN; then
      if [ ! -f /forcefsck ]; then
        touch /forcefsck 2>/dev/null && fix "Created /forcefsck — filesystem check on next reboot"
      else
        info "/forcefsck already exists — fsck will run on next reboot"
      fi
    else
      suggest "Schedule filesystem check: sudo touch /forcefsck && sudo reboot"
    fi
    info "  → For immediate (offline) check: boot from USB and run:"
    info "    sudo e2fsck -fvy ${ROOT_DEV:-/dev/mmcblk0p2}"
  fi

  # ── FIX: SD card wear ─────────────────────────────────────────────────────
  if $FAIL_SD_WEAR; then
    section "FIX: SD CARD WEAR"
    suggest "SD card is wearing out — back up and replace soon"
    info "  → Create full backup:  sudo dd if=/dev/mmcblk0 of=/path/to/backup.img bs=4M status=progress"
    info "  → Or use rpi-clone:    sudo rpi-clone sda  (clone to USB drive)"
    info "  → Reduce write amplification:"
    info "    - Move /tmp to tmpfs:  echo 'tmpfs /tmp tmpfs defaults,noatime,size=100m 0 0' >> /etc/fstab"
    info "    - Move logs to tmpfs:  echo 'tmpfs /var/log tmpfs defaults,noatime,size=50m 0 0' >> /etc/fstab"

    # Offer to reduce writes if card is heavily worn
    if $AUTO_FIX && ! $DRY_RUN; then
      # Add noatime to root mount if not already present
      if ! grep -qP '\s/\s.*noatime' /etc/fstab 2>/dev/null; then
        sed -i 's|\(\s/\s\+\S\+\s\+\)\(\S\+\)|\1\2,noatime|' /etc/fstab 2>/dev/null \
          && fix "Added noatime to root mount in fstab (reboot to apply)"
      fi

      # Reduce swappiness to minimize SD writes
      CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
      if (( CURRENT_SWAPPINESS > 10 )); then
        sysctl -w vm.swappiness=10 >/dev/null 2>&1
        if ! grep -q 'vm.swappiness' /etc/sysctl.d/99-healthbench.conf 2>/dev/null; then
          echo "vm.swappiness=10" >> /etc/sysctl.d/99-healthbench.conf
          fix "Reduced swappiness: ${CURRENT_SWAPPINESS} → 10 (persistent)"
        fi
      fi
    else
      suggest "Add noatime to root mount in /etc/fstab to reduce writes"
      suggest "Reduce swappiness: echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-healthbench.conf"
    fi
  fi

  # ── FIX: Critical log findings ────────────────────────────────────────────
  if $FAIL_LOG_CRITICAL; then
    section "FIX: CRITICAL LOG EVENTS"

    # Triage by finding type
    for entry in "${LOG_FINDINGS[@]}"; do
      IFS='|' read -r sev lbl cnt <<< "$entry"
      [ "$sev" != "CRIT" ] && continue

      case "$lbl" in
        "Kernel panic")
          suggest "Kernel panics detected (${cnt}x) — may indicate RAM or firmware issues"
          info "  → Test RAM: sudo memtester $(( $(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo) / 2 ))M 1"
          info "  → Update firmware: sudo rpi-update   (use with caution)"
          info "  → Review: journalctl -b -1 -p 0   (previous boot critical messages)"
          ;;
        "Out of memory killer")
          suggest "OOM kills detected (${cnt}x) — system running out of RAM"
          info "  → Increase swap:  sudo dphys-swapfile swapoff && sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile && sudo dphys-swapfile setup && sudo dphys-swapfile swapon"
          info "  → Reduce memory pressure: disable unused services"
          info "  → Monitor: watch -n1 free -m"
          if $AUTO_FIX && ! $DRY_RUN; then
            # Increase swap if currently small
            SWAP_SIZE=$(grep 'CONF_SWAPSIZE' /etc/dphys-swapfile 2>/dev/null | grep -oP '\d+' || echo 0)
            if (( SWAP_SIZE < 512 )) && [ -f /etc/dphys-swapfile ]; then
              dphys-swapfile swapoff 2>/dev/null
              sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile 2>/dev/null
              dphys-swapfile setup 2>/dev/null
              dphys-swapfile swapon 2>/dev/null
              fix "Increased swap from ${SWAP_SIZE} MB to 1024 MB"
            fi
          fi
          ;;
        "Filesystem remounted read-only"|"I/O error on block device"|"ext4 filesystem error"|"MMC/SD I/O error")
          suggest "${lbl} detected (${cnt}x) — storage reliability issue"
          info "  → Back up data immediately"
          info "  → Schedule fsck: sudo touch /forcefsck && sudo reboot"
          info "  → If persistent, replace the SD card / storage device"
          if $AUTO_FIX && ! $DRY_RUN; then
            if [ ! -f /forcefsck ]; then
              touch /forcefsck 2>/dev/null && fix "Created /forcefsck — filesystem check on next reboot"
            fi
          fi
          ;;
      esac
    done

    # General log review guidance
    echo ""
    info "For deeper investigation:"
    info "  → Critical current boot:  journalctl -b 0 -p 0..3 --no-pager"
    info "  → Critical previous boot: journalctl -b -1 -p 0..3 --no-pager"
    info "  → Kernel ring buffer:     dmesg -l err,warn | tail -40"
  fi

  # ── Summary of actions ─────────────────────────────────────────────────────
  echo ""
  echo -e "${CYAN}${BOLD}$(printf '─%.0s' {1..70})${RESET}"
  if (( ${#FIX_ACTIONS[@]} > 0 )); then
    echo -e "  ${MAGENTA}${BOLD}FIXES APPLIED: ${#FIX_ACTIONS[@]}${RESET}"
    for a in "${FIX_ACTIONS[@]}"; do
      echo -e "    ${MAGENTA}✓${RESET} $a"
    done
  fi
  if (( ${#FIX_SUGGESTIONS[@]} > 0 )); then
    echo -e "  ${YELLOW}${BOLD}MANUAL SUGGESTIONS: ${#FIX_SUGGESTIONS[@]}${RESET}"
    for s in "${FIX_SUGGESTIONS[@]}"; do
      echo -e "    ${YELLOW}→${RESET} $s"
    done
  fi

  NEEDS_REBOOT=false
  for a in "${FIX_ACTIONS[@]}"; do
    [[ "$a" == *"reboot"* || "$a" == *"config.txt"* || "$a" == *"forcefsck"* ]] && NEEDS_REBOOT=true
  done

  if $NEEDS_REBOOT; then
    echo ""
    echo -e "  ${RED}${BOLD}⚡ REBOOT REQUIRED for some changes to take effect${RESET}"
    echo -e "  ${WHITE}Run: sudo reboot${RESET}"
  fi
elif (( FAIL == 0 && WARN == 0 )); then
  echo ""
  echo -e "  ${GREEN}${BOLD}No remediation needed — system is healthy.${RESET}"
fi

echo -e "${CYAN}${BOLD}$(printf '═%.0s' {1..70})${RESET}\n"
