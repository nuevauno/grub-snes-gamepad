#!/bin/bash
#
# GRUB SNES Gamepad Installer v0.2
# https://github.com/nuevauno/grub-snes-gamepad
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
NC='\033[0m'

# Progress bar function
progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r  ["
    printf "%${filled}s" '' | tr ' ' '█'
    printf "%${empty}s" '' | tr ' ' '░'
    printf "] %3d%%" $percent
}

# Spinner for long operations
spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 $pid 2>/dev/null; do
        printf "\r  ${spin:i++%10:1} ${msg}"
        sleep 0.1
    done
    printf "\r"
}

print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║       GRUB SNES Gamepad Installer v0.2                    ║"
    echo "║       Control your bootloader with a game controller      ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  STEP ${1}/${2}: ${NC}${BOLD}${3}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

ok() { echo -e "  ${GREEN}✓${NC} $1"; }
err() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root${NC}"
    echo "Usage: sudo bash install.sh"
    exit 1
fi

# Get the real user (not root)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)

print_header

#######################################
# STEP 1: Check system
#######################################
print_step 1 6 "Checking system"

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    DISTRO="unknown"
fi

ok "Distro: $DISTRO"

# Check GRUB
if [ -d "/boot/grub" ]; then
    GRUB_DIR="/boot/grub"
    ok "GRUB found: $GRUB_DIR"
elif [ -d "/boot/grub2" ]; then
    GRUB_DIR="/boot/grub2"
    ok "GRUB2 found: $GRUB_DIR"
else
    err "GRUB not found!"
    exit 1
fi

# Determine module dir
if [ -d "$GRUB_DIR/x86_64-efi" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/x86_64-efi"
    GRUB_PLATFORM="x86_64-efi"
elif [ -d "$GRUB_DIR/i386-pc" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/i386-pc"
    GRUB_PLATFORM="i386-pc"
else
    err "Could not determine GRUB platform"
    exit 1
fi
ok "Platform: $GRUB_PLATFORM"

#######################################
# STEP 2: Install dependencies
#######################################
print_step 2 6 "Installing dependencies"

PACKAGES="git build-essential autoconf automake gettext bison flex python3 python3-pip libusb-1.0-0-dev pkg-config"

echo ""
case $DISTRO in
    ubuntu|debian|linuxmint|pop)
        info "Installing packages (this may take a minute)..."
        (apt-get update -qq && apt-get install -y -qq $PACKAGES) > /tmp/apt.log 2>&1 &
        spinner $! "Installing build tools..."
        ok "APT packages installed"
        ;;
    fedora)
        info "Installing packages..."
        (dnf install -y -q git gcc make autoconf automake gettext bison flex python3 python3-pip libusb1-devel) > /tmp/dnf.log 2>&1 &
        spinner $! "Installing build tools..."
        ok "DNF packages installed"
        ;;
    arch|manjaro)
        info "Installing packages..."
        (pacman -Sy --noconfirm git base-devel autoconf automake gettext bison flex python python-pip libusb) > /tmp/pacman.log 2>&1 &
        spinner $! "Installing build tools..."
        ok "Pacman packages installed"
        ;;
    *)
        warn "Unknown distro, trying to continue..."
        ;;
esac

# Install pyusb
pip3 install pyusb -q 2>/dev/null || pip install pyusb -q 2>/dev/null || true
ok "Python USB library ready"

#######################################
# STEP 3: Detect controller
#######################################
print_step 3 6 "Detecting USB controller"

echo -e "  ${YELLOW}Please connect your SNES USB controller now${NC}"
echo ""
read -p "  Press ENTER when connected... "
echo ""

# Find controllers
CONTROLLER_LINE=$(lsusb | grep -iE "(0810|0079|0583|2dc8|12bd|1a34|game|pad|joystick|snes)" | head -1 || true)

if [ -z "$CONTROLLER_LINE" ]; then
    err "No game controller detected!"
    echo ""
    info "All USB devices:"
    lsusb | sed 's/^/    /'
    echo ""
    err "Connect your SNES controller and run again"
    exit 1
fi

CONTROLLER_ID=$(echo "$CONTROLLER_LINE" | grep -oP 'ID \K[0-9a-f]+:[0-9a-f]+')
VENDOR_ID="0x$(echo $CONTROLLER_ID | cut -d: -f1)"
PRODUCT_ID="0x$(echo $CONTROLLER_ID | cut -d: -f2)"

ok "Found: $CONTROLLER_LINE"
ok "VID: $VENDOR_ID  PID: $PRODUCT_ID"

#######################################
# STEP 4: Test controller buttons
#######################################
print_step 4 6 "Testing controller"

# Download and run mapper
MAPPER_SCRIPT=$(mktemp)
cat > "$MAPPER_SCRIPT" << 'MAPPER_EOF'
#!/usr/bin/env python3
import os, sys, time
try:
    import usb.core, usb.util
except:
    print("Installing pyusb...")
    os.system(f"{sys.executable} -m pip install pyusb -q")
    import usb.core, usb.util

C_G='\033[92m'; C_Y='\033[93m'; C_R='\033[91m'; C_B='\033[1m'; C_D='\033[2m'; C_N='\033[0m'

def ok(t): print(f"  {C_G}✓{C_N} {t}")
def warn(t): print(f"  {C_Y}⚠{C_N} {t}")

KNOWN = {
    (0x0810, 0xe501): "Generic SNES", (0x0079, 0x0011): "DragonRise",
    (0x0583, 0x2060): "iBuffalo", (0x2dc8, 0x9018): "8BitDo",
}

# Find controller
dev = None
for d in usb.core.find(find_all=True):
    if (d.idVendor, d.idProduct) in KNOWN or d.bDeviceClass == 0:
        try:
            for cfg in d:
                for intf in cfg:
                    if intf.bInterfaceClass == 3:  # HID
                        dev = d
                        break
        except: pass

if not dev:
    print(f"  {C_R}✗{C_N} No controller found")
    sys.exit(1)

name = KNOWN.get((dev.idVendor, dev.idProduct), "USB Controller")
ok(f"Controller: {name}")

# Setup
try:
    if dev.is_kernel_driver_active(0): dev.detach_kernel_driver(0)
except: pass
try: dev.set_configuration()
except: pass

# Find endpoint
ep = None
for intf in dev.get_active_configuration()[(0,0)]:
    if usb.util.endpoint_direction(intf.bEndpointAddress) == usb.util.ENDPOINT_IN:
        ep = intf
        break

if not ep:
    print(f"  {C_R}✗{C_N} No endpoint")
    sys.exit(1)

# Read baseline
print(f"\n  {C_D}Reading baseline (don't touch controller)...{C_N}")
time.sleep(0.5)
reports = []
for _ in range(10):
    try:
        r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
        reports.append(r)
    except: pass
    time.sleep(0.05)

if not reports:
    print(f"  {C_R}✗{C_N} Cannot read controller")
    sys.exit(1)

baseline = max(set(reports), key=reports.count)
ok(f"Baseline: {baseline.hex()}")

# Test buttons
buttons = [("D-PAD UP", "up"), ("D-PAD DOWN", "down"), ("A BUTTON", "a"), ("START", "start")]
mapping = {}

print(f"\n  {C_B}Quick button test (4 buttons):{C_N}\n")

for display, key in buttons:
    print(f"  {C_Y}>>> Press {C_B}{display}{C_N}{C_Y} <<<{C_N}", end='', flush=True)

    start = time.time()
    detected = False
    while time.time() - start < 10:
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                changes = [(i, a, b) for i,(a,b) in enumerate(zip(baseline, r)) if a != b]
                if changes:
                    mapping[key] = changes
                    print(f"\r  {C_G}✓{C_N} {display}: Byte {changes[0][0]} = 0x{changes[0][1]:02x}→0x{changes[0][2]:02x}     ")
                    detected = True
                    # Wait release
                    while True:
                        try:
                            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
                            if r == baseline: break
                        except: break
                        time.sleep(0.01)
                    break
        except: pass
        time.sleep(0.01)

    if not detected:
        print(f"\r  {C_Y}⚠{C_N} {display}: timeout (skipped)                    ")

print(f"\n  {C_G}Controller working!{C_N} Detected {len(mapping)}/4 buttons")

# Save config
import json
config_dir = "/usr/local/share/grub-snes-gamepad"
os.makedirs(config_dir, exist_ok=True)
with open(f"{config_dir}/controller.json", 'w') as f:
    json.dump({
        'vid': f"0x{dev.idVendor:04x}",
        'pid': f"0x{dev.idProduct:04x}",
        'baseline': baseline.hex(),
        'mapping': {k: [(i, f"0x{a:02x}", f"0x{b:02x}") for i,a,b in v] for k,v in mapping.items()}
    }, f, indent=2)
ok(f"Config saved: {config_dir}/controller.json")
MAPPER_EOF

python3 "$MAPPER_SCRIPT"
MAPPER_EXIT=$?
rm -f "$MAPPER_SCRIPT"

if [ $MAPPER_EXIT -ne 0 ]; then
    err "Controller test failed"
    exit 1
fi

#######################################
# STEP 5: Build GRUB module
#######################################
print_step 5 6 "Building GRUB module"

warn "This step compiles a custom GRUB module"
warn "This takes 5-10 minutes on first run"
echo ""
read -p "  Continue with build? [Y/n] " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Nn]$ ]]; then
    info "Skipped build. Run install.sh again to build later."
    exit 0
fi

BUILD_DIR="/tmp/grub-snes-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone GRUB with gamepad support
echo ""
info "Cloning GRUB source (this takes a minute)..."
(git clone --depth 1 -b grub-gamepad https://github.com/tsoding/grub.git grub 2>&1) &
spinner $! "Downloading GRUB source..."
ok "GRUB source downloaded"

cd grub

# Bootstrap
info "Running bootstrap..."
(./bootstrap 2>&1 > ../bootstrap.log) &
spinner $! "Bootstrapping..."
ok "Bootstrap complete"

# Configure
info "Configuring (this takes a few minutes)..."
(./configure --with-platform=$GRUB_PLATFORM 2>&1 > ../configure.log) &
spinner $! "Configuring GRUB..."
ok "Configure complete"

# Build
info "Compiling GRUB (this is the slow part)..."
CORES=$(nproc 2>/dev/null || echo 2)
echo ""

# Show progress during make
make -j$CORES 2>&1 | while IFS= read -r line; do
    if [[ "$line" == *".o"* ]] || [[ "$line" == *".mod"* ]]; then
        printf "\r  ${DIM}Compiling: %-50s${NC}" "$(echo $line | grep -oP '[^ ]+\.(o|mod)' | tail -1)"
    fi
done
echo ""
ok "Compilation complete"

# Find the module
MODULE=$(find . -name "usb_gamepad.mod" 2>/dev/null | head -1)

if [ -z "$MODULE" ]; then
    err "Module not found after build!"
    info "Check build logs in $BUILD_DIR"
    exit 1
fi

# Copy module
cp "$MODULE" "$GRUB_MOD_DIR/usb_gamepad.mod"
ok "Module installed: $GRUB_MOD_DIR/usb_gamepad.mod"

#######################################
# STEP 6: Configure GRUB
#######################################
print_step 6 6 "Configuring GRUB"

GRUB_CUSTOM="/etc/grub.d/40_custom"

# Backup
if [ ! -f "${GRUB_CUSTOM}.backup-snes" ]; then
    cp "$GRUB_CUSTOM" "${GRUB_CUSTOM}.backup-snes"
    ok "Backed up: ${GRUB_CUSTOM}.backup-snes"
fi

# Add config if not present
if ! grep -q "usb_gamepad" "$GRUB_CUSTOM" 2>/dev/null; then
    cat >> "$GRUB_CUSTOM" << 'GRUBCFG'

# SNES Gamepad Support - added by grub-snes-gamepad
insmod usb_gamepad
terminal_input --append usb_gamepad
GRUBCFG
    ok "Added gamepad to GRUB config"
else
    info "GRUB already configured"
fi

# Update GRUB
info "Updating GRUB..."
if command -v update-grub &> /dev/null; then
    update-grub 2>/dev/null
elif command -v grub2-mkconfig &> /dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
else
    grub-mkconfig -o "$GRUB_DIR/grub.cfg" 2>/dev/null
fi
ok "GRUB updated"

# Cleanup
rm -rf "$BUILD_DIR"
ok "Cleaned up build files"

# Create uninstaller
mkdir -p /usr/local/share/grub-snes-gamepad
cat > /usr/local/share/grub-snes-gamepad/uninstall.sh << 'UNINSTALL'
#!/bin/bash
echo "Uninstalling GRUB SNES Gamepad..."
rm -f /boot/grub*/*/usb_gamepad.mod
[ -f /etc/grub.d/40_custom.backup-snes ] && cp /etc/grub.d/40_custom.backup-snes /etc/grub.d/40_custom
update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
rm -rf /usr/local/share/grub-snes-gamepad
echo "Done!"
UNINSTALL
chmod +x /usr/local/share/grub-snes-gamepad/uninstall.sh

#######################################
# DONE!
#######################################
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║              Installation Complete!                        ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "  ${BOLD}Button Mapping:${NC}"
echo "    D-pad Up/Down  →  Navigate menu"
echo "    A or Start     →  Select entry"
echo "    B              →  Cancel/Back"
echo ""
echo -e "  ${BOLD}Next:${NC}"
echo -e "    ${CYAN}Reboot your computer and test in GRUB menu!${NC}"
echo ""
echo -e "  ${DIM}To uninstall: sudo /usr/local/share/grub-snes-gamepad/uninstall.sh${NC}"
echo ""
