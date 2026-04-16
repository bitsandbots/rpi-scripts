#!/bin/bash
# ============================================================
#  Ollama Performance Optimizer for Raspberry Pi 5
#  Usage: sudo bash ollama-pi5-optimize.sh [--dry-run]
# ============================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && warn "Dry-run mode — no changes will be made."

run() {
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $*"
  else
    "$@"
  fi
}

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
  error "Please run as root: sudo bash $0"
  exit 1
fi

# ── Banner ───────────────────────────────────────────────────
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Ollama Pi5 Optimizer  v1.0              ║"
echo "  ║   Raspberry Pi 5 · $(date +%Y-%m-%d)              ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Detect RAM ───────────────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(( TOTAL_RAM_KB / 1024 / 1024 ))

header "System Detection"
info "Detected RAM: ~${TOTAL_RAM_GB} GB"

if   (( TOTAL_RAM_GB <= 4 ));  then RAM_TIER=4;  GPU_MEM=128
elif (( TOTAL_RAM_GB <= 8 ));  then RAM_TIER=8;  GPU_MEM=256
else                                RAM_TIER=16; GPU_MEM=512
fi
info "RAM tier: ${RAM_TIER}GB  →  GPU memory split: ${GPU_MEM}MB"

# ── Recommend models ─────────────────────────────────────────
header "Recommended Models for ${RAM_TIER}GB RAM"
case $RAM_TIER in
  4)  echo -e "  ${GREEN}✔${RESET} tinyllama:1.1b-chat-q4_0"
      echo -e "  ${GREEN}✔${RESET} phi3:mini-4k-instruct-q4_K_M"
      echo -e "  ${GREEN}✔${RESET} gemma:2b-instruct-q4_0"
      echo -e "  ${RED}✘${RESET} (avoid 7B+ models)" ;;
  8)  echo -e "  ${GREEN}✔${RESET} llama3.2:3b-instruct-q4_K_M"
      echo -e "  ${GREEN}✔${RESET} mistral:7b-instruct-q4_0"
      echo -e "  ${GREEN}✔${RESET} phi3:medium-4k-instruct-q4_K_M"
      echo -e "  ${RED}✘${RESET} (avoid 13B+ models)" ;;
  16) echo -e "  ${GREEN}✔${RESET} llama3.1:8b-instruct-q4_K_M"
      echo -e "  ${GREEN}✔${RESET} mistral:7b-instruct-q8_0"
      echo -e "  ${GREEN}✔${RESET} deepseek-r1:8b-q4_K_M"
      echo -e "  ${RED}✘${RESET} (avoid 70B models)" ;;
esac

# ── 1. Ollama systemd override ────────────────────────────────
header "Step 1/5 · Ollama systemd Tuning"

OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/pi5-performance.conf"

if ! command -v ollama &>/dev/null; then
  warn "Ollama not found — skipping systemd tuning (install Ollama first)."
else
  run "mkdir -p $OVERRIDE_DIR"
  run "cat > $OVERRIDE_FILE << 'EOF'
[Service]
Environment=\"OLLAMA_NUM_PARALLEL=1\"
Environment=\"OLLAMA_MAX_LOADED_MODELS=1\"
Environment=\"OLLAMA_FLASH_ATTENTION=1\"
Environment=\"OLLAMA_NUM_THREAD=4\"
Environment=\"OLLAMA_KEEP_ALIVE=5m\"
EOF"
  run "systemctl daemon-reload"
  run "systemctl restart ollama"
  success "Ollama service tuned and restarted."
fi

# ── 2. GPU memory split ───────────────────────────────────────
header "Step 2/5 · GPU Memory Split (gpu_mem=${GPU_MEM})"

CONFIG_FILE="/boot/firmware/config.txt"
if [[ ! -f "$CONFIG_FILE" ]]; then
  warn "$CONFIG_FILE not found — skipping GPU memory split."
else
  if grep -q "^gpu_mem=" "$CONFIG_FILE"; then
    run "sed -i 's/^gpu_mem=.*/gpu_mem=${GPU_MEM}/' $CONFIG_FILE"
  else
    run "echo 'gpu_mem=${GPU_MEM}' >> $CONFIG_FILE"
  fi
  success "gpu_mem set to ${GPU_MEM}MB in $CONFIG_FILE (reboot required)."
fi

# ── 3. CPU governor ───────────────────────────────────────────
header "Step 3/5 · CPU Performance Governor"

GOVERNOR_FILE="/etc/systemd/system/cpu-performance.service"
run "cat > $GOVERNOR_FILE << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"
run "systemctl enable --now cpu-performance.service"

# Apply immediately (not just on next boot)
if ! $DRY_RUN; then
  echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
fi
success "CPU governor set to 'performance' (persists across reboots)."

# ── 4. Swap optimisation ──────────────────────────────────────
header "Step 4/5 · Swap Optimisation"

# Disable legacy dphys-swapfile if present
if systemctl is-enabled dphys-swapfile &>/dev/null 2>&1; then
  run "systemctl disable --now dphys-swapfile"
  success "Disabled dphys-swapfile (disk swap hurts LLM performance)."
else
  info "dphys-swapfile not active — skipping."
fi

# Set up zram if not already done
if ! command -v zramctl &>/dev/null; then
  warn "zramctl not found — skipping zram setup."
else
  ZRAM_CONF="/etc/systemd/zram-generator.conf"
  if [[ ! -f "$ZRAM_CONF" ]]; then
    # zram-generator package path
    run "apt-get install -y zram-tools 2>/dev/null || true"
  fi

  ZRAM_SIZE=$(( TOTAL_RAM_GB / 2 ))G
  run "cat > /etc/default/zramswap << EOF
ALGO=lz4
PERCENT=50
EOF"
  run "systemctl enable --now zramswap 2>/dev/null || true"
  success "zram swap configured (~${ZRAM_SIZE}) with lz4 compression."
fi

# Tune swappiness
run "sysctl -w vm.swappiness=10"
run "echo 'vm.swappiness=10' > /etc/sysctl.d/99-ollama-swap.conf"
success "vm.swappiness set to 10."

# ── 5. SSD model path ─────────────────────────────────────────
header "Step 5/5 · SSD / Fast Storage for Models"

# Detect if a USB SSD is mounted
SSD_MOUNT=$(lsblk -o MOUNTPOINT,TRAN | awk '$2=="usb" && $1!="" {print $1}' | head -1)

if [[ -n "$SSD_MOUNT" ]]; then
  MODEL_PATH="$SSD_MOUNT/ollama-models"
  run "mkdir -p $MODEL_PATH"

  PROFILE_LINE="export OLLAMA_MODELS=$MODEL_PATH"
  if ! grep -qF "OLLAMA_MODELS" /etc/environment 2>/dev/null; then
    run "echo 'OLLAMA_MODELS=$MODEL_PATH' >> /etc/environment"
  fi
  # Also add to systemd override if it exists
  if [[ -f "$OVERRIDE_FILE" ]]; then
    run "sed -i '/OLLAMA_MODELS/d' $OVERRIDE_FILE"
    run "echo 'Environment=\"OLLAMA_MODELS=$MODEL_PATH\"' >> $OVERRIDE_FILE"
    run "systemctl daemon-reload && systemctl restart ollama"
  fi
  success "Model path set to $MODEL_PATH (USB SSD detected at $SSD_MOUNT)."
else
  warn "No USB SSD detected. Models will be stored in default ~/.ollama/models."
  info "Tip: Mount an SSD and re-run this script for 5–10× faster model loading."
fi

# ── Optional overclock prompt ─────────────────────────────────
header "Optional · CPU Overclock"
echo -e "  Overclocking to 2800 MHz can improve token throughput ~15%."
echo -e "  ${RED}Requires active cooling!${RESET} SD card users: this may cause instability.\n"

if $DRY_RUN; then
  info "[dry-run] Skipping overclock prompt."
else
  read -r -p "  Enable overclock (2800 MHz)? Requires reboot + active cooling [y/N]: " OC_CHOICE
  if [[ "${OC_CHOICE,,}" == "y" ]]; then
    if grep -q "^arm_freq=" "$CONFIG_FILE" 2>/dev/null; then
      sed -i 's/^arm_freq=.*/arm_freq=2800/' "$CONFIG_FILE"
    else
      echo -e "\n# Ollama Pi5 overclock\nover_voltage=6\narm_freq=2800" >> "$CONFIG_FILE"
    fi
    success "Overclock enabled. Reboot required."
  else
    info "Overclock skipped."
  fi
fi

# ── Summary ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════╗"
echo -e "║         Optimisation Complete! 🚀         ║"
echo -e "╚═══════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Changes applied:${RESET}"
echo -e "  ✔ Ollama service tuned (parallelism, threads, flash attention)"
echo -e "  ✔ GPU memory split → ${GPU_MEM}MB"
echo -e "  ✔ CPU governor → performance (persistent)"
echo -e "  ✔ Swap → zram/lz4 + swappiness=10"
[[ -n "${SSD_MOUNT:-}" ]] && echo -e "  ✔ Model path → USB SSD ($MODEL_PATH)"
echo ""
echo -e "  ${YELLOW}⚠ A reboot is recommended to apply all changes.${RESET}"
echo -e "  Run: ${CYAN}sudo reboot${RESET}\n"

# ── Quick-test helper ─────────────────────────────────────────
echo -e "  ${BOLD}Quick benchmark after reboot:${RESET}"
echo -e "  ${CYAN}ollama run tinyllama 'Explain quantum computing in 3 sentences'${RESET}"
echo ""
