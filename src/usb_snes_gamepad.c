/*
 * GRUB USB SNES Gamepad Module
 * Based on tsoding/grub-gamepad, modified for generic SNES USB controllers
 *
 * Supports generic Chinese SNES USB controllers that send 8-byte HID reports:
 *   Byte 0: X-axis (0x00=Left, 0x7F=Center, 0xFF=Right)
 *   Byte 1: Y-axis (0x00=Up, 0x7F=Center, 0xFF=Down)
 *   Byte 4: Buttons (bit0=X, bit1=A, bit2=B, bit3=Y, bit4=L, bit5=R, bit6=Select, bit7=Start)
 */

#include <grub/dl.h>
#include <grub/term.h>
#include <grub/usb.h>
#include <grub/command.h>

GRUB_MOD_LICENSE ("GPLv3");

#define GAMEPADS_CAPACITY 8
#define KEY_QUEUE_CAPACITY 32
#define USB_REPORT_SIZE 8

/* Supported SNES controller VID/PIDs */
struct snes_device {
    grub_uint16_t vid;
    grub_uint16_t pid;
    const char *name;
};

static struct snes_device supported_devices[] = {
    {0x0810, 0xe501, "Generic Chinese SNES"},
    {0x0079, 0x0011, "DragonRise Generic"},
    {0x0583, 0x2060, "iBuffalo SNES"},
    {0x2dc8, 0x9018, "8BitDo SN30"},
    {0x12bd, 0xd015, "Generic 2-pack SNES"},
    {0x1a34, 0x0802, "USB Gamepad"},
    {0x0810, 0x0001, "Generic USB Gamepad"},
    {0x0079, 0x0006, "DragonRise Gamepad"},
    {0x0000, 0x0000, NULL}  /* End marker */
};

/* SNES button bits in byte 4 */
#define SNES_BTN_X      (1 << 0)
#define SNES_BTN_A      (1 << 1)
#define SNES_BTN_B      (1 << 2)
#define SNES_BTN_Y      (1 << 3)
#define SNES_BTN_L      (1 << 4)
#define SNES_BTN_R      (1 << 5)
#define SNES_BTN_SELECT (1 << 6)
#define SNES_BTN_START  (1 << 7)

/* D-pad thresholds */
#define DPAD_CENTER 0x7F
#define DPAD_THRESHOLD 0x40

/* Key mappings - default to GRUB navigation */
static int key_up = GRUB_TERM_KEY_UP;
static int key_down = GRUB_TERM_KEY_DOWN;
static int key_left = GRUB_TERM_KEY_LEFT;
static int key_right = GRUB_TERM_KEY_RIGHT;
static int key_a = '\r';      /* Enter */
static int key_b = GRUB_TERM_ESC;
static int key_start = '\r';  /* Enter */
static int key_select = 'e';  /* Edit */
static int key_l = GRUB_TERM_KEY_PPAGE;  /* Page up */
static int key_r = GRUB_TERM_KEY_NPAGE;  /* Page down */

struct grub_usb_snes_data
{
    grub_usb_device_t usbdev;
    int configno;
    int interfno;
    struct grub_usb_desc_endp *endp;
    grub_usb_transfer_t transfer;
    grub_uint8_t prev_report[USB_REPORT_SIZE];
    grub_uint8_t report[USB_REPORT_SIZE];
    int key_queue[KEY_QUEUE_CAPACITY];
    int key_queue_begin;
    int key_queue_size;
};

static struct grub_term_input gamepads[GAMEPADS_CAPACITY];

/* Baseline for SNES (centered, no buttons) */
static grub_uint8_t snes_baseline[USB_REPORT_SIZE] = {
    0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00, 0x00, 0x00
};

static inline void
key_queue_push(struct grub_usb_snes_data *data, int key)
{
    if (key == GRUB_TERM_NO_KEY) return;

    data->key_queue[(data->key_queue_begin + data->key_queue_size) % KEY_QUEUE_CAPACITY] = key;
    if (data->key_queue_size < KEY_QUEUE_CAPACITY) {
        data->key_queue_size++;
    } else {
        data->key_queue_begin = (data->key_queue_begin + 1) % KEY_QUEUE_CAPACITY;
    }
}

static inline int
key_queue_pop(struct grub_usb_snes_data *data)
{
    if (data->key_queue_size <= 0)
        return GRUB_TERM_NO_KEY;

    int key = data->key_queue[data->key_queue_begin];
    data->key_queue_begin = (data->key_queue_begin + 1) % KEY_QUEUE_CAPACITY;
    data->key_queue_size--;
    return key;
}

static int
is_supported_device(grub_uint16_t vid, grub_uint16_t pid)
{
    for (int i = 0; supported_devices[i].name != NULL; i++) {
        if (supported_devices[i].vid == vid && supported_devices[i].pid == pid)
            return 1;
    }
    return 0;
}

static void
snes_generate_keys(struct grub_usb_snes_data *data)
{
    grub_uint8_t *prev = data->prev_report;
    grub_uint8_t *curr = data->report;

    /* D-pad from X/Y axes (bytes 0 and 1) */
    int prev_up = (prev[1] < DPAD_CENTER - DPAD_THRESHOLD);
    int prev_down = (prev[1] > DPAD_CENTER + DPAD_THRESHOLD);
    int prev_left = (prev[0] < DPAD_CENTER - DPAD_THRESHOLD);
    int prev_right = (prev[0] > DPAD_CENTER + DPAD_THRESHOLD);

    int curr_up = (curr[1] < DPAD_CENTER - DPAD_THRESHOLD);
    int curr_down = (curr[1] > DPAD_CENTER + DPAD_THRESHOLD);
    int curr_left = (curr[0] < DPAD_CENTER - DPAD_THRESHOLD);
    int curr_right = (curr[0] > DPAD_CENTER + DPAD_THRESHOLD);

    /* Generate key on press (not release) */
    if (!prev_up && curr_up) key_queue_push(data, key_up);
    if (!prev_down && curr_down) key_queue_push(data, key_down);
    if (!prev_left && curr_left) key_queue_push(data, key_left);
    if (!prev_right && curr_right) key_queue_push(data, key_right);

    /* Buttons from byte 4 */
    grub_uint8_t prev_btns = prev[4];
    grub_uint8_t curr_btns = curr[4];

#define BTN_PRESSED(prev, curr, mask) (!(prev & mask) && (curr & mask))

    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_A)) key_queue_push(data, key_a);
    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_B)) key_queue_push(data, key_b);
    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_START)) key_queue_push(data, key_start);
    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_SELECT)) key_queue_push(data, key_select);
    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_L)) key_queue_push(data, key_l);
    if (BTN_PRESSED(prev_btns, curr_btns, SNES_BTN_R)) key_queue_push(data, key_r);

#undef BTN_PRESSED
}

static int
usb_snes_getkey(struct grub_term_input *term)
{
    struct grub_usb_snes_data *termdata = term->data;
    grub_size_t actual;

    grub_usb_err_t err = grub_usb_check_transfer(termdata->transfer, &actual);

    if (err != GRUB_USB_ERR_WAIT) {
        snes_generate_keys(termdata);
        grub_memcpy(termdata->prev_report, termdata->report, USB_REPORT_SIZE);

        termdata->transfer = grub_usb_bulk_read_background(
            termdata->usbdev,
            termdata->endp,
            sizeof(termdata->report),
            (char *)&termdata->report);

        if (!termdata->transfer)
            grub_print_error();
    }

    return key_queue_pop(termdata);
}

static int
usb_snes_getkeystatus(struct grub_term_input *term __attribute__((unused)))
{
    return 0;
}

static void
grub_usb_snes_detach(grub_usb_device_t usbdev,
                     int config __attribute__((unused)),
                     int interface __attribute__((unused)))
{
    for (grub_size_t i = 0; i < ARRAY_SIZE(gamepads); ++i) {
        if (!gamepads[i].data)
            continue;

        struct grub_usb_snes_data *data = gamepads[i].data;

        if (data->usbdev != usbdev)
            continue;

        if (data->transfer)
            grub_usb_cancel_transfer(data->transfer);

        grub_term_unregister_input(&gamepads[i]);
        grub_free((char *)gamepads[i].name);
        gamepads[i].name = NULL;
        grub_free(gamepads[i].data);
        gamepads[i].data = NULL;
    }
}

static int
grub_usb_snes_attach(grub_usb_device_t usbdev, int configno, int interfno)
{
    /* Check if this is a supported SNES controller */
    if (!is_supported_device(usbdev->descdev.vendorid, usbdev->descdev.prodid)) {
        grub_dprintf("usb_snes",
                     "Ignoring device VID=%04x PID=%04x (not a known SNES controller)\n",
                     usbdev->descdev.vendorid, usbdev->descdev.prodid);
        return 0;
    }

    grub_dprintf("usb_snes", "SNES controller found! VID=%04x PID=%04x\n",
                 usbdev->descdev.vendorid, usbdev->descdev.prodid);

    /* Find free slot */
    unsigned curnum = 0;
    for (curnum = 0; curnum < ARRAY_SIZE(gamepads); ++curnum)
        if (gamepads[curnum].data == 0)
            break;

    if (curnum >= ARRAY_SIZE(gamepads)) {
        grub_dprintf("usb_snes", "Too many gamepads attached (max %d)\n", GAMEPADS_CAPACITY);
        return 0;
    }

    /* Find interrupt IN endpoint */
    struct grub_usb_desc_endp *endp = NULL;
    int j;
    for (j = 0; j < usbdev->config[configno].interf[interfno].descif->endpointcnt; j++) {
        endp = &usbdev->config[configno].interf[interfno].descendp[j];
        if ((endp->endp_addr & 128) && grub_usb_get_ep_type(endp) == GRUB_USB_EP_INTERRUPT)
            break;
    }

    if (j == usbdev->config[configno].interf[interfno].descif->endpointcnt) {
        grub_dprintf("usb_snes", "No interrupt IN endpoint found\n");
        return 0;
    }

    /* Allocate data structure */
    struct grub_usb_snes_data *data = grub_malloc(sizeof(struct grub_usb_snes_data));
    if (!data) {
        grub_print_error();
        return 0;
    }

    /* Setup terminal */
    gamepads[curnum].name = grub_xasprintf("snes_gamepad%d", curnum);
    gamepads[curnum].getkey = usb_snes_getkey;
    gamepads[curnum].getkeystatus = usb_snes_getkeystatus;
    gamepads[curnum].data = data;
    gamepads[curnum].next = 0;

    /* Setup device data */
    usbdev->config[configno].interf[interfno].detach_hook = grub_usb_snes_detach;
    data->usbdev = usbdev;
    data->configno = configno;
    data->interfno = interfno;
    data->endp = endp;
    data->key_queue_begin = 0;
    data->key_queue_size = 0;
    grub_memcpy(data->prev_report, snes_baseline, USB_REPORT_SIZE);

    /* Start reading */
    data->transfer = grub_usb_bulk_read_background(
        usbdev,
        data->endp,
        sizeof(data->report),
        (char *)&data->report);

    if (!data->transfer) {
        grub_print_error();
        return 0;
    }

    grub_term_register_input_active("snes_gamepad", &gamepads[curnum]);
    grub_printf("SNES gamepad %d connected!\n", curnum);

    return 0;
}

static struct grub_usb_attach_desc attach_hook = {
    .class = GRUB_USB_CLASS_HID,
    .hook = grub_usb_snes_attach
};

GRUB_MOD_INIT(usb_snes_gamepad)
{
    grub_dprintf("usb_snes", "SNES Gamepad module loaded\n");
    grub_usb_register_attach_hook_class(&attach_hook);
}

GRUB_MOD_FINI(usb_snes_gamepad)
{
    for (grub_size_t i = 0; i < ARRAY_SIZE(gamepads); ++i) {
        if (!gamepads[i].data)
            continue;

        struct grub_usb_snes_data *data = gamepads[i].data;

        if (data->transfer)
            grub_usb_cancel_transfer(data->transfer);

        grub_term_unregister_input(&gamepads[i]);
        grub_free((char *)gamepads[i].name);
        gamepads[i].name = NULL;
        grub_free(gamepads[i].data);
        gamepads[i].data = NULL;
    }

    grub_usb_unregister_attach_hook_class(&attach_hook);
    grub_dprintf("usb_snes", "SNES Gamepad module unloaded\n");
}
