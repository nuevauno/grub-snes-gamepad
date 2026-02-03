#!/bin/bash
# Test the GRUB SNES gamepad module in QEMU

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

ISO="$PROJECT_DIR/test.iso"

if [ ! -f "$ISO" ]; then
    echo "Test ISO not found. Run ./scripts/build.sh first"
    exit 1
fi

echo "=== Testing GRUB SNES Gamepad in QEMU ==="
echo ""
echo "Connect your SNES controller before running this."
echo ""

# Find the SNES controller
echo "Looking for SNES controller..."
CONTROLLER=$(lsusb | grep -iE "(0810|0079|0583|2dc8|12bd|1a34|game|snes)" | head -1)

if [ -z "$CONTROLLER" ]; then
    echo "No SNES controller found. Running without USB passthrough."
    echo ""
    qemu-system-x86_64 \
        -cdrom "$ISO" \
        -m 256M \
        -enable-kvm \
        -vga std
else
    echo "Found: $CONTROLLER"

    # Extract bus and device numbers
    BUS=$(echo "$CONTROLLER" | grep -oP 'Bus \K\d+')
    DEV=$(echo "$CONTROLLER" | grep -oP 'Device \K\d+')

    # Extract vendor:product
    VIDPID=$(echo "$CONTROLLER" | grep -oP 'ID \K[0-9a-f]+:[0-9a-f]+')

    echo "Passing through USB device: Bus $BUS Device $DEV ($VIDPID)"
    echo ""

    # Run QEMU with USB passthrough
    # Note: Requires sudo for USB passthrough
    sudo qemu-system-x86_64 \
        -cdrom "$ISO" \
        -m 256M \
        -enable-kvm \
        -vga std \
        -usb \
        -device usb-host,vendorid=0x${VIDPID%%:*},productid=0x${VIDPID##*:}
fi

echo ""
echo "=== QEMU Commands in GRUB Shell ==="
echo "Once GRUB loads, try these commands:"
echo ""
echo "  insmod usb_snes_gamepad"
echo "  terminal_input usb_snes_gamepad"
echo "  snes_status"
echo ""
