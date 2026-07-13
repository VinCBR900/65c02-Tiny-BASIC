# 6502 Tiny BASICs

### uBASIC6502 — fits in a 2716 EPROM (<2 KByte)

**<2048 bytes assembled. ROM at $F800–$FFFF**

A minimal but complete integer BASIC. No tokeniser — program lines are stored as raw ASCII and re-parsed on every execution. This costs RAM and speed but keeps the interpreter very small. Courtesy of [Sehugg and Mango 1](https://github.com/sehugg/mango_one), You can open this project in [8 Bit Workshop](http://8bitworkshop.com/v3.12.1/?redir.html?platform=verilog&githubURL=https%3A%2F%2Fgithub.com%2FVinCBR900%2Fmango_one&file=mango1.v) and try it Out! Type `LIST` to see the embedded BASIC program and `RUN` to execute it - Pressing `ESC` aborts running program. 

This interpreter has also been ported to the John Bell 80-153 single board computer.  A modified sim65c02 simulator (JB-sim65c02) is provided for this version.

**Statements:** 
  * `END` `GOSUB`/`RETURN`  `GOTO`  `IF`/`THEN`  `INPUT`  `LET`  `POKE`  `PRINT [TAB(n)] [;] CHR$(n)`  `REM`  `RUN`  
  * `LIST` `NEW` 

**Expressions:** 
  * `+` `-` `*` `/` `%`(mod) `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)`  variables `A`–`Z`
  * Functions: `ABS(val)`   `FREE`   `PEEK(addr)`  `RND`   `USR(addr)`  

**Numbers:** signed 16-bit integers, −32768 to 32767

**Notes**
- Uses **2 character matching** - with 3rd char match for `GOSUB`/`GOTO` and `RETURN`/`REM`.  Matches anything after e.g. PROCEED matches PRINT.  Therefore  spaces are important e.g. `PRINT TAB(5);"hello"` works, whereas `PRINTTAB(5);"HELLO"` does not.
- **`GOTO`/`GOSUB` accepts expressions** — `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work
- **`RND`** — 16-bit Galois LFSR pseudo-random number, returns 1–32767; seeded at startup; useful as `RND MOD 6 + 1` for a die roll
- **`:` Not Supported** - Multi-statement operator `:` is not supported and input buffer is 32 characters only.

**Errors** (printed as `?N [IN line]`):

| Code | Meaning |
|------|---------|
| ?0 SN | Syntax / bad expression |
| ?1 UL | Undefined line number |
| ?2 OV | Division or modulo by zero |
| ?3 OM | Out of memory |
| ?4 UK | Bad variable assignment |

### 4K BASIC — fits in a 2732 EPROM (<4 KByte)

**<4096 bytes assembled. ROM at $F000–$FFFF**

A significantly more capable integer BASIC. Keywords are tokenised on entry and numbers converted to 16-bit binary, so the interpreter does not re-parse ASCII on execution — several times faster than uBASIC and easier on RAM. 

**Statements:** 
  * `PRINT [TAB(n)] [;] CHR$(n)` `IF`/`THEN`/`ELSE` `GOTO` `GOSUB` `RETURN` `FOR`/`TO`/`STEP`/`NEXT` `LET` `INPUT` `REM` `END` `POKE` `DATA` `READ` `RESTORE` 
  * `RUN` `LIST` `NEW` `FREE` `HELP`
 
**Functions:** `ABS(n)` `SGN(n)` `ASC("c")` `PEEK(addr)` `USR(addr)` `RND` `SIN(deg)`  `COS(deg)`

**Expressions:** `AND` `OR` `XOR` `NOT` `MOD` `+` `-` `*` `/` `%`(mod) `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)` variables `A`–`Z`

**Numbers:** signed 16-bit integers, −32768 to 32767. Relational operators return −1 (true) or 0 (false). `AND`/`OR`/`XOR`/`NOT` are bitwise.

**Notes**
- **`GOTO`/`GOSUB` accepts expressions** — `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work
- **`MOD` keyword** — `10 MOD 3` is now an alternative to `10 % 3` (both give `1`)
- **`RND`** — 16-bit Galois LFSR pseudo-random number, returns 1–32767; seeded at startup; useful as `RND MOD 6 + 1` for a die roll
- **`:` multi-statement** Is Line based - don't have `FOR`/`NEXT`, `FOR`/`FOR`, `GOSUB`/`GOSUB` or `GOSUB`/`RETURN` on same line - its still a Tiny BASIC, after all.

**Errors** (printed as `XX ERR [IN line]`):

| Code | Meaning |
|------|---------|
| SN | Syntax / bad expression |
| UL | Undefined line number |
| OV | Division or modulo by zero |
| OM | Out of memory |
| NR | Nesting error (GOSUB/FOR overflow, or RETURN/NEXT without opener) |
| ST | Zero STEP in FOR loop |
| UK | Unknown statement |
| OD | Out of DATA (READ with no remaining values) |

---

## Files

| File | Description |
|------|-------------|
| `uBASIC6502.asm` | NMOS-6502 uBASIC  with 2-byte keyword-prefix matcher |
| `4kBASIC.asm` | 4K BASIC source (~3100 lines, heavily commented) |
| `asm65c02.c` | In tools folder, Two-pass 6502/65C02 assembler — builds standalone |
| `sim65c02.c` | In tools folder, 65C02/6502 simulator with Kowalski I/O — includes asm65c02.c directly |
| `JB-sim65c02.c` | In tools folder, 65C02/6502 simulator with John Bell 80-153 Bitbang emulation — includes asm65c02.c directly |

---

## Building and Running

### Kowalski Simulator

Both ROMs work in the [Kowalski 65C02 Simulator](https://github.com/Kelmar/kowalski). Set:
- CPU mode: Set **65C02** if using 4k versions
- Terminal emulation addresses: **E000–E006**
- Ensure `uBASIC6502.asm` has the `KOWaLSKI=1` defined at teh top of the file 

Load the assembled binary or paste the `.asm` source click Assemble (F7), Debug (F6) and either RUN (F5) or Animate (Ctrl-F5) if you want to watch it step through - don't forget to click and type into the yellow Terminal window. The INIT trampoline at the start of uBASIC ROM means Kowalski's nominal execute-from-first-byte behaviour works correctly, as does real hardware's reset-vector startup.

### Proprietary Simulator
Building and Running

`sim65c02.c` may be used for batch testing by piping file in from STDIN, or may be started with max-cycles set to 0 and will take inpuit form STDIN, with output going to STDOUT and errors to STDERR.  

**Build**
```
REM for Windows
Tcc -O2 -o sim65c02.exe sim65c02.c 
```

```bash
# for LInux
gcc -O2 -o sim65c02 sim65c02.c
```
**Run:**
```bash
./sim65c02 uBASIC6502.asm --input "PRINT 42"
./sim65c02 4kBASIC.asm --input "PRINT 42"
# to execute the showcase
./sim65c02 4kBASIC.asm --input "RUN" --maxcycles 800000000
# For interactive
./sim65c02 4kBASIC.asm --maxcycles 0
```
Example of batch testing
```bash
# Enter and run a small program non-interactively
./sim65c02 uBASIC.asm \
  --input "NEW" \
  --input "10 FOR I=1 TO 5" \
  --input "20 PRINT I" \
  --input "30 NEXT I" \
  --input "RUN" \
  --maxcycles 5000000
```

---

#### Note on Running from real ROM (no pre-loaded program)

The pre-loaded program relies on `INIT` setting `PE` to point past the program bytes. To start with an empty program instead, change two lines in `INIT`:
```asm
; In INIT, change:
        LDA #<SHOWCASE_END     →     JSR DO_NEW
        LDA #>SHOWCASE_END     →     Delete
```
This sets `PE = PROG = $0200` so the interpreter starts fresh. Both ASM files include this note as a comment near the label.

Program the `.bin` file to an EPROM so that the chip's address 0 maps to $F800 (uBASIC) or $F000 (4K BASIC). The reset vector at $FFFC/$FFFD within the image points to `INIT`, so the interpreter starts on power-up.

#### Terminal I/O

For real Hardware you will need to modify the I/O Addresses for Serial I/O, specified below.  Although 4kBASIC has plenty of ROM space available, uBASIC is a bit tight but probably enough for simple writes to ACIA or bitbang serial.  `FREE` is an obvious candidate to delete to make space if needed, ask Claude.

| Address | Kowalski Virtual Terminal Function  |
|---------|----------|
| $E001 | Putchar |
| $E004 | Getchar (Returns 0 if no char available) |

### Things to watch out for

- **ROM size.** All variants dotn have much free space. Always check after a change. Claude will help you find space savings if you're over budget.
- **Page constraints.** The uBASIC string table must stay entirely on page $F8 (all strings accessed via a shared hi-byte). Claude can get confused if the page boundary is exceeded - it will find it eventually but after a lot of thrashing, so tell it to watch out when adding new strings to uBASIC.
- **Zero-page register clobbers.** The In/Out/Clobbers comments on each function document which of T0/T1/T2/LP/IP/OP are live. Claude will respect these if you share the relevant headers.
- **Fall-through chains.** Several functions share a single RTS by falling through into the next function. These are clearly marked in the source. Inserting code between them without understanding the fall-through will break things — tell Claude to watch out for them.

---

## Technical Notes

#### Why no tokeniser in uBASIC?

A tokeniser saves RAM (shorter stored programs) and speeds execution (no re-parsing). But the tokeniser itself costs ROM. In a 2 KB budget every byte counts, and storing programs as raw ASCII with a simple parse-on-execute design kept the interpreter under 2048 bytes while still being genuinely useful. 4K BASIC has the ROM headroom to tokenise and is significantly faster as a result.

#### The `%` operator and `MOD` keyword

Both interpreters support `%` as integer modulo: `10 % 3` gives `1`. 4K BASIC v11 also accepts the word `MOD`: `10 MOD 3` gives the same result. The sign follows the dividend (C convention), so `-7 % 4` gives `-3`. Division and modulo by zero both raise error OV.

#### `RND` 

`RND` returns a pseudo-random integer in the range 1–32767. It uses a 16-bit Galois LFSR (linear feedback shift register) with taps at $B400, seeded to $ACE1 at startup. The seed is not resettable from BASIC — every run produces the same sequence, which is useful for reproducible tests. A common idiom for a six-sided die roll is:

```basic
10 PRINT RND MOD 6 + 1
```

#### USR(addr)

`USR(addr)` calls machine code at the given address. The routine should end with `RTS` and write any return value to T0 for the return value, allowing hardware-specific extensions without modifying the interpreter source.

#### The pre-loaded showcase program

All ROMs include a pre-loaded feature showcase program for Kowalski simulator. Type `RUN` to execute it, `NEW` to clear it, or `LIST` to read the source. The showcase is designed to exercise as much of each interpreter's instruction set as possible in a single self-contained program.

### Notes
  * Originally I started with a 65c02 2kbyte tiny BASIC, which after got working ported to NMOS 6502.  The 65c02 version had more features due to better code density, but eventually I Realized I should just refactor NMOS 6502 and get as many features in that, rather than working on two 2kbyte versions.  So the original 65c02 version `uBASIC.asm` is in the `Archive` folder.
  * Originally I had two different simulator versions - a batch version and an interactive.  Eventually I realized maintaining both was a pain, and one could do both jobs.  So the old _interactive_ versions are in the `Archive` folder. 

---

## Credits & Similar Projects

- **Oscar Toledo** for [x86 BootBASIC](https://github.com/nanochess/bootBASIC) — original inspiration for a non-IL Tiny BASIC approach.
- **Will Stevens'** [1kbyte 8080 Tiny BASIC](https://github.com/WillStevens/basic1K) - a more recent inspiration and taught me a few old skool tricks on code density. 
- **Hans Otten** for a thorough [6502 Tiny BASIC site](http://retro.hansotten.nl/6502-sbc/kim-1-manuals-and-software/kim-1-software/tiny-basic).
- **[Claude AI](https://claude.ai)** for making it possible for a non-expert to ship something that had been on the back burner since 1989.

---

## Licence

Copyright (c) 2026 Vincent Crabtree

**MIT License**

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
