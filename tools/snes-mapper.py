#!/usr/bin/env python3
"""
SNES Controller Mapper for GRUB
Interactive tool to detect and map USB SNES controller buttons
"""

import os
import sys
import time
import json
import struct
import subprocess
from pathlib import Path

# Check if running as root (needed for USB access)
if os.geteuid() != 0:
    print("This tool needs root access to read USB devices.")
    print("Please run: sudo python3 snes-mapper.py")
    sys.exit(1)

try:
    import usb.core
    import usb.util
except ImportError:
    print("Installing required package: pyusb")
    subprocess.run([sys.executable, "-m", "pip", "install", "pyusb"], check=True)
    import usb.core
    import usb.util

# ANSI colors
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RESET = '\033[0m'

def clear_screen():
    os.system('clear' if os.name == 'posix' else 'cls')

def print_header():
    clear_screen()
    print(f"{Colors.CYAN}{Colors.BOLD}")
    print("╔═══════════════════════════════════════════════════════════╗")
    print("║         SNES Controller Mapper for GRUB                   ║")
    print("║         Configure your controller for bootloader          ║")
    print("╚═══════════════════════════════════════════════════════════╝")
    print(f"{Colors.RESET}")

def print_step(step, total, text):
    print(f"\n{Colors.BLUE}[{step}/{total}]{Colors.RESET} {Colors.BOLD}{text}{Colors.RESET}\n")

def print_success(text):
    print(f"{Colors.GREEN}✓ {text}{Colors.RESET}")

def print_error(text):
    print(f"{Colors.RED}✗ {text}{Colors.RESET}")

def print_info(text):
    print(f"{Colors.CYAN}ℹ {text}{Colors.RESET}")

def print_warning(text):
    print(f"{Colors.YELLOW}⚠ {text}{Colors.RESET}")

# Known SNES controller vendor/product IDs
KNOWN_CONTROLLERS = {
    (0x0810, 0xe501): "Generic Chinese SNES",
    (0x0079, 0x0011): "DragonRise Generic",
    (0x0583, 0x2060): "iBuffalo SNES",
    (0x2dc8, 0x9018): "8BitDo SN30",
    (0x12bd, 0xd015): "Generic 2-pack SNES",
    (0x1a34, 0x0802): "USB Gamepad",
    (0x0810, 0x0001): "Generic USB Gamepad",
    (0x0079, 0x0006): "DragonRise Gamepad",
}

def find_game_controllers():
    """Find all connected USB game controllers"""
    controllers = []

    # Find all USB devices
    devices = usb.core.find(find_all=True)

    for dev in devices:
        # Check if it's a known controller
        key = (dev.idVendor, dev.idProduct)
        if key in KNOWN_CONTROLLERS:
            controllers.append({
                'device': dev,
                'vendor_id': dev.idVendor,
                'product_id': dev.idProduct,
                'name': KNOWN_CONTROLLERS[key]
            })
            continue

        # Check if it's HID class (0x03) - likely a gamepad
        try:
            for cfg in dev:
                for intf in cfg:
                    if intf.bInterfaceClass == 0x03:  # HID
                        # Try to get product name
                        try:
                            name = usb.util.get_string(dev, dev.iProduct) or "Unknown HID Device"
                        except:
                            name = "Unknown HID Device"

                        # Filter out keyboards and mice by checking subclass/protocol
                        # Subclass 1 = Boot Interface, Protocol 1 = Keyboard, 2 = Mouse
                        if intf.bInterfaceSubClass == 1 and intf.bInterfaceProtocol in [1, 2]:
                            continue

                        controllers.append({
                            'device': dev,
                            'vendor_id': dev.idVendor,
                            'product_id': dev.idProduct,
                            'name': name
                        })
                        break
        except:
            pass

    return controllers

def select_controller(controllers):
    """Let user select a controller from the list"""
    print(f"\n{Colors.BOLD}Found {len(controllers)} controller(s):{Colors.RESET}\n")

    for i, ctrl in enumerate(controllers):
        known = " (known)" if (ctrl['vendor_id'], ctrl['product_id']) in KNOWN_CONTROLLERS else ""
        print(f"  {Colors.CYAN}{i + 1}.{Colors.RESET} {ctrl['name']}{known}")
        print(f"     VID: {Colors.DIM}0x{ctrl['vendor_id']:04x}{Colors.RESET}  PID: {Colors.DIM}0x{ctrl['product_id']:04x}{Colors.RESET}")
        print()

    while True:
        try:
            choice = input(f"{Colors.YELLOW}Select controller (1-{len(controllers)}): {Colors.RESET}")
            idx = int(choice) - 1
            if 0 <= idx < len(controllers):
                return controllers[idx]
        except ValueError:
            pass
        print_error("Invalid choice, try again")

def setup_device(controller):
    """Setup USB device for reading"""
    dev = controller['device']

    # Detach kernel driver if active
    try:
        if dev.is_kernel_driver_active(0):
            dev.detach_kernel_driver(0)
            print_info("Detached kernel driver")
    except:
        pass

    # Set configuration
    try:
        dev.set_configuration()
    except:
        pass

    # Find interrupt IN endpoint
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]

    ep = None
    for endpoint in intf:
        if usb.util.endpoint_direction(endpoint.bEndpointAddress) == usb.util.ENDPOINT_IN:
            if usb.util.endpoint_type(endpoint.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR:
                ep = endpoint
                break

    if not ep:
        print_error("Could not find interrupt endpoint!")
        sys.exit(1)

    return dev, ep

def read_report(dev, ep, timeout=100):
    """Read a single HID report"""
    try:
        data = dev.read(ep.bEndpointAddress, ep.wMaxPacketSize, timeout)
        return bytes(data)
    except usb.core.USBTimeoutError:
        return None
    except Exception as e:
        return None

def get_baseline(dev, ep):
    """Get baseline report (no buttons pressed)"""
    print_info("Reading baseline (don't press anything)...")
    time.sleep(0.5)

    # Read several reports and use the most common
    reports = []
    for _ in range(20):
        report = read_report(dev, ep, timeout=50)
        if report:
            reports.append(report)
        time.sleep(0.05)

    if not reports:
        print_error("Could not read from controller!")
        sys.exit(1)

    # Use the most common report as baseline
    baseline = max(set(reports), key=reports.count)
    print_success(f"Baseline: {baseline.hex()}")
    return baseline

def wait_for_button(dev, ep, baseline, button_name, timeout=30):
    """Wait for user to press a button and detect which one"""
    print(f"\n{Colors.YELLOW}>>> Press {Colors.BOLD}{button_name}{Colors.RESET}{Colors.YELLOW} <<<{Colors.RESET}")
    print(f"{Colors.DIM}(waiting {timeout} seconds...){Colors.RESET}")

    start_time = time.time()
    detected_changes = []

    while time.time() - start_time < timeout:
        report = read_report(dev, ep, timeout=50)

        if report and report != baseline:
            # Found a different report - button pressed!
            changes = []
            for i, (a, b) in enumerate(zip(baseline, report)):
                if a != b:
                    changes.append({
                        'byte': i,
                        'baseline': a,
                        'pressed': b,
                        'diff': b ^ a
                    })

            if changes:
                detected_changes.append({
                    'report': report,
                    'changes': changes
                })

                # Wait for button release
                print(f"{Colors.DIM}Detected! Waiting for release...{Colors.RESET}")
                while True:
                    report = read_report(dev, ep, timeout=50)
                    if report == baseline:
                        break
                    time.sleep(0.01)

                return detected_changes[0]

        time.sleep(0.01)

    return None

def map_controller(dev, ep):
    """Interactive mapping process"""
    print_step(2, 4, "Mapping controller buttons")

    baseline = get_baseline(dev, ep)

    buttons_to_map = [
        ("D-PAD UP", "dpad_up"),
        ("D-PAD DOWN", "dpad_down"),
        ("D-PAD LEFT", "dpad_left"),
        ("D-PAD RIGHT", "dpad_right"),
        ("A BUTTON", "btn_a"),
        ("B BUTTON", "btn_b"),
        ("X BUTTON", "btn_x"),
        ("Y BUTTON", "btn_y"),
        ("START", "btn_start"),
        ("SELECT", "btn_select"),
        ("L SHOULDER", "btn_l"),
        ("R SHOULDER", "btn_r"),
    ]

    mapping = {
        'baseline': baseline.hex(),
        'report_size': len(baseline),
        'buttons': {}
    }

    print(f"\n{Colors.BOLD}Press each button when prompted.{Colors.RESET}")
    print(f"{Colors.DIM}Press Ctrl+C to skip a button.{Colors.RESET}\n")

    for display_name, key_name in buttons_to_map:
        try:
            result = wait_for_button(dev, ep, baseline, display_name)

            if result:
                mapping['buttons'][key_name] = {
                    'changes': result['changes'],
                    'report': result['report'].hex()
                }

                # Show what was detected
                for change in result['changes']:
                    print_success(f"Detected: Byte {change['byte']}: "
                                f"0x{change['baseline']:02x} -> 0x{change['pressed']:02x}")
            else:
                print_warning(f"Timeout - skipping {display_name}")

        except KeyboardInterrupt:
            print_warning(f"Skipped {display_name}")
            continue

    return mapping

def generate_config(controller, mapping):
    """Generate configuration files"""
    print_step(3, 4, "Generating configuration")

    config_dir = Path(__file__).parent.parent / "configs"
    config_dir.mkdir(exist_ok=True)

    # Generate filename from controller info
    filename = f"controller_{controller['vendor_id']:04x}_{controller['product_id']:04x}.json"
    config_path = config_dir / filename

    config = {
        'controller': {
            'name': controller['name'],
            'vendor_id': f"0x{controller['vendor_id']:04x}",
            'product_id': f"0x{controller['product_id']:04x}",
        },
        'mapping': mapping
    }

    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)

    print_success(f"Saved config: {config_path}")

    # Generate C code snippet
    c_code = generate_c_code(controller, mapping)
    c_path = config_dir / f"controller_{controller['vendor_id']:04x}_{controller['product_id']:04x}.c"

    with open(c_path, 'w') as f:
        f.write(c_code)

    print_success(f"Saved C code: {c_path}")

    return config_path, c_path

def generate_c_code(controller, mapping):
    """Generate C code for the GRUB module"""
    code = f'''/*
 * Auto-generated controller configuration
 * Controller: {controller['name']}
 * VID: 0x{controller['vendor_id']:04x}  PID: 0x{controller['product_id']:04x}
 */

/* Add to supported_controllers[] array: */
{{ 0x{controller['vendor_id']:04x}, 0x{controller['product_id']:04x}, "{controller['name']}" }},

/* HID Report Analysis:
 * Report size: {mapping['report_size']} bytes
 * Baseline (neutral): {mapping['baseline']}
 */

'''

    # Analyze the mapping to generate button detection code
    if mapping['buttons']:
        code += "/* Button mappings detected:\n"
        for btn_name, btn_data in mapping['buttons'].items():
            for change in btn_data['changes']:
                code += f" * {btn_name}: byte[{change['byte']}] "
                code += f"0x{change['baseline']:02x} -> 0x{change['pressed']:02x}\n"
        code += " */\n"

    return code

def show_summary(controller, mapping, config_path, c_path):
    """Show final summary"""
    print_step(4, 4, "Summary")

    print(f"{Colors.BOLD}Controller:{Colors.RESET} {controller['name']}")
    print(f"{Colors.BOLD}VID:{Colors.RESET} 0x{controller['vendor_id']:04x}  {Colors.BOLD}PID:{Colors.RESET} 0x{controller['product_id']:04x}")
    print()

    print(f"{Colors.BOLD}Mapped buttons:{Colors.RESET}")
    for btn_name in mapping['buttons'].keys():
        print(f"  {Colors.GREEN}✓{Colors.RESET} {btn_name}")
    print()

    print(f"{Colors.BOLD}Generated files:{Colors.RESET}")
    print(f"  • {config_path}")
    print(f"  • {c_path}")
    print()

    print(f"{Colors.CYAN}Next steps:{Colors.RESET}")
    print(f"  1. Review the generated files")
    print(f"  2. Add the controller to src/usb_snes_gamepad.c")
    print(f"  3. Build and test: make build && make test")
    print()

    print(f"{Colors.GREEN}{Colors.BOLD}Done!{Colors.RESET}")

def main():
    print_header()

    # Step 1: Find controllers
    print_step(1, 4, "Detecting USB controllers")

    controllers = find_game_controllers()

    if not controllers:
        print_error("No game controllers found!")
        print_info("Make sure your SNES USB controller is connected.")
        print_info("Run 'lsusb' to see all connected USB devices.")
        sys.exit(1)

    # Select controller
    controller = select_controller(controllers)
    print_success(f"Selected: {controller['name']}")

    # Setup device
    dev, ep = setup_device(controller)
    print_success(f"Device ready (endpoint: 0x{ep.bEndpointAddress:02x})")

    # Map buttons
    mapping = map_controller(dev, ep)

    # Generate configs
    config_path, c_path = generate_config(controller, mapping)

    # Show summary
    show_summary(controller, mapping, config_path, c_path)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n\n{Colors.YELLOW}Cancelled by user{Colors.RESET}")
        sys.exit(0)
    except Exception as e:
        print_error(f"Error: {e}")
        sys.exit(1)
