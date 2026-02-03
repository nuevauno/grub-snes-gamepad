#!/usr/bin/env python3
"""
SNES Controller Mapper - Standalone version for installer
Maps controller buttons and optionally installs to GRUB
"""

import os
import sys
import time
import json
import argparse
import subprocess

# Check root
if os.geteuid() != 0:
    print("Error: Must run as root (sudo)")
    sys.exit(1)

# Install pyusb if needed
try:
    import usb.core
    import usb.util
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "pyusb", "-q"], check=True)
    import usb.core
    import usb.util

# ANSI Colors
class C:
    H = '\033[95m'; B = '\033[94m'; C = '\033[96m'; G = '\033[92m'
    Y = '\033[93m'; R = '\033[91m'; BOLD = '\033[1m'; DIM = '\033[2m'; N = '\033[0m'

def clear(): os.system('clear' if os.name == 'posix' else 'cls')

def ok(t): print(f"{C.G}✓ {t}{C.N}")
def err(t): print(f"{C.R}✗ {t}{C.N}")
def info(t): print(f"{C.C}ℹ {t}{C.N}")
def warn(t): print(f"{C.Y}⚠ {t}{C.N}")

# Known controllers
KNOWN = {
    (0x0810, 0xe501): "Generic Chinese SNES",
    (0x0079, 0x0011): "DragonRise Generic",
    (0x0583, 0x2060): "iBuffalo SNES",
    (0x2dc8, 0x9018): "8BitDo SN30",
    (0x12bd, 0xd015): "Generic 2-pack SNES",
    (0x1a34, 0x0802): "USB Gamepad",
    (0x0810, 0x0001): "Generic USB Gamepad",
    (0x0079, 0x0006): "DragonRise Gamepad",
}

def find_controllers():
    """Find USB game controllers"""
    controllers = []
    for dev in usb.core.find(find_all=True):
        key = (dev.idVendor, dev.idProduct)
        if key in KNOWN:
            controllers.append({'dev': dev, 'vid': dev.idVendor, 'pid': dev.idProduct, 'name': KNOWN[key]})
            continue
        try:
            for cfg in dev:
                for intf in cfg:
                    if intf.bInterfaceClass == 0x03:  # HID
                        if intf.bInterfaceSubClass == 1 and intf.bInterfaceProtocol in [1, 2]:
                            continue
                        try: name = usb.util.get_string(dev, dev.iProduct) or "Unknown"
                        except: name = "Unknown HID"
                        controllers.append({'dev': dev, 'vid': dev.idVendor, 'pid': dev.idProduct, 'name': name})
                        break
        except: pass
    return controllers

def setup_device(ctrl):
    """Setup USB device"""
    dev = ctrl['dev']
    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
    except: pass
    try: dev.set_configuration()
    except: pass

    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]
    for ep in intf:
        if usb.util.endpoint_direction(ep.bEndpointAddress) == usb.util.ENDPOINT_IN:
            if usb.util.endpoint_type(ep.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR:
                return dev, ep
    return None, None

def read_report(dev, ep, timeout=100):
    """Read HID report"""
    try:
        return bytes(dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, timeout))
    except: return None

def get_baseline(dev, ep):
    """Get neutral position baseline"""
    reports = []
    for _ in range(20):
        r = read_report(dev, ep, 50)
        if r: reports.append(r)
        time.sleep(0.05)
    if not reports:
        err("Cannot read controller")
        sys.exit(1)
    return max(set(reports), key=reports.count)

def wait_button(dev, ep, baseline, name, timeout=15):
    """Wait for button press"""
    print(f"\n{C.Y}>>> Press {C.BOLD}{name}{C.N}{C.Y} <<<{C.N}")
    print(f"{C.DIM}(waiting {timeout}s, Ctrl+C to skip){C.N}")

    start = time.time()
    while time.time() - start < timeout:
        r = read_report(dev, ep, 50)
        if r and r != baseline:
            changes = [{'byte': i, 'from': a, 'to': b} for i, (a, b) in enumerate(zip(baseline, r)) if a != b]
            if changes:
                print(f"{C.DIM}Release...{C.N}")
                while read_report(dev, ep, 50) != baseline: time.sleep(0.01)
                return {'report': r.hex(), 'changes': changes}
        time.sleep(0.01)
    return None

def map_controller(dev, ep):
    """Interactive mapping"""
    baseline = get_baseline(dev, ep)
    ok(f"Baseline: {baseline.hex()}")

    buttons = [
        ("D-PAD UP", "up"), ("D-PAD DOWN", "down"), ("D-PAD LEFT", "left"), ("D-PAD RIGHT", "right"),
        ("A BUTTON", "a"), ("B BUTTON", "b"), ("X BUTTON", "x"), ("Y BUTTON", "y"),
        ("START", "start"), ("SELECT", "select"), ("L SHOULDER", "l"), ("R SHOULDER", "r"),
    ]

    mapping = {'baseline': baseline.hex(), 'size': len(baseline), 'buttons': {}}

    print(f"\n{C.BOLD}Press each button when prompted:{C.N}\n")

    for display, key in buttons:
        try:
            result = wait_button(dev, ep, baseline, display)
            if result:
                mapping['buttons'][key] = result
                for c in result['changes']:
                    ok(f"Byte {c['byte']}: 0x{c['from']:02x} → 0x{c['to']:02x}")
            else:
                warn(f"Skipped {display}")
        except KeyboardInterrupt:
            warn(f"Skipped {display}")

    return mapping

def save_config(ctrl, mapping):
    """Save configuration"""
    config_dir = "/usr/local/share/grub-snes-gamepad"
    os.makedirs(config_dir, exist_ok=True)

    config = {
        'controller': {'name': ctrl['name'], 'vid': f"0x{ctrl['vid']:04x}", 'pid': f"0x{ctrl['pid']:04x}"},
        'mapping': mapping
    }

    path = f"{config_dir}/controller_{ctrl['vid']:04x}_{ctrl['pid']:04x}.json"
    with open(path, 'w') as f:
        json.dump(config, f, indent=2)

    ok(f"Config saved: {path}")
    return path

def main():
    parser = argparse.ArgumentParser(description='SNES Controller Mapper')
    parser.add_argument('--install', action='store_true', help='Install to GRUB after mapping')
    args = parser.parse_args()

    clear()
    print(f"{C.C}{C.BOLD}")
    print("╔═══════════════════════════════════════════════════════════╗")
    print("║            SNES Controller Mapper                         ║")
    print("╚═══════════════════════════════════════════════════════════╝")
    print(f"{C.N}\n")

    # Find controllers
    info("Detecting controllers...")
    controllers = find_controllers()

    if not controllers:
        err("No controllers found!")
        info("Connect your SNES USB controller and try again")
        sys.exit(1)

    # Show and select
    print(f"\n{C.BOLD}Found {len(controllers)} controller(s):{C.N}\n")
    for i, c in enumerate(controllers):
        known = " ✓" if (c['vid'], c['pid']) in KNOWN else ""
        print(f"  {C.C}{i+1}.{C.N} {c['name']}{known}")
        print(f"     {C.DIM}VID: 0x{c['vid']:04x}  PID: 0x{c['pid']:04x}{C.N}\n")

    if len(controllers) == 1:
        ctrl = controllers[0]
    else:
        while True:
            try:
                choice = int(input(f"{C.Y}Select (1-{len(controllers)}): {C.N}")) - 1
                if 0 <= choice < len(controllers):
                    ctrl = controllers[choice]
                    break
            except: pass
            err("Invalid choice")

    ok(f"Selected: {ctrl['name']}")

    # Setup device
    dev, ep = setup_device(ctrl)
    if not ep:
        err("Could not setup device")
        sys.exit(1)
    ok("Device ready")

    # Map buttons
    mapping = map_controller(dev, ep)

    # Save config
    save_config(ctrl, mapping)

    # Summary
    print(f"\n{C.G}{C.BOLD}Mapping complete!{C.N}\n")
    print(f"{C.BOLD}Mapped buttons:{C.N}")
    for btn in mapping['buttons']:
        print(f"  {C.G}✓{C.N} {btn}")
    print()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{C.Y}Cancelled{C.N}")
        sys.exit(0)
