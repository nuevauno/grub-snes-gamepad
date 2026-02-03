#!/bin/bash
#
# Gamepad Boot Selector v5.0
#
# Selector de SO que corre DESPUÉS de GRUB, dentro de Linux.
# Usa Python + evdev para leer gamepad USB de verdad.
#
# Las versiones v2-v4 usaban bash 'read' que solo lee teclado.
# Esta versión usa evdev que SÍ lee el gamepad.
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

# ── Paso 1: Dependencias ──────────────────────────────────────────

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 python3-evdev joystick 2>/dev/null

# Verificar que evdev funciona
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

# ── Paso 2: Crear selector Python ─────────────────────────────────

echo -e "${GREEN}[2/5]${NC} Creando selector con soporte de gamepad..."

mkdir -p /opt/boot-selector

cat > /opt/boot-selector/selector.py << 'PYEOF'
#!/usr/bin/env python3
"""
Boot Selector v5.0 - Con soporte REAL de gamepad USB.

Usa evdev para leer eventos del gamepad directamente desde
/dev/input/event*, no desde stdin como las versiones anteriores.
"""

import os
import sys
import time
import select
import logging
import subprocess

# ── Logging (a archivo, NO interfiere con la terminal) ──

logging.basicConfig(
    filename="/var/log/boot-selector.log",
    level=logging.DEBUG,
    format="%(asctime)s %(levelname)s: %(message)s",
)
log = logging.getLogger("boot-selector")
log.info("=" * 50)
log.info("Boot Selector v5.0 started")
try:
    tty_name = os.ttyname(sys.stdout.fileno())
except OSError:
    tty_name = "unknown"
log.info("PID=%d  User=%s  TTY=%s", os.getpid(), os.environ.get("USER", "?"),
         tty_name)

# ── Configuración ──

TIMEOUT = 15          # Segundos para auto-boot
DEFAULT_SEL = 0       # 0=Ubuntu, 1=Windows
FLAG_FILE = "/run/boot-selector-done"
USB_SETTLE_SECS = 2   # Esperar que USB se estabilice
TEST_MODE = "--test" in sys.argv

# ── Importar evdev ──

try:
    import evdev
    from evdev import ecodes
    HAS_EVDEV = True
    log.info("evdev importado correctamente")
except ImportError:
    HAS_EVDEV = False
    log.warning("evdev NO disponible - solo teclado")

# ── Colores ANSI ──

class C:
    G = '\033[1;32m'
    Y = '\033[1;33m'
    CN = '\033[1;36m'
    W = '\033[1;37m'
    R = '\033[0;31m'
    B = '\033[1m'
    N = '\033[0m'

# ── Gamepad ──

def find_gamepad():
    """Busca un gamepad/joystick conectado via evdev."""
    if not HAS_EVDEV:
        return None

    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            caps = dev.capabilities(verbose=False)

            # Buscar dispositivos con ejes absolutos (gamepads/joysticks)
            if ecodes.EV_ABS not in caps:
                continue

            abs_codes = [code for code, _info in caps[ecodes.EV_ABS]]

            # Debe tener ejes X/Y o HAT0 (D-pad digital)
            has_xy = (ecodes.ABS_X in abs_codes and ecodes.ABS_Y in abs_codes)
            has_hat = (ecodes.ABS_HAT0X in abs_codes and ecodes.ABS_HAT0Y in abs_codes)

            if has_xy or has_hat:
                log.info("Gamepad encontrado: %s (%s)", dev.name, dev.path)
                log.info("  Caps ABS: %s", abs_codes)

                # Obtener info de los ejes para calcular centro
                axis_info = {}
                for code, info in caps[ecodes.EV_ABS]:
                    if code in (ecodes.ABS_X, ecodes.ABS_Y,
                                ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
                        axis_info[code] = {
                            'min': info.min,
                            'max': info.max,
                            'flat': info.flat,
                        }
                        log.info("  Eje %d: min=%d max=%d flat=%d",
                                 code, info.min, info.max, info.flat)

                return dev, axis_info

        except (PermissionError, OSError) as e:
            log.debug("No se pudo abrir %s: %s", path, e)
            continue

    log.warning("No se encontró gamepad")
    return None


def read_gamepad(dev, axis_info, timeout=0.05):
    """Lee eventos del gamepad. Retorna 'up', 'down', 'select', o None."""
    if not dev:
        return None

    try:
        r, _, _ = select.select([dev.fd], [], [], timeout)
        if not r:
            return None

        # Drenar TODOS los eventos y quedarnos con la última acción
        # para evitar input lag por eventos acumulados
        last_action = None
        for event in dev.read():
            if event.type == ecodes.EV_ABS:
                # ── Ejes analógicos (ABS_X, ABS_Y) ──
                # SNES controllers: 0=min, 127=center, 255=max
                if event.code == ecodes.ABS_Y:
                    info = axis_info.get(ecodes.ABS_Y, {})
                    mn = info.get('min', 0)
                    mx = info.get('max', 255)
                    center = (mn + mx) // 2
                    threshold = (mx - mn) // 4

                    if event.value < center - threshold:
                        log.debug("Gamepad: ABS_Y UP (val=%d)", event.value)
                        last_action = 'up'
                    elif event.value > center + threshold:
                        log.debug("Gamepad: ABS_Y DOWN (val=%d)", event.value)
                        last_action = 'down'

                # ── Ejes digitales HAT (D-pad) ──
                # Valores: -1, 0, +1
                elif event.code == ecodes.ABS_HAT0Y:
                    if event.value < 0:
                        log.debug("Gamepad: HAT0Y UP (val=%d)", event.value)
                        last_action = 'up'
                    elif event.value > 0:
                        log.debug("Gamepad: HAT0Y DOWN (val=%d)", event.value)
                        last_action = 'down'

            elif event.type == ecodes.EV_KEY and event.value == 1:
                # Botón presionado
                btn = event.code
                log.debug("Gamepad: botón %d presionado", btn)

                # Solo A y Start confirman la selección
                # BTN_SOUTH(304) = A, BTN_START(315) = Start
                # Genéricos: 289(trigger2), 288(trigger) para A/Start
                select_buttons = {
                    304,             # BTN_SOUTH (A)
                    315,             # BTN_START
                    288,             # BTN_TRIGGER (genérico A)
                    289,             # BTN_THUMB (genérico Start)
                    297,             # BTN_BASE4 (genérico Start)
                }
                if btn in select_buttons:
                    last_action = 'select'

        return last_action

    except (OSError, IOError) as e:
        log.error("Error leyendo gamepad: %s", e)

    return None


# ── Teclado ──

def setup_keyboard():
    """Configura stdin para lectura no-bloqueante de teclas."""
    import termios
    import tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    return old


def restore_keyboard(old_settings):
    """Restaura la configuración original del terminal."""
    import termios
    try:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_settings)
    except Exception:
        pass


def read_keyboard(timeout=0.05):
    """Lee teclas del teclado. Retorna 'up', 'down', 'select', o None."""
    try:
        r, _, _ = select.select([sys.stdin], [], [], timeout)
        if not r:
            return None

        key = sys.stdin.read(1)
        if key == '\x1b':  # Escape sequence (flechas)
            r2, _, _ = select.select([sys.stdin], [], [], 0.05)
            if r2:
                seq = sys.stdin.read(2)
                if seq == '[A':
                    return 'up'
                elif seq == '[B':
                    return 'down'
        elif key in ('\r', '\n'):
            return 'select'

    except Exception:
        pass
    return None


# ── Menú ──

def get_windows_entry():
    """Busca la entrada de Windows en grub.cfg."""
    try:
        with open("/boot/grub/grub.cfg", "r") as f:
            for line in f:
                if "menuentry" in line and "indows" in line:
                    # Extraer nombre entre comillas simples
                    start = line.find("'")
                    if start != -1:
                        end = line.find("'", start + 1)
                        if end != -1:
                            return line[start + 1 : end]
    except FileNotFoundError:
        pass
    return None


def draw_menu(selected, remaining, gamepad_name):
    """Dibuja el menú en la terminal."""
    sys.stdout.write('\033[2J\033[H')  # clear + home
    sys.stdout.flush()

    lines = [
        "",
        f"{C.CN}╔══════════════════════════════════════════╗{C.N}",
        f"{C.CN}║     SELECCIONAR SISTEMA OPERATIVO        ║{C.N}",
        f"{C.CN}╚══════════════════════════════════════════╝{C.N}",
        "",
    ]

    if selected == 0:
        lines.append(f"       {C.G}▶ Ubuntu Linux ◀{C.N}")
        lines.append(f"         Windows")
    else:
        lines.append(f"         Ubuntu Linux")
        lines.append(f"       {C.G}▶ Windows ◀{C.N}")

    lines += [
        "",
        f"{C.Y}──────────────────────────────────────────{C.N}",
        "",
        f"  {C.W}D-Pad / Flechas{C.N}  =  Navegar",
        f"  {C.W}A / Start / Enter{C.N}  =  Seleccionar",
        "",
        f"  {C.Y}Auto-boot en: {remaining} segundos{C.N}",
        "",
    ]

    if gamepad_name:
        lines.append(f"  Gamepad: {C.G}✓ {gamepad_name}{C.N}")
    else:
        lines.append(f"  Gamepad: {C.Y}No detectado (usando teclado){C.N}")

    lines.append("")
    print('\n'.join(lines))


# ── Main ──

def main():
    # Verificar flag
    if os.path.exists(FLAG_FILE) and not TEST_MODE:
        log.info("Flag file exists, exiting")
        sys.exit(0)

    log.info("Test mode: %s", TEST_MODE)

    # Esperar que USB se estabilice
    log.info("Esperando %d seg para USB...", USB_SETTLE_SECS)
    time.sleep(USB_SETTLE_SECS)

    # Buscar gamepad
    gamepad_dev = None
    axis_info = {}
    gamepad_name = None
    grabbed = False

    result = find_gamepad()
    if result:
        gamepad_dev, axis_info = result
        gamepad_name = gamepad_dev.name
        try:
            gamepad_dev.grab()
            grabbed = True
            log.info("Gamepad grabbed exclusivamente")
        except (OSError, IOError) as e:
            log.warning("No se pudo hacer grab del gamepad: %s", e)

    # Configurar teclado
    old_term = None
    try:
        old_term = setup_keyboard()
    except Exception as e:
        log.warning("No se pudo configurar teclado: %s", e)

    selected = DEFAULT_SEL
    confirmed = False
    interrupted = False
    remaining = TIMEOUT
    last_time = time.time()
    prev_drawn = (-1, -1)  # (selected, remaining_int) - solo redibujar si cambian

    try:
        while remaining > 0:
            # Solo redibujar si cambió la selección o el countdown
            cur_state = (selected, int(remaining))
            if cur_state != prev_drawn:
                draw_menu(selected, int(remaining), gamepad_name)
                prev_drawn = cur_state

            # Leer gamepad
            action = read_gamepad(gamepad_dev, axis_info, 0.05)

            # Leer teclado si no hubo input del gamepad
            if not action:
                action = read_keyboard(0.05)

            if action == 'up':
                selected = 0
                remaining = TIMEOUT
                log.info("Selección: Ubuntu")
            elif action == 'down':
                selected = 1
                remaining = TIMEOUT
                log.info("Selección: Windows")
            elif action == 'select':
                log.info("Confirmado: %s", "Ubuntu" if selected == 0 else "Windows")
                confirmed = True
                break

            # Actualizar countdown
            now = time.time()
            remaining -= (now - last_time)
            last_time = now

        # Timeout = confirmación implícita del default
        if remaining <= 0:
            confirmed = True
            log.info("Timeout - auto-boot: %s", "Ubuntu" if selected == 0 else "Windows")

    except KeyboardInterrupt:
        interrupted = True
        log.info("Interrumpido por usuario")
    finally:
        # Liberar gamepad
        if grabbed and gamepad_dev:
            try:
                gamepad_dev.ungrab()
            except Exception:
                pass

        # Restaurar teclado
        if old_term:
            restore_keyboard(old_term)

    # Si fue interrumpido, no ejecutar acción ni crear flag
    if interrupted:
        log.info("Abortado - no se ejecuta ninguna acción")
        return

    # Crear flag
    try:
        with open(FLAG_FILE, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    # Limpiar pantalla
    sys.stdout.write('\033[2J\033[H')
    sys.stdout.flush()

    # Ejecutar selección
    if selected == 1:
        win_entry = get_windows_entry()
        if win_entry:
            print(f"{C.CN}Reiniciando a Windows...{C.N}")
            log.info("Ejecutando grub-reboot '%s'", win_entry)
            subprocess.run(["grub-reboot", win_entry], check=False)
            time.sleep(1)
            if not TEST_MODE:
                subprocess.run(["reboot"], check=False)
        else:
            print(f"{C.Y}Windows no encontrado en GRUB, iniciando Ubuntu...{C.N}")
            log.warning("No se encontró entrada de Windows en grub.cfg")
            time.sleep(2)
    else:
        print(f"{C.G}Iniciando Ubuntu...{C.N}")
        log.info("Continuando boot normal (Ubuntu)")

    time.sleep(1)
    log.info("Selector finalizado")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.exception("Error fatal: %s", e)
        sys.exit(1)
PYEOF

chmod +x /opt/boot-selector/selector.py
echo -e "  ${GREEN}✓${NC} Selector Python con soporte de gamepad creado"

# ── Paso 3: Servicio systemd ──────────────────────────────────────

echo -e "${GREEN}[3/5]${NC} Configurando servicio systemd..."

# Desactivar versiones anteriores si existen
systemctl disable boot-selector.service 2>/dev/null || true
systemctl stop boot-selector.service 2>/dev/null || true
rm -f /run/boot-selector-done

cat > /etc/systemd/system/boot-selector.service << 'SVCEOF'
[Unit]
Description=Gamepad Boot OS Selector
After=systemd-udevd.service systemd-tmpfiles-setup.service
Before=display-manager.service gdm.service lightdm.service sddm.service
Wants=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /opt/boot-selector/selector.py
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TimeoutStartSec=30
ConditionPathExists=!/run/boot-selector-done

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable boot-selector.service
echo -e "  ${GREEN}✓${NC} Servicio habilitado"

# ── Paso 4: GRUB ──────────────────────────────────────────────────

echo -e "${GREEN}[4/5]${NC} Configurando GRUB..."
cp /etc/default/grub /etc/default/grub.bak-selector 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} GRUB timeout = 2s"

# ── Paso 5: Scripts auxiliares ────────────────────────────────────

echo -e "${GREEN}[5/5]${NC} Creando scripts auxiliares..."

# Test script
cat > /opt/boot-selector/test.sh << 'TESTEOF'
#!/bin/bash
echo "=== Boot Selector v5.0 - Test ==="
echo "Ejecutando en modo test (no reiniciará)..."
echo ""
sudo rm -f /run/boot-selector-done
sudo python3 /opt/boot-selector/selector.py --test
echo ""
echo "=== Log ==="
tail -20 /var/log/boot-selector.log 2>/dev/null || echo "(sin log aún)"
TESTEOF
chmod +x /opt/boot-selector/test.sh

# Uninstall script
cat > /opt/boot-selector/uninstall.sh << 'UNINSTEOF'
#!/bin/bash
echo "Desinstalando Boot Selector..."
systemctl disable boot-selector.service 2>/dev/null
rm -f /etc/systemd/system/boot-selector.service
rm -f /run/boot-selector-done
rm -rf /opt/boot-selector
cp /etc/default/grub.bak-selector /etc/default/grub 2>/dev/null
update-grub 2>/dev/null || true
systemctl daemon-reload
echo "Desinstalado correctamente"
UNINSTEOF
chmod +x /opt/boot-selector/uninstall.sh

# ── Resultado ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      INSTALACIÓN COMPLETA (v5.0)       ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}PROBAR AHORA:${NC}"
echo "    sudo /opt/boot-selector/test.sh"
echo ""
echo -e "  ${CYAN}VER LOG:${NC}"
echo "    cat /var/log/boot-selector.log"
echo ""
echo -e "  ${CYAN}VERIFICAR SERVICIO:${NC}"
echo "    systemctl status boot-selector.service"
echo ""
echo -e "  ${YELLOW}REINICIAR (para probar en boot real):${NC}"
echo "    sudo reboot"
echo ""
echo -e "  ${RED}DESINSTALAR:${NC}"
echo "    sudo /opt/boot-selector/uninstall.sh"
echo ""
echo -e "  ${BOLD}Qué cambió vs versiones anteriores:${NC}"
echo "    - Usa Python+evdev para leer el gamepad DE VERDAD"
echo "    - v2-v4 usaban bash 'read' que solo lee teclado"
echo "    - D-pad funciona con ejes analógicos Y digitales"
echo "    - Log real en /var/log/boot-selector.log"
echo ""
