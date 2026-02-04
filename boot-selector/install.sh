#!/bin/bash
#
# Gamepad Boot Selector v5.0
#
# Selector de SO que corre DESPUÉS de GRUB, dentro de Linux.
# Se inyecta como ExecStartPre del display manager, así es
# IMPOSIBLE que el escritorio arranque sin pasar por el selector.
#
# Usa Python + evdev para leer gamepad USB de verdad.
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
echo -e "${CYAN}${BOLD}║   Gamepad Boot Selector v5.0           ║${NC}"
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

systemctl disable boot-selector.service 2>/dev/null || true
rm -f /etc/systemd/system/boot-selector.service
rm -rf /etc/systemd/system/display-manager.service.d/wait-boot-selector.conf
rm -f /run/boot-selector-done

# ── Paso 1: Dependencias ──────────────────────────────────────────

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 python3-evdev joystick 2>/dev/null

if ! python3 -c "import evdev" 2>/dev/null; then
    echo -e "${YELLOW}python3-evdev no disponible via apt, intentando pip...${NC}"
    apt-get install -y -qq python3-pip 2>/dev/null || true
    pip3 install evdev 2>/dev/null || pip install evdev 2>/dev/null || true
fi

if ! python3 -c "import evdev" 2>/dev/null; then
    echo -e "${RED}Error: No se pudo instalar python3-evdev${NC}"
    echo "  Intenta manualmente: sudo apt install python3-evdev"
    exit 1
fi

echo -e "  ${GREEN}✓${NC} python3-evdev instalado"

# ── Paso 2: Detectar display manager ─────────────────────────────

echo -e "${GREEN}[2/5]${NC} Detectando display manager..."

DM_SERVICE=""

# Método 1: Leer el symlink de display-manager.service
if [ -L /etc/systemd/system/display-manager.service ]; then
    DM_SERVICE=$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")
fi

# Método 2: Buscar en los servicios habilitados
if [ -z "$DM_SERVICE" ]; then
    for dm in gdm3 gdm lightdm sddm lxdm; do
        if systemctl is-enabled "${dm}.service" 2>/dev/null | grep -q "enabled"; then
            DM_SERVICE="${dm}.service"
            break
        fi
    done
fi

if [ -z "$DM_SERVICE" ]; then
    echo -e "${RED}Error: No se detectó display manager (gdm3, lightdm, sddm)${NC}"
    echo "  Verifica con: systemctl status display-manager.service"
    exit 1
fi

echo -e "  ${GREEN}✓${NC} Display manager: ${BOLD}${DM_SERVICE}${NC}"

# ── Paso 3: Crear scripts ────────────────────────────────────────

echo -e "${GREEN}[3/5]${NC} Creando selector..."

mkdir -p /opt/boot-selector

# Guardar qué DM usamos para el uninstaller
echo "$DM_SERVICE" > /opt/boot-selector/.dm-service

# ── Script wrapper (bash) - maneja TTY y flag ──
cat > /opt/boot-selector/run.sh << 'RUNEOF'
#!/bin/bash
#
# Wrapper que corre ANTES del display manager.
# Maneja el cambio de TTY y el flag de "ya corrí".
#

LOGFILE="/var/log/boot-selector.log"
FLAG="/run/boot-selector-done"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') RUN: $*" >> "$LOGFILE"; }

log "=== run.sh started (PID=$$) ==="

# Si ya corrió este boot, salir inmediatamente
if [ -f "$FLAG" ]; then
    log "Flag exists, skipping"
    exit 0
fi

# Esperar que USB se estabilice
log "Waiting 2s for USB..."
sleep 2

# Cambiar a tty1 para que el usuario vea el menú
log "Switching to tty1"
chvt 1 2>/dev/null || true
sleep 0.5

# Ejecutar el selector Python con tty1 como entrada/salida
log "Starting selector.py"
/usr/bin/python3 /opt/boot-selector/selector.py < /dev/tty1 > /dev/tty1 2>> "$LOGFILE"
RESULT=$?
log "selector.py exited with code $RESULT"

# Crear flag para no correr de nuevo este boot
touch "$FLAG"
log "Flag created"

# Volver a tty donde estará el display manager
# GDM usa tty1 o tty2, LightDM usa tty7
for vt in 1 2 7; do
    chvt "$vt" 2>/dev/null && log "Switched to tty$vt" && break
done

log "=== run.sh finished ==="
exit 0
RUNEOF
chmod +x /opt/boot-selector/run.sh

# ── Script selector Python ──
cat > /opt/boot-selector/selector.py << 'PYEOF'
#!/usr/bin/env python3
"""
Boot Selector v5.0 - Con soporte REAL de gamepad USB.
Usa evdev para leer eventos del gamepad directamente.
"""

import os
import sys
import time
import select
import logging
import subprocess

# ── Logging ──

logging.basicConfig(
    filename="/var/log/boot-selector.log",
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s: %(message)s",
)
log = logging.getLogger("boot-selector")
log.info("Boot Selector v5.0 - Python started (PID=%d)", os.getpid())

# ── Config ──

TIMEOUT = 15
DEFAULT_SEL = 0
TEST_MODE = "--test" in sys.argv

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
        last_action = None
        for event in dev.read():
            if event.type == ecodes.EV_ABS:
                if event.code == ecodes.ABS_Y:
                    info = axis_info.get(ecodes.ABS_Y, {'min': 0, 'max': 255})
                    center = (info['min'] + info['max']) // 2
                    thresh = (info['max'] - info['min']) // 4
                    if event.value < center - thresh:
                        last_action = 'up'
                    elif event.value > center + thresh:
                        last_action = 'down'
                elif event.code == ecodes.ABS_HAT0Y:
                    if event.value < 0:
                        last_action = 'up'
                    elif event.value > 0:
                        last_action = 'down'
            elif event.type == ecodes.EV_KEY and event.value == 1:
                btn = event.code
                log.debug("Button %d pressed", btn)
                if btn in {304, 315, 288, 289, 297}:
                    last_action = 'select'
        return last_action
    except (OSError, IOError) as e:
        log.error("Gamepad read error: %s", e)
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
    opt_u = f"       {C.G}>> Ubuntu Linux <<{C.N}" if selected == 0 else "         Ubuntu Linux"
    opt_w = f"       {C.G}>> Windows <<{C.N}" if selected == 1 else "         Windows"
    gp = f"  Gamepad: {C.G}>> {gp_name}{C.N}" if gp_name else f"  Gamepad: {C.Y}No detectado (teclado){C.N}"
    print(f"""
{C.CN}========================================={C.N}
{C.CN}    SELECCIONAR SISTEMA OPERATIVO        {C.N}
{C.CN}========================================={C.N}

{opt_u}
{opt_w}

{C.Y}-----------------------------------------{C.N}

  {C.W}D-Pad / Flechas{C.N}  =  Navegar
  {C.W}A / Start / Enter{C.N}  =  Seleccionar

  {C.Y}Auto-boot en: {remaining} segundos{C.N}

{gp}
""")

# ── Main ──

def main():
    log.info("Test mode: %s", TEST_MODE)

    gamepad_dev = None
    axis_info = {}
    gp_name = None
    grabbed = False

    result = find_gamepad()
    if result:
        gamepad_dev, axis_info = result
        gp_name = gamepad_dev.name
        try:
            gamepad_dev.grab()
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
    prev_state = (-1, -1)

    try:
        while remaining > 0:
            cur = (selected, int(remaining))
            if cur != prev_state:
                draw_menu(selected, int(remaining), gp_name)
                prev_state = cur

            action = read_gamepad(gamepad_dev, axis_info, 0.05)
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
        if grabbed and gamepad_dev:
            try: gamepad_dev.ungrab()
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
        log.info("Booting Ubuntu (normal)")

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

# Crear drop-in que ejecuta nuestro script ANTES del display manager
# ExecStartPre con - significa: si falla, el DM arranca igual (failsafe)
DM_DROPIN_DIR="/etc/systemd/system/${DM_SERVICE}.d"
mkdir -p "$DM_DROPIN_DIR"

cat > "${DM_DROPIN_DIR}/boot-selector.conf" << 'DROPEOF'
[Service]
ExecStartPre=-/opt/boot-selector/run.sh
DROPEOF

echo -e "  ${GREEN}✓${NC} Drop-in creado en ${DM_DROPIN_DIR}/"

# Recargar systemd
systemctl daemon-reload

# Verificar que el drop-in se cargó
if systemctl cat "${DM_SERVICE}" 2>/dev/null | grep -q "boot-selector"; then
    echo -e "  ${GREEN}✓${NC} Verificado: el display manager ejecutará el selector"
else
    echo -e "  ${YELLOW}!${NC} No se pudo verificar (puede funcionar igual)"
fi

# ── Paso 5: GRUB + scripts auxiliares ─────────────────────────────

echo -e "${GREEN}[5/5]${NC} Configurando GRUB y scripts..."

cp /etc/default/grub /etc/default/grub.bak-selector 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

# Test script
cat > /opt/boot-selector/test.sh << 'TESTEOF'
#!/bin/bash
echo "=== Boot Selector v5.0 - Test ==="
echo ""
sudo rm -f /run/boot-selector-done
sudo python3 /opt/boot-selector/selector.py --test
echo ""
echo "=== Log (últimas 20 líneas) ==="
tail -20 /var/log/boot-selector.log 2>/dev/null || echo "(sin log)"
TESTEOF
chmod +x /opt/boot-selector/test.sh

# Uninstall script - lee qué DM se usó
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
echo "Desinstalado correctamente"
UNINSTEOF
chmod +x /opt/boot-selector/uninstall.sh

# ── Resultado ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      INSTALACION COMPLETA (v5.0)       ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Cómo funciona:${NC}"
echo "    El selector se ejecuta ANTES de ${DM_SERVICE}"
echo "    Es imposible que el escritorio arranque sin pasar por él"
echo ""
echo -e "  ${CYAN}PROBAR AHORA:${NC}"
echo "    sudo /opt/boot-selector/test.sh"
echo ""
echo -e "  ${CYAN}VER LOG:${NC}"
echo "    cat /var/log/boot-selector.log"
echo ""
echo -e "  ${YELLOW}REINICIAR:${NC}"
echo "    sudo reboot"
echo ""
echo -e "  ${RED}DESINSTALAR:${NC}"
echo "    sudo /opt/boot-selector/uninstall.sh"
echo ""
