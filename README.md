# 6502/65C02 Tiny BASICs

### uBASIC — fits in a 2716 EPROM (<2 KByte)

**<2048 bytes assembled. ROM at $F800–$FFFF**

A minimal but complete integer BASIC family. No tokeniser — program lines are stored as raw ASCII and re-parsed on every execution. This costs RAM and speed but keeps the interpreter very small. Both variants below fit a 2716 EPROM (2048 bytes).

#### uBASIC (65C02 baseline) — `uBASIC.asm`

**Statements:** `PRINT` `IF`/`THEN` `GOTO` `LET` `INPUT` `REM` `END` `RUN` `LIST` `NEW` `POKE` `FREE` `HELP`

**Expressions:** `+` `-` `*` `/` `%`(mod) `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)` `CHR$(n)` `PEEK(addr)` `USR(addr)` variables `A`–`Z`

**Multi-statement lines** with `:` separator (e.g. `10 A=1 : B=2 : PRINT A+B`)

**Numbers:** signed 16-bit integers, −32768 to 32767

**Errors** (printed as `?N [IN line]`):

| Code | Meaning |
|------|---------|
| ?0 SN | Syntax / bad expression |
| ?1 UL | Undefined line number |
| ?2 OV | Division or modulo by zero |
| ?3 OM | Out of memory |
| ?4 UK | Bad variable assignment |

**Memory map:**

| Address | Contents |
|---------|----------|
| $0000–$008C | Zero page: interpreter variables, input buffer, A–Z vars |
| $0200–$0FFF | Program storage (RAM, up to ~3.5 KB) |
| $F800–$FFFF | ROM: interpreter + string table + vectors |

#### uBASIC6502 (NMOS 6502 port) — `uBASIC6502.asm`

**Statements:** `PRINT` `IF`/`THEN` `GOTO` `LET` `INPUT` `REM` `END` `RUN` `LIST` `NEW` `POKE`  
(Parser also accepts 2-letter prefixes: `PR` `IF` `GO` `LE` `IN` `RE` `EN` `RU` `LI` `NE` `PO`.)

**Expressions:** `+` `-` `*` `/` `%`(mod) `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)` `CHR$(n)` `PEEK(addr)` `USR(addr)` variables `A`–`Z`

Courtesy of [Sehugg and Mango 1](https://github.com/sehugg/mango_one), You can open this project in [8 Bit Workshop](http://8bitworkshop.com/v3.12.1/?redir.html?platform=verilog&githubURL=https%3A%2F%2Fgithub.com%2FVinCBR900%2Fmango_one&file=mango1.v) and try it Out! Type `LIST` to see the embedded BASIC program and `RUN` to execute it - Pressing `ESC` aborts running program. 

**Notes:** full conventional keywords are accepted by matching the first 2 letters and consuming trailing alphabetic characters; `HELP` and `FREE` are removed in this NMOS variant to keep ROM headroom.

### 4K BASIC — fits in a 2732 EPROM (<4 KByte)

**<4096 bytes assembled. ROM at $F000–$FFFF**

A significantly more capable integer BASIC. Keywords are tokenised on entry and numbers converted to 16-bit binary, so the interpreter does not re-parse ASCII on execution — several times faster than uBASIC and easier on RAM. Structured loops (FOR/NEXT) and subroutines (GOSUB/RETURN) are supported.

**Statements:** `PRINT` `PRINT AT(col,row)` `IF`/`THEN`/`ELSE` `GOTO` `GOSUB` `RETURN` `FOR`/`TO`/`STEP`/`NEXT` `LET` `INPUT` `REM` `END` `RUN` `LIST` `NEW` `POKE` `DATA` `READ` `RESTORE` `FREE` `CLS` `HELP` `ON n GOTO/GOSUB` `:`(multi-statement - don't have `FOR`/`NEXT` or `GOSUB`/`RETURN` on same line)

**Functions:** `ABS(n)` `SGN(n)` `CHR$(n)` `ASC("c")` `PEEK(addr)` `USR(addr)` `INKEY` `RND`

**Expressions:** `AND` `OR` `XOR` `NOT` `MOD` `+` `-` `*` `/` `%`(mod) `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)` variables `A`–`Z`

**Numbers:** signed 16-bit integers, −32768 to 32767. Relational operators return −1 (true) or 0 (false). `AND`/`OR`/`XOR`/`NOT` are bitwise. `PRINT` items separated by `;` suppress the newline between them.

**Notes**
- **`GOTO`/`GOSUB` accept expressions** — `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work
- **`ON n GOTO/GOSUB`** — multi-target branch: `ON N GOTO 100,200,300` jumps to the Nth target; out-of-range silently falls through
- **`MOD` keyword** — `10 MOD 3` is now an alternative to `10 % 3` (both give `1`)
- **`RND`** — 16-bit Galois LFSR pseudo-random number, returns 1–32767; seeded at startup; useful as `RND MOD 6 + 1` for a die roll

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

**Memory map:**

| Address | Contents |
|---------|----------|
| $0000–$00BD | Zero page: interpreter variables, A–Z vars, GOSUB/FOR stacks |
| $0200–$0FFF | Program storage (tokenised, RAM, up to ~3.5 KB) |
| $F000–$FFFF | ROM: interpreter + keyword table + string literals + vectors |

---

## Files

| File | Description |
|------|-------------|
| `uBASIC.asm` | uBASIC source (~1750 lines, heavily commented) |
| `uBASIC6502.asm` | NMOS-6502 uBASIC variant with 2-byte keyword-prefix matcher |
| `4kBASIC.asm` | 4K BASIC source (~3100 lines, heavily commented) |
| `asm65c02.c` | Two-pass 65C02 assembler (C) — builds standalone or embeds in sim |
| `sim65c02.c` | 65C02 Batch simulator— includes asm65c02.c directly |
| `sim65c02_interactive` | 65C02 simulator with NCURSES virtual terminal (C) — includes asm65c02.c directly |
| `sim65c02_interactive_Win32` | 65C02 simulator with Win32 TUI virtual terminal (C) — includes asm65c02.c directly |

All Tiny BASIC assembly sources include a pre-loaded **feature showcase program** at $0200. Type `RUN` (or `RU` on `uBASIC6502`) to see it, `NEW` to clear it, `LIST` to read the source.

The uBASIC / uBASIC6502 (2kbyte) showcase exercises `PRINT`, `CHR$`, arithmetic, comparisons, `IF`/`THEN`, `GOTO`-based loops (including nested), and finishes with a fixed point Mandelbrot renderer.

The 4K BASIC showcase exercises every major feature: `PRINT`, `CHR$`, `ASC`, `ABS`, `SGN`, `MOD`, `NOT`, `AND`, `OR`, `XOR`, `RND`, `PEEK`/`POKE`, `DATA`/`READ`/`RESTORE`, `FOR`/`NEXT`/`STEP`, `IF`/`THEN`/`ELSE`, `GOSUB`/`RETURN`, `ON n GOSUB`, and finishes with the same Mandelbrot renderer as a stress test of the expression evaluator and nested loops.

---

## Building and Running

### Kowalski Simulator

Both ROMs work in the [Kowalski 65C02 Simulator](https://github.com/Kelmar/kowalski). Set:
- CPU mode: Set **65C02** if using enhanced versions
- Terminal emulation addresses: **E000–E006**

Load the assembled binary or paste the `.asm` source click Assemble (F7), Debug (F6) and either RUN (F5) or Animate (Ctrl-F5) if you want to watch it step through - don't forget to click and type into the yellow Terminal window. The INIT trampoline at the start of uBASIC ROM means Kowalski's nominal execute-from-first-byte behaviour works correctly, as does real hardware's reset-vector startup.

The interactive simulator (`sim65c02_interactive.exe`) is a drop-in alternative to Kowalski for day-to-day development. It uses identical I/O port addresses, adds live ZP/variable inspection.

### Proprietary Simulators
Building and Running

Two simulators are available: a **batch simulator** (`sim65c02.c`) for scripted testing and a **interactive simulator** (`sim65c02_interactive.c` for Linux and `sim65c02_interactive_win32.c`) for live use as a Kowalski replacement. Both include the assembler directly and need no external dependencies. 

### Interactive simulator (Windows) — recommended for development

`sim65c02_interactive_win32.c` gives a split-screen Windows console that closely mimics the Kowalski simulator environment — type BASIC directly, see the virtual terminal on the left and live interpreter state on the right.

**Build on Windows with TCC:**
```
Tcc -O2 -o sim65c02_interactive.exe sim65c02_interactive_win32.c
```

**Cross-compile on Linux:**
```bash
gcc -O2 -o sim65c02_interactive sim65c02_interactive.c
```

**Run:**
```
sim65c02_interactive.exe 4kBASIC.asm
sim65c02_interactive.exe uBASIC.asm
sim65c02_interactive.exe 4kBASIC.bin
```

The assembler is embedded — pass an `.asm` file directly. The console auto-resizes to 81×29 on startup; if your terminal has a small maximum buffer you may need to widen it in Properties first.

**Screen layout:**

```
┌─ BASIC Terminal ──────────────────────┐ ┌─ Interpreter State ───────────────┐
│ 4K BASIC v11.5                        │ │ IP:F1A2 PE:06FB CURLN:  430       │
│ 2309 BYTES FREE                       │ │ RUN:RUN  FSTK:1 GRET:0 SP:F8     │
│ > _                                   │ │ T0:0010 T1:0000 T2:0000           │
│                                       │ │ DATA:0000 RND:ACE1                │
│                                       │ │ ---------------------------------  │
│                                       │ │ Variables A-Z:                    │
│                                       │ │ A:0        B:0        C:-128      │
│                                       │ │ ...        I:-58      ...         │
│                                       │ │ ---------------------------------  │
│                                       │ │ FOR stack (1 frame):              │
│                                       │ │  [0]I lim=56  stp=6  ln=600       │
└───────────────────────────────────────┘ └───────────────────────────────────┘
 PC:F2B4 A:3A X:00 Y:00 SP:F8  N0V0D0I1Z0C1  Cyc:12450000  F1:ZP  F5:RST  q:quit
```

The right panel updates live while the CPU runs — you can watch variables change, see FOR stack frames push and pop, and monitor GOSUB nesting depth in real time.

**Controls:**

| Key | Action |
|-----|--------|
| Type normally | Input sent to GETCH — type BASIC commands as usual |
| Enter | Sends CR to the interpreter |
| Backspace | Sends backspace |
| **F1** | Toggle right panel:VARS A-Z  ↔  ZP hex dump `$00–$BF` |
| **F2** | Toggle right panel: FOR/GOSUB stacks ↔ stack `$0100–$01FF` (Top 16) |
| **F5** | Reset CPU (re-runs from reset vector, clears terminal) |
| **F6** | Fire Maskable IRQ - IRQ handler should break into running BASIC program |
| **Escape** | Quit and restore console |

**Kowalski I/O mapping** is identical: `$E000` CLS, `$E001` PUTCH, `$E004` GETCH, `$E005`/`$E006` cursor X/Y. A program that works in Kowalski should behave identically here.

---

### Batch simulator — scripted testing and regression

`sim65c02.c` is a non-interactive simulator best for Claude/automated regression testing. It accepts pre-queued input lines, runs to completion, and prints output to stdout. Useful for automated testing, CI, and Mandelbrot benchmarks.

**Build:**
```bash
gcc -O2 -o sim65c02 sim65c02.c
```

**Run:**
```bash
./sim65c02 uBASIC.asm --input "PRINT 42"
./sim65c02 uBASIC6502.asm --input "PR 42"
./sim65c02 4kBASIC.asm --input "PRINT 42"
./sim65c02 4kBASIC.asm --mandelbrot --maxcycles 800000000
```

`--mandelbrot` simply queues `RUN` — the showcase program (ending with the Mandelbrot renderer) is pre-loaded in both ROMs. `--input` is repeatable; flags are consumed in order, simulating a user typing at the terminal. The simulator exits cleanly when input is exhausted and the interpreter is waiting for a keypress.

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

The simulator can also verify a `.bin` directly — it auto-detects the load address from file size (2048 bytes → $F800, 4096 bytes → $F000):

```bash
./sim65c02 uBASIC.bin --input "PRINT 42"
./sim65c02 4kBASIC.bin --input "PRINT 42"
```

**Options:**

| Option | Description |
|--------|-------------|
| `--input "line"` | Queue a line of input (CR appended); repeatable |
| `--mandelbrot` | Queue `RUN` (showcase + Mandelbrot pre-loaded at `$0200`) |
| `--maxcycles N` | Cycle limit before forced exit (default 800 000 000) |
| `--plain` | Suppress ANSI cursor-position escapes — use for piped/redirected output |
| `--verbose` | Print every instruction as it executes (very slow) |
| `--stats` | Print cycle count and key zero-page values on exit |
| `--load-addr 0xNNNN` | Override auto-detected load address for `.bin` files |

### Assembler standalone

The assembler can also be built on its own to check sizes, print a symbol table, or verify there are no errors:

```bash
gcc -O2 -DASM65C02_MAIN -o asm65c02 asm65c02.c

asm65c02 uBASIC.asm
asm65c02 4kBASIC.asm
```

Output includes key symbol addresses, the reset vector, and a ROM size report. Exits 0 on success, 1 on assembly errors.

#### Producing a ROM binary for real hardware

Use the standalone assembler with `-o <file> -r $lower-upper` to write abinary file:

```bash
# uBASIC — 2 KB ROM image for a 2716 EPROM

asm65c02 uBASIC.asm -o uBASIC.bin -r $F800-$FFFF

# 4K BASIC — 4 KB ROM image for a 2732 EPROM
sm65c02 4kBASIC.asm -o 4kBASIC.bin -r $F000-$FFFF
```

Program the `.bin` file to an EPROM so that the chip's address pin 0 maps to $F800 (uBASIC) or $F000 (4K BASIC). The reset vector at $FFFC/$FFFD within the image points to `INIT`, so the interpreter starts on power-up.


#### Note on Running from real ROM (no pre-loaded program)

The pre-loaded program relies on `INIT` setting `PE` to point past the program bytes. To start with an empty program instead, change two lines in `INIT`:
```asm
; In INIT, change:
        LDA #<SHOWCASE_END     →     LDA #<PROG
        LDA #>SHOWCASE_END     →     LDA #>PROG
```
This sets `PE = PROG = $0200` so the interpreter starts fresh. Both ASM files include this note as a comment near the label.

Program the `.bin` file to an EPROM so that the chip's address 0 maps to $F800 (uBASIC) or $F000 (4K BASIC). The reset vector at $FFFC/$FFFD within the image points to `INIT`, so the interpreter starts on power-up.

#### Terminal I/O

For real Hardware you will need to modify the I/O Addresses for Serial I/O, specified below.  Although 4kBASIC has plenty of ROM space available, uBASIC (6502 and 65c02 version) only have about 2 dozen bytes free, which is just enough for simple writes to ACIA or bitbang serial.  Anything more complicated like screen handling may need to loose a keyword to make space - See Below on Using Claude to Customize.

| Address | Kowalski Virtual Terminal Function  |
|---------|----------|
| $E000 | Clear Screen |
| $E001 | Putchar |
| $E004 | Getchar (Returns 0 if no char available) |
| $E005 | Set Terminal X-Pos |
| $E006 | Set Terminal X-Pos |

### Things to watch out for

- **ROM size.** uBASIC has less than a dozen bytes free, so pretty full. Always check after a change. Claude will help you find space savings if you're over budget.
- **Page constraints.** The uBASIC string table must stay entirely on page $F8 (all strings accessed via a shared hi-byte). Claude can get confused if the page boundary is exceeded - it will find it eventually but after a lot of thrashing, so tell it to watch out when adding new strings to uBASIC.
- **Zero-page register clobbers.** The In/Out/Clobbers comments on each function document which of T0/T1/T2/LP/IP/OP are live. Claude will respect these if you share the relevant headers.
- **Fall-through chains.** Several functions share a single RTS by falling through into the next function. These are clearly marked in the source. Inserting code between them without understanding the fall-through will break things — tell Claude to watch out for them.

---

## Technical Notes

#### Why no tokeniser in uBASIC?

A tokeniser saves RAM (shorter stored programs) and speeds execution (no re-parsing). But the tokeniser itself costs ROM. In a 2 KB budget every byte counts, and storing programs as raw ASCII with a simple parse-on-execute design kept the interpreter under 2048 bytes while still being genuinely useful. 4K BASIC has the ROM headroom to tokenise and is significantly faster as a result.

#### The `%` operator and `MOD` keyword

Both interpreters support `%` as integer modulo: `10 % 3` gives `1`. 4K BASIC v11 also accepts the word `MOD`: `10 MOD 3` gives the same result. The sign follows the dividend (C convention), so `-7 % 4` gives `-3`. Division and modulo by zero both raise error OV.

#### `RND` in 4K BASIC

`RND` returns a pseudo-random integer in the range 1–32767. It uses a 16-bit Galois LFSR (linear feedback shift register) with taps at $B400, seeded to $ACE1 at startup. The seed is not resettable from BASIC — every run produces the same sequence, which is useful for reproducible tests. A common idiom for a six-sided die roll is:

```basic
10 PRINT RND MOD 6 + 1
```

#### USR(addr)

`USR(addr)` calls machine code at the given address. The routine should end with `RTS`; the value in the A register on return becomes the result of the `USR()` expression. This allows hardware-specific extensions without modifying the interpreter source.

#### The pre-loaded showcase program

Both ROMs include a feature showcase program pre-loaded at $0200. Type `RUN` to execute it, `NEW` to clear it, or `LIST` to read the source. The showcase is designed to exercise as much of each interpreter's instruction set as possible in a single self-contained program.

The **4K BASIC showcase** (lines 10–930) produces output like:
```
== 4K BASIC SHOWCASE ==
--- PRINT / CHR$ / ASC ---
CHR$(65)=A  ASC(A)=65
--- ABS / SGN / MOD ---
ABS(-7)=7  SGN(-5)=-1  SGN(0)=0
17 MOD 5=2
--- NOT / AND / OR / XOR ---
NOT 0=-1  NOT -1=0
6 AND 3=2  5 OR 2=7  7 XOR 3=4
--- RND / PEEK / POKE ---
RND=25200  RND MOD 10=4
POKE 512,42  PEEK=42
--- DATA / READ / RESTORE ---
READ: 111,222,333
RESTORE->A=111
--- FOR / NEXT / STEP ---
12345
10741
--- IF / THEN / ELSE ---
IF true
ELSE ok
--- GOSUB / RETURN ---
GOSUB ok
--- ON n GOSUB ---
ON 1
ON 2
ON 3
--- MANDELBROT ---
 '!!!!!!!""%#,,# #""""$*$#)$*' - ##%#
...
```

The **uBASIC showcase** (lines 10–480) demonstrates arithmetic, comparisons, `IF`/`THEN`, `GOTO`-based loops, nested loops, and the same Mandelbrot renderer — all without `FOR`/`NEXT` or `GOSUB`, showcasing how much can be done with minimal primitives.

The Mandelbrot renderer uses only integer arithmetic (scaled fixed-point: coordinates scaled by 64, 16 iterations) and serves as a thorough stress-test of the expression evaluator and loop constructs.

---

## Credits & Similar Projects

- **Oscar Toledo** for [x86 BootBASIC](https://github.com/nanochess/bootBASIC) — my original inspiration for a non-IL Tiny BASIC approach.
- **Will Stevens'** [1kbyte 8080 Tiny BASIC](https://github.com/WillStevens/basic1K) was also a more recent inspiration and taught me a few old skool tricks on code density. 
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
