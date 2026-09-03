# 6502 Tiny BASICs

> **AI Disclosure**: This code was developed with the assistance of AI (Claude by Anthropic, and Gemini by Google). The architecture, code, tests, and documentation were produced collaboratively between a human developer and an AI assistant. All code has been reviewed by the author.
>Specifically:
> - I architected, reviewed, hand optimized.
> - Claude created boilerplate code that was subsequentyl hand optimized, ran regression tests,bugfixed and helped with documentation.
> - Gemini created code fragments that were usually wrong but inspired `code golf` techniques.  
>
> To be frank, without these agents this work would not have been possible.

Here we have several Tiny BASIC for 6502/65c02
  * **pBASIC - TINY** - Proof of Concept 1kbyte Tiny BASIC interpreter for 65c02 - 16 bit signed INTs, `+`,`-`,`*`,`/`,`<`,`=`,`(`,`)` math.
  * **uBASIC - SMALL** - Targeted at original NMOS 6502, meets 1976 Tiny BASIC spec for 16 bit signed ints, fits in 2kbyte with multiple features including bitbang serial IO on a VIA 6522.
  * **4kBASIC - FAST** - Targeted at 65c02, this is a Tokenized, Extended 16bit signed in Tiny BASIC with `FOR`/`NEXT`, CORDIC `SIN`/`COS` degree functions and Bitwise operators.  Fits in a 4kbyte EPROM.
  * **mini-BASIC - TRIG** - Targeted at 65c02, 4 byte floating point with radian based TRIG: `SIN`/`COS`/`TAN`/`ASIN`/`ACOS`/`ATAN`, and Transcendental `LN`/`EXP`, that also fits in a 4kbyte EPROM.   

You can see the development progression - first came uBASIC, then extended 4k BASIC with some trig support, then mini-BASIC with 4byte floats, full trig, and transcendental.

You can play with these online at the link below - all three versions include a showcase BASIC demo - type `RUN` to execute, and `LIST` to view.   
https://vincbr900.github.io/65c02-Tiny-BASIC/

> If you've found these Tiny BASIC interpreters useful for learning, retrocomputing, or your own projects, you can buy me a coffee.  Donations are entirely optional but greatly appreciated.
> [!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/vpcrabtreeZ)

### Pico-BASIC `pBASIC65c02.ASM` — fits in a 2708/2758 EPROM (<1 KByte)

**<1024 bytes assembled. ROM at $FC00–$FFFF**

A tiny but mostly complete integer Tiny BASIC. No tokeniser - BASIC program lines are stored as raw ASCII and re-parsed on every execution. 

**Statements:** 
  * `END` `GOTO <expr>`  `IF` `ASK (INPUT)`  `PRINT [;]` `WR char` (Equivalent to `PRINT CHR$(char);` but statement form)    
  * `LIST ` `NEW` `RUN`

**Expressions:** 
  * Math: `+` `-` `*` `/` unary `-` `(` `)`
  * Relops: `<` and `=` supported - use flipped operands for `>`, e.g. `A>B` as `B<A`. A leading `!` inverts following relop: `A!=B` equivalent to `A<>B`, `A!<B` equivalent to  `A>=B`, and `B!<A` equivalent to `A<=B`.
  * Variables: `A`–`Z` signed 16-bit integers, −32768 to 32767
  * Functions: **None**  

**Notes**
- Uses **2 character testing where only 1st letter is matched** - e.g. `PRINT`, `PR`, `PX` all executes `DO_PRINT`.  So spaces are important e.g. `PRINT A;"=Test"` prints "5=Test" if A is 5, whereas `PRINTA;"=Test"` prints `=Test`.
- **Expressions supported in GOTO** - `GOTO`, `GOTO X`, `GOTO 10*I` all work.  
- **Left to Right Operator Precidence** — up to you to use Parenthesis to get the right order
- **BASIC Line Handling** - to save space in-place insertion/deletion not supported.  This means you can only change the last line - either update or delete.  So if you enter 10 lines and notice an error on line 2, you must delete lines 10, 9, 8, 7, 6, 5, 4, 3 in sequence.  

**Errors** printed as `!N`, no line number shown:

| Code | Meaning |
|------|---------|
| !0 | Syntax / bad expression |
| !1 | Undefined line number |
| !2 | Division by zero |
| !3 | Out of memory |
| !4 | Bad variable assignment |
| !5 | Line Entry Error |

### Micro-BASIC `uBASIC6502.ASM` — fits in a 2716 EPROM (<2 KByte)

**<2048 bytes assembled. ROM at $F800–$FFFF**

A small but feature rich integer Tiny BASIC. No tokeniser - BASIC program lines are stored as raw ASCII and re-parsed on every execution. 

This interpreter has also been ported to the John Bell 80-153 single board computer.  A modified `sim65c02` simulator (`JB-sim65c02`) is provided for this version.

**Statements:** 
  * `END` `GOSUB`/`RETURN`  `GOTO`  `IF`/`THEN`  `INPUT`  `LET`  `POKE`  `PRINT [TAB(n)] [;] [CHR$(n)] [HEX$(val)]`  `REM`    
  * `LIST [start,end]` `NEW` `RUN`

**Expressions:** 
  * Math: `+` `-` `*` `/` `%`(mod)
  * Relops: `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)`
  * Variables: `A`–`Z`, signed 16-bit integers
  * Number representation: decimal −32768 to 32767, Hex $0000-$FFFF 
  * Functions: `ABS(val)`   `FREE`   `PEEK(addr)`  `RND`   `USR(addr)`  
  * Bitwise: `XOR(a,b)`   `AND(a,b)`   `OR(a,b)`  `NOT(a)`

**Notes**
- Uses **2 character matching** - with 3rd char match for `GOSUB`/`GOTO` and `RETURN`/`REM`.  Matches anything after e.g. `PROCEED` matches `PRINT`.  Therefore spaces are important e.g. `PRINT TAB(5);"hello"` prints 5 spaces then `Hello` and works, whereas `PRINTTAB(5);"HELLO"` prints `5Hello` and does not.
- **`GOTO`/`GOSUB` accepts expressions** — `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work.  But Don't have `GOSUB`/`RETURN` on same line.
- **`RND`** — 16-bit Galois LFSR pseudo-random number, returns 1–32767; seeded at startup; useful as `RND % 6 + 1` for a die roll
- **`:` Not Supported** - Multi-statement operator `:` is not supported and input buffer is 40 characters only. 

**Errors** printed as `?N [IN line]`:

| Code | Meaning |
|------|---------|
| ?0 SN | Syntax / bad expression |
| ?1 UL | Undefined line number |
| ?2 OV | Division or modulo by zero |
| ?3 OM | Out of memory |
| ?4 UK | Bad variable assignment |

---

### 4K BASIC — fits in a 2732 EPROM (<4 KByte)

**<4096 bytes assembled. ROM at $F000–$FFFF**

A more capable integer BASIC. Keywords are tokenised on entry and numbers converted to 16-bit binary, so the interpreter does not re-parse ASCII on execution — several times faster than uBASIC and easier on RAM.

Has bitwise operators and also CORDIC `SIN`/`COS` in degrees*1000.

**Statements:** 
  * `PRINT [TAB(n)] [;] [CHR$(n)] [HEX$(val)]`  `IF`/`THEN`/`ELSE` `GOTO` `GOSUB` `RETURN` `FOR`/`TO`/`STEP`/`NEXT` `LET` `INPUT` `REM` `END` `POKE` `DATA` `READ` `RESTORE` 
  * `RUN` `LIST [start,end]` `NEW` `FREE` `HELP`
 
**Functions:** `ABS(n)` `SGN(n)` `PEEK(addr)` `USR(addr)` `RND` `SIN(deg)`  `COS(deg)`  `SHR(n)`   `SHL(n)`

**Expressions:** 
  * `MOD` `+` `-` `*` `/` `%`(mod) `^` (power)
  * `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)`
  * variables `A`–`Z` signed 16-bit integers
  * Number representation: decimal −32768 to 32767, Hex $0000-$FFFF 
  * Bitwise - `AND` `OR` `XOR` `NOT` 

**Numbers:** signed 16-bit integers, −32768 to 32767. Relational operators return −1 (true) or 0 (false). `AND`/`OR`/`XOR`/`NOT` are bitwise.

**Notes**
- **`^` Power** - base can be negative, exponent must be positive
- **`GOTO`/`GOSUB` accepts expressions** - `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work
- **`MOD` keyword** - `10 MOD 3` is now an alternative to `10 % 3` (both give `1`)
- **`RND`** - 16-bit Galois LFSR pseudo-random number, returns 1–32767; seeded at startup; useful as `RND MOD 6 + 1` for a die roll
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

### mini-BASIC65c02 — fits in a 2732 EPROM (<4 KByte)

**<4096 bytes assembled. ROM at $F000–$FFFF**

An expanded Tiny BASIC with 32bit Floating ppoint support (Still vars `A`-`Z`). No tokeniser — program lines are stored as raw ASCII and re-parsed on every execution for ROM size. 

**Statements:** 
  * `PRINT [TAB(n)] [;] CHR$(n)` `IF`/`THEN`/`ELSE` `GOTO` `GOSUB` `RETURN` `FOR`/`TO`/`STEP`/`NEXT` `LET` `INPUT` `REM` `END` `POKE` 
  * `LIST [start,end]` `NEW` `RUN`
 
**Functions:** 
  * `ABS(flt)` `FLOOR(flt)` `PEEK(addr)` `USR(addr)` `RND` `SQRT(flt)` `PI`
  * Radian based TRIG - `SIN(flt)`/`COS(flt)`/`TAN(flt)`/`ASIN(flt)`/`ACOS(flt)`/`ATAN(flt)`
  * Transcendental `LN(flt)`/`EXP(flt)` 

**Expressions:** 
  * `+` `-` `*` `/` `%`(mod) `^` (power)
  * `=` `<` `>` `<=` `>=` `<>` unary `-` `(` `)` - Relational operators return −1 (true) or 0 (false)
  * variables `A`–`Z` 32 bit MBF4 float, ~6-7 significant decimal digits

**Notes**
- **`^` Power** - Base must be >= 0, Exponent can be negative (uses Ln) 
- **`GOTO`/`GOSUB` accepts expressions** — `GOTO X`, `GOSUB BASE+N`, `GOTO 10*I` all work
- **`MOD` keyword** — `10 MOD 3` is now an alternative to `10 % 3` (both give `1`)
- **`RND`** — 16-bit Galois LFSR pseudo-random number, returns 0-1; seeded at startup
- **`:` Not Supported** - Multi-statement operator `:` is not supported and input buffer is 40 characters only.
 
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

## Building and Running

### Proprietary Online Simulator

You can play with these online at the link below - all three versions include a showcase BASIC demo - type `RUN` to execute, and `LIST` to view.   
https://vincbr900.github.io/65c02-Tiny-BASIC/

### Kowalski Simulator

All ROMs work in the [Kowalski 65C02 Simulator](https://github.com/Kelmar/kowalski). Set:
- CPU mode: Set **65C02** if using 4k versions
- Terminal emulation addresses: **E000–E006**
- Ensure `uBASIC6502.asm` has `KOWALSKI=1` defined at the top of the file to disable bitbang serial

Load the assembled binary or paste the `.asm` source, click Assemble (F7), Debug (F6) and either RUN (F5) or Animate (Ctrl-F5) if you want to watch it step through - don't forget to click and type into the yellow Terminal window. The INIT trampoline at the start of uBASIC ROM means Kowalski's nominal execute-from-first-byte behaviour works correctly, as does real hardware's reset-vector startup.

### Proprietary Offline Simulator
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

#### Terminal I/O

For real Hardware you will need to modify the I/O Addresses for Serial I/O, specified below. 

| Address | Kowalski Virtual Terminal Function  |
|---------|----------|
| $E001 | Putchar |
| $E004 | Getchar (Returns 0 if no char available) |

### Things to watch out for

- **ROM size.** All variants don't have much free space. Always check after a change. Claude will help you find space savings if you're over budget.
- **Page constraints.** The string table must stay entirely on page $F8 (all strings accessed via a shared hi-byte). Claude can get confused if the page boundary is exceeded - it will find it eventually but after a lot of thrashing, so tell it to watch out when adding new strings.
- **Zero-page register clobbers.** The In/Out/Clobbers comments on each function document which of T0/T1/T2/LP/IP/OP are live. 
- **Fall-through chains.** Several functions share a single RTS by falling through into the next function. These are clearly marked in the source. Inserting code between them without understanding the fall-through will break things.

---

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
