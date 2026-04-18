# ROM Free Space

Unused ROM space from `LAST_ROM_CODE` up to the reset/IRQ vector page ($FFFC).
This excludes the showcase program (assembled into RAM at $0200).

| Source | LAST_ROM_CODE | Free bytes before vectors |
| --- | --- | ---: |
| uBASIC.asm | $FFAD | 79 (0x4F) |
| uBASIC6502.asm | $FFAF | 77 (0x4D) |
| 4kBASIC.asm | $FF18 | 228 (0xE4) |
