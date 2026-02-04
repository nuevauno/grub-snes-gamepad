#!/bin/bash
#
# GRUB Boot Selector
#
# Selector de SO que corre DESPUES de GRUB, antes del login.
# Se ejecuta como ExecStartPre del display manager.
#

set -Eeuo pipefail

VERSION="2026.02.04"
INSTALL_LOG="/var/log/boot-selector-install.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

exec > >(tee -a "$INSTALL_LOG") 2>&1
trap 'echo -e "${RED}Error en linea ${LINENO}. Revisa ${INSTALL_LOG}${NC}"' ERR

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║        GRUB Boot Selector              ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}${BOLD}           Version ${VERSION}                   ${NC}"
    echo ""
}

step() {
    echo -e "${GREEN}[$1]${NC} $2"
}

err() { echo -e "${RED}Error:${NC} $1"; }
warn() { echo -e "${YELLOW}Aviso:${NC} $1"; }

header

if [ "$EUID" -ne 0 ]; then
    err "Ejecutar como root (sudo)"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    err "systemd no disponible (systemctl)."
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    err "Sistema no soportado"
    exit 1
fi

# Paso 0: limpiar versiones anteriores
step "0/5" "Limpiando versiones anteriores..."

systemctl disable boot-selector.service 2>/dev/null || true
rm -f /etc/systemd/system/boot-selector.service
rm -rf /etc/systemd/system/display-manager.service.d/wait-boot-selector.conf
rm -f /run/boot-selector-done

OLD_DM=$(cat /opt/boot-selector/.dm-service 2>/dev/null || true)
if [ -n "${OLD_DM}" ]; then
    rm -f "/etc/systemd/system/${OLD_DM}.d/boot-selector.conf" || true
    rmdir "/etc/systemd/system/${OLD_DM}.d" 2>/dev/null || true
fi

rm -rf /opt/boot-selector

# Paso 1: dependencias
step "1/5" "Instalando dependencias..."

install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Usando apt-get"
        apt-get update -qq || true
        apt-get install -y -qq python3 python3-evdev joystick kbd
    elif command -v dnf >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Usando dnf"
        dnf -y install python3 python3-evdev joystick kbd
    elif command -v pacman >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Usando pacman"
        pacman -Sy --noconfirm python python-evdev joystick kbd
    elif command -v zypper >/dev/null 2>&1; then
        echo -e "  ${CYAN}→${NC} Usando zypper"
        zypper --non-interactive install python3 python3-evdev joystick kbd
    else
        err "No se encontro un gestor de paquetes soportado."
        exit 1
    fi

    if ! python3 -c "import evdev" >/dev/null 2>&1; then
        warn "python3-evdev no disponible via paquetes, intentando pip..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y -qq python3-pip || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf -y install python3-pip || true
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm python-pip || true
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install python3-pip || true
        fi
        pip3 install evdev || pip install evdev || true
    fi

    if ! python3 -c "import evdev" >/dev/null 2>&1; then
        err "No se pudo instalar python3-evdev"
        exit 1
    fi
}

install_deps

# Paso 2: detectar display manager
step "2/5" "Detectando display manager..."

DM_SERVICE=""

if [ -L /etc/systemd/system/display-manager.service ]; then
    DM_SERVICE=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
fi

if [ -z "$DM_SERVICE" ]; then
    for dm in gdm3 gdm lightdm sddm lxdm; do
        if systemctl is-enabled "${dm}.service" 2>/dev/null | grep -q "enabled"; then
            DM_SERVICE="${dm}.service"
            break
        fi
    done
fi

if [ -z "$DM_SERVICE" ]; then
    err "No se detecto display manager"
    exit 1
fi

echo -e "  ${GREEN}✓${NC} Display manager: ${BOLD}${DM_SERVICE}${NC}"

# Paso 3: crear scripts
step "3/5" "Creando selector..."

mkdir -p /opt/boot-selector

echo "$DM_SERVICE" > /opt/boot-selector/.dm-service

cat > /opt/boot-selector/run.sh << 'RUNEOF'
#!/bin/bash
set +e

LOGFILE="/var/log/boot-selector.log"
FLAG="/run/boot-selector-done"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') RUN: $*" >> "$LOGFILE"; }

log "========================================"
log "run.sh started (PID=$$)"

if [ -f "$FLAG" ]; then
    log "Flag exists -> skip"
    exit 0
fi

# Esperar USB
log "Waiting 2s for USB..."
sleep 2

# Detener Plymouth si existe
if command -v plymouth &>/dev/null; then
    log "Stopping Plymouth..."
    plymouth quit 2>/dev/null && log "Plymouth quit OK" || log "Plymouth quit failed"
    sleep 0.5
else
    log "Plymouth not found (skipping)"
fi

# Forzar modo texto en tty1
log "Forcing tty1 to text mode (KD_TEXT)..."
/usr/bin/python3 -c "
import fcntl, os
fd = os.open('/dev/tty1', os.O_WRONLY)
try:
    fcntl.ioctl(fd, 0x4B3A, 0)
finally:
    os.close(fd)
" 2>/dev/null && log "tty1 KD_TEXT OK" || log "tty1 KD_TEXT failed"

# Cambiar a tty1
log "Switching to tty1..."
chvt 1 2>/dev/null && log "chvt 1 OK" || log "chvt 1 failed"
sleep 0.3

# Limpiar pantalla
printf '\033[2J\033[H' > /dev/tty1 2>/dev/null

# Ejecutar selector
log "Starting selector.py on tty1..."
/usr/bin/python3 /opt/boot-selector/selector.py < /dev/tty1 > /dev/tty1 2>> "$LOGFILE"
RESULT=$?
log "selector.py exited with code $RESULT"

# Marcar como ejecutado
: > "$FLAG"
log "Flag created"

log "run.sh finished"
exit 0
RUNEOF
chmod +x /opt/boot-selector/run.sh

cat > /opt/boot-selector/selector.py << 'PYEOF'
#!/usr/bin/env python3
"""
Boot Selector - Gamepad USB + Teclado.
Usa evdev para leer el gamepad directamente.
"""

import os
import sys
import time
import select
import logging
import subprocess
import re
import shutil

# --- Logging ---

logging.basicConfig(
    filename="/var/log/boot-selector.log",
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s: %(message)s",
)
log = logging.getLogger("boot-selector")
log.info("selector.py started (PID=%d)", os.getpid())

# --- Config ---

TIMEOUT = 15
DEFAULT_SEL = 0
TEST_MODE = "--test" in sys.argv
APP_VERSION = "2026.02.04"
COMPANY_SITE = "nuevauno.com"
COMPANY_EMAIL = "hola@nuevauno.com"

# --- evdev ---

try:
    import evdev
    from evdev import ecodes
    HAS_EVDEV = True
    log.info("evdev OK")
except ImportError:
    HAS_EVDEV = False
    log.warning("evdev not available")

# --- Colors ---

class C:
    G = '\033[1;32m'
    Y = '\033[1;33m'
    CN = '\033[1;36m'
    W = '\033[1;37m'
    N = '\033[0m'

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# --- Gamepad ---

def find_gamepad():
    if not HAS_EVDEV:
        return None
    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            caps = dev.capabilities(verbose=False)
            if ecodes.EV_ABS not in caps:
                continue
            abs_codes = [c for c, _ in caps[ecodes.EV_ABS]]
            has_xy = ecodes.ABS_X in abs_codes and ecodes.ABS_Y in abs_codes
            has_hat = ecodes.ABS_HAT0X in abs_codes and ecodes.ABS_HAT0Y in abs_codes
            if has_xy or has_hat:
                axis_info = {}
                for code, info in caps[ecodes.EV_ABS]:
                    if code in (ecodes.ABS_X, ecodes.ABS_Y,
                                ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
                        axis_info[code] = {'min': info.min, 'max': info.max}
                log.info("Gamepad: %s (%s) axes=%s", dev.name, dev.path, axis_info)
                return dev, axis_info
        except (PermissionError, OSError) as e:
            log.debug("Skip %s: %s", path, e)
    log.warning("No gamepad found")
    return None

def read_gamepad(dev, axis_info, timeout=0.05):
    if not dev:
        return None
    try:
        r, _, _ = select.select([dev.fd], [], [], timeout)
        if not r:
            return None
        last = None
        for event in dev.read():
            if event.type == ecodes.EV_ABS:
                if event.code == ecodes.ABS_Y:
                    info = axis_info.get(ecodes.ABS_Y, {'min': 0, 'max': 255})
                    center = (info['min'] + info['max']) // 2
                    thresh = (info['max'] - info['min']) // 4
                    if event.value < center - thresh:
                        last = 'up'
                    elif event.value > center + thresh:
                        last = 'down'
                elif event.code == ecodes.ABS_HAT0Y:
                    if event.value < 0:
                        last = 'up'
                    elif event.value > 0:
                        last = 'down'
            elif event.type == ecodes.EV_KEY and event.value == 1:
                if event.code in {304, 315, 288, 289, 297}:
                    last = 'select'
        return last
    except (OSError, IOError) as e:
        log.error("Gamepad error: %s", e)
    return None

# --- Keyboard ---

def setup_keyboard():
    import termios, tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    return old

def restore_keyboard(old):
    import termios
    try:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
    except Exception:
        pass

def read_keyboard(timeout=0.05):
    try:
        r, _, _ = select.select([sys.stdin], [], [], timeout)
        if not r:
            return None
        key = sys.stdin.read(1)
        if key == '\x1b':
            r2, _, _ = select.select([sys.stdin], [], [], 0.05)
            if r2:
                seq = sys.stdin.read(2)
                if seq == '[A': return 'up'
                if seq == '[B': return 'down'
        elif key in ('\r', '\n'):
            return 'select'
    except Exception:
        pass
    return None

# --- Menu ---

def get_windows_entry():
    try:
        with open("/boot/grub/grub.cfg") as f:
            for line in f:
                if "menuentry" in line and "indows" in line:
                    s = line.find("'")
                    if s != -1:
                        e = line.find("'", s + 1)
                        if e != -1:
                            return line[s+1:e]
    except FileNotFoundError:
        pass
    return None

def draw_menu(selected, remaining, gp_name):
    sys.stdout.write('\033[2J\033[H')
    sys.stdout.flush()
    width, height = shutil.get_terminal_size((80, 24))
    bar_len = max(24, min(60, width - 6))
    bar = "=" * bar_len
    sep = "-" * bar_len

    def strip_ansi(s):
        return ANSI_RE.sub("", s)

    def center_line(s):
        plain = strip_ansi(s)
        if not plain:
            return ""
        if len(plain) >= width:
            return s
        pad = (width - len(plain)) // 2
        return " " * pad + s

    u = f"{C.G}>> UBUNTU LINUX <<{C.N}" if selected == 0 else "   UBUNTU LINUX   "
    w = f"{C.G}>> WINDOWS <<{C.N}" if selected == 1 else "   WINDOWS   "
    gp = f"Gamepad: {C.G}{gp_name}{C.N}" if gp_name else f"Gamepad: {C.Y}No detectado (teclado){C.N}"

    lines = [
        center_line(f"{C.CN}{bar}{C.N}"),
        center_line(f"{C.CN}SELECTOR DE ARRANQUE{C.N}"),
        center_line(f"{C.CN}ELIGE SISTEMA OPERATIVO{C.N}"),
        center_line(f"{C.CN}{bar}{C.N}"),
        "",
        center_line(u),
        center_line(w),
        "",
        center_line(f"{C.Y}{sep}{C.N}"),
        "",
        center_line(f"{C.W}D-Pad / Flechas = Navegar{C.N}"),
        center_line(f"{C.W}A / Start / Enter = Seleccionar{C.N}"),
        "",
        center_line(f"{C.Y}Auto-boot en: {remaining} segundos{C.N}"),
        "",
        center_line(gp),
        "",
        center_line(f"{C.W}Version {APP_VERSION}{C.N}"),
        center_line(f"{C.W}{COMPANY_SITE}  |  {COMPANY_EMAIL}{C.N}"),
    ]

    pad_top = max(0, (height - len(lines)) // 2)
    if pad_top:
        sys.stdout.write("\n" * pad_top)
    print("\n".join(lines))

# --- Main ---

def main():
    gp_dev = None
    axis_info = {}
    gp_name = None
    grabbed = False

    result = find_gamepad()
    if result:
        gp_dev, axis_info = result
        gp_name = gp_dev.name
        try:
            gp_dev.grab()
            grabbed = True
        except (OSError, IOError):
            pass

    old_term = None
    try:
        old_term = setup_keyboard()
    except Exception as e:
        log.warning("Keyboard setup failed: %s", e)

    selected = DEFAULT_SEL
    interrupted = False
    remaining = TIMEOUT
    last_time = time.time()
    prev = (-1, -1)

    try:
        while remaining > 0:
            cur = (selected, int(remaining))
            if cur != prev:
                draw_menu(selected, int(remaining), gp_name)
                prev = cur

            action = read_gamepad(gp_dev, axis_info, 0.05)
            if not action:
                action = read_keyboard(0.05)

            if action == 'up':
                selected = 0
                remaining = TIMEOUT
            elif action == 'down':
                selected = 1
                remaining = TIMEOUT
            elif action == 'select':
                log.info("Confirmed: %s", "Ubuntu" if selected == 0 else "Windows")
                break

            now = time.time()
            remaining -= (now - last_time)
            last_time = now

        if remaining <= 0:
            log.info("Timeout -> %s", "Ubuntu" if selected == 0 else "Windows")

    except KeyboardInterrupt:
        interrupted = True
    finally:
        if grabbed and gp_dev:
            try:
                gp_dev.ungrab()
            except Exception:
                pass
        if old_term:
            restore_keyboard(old_term)

    if interrupted:
        return

    sys.stdout.write('\033[2J\033[H')
    sys.stdout.flush()

    if selected == 1:
        win = get_windows_entry()
        if win:
            print(f"{C.CN}Reiniciando a Windows...{C.N}")
            log.info("grub-reboot '%s'", win)
            subprocess.run(["grub-reboot", win], check=False)
            time.sleep(1)
            if not TEST_MODE:
                subprocess.run(["reboot"], check=False)
        else:
            print(f"{C.Y}Windows no encontrado, iniciando Ubuntu...{C.N}")
            time.sleep(2)
    else:
        print(f"{C.G}Iniciando Ubuntu...{C.N}")
        log.info("Booting Ubuntu")

    time.sleep(1)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.exception("Fatal: %s", e)
        sys.exit(1)
PYEOF
chmod +x /opt/boot-selector/selector.py

echo -e "  ${GREEN}✓${NC} Selector creado"

# Paso 4: inyectar en display manager
step "4/5" "Inyectando en ${DM_SERVICE}..."

DM_DROPIN_DIR="/etc/systemd/system/${DM_SERVICE}.d"
mkdir -p "$DM_DROPIN_DIR"

cat > "${DM_DROPIN_DIR}/boot-selector.conf" << 'DROPEOF'
[Service]
ExecStartPre=-/opt/boot-selector/run.sh
DROPEOF

systemctl daemon-reload

if systemctl cat "${DM_SERVICE}" 2>/dev/null | grep -q "boot-selector"; then
    echo -e "  ${GREEN}✓${NC} Verificado: ${DM_SERVICE} ejecutara el selector antes de arrancar"
else
    warn "No se pudo verificar el drop-in"
fi

# Paso 5: scripts utiles
step "5/5" "Creando scripts utiles..."

cat > /opt/boot-selector/test.sh << 'TESTEOF'
#!/bin/bash
set -e
sudo rm -f /run/boot-selector-done
sudo python3 /opt/boot-selector/selector.py --test
TESTEOF
chmod +x /opt/boot-selector/test.sh

cat > /opt/boot-selector/uninstall.sh << 'UNINSTEOF'
#!/bin/bash
set -e
DM_SERVICE=$(cat /opt/boot-selector/.dm-service 2>/dev/null || true)
if [ -n "$DM_SERVICE" ]; then
    rm -f "/etc/systemd/system/${DM_SERVICE}.d/boot-selector.conf"
    rmdir "/etc/systemd/system/${DM_SERVICE}.d" 2>/dev/null || true
fi
systemctl daemon-reload
rm -rf /opt/boot-selector
rm -f /run/boot-selector-done

echo "Boot Selector desinstalado"
UNINSTEOF
chmod +x /opt/boot-selector/uninstall.sh

echo ""
echo -e "${GREEN}Listo.${NC}"
echo "Probar: sudo /opt/boot-selector/test.sh"
echo "Log:   cat /var/log/boot-selector.log"
