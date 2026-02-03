# HID Report Documentation

This document describes the HID report formats for various USB SNES controllers.

## How to Capture Your Controller's HID Reports

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt install usbhid-dump

# Fedora
sudo dnf install usbutils

# Arch
sudo pacman -S usbutils
```

### Steps

1. **Find your controller's USB ID**
   ```bash
   lsusb | grep -i game
   # Example output: Bus 001 Device 005: ID 0810:e501 Personal Communication Systems
   ```

2. **Capture HID reports**
   ```bash
   sudo usbhid-dump -d 0810:e501 -es
   ```

3. **Press buttons and note changes**
   - Rest state (no buttons pressed)
   - Each button individually
   - Each D-pad direction

## Generic SNES Controller (0810:e501)

Most common cheap Chinese SNES controllers.

### Report Format (8 bytes)

```
Byte 0: X-axis
  - 0x00 = Left pressed
  - 0x7F = Center (neutral)
  - 0xFF = Right pressed

Byte 1: Y-axis
  - 0x00 = Up pressed
  - 0x7F = Center (neutral)
  - 0xFF = Down pressed

Byte 2: 0x7F (unused)

Byte 3: 0x7F (unused)

Byte 4: Buttons
  - Bit 0 (0x01): X button
  - Bit 1 (0x02): A button
  - Bit 2 (0x04): B button
  - Bit 3 (0x08): Y button
  - Bit 4 (0x10): L shoulder
  - Bit 5 (0x20): R shoulder
  - Bit 6 (0x40): Select
  - Bit 7 (0x80): Start

Byte 5-7: 0x00 (padding)
```

### Example Reports

| State | Hex Dump |
|-------|----------|
| Neutral | `7F 7F 7F 7F 00 00 00 00` |
| Up | `7F 00 7F 7F 00 00 00 00` |
| Down | `7F FF 7F 7F 00 00 00 00` |
| Left | `00 7F 7F 7F 00 00 00 00` |
| Right | `FF 7F 7F 7F 00 00 00 00` |
| A | `7F 7F 7F 7F 02 00 00 00` |
| B | `7F 7F 7F 7F 04 00 00 00` |
| X | `7F 7F 7F 7F 01 00 00 00` |
| Y | `7F 7F 7F 7F 08 00 00 00` |
| Start | `7F 7F 7F 7F 80 00 00 00` |
| Select | `7F 7F 7F 7F 40 00 00 00` |
| L | `7F 7F 7F 7F 10 00 00 00` |
| R | `7F 7F 7F 7F 20 00 00 00` |

## DragonRise Controller (0079:0011)

Common generic chipset used in many budget controllers.

### Report Format

Similar to generic, but may have slight variations:

```
Byte 0: X-axis (0x00-0xFF)
Byte 1: Y-axis (0x00-0xFF)
Byte 2-3: Hat switch / unused
Byte 4: Buttons low byte
Byte 5: Buttons high byte
Byte 6-7: Padding
```

## iBuffalo SNES (0583:2060)

Higher quality controller with better D-pad feel.

### Report Format

```
Byte 0: Buttons byte 1
Byte 1: Buttons byte 2
```

Note: iBuffalo uses a different, more compact format. Each button has its own bit:

```
Byte 0:
  - Bit 0: Y
  - Bit 1: B
  - Bit 2: A
  - Bit 3: X
  - Bit 4: L
  - Bit 5: R
  - Bit 6-7: unused

Byte 1:
  - Bit 0: Select
  - Bit 1: Start
  - Bit 2-5: D-pad (encoded)
  - Bit 6-7: unused
```

## 8BitDo SN30 (2dc8:9018)

Premium controller with multiple modes.

### Notes

- Has D-input and X-input modes
- D-input mode is more compatible with GRUB
- Press START+B for 3 seconds to switch to D-input mode
- LED blinks differently for each mode

### Report Format (D-input mode)

Standard 8-byte HID gamepad format, similar to generic SNES.

## Adding Support for New Controllers

1. **Capture the report format**
   ```bash
   sudo usbhid-dump -d XXXX:YYYY -es > my_controller.txt
   ```

2. **Document each button/axis**
   - Press each button individually
   - Note which byte and bit changes

3. **Add to supported list in source code**
   ```c
   static struct snes_controller_info supported_controllers[] = {
       { 0xXXXX, 0xYYYY, "My Controller Name" },
       ...
   };
   ```

4. **If report format differs significantly**
   - Create a new report struct
   - Add detection logic based on VID/PID
   - Implement custom process_report function

5. **Submit a PR with your findings!**
