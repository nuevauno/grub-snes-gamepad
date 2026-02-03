#!/bin/bash
#
# GRUB SNES Gamepad - One-click installer
# https://github.com/nuevauno/grub-snes-gamepad
#
# Usage: curl -sSL https://raw.githubusercontent.com/nuevauno/grub-snes-gamepad/main/install.sh | sudo bash
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Print functions
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║       GRUB SNES Gamepad Installer                         ║"
    echo "║       Control your bootloader with a SNES controller      ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BLUE}[${1}/${2}]${NC} ${BOLD}${3}${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

print_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This installer must be run as root"
        echo "Please run: sudo bash install.sh"
        exit 1
    fi
}

# Detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        DISTRO_VERSION=$VERSION_ID
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO=$DISTRIB_ID
        DISTRO_VERSION=$DISTRIB_RELEASE
    else
        DISTRO="unknown"
    fi

    print_info "Detected: $DISTRO $DISTRO_VERSION"
}

# Install dependencies
install_deps() {
    print_step 1 5 "Installing dependencies"

    case $DISTRO in
        ubuntu|debian|linuxmint|pop)
            apt-get update -qq
            apt-get install -y -qq python3 python3-pip python3-usb usbutils > /dev/null 2>&1
            ;;
        fedora|rhel|centos)
            dnf install -y -q python3 python3-pip python3-pyusb usbutils > /dev/null 2>&1
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm python python-pip python-pyusb usbutils > /dev/null 2>&1
            ;;
        opensuse*)
            zypper install -y python3 python3-pip python3-usb usbutils > /dev/null 2>&1
            ;;
        *)
            print_warning "Unknown distro, trying pip..."
            pip3 install pyusb 2>/dev/null || pip install pyusb
            ;;
    esac

    # Ensure pyusb is installed
    pip3 install pyusb -q 2>/dev/null || true

    print_success "Dependencies installed"
}

# Detect SNES controllers
detect_controllers() {
    print_step 2 5 "Detecting SNES controllers"

    echo -e "${DIM}Looking for USB game controllers...${NC}"

    # Known SNES controller IDs
    KNOWN_IDS="0810:e501|0079:0011|0583:2060|2dc8:9018|12bd:d015|1a34:0802|0810:0001|0079:0006"

    CONTROLLERS=$(lsusb | grep -iE "(game|controller|joystick|pad|snes|nintendo|${KNOWN_IDS})" || true)

    if [ -z "$CONTROLLERS" ]; then
        print_error "No game controllers detected!"
        echo ""
        echo "Please:"
        echo "  1. Connect your USB SNES controller"
        echo "  2. Run this installer again"
        echo ""
        echo "To see all USB devices, run: lsusb"
        exit 1
    fi

    echo -e "\n${BOLD}Found controllers:${NC}\n"
    echo "$CONTROLLERS" | while read line; do
        echo -e "  ${GREEN}•${NC} $line"
    done

    # Extract first controller's VID:PID
    CONTROLLER_ID=$(echo "$CONTROLLERS" | head -1 | grep -oP 'ID \K[0-9a-f]+:[0-9a-f]+')
    VENDOR_ID=$(echo $CONTROLLER_ID | cut -d: -f1)
    PRODUCT_ID=$(echo $CONTROLLER_ID | cut -d: -f2)

    echo ""
    print_success "Using controller: $CONTROLLER_ID"

    export VENDOR_ID PRODUCT_ID
}

# Download and run mapper
run_mapper() {
    print_step 3 5 "Mapping controller buttons"

    TEMP_DIR=$(mktemp -d)
    MAPPER_URL="https://raw.githubusercontent.com/nuevauno/grub-snes-gamepad/main/tools/snes-mapper-standalone.py"

    print_info "Downloading mapper tool..."

    if command -v curl &> /dev/null; then
        curl -sSL "$MAPPER_URL" -o "$TEMP_DIR/mapper.py"
    elif command -v wget &> /dev/null; then
        wget -q "$MAPPER_URL" -O "$TEMP_DIR/mapper.py"
    else
        print_error "Neither curl nor wget found!"
        exit 1
    fi

    # Run the mapper
    python3 "$TEMP_DIR/mapper.py" --install

    MAPPER_EXIT=$?
    rm -rf "$TEMP_DIR"

    if [ $MAPPER_EXIT -ne 0 ]; then
        print_error "Mapper failed"
        exit 1
    fi
}

# Install pre-built module (for common controllers)
install_prebuilt() {
    print_step 3 5 "Installing GRUB module"

    # Determine GRUB module directory
    if [ -d "/boot/grub/x86_64-efi" ]; then
        GRUB_MOD_DIR="/boot/grub/x86_64-efi"
    elif [ -d "/boot/grub/i386-pc" ]; then
        GRUB_MOD_DIR="/boot/grub/i386-pc"
    elif [ -d "/boot/grub2/x86_64-efi" ]; then
        GRUB_MOD_DIR="/boot/grub2/x86_64-efi"
    else
        print_error "Could not find GRUB modules directory"
        exit 1
    fi

    print_info "GRUB modules: $GRUB_MOD_DIR"

    # Download pre-built module
    MODULE_URL="https://github.com/nuevauno/grub-snes-gamepad/releases/latest/download/usb_snes_gamepad.mod"

    print_info "Downloading GRUB module..."

    if command -v curl &> /dev/null; then
        curl -sSL "$MODULE_URL" -o "$GRUB_MOD_DIR/usb_snes_gamepad.mod" 2>/dev/null || DOWNLOAD_FAILED=1
    else
        wget -q "$MODULE_URL" -O "$GRUB_MOD_DIR/usb_snes_gamepad.mod" 2>/dev/null || DOWNLOAD_FAILED=1
    fi

    if [ "$DOWNLOAD_FAILED" = "1" ]; then
        print_warning "Pre-built module not available yet"
        print_info "The module needs to be compiled from source"
        print_info "See: https://github.com/nuevauno/grub-snes-gamepad#building-from-source"
        return 1
    fi

    print_success "Module installed to $GRUB_MOD_DIR"
    return 0
}

# Configure GRUB
configure_grub() {
    print_step 4 5 "Configuring GRUB"

    # Determine GRUB config location
    if [ -f "/etc/default/grub" ]; then
        GRUB_DEFAULT="/etc/default/grub"
    else
        print_error "Could not find GRUB configuration"
        exit 1
    fi

    # Determine custom config location
    if [ -d "/etc/grub.d" ]; then
        GRUB_CUSTOM="/etc/grub.d/40_custom"
    else
        print_error "Could not find GRUB scripts directory"
        exit 1
    fi

    # Backup original
    if [ ! -f "${GRUB_CUSTOM}.backup" ]; then
        cp "$GRUB_CUSTOM" "${GRUB_CUSTOM}.backup"
        print_info "Backed up original config"
    fi

    # Check if already configured
    if grep -q "usb_snes_gamepad" "$GRUB_CUSTOM" 2>/dev/null; then
        print_info "GRUB already configured for SNES gamepad"
    else
        # Add SNES gamepad configuration
        cat >> "$GRUB_CUSTOM" << 'GRUBCFG'

# SNES Gamepad Support
# Added by grub-snes-gamepad installer
insmod usb_snes_gamepad
terminal_input --append usb_snes_gamepad
GRUBCFG
        print_success "Added SNES gamepad to GRUB config"
    fi

    # Update GRUB
    print_info "Updating GRUB..."

    if command -v update-grub &> /dev/null; then
        update-grub 2>/dev/null
    elif command -v grub2-mkconfig &> /dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
    elif command -v grub-mkconfig &> /dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null
    else
        print_warning "Could not update GRUB automatically"
        print_info "Please run 'update-grub' manually"
    fi

    print_success "GRUB configured"
}

# Show completion message
show_complete() {
    print_step 5 5 "Installation complete!"

    echo -e "${GREEN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                    Installation Complete!                  ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}Your SNES controller is now configured for GRUB!${NC}\n"

    echo -e "${CYAN}Button Mapping:${NC}"
    echo "  D-pad Up/Down  →  Navigate menu"
    echo "  A or Start     →  Select/Boot"
    echo "  B              →  Back/Cancel"
    echo "  Select         →  Edit entry"
    echo "  L/R            →  Page Up/Down"
    echo ""

    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Reboot your computer"
    echo "  2. In GRUB menu, use your SNES controller!"
    echo ""

    echo -e "${DIM}To uninstall: sudo bash /usr/local/share/grub-snes-gamepad/uninstall.sh${NC}"
    echo ""
}

# Create uninstaller
create_uninstaller() {
    INSTALL_DIR="/usr/local/share/grub-snes-gamepad"
    mkdir -p "$INSTALL_DIR"

    cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALL'
#!/bin/bash
# GRUB SNES Gamepad Uninstaller

echo "Removing GRUB SNES Gamepad..."

# Remove module
rm -f /boot/grub/x86_64-efi/usb_snes_gamepad.mod 2>/dev/null
rm -f /boot/grub/i386-pc/usb_snes_gamepad.mod 2>/dev/null
rm -f /boot/grub2/x86_64-efi/usb_snes_gamepad.mod 2>/dev/null

# Restore GRUB config
if [ -f "/etc/grub.d/40_custom.backup" ]; then
    cp /etc/grub.d/40_custom.backup /etc/grub.d/40_custom
fi

# Update GRUB
update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null

# Remove install directory
rm -rf /usr/local/share/grub-snes-gamepad

echo "Uninstalled successfully!"
UNINSTALL

    chmod +x "$INSTALL_DIR/uninstall.sh"
}

# Main installation flow
main() {
    print_header
    check_root
    detect_distro
    install_deps
    detect_controllers

    # Try to install pre-built module
    if install_prebuilt; then
        configure_grub
        create_uninstaller
        show_complete
    else
        echo ""
        print_warning "Pre-built module not available"
        echo ""
        echo "The GRUB module needs to be compiled from source."
        echo "This requires building GRUB with the custom module."
        echo ""
        echo "Options:"
        echo "  1. Wait for a release with pre-built modules"
        echo "  2. Build from source (see GitHub repo)"
        echo ""
        echo "Repository: https://github.com/nuevauno/grub-snes-gamepad"
        echo ""

        # Still configure GRUB for when module is available
        read -p "Configure GRUB anyway (for when module is installed)? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            configure_grub
            create_uninstaller
            print_success "GRUB configured. Install the module manually to complete setup."
        fi
    fi
}

# Run main
main "$@"
