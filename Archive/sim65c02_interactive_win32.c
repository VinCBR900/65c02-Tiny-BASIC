/*
 * sim65c02_interactive_win32.c  —  Toy interactive 65c02  simulator for Windows  (v5, Mar 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Split-screen Windows console TUI — no external dependencies, pure Win32 API.
 *
 *   Left  pane (40x25): Virtual BASIC terminal, exact Kowalski I/O mapping
 *   Right pane (38 cols): Interpreter state panel (live ZP / variable display)
 *   Bottom bar: CPU registers + cycle count
 *
 * Build (TCC) using Windows console interface:
 *   TCC -O2 -o sim65c02_interactive_W32.exe sim65c02_interactive_win32.c
 *   (asm65c02.c must be in same directory)
 *
 * Usage: 
 *   sim65c02_interactive.exe <file.asm | file.bin> [--load-addr 0xNNNN]
 *
 * Kowalski I/O ports (identical to Kowalski simulator):
 *   $E000  write  CLS      clear virtual terminal + home cursor
 *   $E001  write  PUTCH    character to virtual terminal
 *   $E004  read   GETCH    non-blocking key poll (0 = no key)
 *   $E005  write  XPOS     set cursor column (0-based)
 *   $E006  write  YPOS     set cursor row (0-based)
 * Additional I/O Ports
 *   $E007  Write  N/A      Dummy write - used to initiate an Interrupt
 *
 * Controls:
 *   Normal typing  → fed to GETCH as keyboard input (CR sent on Enter)
 *   F1             → toggle right panel: VARS+FOR  ↔  ZP hex dump $00-$BF
 *   F5             → reset CPU (warm restart via reset vector)
 *   F6             → fire maskable IRQ (Break key)
 *   Escape         → quit  (q/Q are passed through to BASIC as normal input)
 *
 * Version history:
 *   v1  Initial Windows port.
 *   v5  F6 key fires maskable IRQ ($E007); status bar shows F6:BRK.
 *   v2  Fixed HALT crash: step() replaced with proven original from sim65c02.c.
 *       Terminal redrawn via WriteConsoleOutputCharacterA for clean 40-col rendering.
 *   v3  Fix CR/LF double-spacing: CR ($0D) resets column only; LF ($0A) advances row.
 *       q/Q passed to BASIC as normal input; Escape to quit.
 *       Halt message shows op, SP, stack top 4 bytes, and last-16-PC trace.
 *   v4  Version sync with Linux v2 (no functional change).
 *   V5  Version sync with Linux - IRQ trigger writing to $E007
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

/* ── embedded assembler ──────────────────────────────────────────────────── */
#include "asm65c02.c"

/* ══════════════════════════════════════════════════════════════════════════
 * Layout constants  (all 0-based)
 * ══════════════════════════════════════════════════════════════════════════ */
#define TERM_COLS    40     /* virtual terminal width  */
#define TERM_ROWS    25     /* virtual terminal height */

/* Console layout (with 1-char border):
 *   Cols  0-41  : left pane border + 40-col terminal + border
 *   Col  42     : separator
 *   Cols 43-80  : right panel (37 cols usable)
 *   Row  27     : status bar
 */
#define LEFT_BORDER_COL   0
#define LEFT_CONTENT_COL  1
#define RIGHT_COL         43
#define RIGHT_WIDTH       37
#define STATUS_ROW        27
#define TOTAL_ROWS        28
#define TOTAL_COLS        81

/* Colours (Windows console attributes) */
#define COL_NORMAL   (FOREGROUND_GREEN | FOREGROUND_INTENSITY)
#define COL_BORDER   (FOREGROUND_GREEN)
#define COL_PANEL    (FOREGROUND_BLUE | FOREGROUND_GREEN | FOREGROUND_INTENSITY)
#define COL_LABEL    (FOREGROUND_RED   | FOREGROUND_GREEN | FOREGROUND_INTENSITY) /* yellow */
#define COL_STATUS   (FOREGROUND_RED   | FOREGROUND_GREEN | FOREGROUND_BLUE | FOREGROUND_INTENSITY)
#define COL_CURSOR   (BACKGROUND_GREEN | FOREGROUND_RED | FOREGROUND_GREEN | FOREGROUND_BLUE)
#define COL_CHANGED  (FOREGROUND_RED   | FOREGROUND_INTENSITY)

/* ══════════════════════════════════════════════════════════════════════════
 * Console handle + helper
 * ══════════════════════════════════════════════════════════════════════════ */
static HANDLE hout = INVALID_HANDLE_VALUE;
static HANDLE hin  = INVALID_HANDLE_VALUE;

static void con_write(int col, int row, const char *s, WORD attr) {
    COORD pos = { (SHORT)col, (SHORT)row };
    DWORD written;
    SetConsoleCursorPosition(hout, pos);
    SetConsoleTextAttribute(hout, attr);
    WriteConsoleA(hout, s, (DWORD)strlen(s), &written, NULL);
}

static void con_writech(int col, int row, char ch, WORD attr) {
    char buf[2] = { ch, 0 };
    con_write(col, row, buf, attr);
}

static void con_fill(int col, int row, int width, char ch, WORD attr) {
    char buf[128];
    int n = width < 127 ? width : 127;
    memset(buf, ch, n); buf[n] = 0;
    con_write(col, row, buf, attr);
}

static void con_printf(int col, int row, WORD attr, const char *fmt, ...) {
    char buf[128];
    va_list ap; va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    con_write(col, row, buf, attr);
}

/* Hide the real console cursor (we draw our own) */
static void hide_cursor(void) {
    CONSOLE_CURSOR_INFO ci = { 1, FALSE };
    SetConsoleCursorInfo(hout, &ci);
}

/* ══════════════════════════════════════════════════════════════════════════
 * Virtual terminal
 * ══════════════════════════════════════════════════════════════════════════ */
static char  vterm[TERM_ROWS][TERM_COLS+1];
static int   vcol = 0;
static int   vrow = 0;

/* Track which cells are dirty so we only repaint what changed */
static char  vterm_prev[TERM_ROWS][TERM_COLS+1];
static int   vterm_dirty = 1;   /* force full redraw first time */

static void vterm_clear(void) {
    for (int r = 0; r < TERM_ROWS; r++) {
        memset(vterm[r],      ' ', TERM_COLS); vterm[r][TERM_COLS]      = 0;
        memset(vterm_prev[r], 0,   TERM_COLS+1);  /* force repaint */
    }
    vcol = 0; vrow = 0;
    vterm_dirty = 1;
}

static void vterm_scroll(void) {
    for (int r = 0; r < TERM_ROWS-1; r++)
        memcpy(vterm[r], vterm[r+1], TERM_COLS);
    memset(vterm[TERM_ROWS-1], ' ', TERM_COLS);
    vterm_dirty = 1;
}

static void vterm_putch(uint8_t ch) {
    if (ch == '\r') {
        vcol = 0;                          /* CR: carriage return only, no line advance */
        return;
    }
    if (ch == '\n') {
        vcol = 0;                          /* LF: also reset column (standard terminal) */
        vrow++;
        if (vrow >= TERM_ROWS) { vterm_scroll(); vrow = TERM_ROWS-1; }
        return;
    }
    if (ch == '\b') {
        if (vcol > 0) { vcol--; vterm[vrow][vcol] = ' '; vterm_dirty = 1; }
        return;
    }
    if (ch < 0x20 || ch > 0x7E) return;
    if (vcol >= TERM_COLS) {
        vcol = 0; vrow++;
        if (vrow >= TERM_ROWS) { vterm_scroll(); vrow = TERM_ROWS-1; }
    }
    if (vterm[vrow][vcol] != (char)ch) vterm_dirty = 1;
    vterm[vrow][vcol++] = (char)ch;
}

/* ══════════════════════════════════════════════════════════════════════════
 * Keyboard queue
 * ══════════════════════════════════════════════════════════════════════════ */
#define KEYQ_MAX 256
static uint8_t keyq[KEYQ_MAX];
static int     keyq_head = 0, keyq_tail = 0;

static void keyq_push(uint8_t c) {
    int next = (keyq_tail+1) & (KEYQ_MAX-1);
    if (next != keyq_head) { keyq[keyq_tail] = c; keyq_tail = next; }
}
static uint8_t keyq_poll(void) {
    if (keyq_head == keyq_tail) return 0;
    uint8_t c = keyq[keyq_head];
    keyq_head = (keyq_head+1) & (KEYQ_MAX-1);
    return c;
}
static int keyq_empty(void) { return keyq_head == keyq_tail; }

/* ══════════════════════════════════════════════════════════════════════════
 * Memory + 65C02 I/O
 * ══════════════════════════════════════════════════════════════════════════ */
uint8_t mem[65536];

static uint8_t rd(uint16_t a) {
    if (a == 0xE004) return keyq_poll();
    return mem[a];
}
static int irq_pending = 0;   /* set by F6 key / $E007 write */

void wr(uint16_t a, uint8_t v) {
    switch (a) {
    case 0xE000: vterm_clear(); return;
    case 0xE001: vterm_putch(v); return;
    case 0xE005: vcol = (v < TERM_COLS) ? v : TERM_COLS-1; return;
    case 0xE006: vrow = (v < TERM_ROWS) ? v : TERM_ROWS-1; return;
    case 0xE007: irq_pending = 1; return;   /* IRQ trigger */
    default:     mem[a] = v;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * 65C02 CPU  (copy of sim65c02.c step())
 * ══════════════════════════════════════════════════════════════════════════ */
typedef struct { uint16_t PC; uint8_t A,X,Y,SP,N,V,D,I,Z,C; } CPU;

static uint8_t cpu_pop(CPU *cpu) { cpu->SP++; return mem[0x100 + cpu->SP]; }
#define PUSH(cpu,v)  (mem[0x100+(cpu)->SP--]=(v))
#define POP(cpu)     cpu_pop(cpu)
static void set_nz(CPU *c,uint8_t v){c->N=(v>>7)&1;c->Z=(v==0);}
static uint8_t pack_flags(CPU *c){return(c->N<<7)|(c->V<<6)|(1<<5)|(1<<4)|(c->D<<3)|(c->I<<2)|(c->Z<<1)|c->C;}
static void unpack_flags(CPU *c,uint8_t p){c->N=(p>>7)&1;c->V=(p>>6)&1;c->D=(p>>3)&1;c->I=(p>>2)&1;c->Z=(p>>1)&1;c->C=p&1;}
static uint16_t zp(uint16_t pc){return mem[pc];}
static uint16_t zpx(CPU *c,uint16_t pc){return(mem[pc]+c->X)&0xFF;}
static uint16_t zpy(CPU *c,uint16_t pc){return(mem[pc]+c->Y)&0xFF;}
static uint16_t ab(uint16_t pc){return mem[pc]|(mem[pc+1]<<8);}
static uint16_t abx(CPU *c,uint16_t pc){return(uint16_t)((mem[pc]|(mem[pc+1]<<8))+c->X);}
static uint16_t aby(CPU *c,uint16_t pc){return(uint16_t)((mem[pc]|(mem[pc+1]<<8))+c->Y);}
static uint16_t indy(CPU *c,uint16_t pc){uint8_t z=mem[pc];return(uint16_t)((mem[z]|(mem[(z+1)&0xFF]<<8))+c->Y);}
static uint16_t indx(CPU *c,uint16_t pc){uint8_t z=(mem[pc]+c->X)&0xFF;return(uint16_t)(mem[z]|(mem[(z+1)&0xFF]<<8));}
static uint16_t indzp(uint16_t pc){uint8_t z=mem[pc];return(uint16_t)(mem[z]|(mem[(z+1)&0xFF]<<8));}
static uint16_t ind(uint16_t pc){uint16_t a=mem[pc]|(mem[pc+1]<<8);return(uint16_t)(mem[a]|(mem[a+1]<<8));}
static void do_adc(CPU *c,uint8_t v){uint16_t r=c->A+v+c->C;c->V=(~(c->A^v)&(c->A^(uint8_t)r)&0x80)?1:0;c->C=(r>0xFF)?1:0;c->A=(uint8_t)r;set_nz(c,c->A);}
static void do_sbc(CPU *c,uint8_t v){do_adc(c,v^0xFF);}
static void do_cmp(CPU *c,uint8_t reg,uint8_t v){uint16_t r=reg-v;c->C=(reg>=v)?1:0;set_nz(c,(uint8_t)r);}
static uint16_t branch(uint16_t pc,uint8_t off){return(uint16_t)(pc+(int8_t)off);}
static long long cycle_count = 0;

static int step(CPU *cpu) {
    uint16_t pc = cpu->PC;
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

    /* ── ROL ── */
    case 0x2A: { uint8_t c=cpu->C; cpu->C=cpu->A>>7; cpu->A=(cpu->A<<1)|c; set_nz(cpu,cpu->A); return 0; }
    case 0x26: { uint8_t v=mem[ZP]; uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x36: { uint8_t v=mem[ZPX];uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x2E: { uint8_t v=RD(ABS); uint8_t c=cpu->C; cpu->C=v>>7; v=(v<<1)|c; WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }

    /* ── ROR ── */
    case 0x6A: { uint8_t c=cpu->C; cpu->C=cpu->A&1; cpu->A=(cpu->A>>1)|(c<<7); set_nz(cpu,cpu->A); return 0; }
    case 0x66: { uint8_t v=mem[ZP]; uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ZP,v); cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x76: { uint8_t v=mem[ZPX];uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ZPX,v);cpu->PC+=1; set_nz(cpu,v); return 0; }
    case 0x6E: { uint8_t v=RD(ABS); uint8_t c=cpu->C; cpu->C=v&1; v=(v>>1)|(c<<7); WR(ABS,v);cpu->PC+=2; set_nz(cpu,v); return 0; }

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
        return 1;
    }
}


/* ══════════════════════════════════════════════════════════════════════════
 * Display rendering
 * ══════════════════════════════════════════════════════════════════════════ */
static int panel_mode = 0;  /* 0=vars+FOR, 1=ZP hex dump */

static int16_t mem16s(int a){ return (int16_t)(mem[a]|(mem[a+1]<<8)); }
static uint16_t mem16u(int a){ return (uint16_t)(mem[a]|(mem[a+1]<<8)); }

/* Draw the static frame (borders, labels) once at startup */
static void draw_frame(void) {
    /* Left pane border */
    for (int r = 0; r <= TERM_ROWS+1; r++) {
        con_writech(0, r, (r==0)?'+':((r==TERM_ROWS+1)?'+':'|'), COL_BORDER);
        con_writech(TERM_COLS+1, r, (r==0)?'+':((r==TERM_ROWS+1)?'+':'|'), COL_BORDER);
    }
    con_fill(1, 0, TERM_COLS, '-', COL_BORDER);
    con_fill(1, TERM_ROWS+1, TERM_COLS, '-', COL_BORDER);
    con_write(2, 0, " BASIC Terminal ", COL_LABEL);

    /* Separator */
    for (int r = 0; r <= TERM_ROWS+1; r++)
        con_writech(TERM_COLS+2, r, '|', COL_BORDER);

    /* Right pane border */
    for (int r = 0; r <= TERM_ROWS+1; r++) {
        con_writech(RIGHT_COL-1, r, (r==0)?'+':((r==TERM_ROWS+1)?'+':'|'), COL_BORDER);
        con_writech(RIGHT_COL+RIGHT_WIDTH, r, (r==0)?'+':((r==TERM_ROWS+1)?'+':'|'), COL_BORDER);
    }
    con_fill(RIGHT_COL, 0, RIGHT_WIDTH, '-', COL_BORDER);
    con_fill(RIGHT_COL, TERM_ROWS+1, RIGHT_WIDTH, '-', COL_BORDER);
    con_write(RIGHT_COL+1, 0, " Interpreter State ", COL_LABEL);
}

static void draw_terminal(void) {
    if (!vterm_dirty) return;
    for (int r = 0; r < TERM_ROWS; r++) {
        COORD pos = { (SHORT)LEFT_CONTENT_COL, (SHORT)(r+1) };
        DWORD written;
        char row_chars[TERM_COLS];
        WORD row_attrs[TERM_COLS];
        for (int c = 0; c < TERM_COLS; c++) {
            char ch = vterm[r][c];
            row_chars[c] = (ch >= 0x20 && ch <= 0x7E) ? ch : ' ';
            row_attrs[c] = (r == vrow && c == vcol) ? COL_CURSOR : COL_NORMAL;
        }
        WriteConsoleOutputCharacterA(hout, row_chars, TERM_COLS, pos, &written);
        WriteConsoleOutputAttribute(hout, row_attrs, TERM_COLS, pos, &written);
        memcpy(vterm_prev[r], vterm[r], TERM_COLS);
    }
    vterm_dirty = 0;
}

static void draw_panel_vars(void) {
    uint16_t ip    = mem16u(0x00);
    uint16_t pe    = mem16u(0x02);
    uint16_t curln = mem16u(0x0C);
    uint8_t  run   = mem[0x0F];
    uint8_t  gret  = mem[0x0E];
    uint8_t  fstk  = mem[0x9D];
    uint8_t  runsp = mem[0xBA];
    int r = RIGHT_COL;
    int row = 1;

    con_printf(r, row++, COL_PANEL, "IP:%04X PE:%04X CURLN:%5u   ", ip, pe, curln);
    con_printf(r, row++, COL_PANEL, "RUN:%-3s FSTK:%u GRET:%u SP:%02X   ",
               run ? "RUN" : "---", fstk, gret, runsp);
    con_printf(r, row++, COL_PANEL, "T0:%04X T1:%04X T2:%04X   ",
               mem16u(0x06), mem16u(0x08), mem16u(0x0A));
    con_printf(r, row++, COL_PANEL, "DATA:%04X RND:%04X             ",
               mem16u(0xBC), mem16u(0xBE));

    /* divider */
    con_fill(r, row++, RIGHT_WIDTH, '-', COL_BORDER);

    /* VARS A–Z in 3 columns of 12 chars each */
    con_write(r, row++, "Variables A-Z:", COL_LABEL);
    for (int i = 0; i < 26; i++) {
        int16_t val = mem16s(0x50 + i*2);
        int col_off = (i % 3) * 12;
        if (i % 3 == 0 && i > 0) row++;
        char buf[14]; snprintf(buf, sizeof(buf), "%c:%-8d", 'A'+i, val);
        con_write(r + col_off, row, buf, COL_PANEL);
    }
    row += 2;

    con_fill(r, row++, RIGHT_WIDTH, '-', COL_BORDER);

    /* FOR stack frames */
    if (fstk > 0) {
        char hdr[32]; snprintf(hdr, sizeof(hdr), "FOR stack (%u frame%s):", fstk, fstk==1?"":"s");
        con_write(r, row++, hdr, COL_LABEL);
        for (int f = 0; f < (int)fstk && row < TERM_ROWS+1; f++) {
            int base = 0x9E + f*7;
            uint8_t  slot  = mem[base];
            int16_t  lim   = mem16s(base+1);
            int16_t  stp   = mem16s(base+3);
            uint16_t lline = mem16u(base+5);
            char varname   = (slot < 52) ? (char)('A' + slot/2) : '?';
            char buf[38];
            snprintf(buf, sizeof(buf), " [%d]%c lim=%-5d stp=%-4d ln=%-5u",
                     f, varname, lim, stp, lline);
            con_write(r, row++, buf, COL_PANEL);
        }
    } else {
        con_write(r, row++, "FOR stack: (empty)          ", COL_PANEL);
    }

    /* GOSUB stack */
    if (gret > 0 && row < TERM_ROWS+1) {
        char hdr[32]; snprintf(hdr, sizeof(hdr), "GOSUB (%u):", gret);
        con_write(r, row++, hdr, COL_LABEL);
        for (int g = 0; g < (int)gret && row < TERM_ROWS+1; g++) {
            char buf[24];
            snprintf(buf, sizeof(buf), "  [%d] ret=$%04X         ", g, mem16u(0x8C + g*2));
            con_write(r, row++, buf, COL_PANEL);
        }
    }

    /* blank remaining rows in panel */
    while (row < TERM_ROWS+1) {
        con_fill(r, row++, RIGHT_WIDTH, ' ', COL_PANEL);
    }
}

static void draw_panel_zp(void) {
    int r = RIGHT_COL;
    con_write(r, 0, " ZP $00-$BF ", COL_LABEL);
    for (int row = 0; row < 12; row++) {
        int addr = row * 16;
        char buf[38];
        snprintf(buf, sizeof(buf), "%02X: %02X %02X %02X %02X %02X %02X %02X %02X"
                                   " %02X %02X %02X %02X %02X %02X %02X %02X",
                 addr,
                 mem[addr+ 0],mem[addr+ 1],mem[addr+ 2],mem[addr+ 3],
                 mem[addr+ 4],mem[addr+ 5],mem[addr+ 6],mem[addr+ 7],
                 mem[addr+ 8],mem[addr+ 9],mem[addr+10],mem[addr+11],
                 mem[addr+12],mem[addr+13],mem[addr+14],mem[addr+15]);
        con_write(r, row+1, buf, COL_PANEL);
    }
    /* blank remaining rows */
    for (int row = 13; row < TERM_ROWS+1; row++)
        con_fill(r, row, RIGHT_WIDTH, ' ', COL_PANEL);
}

static void draw_status(CPU *cpu) {
    char buf[82];
    snprintf(buf, sizeof(buf),
        " PC:%04X A:%02X X:%02X Y:%02X SP:%02X  N%dV%dD%dI%dZ%dC%d"
        "  Cyc:%-12lld  F1:ZP  F5:RST  F6:BRK  Esc:quit",
        cpu->PC, cpu->A, cpu->X, cpu->Y, cpu->SP,
        cpu->N, cpu->V, cpu->D, cpu->I, cpu->Z, cpu->C,
        cycle_count);
    /* pad to 80 chars */
    int len = (int)strlen(buf);
    while (len < 80) buf[len++] = ' ';
    buf[80] = 0;
    con_write(0, STATUS_ROW, buf, COL_STATUS);
}

static void redraw_all(CPU *cpu) {
    draw_terminal();
    if (panel_mode == 0) draw_panel_vars();
    else                 draw_panel_zp();
    draw_status(cpu);
}

/* ══════════════════════════════════════════════════════════════════════════
 * ROM loading
 * ══════════════════════════════════════════════════════════════════════════ */
static uint32_t bin_load_addr = 0;

static int load_bin(const char *path) {
    FILE *f = fopen(path,"rb");
    if(!f){fprintf(stderr,"Cannot open %s\n",path);return -1;}
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint32_t base = bin_load_addr;
    if(!base){
        if(sz==2048) base=0xF800;
        else if(sz==4096) base=0xF000;
        else if(sz==65536) base=0;
        else base=(uint32_t)(0x10000-sz);
    }
    size_t got = fread(mem+base,1,(size_t)sz,f);
    fclose(f);
    if((long)got<sz&&sz<65536){fprintf(stderr,"Short read %s\n",path);return -1;}
    return 0;
}

static int assemble_and_load(const char *path) {
    FILE *f = fopen(path,"r");
    if(!f){fprintf(stderr,"Cannot open %s\n",path);return -1;}
    static char source[1024*1024];
    size_t n = fread(source,1,sizeof(source)-1,f);
    fclose(f);
    source[n] = '\0';
    memset(mem,0,sizeof(mem));
    int ok = assemble(source);
    if(!ok){
        fprintf(stderr,"Assembly failed (%d errors):\n",nerrors);
        for(int i=0;i<nerrors;i++) fprintf(stderr,"  %s\n",errors[i]);
        return -1;
    }
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 * Keyboard handler — called on each Windows console key event
 * ══════════════════════════════════════════════════════════════════════════ */
static int    quit_flag  = 0;
static int    reset_flag = 0;

static void handle_key(KEY_EVENT_RECORD *ke, CPU *cpu) {
    if (!ke->bKeyDown) return;
    WORD vk = ke->wVirtualKeyCode;
    char asc = ke->uChar.AsciiChar;

    if (vk == VK_F1)     { panel_mode ^= 1; return; }
    if (vk == VK_F5)     { reset_flag = 1;  return; }
    if (vk == VK_F6)     { irq_pending = 1; return; }  /* Break key */
    if (vk == VK_ESCAPE) { quit_flag  = 1;  return; }
    if (asc == 'q' || asc == 'Q') { keyq_push((uint8_t)asc); return; }  /* q/Q = normal char, not quit */

    /* Translate to bytes for GETCH queue */
    if (vk == VK_RETURN)    { keyq_push('\r'); return; }
    if (vk == VK_BACK)      { keyq_push('\b'); return; }
    if (vk == VK_TAB)       { keyq_push('\t'); return; }
    if (vk == VK_UP)        { keyq_push(0x1B); keyq_push('['); keyq_push('A'); return; }
    if (vk == VK_DOWN)      { keyq_push(0x1B); keyq_push('['); keyq_push('B'); return; }
    if (vk == VK_LEFT)      { keyq_push(0x1B); keyq_push('['); keyq_push('D'); return; }
    if (vk == VK_RIGHT)     { keyq_push(0x1B); keyq_push('['); keyq_push('C'); return; }

    /* Printable ASCII */
    if (asc >= 0x20 && asc <= 0x7E) { keyq_push((uint8_t)asc); return; }
    /* Ctrl keys */
    if (asc >= 1 && asc <= 26) { keyq_push((uint8_t)asc); return; }
}

/* ══════════════════════════════════════════════════════════════════════════
 * main
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "sim65c02_interactive - interactive 65C02 simulator (Windows)\n"
            "Usage: sim65c02_interactive <file.asm | file.bin> [--load-addr 0xNNNN]\n"
            "  F1       toggle ZP hex dump panel\n"
            "  F5       reset CPU\n"
            "  Escape   quit\n"
            "\nBuild: x86_64-w64-mingw32-gcc -O2 -o sim65c02_interactive.exe "
            "sim65c02_interactive_win32.c\n");
        return 1;
    }

    const char *filename = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"--load-addr") && i+1<argc)
            bin_load_addr = (uint32_t)strtoul(argv[++i],NULL,0);
        else if (argv[i][0] != '-')
            filename = argv[i];
    }
    if (!filename) { fprintf(stderr,"No input file\n"); return 1; }

    /* Load ROM before touching the console */
    memset(mem, 0, sizeof(mem));
    size_t fnlen = strlen(filename);
    if (fnlen > 4 && !strcmp(filename+fnlen-4, ".asm")) {
        fprintf(stderr,"[SIM] Assembling %s ...\n", filename);
        if (assemble_and_load(filename) < 0) return 1;
        fprintf(stderr,"[SIM] Assembly OK\n");
    } else {
        if (load_bin(filename) < 0) return 1;
    }

    /* Init CPU */
    CPU cpu;
    memset(&cpu, 0, sizeof(cpu));
    cpu.SP = 0xFF; cpu.I = 1;
    cpu.PC = (uint16_t)(mem[0xFFFC] | (mem[0xFFFD]<<8));
    if (!cpu.PC) { fprintf(stderr,"Reset vector is $0000 — bad ROM?\n"); return 1; }

    /* Find GETCH address */
    uint16_t getch_addr = 0;
    for (int ga = 0xF000; ga < 0xFFFF-3; ga++) {
        if (mem[ga]==0xAD && mem[ga+1]==0x04 && mem[ga+2]==0xE0 && mem[ga+3]==0xF0) {
            getch_addr = (uint16_t)ga; break;
        }
    }

    /* Set up Windows console */
    hout = GetStdHandle(STD_OUTPUT_HANDLE);
    hin  = GetStdHandle(STD_INPUT_HANDLE);

    /* Switch to raw input mode */
    SetConsoleMode(hin, ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT);

    /* Resize console to fit our layout (80 wide × 29 tall) */
    COORD size = { TOTAL_COLS, TOTAL_ROWS+1 };
    SetConsoleScreenBufferSize(hout, size);
    SMALL_RECT rect = { 0, 0, TOTAL_COLS-1, TOTAL_ROWS };
    SetConsoleWindowInfo(hout, TRUE, &rect);

    /* Hide cursor, clear screen */
    hide_cursor();
    {
        COORD origin = {0,0}; DWORD written;
        WORD blank_attr = COL_NORMAL;
        FillConsoleOutputCharacterA(hout, ' ', TOTAL_COLS*TOTAL_ROWS, origin, &written);
        FillConsoleOutputAttribute(hout, blank_attr, TOTAL_COLS*TOTAL_ROWS, origin, &written);
    }

    /* Draw static frame */
    vterm_clear();
    draw_frame();
    redraw_all(&cpu);

    /* ── main loop ─────────────────────────────────────────────────────── */
    long long display_timer = 0;
    const long long DISPLAY_INTERVAL = 20000;

    /* PC trace ring buffer — last 16 PCs before any halt */
    #define TRACE_N 16
    uint16_t trace_buf[TRACE_N]; int trace_pos = 0;
    memset(trace_buf, 0, sizeof(trace_buf));

    while (!quit_flag) {
        /* ── poll keyboard (non-blocking) ───────────────────────────── */
        {
            INPUT_RECORD ir[16]; DWORD nread = 0;
            PeekConsoleInput(hin, ir, 16, &nread);
            if (nread > 0) {
                ReadConsoleInput(hin, ir, nread, &nread);
                for (DWORD i = 0; i < nread; i++) {
                    if (ir[i].EventType == KEY_EVENT)
                        handle_key(&ir[i].Event.KeyEvent, &cpu);
                }
            }
        }

        /* ── reset ──────────────────────────────────────────────────── */
        if (reset_flag) {
            reset_flag = 0;
            memset(&cpu, 0, sizeof(cpu));
            cpu.SP = 0xFF; cpu.I = 1;
            cpu.PC = (uint16_t)(mem[0xFFFC]|(mem[0xFFFD]<<8));
            cycle_count = 0;
            vterm_clear();
            draw_frame();
        }

        /* ── run CPU burst ──────────────────────────────────────────── */
        int burst = 5000;
        /* Idle throttle: if spinning in GETCH with no input, slow down */
        if (getch_addr && cpu.PC == getch_addr && keyq_empty())
            burst = 50;

        for (int i = 0; i < burst && !quit_flag; i++) {
            /* deliver pending IRQ before next instruction */
            if (irq_pending && !cpu.I) {
                irq_pending = 0;
                PUSH(&cpu, (cpu.PC >> 8) & 0xFF);
                PUSH(&cpu, cpu.PC & 0xFF);
                PUSH(&cpu, pack_flags(&cpu) & ~0x10);
                cpu.I = 1;
                cpu.PC = (uint16_t)(mem[0xFFFE] | (mem[0xFFFF] << 8));
            }
            trace_buf[trace_pos % TRACE_N] = cpu.PC;
            trace_pos++;
            int r = step(&cpu);
            if (r) {
                /* BRK / unknown — display trace + message and wait for key */
                char msg[512]; int mlen = 0;
                mlen += snprintf(msg+mlen, sizeof(msg)-mlen,
                    "\r\n[HALT $%04X op=$%02X SP=$%02X]\r\n"
                    "Stk: %02X %02X %02X %02X\r\nTrace:",
                    cpu.PC-1, mem[cpu.PC-1], cpu.SP,
                    mem[0x100+(uint8_t)(cpu.SP+1)], mem[0x100+(uint8_t)(cpu.SP+2)],
                    mem[0x100+(uint8_t)(cpu.SP+3)], mem[0x100+(uint8_t)(cpu.SP+4)]);
                for (int t = 0; t < TRACE_N; t++) {
                    int idx = (trace_pos - TRACE_N + t + TRACE_N*1000) % TRACE_N;
                    mlen += snprintf(msg+mlen, sizeof(msg)-mlen,
                        " $%04X", trace_buf[idx]);
                }
                mlen += snprintf(msg+mlen, sizeof(msg)-mlen, "\r\n[press key]\r\n");
                for (char *p = msg; *p; p++) vterm_putch((uint8_t)*p);
                vterm_dirty = 1;
                redraw_all(&cpu);
                /* wait for any key */
                INPUT_RECORD ir; DWORD nr;
                do { ReadConsoleInput(hin, &ir, 1, &nr); }
                while (!(ir.EventType==KEY_EVENT && ir.Event.KeyEvent.bKeyDown));
                /* reset */
                memset(&cpu,0,sizeof(cpu));
                cpu.SP=0xFF; cpu.I=1;
                cpu.PC=(uint16_t)(mem[0xFFFC]|(mem[0xFFFD]<<8));
                break;
            }
        }

        /* ── refresh display ─────────────────────────────────────────── */
        display_timer += burst;
        if (display_timer >= DISPLAY_INTERVAL) {
            display_timer = 0;
            redraw_all(&cpu);
        }
    }

    /* Restore console */
    SetConsoleMode(hin, ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
    SetConsoleTextAttribute(hout, FOREGROUND_RED|FOREGROUND_GREEN|FOREGROUND_BLUE);
    {
        COORD origin = {0,0}; DWORD written;
        FillConsoleOutputCharacterA(hout, ' ', TOTAL_COLS*TOTAL_ROWS, origin, &written);
        SetConsoleCursorPosition(hout, origin);
    }
    CONSOLE_CURSOR_INFO ci = { 25, TRUE };
    SetConsoleCursorInfo(hout, &ci);

    return 0;
}
