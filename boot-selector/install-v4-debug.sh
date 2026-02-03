#!/bin/bash
#
# GRUB Gamepad Boot Selector v4.0 - DEBUG VERSION
#
# Esta versión registra TODO en /var/log/boot-selector.log
# para diagnosticar por qué no funciona.
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
echo -e "${CYAN}${BOLD}║   Gamepad Boot Selector v4.0 DEBUG     ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Ejecutar como root (sudo)${NC}"
    exit 1
fi

echo -e "${GREEN}[1/5]${NC} Instalando dependencias..."
apt-get update -qq
apt-get install -y -qq python3 evtest joystick dialog 2>/dev/null || true

echo -e "${GREEN}[2/5]${NC} Creando selector con DEBUG..."

mkdir -p /opt/boot-selector

# Script del selector - VERSION DEBUG
cat > /opt/boot-selector/menu.sh << 'MENUSCRIPT'
#!/bin/bash

# ============ DEBUG LOG ============
LOGFILE="/var/log/boot-selector.log"
exec 2>> "$LOGFILE"
echo "========================================" >> "$LOGFILE"
echo "Boot Selector started at: $(date)" >> "$LOGFILE"
echo "PID: $$" >> "$LOGFILE"
echo "User: $(whoami)" >> "$LOGFILE"
echo "TTY: $(tty 2>/dev/null || echo 'none')" >> "$LOGFILE"
echo "TERM: $TERM" >> "$LOGFILE"
echo "Arguments: $@" >> "$LOGFILE"

# Flag para no correr dos veces
FLAG_FILE="/run/boot-selector-done"
if [ -f "$FLAG_FILE" ]; then
    echo "FLAG FILE EXISTS - exiting" >> "$LOGFILE"
    exit 0
fi

# Modo test si se pasa --test
TEST_MODE=0
if [ "$1" = "--test" ]; then
    TEST_MODE=1
    echo "TEST MODE ENABLED" >> "$LOGFILE"
fi

# Configuración
TIMEOUT=15
DEFAULT=0

echo "Waiting for USB (3 seconds)..." >> "$LOGFILE"
sleep 3

# Detectar si estamos en TTY o terminal gráfica
CURRENT_TTY=$(tty 2>/dev/null || echo "")
echo "Current TTY: $CURRENT_TTY" >> "$LOGFILE"

# Solo redirigir a TTY1 si NO estamos en modo test y NO estamos ya en un terminal
if [ "$TEST_MODE" -eq 0 ]; then
    if [ -e /dev/tty1 ]; then
        echo "Redirecting to /dev/tty1" >> "$LOGFILE"
        exec < /dev/tty1 > /dev/tty1 2>&1
    else
        echo "ERROR: /dev/tty1 does not exist!" >> "$LOGFILE"
        exit 1
    fi
fi

echo "After redirect, starting menu..." >> "$LOGFILE"

# Colores
G='\033[1;32m'
Y='\033[1;33m'
C='\033[1;36m'
W='\033[1;37m'
N='\033[0m'

selected=$DEFAULT

draw() {
    clear
    echo ""
    echo -e "${C}╔══════════════════════════════════════════╗${N}"
    echo -e "${C}║     SELECCIONAR SISTEMA OPERATIVO        ║${N}"
    echo -e "${C}╚══════════════════════════════════════════╝${N}"
    echo ""

    if [ $selected -eq 0 ]; then
        echo -e "       ${G}▶ Ubuntu Linux ◀${N}"
        echo -e "         Windows"
    else
        echo -e "         Ubuntu Linux"
        echo -e "       ${G}▶ Windows ◀${N}"
    fi

    echo ""
    echo -e "${Y}──────────────────────────────────────────${N}"
    echo ""
    echo -e "  ${W}Flechas ↑↓${N} = Navegar"
    echo -e "  ${W}Enter${N}      = Seleccionar"
    echo ""
    echo -e "  ${Y}Auto-boot en: $1 segundos${N}"
    echo ""

    if ls /dev/input/js* 1>/dev/null 2>&1; then
        echo -e "  Gamepad: ${G}✓ Detectado${N}"
    else
        echo -e "  Gamepad: ${Y}Usando teclado${N}"
    fi
}

get_windows() {
    grep -m1 -oP "menuentry '[^']*[Ww]indows[^']*" /boot/grub/grub.cfg 2>/dev/null | sed "s/menuentry '//" | head -1
}

# Loop principal
remaining=$TIMEOUT
while [ $remaining -gt 0 ]; do
    draw $remaining

    if read -rsn1 -t1 key; then
        case "$key" in
            $'\x1b')
                read -rsn2 -t0.1 seq
                case "$seq" in
                    '[A') selected=0 ;;
                    '[B') selected=1 ;;
                esac
                remaining=$TIMEOUT
                ;;
            '')
                break
                ;;
        esac
    else
        remaining=$((remaining - 1))
    fi
done

touch "$FLAG_FILE"
clear

if [ $selected -eq 1 ]; then
    win=$(get_windows)
    if [ -n "$win" ]; then
        echo -e "${C}Reiniciando a Windows...${N}"
        grub-reboot "$win" 2>/dev/null || grub-reboot "Windows Boot Manager" 2>/dev/null
        sleep 1
        [ "$TEST_MODE" -eq 0 ] && reboot
        exit 0
    else
        echo -e "${Y}Windows no encontrado, iniciando Ubuntu...${N}"
        sleep 2
    fi
fi

echo -e "${G}Iniciando Ubuntu...${N}"
sleep 1
MENUSCRIPT

chmod +x /opt/boot-selector/menu.sh

# Script de prueba simple
cat > /opt/boot-selector/test.sh << 'TESTSCRIPT'
#!/bin/bash
echo "=== Boot Selector Test ==="
echo "Running menu in TEST mode..."
sudo rm -f /run/boot-selector-done
sudo /opt/boot-selector/menu.sh --test
TESTSCRIPT
chmod +x /opt/boot-selector/test.sh

echo -e "${GREEN}[3/5]${NC} Configurando servicio systemd..."

cat > /etc/systemd/system/boot-selector.service << 'SVCFILE'
[Unit]
Description=Boot OS Selector (DEBUG)
After=systemd-user-sessions.service
Before=display-manager.service gdm.service lightdm.service sddm.service
ConditionPathExists=!/run/boot-selector-done

[Service]
Type=oneshot
ExecStart=/opt/boot-selector/menu.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload
systemctl enable boot-selector.service

echo -e "${GREEN}[4/5]${NC} Configurando GRUB..."
cp /etc/default/grub /etc/default/grub.bak-selector 2>/dev/null || true
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

echo -e "${GREEN}[5/5]${NC} Creando desinstalador..."

cat > /opt/boot-selector/uninstall.sh << 'UNINST'
#!/bin/bash
systemctl disable boot-selector.service 2>/dev/null
rm -f /etc/systemd/system/boot-selector.service
rm -rf /opt/boot-selector
rm -f /run/boot-selector-done
cp /etc/default/grub.bak-selector /etc/default/grub 2>/dev/null
update-grub 2>/dev/null || true
systemctl daemon-reload
echo "Desinstalado correctamente"
UNINST
chmod +x /opt/boot-selector/uninstall.sh

echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}   ¡INSTALACIÓN COMPLETA! (DEBUG)       ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${YELLOW}PROBAR (desde tu terminal actual):${NC}"
echo "    sudo /opt/boot-selector/test.sh"
echo ""
echo -e "  ${YELLOW}VER LOG DE DEBUG:${NC}"
echo "    cat /var/log/boot-selector.log"
echo ""
echo -e "  ${YELLOW}VER LOG DESPUÉS DE REINICIAR:${NC}"
echo "    sudo journalctl -u boot-selector.service"
echo ""
echo -e "  ${CYAN}REINICIAR:${NC}"
echo "    sudo reboot"
echo ""
echo -e "  ${RED}DESINSTALAR:${NC}"
echo "    sudo /opt/boot-selector/uninstall.sh"
echo ""
