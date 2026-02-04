#!/bin/bash
#
# Gamepad Boot Selector
#
# Selector de SO que corre DESPUÉS de GRUB, dentro de Linux.
# Se inyecta como ExecStartPre del display manager.
# Desactiva Plymouth (boot splash) para tomar control de la pantalla.
# Usa Python + evdev para leer gamepad USB.
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║      Gamepad Boot Selector             ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecutar como root (sudo)${NC}"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}Error: Sistema no soportado${NC}"
    exit 1
fi

# ── Limpiar versiones anteriores ──────────────────────────────────

echo -e "${GREEN}[0/5]${NC} Limpiando versiones anteriores..."
systemctl disable boot-selector.service 2>/dev/null || true
rm -f /etc/systemd/system/boot-selector.service
rm -rf /etc/systemd/system/display-manager.service.d/wait-boot-selector.conf
rm -f /run/boot-selector-done
# Limpiar drop-ins anteriores de cualquier DM
OLD_DM=$(cat /opt/boot-selector/.dm-service 2>/dev/null)
if [ -n "$OLD_DM" ]; then
    rm -f "/etc/systemd/system/${OLD_DM}.d/boot-selector.conf"
    rmdir "/etc/systemd/system/${OLD_DM}.d" 2>/dev/null || true
fi

# ── Paso 1: Dependencias ──────────────────────────────────────────

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 python3-evdev joystick kbd 2>/dev/null

if ! python3 -c "import evdev" 2>/dev/null; then
    echo -e "${YELLOW}python3-evdev no disponible via apt, intentando pip...${NC}"
    apt-get install -y -qq python3-pip 2>/dev/null || true
    pip3 install evdev 2>/dev/null || pip install evdev 2>/dev/null || true
fi

if ! python3 -c "import evdev" 2>/dev/null; then
    echo -e "${RED}Error: No se pudo instalar python3-evdev${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓${NC} python3-evdev instalado"

# ── Paso 2: Detectar display manager ─────────────────────────────

echo -e "${GREEN}[2/5]${NC} Detectando display manager..."

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
    echo -e "${RED}Error: No se detectó display manager${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓${NC} Display manager: ${BOLD}${DM_SERVICE}${NC}"

# ── Paso 3: Crear scripts ────────────────────────────────────────

echo -e "${GREEN}[3/5]${NC} Creando selector..."

mkdir -p /opt/boot-selector
echo "$DM_SERVICE" > /opt/boot-selector/.dm-service

# ── run.sh: wrapper que desactiva Plymouth y muestra el selector ──
cat > /opt/boot-selector/run.sh << 'RUNEOF'
#!/bin/bash
LOGFILE="/var/log/boot-selector.log"
FLAG="/run/boot-selector-done"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') RUN: $*" >> "$LOGFILE"; }

log "========================================"
log "run.sh started (PID=$$)"

if [ -f "$FLAG" ]; then
    log "Flag exists -> skip"
    exit 0
fi

# Esperar a que los dispositivos USB se enumeren
log "Waiting 2s for USB..."
sleep 2

# CRITICO: Plymouth (boot splash) controla el framebuffer durante el boot.
# Hay que PARARLO completamente (quit, no solo deactivate).
if command -v plymouth &>/dev/null; then
    log "Stopping Plymouth..."
    plymouth quit 2>/dev/null && log "Plymouth quit OK" || log "Plymouth quit failed (may not be running)"
    sleep 0.5
else
    log "Plymouth not found (skipping)"
fi

# CRITICO: Aunque Plymouth pare, el VT queda en modo KD_GRAPHICS.
# En ese modo el texto se escribe al buffer pero NO se renderiza en pantalla.
# Hay que forzar KD_TEXT (0x00) via ioctl KDSETMODE (0x4B3A).
log "Forcing tty1 to text mode (KD_TEXT)..."
/usr/bin/python3 -c "
import fcntl, os
fd = os.open('/dev/tty1', os.O_WRONLY)
try:
    fcntl.ioctl(fd, 0x4B3A, 0)  # KDSETMODE=0x4B3A, KD_TEXT=0x00
finally:
    os.close(fd)
" 2>/dev/null && log "tty1 KD_TEXT OK" || log "tty1 KD_TEXT failed"

# Cambiar a tty1
log "Switching to tty1..."
chvt 1 2>/dev/null && log "chvt 1 OK" || log "chvt 1 failed"
sleep 0.3

# Limpiar pantalla
printf '\033[2J\033[H' > /dev/tty1 2>/dev/null

# Ejecutar selector directamente en tty1
log "Starting selector.py on tty1..."
/usr/bin/python3 /opt/boot-selector/selector.py < /dev/tty1 > /dev/tty1 2>> "$LOGFILE"
RESULT=$?
log "selector.py exited with code $RESULT"

# Marcar como ejecutado
touch "$FLAG"
log "Flag created"

log "run.sh finished"
exit 0
RUNEOF
chmod +x /opt/boot-selector/run.sh

# ── selector.py: menú con gamepad real ──
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

# ── Logging ──

logging.basicConfig(
    filename="/var/log/boot-selector.log",
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s: %(message)s",
)
log = logging.getLogger("boot-selector")
log.info("selector.py started (PID=%d)", os.getpid())

# ── Config ──

TIMEOUT = 15
DEFAULT_SEL = 0
TEST_MODE = "--test" in sys.argv
APP_VERSION = "2026.02.04"
COMPANY_SITE = "nuevauno.com"
COMPANY_EMAIL = "hola@nuevauno.com"

# ── evdev ──

try:
    import evdev
    from evdev import ecodes
    HAS_EVDEV = True
    log.info("evdev OK")
except ImportError:
    HAS_EVDEV = False
    log.warning("evdev not available")

# ── Colores ──

class C:
    G = '\033[1;32m'
    Y = '\033[1;33m'
    CN = '\033[1;36m'
    W = '\033[1;37m'
    N = '\033[0m'

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# ── Gamepad ──

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
                log.debug("Button %d", event.code)
                if event.code in {304, 315, 288, 289, 297}:
                    last = 'select'
        return last
    except (OSError, IOError) as e:
        log.error("Gamepad error: %s", e)
    return None

# ── Teclado ──

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

# ── Menú ──

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

# ── Main ──

def main():
    log.info("Test mode: %s", TEST_MODE)

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
            try: gp_dev.ungrab()
            except Exception: pass
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

# ── Paso 4: Inyectar en el display manager ────────────────────────

echo -e "${GREEN}[4/5]${NC} Inyectando en ${BOLD}${DM_SERVICE}${NC}..."

DM_DROPIN_DIR="/etc/systemd/system/${DM_SERVICE}.d"
mkdir -p "$DM_DROPIN_DIR"

# ExecStartPre con - = si falla, el DM arranca igual (failsafe)
cat > "${DM_DROPIN_DIR}/boot-selector.conf" << 'DROPEOF'
[Service]
ExecStartPre=-/opt/boot-selector/run.sh
DROPEOF

systemctl daemon-reload

if systemctl cat "${DM_SERVICE}" 2>/dev/null | grep -q "boot-selector"; then
    echo -e "  ${GREEN}✓${NC} Verificado: ${DM_SERVICE} ejecutará el selector antes de arrancar"
else
    echo -e "  ${YELLOW}!${NC} No se pudo verificar el drop-in"
fi

# ── Paso 5: GRUB + scripts auxiliares ─────────────────────────────

echo -e "${GREEN}[5/5]${NC} Configurando GRUB y scripts..."

cp /etc/default/grub /etc/default/grub.bak-selector 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

cat > /opt/boot-selector/test.sh << 'TESTEOF'
#!/bin/bash
echo "=== Boot Selector - Test ==="
echo ""
sudo rm -f /run/boot-selector-done
sudo python3 /opt/boot-selector/selector.py --test
echo ""
echo "=== Log ==="
tail -20 /var/log/boot-selector.log 2>/dev/null || echo "(sin log)"
TESTEOF
chmod +x /opt/boot-selector/test.sh

cat > /opt/boot-selector/uninstall.sh << 'UNINSTEOF'
#!/bin/bash
echo "Desinstalando Boot Selector..."
DM_SERVICE=$(cat /opt/boot-selector/.dm-service 2>/dev/null)
if [ -n "$DM_SERVICE" ]; then
    rm -f "/etc/systemd/system/${DM_SERVICE}.d/boot-selector.conf"
    rmdir "/etc/systemd/system/${DM_SERVICE}.d" 2>/dev/null || true
    echo "  Drop-in de ${DM_SERVICE} eliminado"
fi
systemctl disable boot-selector.service 2>/dev/null || true
rm -f /etc/systemd/system/boot-selector.service
rm -rf /etc/systemd/system/display-manager.service.d/wait-boot-selector.conf
rm -f /run/boot-selector-done
cp /etc/default/grub.bak-selector /etc/default/grub 2>/dev/null
update-grub 2>/dev/null || true
systemctl daemon-reload
rm -rf /opt/boot-selector
echo "Desinstalado"
UNINSTEOF
chmod +x /opt/boot-selector/uninstall.sh

# ── Resultado ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║        INSTALACION COMPLETA            ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Cómo funciona:${NC}"
echo "    Desactiva Plymouth, muestra menu en tty1, ANTES de ${DM_SERVICE}"
echo ""
echo -e "  ${CYAN}PROBAR:${NC}  sudo /opt/boot-selector/test.sh"
echo -e "  ${CYAN}LOG:${NC}     cat /var/log/boot-selector.log"
echo -e "  ${YELLOW}REBOOT:${NC}  sudo reboot"
echo -e "  ${RED}REMOVE:${NC}  sudo /opt/boot-selector/uninstall.sh"
echo ""
echo -e "  ${YELLOW}IMPORTANTE: después de reiniciar, revisa el log:${NC}"
echo "    cat /var/log/boot-selector.log"
echo ""
