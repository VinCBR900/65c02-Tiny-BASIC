/*
 * sim65c02.c  —  Toy 65C02 simulator  (v11, Jul 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Canonical simulator for:
 *   ubasic6502.asm       uBASIC     (2 KB ROM at $F800-$FFFF)
 *   miniBASIC65c02.asm   4K BASIC   (4 KB ROM at $F000-$FFFF)
 *
 * Reset vector at $FFFC/$FFFD is used to set the initial PC on startup.
 *
 * Build (requires asm65c02.c in the same directory):
 *   gcc -O2 -o sim65c02 sim65c02.c
 *
 * The assembler (asm65c02.c) is #included directly — no Python required.
 *
 * Usage:
 *   sim65c02 <file.asm | file.bin> [options]
 *   sim65c02 --help
 *
 * Options:
 *   --input "line"     Queue a line of input (CR appended); repeatable.
 *                      Multiple --input flags are consumed in order, simulating
 *                      a user typing at the terminal.  Max total 4096 bytes.
 *                      Takes precedence over stdin (see below) whenever given.
 *   --maxcycles N      Cycle limit before forced exit (default 500 000 000).
 *                      N=0 means UNLIMITED: no cycle cap and no automatic
 *                      GETCH-idle-exhaustion exit either (see GETCH/PUTCH
 *                      section below) -- the only ways out are a program-
 *                      driven halt (BRK/unknown opcode/watchpoint) or
 *                      Ctrl-C, which now exits gracefully and still prints
 *                      --stats/-m output (see Ctrl-C section below).
 *   --verbose          Print every instruction as it executes.  Very slow;
 *                      intended for single-instruction debugging only.
 *   --stats            Print cycle count and key zero-page values on exit.
 *   --load-addr 0xNNNN Override auto-detected load address for .bin files.
 *   --getch-addr 0xNNNN Override the GETCH (input poll) port address
 *                      (default $E004). See GETCH/PUTCH section below.
 *   --putch-addr 0xNNNN Override the PUTCH (character output) port address
 *                      (default $E001). See GETCH/PUTCH section below.
 *   -w 0xADDR          Write watchpoint: log every write to address to stderr,
 *                      continue running. Repeatable.
 *   -W 0xADDR          Write watchpoint: log to stderr and halt on first write.
 *                      Repeatable.\n"
 *   -m 0xADDR LEN      Dump LEN bytes from address to stderr at exit/halt.
 *                      Up to 4 -m options.
 *   -D NAME            Predefine NAME as 1 for the assembler's .IF directive,
 *                      as if "NAME = 1" appeared before the source file.
 *                      Only applies to a .asm input -- ignored (with a
 *                      warning) if given with a .bin file. Repeatable.
 *   -D NAME=EXPR       Predefine NAME as EXPR (decimal, $hex, %binary, etc).
 *                      Earlier -D flags on the same command line are
 *                      visible to later ones, e.g. -D A=1 -D B=A+1 but not code.
 *   --help             Print this help and exit.
 *
 * TYPICAL INVOCATION
 *
 *   ./sim65c02 ubasic.asm --input "PRINT 42"
 *   ./sim65c02 minibasic.asm --input "NEW" --input "10 PRINT 1+1" --input "RUN"
 *   ./sim65c02 ubasic.bin --load-addr 0xF800 --input "PRINT 42"
 *   ./sim65c02 ubasic.asm -w 0x08 -w 0x04 --input \"PRINT 1\" -m 0x08 2
 *   ./sim65c02 minibasic.asm < test_script.txt
 *       (test_script.txt is a plain text file of BASIC lines/commands, one
 *        per line -- see "Input source" below.
 *
 * File types:
 *   .asm   Assembled in-process via the embedded asm65c02 assembler.
 *   .bin   Loaded as a raw binary.  Load address auto-detected from size:
 *            2048 bytes → $F800  (uBASIC)
 *            4096 bytes → $F000  (miniBASIC)
 *           65536 bytes → verbatim full-image load
 *           other size  → placed at top of 64 KB (0x10000 - size)
 *          Override with --load-addr if needed.
 *
 * NOTES
 * 
 * Kowalski virtual I/O ports:
 *   $E000  write  TERMINAL_CLS    clear screen (ANSI ESC[2J + home)
 *   $E001  write  PUTCH           character output to stdout (configurable,
 *                                 see GETCH/PUTCH section below)
 *   $E004  read   GETCH           non-blocking poll; returns 0 if no char
 *                                 (configurable, see below)
 *   $E005  write  TERMINAL_X_POS  set cursor column (0-based, ANSI CSI)
 *   $E006  write  TERMINAL_Y_POS  set cursor row    (0-based, ANSI CSI)
 *   $E007  write  IO_IRQ          any write triggers a maskable hardware IRQ
 *
 * GETCH/PUTCH addresses and idle-exhaustion detection (v8):
 *   GETCH ($E004 by default) and PUTCH ($E001 by default) are intercepted
 *   to emulate character IO. Override with --getch-addr and --putch-addr 
 *   to map elsewhere, regardless of ASM or bin file.
 *
 *   Idle-exhaustion: every read of the GETCH address that finds no
 *   character available (queued-buffer empty, or stdin at EOF in live
 *   mode -- see below) increments a counter (reset to 0 the moment a
 *   real character is returned); once that counter passes 50 000
 *   consecutive empty reads, the simulator concludes input is exhausted
 *   and terminates gracefully. This check is skipped --maxcycles 0 sets
 *   unlimited mode is, Ctrl-C is the only way out short of a program-
 *   driven halt.
 *
 * Input source: --input queue vs. live stdin (v8):
 *   If --input supplied anything at all (even --input ""), that queued
 *   buffer is used exactly as before -- a non-blocking drain, 0 returned
 *   once empty. --input ALWAYS takes precedence when given.
 *
 *   A terminal's Enter key (or a text file's line ending) sends LF; 
 *   translated to CR here to match the line-ending convention the BASIC
 *   ROMs expect..
 *
 *   Once stdin hits EOF, every later fgetc() returns EOF immediately (no
 *   re-blocking), so clicks up and fires.  Hence a redirected/piped-input
 *   with --maxcycles 0 will busy spin forever until Ctrl-C. This also
 *   applies if the script  never ends (e.g. GOTO 10 loop) 
 */

 /*
 * VERSION HISTORY (Newest First)
 *
 * v11 — Conditional-Assembly Predefines
 *   - ADDED: -D NAME / -D NAME=EXPR command-line flags, forwarded straight
 *     into the embedded assembler typically used with .IF directive. 
 *   - -D is a no-op for .bin files with a warning.
 * 
 * v10 — Opcode Completeness
 *   - FIXED: Added missing execution mapping for CMP (zp) ($D2) zero-page 
 *     indirect addressing mode to align with other core arithmetic opcodes.
 *
 * v9 — CLI Streamlining
 *   - REMOVED: Redundant --mandelbrot and --plain flags now that full native 
 *     stdin redirection (`sim65c02 rom.asm < script.txt`) is supported.
 *   - ADDED: Explicit documentation for stdin test-script pipelining.
 *
 * v8 — Core I/O Overhaul & Execution Engine Updates
 *   - ADDED: Opcode execution support for CMP abs,Y ($D9), CMP (zp,X) ($C1), 
 *     and absolute indexed X variants for LSR, ROL, ROR, and LDY ($5E/$3E/$7E/$BC).
 *   - CHANGED: Replaced fragile ROM signature polling loops with robust, 
 *     address-configurable hooks via --getch-addr and --putch-addr inside rd()/wr().
 *   - CHANGED: --maxcycles 0 now specifies unlimited execution.
 *   - ADDED: Real-time, blocking stdin fallback (with LF->CR translation) when 
 *     the --input buffer queue is exhausted or omitted.
 *   - ADDED: SIGINT (Ctrl-C) trap handler for graceful exits and telemetry dumping.
 *   - FIXED: Tied idle-exhaustion detection directly to explicit GETCH activity 
 *     rather than static PC tracking.
 *
 * v7 — Diagnostic Monitoring
 *   - ADDED: -w and -W watchpoint tracking switches routed directly to stderr.
 *
 * v6 — UX & Documentation Refreshes
 *   - ADDED: Comprehensive inline option documentation and the --help CLI flag.
 *
 * v5 — Toolchain Native Integration
 *   - CHANGED: Migrated the external Python assembler compilation pipeline 
 *     to a direct C `#include "asm65c02.c"` block, removing the Python runtime dependency.
 *
 * v4 — Loader Stability
 *   - ADDED: Automated ROM base-address detection inferred from source file size.
 *   - FIXED: Corrected target initialization bugs within the --load-addr driver.
 *   - CLEANUP: General codebase maintenance and repository archive archiving.
 *
 * v3 — Instrumentation Interface
 *   - ADDED: Preliminary diagnostics tracking flags: --mandelbrot, --input, 
 *     --maxcycles, and --stats.
 *   - ADDED: Experimental automated GETCH trapping hooks.
 *
 * v2 — Control Architecture Support
 *   - ADDED: Support for GOSUB/RETURN and FOR/NEXT loops to enable 4K BASIC compatibility.
 *
 * v1 — Prototype Release
 *   - Initial execution framework deployed for microbasic and uBASIC environments.
 * =============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdint.h>
#include <ctype.h>

/* ── embedded assembler ──────────────────────────────────────────────────── */
/* asm65c02.c is included here directly; it uses sim's mem[] array.
   Do NOT define ASM65C02_MAIN — we only want the assembler internals,
   not its standalone main(). */
#include "asm65c02.c"

/* ── input queue ─────────────────────────────────────────────────────────── */
#define INBUF_MAX 4096
static char  inbuf[INBUF_MAX];
static int   inbuf_len = 0;
static int   inbuf_pos = 0;

static uint8_t getch_poll(void) {
    /* peek: return next char without consuming if available, else 0 */
    if (inbuf_pos < inbuf_len)
        return (uint8_t)inbuf[inbuf_pos];
    return 0;
}

static uint8_t getch_consume(void) {
    if (inbuf_pos < inbuf_len)
        return (uint8_t)inbuf[inbuf_pos++];
    return 0;
}

/* ── terminal cursor state (for PRINT AT support) ────────────────────────── */
static int term_col = 0;     /* current cursor column (0-based) */
static int term_row = 0;     /* current cursor row    (0-based) */

/* ── memory ─────────────────────────────────────────────────────────────── */
uint8_t mem[65536];   /* shared with embedded asm65c02.c */

/* Pending hardware IRQ: set by write to $E007, consumed by main loop */
static int pending_irq = 0;

/*
 * g_stop_requested (v8)
 *   Set by on_sigint() when the user presses Ctrl-C. Checked by the main
 *   run loop's condition so a Ctrl-C produces a graceful loop exit
 *   (falls through to the normal --stats/dump reporting code) instead of
 *   the OS's abrupt default SIGINT termination. Declared volatile
 *   sig_atomic_t per the standard signal-handler-safety requirement --
 *   this is the only variable touched inside the handler.
 *   Safe to rely on default-terminate semantics being bypassed here:
 *   the simulator never writes to disk during the run loop (only at
 *   startup, loading the ROM/source), so there is nothing that could be
 *   left half-written by interrupting mid-run.
 */
static volatile sig_atomic_t g_stop_requested = 0;

/*
 * on_sigint (v8)  --  SIGINT handler; see g_stop_requested comment above.
 *   In:  sig (unused, required by signal() handler signature)
 *   Out: none
 *   Clobbers: g_stop_requested
 */
static void on_sigint(int sig) {
    (void)sig;
    g_stop_requested = 1;
}

/* ── write watchpoints (-w log-only, -W log+halt) and post-halt dumps (-m) ── */
#define MAX_WATCH 16
static uint16_t watch_addr[MAX_WATCH];
static int      watch_halt[MAX_WATCH];   /* 0 = -w, 1 = -W */
static int      nwatch = 0;
static int      watch_triggered  = 0;    /* set when a -W watchpoint fires */
static uint16_t watch_trigger_addr = 0;
static uint8_t  watch_trigger_val  = 0;
static uint16_t watch_trigger_pc   = 0;

#define MAX_DUMP 4
static uint16_t dump_addr[MAX_DUMP];
static int      dump_len[MAX_DUMP];
static int      ndump = 0;

static uint16_t cur_instr_pc = 0;   /* PC of the instruction currently executing; set by step() */

static void check_watch(uint16_t a, uint8_t v) {
    for (int i = 0; i < nwatch; i++) {
        if (watch_addr[i] == a) {
            fprintf(stderr, "[WATCH] $%04X <- $%02X  (PC=$%04X)\n", a, v, cur_instr_pc);
            if (watch_halt[i] && !watch_triggered) {
                watch_triggered    = 1;
                watch_trigger_addr = a;
                watch_trigger_val  = v;
                watch_trigger_pc   = cur_instr_pc;
            }
        }
    }
}

/*
 * io_getch_addr / io_putch_addr (v8)
 *   Configurable Kowalski-convention I/O port addresses. Default to the
 *   traditional $E004 (GETCH, read)/$E001 (PUTCH, write), overridable via
 *   --getch-addr/--putch-addr for ROMs that map these ports elsewhere.
 *   Only these two ports are configurable; CLS/cursor-pos/IRQ ($E000,
 *   $E005-$E007) remain fixed, matching the scope of what was asked for.
 */
static uint16_t io_getch_addr = 0xE004;
static uint16_t io_putch_addr = 0xE001;

/*
 * use_live_stdin (v8)
 *   Set once, after CLI parsing, before the run loop starts. True when
 *   --input supplied no queued input (inbuf_len==0) -- i.e. --input
 *   always takes precedence over stdin when given (even --input ""
 *   appends a CR, so this check is unambiguous). When true, rd()'s
 *   GETCH handling reads real stdin via a blocking fgetc() per poll
 *   instead of draining the pre-queued inbuf[] buffer -- see rd()'s
 *   header comment for the read model. No isatty() check is performed:
 *   stdin is always attempted in this mode, whether it's a live
 *   terminal, a pipe, or a redirected file.
 */
static int use_live_stdin = 0;

/*
 * getch_idle (v8)
 *   Consecutive-empty-read counter for the configured GETCH address,
 *   maintained directly inside rd() at the point of the actual I/O
 *   event, rather than by matching the CPU's PC against a separately
 *   located "spin loop address" (the old approach required scanning ROM
 *   for a specific byte pattern to find where the poll loop lived in
 *   code; this one doesn't care how the polling loop is written, only
 *   whether the input port is being read with nothing available).
 *   Incremented each time rd(io_getch_addr) is called and the input
 *   queue is empty (queued-buffer mode) or stdin is at EOF (live-stdin
 *   mode); reset to 0 the moment a real character is returned. Read by
 *   the main loop in main() to detect "input exhausted" and terminate
 *   gracefully (see maxcycles==0 handling there for how this interacts
 *   with unbounded runs -- unaffected by which input source is active).
 */
static long long getch_idle = 0;

/*
 * rd (v8 -- GETCH read model)
 *   Memory read, intercepting the configured GETCH address.
 *   In:  a -- address being read
 *   Out: byte value; for GETCH, either a real character or 0 ("no
 *        character available right now")
 *   Clobbers: getch_idle; in live-stdin mode, consumes one byte from
 *             stdin per GETCH read (blocking -- see use_live_stdin)
 *
 *   Two input sources, chosen once at startup via use_live_stdin:
 *     - Queued buffer (--input given): unchanged from before --
 *       non-blocking drain of inbuf[], 0 when exhausted.
 *     - Live stdin (--input not given): each GETCH poll performs a REAL
 *       BLOCKING fgetc(stdin) read. This means a single 6502 "cycle" can
 *       now take arbitrary wall-clock time while waiting for the user to
 *       type -- intentional, this is what makes typing while the
 *       emulated program runs possible. A terminal's Enter key sends LF
 *       ('\n'); translated to CR ('\r') here to match the line-ending
 *       convention the BASIC ROMs expect (same one --input's CR-append
 *       already uses). Once stdin hits EOF, every subsequent fgetc()
 *       call returns EOF immediately (standard C stdio behavior, no
 *       re-blocking), so getch_idle races up and the normal exhaustion
 *       path fires shortly after -- still subject to being disabled by
 *       --maxcycles 0 like any other exhaustion, so a piped-input run
 *       with --maxcycles 0 will busy-spin on instant EOF reads until
 *       Ctrl-C rather than exit on its own; this is a known, accepted
 *       consequence of "0 means unlimited, no exceptions" and not a bug.
 */
static uint8_t rd(uint16_t a) {
    if (a == io_getch_addr) {
        if (use_live_stdin) {
            int c = fgetc(stdin);
            if (c == EOF) { getch_idle++; return 0; }
            getch_idle = 0;
            if (c == '\n') c = '\r';   /* terminal Enter -> BASIC CR convention */
            return (uint8_t)c;
        }
        /* poll: if char available consume and return it, else 0 */
        if (inbuf_pos < inbuf_len) {
            getch_idle = 0;
            return (uint8_t)inbuf[inbuf_pos++];
        }
        getch_idle++;
        return 0;
    }
    return mem[a];
}

static void wr(uint16_t a, uint8_t v) {
    check_watch(a, v);
    if (a == io_putch_addr) {   /* PUTCH: character output */
        putchar(v);
        fflush(stdout);
        return;
    }
    switch (a) {
    case 0xE000:             /* TERMINAL_CLS: clear screen and home cursor */
        fputs("\033[2J\033[H", stdout); fflush(stdout);
        term_col = 0; term_row = 0;
        return;
    case 0xE005:             /* TERMINAL_X_POS: set cursor column ($E005) */
        term_col = v;
        printf("\033[%d;%dH", term_row + 1, term_col + 1); fflush(stdout);
        return;
    case 0xE006:             /* TERMINAL_Y_POS: set cursor row ($E006) */
        term_row = v;
        printf("\033[%d;%dH", term_row + 1, term_col + 1); fflush(stdout);
        return;
    case 0xE007:             /* IO_IRQ: any write triggers a maskable hardware IRQ */
        pending_irq = 1;
        return;
    default:
        mem[a] = v;
    }
}

/* ── CPU state ───────────────────────────────────────────────────────────── */
typedef struct {
    uint16_t PC;
    uint8_t  A, X, Y, SP;
    /* flags */
    uint8_t  N, V, D, I, Z, C; /* each 0 or 1 */
} CPU;

#define PUSH(cpu,v)  do { uint8_t _pv=(v); check_watch((uint16_t)(0x100+(cpu)->SP), _pv); mem[0x100 + (cpu)->SP--] = _pv; } while(0)
#define POP(cpu)     mem[0x100 + ++(cpu)->SP]

static uint8_t pack_flags(CPU *cpu) {
    return (cpu->N<<7)|(cpu->V<<6)|(1<<5)|(1<<4)|
           (cpu->D<<3)|(cpu->I<<2)|(cpu->Z<<1)|(cpu->C);
}
static void unpack_flags(CPU *cpu, uint8_t p) {
    cpu->N=(p>>7)&1; cpu->V=(p>>6)&1;
    cpu->D=(p>>3)&1; cpu->I=(p>>2)&1;
    cpu->Z=(p>>1)&1; cpu->C=p&1;
}

static void set_nz(CPU *cpu, uint8_t v) {
    cpu->N = (v>>7)&1;
    cpu->Z = (v==0);
}

/* ── address mode helpers ────────────────────────────────────────────────── */
static uint16_t zp(uint16_t pc)          { return mem[pc]; }
static uint16_t zpx(CPU *c, uint16_t pc) { return (mem[pc]+c->X)&0xFF; }
static uint16_t zpy(CPU *c, uint16_t pc) { return (mem[pc]+c->Y)&0xFF; }
static uint16_t ab(uint16_t pc)          { return mem[pc]|(mem[pc+1]<<8); }
static uint16_t abx(CPU *c,uint16_t pc)  { return (mem[pc]|(mem[pc+1]<<8))+c->X; }
static uint16_t aby(CPU *c,uint16_t pc)  { return (mem[pc]|(mem[pc+1]<<8))+c->Y; }
static uint16_t indy(CPU *c,uint16_t pc) {
    uint8_t z=mem[pc];
    return (mem[z]|(mem[(z+1)&0xFF]<<8))+c->Y;
}
static uint16_t indx(CPU *c,uint16_t pc) { /* (zp,X) */
    uint8_t z=(mem[pc]+c->X)&0xFF;
    return mem[z]|(mem[(z+1)&0xFF]<<8);
}
static uint16_t indzp(uint16_t pc) { /* 65C02: (zp) — zero-page indirect, no index */
    uint8_t z=mem[pc];
    return mem[z]|(mem[(z+1)&0xFF]<<8);
}
static uint16_t ind(uint16_t pc) { /* (abs) */
    uint16_t a=mem[pc]|(mem[pc+1]<<8);
    return mem[a]|(mem[a+1]<<8);
}

/* ── ADC / SBC helpers ───────────────────────────────────────────────────── */
static void do_adc(CPU *cpu, uint8_t v) {
    uint16_t r = cpu->A + v + cpu->C;
    cpu->V = (~(cpu->A ^ v) & (cpu->A ^ r) & 0x80) ? 1 : 0;

    if (!cpu->D) {
        cpu->C = (r > 0xFF) ? 1 : 0;
        cpu->A = r & 0xFF;
        set_nz(cpu, cpu->A);
        return;
    }

    int lo = (cpu->A & 0x0F) + (v & 0x0F) + cpu->C;
    int hi = (cpu->A >> 4) + (v >> 4);

    if (lo > 9) {
        lo += 6;
        hi += 1;
    }
    if (hi > 9) {
        hi += 6;
    }

    cpu->C = (hi > 0x0F) ? 1 : 0;
    cpu->A = (uint8_t)(((hi << 4) | (lo & 0x0F)) & 0xFF);
    set_nz(cpu, cpu->A);
}
static void do_sbc(CPU *cpu, uint8_t v) {
    uint16_t r = (uint16_t)cpu->A - v - (cpu->C ? 0 : 1);
    cpu->V = ((cpu->A ^ v) & (cpu->A ^ r) & 0x80) ? 1 : 0;

    if (!cpu->D) {
        cpu->C = (r < 0x100) ? 1 : 0;
        cpu->A = (uint8_t)(r & 0xFF);
        set_nz(cpu, cpu->A);
        return;
    }

    int lo = (cpu->A & 0x0F) - (v & 0x0F) - (cpu->C ? 0 : 1);
    int hi = (cpu->A >> 4) - (v >> 4);

    if (lo < 0) {
        lo -= 6;
        hi -= 1;
    }
    if (hi < 0) {
        hi -= 6;
    }

    cpu->C = (r < 0x100) ? 1 : 0;
    cpu->A = (uint8_t)((((uint8_t)hi) << 4) | (lo & 0x0F));
    set_nz(cpu, cpu->A);
}
static void do_cmp(CPU *cpu, uint8_t reg, uint8_t v) {
    uint16_t r = reg - v;
    cpu->C = (reg>=v)?1:0;
    set_nz(cpu, r&0xFF);
}

/* ── branch helper ───────────────────────────────────────────────────────── */
static uint16_t branch(uint16_t pc, uint8_t off) {
    return pc + (int8_t)off;
}

/* ── BBR/BBS (65C02 bit-branch) ──────────────────────────────────────────── */
/* opcode format: zp, rel  (2 extra bytes after opcode) */

/* ── single step ─────────────────────────────────────────────────────────── */
static long long cycle_count = 0;

/* returns 0=ok, 1=BRK/unknown */
static int step(CPU *cpu) {
    uint16_t pc = cpu->PC;
    cur_instr_pc = pc;
    uint8_t  op = mem[pc];
    cpu->PC++;
    cycle_count++;

#define RD(a)    rd(a)
#define WR(a,v)  wr(a,v)
#define IMM      mem[cpu->PC]
#define ZP       zp(cpu->PC)
#define ZPX      zpx(cpu,cpu->PC)
#define ZPY      zpy(cpu,cpu->PC)
#define ABS      ab(cpu->PC)
#define ABSX     abx(cpu,cpu->PC)
#define ABSY     aby(cpu,cpu->PC)
#define INDY     indy(cpu,cpu->PC)
#define INDX     indx(cpu,cpu->PC)
#define INDZP    indzp(cpu->PC)      /* 65C02: (zp) zero-page indirect no index */
#define IND      ind(cpu->PC)
#define REL      branch(cpu->PC+1, mem[cpu->PC])

    switch(op) {
    /* ── BRK ── */
    case 0x00: return 1;

    /* ── NOP ── */
    case 0xEA: return 0;

    /* ── LDA ── */
    case 0xA9: cpu->A=IMM;         cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0xA5: cpu->A=RD(ZP);      cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0xB5: cpu->A=RD(ZPX);     cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0xAD: cpu->A=RD(ABS);     cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0xBD: cpu->A=RD(ABSX);    cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0xB9: cpu->A=RD(ABSY);    cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0xB1: cpu->A=RD(INDY);    cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0xA1: cpu->A=RD(INDX);    cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0xB2: cpu->A=RD(INDZP);   cpu->PC+=1; set_nz(cpu,cpu->A); return 0; /* 65C02 */

    /* ── LDX ── */
    case 0xA2: cpu->X=IMM;       cpu->PC+=1; set_nz(cpu,cpu->X); return 0;
    case 0xA6: cpu->X=RD(ZP);    cpu->PC+=1; set_nz(cpu,cpu->X); return 0;
    case 0xB6: cpu->X=RD(ZPY);   cpu->PC+=1; set_nz(cpu,cpu->X); return 0;
    case 0xAE: cpu->X=RD(ABS);   cpu->PC+=2; set_nz(cpu,cpu->X); return 0;
    case 0xBE: cpu->X=RD(ABSY);  cpu->PC+=2; set_nz(cpu,cpu->X); return 0;

    /* ── LDY ── */
    case 0xA0: cpu->Y=IMM;       cpu->PC+=1; set_nz(cpu,cpu->Y); return 0;
    case 0xA4: cpu->Y=RD(ZP);    cpu->PC+=1; set_nz(cpu,cpu->Y); return 0;
    case 0xB4: cpu->Y=RD(ZPX);   cpu->PC+=1; set_nz(cpu,cpu->Y); return 0;
    case 0xAC: cpu->Y=RD(ABS);   cpu->PC+=2; set_nz(cpu,cpu->Y); return 0;
    /* v8: LDY abs,X -- newly reachable now that asm65c02.c (v1.9) can
     * emit it; previously unassemblable so unneeded here. */
    case 0xBC: cpu->Y=RD(ABSX);  cpu->PC+=2; set_nz(cpu,cpu->Y); return 0;

    /* ── STA ── */
    case 0x85: WR(ZP,   cpu->A); cpu->PC+=1; return 0;
    case 0x95: WR(ZPX,  cpu->A); cpu->PC+=1; return 0;
    case 0x8D: WR(ABS,  cpu->A); cpu->PC+=2; return 0;
    case 0x9D: WR(ABSX, cpu->A); cpu->PC+=2; return 0;
    case 0x99: WR(ABSY, cpu->A); cpu->PC+=2; return 0;
    case 0x91: WR(INDY, cpu->A); cpu->PC+=1; return 0;
    case 0x81: WR(INDX, cpu->A); cpu->PC+=1; return 0;
    case 0x92: WR(INDZP,cpu->A); cpu->PC+=1; return 0; /* 65C02: STA (zp) */

    /* ── STX ── */
    case 0x86: WR(ZP,  cpu->X); cpu->PC+=1; return 0;
    case 0x96: WR(ZPY, cpu->X); cpu->PC+=1; return 0;
    case 0x8E: WR(ABS, cpu->X); cpu->PC+=2; return 0;

    /* ── STY ── */
    case 0x84: WR(ZP,  cpu->Y); cpu->PC+=1; return 0;
    case 0x94: WR(ZPX, cpu->Y); cpu->PC+=1; return 0;
    case 0x8C: WR(ABS, cpu->Y); cpu->PC+=2; return 0;

    /* ── STZ (65C02) ── */
    case 0x64: WR(ZP,  0); cpu->PC+=1; return 0;
    case 0x74: WR(ZPX, 0); cpu->PC+=1; return 0;
    case 0x9C: WR(ABS, 0); cpu->PC+=2; return 0;
    case 0x9E: WR(ABSX,0); cpu->PC+=2; return 0;

    /* ── Transfer ── */
    case 0xAA: cpu->X=cpu->A; set_nz(cpu,cpu->X); return 0;
    case 0xA8: cpu->Y=cpu->A; set_nz(cpu,cpu->Y); return 0;
    case 0x8A: cpu->A=cpu->X; set_nz(cpu,cpu->A); return 0;
    case 0x98: cpu->A=cpu->Y; set_nz(cpu,cpu->A); return 0;
    case 0xBA: cpu->X=cpu->SP; set_nz(cpu,cpu->X); return 0;
    case 0x9A: cpu->SP=cpu->X; return 0;

    /* ── Stack ── */
    case 0x48: PUSH(cpu,cpu->A); return 0;
    case 0x68: cpu->A=POP(cpu); set_nz(cpu,cpu->A); return 0;
    case 0x08: PUSH(cpu,pack_flags(cpu)); return 0;
    case 0x28: unpack_flags(cpu,POP(cpu)); return 0;
    case 0xDA: PUSH(cpu,cpu->X); return 0;  /* PHX 65C02 */
    case 0xFA: cpu->X=POP(cpu); set_nz(cpu,cpu->X); return 0; /* PLX */
    case 0x5A: PUSH(cpu,cpu->Y); return 0;  /* PHY 65C02 */
    case 0x7A: cpu->Y=POP(cpu); set_nz(cpu,cpu->Y); return 0; /* PLY */

    /* ── INC/DEC register (65C02) ── */
    case 0x1A: cpu->A++; set_nz(cpu,cpu->A); return 0; /* INC A */
    case 0x3A: cpu->A--; set_nz(cpu,cpu->A); return 0; /* DEC A */
    case 0xE8: cpu->X++; set_nz(cpu,cpu->X); return 0;
    case 0xCA: cpu->X--; set_nz(cpu,cpu->X); return 0;
    case 0xC8: cpu->Y++; set_nz(cpu,cpu->Y); return 0;
    case 0x88: cpu->Y--; set_nz(cpu,cpu->Y); return 0;

    /* ── INC/DEC memory ── */
    case 0xE6: { uint8_t v=mem[ZP]+1;  WR(ZP, v);  cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0xF6: { uint8_t v=mem[ZPX]+1; WR(ZPX,v);  cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0xEE: { uint8_t v=RD(ABS)+1;  WR(ABS,v);  cpu->PC+=2; set_nz(cpu,v); return 0; }
    case 0xFE: { uint8_t v=RD(ABSX)+1; WR(ABSX,v); cpu->PC+=2; set_nz(cpu,v); return 0; }
    case 0xC6: { uint8_t v=mem[ZP]-1;  WR(ZP, v);  cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0xD6: { uint8_t v=mem[ZPX]-1; WR(ZPX,v);  cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0xCE: { uint8_t v=RD(ABS)-1;  WR(ABS,v);  cpu->PC+=2; set_nz(cpu,v); return 0; }
    case 0xDE: { uint8_t v=RD(ABSX)-1; WR(ABSX,v); cpu->PC+=2; set_nz(cpu,v); return 0; }

    /* ── ADC ── */
    case 0x69: do_adc(cpu,IMM);        cpu->PC+=1; return 0;
    case 0x65: do_adc(cpu,RD(ZP));     cpu->PC+=1; return 0;
    case 0x75: do_adc(cpu,RD(ZPX));    cpu->PC+=1; return 0;
    case 0x6D: do_adc(cpu,RD(ABS));    cpu->PC+=2; return 0;
    case 0x7D: do_adc(cpu,RD(ABSX));   cpu->PC+=2; return 0;
    case 0x79: do_adc(cpu,RD(ABSY));   cpu->PC+=2; return 0;
    case 0x71: do_adc(cpu,RD(INDY));   cpu->PC+=1; return 0;
    case 0x61: do_adc(cpu,RD(INDX));   cpu->PC+=1; return 0;
    case 0x72: do_adc(cpu,RD(INDZP));  cpu->PC+=1; return 0; /* 65C02: ADC (zp) */

    /* ── SBC ── */
    case 0xE9: do_sbc(cpu,IMM);        cpu->PC+=1; return 0;
    case 0xE5: do_sbc(cpu,RD(ZP));     cpu->PC+=1; return 0;
    case 0xF5: do_sbc(cpu,RD(ZPX));    cpu->PC+=1; return 0;
    case 0xED: do_sbc(cpu,RD(ABS));    cpu->PC+=2; return 0;
    case 0xFD: do_sbc(cpu,RD(ABSX));   cpu->PC+=2; return 0;
    case 0xF9: do_sbc(cpu,RD(ABSY));   cpu->PC+=2; return 0;
    case 0xF1: do_sbc(cpu,RD(INDY));   cpu->PC+=1; return 0;
    case 0xF2: do_sbc(cpu,RD(INDZP));  cpu->PC+=1; return 0; /* 65C02: SBC (zp) */

    /* ── AND ── */
    case 0x29: cpu->A&=IMM;        cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x25: cpu->A&=RD(ZP);     cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x35: cpu->A&=RD(ZPX);    cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x2D: cpu->A&=RD(ABS);    cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x31: cpu->A&=RD(INDY);   cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x32: cpu->A&=RD(INDZP);  cpu->PC+=1; set_nz(cpu,cpu->A); return 0; /* 65C02 */

    /* ── ORA ── */
    case 0x09: cpu->A|=IMM;        cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x05: cpu->A|=RD(ZP);     cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x15: cpu->A|=RD(ZPX);    cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x0D: cpu->A|=RD(ABS);    cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x11: cpu->A|=RD(INDY);   cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x12: cpu->A|=RD(INDZP);  cpu->PC+=1; set_nz(cpu,cpu->A); return 0; /* 65C02 */

    /* ── EOR ── */
    case 0x49: cpu->A^=IMM;        cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x45: cpu->A^=RD(ZP);     cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x55: cpu->A^=RD(ZPX);    cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x4D: cpu->A^=RD(ABS);    cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x51: cpu->A^=RD(INDY);   cpu->PC+=1; set_nz(cpu,cpu->A); return 0;
    case 0x52: cpu->A^=RD(INDZP);  cpu->PC+=1; set_nz(cpu,cpu->A); return 0; /* 65C02 */

    /* ── CMP ── */
    case 0xC9: do_cmp(cpu,cpu->A,IMM);      cpu->PC+=1; return 0;
    case 0xC5: do_cmp(cpu,cpu->A,RD(ZP));   cpu->PC+=1; return 0;
    case 0xD5: do_cmp(cpu,cpu->A,RD(ZPX));  cpu->PC+=1; return 0;
    case 0xCD: do_cmp(cpu,cpu->A,RD(ABS));  cpu->PC+=2; return 0;
    case 0xD1: do_cmp(cpu,cpu->A,RD(INDY)); cpu->PC+=1; return 0;
    case 0xDD: do_cmp(cpu,cpu->A,RD(ABSX)); cpu->PC+=2; return 0;
    /* v8: CMP abs,Y and CMP (zp,X) -- newly reachable now that asm65c02.c
     * (v1.9) can emit them; previously unassemblable so unneeded here. */
    case 0xD9: do_cmp(cpu,cpu->A,RD(ABSY)); cpu->PC+=2; return 0;
    case 0xC1: do_cmp(cpu,cpu->A,RD(INDX)); cpu->PC+=1; return 0;
    case 0xD2: do_cmp(cpu,cpu->A,RD(INDZP));cpu->PC+=1; return 0; /* 65C02: CMP (zp) */

    /* ── CPX ── */
    case 0xE0: do_cmp(cpu,cpu->X,IMM);    cpu->PC+=1; return 0;
    case 0xE4: do_cmp(cpu,cpu->X,RD(ZP)); cpu->PC+=1; return 0;
    case 0xEC: do_cmp(cpu,cpu->X,RD(ABS));cpu->PC+=2; return 0;

    /* ── CPY ── */
    case 0xC0: do_cmp(cpu,cpu->Y,IMM);    cpu->PC+=1; return 0;
    case 0xC4: do_cmp(cpu,cpu->Y,RD(ZP)); cpu->PC+=1; return 0;
    case 0xCC: do_cmp(cpu,cpu->Y,RD(ABS));cpu->PC+=2; return 0;

    /* ── EOR (missing abs,x abs,y) ── */
    case 0x5D: cpu->A^=RD(ABSX); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x59: cpu->A^=RD(ABSY); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;

    /* ── AND abs,x abs,y ── */
    case 0x3D: cpu->A&=RD(ABSX); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x39: cpu->A&=RD(ABSY); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;

    /* ── ORA abs,x abs,y ── */
    case 0x1D: cpu->A|=RD(ABSX); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;
    case 0x19: cpu->A|=RD(ABSY); cpu->PC+=2; set_nz(cpu,cpu->A); return 0;

    case 0x06: { uint8_t v=mem[ZP]; cpu->C=v>>7; v<<=1; WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x16: { uint8_t v=mem[ZPX];cpu->C=v>>7; v<<=1; WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x0E: { uint8_t v=RD(ABS); cpu->C=v>>7; v<<=1; WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }
    case 0x1E: { uint8_t v=RD(ABSX);cpu->C=v>>7; v<<=1; WR(ABSX,v);cpu->PC+=2;set_nz(cpu,v); return 0; }

    /* ── LSR ── */
    /* ── ASL ── */
    case 0x0A: cpu->C=(cpu->A>>7); cpu->A<<=1; set_nz(cpu,cpu->A); return 0;
    case 0x4A: cpu->C=cpu->A&1; cpu->A>>=1; set_nz(cpu,cpu->A); return 0; /* LSR A */
    case 0x46: { uint8_t v=mem[ZP]; cpu->C=v&1; v>>=1; WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x56: { uint8_t v=mem[ZPX];cpu->C=v&1; v>>=1; WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x4E: { uint8_t v=RD(ABS); cpu->C=v&1; v>>=1; WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }
    /* v8: LSR abs,X -- newly reachable now that asm65c02.c (v1.9) can
     * emit it; previously unassemblable so unneeded here. */
    case 0x5E: { uint8_t v=RD(ABSX);cpu->C=v&1; v>>=1; WR(ABSX,v);cpu->PC+=2;set_nz(cpu,v); return 0; }

    /* ── ROL ── */
    case 0x2A: { uint8_t c=cpu->C; cpu->C=cpu->A>>7; cpu->A=(cpu->A<<1)|c; set_nz(cpu,cpu->A); return 0; }
    case 0x26: { uint8_t v=mem[ZP]; uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x36: { uint8_t v=mem[ZPX];uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x2E: { uint8_t v=RD(ABS); uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }
    /* v8: ROL abs,X -- see LSR abs,X note above. */
    case 0x3E: { uint8_t v=RD(ABSX);uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ABSX,v);cpu->PC+=2; set_nz(cpu,v); return 0; }

    /* ── ROR ── */
    case 0x6A: { uint8_t c=cpu->C; cpu->C=cpu->A&1; cpu->A=(cpu->A>>1)|(c<<7); set_nz(cpu,cpu->A); return 0; }
    case 0x66: { uint8_t v=mem[ZP]; uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x76: { uint8_t v=mem[ZPX];uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x6E: { uint8_t v=RD(ABS); uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }
    /* v8: ROR abs,X -- see LSR abs,X note above. */
    case 0x7E: { uint8_t v=RD(ABSX);uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ABSX,v);cpu->PC+=2; set_nz(cpu,v); return 0; }

    /* ── BIT ── */
    case 0x24: { uint8_t v=mem[ZP];  cpu->Z=((cpu->A&v)==0); cpu->N=(v>>7); cpu->V=(v>>6)&1; cpu->PC+=1; return 0; }
    case 0x2C: { uint8_t v=RD(ABS);  cpu->Z=((cpu->A&v)==0); cpu->N=(v>>7); cpu->V=(v>>6)&1; cpu->PC+=2; return 0; }
    case 0x89: { uint8_t v=IMM; cpu->Z=((cpu->A&v)==0); cpu->PC+=1; return 0; } /* BIT imm 65C02 */

    /* ── Branches ── */
    case 0x90: if(!cpu->C) cpu->PC=REL; else cpu->PC+=1; return 0; /* BCC */
    case 0xB0: if( cpu->C) cpu->PC=REL; else cpu->PC+=1; return 0; /* BCS */
    case 0xF0: if( cpu->Z) cpu->PC=REL; else cpu->PC+=1; return 0; /* BEQ */
    case 0xD0: if(!cpu->Z) cpu->PC=REL; else cpu->PC+=1; return 0; /* BNE */
    case 0x30: if( cpu->N) cpu->PC=REL; else cpu->PC+=1; return 0; /* BMI */
    case 0x10: if(!cpu->N) cpu->PC=REL; else cpu->PC+=1; return 0; /* BPL */
    case 0x50: if(!cpu->V) cpu->PC=REL; else cpu->PC+=1; return 0; /* BVC */
    case 0x70: if( cpu->V) cpu->PC=REL; else cpu->PC+=1; return 0; /* BVS */
    case 0x80: cpu->PC=REL; return 0;                               /* BRA 65C02 */

    /* ── BBR / BBS (65C02) ── bit-branch opcodes ──
       Format: opcode zp_addr rel_offset  (3 bytes total)
       BBRn: branch if bit n of mem[zp] == 0
       BBSn: branch if bit n of mem[zp] == 1  */
    case 0x0F: case 0x1F: case 0x2F: case 0x3F:
    case 0x4F: case 0x5F: case 0x6F: case 0x7F: {
        /* BBR0..BBR7 */
        int  bit = (op>>4)&7;
        uint8_t zp_addr = mem[cpu->PC];
        uint8_t rel     = mem[cpu->PC+1];
        cpu->PC += 2;
        if(!(mem[zp_addr] & (1<<bit))) cpu->PC = branch(cpu->PC, rel);
        return 0;
    }
    case 0x8F: case 0x9F: case 0xAF: case 0xBF:
    case 0xCF: case 0xDF: case 0xEF: case 0xFF: {
        /* BBS0..BBS7 */
        int  bit = (op>>4)&7;
        uint8_t zp_addr = mem[cpu->PC];
        uint8_t rel     = mem[cpu->PC+1];
        cpu->PC += 2;
        if(mem[zp_addr] & (1<<bit)) cpu->PC = branch(cpu->PC, rel);
        return 0;
    }

    /* ── RMB / SMB (65C02) ── */
    case 0x07: case 0x17: case 0x27: case 0x37:
    case 0x47: case 0x57: case 0x67: case 0x77: {
        int bit=(op>>4)&7; uint8_t a=mem[cpu->PC++]; mem[a]&=~(1<<bit); return 0;
    }
    case 0x87: case 0x97: case 0xA7: case 0xB7:
    case 0xC7: case 0xD7: case 0xE7: case 0xF7: {
        int bit=(op>>4)&7; uint8_t a=mem[cpu->PC++]; mem[a]|=(1<<bit); return 0;
    }

    /* ── JMP ── */
    case 0x4C: cpu->PC=ABS;  return 0;
    case 0x6C: cpu->PC=IND;  return 0;
    case 0x7C: { /* JMP (abs,X) 65C02 */
        uint16_t a=(mem[cpu->PC]|(mem[cpu->PC+1]<<8))+cpu->X;
        cpu->PC=mem[a]|(mem[a+1]<<8);
        return 0;
    }

    /* ── JSR / RTS / RTI ── */
    case 0x20: {
        uint16_t target=ABS;
        uint16_t ret=cpu->PC+1;
        PUSH(cpu,(ret>>8)&0xFF);
        PUSH(cpu,ret&0xFF);
        cpu->PC=target;
        return 0;
    }
    case 0x60: {
        uint8_t lo=POP(cpu), hi=POP(cpu);
        cpu->PC=((hi<<8)|lo)+1;
        return 0;
    }
    case 0x40: {
        unpack_flags(cpu,POP(cpu));
        uint8_t lo=POP(cpu), hi=POP(cpu);
        cpu->PC=(hi<<8)|lo;
        return 0;
    }

    /* ── Flags ── */
    case 0x18: cpu->C=0; return 0; /* CLC */
    case 0x38: cpu->C=1; return 0; /* SEC */
    case 0x58: cpu->I=0; return 0; /* CLI */
    case 0x78: cpu->I=1; return 0; /* SEI */
    case 0xB8: cpu->V=0; return 0; /* CLV */
    case 0xD8: cpu->D=0; return 0; /* CLD */
    case 0xF8: cpu->D=1; return 0; /* SED */

    /* ── TSB / TRB (65C02) ── */
    case 0x04: { uint8_t v=mem[ZP];  cpu->Z=((cpu->A&v)==0); WR(ZP, v|cpu->A);  cpu->PC+=1; return 0; }
    case 0x0C: { uint8_t v=RD(ABS);  cpu->Z=((cpu->A&v)==0); WR(ABS,v|cpu->A);  cpu->PC+=2; return 0; }
    case 0x14: { uint8_t v=mem[ZP];  cpu->Z=((cpu->A&v)==0); WR(ZP, v&~cpu->A); cpu->PC+=1; return 0; }
    case 0x1C: { uint8_t v=RD(ABS);  cpu->Z=((cpu->A&v)==0); WR(ABS,v&~cpu->A); cpu->PC+=2; return 0; }

    default:
        fprintf(stderr, "\n[SIM] Unknown opcode $%02X at $%04X\n", op, pc);
        return 1;
    }
}

/* ── load binary ─────────────────────────────────────────────────────────── */
static uint32_t bin_load_addr = 0xFFFFFFFF; /* sentinel = auto */

static int load_bin(const char *path) {
    FILE *f = fopen(path,"rb");
    if(!f) { perror(path); return -1; }
    fseek(f,0,SEEK_END);
    long sz=ftell(f); rewind(f);
    uint32_t base;
    if(bin_load_addr != 0xFFFFFFFF) {
        base = bin_load_addr;            /* explicit --load-addr */
    } else if(sz == 65536) {
        base = 0;                        /* full flat image: load verbatim */
    } else if(sz == 4096) {
        base = 0xF000;                   /* 4 KB ROM: 4K BASIC */
    } else {
        base = 0x10000 - (uint32_t)sz;  /* general: place at top of 64KB */
    }
    if(sz==65536) {
        fread(mem,1,65536,f);
    } else {
        if(base + (uint32_t)sz > 65536) {
            fprintf(stderr,"[SIM] Binary too large for load address $%04X\n",(unsigned)base);
            fclose(f); return -1;
        }
        size_t n=fread(mem+base,1,(size_t)sz,f);
        (void)n;
        fprintf(stderr,"[SIM] Loaded %ld bytes at $%04X\n", sz, (unsigned)base);
    }
    fclose(f);
    return 0;
}

/* ── assemble & load ─────────────────────────────────────────────────────── */
static int assemble_and_load(const char *asm_path) {
    /* Read source file */
    FILE *f = fopen(asm_path, "r");
    if (!f) { perror(asm_path); return -1; }
    static char source[1024*1024];
    size_t n = fread(source, 1, sizeof(source)-1, f);
    fclose(f);
    source[n] = '\0';

    /* Assemble directly into mem[] (provided by this file) */
    memset(mem, 0, sizeof(mem));
    int ok = assemble(source);
    if (!ok) {
        fprintf(stderr, "[ASM] Assembly failed (%d error(s)):\n", nerrors);
        for (int i = 0; i < nerrors; i++)
            fprintf(stderr, "  %s\n", errors[i]);
        return -1;
    }
    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */
static void sim_usage(FILE *out) {
    fprintf(out,
        "sim65c02 v11 — 65C02 simulator for uBASIC\n"
        "\n"
        "Usage:\n"
        "  sim65c02 <file.asm | file.bin> [options]\n"
        "  sim65c02 --help\n"
        "\n"
        "Options:\n"
        "  --input \"line\"     Queue a line of input (CR appended); repeatable.\n"
        "                     Takes precedence over stdin (below) whenever given.\n"
        "  --maxcycles N      Cycle limit before forced exit (default 500000000).\n"
        "                     N=0 means UNLIMITED: no cycle cap, and the GETCH-idle-\n"
        "                     exhaustion auto-exit is skipped too -- Ctrl-C or a\n"
        "                     program-driven halt are the only ways out.\n"
        "  --verbose          Print every instruction executed (very slow).\n"
        "  --stats            Print cycle count and ZP state on exit.\n"
        "  --load-addr 0xNNNN Override auto-detected load address for .bin files.\n"
        "  --getch-addr 0xNNNN Override the GETCH (input poll) port (default $E004).\n"
        "  --putch-addr 0xNNNN Override the PUTCH (char output) port (default $E001).\n"
        "  -w 0xADDR          Write watchpoint: log every write to address to stderr,\n"
        "                     continue running. Repeatable.\n"
        "  -W 0xADDR          Write watchpoint: log to stderr and halt on first write.\n"
        "                     Repeatable.\n"
        "  -m 0xADDR LEN      Dump LEN bytes from address to stderr at exit/halt.\n"
        "                     Up to 4 -m options.\n"
        "  -D NAME            Predefine NAME as 1 for the assembler's .IF directive,\n"
        "                     as if 'NAME = 1' appeared before the source file starts.\n"
        "                     Only applies to a .asm input -- has no effect (and warns)\n"
        "                     if given with a .bin file, since there's no assembly\n"
        "                     step for it to affect. Repeatable.\n"
        "  -D NAME=EXPR       Predefine NAME as EXPR (decimal, $hex, %%binary, etc).\n"
        "                     Earlier -D flags on the same command line are visible\n"
        "                     to later ones, e.g. -D A=1 -D B=A+1.\n"
        "  --help             Print this help and exit.\n"
        "\n"
        "Examples:\n"
        "  sim65c02 uBASIC.asm --input \"PRINT 42\"\n"
        "  sim65c02 miniBASIC.asm --input \"NEW\" --input \"10 PRINT 1+1\" --input \"RUN\"\n"
        "  sim65c02 basic.asm -w 0x08 -w 0x04 --input \"PRINT 1\" -m 0x08 2\n"
        "  echo -e \"PRINT 1+1\\r\" | sim65c02 basic.asm            (piped stdin, no --input given)\n"
        "  sim65c02 4kbasic_v7.asm < test_script.txt              (redirected test script, see below)\n"
        "\n"
        "Test scripts via stdin redirect: if --input is not given, GETCH reads real\n"
        "stdin directly (blocking per poll, so you can type while the program runs;\n"
        "Enter's LF -- or a text file's line ending -- is translated to the CR the\n"
        "BASIC ROMs expect). This means a plain text file of BASIC lines/commands,\n"
        "one per line exactly as you'd type them, can be redirected straight in:\n"
        "  NEW\n"
        "  10 PRINT \"HELLO WORLD\"\n"
        "  20 GOTO 10\n"
        "  RUN\n"
        "EOF on stdin feeds the same idle-exhaustion exit as a queued buffer running\n"
        "out, so it is likewise disabled by --maxcycles 0. A script that ends in an\n"
        "infinite loop (like the GOTO above) requires Ctrl-C regardless of\n"
        "--maxcycles, since the program is legitimately running, not idle-polling.\n"
        "\n"
        "Ctrl-C (SIGINT) exits the run loop gracefully -- --stats/-m output still\n"
        "prints afterward, since nothing is written to disk during the run.\n"
        "\n"
        "Build:\n"
        "  gcc -O2 -o sim65c02 sim65c02.c      (asm65c02.c must be in same directory)\n"
    );
}

int main(int argc, char **argv) {
    /* --help (or -h) anywhere in args */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            sim_usage(stdout);
            return 0;
        }
    }

    const char *src_file  = NULL;
    const char *bin_file  = NULL;
    long long   maxcycles = 500000000LL; /* 500M default */
    int         verbose   = 0;
    int         show_stats= 0;

    /* parse args */
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--maxcycles") && i+1<argc) { maxcycles=atoll(argv[++i]); }
        else if(!strcmp(argv[i],"--input") && i+1<argc) {
            /* append to input queue with CR */
            const char *s=argv[++i];
            int n=strlen(s);
            if(inbuf_len+n+2<INBUF_MAX){
                memcpy(inbuf+inbuf_len,s,n);
                inbuf_len+=n;
                inbuf[inbuf_len++]='\r'; /* CR */
            }
        }
        else if(!strcmp(argv[i],"--verbose")) { verbose=1; }
        else if(!strcmp(argv[i],"--stats"))   { show_stats=1; }
        else if(!strcmp(argv[i],"--load-addr") && i+1<argc) { bin_load_addr=(uint32_t)strtoul(argv[++i],NULL,0); }
        else if(!strcmp(argv[i],"--getch-addr") && i+1<argc) { io_getch_addr=(uint16_t)strtoul(argv[++i],NULL,0); }
        else if(!strcmp(argv[i],"--putch-addr") && i+1<argc) { io_putch_addr=(uint16_t)strtoul(argv[++i],NULL,0); }
        else if(!strcmp(argv[i],"-w") && i+1<argc) {
            if(nwatch<MAX_WATCH){ watch_addr[nwatch]=(uint16_t)strtoul(argv[++i],NULL,0); watch_halt[nwatch]=0; nwatch++; }
            else { i++; }
        }
        else if(!strcmp(argv[i],"-W") && i+1<argc) {
            if(nwatch<MAX_WATCH){ watch_addr[nwatch]=(uint16_t)strtoul(argv[++i],NULL,0); watch_halt[nwatch]=1; nwatch++; }
            else { i++; }
        }
        else if(!strcmp(argv[i],"-m") && i+2<argc) {
            uint16_t a=(uint16_t)strtoul(argv[i+1],NULL,0);
            int len=atoi(argv[i+2]);
            i+=2;
            if(ndump<MAX_DUMP && len>0){ dump_addr[ndump]=a; dump_len[ndump]=len; ndump++; }
        }
        else if(!strcmp(argv[i],"-D")) {
            if(i+1>=argc) { fprintf(stderr,"-D requires an argument (NAME or NAME=EXPR)\n"); return 1; }
            if(!asm_predefine(argv[++i])) {
                fprintf(stderr,"Invalid -D argument: '%s' (expected NAME or NAME=EXPR)\n",argv[i]);
                return 1;
            }
        }
        else if(argv[i][0]!='-'){
            /* positional: .asm or .bin */
            size_t l=strlen(argv[i]);
            if(l>4 && !strcmp(argv[i]+l-4,".asm")) src_file=argv[i];
            else                                     bin_file=argv[i];
        }
    }

    /* load ROM */
    memset(mem,0,sizeof(mem));
    if(src_file){
        fprintf(stderr,"[SIM] Assembling %s ...\n",src_file);
        if(assemble_and_load(src_file)<0) return 1;
        fprintf(stderr,"[SIM] Assembly OK\n");
    } else if(bin_file){
        if(n_cli_predefines > 0) {
            fprintf(stderr,"[SIM] Warning: -D flag(s) ignored -- loading a raw .bin file has no assembly step for them to affect.\n");
        }
        if(load_bin(bin_file)<0) return 1;
    } else {
        sim_usage(stderr);
        return 1;
    }

    /* init CPU from reset vector */
    CPU cpu;
    memset(&cpu,0,sizeof(cpu));
    cpu.SP=0xFF;
    cpu.I=1;
    cpu.PC = mem[0xFFFC] | (mem[0xFFFD]<<8);
    if(cpu.PC==0){ fprintf(stderr,"[SIM] Reset vector is $0000 - bad ROM?\n"); return 1; }
    if (maxcycles==0)
        fprintf(stderr,"[SIM] Reset PC=$%04X  maxcycles=0 (unlimited)\n",cpu.PC);
    else
        fprintf(stderr,"[SIM] Reset PC=$%04X  maxcycles=%lld\n",cpu.PC,maxcycles);

    /* v8: --input always takes precedence when given; fall back to live
     * stdin only if it supplied nothing (see use_live_stdin header
     * comment). inbuf_len is final by this point. */
    use_live_stdin = (inbuf_len == 0);

    /* v8: GETCH/PUTCH are configured addresses (see io_getch_addr/
     * io_putch_addr, --getch-addr/--putch-addr), not scanned or detected
     * -- always shown here since there's nothing left to "detect". */
    fprintf(stderr,"[SIM] GETCH addr=$%04X  PUTCH addr=$%04X  input=%s\n",
            io_getch_addr, io_putch_addr,
            use_live_stdin ? "stdin (live)" : "--input queue");

    /* v8: catch Ctrl-C so the run loop exits gracefully (falls through to
     * --stats/-m reporting below) instead of an abrupt OS-default kill.
     * See g_stop_requested comment for why this is safe to do. */
    signal(SIGINT, on_sigint);

    /* run */
    long long cycles=0;
    while(!g_stop_requested && (maxcycles==0 || cycles < maxcycles)){
        /* v8: idle-exhaustion is driven directly by rd()'s getch_idle
         * counter now (see its header comment) -- no PC-matching needed.
         * When maxcycles==0 (unlimited), this check is skipped entirely:
         * unlimited means unlimited, with no automatic exit other than a
         * program-driven halt (BRK/unknown opcode/watchpoint) or Ctrl-C. */
        if(maxcycles!=0 && getch_idle > 50000) {
            fprintf(stderr,"\n[SIM] Input exhausted after %lld cycles\n",cycles);
            break;
        }

        int r=step(&cpu);
        cycles++;
        if(r) {
            fprintf(stderr,"\n[SIM] Halted (BRK/unknown) at $%04X after %lld cycles\n",
                    cpu.PC-1,cycles);
            break;
        }
        if(watch_triggered) {
            fprintf(stderr,"\n[SIM] Watchpoint halt: $%04X <- $%02X at PC=$%04X after %lld cycles\n",
                    watch_trigger_addr, watch_trigger_val, watch_trigger_pc, cycles);
            break;
        }
        /* hardware IRQ: fire if pending and I flag clear */
        if (pending_irq && !cpu.I) {
            pending_irq = 0;
            cpu.I = 1;                                /* SEI: mask further IRQs */
            PUSH(&cpu, (uint8_t)(cpu.PC >> 8));       /* push PChi */
            PUSH(&cpu, (uint8_t)(cpu.PC & 0xFF));     /* push PClo */
            PUSH(&cpu, pack_flags(&cpu) & ~0x10);     /* push P with B=0 */
            cpu.PC = (uint16_t)mem[0xFFFE] | ((uint16_t)mem[0xFFFF] << 8);
        }
    }
    if(g_stop_requested)
        fprintf(stderr,"\n[SIM] Interrupted by user (Ctrl-C) after %lld cycles\n",cycles);
    else if(maxcycles!=0 && cycles>=maxcycles)
        fprintf(stderr,"\n[SIM] Cycle limit %lld reached\n",maxcycles);

    if(show_stats){
        fprintf(stderr,"[SIM] Total cycles: %lld\n",cycles);
        fprintf(stderr,"[SIM] ZP dump: IP=%02X%02X PE=%02X%02X RUN=%02X\n",
                mem[1],mem[0],mem[3],mem[2],mem[0x0E]);
    }
    for(int i=0;i<ndump;i++){
        fprintf(stderr,"[DUMP $%04X len=%d]:", dump_addr[i], dump_len[i]);
        for(int j=0;j<dump_len[i];j++)
            fprintf(stderr," %02X", mem[(uint16_t)(dump_addr[i]+j)]);
        fprintf(stderr,"\n");
    }
    return 0;
}