# ROM Free Space

Unused ROM space from `LAST_ROM_CODE` up to the reset/IRQ vector page ($FFFC).
This excludes the showcase program (assembled into RAM at $0200).

| Source | LAST_ROM_CODE | Free bytes before vectors |
| --- | --- | ---: |
| uBASIC.asm | $FFA8 | 84 (0x54) |
| uBASIC6502.asm | $FFA9 | 83 (0x53) |
| 4kBASIC.asm | $FF13 | 233 (0xE9) |
