# GRUB SNES Gamepad

Navigate GRUB bootloader menu using a USB SNES controller. Perfect for dual-boot systems with Bluetooth keyboards that don't work at boot time.

## Problem

When you have a dual-boot system (e.g., Windows/Ubuntu) with Bluetooth keyboard/mouse, you can't select the OS in GRUB because Bluetooth isn't available at boot time.

## Solution

Use a cheap USB SNES controller to navigate GRUB menu:
- **D-pad Up/Down** → Navigate menu entries
- **A or Start** → Select/Boot
- **B** → Back/Cancel
- **L/R** → Page Up/Down

## One-Line Install

```bash
curl -sSL https://raw.githubusercontent.com/nuevauno/grub-snes-gamepad/main/install.sh | sudo bash
```

Or download and run manually:
```bash
wget https://github.com/nuevauno/grub-snes-gamepad/releases/latest/download/install.sh
sudo bash install.sh
```

## Status

🚧 **Work in Progress** - Based on [tsoding/grub-gamepad](https://github.com/tsoding/grub-gamepad)

## How It Works

This project creates a GRUB module (`usb_snes_gamepad.mod`) that:
1. Detects USB SNES controllers at boot
2. Reads HID reports from the controller
3. Translates D-pad/buttons to keyboard events GRUB understands

## Supported Controllers

| Controller | Vendor ID | Product ID | Status |
|------------|-----------|------------|--------|
| Generic SNES USB (Chinese) | 0x0810 | 0xe501 | 🎯 Target |
| DragonRise Generic | 0x0079 | 0x0011 | Planned |
| iBuffalo SNES | 0x0583 | 0x2060 | Planned |
| 8BitDo SN30 | 0x2dc8 | 0x9018 | Planned |

## Project Structure

```
grub-snes-gamepad/
├── src/
│   └── usb_snes_gamepad.c    # GRUB module source
├── tools/
│   └── snes-mapper.py        # Interactive controller mapper
├── configs/                   # Generated controller configs
├── docs/
│   ├── hid-reports.md        # HID report format documentation
│   └── research.md           # Research notes
├── scripts/
│   ├── build.sh              # Build script
│   ├── detect-controller.sh  # Detect controller USB IDs
│   ├── capture-hid.sh        # Capture raw HID reports
│   └── test-qemu.sh          # Test in QEMU
├── iso/boot/grub/
│   └── grub.cfg              # Test GRUB configuration
└── README.md
```

## Quick Start

### Option A: Interactive Mapper (Recommended)

The easiest way to configure your controller:

```bash
# Install dependency
sudo apt install python3-pip
pip3 install pyusb

# Run the interactive mapper
sudo python3 tools/snes-mapper.py
```

The tool will:
1. Detect your controller automatically
2. Guide you to press each button
3. Generate configuration files
4. Show you exactly what to do next

### Option B: Manual Setup

#### 1. Find Your Controller's USB IDs

```bash
# Connect your SNES controller and run:
./scripts/detect-controller.sh

# Or manually:
lsusb | grep -i game
# Example output: Bus 001 Device 005: ID 0810:e501 Personal Communication Systems, Inc.
```

#### 2. Build the Module

```bash
./scripts/build.sh
```

#### 3. Install

```bash
sudo cp usb_snes_gamepad.mod /boot/grub/x86_64-efi/
# Add to /etc/grub.d/40_custom:
# insmod usb_snes_gamepad
# terminal_input --append usb_snes_gamepad
sudo update-grub
```

## Development

### Prerequisites

- Ubuntu/Debian: `sudo apt install build-essential autoconf automake gettext`
- GRUB source code (included as submodule)

### Building from Source

```bash
git clone --recursive https://github.com/YOUR_USERNAME/grub-snes-gamepad.git
cd grub-snes-gamepad
./scripts/build.sh
```

### Testing with QEMU

```bash
./scripts/test-qemu.sh
```

## USB HID Report Format (SNES Controllers)

Most generic SNES USB controllers send 8-byte HID reports:

```
Byte 0: X-axis (0x00=Left, 0x7F=Center, 0xFF=Right)
Byte 1: Y-axis (0x00=Up, 0x7F=Center, 0xFF=Down)
Byte 2: Unused (usually 0x7F)
Byte 3: Unused (usually 0x7F)
Byte 4: Buttons byte 1
        Bit 0: X
        Bit 1: A
        Bit 2: B
        Bit 3: Y
        Bit 4: L
        Bit 5: R
        Bit 6: Select
        Bit 7: Start
Byte 5: Usually 0x00
Byte 6: Usually 0x00
Byte 7: Usually 0x00
```

## References

- [tsoding/grub-gamepad](https://github.com/tsoding/grub-gamepad) - Original inspiration
- [GRUB Manual](https://www.gnu.org/software/grub/manual/grub/grub.html)
- [USB HID Specification](https://www.usb.org/hid)

## License

GPLv3 (same as GRUB)

## Contributing

1. Find your controller's USB IDs with `lsusb`
2. Capture HID reports with `sudo usbhid-dump -d XXXX:XXXX -es`
3. Submit a PR with the mapping!
