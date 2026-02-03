#!/bin/bash
# Detect USB game controllers and their IDs

echo "=== USB Game Controllers Detected ==="
echo ""

# List all USB devices that might be game controllers
lsusb | grep -iE "(game|controller|joystick|pad|snes|nintendo|retro|0810|0079|12bd|2dc8|0583)" || echo "No obvious game controllers found"

echo ""
echo "=== All USB Devices ==="
lsusb

echo ""
echo "=== Instructions ==="
echo "1. Connect your SNES USB controller"
echo "2. Run this script again"
echo "3. Note the ID (e.g., '0810:e501')"
echo "   - First part (0810) is Vendor ID"
echo "   - Second part (e501) is Product ID"
echo ""
echo "Common SNES controller IDs:"
echo "  0810:e501 - Generic Chinese SNES"
echo "  0079:0011 - DragonRise Generic"
echo "  0583:2060 - iBuffalo SNES"
echo "  2dc8:9018 - 8BitDo SN30"
echo ""

# If a device ID is passed as argument, show detailed info
if [ -n "$1" ]; then
    echo "=== Detailed info for $1 ==="
    lsusb -d "$1" -v 2>/dev/null || echo "Device not found"
fi
