#!/bin/bash
#
# GRUB SNES Gamepad Installer v0.6
# https://github.com/nuevauno/grub-snes-gamepad
#
# Builds and installs a custom GRUB module for USB gamepad support
# Based on https://github.com/tsoding/grub (grub-gamepad branch)
#

set -e

# Trap errors for better debugging
trap 'echo "Error at line $LINENO. Exit code: $?" >&2' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Spinner function - runs in background
spinner_pid=""

start_spinner() {
    local msg="$1"
    (
        chars='|/-\'
        while true; do
            for (( i=0; i<${#chars}; i++ )); do
                printf "\r  [%s] %s" "${chars:$i:1}" "$msg"
                sleep 0.2
            done
        done
    ) &
    spinner_pid=$!
}

stop_spinner() {
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        spinner_pid=""
        printf "\r                                                              \r"
    fi
}

# Cleanup spinner on exit
trap stop_spinner EXIT

print_header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}=======================================================${NC}"
    echo -e "${CYAN}${BOLD}       GRUB SNES Gamepad Installer v0.6                ${NC}"
    echo -e "${CYAN}${BOLD}       Control your bootloader with a game controller  ${NC}"
    echo -e "${CYAN}${BOLD}=======================================================${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${BLUE}--- STEP ${1}/${2}: ${BOLD}${3}${NC} ---"
    echo ""
}

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

# Run command with spinner
run_with_spinner() {
    local msg="$1"
    local logfile="$2"
    shift 2

    start_spinner "$msg"
    if "$@" > "$logfile" 2>&1; then
        stop_spinner
        return 0
    else
        stop_spinner
        return 1
    fi
}

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Run as root${NC}"
    echo "Usage: sudo bash install.sh"
    exit 1
fi

print_header

#######################################
# STEP 1: Check system
#######################################
print_step 1 6 "Checking system"

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
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

case "$DISTRO" in
    ubuntu|debian|linuxmint|pop)
        start_spinner "Updating package lists..."
        apt-get update -qq 2>/dev/null
        stop_spinner
        ok "Package lists updated"

        # Full list of packages required for GRUB compilation from git source
        # See: https://www.gnu.org/software/grub/manual/grub/html_node/Obtaining-and-Building-GRUB.html
        GRUB_BUILD_DEPS="git build-essential autoconf automake autopoint autogen gettext bison flex"
        GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS python3 python3-pip python-is-python3"
        GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libusb-1.0-0-dev pkg-config fonts-unifont libfreetype-dev"
        GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS help2man texinfo liblzma-dev libopts25 libopts25-dev"
        GRUB_BUILD_DEPS="$GRUB_BUILD_DEPS libdevmapper-dev libfuse-dev xorriso"

        start_spinner "Installing build tools (this takes ~2 min)..."
        if ! apt-get install -y -qq $GRUB_BUILD_DEPS 2>/dev/null; then
            stop_spinner
            warn "Some optional packages failed, trying essential packages only..."
            start_spinner "Installing essential packages..."
            apt-get install -y -qq git build-essential autoconf automake autopoint gettext bison flex python3 python3-pip libusb-1.0-0-dev pkg-config fonts-unifont help2man texinfo 2>/dev/null || true
            stop_spinner
        fi
        ok "APT packages installed"
        ;;
    fedora)
        start_spinner "Installing packages with dnf..."
        dnf install -y -q git gcc make autoconf automake autogen gettext bison flex python3 python3-pip libusb1-devel texinfo help2man xz-devel device-mapper-devel 2>/dev/null
        stop_spinner
        ok "DNF packages installed"
        ;;
    arch|manjaro)
        start_spinner "Installing packages with pacman..."
        pacman -Sy --noconfirm git base-devel autoconf automake autogen gettext bison flex python python-pip libusb texinfo help2man xz device-mapper 2>/dev/null
        stop_spinner
        ok "Pacman packages installed"
        ;;
    *)
        warn "Unknown distro, trying to continue..."
        ;;
esac

# Install pyusb
if pip3 install pyusb -q 2>/dev/null || pip install pyusb -q 2>/dev/null; then
    ok "Python USB library ready"
else
    warn "Could not install pyusb via pip, will try in Python"
fi

#######################################
# STEP 3: Detect controller
#######################################
print_step 3 6 "Detecting USB controller"

echo -e "  ${YELLOW}Please connect your SNES USB controller now${NC}"
echo ""
read -p "  Press ENTER when connected... " DUMMY
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

# Extract ID using sed (more portable than grep -P)
CONTROLLER_ID=$(echo "$CONTROLLER_LINE" | sed -n 's/.*ID \([0-9a-f]*:[0-9a-f]*\).*/\1/p')
VENDOR_ID="0x$(echo "$CONTROLLER_ID" | cut -d: -f1)"
PRODUCT_ID="0x$(echo "$CONTROLLER_ID" | cut -d: -f2)"

ok "Found: $CONTROLLER_LINE"
ok "VID: $VENDOR_ID  PID: $PRODUCT_ID"

#######################################
# STEP 4: Test controller buttons
#######################################
print_step 4 6 "Testing controller"

# Create Python script in temp file to avoid heredoc issues
PYSCRIPT=$(mktemp /tmp/mapper_XXXXXX.py)

cat > "$PYSCRIPT" << 'ENDPYTHON'
import os
import sys
import time
import json
import subprocess

try:
    import usb.core
    import usb.util
except ImportError:
    print("  Installing pyusb...")
    subprocess.run([sys.executable, "-m", "pip", "install", "pyusb", "-q"], check=False)
    import usb.core
    import usb.util

GREEN = '\033[92m'
YELLOW = '\033[93m'
RED = '\033[91m'
BOLD = '\033[1m'
DIM = '\033[2m'
NC = '\033[0m'

def ok(t):
    print("  " + GREEN + "[OK]" + NC + " " + t)

def warn(t):
    print("  " + YELLOW + "[WARN]" + NC + " " + t)

KNOWN = {
    (0x0810, 0xe501): "Generic SNES",
    (0x0079, 0x0011): "DragonRise",
    (0x0583, 0x2060): "iBuffalo",
    (0x2dc8, 0x9018): "8BitDo",
    (0x12bd, 0xd015): "Generic 2-pack",
    (0x1a34, 0x0802): "USB Gamepad",
}

# Find controller
dev = None
for d in usb.core.find(find_all=True):
    key = (d.idVendor, d.idProduct)
    if key in KNOWN or d.bDeviceClass == 0:
        try:
            for cfg in d:
                for intf in cfg:
                    if intf.bInterfaceClass == 3:
                        dev = d
                        break
                if dev:
                    break
        except Exception:
            pass
    if dev:
        break

if not dev:
    print("  " + RED + "[ERROR]" + NC + " No controller found")
    sys.exit(1)

name = KNOWN.get((dev.idVendor, dev.idProduct), "USB Controller")
ok("Controller: " + name)

# Setup
try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
except Exception:
    pass

try:
    dev.set_configuration()
except Exception:
    pass

# Find endpoint
ep = None
try:
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]
    for e in intf:
        if usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN:
            ep = e
            break
except Exception:
    pass

if not ep:
    print("  " + RED + "[ERROR]" + NC + " No endpoint found")
    sys.exit(1)

# Read baseline
print("")
print("  " + DIM + "Reading baseline (don't touch controller)..." + NC)
time.sleep(0.5)

reports = []
for _ in range(10):
    try:
        r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
        reports.append(r)
    except Exception:
        pass
    time.sleep(0.05)

if not reports:
    print("  " + RED + "[ERROR]" + NC + " Cannot read controller")
    sys.exit(1)

baseline = max(set(reports), key=reports.count)
ok("Baseline: " + baseline.hex())

# Test buttons
buttons = [
    ("D-PAD UP", "up"),
    ("D-PAD DOWN", "down"),
    ("A BUTTON", "a"),
    ("START", "start")
]
mapping = {}

print("")
print("  " + BOLD + "Quick button test (4 buttons):" + NC)
print("")

for display, key in buttons:
    sys.stdout.write("  " + YELLOW + ">>> Press " + BOLD + display + NC + YELLOW + " <<<" + NC)
    sys.stdout.flush()

    start = time.time()
    detected = False

    while time.time() - start < 10:
        try:
            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
            if r != baseline:
                changes = []
                for i in range(min(len(baseline), len(r))):
                    if baseline[i] != r[i]:
                        changes.append((i, baseline[i], r[i]))

                if changes:
                    mapping[key] = changes
                    i, a, b = changes[0]
                    result = "  " + GREEN + "[OK]" + NC + " " + display + ": Byte " + str(i) + " = 0x" + format(a, '02x') + " -> 0x" + format(b, '02x')
                    print("\r" + result + "          ")
                    detected = True

                    # Wait for release
                    for _ in range(100):
                        try:
                            r = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 50))
                            if r == baseline:
                                break
                        except Exception:
                            break
                        time.sleep(0.01)
                    break
        except Exception:
            pass
        time.sleep(0.01)

    if not detected:
        print("\r  " + YELLOW + "[WARN]" + NC + " " + display + ": timeout (skipped)                    ")

print("")
print("  " + GREEN + "Controller working!" + NC + " Detected " + str(len(mapping)) + "/4 buttons")

# Save config
config_dir = "/usr/local/share/grub-snes-gamepad"
try:
    os.makedirs(config_dir, exist_ok=True)
except Exception:
    pass

config_data = {
    'vid': "0x" + format(dev.idVendor, '04x'),
    'pid': "0x" + format(dev.idProduct, '04x'),
    'baseline': baseline.hex(),
    'mapping': {}
}

for k, v in mapping.items():
    config_data['mapping'][k] = [[i, "0x" + format(a, '02x'), "0x" + format(b, '02x')] for i, a, b in v]

try:
    with open(config_dir + "/controller.json", 'w') as f:
        json.dump(config_data, f, indent=2)
    ok("Config saved: " + config_dir + "/controller.json")
except Exception as e:
    warn("Could not save config: " + str(e))
ENDPYTHON

python3 "$PYSCRIPT"
MAPPER_EXIT=$?
rm -f "$PYSCRIPT"

if [ "$MAPPER_EXIT" -ne 0 ]; then
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
read -p "  Continue with build? [Y/n] " BUILD_CONFIRM
echo ""

if [ "$BUILD_CONFIRM" = "n" ] || [ "$BUILD_CONFIRM" = "N" ]; then
    info "Skipped build. Run install.sh again to build later."
    exit 0
fi

BUILD_DIR="/tmp/grub-snes-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || { err "Cannot create build directory"; exit 1; }

# Clone GRUB with gamepad support
# Note: We need full clone (not shallow) because bootstrap checks git history
echo ""
start_spinner "Downloading GRUB source (this may take 1-2 minutes)..."
if git clone -b grub-gamepad https://github.com/tsoding/grub.git grub > clone.log 2>&1; then
    stop_spinner
    ok "GRUB source downloaded"
else
    stop_spinner
    err "Failed to clone GRUB. Check your internet connection."
    cat clone.log | tail -10
    exit 1
fi

cd grub || { err "Cannot enter grub directory"; exit 1; }

# Set PYTHON env var to ensure python3 is used (autogen.sh defaults to 'python')
export PYTHON=python3

# Bootstrap - this downloads gnulib and generates Makefile.util.am
# This step can take 2-5 minutes as it clones gnulib from git.sv.gnu.org
info "Running bootstrap (downloads gnulib, may take 3-5 minutes)..."
info "This step clones gnulib from git.sv.gnu.org and generates build files"
echo ""

# Run bootstrap with verbose output to a log, show progress to user
(
    count=0
    while true; do
        count=$((count + 1))
        dots=""
        for i in $(seq 1 $((count % 4))); do
            dots="${dots}."
        done
        printf "\r  [*] Bootstrap in progress%-4s (elapsed: %ds)" "$dots" "$count"
        sleep 1
    done
) &
BOOTSTRAP_PROGRESS_PID=$!

if ./bootstrap > ../bootstrap.log 2>&1; then
    kill $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    wait $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    printf "\r                                                              \r"
    ok "Bootstrap complete"
else
    kill $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    wait $BOOTSTRAP_PROGRESS_PID 2>/dev/null || true
    printf "\r                                                              \r"

    # Check for common errors
    if grep -q "gnulib" ../bootstrap.log 2>/dev/null; then
        err "Bootstrap failed during gnulib download"
        warn "This is often a network issue. Gnulib is downloaded from git.sv.gnu.org"
        echo ""
        info "Trying alternative approach: manual gnulib clone..."

        # Try cloning gnulib manually
        if [ ! -d "gnulib" ]; then
            start_spinner "Cloning gnulib manually (this takes 2-3 minutes)..."
            if git clone --depth 1 https://git.savannah.gnu.org/git/gnulib.git gnulib > ../gnulib-clone.log 2>&1; then
                stop_spinner
                ok "Gnulib cloned successfully"

                # Retry bootstrap with local gnulib
                info "Retrying bootstrap with local gnulib..."
                if ./bootstrap --gnulib-srcdir=gnulib > ../bootstrap2.log 2>&1; then
                    ok "Bootstrap complete (with manual gnulib)"
                else
                    err "Bootstrap still failed. See $BUILD_DIR/bootstrap2.log"
                    cat ../bootstrap2.log | tail -20
                    exit 1
                fi
            else
                stop_spinner
                err "Failed to clone gnulib manually"
                cat ../gnulib-clone.log | tail -10
                exit 1
            fi
        fi
    elif grep -q "Makefile.util.am" ../bootstrap.log 2>/dev/null; then
        err "Bootstrap failed: Makefile.util.am not generated"
        warn "This usually means autogen.sh failed. Checking Python..."

        # Check if python works
        if ! command -v python3 > /dev/null 2>&1; then
            err "Python3 not found! Please install python3."
            exit 1
        fi

        # Try running autogen.sh directly
        info "Trying to run autogen.sh directly..."
        if [ -f "grub-core/lib/gnulib/stdlib.in.h" ]; then
            if ./autogen.sh > ../autogen.log 2>&1; then
                ok "autogen.sh completed"
            else
                err "autogen.sh failed. See $BUILD_DIR/autogen.log"
                cat ../autogen.log | tail -20
                exit 1
            fi
        else
            err "Gnulib not properly bootstrapped"
            echo ""
            cat ../bootstrap.log | tail -30
            exit 1
        fi
    else
        err "Bootstrap failed. Check $BUILD_DIR/bootstrap.log"
        echo ""
        echo "Last 30 lines of bootstrap.log:"
        cat ../bootstrap.log | tail -30
        exit 1
    fi
fi

# Verify that Makefile.util.am was generated
if [ ! -f "Makefile.util.am" ]; then
    err "Makefile.util.am was not generated!"
    warn "This file should be created by autogen.sh/gentpl.py"

    # Try running autogen.sh if gnulib exists
    if [ -f "grub-core/lib/gnulib/stdlib.in.h" ]; then
        info "Gnulib exists, trying to run autogen.sh..."
        if FROM_BOOTSTRAP=1 ./autogen.sh > ../autogen-retry.log 2>&1; then
            ok "autogen.sh succeeded"
        else
            err "autogen.sh failed"
            cat ../autogen-retry.log | tail -20
            exit 1
        fi
    else
        err "Gnulib not found. Bootstrap did not complete properly."
        exit 1
    fi
fi

# Double-check the file exists now
if [ ! -f "Makefile.util.am" ]; then
    err "Makefile.util.am still not found after all attempts!"
    err "Cannot continue without this file."
    exit 1
fi

ok "Build system files generated successfully"

# Configure
info "Configuring GRUB for $GRUB_PLATFORM (2-3 minutes)..."
echo ""

# Determine configure options based on platform
CONFIGURE_OPTS="--with-platform=${GRUB_PLATFORM##*-}"
if [ "$GRUB_PLATFORM" = "x86_64-efi" ]; then
    CONFIGURE_OPTS="$CONFIGURE_OPTS --target=x86_64"
elif [ "$GRUB_PLATFORM" = "i386-pc" ]; then
    CONFIGURE_OPTS="$CONFIGURE_OPTS --target=i386"
fi

# Disable some features we don't need to speed up compilation
CONFIGURE_OPTS="$CONFIGURE_OPTS --disable-werror"

start_spinner "Running configure..."
if ./configure $CONFIGURE_OPTS > ../configure.log 2>&1; then
    stop_spinner
    ok "Configure complete"
else
    stop_spinner

    # Check for common configure errors
    if grep -q "cannot run C compiled programs" ../configure.log 2>/dev/null; then
        err "Configure failed: Cannot run compiled programs"
        warn "This might be a cross-compilation issue or missing libc"
    elif grep -q "C compiler cannot create executables" ../configure.log 2>/dev/null; then
        err "Configure failed: C compiler not working"
        warn "Please ensure gcc/build-essential is properly installed"
    else
        err "Configure failed. Check $BUILD_DIR/configure.log"
    fi

    echo ""
    echo "Last 30 lines of configure.log:"
    cat ../configure.log | tail -30
    exit 1
fi

# Build - this is the long one, show progress
info "Compiling GRUB (3-5 minutes)..."
echo ""
CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# Show a progress indicator during make
(
    count=0
    while true; do
        count=$((count + 1))
        bar=""
        pct=$((count % 100))
        filled=$((pct / 5))
        for i in $(seq 1 20); do
            if [ $i -le $filled ]; then
                bar="${bar}#"
            else
                bar="${bar}-"
            fi
        done
        printf "\r  [%s] Compiling... (%d files processed)" "$bar" "$count"
        sleep 0.5
    done
) &
PROGRESS_PID=$!

if make -j"$CORES" > ../make.log 2>&1; then
    kill $PROGRESS_PID 2>/dev/null || true
    wait $PROGRESS_PID 2>/dev/null || true
    printf "\r                                                                    \r"
    ok "Compilation complete"
else
    kill $PROGRESS_PID 2>/dev/null || true
    wait $PROGRESS_PID 2>/dev/null || true
    printf "\r                                                                    \r"
    err "Compilation failed. Check $BUILD_DIR/make.log"
    cat ../make.log | tail -30
    exit 1
fi

# Find the module
MODULE=$(find . -name "usb_gamepad.mod" 2>/dev/null | head -1)

if [ -z "$MODULE" ]; then
    err "Module not found after build!"
    info "Looking for any .mod files..."
    find . -name "*.mod" 2>/dev/null | head -10
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
    echo "" >> "$GRUB_CUSTOM"
    echo "# SNES Gamepad Support - added by grub-snes-gamepad" >> "$GRUB_CUSTOM"
    echo "insmod usb_gamepad" >> "$GRUB_CUSTOM"
    echo "terminal_input --append usb_gamepad" >> "$GRUB_CUSTOM"
    ok "Added gamepad to GRUB config"
else
    info "GRUB already configured"
fi

# Update GRUB
start_spinner "Updating GRUB configuration..."
if command -v update-grub > /dev/null 2>&1; then
    update-grub > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with update-grub"
elif command -v grub2-mkconfig > /dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with grub2-mkconfig"
elif command -v grub-mkconfig > /dev/null 2>&1; then
    grub-mkconfig -o "$GRUB_DIR/grub.cfg" > /dev/null 2>&1 || true
    stop_spinner
    ok "GRUB updated with grub-mkconfig"
else
    stop_spinner
    warn "Could not find grub update command. Please run update-grub manually."
fi

# Cleanup
cd /
rm -rf "$BUILD_DIR"
ok "Cleaned up build files"

# Create uninstaller
mkdir -p /usr/local/share/grub-snes-gamepad

cat > /usr/local/share/grub-snes-gamepad/uninstall.sh << 'ENDUNINSTALL'
#!/bin/bash
echo "Uninstalling GRUB SNES Gamepad..."
rm -f /boot/grub/x86_64-efi/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub/i386-pc/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub2/x86_64-efi/usb_gamepad.mod 2>/dev/null
rm -f /boot/grub2/i386-pc/usb_gamepad.mod 2>/dev/null
if [ -f /etc/grub.d/40_custom.backup-snes ]; then
    cp /etc/grub.d/40_custom.backup-snes /etc/grub.d/40_custom
    echo "Restored GRUB config"
fi
if command -v update-grub > /dev/null 2>&1; then
    update-grub 2>/dev/null
elif command -v grub2-mkconfig > /dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null
fi
rm -rf /usr/local/share/grub-snes-gamepad
echo "Done! GRUB SNES Gamepad has been uninstalled."
ENDUNINSTALL

chmod +x /usr/local/share/grub-snes-gamepad/uninstall.sh

#######################################
# DONE!
#######################################
echo ""
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo -e "${GREEN}${BOLD}              Installation Complete!                    ${NC}"
echo -e "${GREEN}${BOLD}=======================================================${NC}"
echo ""
echo -e "  ${BOLD}Button Mapping:${NC}"
echo "    D-pad Up/Down  ->  Navigate menu"
echo "    A or Start     ->  Select entry"
echo "    B              ->  Cancel/Back"
echo ""
echo -e "  ${BOLD}Next step:${NC}"
echo -e "    ${CYAN}Reboot your computer and test in GRUB menu!${NC}"
echo ""
echo -e "  ${DIM}To uninstall: sudo /usr/local/share/grub-snes-gamepad/uninstall.sh${NC}"
echo ""
