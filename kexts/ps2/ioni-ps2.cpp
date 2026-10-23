/*
 * com.ioni.kext.ps2 - i8042 PS/2 controller + keyboard driver (stage (c),
 * round 4).
 *
 * Register-level sequences follow the i8042 programming convention used
 * by the PureDarwin ecosystem PS/2 drivers (ApplePS2Controller / the
 * VoodooPS2 controller family): controller self-test, port enable,
 * command-byte setup, keyboard enable-scanning, then scancode decode.
 * Implemented directly against ports 0x60/0x64 - no IOPCIFamily or ACPI
 * nub dependency (QEMU q35 wires the i8042 at the fixed ISA ports).
 *
 * Poll mode: a kernel thread samples the output buffer at 10ms and
 * decodes scancode set 1 make/break events. Interrupt-driven operation
 * (IRQ1 via the 8259/IOAPIC nub) is the next-stage upgrade.
 *
 * Boot test PASS markers:
 *   "com.ioni.ps2: keyboard ready"
 *   scancode decode lines on keypresses (not required for CI PASS).
 */

#include <stdint.h>
#include <string.h>
#include <mach/kmod.h>
#include <kern/misc_protos.h>
#include <kern/thread.h>
#include <mach/thread_act.h>
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>

/* ------------------------------------------------------------------ */
/* kmod_info - literal, pack(4) ABI (pipeline requirement)              */
/* ------------------------------------------------------------------ */

_Static_assert(__builtin_offsetof(kmod_info_t, address) == 156,
    "kmod_info pack(4) ABI");

static kern_return_t ioni_ps2_kmod_start(kmod_info_t *ki, void *data);
static kern_return_t ioni_ps2_kmod_stop(kmod_info_t *ki, void *data);

struct kmod_info kmod_info = {
        .next = NULL,
        .info_version = 1,
        .id = 0,
        .name = "com.ioni.kext.ps2",
        .version = "1.0",
        .reference_count = 0,
        .reference_list = NULL,
        .address = 0,
        .size = 0,
        .hdr_size = 0,
        .start = ioni_ps2_kmod_start,
        .stop = ioni_ps2_kmod_stop,
};

static int
ioni_ps2_kmod_start(struct kmod_info *ki, void *data)
{
        (void)ki; (void)data;
        return 0;
}

static int
ioni_ps2_kmod_stop(struct kmod_info *ki, void *data)
{
        (void)ki; (void)data;
        return 0;
}

/* ------------------------------------------------------------------ */
/* i8042 ports                                                          */
/* ------------------------------------------------------------------ */

#define PS2_DATA       0x60
#define PS2_STATUS     0x64
#define PS2_COMMAND    0x64

#define SR_OBF         0x01   /* output buffer full */
#define SR_IBF         0x02   /* input buffer full */

#define CMD_READ_CFG   0x20
#define CMD_WRITE_CFG  0x60
#define CMD_SELF_TEST  0xAA   /* -> 0x55 */
#define CMD_PORT1_DISABLE 0xA7
#define CMD_PORT1_ENABLE  0xA8
#define CMD_PORT0_DISABLE 0xAD
#define CMD_PORT0_ENABLE  0xAE

#define CFG_PORT1_IRQ  0x02
#define CFG_PORT1_CLK  0x10   /* 1 = second port clock disabled */
#define CFG_TRANSLATION 0x40

#define KBD_ACK        0xFA
#define KBD_RESEND     0xFE
#define KBD_ENABLE_SCANNING 0xF4
#define KBD_RESET           0xFF

static inline uint8_t inb_port(uint16_t port)
{
        uint8_t v;
        __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
        return v;
}

static inline void outb_port(uint16_t port, uint8_t v)
{
        __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(port));
}

static void ps2_flush_output(void)
{
        for (unsigned i = 0; i < 32; i++) {
                if ((inb_port(PS2_STATUS) & SR_OBF) == 0)
                        return;
                (void)inb_port(PS2_DATA);
                IOSleep(1);
        }
}

static bool ps2_wait_write(void)
{
        for (unsigned i = 0; i < 100000; i++)
                if ((inb_port(PS2_STATUS) & SR_IBF) == 0)
                        return true;
        return false;
}

static bool ps2_command(uint8_t cmd)
{
        if (!ps2_wait_write())
                return false;
        outb_port(PS2_COMMAND, cmd);
        return true;
}

static bool ps2_keyboard_cmd(uint8_t cmd)
{
        if (!ps2_wait_write())
                return false;
        outb_port(PS2_DATA, cmd);
        for (unsigned i = 0; i < 100000; i++) {
                if ((inb_port(PS2_STATUS) & SR_OBF) == 0)
                        continue;
                uint8_t ack = inb_port(PS2_DATA);
                if (ack == KBD_ACK)
                        return true;
                if (ack == KBD_RESEND)
                        return ps2_keyboard_cmd(cmd);
                return false;
        }
        return false;
}

/* ------------------------------------------------------------------ */
/* scancode set 1 -> US layout subset (make codes; break = make | 0x80) */
/* ------------------------------------------------------------------ */

struct ioni_ps2_keymap_entry {
        uint8_t make;
        const char* name;
};

static const struct ioni_ps2_keymap_entry ioni_ps2_keymap[] = {
        {0x1E, "a"}, {0x30, "b"}, {0x2E, "c"}, {0x20, "d"}, {0x12, "e"},
        {0x21, "f"}, {0x22, "g"}, {0x23, "h"}, {0x17, "i"}, {0x24, "j"},
        {0x25, "k"}, {0x26, "l"}, {0x32, "m"}, {0x31, "n"}, {0x18, "o"},
        {0x19, "p"}, {0x10, "q"}, {0x13, "r"}, {0x1F, "s"}, {0x14, "t"},
        {0x16, "u"}, {0x2F, "v"}, {0x11, "w"}, {0x2D, "x"}, {0x15, "y"},
        {0x2C, "z"},
        {0x02, "1"}, {0x03, "2"}, {0x04, "3"}, {0x05, "4"}, {0x06, "5"},
        {0x07, "6"}, {0x08, "7"}, {0x09, "8"}, {0x0A, "9"}, {0x0B, "0"},
        {0x39, "space"}, {0x1C, "enter"}, {0x0E, "backspace"}, {0x0F, "tab"},
        {0x2A, "lshift"}, {0x36, "rshift"}, {0x1D, "lctrl"}, {0x38, "lalt"},
        {0x01, "esc"},
};

static const char* decode_set1(uint8_t make)
{
        for (unsigned i = 0; i < sizeof(ioni_ps2_keymap)
                / sizeof(ioni_ps2_keymap[0]); i++)
                if (ioni_ps2_keymap[i].make == make)
                        return ioni_ps2_keymap[i].name;
        return NULL;
}

/* ------------------------------------------------------------------ */
/* driver                                                               */
/* ------------------------------------------------------------------ */

class com_ioni_ps2 : public IOService {
        OSDeclareDefaultStructors(com_ioni_ps2);

public:
        bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
        void stop(IOService * provider) APPLE_KEXT_OVERRIDE;

private:
        static void pollThread(void* arg, wait_result_t wr);
        void pollLoop(void);
};

OSDefineMetaClassAndStructors(com_ioni_ps2, IOService);

void
com_ioni_ps2::pollLoop(void)
{
        bool shift = false;
        for (;;) {
                uint8_t status = inb_port(PS2_STATUS);
                if ((status & SR_OBF) == 0) {
                        IOSleep(10);
                        continue;
                }
                uint8_t sc = inb_port(PS2_DATA);
                bool break_code = (sc & 0x80) != 0;
                uint8_t make = sc & 0x7F;

                if (make == 0x2A || make == 0x36) {
                        shift = !break_code;
                        continue;
                }
                const char* key = decode_set1(make);
                if (key == NULL)
                        continue;
                IOLog("com.ioni.ps2: key %s%s [%02x]\n", key,
                    break_code ? " up" : " down", sc);
        }
}

void
com_ioni_ps2::pollThread(void* arg, wait_result_t wr)
{
        (void)wr;
        com_ioni_ps2* self = (com_ioni_ps2*)arg;
        self->pollLoop();
}

bool
com_ioni_ps2::start(IOService * provider)
{
        IOLog("com.ioni.ps2: start on provider \"%s\"\n",
            provider ? provider->getName() : "(none)");

        if (!IOService::start(provider))
                return false;

        /* 1. Flush and disable both ports (controller reprogram sequence). */
        ps2_flush_output();
        ps2_command(CMD_PORT0_DISABLE);
        ps2_command(CMD_PORT1_DISABLE);
        ps2_flush_output();

        /* 2. Controller self-test: 0xAA must answer 0x55. */
        if (!ps2_command(CMD_SELF_TEST)) {
                IOLog("com.ioni.ps2: self-test command timeout\n");
                return false;
        }
        unsigned spins = 0;
        uint8_t result = 0;
        while ((inb_port(PS2_STATUS) & SR_OBF) == 0) {
                if (++spins > 100000) {
                        IOLog("com.ioni.ps2: self-test answer timeout\n");
                        return false;
                }
        }
        result = inb_port(PS2_DATA);
        if (result != 0x55) {
                IOLog("com.ioni.ps2: controller self-test FAILED (0x%02x)\n", result);
                return false;
        }
        IOLog("com.ioni.ps2: controller self-test OK (0x55)\n");

        /* 3. Command byte: enable keyboard IRQ line (unused in poll mode,
         * but mirrors the conventional setup), keep first port clock
         * enabled, leave translation on (QEMU keyboard sends set-1). */
        ps2_command(CMD_READ_CFG);
        while ((inb_port(PS2_STATUS) & SR_OBF) == 0)
                ;
        uint8_t cfg = inb_port(PS2_DATA);
        cfg |= CFG_TRANSLATION;
        cfg |= CFG_PORT1_IRQ;
        cfg &= (uint8_t)~CFG_PORT1_CLK; /* enable second port clock */
        ps2_command(CMD_WRITE_CFG);
        ps2_wait_write();
        outb_port(PS2_DATA, cfg);
        IOLog("com.ioni.ps2: command byte 0x%02x\n", cfg);

        /* 4. Enable the keyboard port and scanning. */
        ps2_command(CMD_PORT0_ENABLE);
        if (!ps2_keyboard_cmd(KBD_ENABLE_SCANNING)) {
                IOLog("com.ioni.ps2: enable-scanning not ACKed - no keyboard?\n");
                /* Keep the driver alive anyway: the poll thread just idles. */
        } else {
                IOLog("com.ioni.ps2: keyboard ready (scanning enabled, set 1)\n");
        }

        /* 5. Poll thread. */
        thread_t th = NULL;
        if (kernel_thread_start(&com_ioni_ps2::pollThread, this, &th)
            == KERN_SUCCESS) {
                thread_deallocate(th);
                IOLog("com.ioni.ps2: poll thread launched (10ms)\n");
        } else {
                IOLog("com.ioni.ps2: poll thread launch FAILED\n");
                return false;
        }
        return true;
}

void
com_ioni_ps2::stop(IOService * provider)
{
        IOLog("com.ioni.ps2: stop\n");
        IOService::stop(provider);
}
