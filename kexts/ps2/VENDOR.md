# PS/2 driver provenance (round 4)

`../ioni-ps2.cpp` is an original IONI implementation of the standard i8042
programming sequences, following the register-level conventions of the
PureDarwin ecosystem PS/2 drivers (Apple's `ApplePS2Controller` - APSL,
shipped in the PureDarwin Xmas images - and the Acidanthera
`VoodooPS2Controller` family that maintains the same controller bring-up
order). No upstream code was copied; the sequence structure (flush ->
disable ports -> 0xAA self-test expecting 0x55 -> command byte 0x60 ->
port enable 0xAE -> keyboard 0xF4 enable-scanning with 0xFA ACK) is the
i8042 datasheet/`IBM PC AT` convention those drivers implement.

Scancode decoding: scancode set 1 (QEMU default keyboard with AT
translation on), make/break table for the US layout subset.

Roadmap: IRQ1-driven operation (8259/IOAPIC interrupt nub), mouse
(auxiliary port, set-3 mode for wheel mice), then personality-matched
child drivers (keyboard/pointer separation) per the upstream family
architecture.
