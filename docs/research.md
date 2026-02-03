# Research Notes

## Problem Statement

Dual-boot systems with Bluetooth peripherals cannot select OS in GRUB bootloader because Bluetooth is not initialized at boot time.

## Solution Approach

Create a GRUB module that reads USB SNES controllers and translates button presses to keyboard events that GRUB understands.

## Prior Art

### tsoding/grub-gamepad
- https://github.com/tsoding/grub-gamepad
- Proof of concept that gamepad support in GRUB is possible
- Only supports Logitech Rumblepad F510 (VID=0x046d, PID=0xc218)
- Uses DirectInput mode, 8-byte HID reports
- Development done on Twitch streams

### Key Insights from tsoding's Implementation

1. **Module Structure**: Located in `grub-core/term/` directory
2. **USB Attach Hook**: Uses `grub_usb_register_attach_hook_class()` with `GRUB_USB_CLASS_HID`
3. **Polling**: Uses `grub_usb_bulk_read_timeout()` for reading HID reports
4. **Terminal Input**: Implements `grub_term_input` interface with `getkey` and `checkkey`

## USB SNES Controllers

### Common Controllers and Their IDs

| Controller | VID | PID | Notes |
|------------|-----|-----|-------|
| Generic Chinese | 0x0810 | 0xe501 | Most common, ~$5 |
| DragonRise | 0x0079 | 0x0011 | Common generic chipset |
| iBuffalo SNES | 0x0583 | 0x2060 | Higher quality |
| 8BitDo SN30 | 0x2dc8 | 0x9018 | Premium, wireless capable |
| Generic 2-pack | 0x12bd | 0xd015 | Budget option |

### HID Report Format

Most USB SNES controllers use an 8-byte HID report:

```
Offset  Size  Description
------  ----  -----------
0       1     X-axis (0x00=Left, 0x7F=Center, 0xFF=Right)
1       1     Y-axis (0x00=Up, 0x7F=Center, 0xFF=Down)
2       1     Unused (0x7F)
3       1     Unused (0x7F)
4       1     Button byte:
              Bit 0: X
              Bit 1: A
              Bit 2: B
              Bit 3: Y
              Bit 4: L
              Bit 5: R
              Bit 6: Select
              Bit 7: Start
5-7     3     Padding (0x00)
```

### Capturing HID Reports

```bash
# Install tools
sudo apt install usbhid-dump

# List HID devices
sudo usbhid-dump -e

# Stream HID reports from specific device
sudo usbhid-dump -d 0810:e501 -es
```

## GRUB USB Stack

### Key APIs

- `grub_usb_register_attach_hook_class()` - Register for USB device attach events
- `grub_usb_bulk_read_timeout()` - Read data from USB endpoint
- `grub_term_register_input()` - Register as terminal input device

### USB Classes

- `GRUB_USB_CLASS_HID` (0x03) - Human Interface Device

### Endpoint Types

- `GRUB_USB_EP_INTERRUPT` (0x03) - Interrupt endpoint (used by HID)

## Button Mapping Strategy

| SNES Button | GRUB Key | Purpose |
|-------------|----------|---------|
| D-pad Up | KEY_UP | Navigate menu up |
| D-pad Down | KEY_DOWN | Navigate menu down |
| D-pad Left | KEY_LEFT | (reserved) |
| D-pad Right | KEY_RIGHT | (reserved) |
| A | Enter | Select entry |
| B | Escape | Back/Cancel |
| Start | Enter | Select entry |
| Select | 'e' | Edit entry |
| Y | 'c' | Command line |
| X | Escape | Back |
| L | Page Up | Scroll long menus |
| R | Page Down | Scroll long menus |

## Build System

GRUB uses autotools (autoconf/automake). To add a new module:

1. Add source file to `grub-core/term/`
2. Register module in `grub-core/Makefile.core.def`
3. Run `./bootstrap` and `./configure`
4. Build with `make`

## Testing

### QEMU

```bash
qemu-system-x86_64 \
    -cdrom test.iso \
    -m 256M \
    -usb \
    -device usb-host,vendorid=0x0810,productid=0xe501
```

### VirtualBox

1. Create VM with 256MB RAM, no disk
2. Mount ISO as boot CD
3. Enable USB controller (OHCI)
4. Add USB device filter for SNES controller

## References

- [GRUB Manual](https://www.gnu.org/software/grub/manual/grub/grub.html)
- [USB HID Specification](https://www.usb.org/hid)
- [tsoding/grub-gamepad](https://github.com/tsoding/grub-gamepad)
- [Linux Gamepad Driver](https://github.com/torvalds/linux/blob/master/drivers/input/joystick/xpad.c)
