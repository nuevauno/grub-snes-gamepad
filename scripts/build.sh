#!/bin/bash
# Build the GRUB SNES gamepad module

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GRUB_DIR="$PROJECT_DIR/grub"

echo "=== Building GRUB SNES Gamepad Module ==="

# Check if GRUB submodule exists
if [ ! -d "$GRUB_DIR" ]; then
    echo "GRUB source not found. Cloning..."
    cd "$PROJECT_DIR"
    git submodule add https://github.com/tsoding/grub.git grub
    git submodule update --init --recursive
    cd "$GRUB_DIR"
    git checkout grub-gamepad
fi

# Check dependencies
echo "Checking dependencies..."
DEPS="build-essential autoconf automake gettext bison flex"
MISSING=""
for dep in $DEPS; do
    if ! dpkg -l | grep -q "^ii  $dep"; then
        MISSING="$MISSING $dep"
    fi
done

if [ -n "$MISSING" ]; then
    echo "Installing missing dependencies:$MISSING"
    sudo apt update
    sudo apt install -y $MISSING
fi

# Build GRUB
cd "$GRUB_DIR"

if [ ! -f "configure" ]; then
    echo "Running bootstrap..."
    ./bootstrap
fi

if [ ! -f "Makefile" ]; then
    echo "Running configure..."
    ./configure
fi

echo "Building GRUB..."
make -j$(nproc)

# Copy our module source
echo "Copying SNES gamepad module..."
cp "$PROJECT_DIR/src/usb_snes_gamepad.c" "$GRUB_DIR/grub-core/term/"

# Rebuild with our module
echo "Rebuilding with SNES module..."
make -j$(nproc)

# Create test ISO
echo "Creating test ISO..."
cd "$PROJECT_DIR"
"$GRUB_DIR/grub-mkrescue" -o test.iso iso/

echo ""
echo "=== Build Complete ==="
echo "Test ISO: $PROJECT_DIR/test.iso"
echo "Module: $GRUB_DIR/grub-core/term/usb_snes_gamepad.mod"
echo ""
echo "To test: ./scripts/test-qemu.sh"
