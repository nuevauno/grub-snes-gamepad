.PHONY: all build test clean help

all: build

build:
	@./scripts/build.sh

test:
	@./scripts/test-qemu.sh

detect:
	@./scripts/detect-controller.sh

capture:
	@echo "Usage: make capture DEVICE=0810:e501"
	@if [ -n "$(DEVICE)" ]; then ./scripts/capture-hid.sh $(DEVICE); fi

clean:
	rm -f test.iso
	rm -rf grub/

help:
	@echo "GRUB SNES Gamepad - Available targets:"
	@echo ""
	@echo "  make build    - Build the GRUB module and test ISO"
	@echo "  make test     - Test in QEMU with USB passthrough"
	@echo "  make detect   - Detect connected USB controllers"
	@echo "  make capture DEVICE=0810:e501 - Capture HID reports"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make help     - Show this help"
