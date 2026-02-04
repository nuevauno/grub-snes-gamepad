#!/bin/bash
#
# GRUB Boot Selector Installer v5.0
# https://github.com/nuevauno/grub-boot-selector
#
# This version compiles a NEW module from scratch based on the working
# usb_keyboard.c code, instead of patching tsoding's code.
#

VERSION="5.0"

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GRUB_DIR=""
GRUB_MOD_DIR=""
GRUB_PLATFORM=""
BUILD_DIR="/tmp/grub-boot-selector-build-$$"

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; }
err() { echo -e "  ${RED}[ERROR]${NC} $1"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }

header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo -e "${CYAN}${BOLD}     GRUB Boot Selector Installer v${VERSION}${NC}"
    echo -e "${CYAN}${BOLD}================================================${NC}"
    echo ""
}

step() {
    echo ""
    echo -e "${BLUE}━━━ STEP $1: $2 ━━━${NC}"
    echo ""
}

cleanup() {
    [ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR" 2>/dev/null || true
}
trap cleanup EXIT

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
elif [ -d "$GRUB_DIR/i386-efi" ]; then
    GRUB_MOD_DIR="$GRUB_DIR/i386-efi"
    GRUB_PLATFORM="i386-efi"
else
    err "Unknown GRUB platform"
    ls -la "$GRUB_DIR"
    exit 1
fi
ok "Platform: $GRUB_PLATFORM"

########################################
# STEP 2: Detect controller
########################################
step "2/5" "Detecting controller"

echo -e "  ${YELLOW}Connect your SNES USB controller now${NC}"
echo ""
read -r -p "  Press ENTER when ready... "

CTRL=$(lsusb | grep -iE "game|pad|joystick|snes|0810|0079|0583|2dc8|12bd|1a34" | head -1 || true)

if [ -z "$CTRL" ]; then
    warn "No known controller found. Showing all USB devices:"
    lsusb
    echo ""
    read -r -p "  Continue anyway? [y/N] " CONT
    if [ "$CONT" != "y" ] && [ "$CONT" != "Y" ]; then
        exit 1
    fi
else
    ok "Found: $CTRL"
fi

# Extract VID:PID for later
VID=""
PID=""
if [ -n "$CTRL" ]; then
    VID_PID=$(echo "$CTRL" | grep -oE "[0-9a-f]{4}:[0-9a-f]{4}" | head -1)
    VID=$(echo "$VID_PID" | cut -d: -f1)
    PID=$(echo "$VID_PID" | cut -d: -f2)
    ok "Controller ID: VID=0x$VID PID=0x$PID"
fi

########################################
# STEP 3: Quick button test
########################################
step "3/5" "Quick button test"

# Try to install pyusb for button test
pip3 install -q pyusb 2>/dev/null || pip3 install -q --break-system-packages pyusb 2>/dev/null || true

if python3 -c "import usb.core" 2>/dev/null; then
    echo -e "  ${YELLOW}Press any button on your controller...${NC}"

    set +e
    timeout 5 python3 << 'PYEOF' 2>/dev/null
import usb.core, usb.util, sys, time

KNOWN = [(0x0810,0xe501),(0x0079,0x0011),(0x0583,0x2060),(0x2dc8,0x9018),
         (0x12bd,0xd015),(0x1a34,0x0802),(0x0810,0x0001),(0x0079,0x0006)]

dev = None
for d in usb.core.find(find_all=True):
    if (d.idVendor, d.idProduct) in KNOWN:
        dev = d
        break
    try:
        for cfg in d:
            for intf in cfg:
                if intf.bInterfaceClass == 3 and intf.bInterfaceSubClass != 1:
                    dev = d
                    break
    except: pass
    if dev: break

if not dev:
    print("  No controller found")
    sys.exit(1)

try:
    if dev.is_kernel_driver_active(0):
        dev.detach_kernel_driver(0)
    dev.set_configuration()
    cfg = dev.get_active_configuration()
    ep = None
    for intf in cfg:
        for e in intf:
            if usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN:
                if usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR:
                    ep = e
                    break
        if ep: break

    if not ep:
        print("  No interrupt endpoint")
        sys.exit(1)

    # Get baseline
    baseline = None
    for _ in range(10):
        try:
            baseline = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
            break
        except: pass

    if not baseline:
        print("  Cannot read from device")
        sys.exit(1)

    print(f"  Baseline: {baseline.hex()}")

    # Wait for button press
    start = time.time()
    while time.time() - start < 4:
        try:
            data = bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, 100))
            if data != baseline:
                print(f"  \033[92mButton detected!\033[0m Report: {data.hex()}")
                sys.exit(0)
        except: pass

    print("  No button press detected")
except Exception as e:
    print(f"  Error: {e}")
PYEOF
    set -e
    echo ""
else
    warn "pyusb not available - skipping button test"
fi

read -r -p "  Press ENTER to continue to build... "

########################################
# STEP 4: Build GRUB module
########################################
step "4/5" "Building GRUB module"

echo -e "  ${YELLOW}${BOLD}This compiles a custom GRUB module for SNES controllers${NC}"
echo -e "  ${YELLOW}Build time: 10-20 minutes${NC}"
echo ""
read -r -p "  Continue? [Y/n] " CONFIRM

if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    info "Cancelled"
    exit 0
fi

# Install dependencies
info "Installing build dependencies..."
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq git build-essential autoconf automake autopoint \
    gettext bison flex pkg-config fonts-unifont help2man texinfo \
    python3 liblzma-dev 2>/dev/null || true
ok "Dependencies installed"

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Clone official GRUB (we need the build system)
info "Downloading GRUB source..."
if ! git clone -q --depth 1 https://git.savannah.gnu.org/git/grub.git grub 2>&1; then
    # Fallback to GitHub mirror
    if ! git clone -q --depth 1 https://github.com/rhboot/grub2.git grub 2>&1; then
        err "Failed to clone GRUB"
        exit 1
    fi
fi
ok "GRUB source downloaded"

cd grub

# Write our custom module source
info "Creating usb_snes module..."

cat > grub-core/term/usb_snes.c << 'MODSRC'
/*
 *  GRUB USB SNES Gamepad - Based on working usb_keyboard.c
 *
 *  Key difference: Accepts HID devices with ANY subclass/protocol,
 *  not just keyboards (subclass=1, protocol=1).
 */

#include <grub/term.h>
#include <grub/time.h>
#include <grub/misc.h>
#include <grub/usb.h>
#include <grub/dl.h>

GRUB_MOD_LICENSE ("GPLv3+");

#define USB_HID_SET_IDLE        0x0A
#define USB_HID_SET_PROTOCOL    0x0B
#define SNES_REPORT_SIZE 8
#define AXIS_CENTER      0x7F
#define AXIS_THRESHOLD   0x40
#define MAX_GAMEPADS 8

static struct {
    grub_uint16_t vid;
    grub_uint16_t pid;
} supported_devices[] = {
    {0x0810, 0xe501}, {0x0079, 0x0011}, {0x0583, 0x2060},
    {0x2dc8, 0x9018}, {0x12bd, 0xd015}, {0x1a34, 0x0802},
    {0x0810, 0x0001}, {0x0079, 0x0006}, {0x046d, 0xc218},
    {0, 0}
};

struct grub_usb_snes_data {
    grub_usb_device_t usbdev;
    int interfno;
    struct grub_usb_desc_endp *endp;
    grub_usb_transfer_t transfer;
    grub_uint8_t report[SNES_REPORT_SIZE];
    grub_uint8_t prev_report[SNES_REPORT_SIZE];
    int dead;
    int key_queue[32];
    int key_queue_head, key_queue_tail, key_queue_count;
};

static struct grub_term_input grub_usb_snes_terms[MAX_GAMEPADS];

static void key_queue_push(struct grub_usb_snes_data *d, int k) {
    if (d->key_queue_count >= 32 || k == GRUB_TERM_NO_KEY) return;
    d->key_queue[d->key_queue_tail] = k;
    d->key_queue_tail = (d->key_queue_tail + 1) % 32;
    d->key_queue_count++;
}

static int key_queue_pop(struct grub_usb_snes_data *d) {
    if (d->key_queue_count <= 0) return GRUB_TERM_NO_KEY;
    int k = d->key_queue[d->key_queue_head];
    d->key_queue_head = (d->key_queue_head + 1) % 32;
    d->key_queue_count--;
    return k;
}

static int is_supported(grub_uint16_t v, grub_uint16_t p) {
    for (int i = 0; supported_devices[i].vid; i++)
        if (supported_devices[i].vid == v && supported_devices[i].pid == p)
            return 1;
    return 0;
}

static void parse_report(struct grub_usb_snes_data *d) {
    grub_uint8_t *p = d->prev_report, *c = d->report;

    int pu = (p[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int pd = (p[1] > AXIS_CENTER + AXIS_THRESHOLD);
    int pl = (p[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int pr = (p[0] > AXIS_CENTER + AXIS_THRESHOLD);
    int cu = (c[1] < AXIS_CENTER - AXIS_THRESHOLD);
    int cd = (c[1] > AXIS_CENTER + AXIS_THRESHOLD);
    int cl = (c[0] < AXIS_CENTER - AXIS_THRESHOLD);
    int cr = (c[0] > AXIS_CENTER + AXIS_THRESHOLD);

    if (!pu && cu) key_queue_push(d, GRUB_TERM_KEY_UP);
    if (!pd && cd) key_queue_push(d, GRUB_TERM_KEY_DOWN);
    if (!pl && cl) key_queue_push(d, GRUB_TERM_KEY_LEFT);
    if (!pr && cr) key_queue_push(d, GRUB_TERM_KEY_RIGHT);

    grub_uint8_t pb = p[4], cb = c[4];
    if (!(pb & 0x02) && (cb & 0x02)) key_queue_push(d, '\r');  /* A */
    if (!(pb & 0x04) && (cb & 0x04)) key_queue_push(d, GRUB_TERM_ESC); /* B */
    if (!(pb & 0x80) && (cb & 0x80)) key_queue_push(d, '\r');  /* Start */
    if (!(pb & 0x40) && (cb & 0x40)) key_queue_push(d, GRUB_TERM_ESC); /* Select */
    if (!(pb & 0x10) && (cb & 0x10)) key_queue_push(d, GRUB_TERM_KEY_PPAGE); /* L */
    if (!(pb & 0x20) && (cb & 0x20)) key_queue_push(d, GRUB_TERM_KEY_NPAGE); /* R */
}

static int grub_usb_snes_getkey(struct grub_term_input *t) {
    struct grub_usb_snes_data *d = t->data;
    grub_size_t actual;

    if (d->dead) return GRUB_TERM_NO_KEY;
    if (d->key_queue_count > 0) return key_queue_pop(d);

    grub_usb_err_t err = grub_usb_check_transfer(d->transfer, &actual);
    if (err == GRUB_USB_ERR_WAIT) return GRUB_TERM_NO_KEY;

    if (err == GRUB_USB_ERR_NONE && actual >= 1) {
        parse_report(d);
        grub_memcpy(d->prev_report, d->report, SNES_REPORT_SIZE);
    }

    d->transfer = grub_usb_bulk_read_background(d->usbdev, d->endp,
        sizeof(d->report), (char *)d->report);
    if (!d->transfer) { d->dead = 1; return GRUB_TERM_NO_KEY; }

    return key_queue_pop(d);
}

static int grub_usb_snes_getkeystatus(struct grub_term_input *t __attribute__((unused))) {
    return 0;
}

static void grub_usb_snes_detach(grub_usb_device_t usbdev,
    int config __attribute__((unused)), int iface __attribute__((unused))) {
    for (unsigned i = 0; i < MAX_GAMEPADS; i++) {
        struct grub_usb_snes_data *d = grub_usb_snes_terms[i].data;
        if (!d || d->usbdev != usbdev) continue;
        if (d->transfer) grub_usb_cancel_transfer(d->transfer);
        grub_term_unregister_input(&grub_usb_snes_terms[i]);
        grub_free((char *)grub_usb_snes_terms[i].name);
        grub_usb_snes_terms[i].name = NULL;
        grub_free(d);
        grub_usb_snes_terms[i].data = NULL;
    }
}

static int grub_usb_snes_attach(grub_usb_device_t usbdev, int configno, int interfno) {
    if (!is_supported(usbdev->descdev.vendorid, usbdev->descdev.prodid))
        return 0;

    unsigned curnum;
    for (curnum = 0; curnum < MAX_GAMEPADS; curnum++)
        if (!grub_usb_snes_terms[curnum].data) break;
    if (curnum == MAX_GAMEPADS) return 0;

    struct grub_usb_desc_endp *endp = NULL;
    for (int j = 0; j < usbdev->config[configno].interf[interfno].descif->endpointcnt; j++) {
        endp = &usbdev->config[configno].interf[interfno].descendp[j];
        if ((endp->endp_addr & 128) && grub_usb_get_ep_type(endp) == GRUB_USB_EP_INTERRUPT)
            break;
    }
    if (!endp) return 0;

    struct grub_usb_snes_data *d = grub_malloc(sizeof(*d));
    if (!d) return 0;
    grub_memset(d, 0, sizeof(*d));
    d->usbdev = usbdev;
    d->interfno = interfno;
    d->endp = endp;
    d->prev_report[0] = d->prev_report[1] = AXIS_CENTER;

    /* CRITICAL: HID initialization from working usb_keyboard.c */
    grub_usb_set_configuration(usbdev, configno + 1);
    grub_usb_control_msg(usbdev, GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
        USB_HID_SET_PROTOCOL, 0, interfno, 0, 0);
    grub_usb_control_msg(usbdev, GRUB_USB_REQTYPE_CLASS_INTERFACE_OUT,
        USB_HID_SET_IDLE, 0, interfno, 0, 0);

    grub_usb_snes_terms[curnum].name = grub_xasprintf("usb_snes%d", curnum);
    grub_usb_snes_terms[curnum].getkey = grub_usb_snes_getkey;
    grub_usb_snes_terms[curnum].getkeystatus = grub_usb_snes_getkeystatus;
    grub_usb_snes_terms[curnum].data = d;
    grub_usb_snes_terms[curnum].next = 0;

    usbdev->config[configno].interf[interfno].detach_hook = grub_usb_snes_detach;

    d->transfer = grub_usb_bulk_read_background(usbdev, d->endp,
        sizeof(d->report), (char *)d->report);
    if (!d->transfer) { grub_free(d); return 0; }

    grub_term_register_input_active("usb_snes", &grub_usb_snes_terms[curnum]);
    grub_printf("SNES gamepad connected!\n");
    return 1;
}

static struct grub_usb_attach_desc attach_hook = {
    .class = GRUB_USB_CLASS_HID,
    .hook = grub_usb_snes_attach
};

GRUB_MOD_INIT(usb_snes) {
    grub_usb_register_attach_hook_class(&attach_hook);
}

GRUB_MOD_FINI(usb_snes) {
    for (unsigned i = 0; i < MAX_GAMEPADS; i++) {
        struct grub_usb_snes_data *d = grub_usb_snes_terms[i].data;
        if (!d) continue;
        if (d->transfer) grub_usb_cancel_transfer(d->transfer);
        grub_term_unregister_input(&grub_usb_snes_terms[i]);
        grub_free((char *)grub_usb_snes_terms[i].name);
        grub_free(d);
        grub_usb_snes_terms[i].data = NULL;
    }
    grub_usb_unregister_attach_hook_class(&attach_hook);
}
MODSRC

ok "Module source created"

# Add to GRUB build system
info "Configuring build system..."

# Add module to Makefile.core.def
if ! grep -q "usb_snes" grub-core/Makefile.core.def 2>/dev/null; then
    cat >> grub-core/Makefile.core.def << 'MAKEDEF'

module = {
  name = usb_snes;
  common = term/usb_snes.c;
  enable = usb;
};
MAKEDEF
fi
ok "Build system configured"

# Bootstrap
export PYTHON=python3
info "Running bootstrap (5-10 minutes)..."
if ! ./bootstrap > ../bootstrap.log 2>&1; then
    err "Bootstrap failed"
    tail -30 ../bootstrap.log
    exit 1
fi
ok "Bootstrap complete"

# Configure
info "Configuring..."
CONF_OPTS="--with-platform=${GRUB_PLATFORM##*-} --disable-werror --enable-usb"
[ "$GRUB_PLATFORM" = "x86_64-efi" ] && CONF_OPTS="$CONF_OPTS --target=x86_64"
[ "$GRUB_PLATFORM" = "i386-efi" ] && CONF_OPTS="$CONF_OPTS --target=i386"

if ! ./configure $CONF_OPTS > ../configure.log 2>&1; then
    err "Configure failed"
    tail -30 ../configure.log
    exit 1
fi
ok "Configure complete"

# Compile
info "Compiling (5-10 minutes)..."
CORES=$(nproc 2>/dev/null || echo 2)
if ! make -j"$CORES" > ../make.log 2>&1; then
    err "Compile failed"
    tail -50 ../make.log
    exit 1
fi
ok "Compile complete"

# Find and copy module
MOD=$(find . -name "usb_snes.mod" -type f 2>/dev/null | head -1)
if [ -z "$MOD" ]; then
    warn "usb_snes.mod not found, looking for usb_gamepad.mod..."
    MOD=$(find . -name "usb_gamepad.mod" -type f 2>/dev/null | head -1)
fi

if [ -z "$MOD" ]; then
    err "No gamepad module found!"
    echo "Available modules:"
    find . -name "*.mod" | grep -i usb | head -10
    exit 1
fi

cp "$MOD" "$GRUB_MOD_DIR/usb_snes.mod"
chmod 644 "$GRUB_MOD_DIR/usb_snes.mod"
ok "Module installed: $GRUB_MOD_DIR/usb_snes.mod"

########################################
# STEP 5: Configure GRUB
########################################
step "5/5" "Configuring GRUB"

GRUB_CUSTOM="/etc/grub.d/40_custom"

# Backup
if [ ! -f "${GRUB_CUSTOM}.backup-snes" ]; then
    cp "$GRUB_CUSTOM" "${GRUB_CUSTOM}.backup-snes"
    ok "Backed up GRUB config"
fi

# Add gamepad configuration
if ! grep -q "usb_snes" "$GRUB_CUSTOM" 2>/dev/null; then
    cat >> "$GRUB_CUSTOM" << 'GRUBEOF'

# ========================================
# SNES Gamepad Support (v5.0)
# ========================================
# Load USB drivers
insmod ohci
insmod uhci
insmod ehci
insmod xhci

# Load USB stack
insmod usb

# Load SNES gamepad module
insmod usb_snes

# Register gamepad as input
terminal_input --append usb_snes
GRUBEOF
    ok "Added SNES config to GRUB"
else
    info "GRUB already configured"
fi

# Update GRUB
info "Updating GRUB..."
if command -v update-grub &>/dev/null; then
    update-grub 2>/dev/null || true
elif command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o "$GRUB_DIR/grub.cfg" 2>/dev/null || true
fi
ok "GRUB updated"

# Cleanup
cd /
rm -rf "$BUILD_DIR"

########################################
# DONE
########################################
echo ""
echo -e "${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}          Installation Complete!                ${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}"
echo ""
echo "  Module: $GRUB_MOD_DIR/usb_snes.mod"
echo ""
echo "  Controls:"
echo "    D-pad Up/Down    -> Navigate menu"
echo "    D-pad Left/Right -> Submenus"
echo "    A / Start        -> Select (Enter)"
echo "    B / Select       -> Back (Escape)"
echo "    L / R            -> Page Up/Down"
echo ""
echo -e "  ${CYAN}${BOLD}Reboot to test!${NC}"
echo ""
echo "  Debug (in GRUB press 'c'):"
echo "    set debug=usb_snes"
echo "    terminal_input usb_snes"
echo ""
echo "  Uninstall:"
echo "    sudo rm $GRUB_MOD_DIR/usb_snes.mod"
echo "    sudo cp ${GRUB_CUSTOM}.backup-snes $GRUB_CUSTOM"
echo "    sudo update-grub"
echo ""
