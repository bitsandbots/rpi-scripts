# Development Guide

## Directory Structure

```
rpi-scripts/
├── docs/               # This documentation
│   ├── index.md        # Project overview
│   ├── architecture.md # High-level design
│   ├── tech-stack.md   # Dependencies and versions
│   ├── usage.md        # User guide
│   └── components/     # Component-specific docs
│       ├── usb-mount.md
│       ├── healthbench.md
│       └── ollama-optimize.md
├── .remember/          # Session state (auto-created)
├── .git/               # Git repository
├── ollama-pi5-optimize.sh
├── rpi-healthbench.sh
└── usb-mount.sh
```

## Code Style

### Shell Scripting (bash)

- **Style**: Follow existing patterns in scripts
- **Error handling**: `set -euo pipefail` at top of all scripts
- **Line length**: Max 80 characters (consistent with existing scripts)
- **Comments**: Use `─` box-drawing characters for section headers

### Color Output

Use the color constants defined at top of each script:
- `RED`, `YELLOW`, `GREEN`, `CYAN`, `BLUE`, `MAGENTA`, `WHITE`
- `BOLD`, `RESET` for formatting

### Variable Naming

- Constants: `UPPERCASE` (e.g., `MOUNT_BASE`, `TEMP_WARN`)
- Function locals: `snake_case` (e.g., `mount_point`, `cpu_temp`)
- Globals: `CAPITALS` for exported values (e.g., `FAIL_TEMP`)

## Testing Scripts

### Manual Testing

```bash
# Test without modifying system (dry-run)
sudo ./ollama-pi5-optimize.sh --dry-run
sudo ./rpi-healthbench.sh --dry-run
```

### Linting

```bash
# Install shellcheck
sudo apt-get install shellcheck

# Run linter
shellcheck ollama-pi5-optimize.sh rpi-healthbench.sh usb-mount.sh
```

### Formatting

```bash
# Install shfmt
sudo apt-get install shfmt

# Format all scripts
shfmt -w ollama-pi5-optimize.sh rpi-healthbench.sh usb-mount.sh
```

## Git Workflow

### Branching

- `main` - Production-ready code
- `feature/*` - New features
- `fix/*` - Bug fixes

### Commit Messages

```
chore: initial commit - Raspberry Pi admin scripts
feat(healthbench): add NVMe SSD support
fix(usb-mount): handle missing lsblk -J gracefully
docs: add component documentation
```

### Pre-commit Checklist

- [ ] Scripts run without errors (`bash -n script.sh`)
- [ ] Dry-run mode works correctly
- [ ] No hardcoded secrets or paths
- [ ] Root check present for scripts requiring sudo
- [ ] Dependencies checked before use

## Adding New Scripts

1. Create script with shebang: `#!/bin/bash`
2. Add `set -euo pipefail` after shebang
3. Define colors and helper functions
4. Add CLI flag parsing (`--help`, `--dry-run`)
5. Implement main logic
6. Add cleanup trap if needed
7. Test with `--dry-run`

## Documentation Standards

- **Component docs**: Detailed function reference, data structures, key paths
- **Usage docs**: CLI options, examples, troubleshooting
- **Architecture docs**: Data flow diagrams, decision trees
- **Tech stack docs**: Dependencies, versions, packages

## Travis CI / GitHub Actions

Add `.github/workflows/ci.yml`:

```yaml
name: Lint Scripts
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get install shellcheck
      - name: Lint scripts
        run: shellcheck *.sh
```

## Debugging

### Enable Bash Debugging

```bash
set -x  # Print commands as they execute
# or
bash -x script.sh
```

### Check Dependencies

```bash
# Verify required packages
which vcgencmd
which sysbench
which hdparm
which bc
```

### View Journal Logs

```bash
# For service-related issues
journalctl -u ollama -f

# For boot issues
journalctl -b -1  # Previous boot
```

## Maintenance

### Script Updates

1. Update version number in header comment
2. Add changelog in commit message
3. Test on target hardware before committing

### Documentation Updates

- Update component docs when functions change
- Update usage docs when CLI options change
- Update tech stack when dependencies change

## Contributing

1. Fork repository
2. Create feature branch
3. Make changes with tests
4. Run `shellcheck` and `shfmt -w`
5. Update documentation as needed
6. Submit pull request

## License

MIT - See repository root for license file.
