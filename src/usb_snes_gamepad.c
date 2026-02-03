/*
 *  GRUB  --  GRand Unified Bootloader
 *  Copyright (C) 2024  Free Software Foundation, Inc.
 *
 *  GRUB is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  Based on tsoding/grub-gamepad - adapted for USB SNES controllers
 *  https://github.com/tsoding/grub-gamepad
 */

#include <grub/dl.h>
#include <grub/misc.h>
#include <grub/term.h>
#include <grub/usb.h>
#include <grub/command.h>

GRUB_MOD_LICENSE ("GPLv3+");

/* =============================================================================
 * SUPPORTED USB SNES CONTROLLERS
 * Add your controller's Vendor ID and Product ID here
 * Find them with: lsusb | grep -i game
 * =============================================================================
 */

struct snes_controller_info {
    grub_uint16_t vendor_id;
    grub_uint16_t product_id;
    const char *name;
};

static struct snes_controller_info supported_controllers[] = {
    { 0x0810, 0xe501, "Generic Chinese SNES" },
    { 0x0079, 0x0011, "DragonRise Generic" },
    { 0x0583, 0x2060, "iBuffalo SNES" },
    { 0x2dc8, 0x9018, "8BitDo SN30" },
    { 0x12bd, 0xd015, "Generic 2-pack SNES" },
    { 0x1a34, 0x0802, "USB Gamepad" },
    /* Add more controllers here */
    { 0, 0, NULL }  /* End marker */
};

/* =============================================================================
 * HID REPORT STRUCTURE FOR SNES CONTROLLERS
 * Most generic SNES USB controllers use this 8-byte format:
 *
 * Byte 0: X-axis (0x00=Left, 0x7F=Center, 0xFF=Right)
 * Byte 1: Y-axis (0x00=Up, 0x7F=Center, 0xFF=Down)
 * Byte 2-3: Unused (usually 0x7F)
 * Byte 4: Button byte
 *         Bit 0: X (top button)
 *         Bit 1: A (right button)
 *         Bit 2: B (bottom button)
 *         Bit 3: Y (left button)
 *         Bit 4: L shoulder
 *         Bit 5: R shoulder
 *         Bit 6: Select
 *         Bit 7: Start
 * Byte 5-7: Usually 0x00
 * =============================================================================
 */

struct snes_hid_report {
    grub_uint8_t x_axis;      /* 0x00=Left, 0x7F=Center, 0xFF=Right */
    grub_uint8_t y_axis;      /* 0x00=Up, 0x7F=Center, 0xFF=Down */
    grub_uint8_t unused1;
    grub_uint8_t unused2;
    grub_uint8_t buttons;     /* Button bits */
    grub_uint8_t padding[3];
};

#define SNES_REPORT_SIZE 8

/* Button bit masks */
#define BTN_X      (1 << 0)
#define BTN_A      (1 << 1)
#define BTN_B      (1 << 2)
#define BTN_Y      (1 << 3)
#define BTN_L      (1 << 4)
#define BTN_R      (1 << 5)
#define BTN_SELECT (1 << 6)
#define BTN_START  (1 << 7)

/* Axis thresholds */
#define AXIS_CENTER    0x7F
#define AXIS_THRESHOLD 0x40

/* =============================================================================
 * KEY MAPPINGS
 * Default mappings - can be changed with grub commands
 * =============================================================================
 */

static int key_up = GRUB_TERM_KEY_UP;
static int key_down = GRUB_TERM_KEY_DOWN;
static int key_left = GRUB_TERM_KEY_LEFT;
static int key_right = GRUB_TERM_KEY_RIGHT;
static int key_enter = '\r';          /* A button -> Enter */
static int key_escape = GRUB_TERM_KEY_ESC;  /* B button -> Escape */

/* =============================================================================
 * DEVICE STATE
 * =============================================================================
 */

struct snes_gamepad {
    grub_usb_device_t usbdev;
    int endpoint;
    int endpoint_maxlen;
    struct snes_hid_report last_report;
    const char *name;
};

static struct snes_gamepad *attached_gamepad = NULL;

/* Key queue for buffering generated key events */
#define KEY_QUEUE_SIZE 16
static int key_queue[KEY_QUEUE_SIZE];
static int key_queue_head = 0;
static int key_queue_tail = 0;

/* =============================================================================
 * KEY QUEUE FUNCTIONS
 * =============================================================================
 */

static void
key_queue_push(int key)
{
    int next = (key_queue_head + 1) % KEY_QUEUE_SIZE;
    if (next != key_queue_tail) {
        key_queue[key_queue_head] = key;
        key_queue_head = next;
    }
}

static int
key_queue_pop(void)
{
    if (key_queue_head == key_queue_tail)
        return GRUB_TERM_NO_KEY;
    int key = key_queue[key_queue_tail];
    key_queue_tail = (key_queue_tail + 1) % KEY_QUEUE_SIZE;
    return key;
}

static int
key_queue_empty(void)
{
    return key_queue_head == key_queue_tail;
}

/* =============================================================================
 * HID REPORT PROCESSING
 * =============================================================================
 */

static void
process_report(struct snes_hid_report *report, struct snes_hid_report *last)
{
    /* Process D-pad / analog stick */

    /* Y-axis: Up/Down */
    if (report->y_axis < (AXIS_CENTER - AXIS_THRESHOLD)) {
        if (last->y_axis >= (AXIS_CENTER - AXIS_THRESHOLD))
            key_queue_push(key_up);
    }
    else if (report->y_axis > (AXIS_CENTER + AXIS_THRESHOLD)) {
        if (last->y_axis <= (AXIS_CENTER + AXIS_THRESHOLD))
            key_queue_push(key_down);
    }

    /* X-axis: Left/Right */
    if (report->x_axis < (AXIS_CENTER - AXIS_THRESHOLD)) {
        if (last->x_axis >= (AXIS_CENTER - AXIS_THRESHOLD))
            key_queue_push(key_left);
    }
    else if (report->x_axis > (AXIS_CENTER + AXIS_THRESHOLD)) {
        if (last->x_axis <= (AXIS_CENTER + AXIS_THRESHOLD))
            key_queue_push(key_right);
    }

    /* Process buttons (on press, not release) */
    grub_uint8_t pressed = report->buttons & ~last->buttons;

    if (pressed & BTN_A)
        key_queue_push(key_enter);

    if (pressed & BTN_B)
        key_queue_push(key_escape);

    if (pressed & BTN_START)
        key_queue_push(key_enter);

    if (pressed & BTN_SELECT)
        key_queue_push('e');  /* Edit menu entry */

    if (pressed & BTN_Y)
        key_queue_push('c');  /* Command line */

    if (pressed & BTN_X)
        key_queue_push(GRUB_TERM_KEY_ESC);

    /* L/R for page up/down in long menus */
    if (pressed & BTN_L)
        key_queue_push(GRUB_TERM_KEY_PPAGE);

    if (pressed & BTN_R)
        key_queue_push(GRUB_TERM_KEY_NPAGE);
}

/* =============================================================================
 * USB DEVICE HANDLING
 * =============================================================================
 */

static int
is_supported_controller(grub_usb_device_t usbdev, const char **name)
{
    struct snes_controller_info *info;

    for (info = supported_controllers; info->vendor_id != 0; info++) {
        if (usbdev->descdev.vendorid == info->vendor_id &&
            usbdev->descdev.prodid == info->product_id) {
            if (name)
                *name = info->name;
            return 1;
        }
    }
    return 0;
}

static int
grub_usb_snes_attach(grub_usb_device_t usbdev, int configno, int interfno)
{
    const char *name = NULL;

    /* Check if this is a supported controller */
    if (!is_supported_controller(usbdev, &name))
        return 0;

    /* Already have a controller attached */
    if (attached_gamepad)
        return 0;

    grub_dprintf("snes_gamepad", "Found controller: %s (VID=%04x PID=%04x)\n",
                 name, usbdev->descdev.vendorid, usbdev->descdev.prodid);

    /* Find interrupt IN endpoint */
    struct grub_usb_desc_if *interf;
    int endpoint = -1;
    int endpoint_maxlen = 0;

    interf = usbdev->config[configno].interf[interfno].descif;

    for (int i = 0; i < interf->endpointcnt; i++) {
        struct grub_usb_desc_endp *ep;
        ep = &usbdev->config[configno].interf[interfno].descendp[i];

        /* Look for interrupt IN endpoint */
        if ((ep->endp_addr & 0x80) && /* IN endpoint */
            (ep->attrib & 0x03) == GRUB_USB_EP_INTERRUPT) {
            endpoint = ep->endp_addr;
            endpoint_maxlen = ep->maxpacket;
            break;
        }
    }

    if (endpoint < 0) {
        grub_dprintf("snes_gamepad", "No interrupt endpoint found\n");
        return 0;
    }

    /* Allocate and initialize gamepad structure */
    attached_gamepad = grub_malloc(sizeof(*attached_gamepad));
    if (!attached_gamepad)
        return 0;

    attached_gamepad->usbdev = usbdev;
    attached_gamepad->endpoint = endpoint;
    attached_gamepad->endpoint_maxlen = endpoint_maxlen;
    attached_gamepad->name = name;
    grub_memset(&attached_gamepad->last_report, AXIS_CENTER,
                sizeof(attached_gamepad->last_report));

    grub_printf("SNES controller attached: %s\n", name);

    return 1;
}

static void
grub_usb_snes_detach(grub_usb_device_t usbdev,
                     int configno __attribute__((unused)),
                     int interfno __attribute__((unused)))
{
    if (attached_gamepad && attached_gamepad->usbdev == usbdev) {
        grub_printf("SNES controller detached: %s\n", attached_gamepad->name);
        grub_free(attached_gamepad);
        attached_gamepad = NULL;
    }
}

static struct grub_usb_attach_desc attach_hook = {
    .class = GRUB_USB_CLASS_HID,
    .hook = grub_usb_snes_attach,
    .detach_hook = grub_usb_snes_detach
};

/* =============================================================================
 * TERMINAL INPUT INTERFACE
 * =============================================================================
 */

static int
grub_snes_getkey(struct grub_term_input *term __attribute__((unused)))
{
    /* Return buffered key if available */
    if (!key_queue_empty())
        return key_queue_pop();

    if (!attached_gamepad)
        return GRUB_TERM_NO_KEY;

    /* Poll the controller */
    grub_uint8_t report_data[SNES_REPORT_SIZE];
    grub_size_t actual;
    grub_usb_err_t err;

    err = grub_usb_bulk_read_timeout(attached_gamepad->usbdev,
                                     attached_gamepad->endpoint,
                                     sizeof(report_data),
                                     (char *)report_data,
                                     10,  /* 10ms timeout */
                                     &actual);

    if (err || actual < sizeof(struct snes_hid_report))
        return GRUB_TERM_NO_KEY;

    /* Process the report */
    struct snes_hid_report *report = (struct snes_hid_report *)report_data;
    process_report(report, &attached_gamepad->last_report);
    grub_memcpy(&attached_gamepad->last_report, report, sizeof(*report));

    /* Return first queued key */
    return key_queue_pop();
}

static int
grub_snes_checkkey(struct grub_term_input *term __attribute__((unused)))
{
    if (!key_queue_empty())
        return 1;

    /* Try to get a key, which will populate the queue */
    int key = grub_snes_getkey(NULL);
    if (key != GRUB_TERM_NO_KEY) {
        /* Put it back in the queue */
        key_queue_push(key);
        return 1;
    }

    return 0;
}

static struct grub_term_input grub_snes_term_input = {
    .name = "usb_snes_gamepad",
    .getkey = grub_snes_getkey,
    .checkkey = grub_snes_checkkey
};

/* =============================================================================
 * GRUB COMMANDS FOR CONFIGURATION
 * =============================================================================
 */

static grub_err_t
grub_cmd_snes_status(grub_command_t cmd __attribute__((unused)),
                     int argc __attribute__((unused)),
                     char **args __attribute__((unused)))
{
    if (attached_gamepad) {
        grub_printf("SNES controller connected: %s\n", attached_gamepad->name);
        grub_printf("  Vendor ID:  0x%04x\n",
                    attached_gamepad->usbdev->descdev.vendorid);
        grub_printf("  Product ID: 0x%04x\n",
                    attached_gamepad->usbdev->descdev.prodid);
    } else {
        grub_printf("No SNES controller connected\n");
        grub_printf("\nSupported controllers:\n");
        for (struct snes_controller_info *info = supported_controllers;
             info->vendor_id != 0; info++) {
            grub_printf("  %s (VID=%04x PID=%04x)\n",
                       info->name, info->vendor_id, info->product_id);
        }
    }
    return GRUB_ERR_NONE;
}

static grub_command_t cmd_status;

/* =============================================================================
 * MODULE INIT/FINI
 * =============================================================================
 */

GRUB_MOD_INIT(usb_snes_gamepad)
{
    grub_usb_register_attach_hook_class(&attach_hook);
    grub_term_register_input("usb_snes_gamepad", &grub_snes_term_input);
    cmd_status = grub_register_command("snes_status", grub_cmd_snes_status,
                                       NULL, "Show SNES controller status");
}

GRUB_MOD_FINI(usb_snes_gamepad)
{
    grub_usb_unregister_attach_hook_class(&attach_hook);
    grub_term_unregister_input(&grub_snes_term_input);
    grub_unregister_command(cmd_status);

    if (attached_gamepad) {
        grub_free(attached_gamepad);
        attached_gamepad = NULL;
    }
}
