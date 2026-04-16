# rpi-scripts — Raspberry Pi Administration Tools

## Overview

**rpi-scripts** is a collection of bash utilities for Raspberry Pi system administration, monitoring, and optimization. Created by [CoreConduit Consulting Services](https://coreconduit.com), these tools empower system administrators and developers to maintain healthy, high-performance Raspberry Pi deployments—particularly suited for self-hosted AI and IoT edge computing scenarios.

### Project Goals

- **Health Monitoring**: Detect hardware issues, performance bottlenecks, and system degradation before they become critical
- **Performance Optimization**: Automatically tune system configurations for specific workloads (especially LLM inference with Ollama)
- **Simplified Operations**: Provide one-command utilities for common Pi administration tasks
- **Educational**: Serve as reference implementations for Raspberry Pi system internals

## Quick Start

```bash
# Mount USB drives
sudo ./usb-mount.sh

# Check system health
sudo ./rpi-healthbench.sh

# Optimize Ollama for Pi 5
sudo ./ollama-pi5-optimize.sh
```

## Documentation Structure

| Document | Purpose |
|----------|---------|
| [Usage Guide](usage.md) | Complete CLI reference and examples |
| [Architecture](architecture.md) | System design and data flow |
| [Tech Stack](tech-stack.md) | Dependencies, versions, and tools |
| [Development](development.md) | Contributing and testing |
| Component Docs | Detailed module documentation |

## Components

### usb-mount.sh

Auto-detects and mounts USB storage devices with filesystem-specific options.

**Key Features**:
- JSON-parsed `lsblk` output for reliable detection
- Filesystem-specific mount options (vfat, exfat, ntfs, ext4, etc.)
- Mount point at `/mnt/usb/<label>`

### rpi-healthbench.sh

Comprehensive health benchmark with model-specific thresholds and auto-fix capabilities.

**Key Features**:
- Hardware detection (Pi 2-5, Zero variants)
- CPU, memory, and disk benchmarks
- Throttle/voltage status analysis
- Filesystem and SD card health checks
- Log analysis with pattern matching
- Auto-fix with `--fix` flag

**Thresholds**:
| Model | CPU Min | Temp Warn | Temp Fail |
|-------|---------|-----------|-----------|
| Pi 5 | 2400 MHz | 70°C | 80°C |
| Pi 4 | 1800 MHz | 70°C | 80°C |
| Pi 3 | 1200 MHz | 68°C | 78°C |
| Pi 2 | 900 MHz | 68°C | 78°C |

### ollama-pi5-optimize.sh

System optimizer for Ollama LLM inference on Raspberry Pi 5.

**Key Features**:
- RAM tier detection (4GB, 8GB, 16GB+)
- GPU memory split configuration
- CPU governor → performance mode
- zram swap + low swappiness
- SSD model path detection
- Optional overclock (2800 MHz)

## Tech Stack

| Component | Version |
|-----------|---------|
| Shell | Bash 5.0+ |
| Benchmarking | sysbench 1.0+ |
| Disk Tests | hdparm, dd |
| System Info | vcgencmd, systemd |
| Python | 3.8+ (JSON parsing) |

## Requirements

- Raspberry Pi 2+ (tested on 2, 3, 4, 5, Zero 2)
- Raspberry Pi OS / Debian Bookworm or newer
- Root access (`sudo`)
- Dependencies: `bc`, `hdparm`, `sysbench`

## License

MIT - See LICENSE file in repository root.

## Author

CoreConduit Consulting Services  
https://coreconduit.com
