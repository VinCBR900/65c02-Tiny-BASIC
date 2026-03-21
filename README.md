# 6502/65C02 Tiny BASICs

**Small Functional BASICs for Nostalgic 6502ers**

This repository contains two Tiny BASIC interpreters for 6502/65C02 systems, along with a pure-C assembler and C simulator used to build and test them. Tiny BASICs are minimal BASIC interpreters from the dawn of home computing — see the original 1976 [Dr. Dobb's Journal Vol. 1](https://archive.org/details/dr_dobbs_journal_vol_01) for the history.

As per Dr Dobbs, the classic approach was to use an Intermediate Language (IL) between the host CPU and the BASIC parser, which eased porting but cost speed. A hand-assembled 6502 IL version was written by Tom Pittman and is documented at [ittybittycomputers.com](http://www.ittybittycomputers.com/IttyBitty/TinyBasic/index.htm). 

I first came across Tiny BASIC single chip micros with the [Zilog Z8671](https://hc-ddr.hucki.net/wiki/lib/exe/fetch.php/einplatinenrechner/z8671_app_note.pdf) in the late 1980s and built an [Intel 8052AHBasic](https://www.bitsavers.org/components/intel/8051/MCS_BASIC-52/270010-003_MCS_BASIC-52_Users_Manual_Nov1986.pdf) toy system in early 1990s, and was fascinated in BASIC functionality in tiny ROM.  However I never found a 2 KB Tiny BASIC that would fit comfortably in a 2716 EPROM (Apple 1 Integer BASIC was 4kbyte, see below).

Writing a non-IL Tiny BASIC like [Li Chen's 2kbyte 8080 Palo Alto Tiny BASIC](https://archive.org/details/Palo_Alto_Tiny_BASIC_Version_3_Li-Chen_Wang_1977) myself seemed daunting, until I came across [x86 BootBASIC](https://github.com/nanochess/bootBASIC) by Oscar Toledo, which sparked the idea of a short, doable direct (non-IL) 6502 version, but after trying it was obvious my 65c02 were just not up to it.  

Time inevitably passed, then recently [Anthropic made a press release where Claude developed A C compiler itself](https://www.anthropic.com/engineering/building-c-compiler), so I thought I'd give it a try on Tiny BASIC.  With significant help from [Claude AI](https://claude.ai), these two interpreters emerged. See [Using Claude to modify the interpreters](#using-claude-to-modify-the-interpreters) below.

Both interpreters have been tested on the [Kowalski 65C02 Simulator](https://github.com/Kelmar/kowalski) — enable 65C02 mode and set terminal emulation to E00x, don't forget to click and type into the yellow Terminal window.

> **Note:** Only the specific uBASIC6502.asm works on an NMOS 6502, 4kBASIC and uBASIC use 65C02 instructions (STZ, BRA, INC/DEC acc, indirect-zp LDA/STA). 

---

## The Two Interpreters

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

Courtesy of [Sehugg and Mango 1](https://github.com/sehugg/mango_one), You can open this project in [8 Bit Workshop](https://8bitworkshop.com/v3.12.1/?repo=VinCBR900%2Fmango_one&platform=verilog&file=mango1.v) and try it Out!

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

Rwo simulators are available: a **batch simulator** (`sim65c02.c`) for scripted testing and a **interactive simulator** (`sim65c02_interactive.c` for Linux and `sim65c02_interactive_win32.c`) for live use as a Kowalski replacement. Both include the assembler directly and need no external dependencies. 

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

---

## Using Claude to Modify the Interpreters

As I'm a 65c02 Novice, these interpreters were written collaboratively with [Claude AI](https://claude.ai) — which understood the 65C02 instruction set, the space constraints, and the design tradeoffs. The assembler and simulators were also written this way, and together the three tools form a tight workflow that makes the source highly accessible to modification even if you are not a 65C02 expert. If you are then YMMV.

This may be old news to many people but is included here for those to whom this is new. 

### The workflow

The key insight is that you do not need to understand every byte of 65C02 assembly to extend these interpreters. The workflow is:

1. **Create a 'Project' in Claude**, Upload ASM65c02.c, SIM65c02.c to the files section, add rules like below, and in the chat window upload the ASM version you want to modify and tell it to review.
```asm
Create a TRACE LOG file that includes the version of any tools in it that you need and charts progress so you can continue if interrupted.
Always uprev tool versions if you need to modify them by updating the header file and update the trace file.
To avoid using wrong version, Copy old source version to an archive folder and only use them for regression testing.
Ensure source files have the header updated with change log and all functions are commented with inputs, outputs and clobbers. 
```
3. **Describe what you want** to Claude in plain English — a new statement, a new operator, a bug fix, or a size optimisation.
4. **Claude proposes the assembly change** with full explanation of what it is doing and whether the tools need updating.
5. **Tell Claude to implement and Test with the simulator** - Claude will use the TRACE log in case the session is interrupted. If it is interrupted **Dont't Click Retry** but type "continue from Trace file" and it should.
6. **Paste the modified source** into the Kowalski simulator or Interactive Sim:
   ```bash
   ./sim65c02_interactive uBASIC.asm "
   ```
7. **When it works**, check the size report (`asm65c02 uBASIC.asm`) to make sure the ROM still fits.
8. **Iterate.** The assembler gives clear error messages; the simulator lets you inject test input without hardware.

### Useful prompts to get started

```
I want to add a WAIT N statement to uBASIC that spins for approximately N milliseconds.
Look for the ST_TAB and a short existing statement handler for reference.
The ROM currently has 9 bytes free. How many bytes would this take?
```

```
The attached ubasic13.asm has a PRINT statement handler (DO_PRINT).
Can you add support for PRINT TAB(n) — move to column n before printing?
```

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

## Comparison: Original Tiny BASIC, uBASIC, Apple 1 BASIC, and 4K BASIC

This section compares four interpreters from the same tradition: the original Tiny BASIC specification published in Dr. Dobb's Journal (1975–1976), this 2 KB uBASIC, Apple 1 BASIC written by Steve Wozniak (1976), and this 4 KB BASIC.

### Background

**Original Tiny BASIC** was not a single implementation but a language specification published in the People's Computer Company newsletter in September 1975 by Dennis Allison, then elaborated in the first issues of Dr. Dobb's Journal of Computer Calisthenics and Orthodontia (January 1976 onwards). The journal was launched specifically on the back of reader enthusiasm for Tiny BASIC. The canonical feature set is defined by the BNF grammar published with the specification: `PRINT`, `IF…THEN`, `GOTO`, `INPUT`, `LET`, `GOSUB`, `RETURN`, `CLEAR`, `LIST`, `RUN`, `END` — and nothing else. No `FOR`, no `REM`, no `DATA`, no functions beyond what the expression grammar provides. Li-Chen Wang's Palo Alto Tiny BASIC (DDJ Vol 1 No 5, May 1976) is the most celebrated implementation, fitting in 1.77 KB for the 8080.

**Apple 1 BASIC** was written by Steve Wozniak — a hardware engineer who had not written a BASIC interpreter before — as a cassette-tape program for the Apple 1 computer in 1976. It occupied exactly 4 KB of RAM (loaded at `$E000`–`$EFFF`). Wozniak was a member of the Homebrew Computer Club alongside Wang and other Tiny BASIC authors. The Apple 1 BASIC manual is the primary source for its feature set; unlike the Apple II version, the Apple 1 had no lo-res graphics hardware at all, no paddles, and no screen-positioning capability — just a dumb serial terminal interface. The interpreter evolved through at least four versions (A–D) during 1976, with version A lacking even `INPUT`. The table below reflects the final/stable version D that shipped with the cassette. It is tokenised, works in signed 16-bit integers, supports arrays (`DIM`), strings as character arrays, `FOR`/`NEXT`, `GOSUB`/`RETURN`, and `GOTO` to expressions. Notably absent: `DATA`/`READ`, `ELSE`, `ON…GOTO`, `REM`, `MOD`, `RND`, and any screen control.

### Original Tiny BASIC specification grammar

From the BNF published in Dr. Dobb's Journal Vol 1 (1975–1976):

```
line       ::= number statement CR | statement CR
statement  ::= PRINT expr-list
             | IF expression relop expression THEN statement
             | GOTO expression
             | INPUT var-list
             | LET var = expression
             | GOSUB expression
             | RETURN
             | CLEAR
             | LIST
             | RUN
             | END
expr-list  ::= (string | expression) (, (string | expression))*
var-list   ::= var (, var)*
expression ::= (+|-|ε) term ((+|-) term)*
term       ::= factor ((*|/) factor)*
factor     ::= var | number | (expression)
var        ::= A | B | C ... | Z
number     ::= digit digit*
relop      ::= < (>|=|ε) | > (<|=|ε) | =
```

Key points: variables are single letters A–Z only (no arrays, no strings). Numbers are unsigned in the grammar but implementations typically used signed 16-bit. `IF` has no `ELSE`. `GOTO`/`GOSUB` take expressions (computed jumps were part of the spec from the start). String literals can appear in `PRINT` lists. There is no `REM`, no `FOR`, no `DATA`, no `RND`, no `PEEK`/`POKE`, no `ABS`.

### Feature comparison table

| Feature | Original Tiny BASIC (spec) | uBASIC / uBASIC6502 (~2 KB) | Apple 1 BASIC (~4 KB, 6502) | 4K BASIC (~4 KB, 6502) |
|---------|---------------------------|-------------------------------|-----------------------------|-----------------------------|
| **Size** | Spec only | uBASIC: ~2 KB, uBASIC6502: 2006 bytes | 4096 bytes (cassette) | 4093 bytes (ROM) |
| **CPU target** | N/A | uBASIC: 65C02, uBASIC6502: NMOS 6502 | 6502 | 65C02 |
| **Tokenised** | ✗ (most impls raw ASCII) | ✗ (raw ASCII) | ✓ | ✓ |
| **Integer only** | ✓ signed 16-bit | ✓ signed 16-bit | ✓ signed 16-bit | ✓ signed 16-bit |
| **Variables** | A–Z | A–Z | A–Z, An (letter+digit) | A–Z |
| **Integer arrays / DIM** | ✗ | ✗ | `DIM A(n)` | ✗ |
| **Strings** | ✗ (literals in PRINT only) | ✗ | ✓ (char arrays, `DIM A$(n)`) | ✗ (literals in PRINT only) |
| **Multi-statement `:`** | ✗ | ✓ | ✓ | ✓ |
| **PRINT `;` no-newline** | ✗ | ✓ | ✓ | ✓ |
| **PRINT string literal** | ✓ | ✓ | ✓ | ✓ |
| **INPUT** | ✓ | ✓ | ✓ (With Prompt) | ✓ |
| **LET** | ✓ (required) | ✓ (optional) | ✓ (optional) | ✓ (optional) |
| **IF/THEN** | ✓ (line number or stmt) | ✓ | ✓ (stmt or line number) | ✓ |
| **ELSE** | ✗ | ✗ | ✗ | ✓ |
| **GOTO expression** | ✓ (computed) | ✗ (literal only) | ✓ (computed) | ✓ (computed) |
| **GOSUB expression** | ✓ (computed) | ✗ | ✓ (computed) | ✓ (computed) |
| **RETURN** | ✓ | ✗ | ✓ | ✓ |
| **ON n GOTO/GOSUB** | ✗ | ✗ | ✗ | ✓ |
| **FOR/NEXT/STEP** | ✗ | ✗ | ✓ (up to 8 nested) | ✓ |
| **DATA/READ/RESTORE** | ✗ | ✗ | ✗ | ✓ |
| **REM** | ✗ | ✓ | ✗ | ✓ |
| **END** | ✓ | ✓ | ✓ | ✓ |
| **CLEAR / NEW** | `CLEAR` | `NEW` | `NEW` | `NEW` |
| **RUN / LIST** | ✓ | ✓ | ✓ | ✓ |
| **PEEK / POKE** | ✗ | ✓ | ✓ | ✓ |
| **Machine Langauge** | ✗ | `USR(addr)` (JSR, returns A)  | `CALL addr` (JSR, no retval) | `USR(addr)` (JSR, returns A) |
| **Arithmetic Ops** | ✗ | ✗ | `ABS` | `ABS` `SGN` |
| **RND** | ✗ | ✗ | ✓ `RND(n)` → 0..n-1 | ✓ `RND` → 1..32767 |
| **Character Conv** | ✗ | `CHR$` | ✗ | `ASC` `CHR$` |
| **LEN(str)** | ✗ | ✗ | ✓ (on DIM'd strings) | ✗ |
| **MOD / %** | ✗ | ✓ `%` | ✗ | ✓ both |
| **Logical Ops** | ✗ | ✗ | ✓ bitwise `AND` `OR` `NOT`) | ✓ bitwise `AND` `OR` `NOT` `XOR` |
| **Relational ops** | `<` `>` `=` `<=` `>=` `<>` | ✓ | ✓ (also `#` for `<>`) | ✓ |
| **INKEY (non-blocking)** | ✗ | ✗ | ✗ | ✓ |
| **CLS / HOME (clear screen)** | ✗ | ✗ | ✗ | ✓ `CLS` |
| **Cursor positioning** | ✗ | ✗ | ✗ (dumb terminal only) | ✓ `AT(col,row)` in PRINT |
| **FREE (memory query)** | ✗ | uBASIC: ✓, uBASIC6502: ✗ | ✓ `HIMEM=` / `LOMEM=` | ✓ |
| **HELP / keyword list** | ✗ | uBASIC: ✓, uBASIC6502: ✗ | ✗ | ✓ |
| **AUTO line numbering** | ✗ | ✗ | ✓ | ✗ |
| **Cassette LOAD/SAVE** | ✗ | ✗ | ✓ (via ACI hardware) | ✗ |
| **GOSUB nesting depth** | impl-dependent | n/a | 8 max | 8 |
| **FOR nesting depth** | n/a | n/a | 8 max | 8 |
| **Line number range** | 1–32767 | 0–32767 | 0–32767 | 0–32767 |

#### Notes on each column

**Original Tiny BASIC specification** (DDJ Vol 1, 1975–1976). The spec is intentionally minimal — Dennis Allison's goal was a BASIC small enough to fit in 4 KB of RAM on an 8080 with room left for programs. `IF` does not have `ELSE`. There is no `REM`, no `FOR`, no `DATA`, no functions. `GOSUB` and computed `GOTO` are present from the start. The single-array `@(i)` was added by some implementations (notably Palo Alto Tiny BASIC) but is not in the base specification. String literals appear only as arguments to `PRINT`.

**uBASIC** (~2 KB, this project). Closest in spirit to the original Tiny BASIC spec. Adds `REM`, `%` (modulo), `CHR$(n)`, `USR(addr)`, `PEEK`/`POKE`, bitwise operators, and `FREE` — all things a bare-metal 6502 programmer needs immediately. Omits `FOR`, `GOSUB`, and computed `GOTO` to stay within 2 KB. Does not tokenise: programs are stored and interpreted as raw ASCII, which costs some speed but saves tokeniser code. Loops and subroutines are implemented with `GOTO` and variable-based state, as in the classic Tiny BASIC tradition.

**Apple 1 BASIC** (~4 KB, Wozniak 1976). Fills its 4 KB cassette image with considerably more than the spec. Tokenised for speed; Wozniak noted it outperformed Microsoft BASIC on benchmarks of the day. Adds `FOR`/`NEXT`, integer arrays, character-array strings with `DIM`, `ABS`, `RND`, `AND`/`OR`/`NOT`, `CALL`, `AUTO`, and `HIMEM=`/`LOMEM=`. The `IF` condition uses a value of 1 for true (not just non-zero) which differs from most BASICs. Notably absent: `DATA`/`READ`, `REM`, `ELSE`, `ON…GOTO`, `MOD`, `CHR$`, `ASC`, `SGN`. The Apple 1 had no graphics hardware and no cursor positioning — just a raw serial output, so there is no `HOME`, `TAB`, `VTAB`, `PLOT`, `GR`, etc. at all (those came with the Apple II port). Program execution stops if any key is pressed, which made it easy to accidentally interrupt a running program.

**4K BASIC** (~4 KB, this project). Takes the same 4 KB budget as Apple 1 BASIC and spends it differently: tokenised, includes `FOR`/`NEXT`, `GOSUB`/`RETURN`, `DATA`/`READ`/`RESTORE`, `ON n GOTO/GOSUB`, `ELSE`, `SGN`, `ABS`, `RND`, `ASC`, `CHR$`, `MOD`/`%`, `XOR`, `INKEY`, `CLS`, and `AT(col,row)` cursor control — while omitting arrays and strings. Uses the 65C02's additional instructions (`STZ`, `BRA`, zero-page indirect) to squeeze more features per byte than was possible on the original 6502.

#### What Apple 1 BASIC has that neither Tiny BASIC variant provides

- **Integer arrays.** `DIM A(20)` allocates a numeric array. Wozniak's original game programs used arrays heavily for board state.
- **Character-array strings.** `DIM A$(20)` plus slice indexing `A$(2,5)` — an HP BASIC style approach that avoids the overhead of a string heap. There is no equivalent in any Tiny BASIC without significant added code.
- **`AUTO` line numbering.** Prompt with incrementing line numbers — saves typing.
- **`HIMEM=` / `LOMEM=`.** Direct control of the program/variable memory boundaries. Useful when BASIC shares memory with machine code.
- **Cassette LOAD/SAVE.** Via the Apple Cassette Interface — entirely hardware-specific but functional.

#### What these Tiny BASIC variants have that Apple 1 BASIC doesn't

- **`DATA` / `READ` / `RESTORE`** (4K BASIC). Wozniak deliberately omitted these as unnecessary for game programming. 4K BASIC includes full support; look-up tables and static sequences are much more convenient with `DATA`.
- **`ON n GOTO` / `ON n GOSUB`** (4K BASIC). Multi-way computed dispatch without needing a computed `GOTO` expression and careful arithmetic.
- **`ELSE`** (4K BASIC). Apple 1 BASIC's `IF` has no else branch; a second `IF NOT (...)` line is needed.
- **`MOD` / `%`** (both). Apple 1 BASIC has no modulo; programmers used `A - (A/B)*B`.
- **`REM`** (uBASIC, 4K BASIC). Apple 1 BASIC has no comment statement at all.
- **`AND` / `OR` / `XOR` / `NOT`** (4K BASIC).
- **`CHR$(n)` / `ASC(c)`** (uBASIC, 4K BASIC). Useful for character-based I/O.
- **`INKEY`** (4K BASIC). Non-blocking key read. Apple 1 BASIC stops execution on any keypress, making non-blocking input impossible.
- **Cursor control** (4K BASIC). `AT(col,row)` in PRINT. The Apple 1's dumb terminal interface made this hardware-impossible.
- **`CLS`** (4K BASIC).

### Size perspective

| Interpreter | Year | Size | Platform |
|-------------|------|------|----------|
| Original Tiny BASIC spec | 1975 | — (spec) | any |
| Palo Alto Tiny BASIC v1 (Li-Chen Wang) | 1976 | 1.77 KB | 8080 |
| Apple 1 BASIC (Wozniak) | 1976 | 4.0 KB | 6502 |
| uBASIC (this project) | 2026 | 2.0 KB | 6502/65C02 |
| 4K BASIC (this project) | 2026 | 4.0 KB | 65C02 |

Apple 1 BASIC and 4K BASIC both occupy 4 KB, yet spend that budget in distinctly different ways. Wozniak used much of the space on arrays, strings, and `RND`; the 4K BASIC uses the same space for `DATA`/`READ`, `ELSE`, `ON…GOTO`, `SGN`, `ASC`/`CHR$`, `INKEY`, `CLS`, and cursor control — features more useful on a modern embedded target than array support. Apple 1 BASIC had the original 6502, while these Tiny BASICs uses the 65C02's extra instructions (`STZ`, `BRA`, zero-page indirect addressing) which were not available to Wozniak in 1976.

uBASIC at 2 KB sits squarely in the original Tiny BASIC tradition: non-tokenised, no `FOR`, no `GOSUB`, immediate and simple. It extends the spec with the minimum needed for a real 6502 system: `PEEK`/`POKE`, `USR()`, `CHR$`, `%`, bitwise operators.

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
