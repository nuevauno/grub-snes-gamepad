#!/bin/bash
#
# GRUB SNES Gamepad Installer v1.0
# https://github.com/nuevauno/grub-snes-gamepad
#
# Simple installer: Maps your controller, then builds GRUB module
#

VERSION="1.1"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Globals
GRUB_DIR=""
GRUB_MOD_DIR=""
GRUB_PLATFORM=""
BUILD_DIR="/tmp/grub-snes-build"

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo -e "${CYAN}${BOLD}  GRUB SNES Gamepad Installer v${VERSION}${NC}"
    echo -e "${CYAN}${BOLD}======================================${NC}"
    echo ""
}

step() {
    echo ""
    echo -e "${BLUE}--- STEP $1: $2 ---${NC}"
    echo ""
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root (sudo)${NC}"
    exit 1
fi

header

########################################
# STEP 1: System check
########################################
step "1/5" "Checking system"

# Check GRUB
if [ -d "/boot/grub" ]; then
    GRUB_DIR="/boot/grub"
elif [ -d "/boot/grub2" ]; then
    GRUB_DIR="/boot/grub2"
else
    err "GRUB not found!"
    exit 1
fi
ok "GRUB: $GRUB_DIR"

# Platform
if [ -d "$GRUB_DIR/x86_64-efi" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/x86_64-efi"
    GRUB_PLATFORM="x86_64-efi"
elif [ -d "$GRUB_DIR/i386-pc" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/i386-pc"
    GRUB_PLATFORM="i386-pc"
else
    err "Unknown GRUB platform"
    exit 1
fi
ok "Platform: $GRUB_PLATFORM"

# Python
if ! command -v python3 &>/dev/null; then
    err "Python3 required. Install: apt install python3"
    exit 1
fi
ok "Python3 found"

########################################
# STEP 2: Detect controller
########################################
step "2/5" "Detecting controller"

echo -e "  ${YELLOW}Connect your SNES USB controller now${NC}"
echo ""
read -r -p "  Press ENTER when ready... " _

CTRL=$(lsusb | grep -iE "game|pad|joystick|snes|0810|0079|0583|2dc8" | head -1 || true)

if [ -z "$CTRL" ]; then
    err "No controller found!"
    lsusb | head -10
    exit 1
fi

ok "Found: $CTRL"

########################################
# STEP 3: Map controller (MANDATORY)
########################################
step "3/5" "Map controller buttons"

echo -e "  ${RED}${BOLD}>>> MANDATORY: You must map your controller <<<${NC}"
echo ""

# Install pyusb
info "Installing USB library..."
pip3 install -q pyusb 2>/dev/null || pip3 install -q --break-system-packages pyusb 2>/dev/null || true

if ! python3 -c "import usb.core" 2>/dev/null; then
    err "Cannot import pyusb. Try: apt install libusb-1.0-0-dev"
    exit 1
fi
ok "USB library ready"

echo ""
echo -e "  ${YELLOW}${BOLD}Press each button when asked (10 sec timeout)${NC}"
echo ""
sleep 1

# Simple inline Python mapper - runs directly (not captured)
MAPPER_EXIT=0
set +e  # Disable errexit so we can capture Python's exit code
python3 << 'PYEOF'
import sys, time
import usb.core, usb.util

G='\033[92m'; Y='\033[93m'; R='\033[91m'; B='\033[1m'; N='\033[0m'

def ok(s): print(f"  {G}[OK]{N} {s}")
def err(s): print(f"  {R}[ERROR]{N} {s}")

# Find HID device
dev = None
for d in usb.core.find(find_all=True):
    try:
        for c in d:
            for i in c:
                if i.bInterfaceClass == 3:  # HID
                    if not (i.bInterfaceSubClass == 1 and i.bInterfaceProtocol in [1,2]):
                        dev = d
                        break
            if dev: break
        if dev: break
    except: pass

if not dev:
    err("No USB HID controller found!")
    sys.exit(1)

ok(f"Controller: VID=0x{dev.idVendor:04x} PID=0x{dev.idProduct:04x}")

# Setup
try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
except: pass
try: dev.set_configuration()
except: pass

cfg = dev.get_active_configuration()
intf = cfg[(0,0)]
ep = None
for e in intf:
    if usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN:
        ep = e
        break

if not ep:
    err("No input endpoint!")
    sys.exit(1)

ok(f"Endpoint: 0x{ep.bEndpointAddress:02x}")

# Baseline
print(f"\n  {Y}Do NOT press anything for 2 seconds...{N}")
time.sleep(0.5)
reports = []
for _ in range(20):
    try:
        r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
        reports.append(r)
    except: pass
    time.sleep(0.05)

if not reports:
    err("Cannot read from controller!")
    sys.exit(1)

baseline = max(set(reports), key=reports.count)
ok(f"Baseline: {baseline.hex()}")

# Map buttons
buttons = [("D-PAD UP", "up"), ("D-PAD DOWN", "down"), ("A BUTTON", "a"), ("START", "start")]
detected = 0

print(f"\n  {B}Press each button when prompted:{N}\n")

for name, key in buttons:
    print(f"  {Y}>>> Press {B}{name}{N}{Y} <<<{N}", end='', flush=True)
    found = False
    start = time.time()
    while time.time() - start < 10:
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                for i in range(len(baseline)):
                    if i < len(r) and baseline[i] != r[i]:
                        print(f"\r  {G}[OK]{N} {name}: byte {i} = 0x{baseline[i]:02x} -> 0x{r[i]:02x}       ")
                        detected += 1
                        found = True
                        # Wait release
                        time.sleep(0.3)
                        while True:
                            try:
                                r2 = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
                                if r2 == baseline: break
                            except: break
                            time.sleep(0.01)
                        break
                if found: break
        except: pass
        time.sleep(0.01)
    if not found:
        print(f"\r  {Y}[SKIP]{N} {name}: timeout                           ")
    time.sleep(0.2)

print(f"\n  {'='*40}\n")

if detected >= 2:
    ok(f"SUCCESS: {detected}/4 buttons detected")
    print(f"\n  BUTTONS_OK")
    sys.exit(0)
else:
    err(f"FAILED: Only {detected}/4 buttons detected")
    err("Need at least 2 buttons. Check your controller.")
    sys.exit(1)
PYEOF

MAPPER_EXIT=$?
set -e  # Re-enable errexit

if [ $MAPPER_EXIT -ne 0 ]; then
    err "Controller mapping failed!"
    exit 1
fi

ok "Controller verified!"

########################################
# STEP 4: Build GRUB module
########################################
step "4/5" "Build GRUB module"

echo -e "  ${YELLOW}This compiles GRUB from source (5-15 min)${NC}"
echo ""
read -r -p "  Continue? [Y/n] " CONFIRM

if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    info "Cancelled. Run again when ready."
    exit 0
fi

# Install build deps
info "Installing build tools..."
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq git build-essential autoconf automake autopoint \
    gettext bison flex libusb-1.0-0-dev pkg-config fonts-unifont \
    help2man texinfo python-is-python3 2>/dev/null || true
ok "Build tools installed"

# Clone GRUB
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

info "Downloading GRUB source..."
if ! git clone -q -b grub-gamepad https://github.com/tsoding/grub.git grub 2>&1; then
    err "Git clone failed"
    exit 1
fi
ok "GRUB downloaded"

cd grub
export PYTHON=python3

# Bootstrap
info "Running bootstrap (3-8 min, please wait)..."
echo "  (Progress: check with 'ls $BUILD_DIR/grub/gnulib' in another terminal)"

if ! ./bootstrap > ../bootstrap.log 2>&1; then
    err "Bootstrap failed"
    tail -20 ../bootstrap.log
    exit 1
fi
ok "Bootstrap done"

# Configure
info "Configuring..."
CONF_OPTS="--with-platform=${GRUB_PLATFORM##*-} --disable-werror --enable-usb"
[ "$GRUB_PLATFORM" = "x86_64-efi" ] && CONF_OPTS="$CONF_OPTS --target=x86_64"

if ! ./configure $CONF_OPTS > ../configure.log 2>&1; then
    err "Configure failed"
    tail -20 ../configure.log
    exit 1
fi
ok "Configure done"

# Make
info "Compiling (3-5 min)..."
CORES=$(nproc 2>/dev/null || echo 2)

if ! make -j"$CORES" > ../make.log 2>&1; then
    err "Compile failed"
    tail -20 ../make.log
    exit 1
fi
ok "Compile done"

# Find module
MOD=$(find . -name "usb_gamepad.mod" | head -1)
if [ -z "$MOD" ]; then
    err "Module not found!"
    exit 1
fi

cp "$MOD" "$GRUB_MOD_DIR/usb_gamepad.mod"
ok "Module installed: $GRUB_MOD_DIR/usb_gamepad.mod"

########################################
# STEP 5: Configure GRUB
########################################
step "5/5" "Configure GRUB"

GRUB_CUSTOM="/etc/grub.d/40_custom"

if ! grep -q "usb_gamepad" "$GRUB_CUSTOM" 2>/dev/null; then
    echo "" >> "$GRUB_CUSTOM"
    echo "# SNES Gamepad" >> "$GRUB_CUSTOM"
    echo "insmod usb_gamepad" >> "$GRUB_CUSTOM"
    echo "terminal_input --append usb_gamepad" >> "$GRUB_CUSTOM"
    ok "Added to GRUB config"
fi

# Update GRUB
if command -v update-grub &>/dev/null; then
    update-grub 2>/dev/null || true
elif command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
fi
ok "GRUB updated"

# Cleanup
cd /
rm -rf "$BUILD_DIR"

########################################
# DONE
########################################
echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}        Installation Complete!          ${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo "  Controls:"
echo "    D-pad Up/Down  ->  Navigate"
echo "    A or Start     ->  Select"
echo ""
echo -e "  ${CYAN}Reboot and test in GRUB menu!${NC}"
echo ""
