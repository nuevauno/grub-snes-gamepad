#!/bin/bash
# Capture HID reports from a USB game controller
# Usage: ./capture-hid.sh 0810:e501

if [ -z "$1" ]; then
    echo "Usage: $0 <vendor:product>"
    echo "Example: $0 0810:e501"
    echo ""
    echo "Run ./detect-controller.sh first to find your device ID"
    exit 1
fi

DEVICE_ID="$1"

echo "=== Capturing HID reports from $DEVICE_ID ==="
echo "Press buttons on your controller to see the reports"
echo "Press Ctrl+C to stop"
echo ""

# Check if usbhid-dump is installed
if ! command -v usbhid-dump &> /dev/null; then
    echo "usbhid-dump not found. Installing..."
    if command -v apt &> /dev/null; then
        sudo apt install usbhid-dump
    elif command -v dnf &> /dev/null; then
        sudo dnf install usbutils
    elif command -v pacman &> /dev/null; then
        sudo pacman -S usbutils
    else
        echo "Please install usbhid-dump manually"
        exit 1
    fi
fi

# Capture HID reports
sudo usbhid-dump -d "$DEVICE_ID" -es

echo ""
echo "=== Tips ==="
echo "1. The output shows raw HID reports in hex"
echo "2. Press different buttons and note which bytes change"
echo "3. D-pad usually changes bytes 0-1 (X/Y axis)"
echo "4. Buttons usually change bytes 4-5"
