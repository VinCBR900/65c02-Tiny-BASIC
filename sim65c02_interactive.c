/*
 * sim65c02_interactive.c  —  interactive TUI mode for sim65c02  (v3, Mar 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Provides a split-screen ncurses interface:
 *   Left pane  (40 cols × 25 rows): Virtual BASIC terminal, exact Kowalski I/O mapping
 *
 * Changes:
 *   v1  Initial Linux/ncurses version.
 *   v2  Fix CR/LF double-spacing: CR ($0D) resets column only; LF ($0A) advances row.
 *       q/Q no longer quit — they are passed to BASIC as normal input (Ctrl-C to quit).
 *       Halt message now shows op, SP, stack top 4 bytes, and last 16 PC trace.
 *       draw_terminal rewritten to use mvwaddnstr for full 40-col row rendering.
 *   Right pane (38 cols):           ZP / interpreter state panel, live-updating
 *   Status bar (bottom):            CPU registers, cycle count, speed
 *
 * Build:
 *   gcc -O2 -o sim65c02_interactive sim65c02_interactive.c -lncurses
 *   (asm65c02.c must be in same directory)
 *
 * Usage:
 *   sim65c02_interactive <file.asm | file.bin>
 *
 * Kowalski I/O ports (identical to sim65c02):
 *   $E000  write  CLS      clear virtual terminal
 *   $E001  write  PUTCH    character to virtual terminal
 *   $E004  read   GETCH    non-blocking keyboard poll (0 = no key)
 *   $E005  write  XPOS     set cursor column (0-based)
 *   $E006  write  YPOS     set cursor row (0-based)
 *   $E007  write  IRQ      fire maskable IRQ (Break key)
 *
 * 4K BASIC v11 zero-page map used for the state panel:
 *   $00-$01  IP      interpreter pointer
 *   $02-$03  PE      program end
 *   $04-$05  LP      list/edit pointer
 *   $06-$07  T0      expression result
 *   $08-$09  T1      scratch 1
 *   $0A-$0B  T2      scratch 2
 *   $0C-$0D  CURLN   current line number
 *   $0E      GRET    GOSUB nesting depth
 *   $0F      RUN     0=idle $FF=running
 *   $50-$8B  VARS    A-Z (26 × 2 bytes, signed 16-bit LE)
 *   $8C-$9B  GORET   GOSUB return stack (8 × 2 bytes)
 *   $9C      TKTOK   keyword index scratch
 *   $9D      FSTK    FOR nesting depth
 *   $9E-$B9  FOR_STK FOR frames (4 × 7 bytes)
 *   $BA      RUNSP   saved SP
 *   $BC-$BD  DATA_PTR
 *   $BE-$BF  RND_SEED
 *
 * Controls:
 *   Normal typing  →  fed to GETCH as keyboard input
 *   F1 or Ctrl-H   →  toggle panel: VARS A-Z  ↔  ZP hex dump $00-$BF
 *   F2             →  toggle panel: FOR frames  ↔  stack $0100-$01FF (top 16)
 *   F5             →  reset CPU (warm restart via reset vector)
 *   F6             →  fire maskable IRQ (Break key)
 *   Ctrl-C / Escape+q  →  quit
 *
 * Version history:
 *   v1  Initial version.
 *   v2  Fix CR/LF; q/Q as normal input; improved halt display.
 *   v3  F6 key fires maskable IRQ ($E007); status bar shows F6:break.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <ncurses.h>
#include <locale.h>

/* ── embedded assembler ──────────────────────────────────────────────────── */
#include "asm65c02.c"

/* ══════════════════════════════════════════════════════════════════════════
 * Layout constants
 * ══════════════════════════════════════════════════════════════════════════ */
#define TERM_COLS   40          /* virtual terminal width  */
#define TERM_ROWS   25          /* virtual terminal height */
#define PANEL_COL   41          /* state panel starts at column 41 */
#define STATUS_ROW  26          /* status bar row (0-based) */

/* ══════════════════════════════════════════════════════════════════════════
 * Virtual terminal state
 * ══════════════════════════════════════════════════════════════════════════ */
static char  vterm[TERM_ROWS][TERM_COLS+1]; /* character grid */
static int   vcol = 0;                       /* cursor column  */
static int   vrow = 0;                       /* cursor row     */

static void vterm_clear(void) {
    for (int r = 0; r < TERM_ROWS; r++) {
        memset(vterm[r], ' ', TERM_COLS);
        vterm[r][TERM_COLS] = '\0';
    }
    vcol = 0; vrow = 0;
}

static void vterm_scroll(void) {
    for (int r = 0; r < TERM_ROWS-1; r++)
        memcpy(vterm[r], vterm[r+1], TERM_COLS);
    memset(vterm[TERM_ROWS-1], ' ', TERM_COLS);
}

/* Output one character to the virtual terminal, handling CR/LF/wrapping */
static void vterm_putch(uint8_t ch) {
    if (ch == '\r') {
        vcol = 0;                /* CR: carriage return only — do NOT advance row */
        return;
    }
    if (ch == '\n') {
        vcol = 0;                /* LF: reset column AND advance row */
        vrow++;
        if (vrow >= TERM_ROWS) { vterm_scroll(); vrow = TERM_ROWS-1; }
        return;
    }
    if (ch == '\b') {
        if (vcol > 0) { vcol--; vterm[vrow][vcol] = ' '; }
        return;
    }
    if (ch < 0x20 || ch > 0x7E) return;   /* ignore other control chars */
    if (vcol >= TERM_COLS) {               /* wrap */
        vcol = 0; vrow++;
        if (vrow >= TERM_ROWS) { vterm_scroll(); vrow = TERM_ROWS-1; }
    }
    vterm[vrow][vcol++] = (char)ch;
}

/* ══════════════════════════════════════════════════════════════════════════
 * Keyboard input queue (fed from ncurses getch)
 * ══════════════════════════════════════════════════════════════════════════ */
#define KEYQ_MAX 256
static uint8_t keyq[KEYQ_MAX];
static int     keyq_head = 0;
static int     keyq_tail = 0;

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
 * Memory + I/O
 * ══════════════════════════════════════════════════════════════════════════ */
uint8_t mem[65536];

static uint8_t rd(uint16_t a) {
    if (a == 0xE004) return keyq_poll();   /* GETCH: consume one key */
    return mem[a];
}
static int irq_pending = 0;   /* set by F6 key / $E007 write */

static void wr(uint16_t a, uint8_t v) {
    switch (a) {
    case 0xE000:  vterm_clear();        return;  /* CLS         */
    case 0xE001:  vterm_putch(v);       return;  /* PUTCH       */
    case 0xE005:  vcol = v < TERM_COLS ? v : TERM_COLS-1; return; /* X_POS */
    case 0xE006:  vrow = v < TERM_ROWS ? v : TERM_ROWS-1; return; /* Y_POS */
    case 0xE007:  irq_pending = 1; return;                        /* IRQ   */
    default:      mem[a] = v;
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * CPU (identical to sim65c02.c)
 * ══════════════════════════════════════════════════════════════════════════ */
typedef struct { uint16_t PC; uint8_t A,X,Y,SP,N,V,D,I,Z,C; } CPU;
static uint8_t cpu_pop(CPU *cpu) { cpu->SP++; return mem[0x100 + cpu->SP]; }
#define PUSH(cpu,v)  mem[0x100+(cpu)->SP--]=(v)
#define POP(cpu)     cpu_pop(cpu)
static uint8_t pack_flags(CPU *c){return(c->N<<7)|(c->V<<6)|(1<<5)|(1<<4)|(c->D<<3)|(c->I<<2)|(c->Z<<1)|c->C;}
static void unpack_flags(CPU *c,uint8_t p){c->N=(p>>7)&1;c->V=(p>>6)&1;c->D=(p>>3)&1;c->I=(p>>2)&1;c->Z=(p>>1)&1;c->C=p&1;}
static void set_nz(CPU *c,uint8_t v){c->N=(v>>7)&1;c->Z=(v==0);}
static uint16_t zp(uint16_t pc){return mem[pc];}
static uint16_t zpx(CPU *c,uint16_t pc){return(mem[pc]+c->X)&0xFF;}
static uint16_t zpy(CPU *c,uint16_t pc){return(mem[pc]+c->Y)&0xFF;}
static uint16_t ab(uint16_t pc){return mem[pc]|(mem[pc+1]<<8);}
static uint16_t abx(CPU *c,uint16_t pc){return(mem[pc]|(mem[pc+1]<<8))+c->X;}
static uint16_t aby(CPU *c,uint16_t pc){return(mem[pc]|(mem[pc+1]<<8))+c->Y;}
static uint16_t indy(CPU *c,uint16_t pc){uint8_t z=mem[pc];return(mem[z]|(mem[(z+1)&0xFF]<<8))+c->Y;}
static uint16_t indx(CPU *c,uint16_t pc){uint8_t z=(mem[pc]+c->X)&0xFF;return mem[z]|(mem[(z+1)&0xFF]<<8);}
static uint16_t indzp(uint16_t pc){uint8_t z=mem[pc];return mem[z]|(mem[(z+1)&0xFF]<<8);}
static uint16_t ind(uint16_t pc){uint16_t a=mem[pc]|(mem[pc+1]<<8);return mem[a]|(mem[a+1]<<8);}
static void do_adc(CPU *c,uint8_t v){uint16_t r=c->A+v+c->C;c->V=(~(c->A^v)&(c->A^r)&0x80)?1:0;c->C=(r>0xFF)?1:0;c->A=r&0xFF;set_nz(c,c->A);}
static void do_sbc(CPU *c,uint8_t v){do_adc(c,v^0xFF);}
static void do_cmp(CPU *c,uint8_t reg,uint8_t v){uint16_t r=reg-v;c->C=(reg>=v)?1:0;set_nz(c,r&0xFF);}
static uint16_t branch(uint16_t pc,uint8_t off){return pc+(int8_t)off;}
static long long cycle_count=0;

/* step() — identical to sim65c02.c; returns 0=ok 1=halt */
static int step(CPU *cpu) {
    uint16_t pc=cpu->PC; uint8_t op=mem[pc]; cpu->PC++; cycle_count++;
#define RD(a)   rd(a)
#define WR(a,v) wr(a,v)
#define IMM     mem[cpu->PC]
#define ZP      zp(cpu->PC)
#define ZPX     zpx(cpu,cpu->PC)
#define ZPY     zpy(cpu,cpu->PC)
#define ABS     ab(cpu->PC)
#define ABSX    abx(cpu,cpu->PC)
#define ABSY    aby(cpu,cpu->PC)
#define INDX    indx(cpu,cpu->PC)
#define INDY    indy(cpu,cpu->PC)
#define INDZP   indzp(cpu->PC)
#define IND     ind(cpu->PC)
    switch(op){
    /* LDA */ case 0xA9:{uint8_t v=IMM;cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
              case 0xA5:{uint8_t v=RD(ZP);cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
              case 0xB5:{uint8_t v=RD(ZPX);cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
              case 0xAD:{uint8_t v=RD(ABS);cpu->PC+=2;cpu->A=v;set_nz(cpu,v);break;}
              case 0xBD:{uint8_t v=RD(ABSX);cpu->PC+=2;cpu->A=v;set_nz(cpu,v);break;}
              case 0xB9:{uint8_t v=RD(ABSY);cpu->PC+=2;cpu->A=v;set_nz(cpu,v);break;}
              case 0xA1:{uint8_t v=RD(INDX);cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
              case 0xB1:{uint8_t v=RD(INDY);cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
              case 0xB2:{uint8_t v=RD(INDZP);cpu->PC++;cpu->A=v;set_nz(cpu,v);break;}
    /* LDX */ case 0xA2:{uint8_t v=IMM;cpu->PC++;cpu->X=v;set_nz(cpu,v);break;}
              case 0xA6:{uint8_t v=RD(ZP);cpu->PC++;cpu->X=v;set_nz(cpu,v);break;}
              case 0xB6:{uint8_t v=RD(ZPY);cpu->PC++;cpu->X=v;set_nz(cpu,v);break;}
              case 0xAE:{uint8_t v=RD(ABS);cpu->PC+=2;cpu->X=v;set_nz(cpu,v);break;}
              case 0xBE:{uint8_t v=RD(ABSY);cpu->PC+=2;cpu->X=v;set_nz(cpu,v);break;}
    /* LDY */ case 0xA0:{uint8_t v=IMM;cpu->PC++;cpu->Y=v;set_nz(cpu,v);break;}
              case 0xA4:{uint8_t v=RD(ZP);cpu->PC++;cpu->Y=v;set_nz(cpu,v);break;}
              case 0xB4:{uint8_t v=RD(ZPX);cpu->PC++;cpu->Y=v;set_nz(cpu,v);break;}
              case 0xAC:{uint8_t v=RD(ABS);cpu->PC+=2;cpu->Y=v;set_nz(cpu,v);break;}
              case 0xBC:{uint8_t v=RD(ABSX);cpu->PC+=2;cpu->Y=v;set_nz(cpu,v);break;}
    /* STA */ case 0x85:{WR(ZP,cpu->A);cpu->PC++;break;}
              case 0x95:{WR(ZPX,cpu->A);cpu->PC++;break;}
              case 0x8D:{WR(ABS,cpu->A);cpu->PC+=2;break;}
              case 0x9D:{WR(ABSX,cpu->A);cpu->PC+=2;break;}
              case 0x99:{WR(ABSY,cpu->A);cpu->PC+=2;break;}
              case 0x81:{WR(INDX,cpu->A);cpu->PC++;break;}
              case 0x91:{WR(INDY,cpu->A);cpu->PC++;break;}
              case 0x92:{WR(INDZP,cpu->A);cpu->PC++;break;}
    /* STX */ case 0x86:{WR(ZP,cpu->X);cpu->PC++;break;}
              case 0x96:{WR(ZPY,cpu->X);cpu->PC++;break;}
              case 0x8E:{WR(ABS,cpu->X);cpu->PC+=2;break;}
    /* STY */ case 0x84:{WR(ZP,cpu->Y);cpu->PC++;break;}
              case 0x94:{WR(ZPX,cpu->Y);cpu->PC++;break;}
              case 0x8C:{WR(ABS,cpu->Y);cpu->PC+=2;break;}
    /* STZ */ case 0x64:{WR(ZP,0);cpu->PC++;break;}
              case 0x74:{WR(ZPX,0);cpu->PC++;break;}
              case 0x9C:{WR(ABS,0);cpu->PC+=2;break;}
              case 0x9E:{WR(ABSX,0);cpu->PC+=2;break;}
    /* ADC */ case 0x69:{do_adc(cpu,IMM);cpu->PC++;break;}
              case 0x65:{do_adc(cpu,RD(ZP));cpu->PC++;break;}
              case 0x75:{do_adc(cpu,RD(ZPX));cpu->PC++;break;}
              case 0x6D:{do_adc(cpu,RD(ABS));cpu->PC+=2;break;}
              case 0x7D:{do_adc(cpu,RD(ABSX));cpu->PC+=2;break;}
              case 0x79:{do_adc(cpu,RD(ABSY));cpu->PC+=2;break;}
              case 0x61:{do_adc(cpu,RD(INDX));cpu->PC++;break;}
              case 0x71:{do_adc(cpu,RD(INDY));cpu->PC++;break;}
              case 0x72:{do_adc(cpu,RD(INDZP));cpu->PC++;break;}
    /* SBC */ case 0xE9:{do_sbc(cpu,IMM);cpu->PC++;break;}
              case 0xE5:{do_sbc(cpu,RD(ZP));cpu->PC++;break;}
              case 0xF5:{do_sbc(cpu,RD(ZPX));cpu->PC++;break;}
              case 0xED:{do_sbc(cpu,RD(ABS));cpu->PC+=2;break;}
              case 0xFD:{do_sbc(cpu,RD(ABSX));cpu->PC+=2;break;}
              case 0xF9:{do_sbc(cpu,RD(ABSY));cpu->PC+=2;break;}
              case 0xE1:{do_sbc(cpu,RD(INDX));cpu->PC++;break;}
              case 0xF1:{do_sbc(cpu,RD(INDY));cpu->PC++;break;}
              case 0xF2:{do_sbc(cpu,RD(INDZP));cpu->PC++;break;}
    /* CMP */ case 0xC9:{do_cmp(cpu,cpu->A,IMM);cpu->PC++;break;}
              case 0xC5:{do_cmp(cpu,cpu->A,RD(ZP));cpu->PC++;break;}
              case 0xD5:{do_cmp(cpu,cpu->A,RD(ZPX));cpu->PC++;break;}
              case 0xCD:{do_cmp(cpu,cpu->A,RD(ABS));cpu->PC+=2;break;}
              case 0xDD:{do_cmp(cpu,cpu->A,RD(ABSX));cpu->PC+=2;break;}
              case 0xD9:{do_cmp(cpu,cpu->A,RD(ABSY));cpu->PC+=2;break;}
              case 0xC1:{do_cmp(cpu,cpu->A,RD(INDX));cpu->PC++;break;}
              case 0xD1:{do_cmp(cpu,cpu->A,RD(INDY));cpu->PC++;break;}
              case 0xD2:{do_cmp(cpu,cpu->A,RD(INDZP));cpu->PC++;break;}
    /* CPX */ case 0xE0:{do_cmp(cpu,cpu->X,IMM);cpu->PC++;break;}
              case 0xE4:{do_cmp(cpu,cpu->X,RD(ZP));cpu->PC++;break;}
              case 0xEC:{do_cmp(cpu,cpu->X,RD(ABS));cpu->PC+=2;break;}
    /* CPY */ case 0xC0:{do_cmp(cpu,cpu->Y,IMM);cpu->PC++;break;}
              case 0xC4:{do_cmp(cpu,cpu->Y,RD(ZP));cpu->PC++;break;}
              case 0xCC:{do_cmp(cpu,cpu->Y,RD(ABS));cpu->PC+=2;break;}
    /* AND */ case 0x29:{cpu->A&=IMM;cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x25:{cpu->A&=RD(ZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x35:{cpu->A&=RD(ZPX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x2D:{cpu->A&=RD(ABS);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x3D:{cpu->A&=RD(ABSX);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x39:{cpu->A&=RD(ABSY);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x21:{cpu->A&=RD(INDX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x31:{cpu->A&=RD(INDY);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x32:{cpu->A&=RD(INDZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
    /* ORA */ case 0x09:{cpu->A|=IMM;cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x05:{cpu->A|=RD(ZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x15:{cpu->A|=RD(ZPX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x0D:{cpu->A|=RD(ABS);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x1D:{cpu->A|=RD(ABSX);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x19:{cpu->A|=RD(ABSY);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x01:{cpu->A|=RD(INDX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x11:{cpu->A|=RD(INDY);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x12:{cpu->A|=RD(INDZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
    /* EOR */ case 0x49:{cpu->A^=IMM;cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x45:{cpu->A^=RD(ZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x55:{cpu->A^=RD(ZPX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x4D:{cpu->A^=RD(ABS);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x5D:{cpu->A^=RD(ABSX);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x59:{cpu->A^=RD(ABSY);cpu->PC+=2;set_nz(cpu,cpu->A);break;}
              case 0x41:{cpu->A^=RD(INDX);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x51:{cpu->A^=RD(INDY);cpu->PC++;set_nz(cpu,cpu->A);break;}
              case 0x52:{cpu->A^=RD(INDZP);cpu->PC++;set_nz(cpu,cpu->A);break;}
    /* BIT */ case 0x89:{uint8_t v=IMM;cpu->PC++;cpu->Z=(cpu->A&v)?0:1;break;}
              case 0x24:{uint8_t v=RD(ZP);cpu->PC++;cpu->N=(v>>7)&1;cpu->V=(v>>6)&1;cpu->Z=(cpu->A&v)?0:1;break;}
              case 0x34:{uint8_t v=RD(ZPX);cpu->PC++;cpu->N=(v>>7)&1;cpu->V=(v>>6)&1;cpu->Z=(cpu->A&v)?0:1;break;}
              case 0x2C:{uint8_t v=RD(ABS);cpu->PC+=2;cpu->N=(v>>7)&1;cpu->V=(v>>6)&1;cpu->Z=(cpu->A&v)?0:1;break;}
              case 0x3C:{uint8_t v=RD(ABSX);cpu->PC+=2;cpu->N=(v>>7)&1;cpu->V=(v>>6)&1;cpu->Z=(cpu->A&v)?0:1;break;}
    /* INC */ case 0xE6:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a)+1;WR(a,v);set_nz(cpu,v);break;}
              case 0xF6:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a)+1;WR(a,v);set_nz(cpu,v);break;}
              case 0xEE:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a)+1;WR(a,v);set_nz(cpu,v);break;}
              case 0xFE:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a)+1;WR(a,v);set_nz(cpu,v);break;}
              case 0x1A:{cpu->A++;set_nz(cpu,cpu->A);break;}
    /* DEC */ case 0xC6:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a)-1;WR(a,v);set_nz(cpu,v);break;}
              case 0xD6:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a)-1;WR(a,v);set_nz(cpu,v);break;}
              case 0xCE:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a)-1;WR(a,v);set_nz(cpu,v);break;}
              case 0xDE:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a)-1;WR(a,v);set_nz(cpu,v);break;}
              case 0x3A:{cpu->A--;set_nz(cpu,cpu->A);break;}
    /* INX/INY/DEX/DEY */
              case 0xE8:{cpu->X++;set_nz(cpu,cpu->X);break;}
              case 0xC8:{cpu->Y++;set_nz(cpu,cpu->Y);break;}
              case 0xCA:{cpu->X--;set_nz(cpu,cpu->X);break;}
              case 0x88:{cpu->Y--;set_nz(cpu,cpu->Y);break;}
    /* ASL */ case 0x0A:{cpu->C=(cpu->A>>7)&1;cpu->A<<=1;set_nz(cpu,cpu->A);break;}
              case 0x06:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a);cpu->C=(v>>7)&1;v<<=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x16:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a);cpu->C=(v>>7)&1;v<<=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x0E:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);cpu->C=(v>>7)&1;v<<=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x1E:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a);cpu->C=(v>>7)&1;v<<=1;WR(a,v);set_nz(cpu,v);break;}
    /* LSR */ case 0x4A:{cpu->C=cpu->A&1;cpu->A>>=1;set_nz(cpu,cpu->A);break;}
              case 0x46:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a);cpu->C=v&1;v>>=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x56:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a);cpu->C=v&1;v>>=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x4E:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);cpu->C=v&1;v>>=1;WR(a,v);set_nz(cpu,v);break;}
              case 0x5E:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a);cpu->C=v&1;v>>=1;WR(a,v);set_nz(cpu,v);break;}
    /* ROL */ case 0x2A:{uint8_t c=cpu->C;cpu->C=(cpu->A>>7)&1;cpu->A=(cpu->A<<1)|c;set_nz(cpu,cpu->A);break;}
              case 0x26:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=(v>>7)&1;v=(v<<1)|c;WR(a,v);set_nz(cpu,v);break;}
              case 0x36:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=(v>>7)&1;v=(v<<1)|c;WR(a,v);set_nz(cpu,v);break;}
              case 0x2E:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=(v>>7)&1;v=(v<<1)|c;WR(a,v);set_nz(cpu,v);break;}
              case 0x3E:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=(v>>7)&1;v=(v<<1)|c;WR(a,v);set_nz(cpu,v);break;}
    /* ROR */ case 0x6A:{uint8_t c=cpu->C;cpu->C=cpu->A&1;cpu->A=(cpu->A>>1)|(c<<7);set_nz(cpu,cpu->A);break;}
              case 0x66:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=v&1;v=(v>>1)|(c<<7);WR(a,v);set_nz(cpu,v);break;}
              case 0x76:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=v&1;v=(v>>1)|(c<<7);WR(a,v);set_nz(cpu,v);break;}
              case 0x6E:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=v&1;v=(v>>1)|(c<<7);WR(a,v);set_nz(cpu,v);break;}
              case 0x7E:{uint16_t a=ABSX;cpu->PC+=2;uint8_t v=RD(a);uint8_t c=cpu->C;cpu->C=v&1;v=(v>>1)|(c<<7);WR(a,v);set_nz(cpu,v);break;}
    /* TSB/TRB (65C02) */
              case 0x04:{uint16_t a=ZP;cpu->PC++;uint8_t v=RD(a);cpu->Z=(cpu->A&v)?0:1;WR(a,v|cpu->A);break;}
              case 0x14:{uint16_t a=ZPX;cpu->PC++;uint8_t v=RD(a);cpu->Z=(cpu->A&v)?0:1;WR(a,v|cpu->A);break;}
              case 0x0C:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);cpu->Z=(cpu->A&v)?0:1;WR(a,v|cpu->A);break;}
              case 0x1C:{uint16_t a=ABS;cpu->PC+=2;uint8_t v=RD(a);cpu->Z=(cpu->A&v)?0:1;WR(a,v&~cpu->A);break;}
    /* Branches */
              case 0x90:{uint8_t o=mem[cpu->PC++];if(!cpu->C)cpu->PC=branch(cpu->PC,o);break;}
              case 0xB0:{uint8_t o=mem[cpu->PC++];if(cpu->C)cpu->PC=branch(cpu->PC,o);break;}
              case 0xF0:{uint8_t o=mem[cpu->PC++];if(cpu->Z)cpu->PC=branch(cpu->PC,o);break;}
              case 0xD0:{uint8_t o=mem[cpu->PC++];if(!cpu->Z)cpu->PC=branch(cpu->PC,o);break;}
              case 0x30:{uint8_t o=mem[cpu->PC++];if(cpu->N)cpu->PC=branch(cpu->PC,o);break;}
              case 0x10:{uint8_t o=mem[cpu->PC++];if(!cpu->N)cpu->PC=branch(cpu->PC,o);break;}
              case 0x70:{uint8_t o=mem[cpu->PC++];if(cpu->V)cpu->PC=branch(cpu->PC,o);break;}
              case 0x50:{uint8_t o=mem[cpu->PC++];if(!cpu->V)cpu->PC=branch(cpu->PC,o);break;}
              case 0x80:{uint8_t o=mem[cpu->PC++];cpu->PC=branch(cpu->PC,o);break;}/* BRA */
    /* JMP  */ case 0x4C:{cpu->PC=ABS;break;}
               case 0x6C:{cpu->PC=ind(cpu->PC);break;}
               case 0x7C:{uint16_t a=(mem[cpu->PC]|(mem[cpu->PC+1]<<8))+cpu->X;cpu->PC=mem[a]|(mem[a+1]<<8);break;}
    /* JSR  */ case 0x20:{uint16_t t=ABS;uint16_t r=cpu->PC+1;PUSH(cpu,(r>>8)&0xFF);PUSH(cpu,r&0xFF);cpu->PC=t;break;}
    /* RTS  */ case 0x60:{uint8_t lo=POP(cpu),hi=POP(cpu);cpu->PC=(lo|(hi<<8))+1;break;}
    /* RTI  */ case 0x40:{unpack_flags(cpu,POP(cpu));uint8_t lo=POP(cpu),hi=POP(cpu);cpu->PC=lo|(hi<<8);break;}
    /* Push/Pull */
              case 0x48:{PUSH(cpu,cpu->A);break;}
              case 0x08:{PUSH(cpu,pack_flags(cpu));break;}
              case 0x5A:{PUSH(cpu,cpu->Y);break;}
              case 0xDA:{PUSH(cpu,cpu->X);break;}
              case 0x68:{cpu->A=POP(cpu);set_nz(cpu,cpu->A);break;}
              case 0x28:{unpack_flags(cpu,POP(cpu));break;}
              case 0x7A:{cpu->Y=POP(cpu);set_nz(cpu,cpu->Y);break;}
              case 0xFA:{cpu->X=POP(cpu);set_nz(cpu,cpu->X);break;}
    /* Transfers */
              case 0xAA:{cpu->X=cpu->A;set_nz(cpu,cpu->X);break;}
              case 0xA8:{cpu->Y=cpu->A;set_nz(cpu,cpu->Y);break;}
              case 0x8A:{cpu->A=cpu->X;set_nz(cpu,cpu->A);break;}
              case 0x98:{cpu->A=cpu->Y;set_nz(cpu,cpu->A);break;}
              case 0x9A:{cpu->SP=cpu->X;break;}
              case 0xBA:{cpu->X=cpu->SP;set_nz(cpu,cpu->X);break;}
    /* Flags  */
              case 0x18:{cpu->C=0;break;} case 0x38:{cpu->C=1;break;}
              case 0x58:{cpu->I=0;break;} case 0x78:{cpu->I=1;break;}
              case 0xB8:{cpu->V=0;break;} case 0xD8:{cpu->D=0;break;}
              case 0xF8:{cpu->D=1;break;} case 0xEA:{break;}/* NOP */
    /* BRK  */ case 0x00: return 1;
    default:   return 1;
    }
    return 0;
#undef RD
#undef WR
#undef IMM
#undef ZP
#undef ZPX
#undef ZPY
#undef ABS
#undef ABSX
#undef ABSY
#undef INDX
#undef INDY
#undef INDZP
#undef IND
}

/* ══════════════════════════════════════════════════════════════════════════
 * ncurses windows
 * ══════════════════════════════════════════════════════════════════════════ */
static WINDOW *wterm  = NULL;   /* virtual terminal  (left)  */
static WINDOW *wpanel = NULL;   /* state panel       (right) */
static WINDOW *wstatus= NULL;   /* status bar        (bottom)*/

static void create_windows(void) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);
    (void)rows; (void)cols;

    /* Virtual terminal window: row 0, col 0, 27 rows × 42 cols (border+content) */
    wterm   = newwin(TERM_ROWS+2, TERM_COLS+2, 0, 0);
    /* State panel: row 0, col 43, height fills to status bar */
    wpanel  = newwin(TERM_ROWS+2, 37, 0, TERM_COLS+3);
    /* Status bar: last row */
    wstatus = newwin(1, 80, TERM_ROWS+2, 0);

    scrollok(wterm,  FALSE);
    scrollok(wpanel, FALSE);
    keypad(stdscr, TRUE);
}

/* ══════════════════════════════════════════════════════════════════════════
 * Display rendering
 * ══════════════════════════════════════════════════════════════════════════ */
static int panel_mode = 0;  /* 0=VARS+frames, 1=ZP hex dump */

/* Decode signed 16-bit LE from memory at given address */
static int16_t mem16s(int addr) {
    return (int16_t)(mem[addr] | (mem[addr+1] << 8));
}
static uint16_t mem16u(int addr) {
    return (uint16_t)(mem[addr] | (mem[addr+1] << 8));
}

static void draw_terminal(void) {
    werase(wterm);
    box(wterm, 0, 0);
    mvwaddstr(wterm, 0, 2, " BASIC Terminal ");
    for (int r = 0; r < TERM_ROWS; r++) {
        mvwaddnstr(wterm, r+1, 1, vterm[r], TERM_COLS);
    }
    /* show cursor */
    int cr = vrow+1, cc = vcol+1;
    if (cr >= 1 && cr <= TERM_ROWS && cc >= 1 && cc <= TERM_COLS) {
        char ch = vterm[vrow][vcol];
        wattron(wterm, A_REVERSE);
        mvwaddch(wterm, cr, cc, (ch >= 0x20 && ch <= 0x7E) ? ch : ' ');
        wattroff(wterm, A_REVERSE);
    }
    wnoutrefresh(wterm);
}

static void draw_panel_vars(void) {
    werase(wpanel);
    box(wpanel, 0, 0);

    /* Header */
    uint16_t ip    = mem16u(0x00);
    uint16_t pe    = mem16u(0x02);
    uint8_t  run   = mem[0x0F];
    uint16_t curln = mem16u(0x0C);
    uint8_t  gret  = mem[0x0E];
    uint8_t  fstk  = mem[0x9D];
    uint8_t  runsp = mem[0xBA];

    mvwprintw(wpanel, 0, 2, " Interpreter State ");

    int row = 1;
    wattron(wpanel, A_BOLD);
    mvwprintw(wpanel, row++, 1, "IP:%04X PE:%04X CURLN:%5u", ip, pe, curln);
    mvwprintw(wpanel, row++, 1, "RUN:%-3s  FSTK:%u GRET:%u SP:%02X",
              run ? "RUN" : "---", fstk, gret, runsp);
    wattroff(wpanel, A_BOLD);

    /* T0/T1/T2 */
    mvwprintw(wpanel, row++, 1, "T0:%04X T1:%04X T2:%04X",
              mem16u(0x06), mem16u(0x08), mem16u(0x0A));

    /* DATA_PTR / RND_SEED */
    mvwprintw(wpanel, row++, 1, "DATA:%04X RND:%04X",
              mem16u(0xBC), mem16u(0xBE));

    /* Divider */
    mvwhline(wpanel, row++, 1, ACS_HLINE, 34);

    /* VARS A–Z in 3 columns */
    wattron(wpanel, A_BOLD);
    mvwaddstr(wpanel, row++, 1, "Variables A-Z (signed 16-bit):");
    wattroff(wpanel, A_BOLD);
    for (int i = 0; i < 26; i++) {
        int16_t val = mem16s(0x50 + i*2);
        int col_off = (i % 3) * 12;
        if (i % 3 == 0) { /* start new row */
            if (i > 0) row++;
            /* print label on this row */
        }
        mvwprintw(wpanel, row, 1 + col_off, "%c:%-6d", 'A'+i, val);
    }
    row += 2;  /* last row of vars + blank */

    /* Divider */
    if (row < TERM_ROWS) mvwhline(wpanel, row++, 1, ACS_HLINE, 34);

    /* FOR stack frames */
    if (fstk > 0 && row < TERM_ROWS+1) {
        wattron(wpanel, A_BOLD);
        mvwprintw(wpanel, row++, 1, "FOR stack (%u frame%s):", fstk, fstk==1?"":"s");
        wattroff(wpanel, A_BOLD);
        for (int f = 0; f < (int)fstk && row < TERM_ROWS+1; f++) {
            int base = 0x9E + f*7;
            uint8_t  slot  = mem[base+0];
            int16_t  lim   = mem16s(base+1);
            int16_t  step  = mem16s(base+3);
            uint16_t lline = mem16u(base+5);
            char varname   = (slot < 52) ? ('A' + slot/2) : '?';
            mvwprintw(wpanel, row++, 1, " [%d]%c lim=%-5d stp=%-4d ln=%u",
                      f, varname, lim, step, lline);
        }
    } else if (row < TERM_ROWS+1) {
        mvwaddstr(wpanel, row++, 1, "FOR stack: (empty)");
    }

    /* GOSUB return stack */
    if (gret > 0 && row < TERM_ROWS+1) {
        wattron(wpanel, A_BOLD);
        mvwprintw(wpanel, row++, 1, "GOSUB stack (%u):", gret);
        wattroff(wpanel, A_BOLD);
        for (int g = 0; g < (int)gret && row < TERM_ROWS+1; g++) {
            mvwprintw(wpanel, row++, 1, "  [%d] ret=$%04X", g, mem16u(0x8C + g*2));
        }
    }

    wnoutrefresh(wpanel);
}

static void draw_panel_zp(void) {
    werase(wpanel);
    box(wpanel, 0, 0);
    mvwaddstr(wpanel, 0, 2, " Zero Page $00-$BF ");

    for (int row = 0; row < 12; row++) {
        int addr = row * 16;
        mvwprintw(wpanel, row+1, 1, "%02X:", addr);
        for (int col = 0; col < 16 && addr+col <= 0xBF; col++) {
            mvwprintw(wpanel, row+1, 4 + col*2, "%02X", mem[addr+col]);
        }
    }
    wnoutrefresh(wpanel);
}

static void draw_status(CPU *cpu, long long cycles) {
    werase(wstatus);
    wattron(wstatus, A_REVERSE);
    mvwprintw(wstatus, 0, 0,
        " PC:%04X A:%02X X:%02X Y:%02X SP:%02X  N%dV%dD%dI%dZ%dC%d"
        "  Cyc:%-12lld  F1:ZP F5:reset F6:break Ctrl-C:quit",
        cpu->PC, cpu->A, cpu->X, cpu->Y, cpu->SP,
        cpu->N, cpu->V, cpu->D, cpu->I, cpu->Z, cpu->C,
        cycles);
    /* pad to end of line */
    int y,x; getyx(wstatus,y,x); (void)y;
    for(int i=x;i<79;i++) waddch(wstatus,' ');
    wattroff(wstatus, A_REVERSE);
    wnoutrefresh(wstatus);
}

static void redraw_all(CPU *cpu, long long cycles) {
    draw_terminal();
    if (panel_mode == 0) draw_panel_vars();
    else                 draw_panel_zp();
    draw_status(cpu, cycles);
    doupdate();
}

/* ══════════════════════════════════════════════════════════════════════════
 * ROM loading (same as sim65c02.c)
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
    if(fread(mem+base,1,sz,f)<(size_t)sz&&sz<65536){fclose(f);fprintf(stderr,"Short read %s\n",path);return -1;}
    fclose(f);
    return 0;
}
static int assemble_and_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return -1; }
    static char source[1024*1024];
    size_t n = fread(source, 1, sizeof(source)-1, f);
    fclose(f);
    source[n] = '\0';
    memset(mem, 0, sizeof(mem));
    int ok = assemble(source);
    if (!ok) {
        fprintf(stderr, "Assembly failed (%d error(s)):\n", nerrors);
        for (int i = 0; i < nerrors; i++) fprintf(stderr, "  %s\n", errors[i]);
        return -1;
    }
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 * main
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "sim65c02_interactive — interactive 65C02 simulator with TUI\n"
            "Usage: sim65c02_interactive <file.asm | file.bin>\n"
            "  F1  toggle ZP hex dump panel\n"
            "  F5  reset CPU\n"
            "  F6  fire IRQ (Break key)\n"
            "  Ctrl-C  quit\n"
            "\nBuild: gcc -O2 -o sim65c02_interactive sim65c02_interactive.c -lncurses\n"
        );
        return 1;
    }

    const char *filename = NULL;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] != '-') { filename = argv[i]; break; }
        if (!strcmp(argv[i],"--load-addr") && i+1<argc) {
            bin_load_addr = (uint32_t)strtoul(argv[++i],NULL,0);
        }
    }
    if (!filename) { fprintf(stderr,"No input file\n"); return 1; }

    /* load ROM before ncurses init so errors go to stderr cleanly */
    memset(mem, 0, sizeof(mem));
    size_t fnlen = strlen(filename);
    if (fnlen > 4 && !strcmp(filename+fnlen-4, ".asm")) {
        if (assemble_and_load(filename) < 0) return 1;
        fprintf(stderr,"[SIM] Assembly OK\n");
    } else {
        if (load_bin(filename) < 0) return 1;
    }

    /* init CPU */
    CPU cpu;
    memset(&cpu, 0, sizeof(cpu));
    cpu.SP = 0xFF; cpu.I = 1;
    cpu.PC = mem[0xFFFC] | (mem[0xFFFD] << 8);
    if (!cpu.PC) { fprintf(stderr,"Reset vector $0000 — bad ROM?\n"); return 1; }

    /* find GETCH address */
    uint16_t getch_addr = 0;
    for (int ga = 0xF000; ga < 0xFFFF-3; ga++) {
        if (mem[ga]==0xAD && mem[ga+1]==0x04 && mem[ga+2]==0xE0 && mem[ga+3]==0xF0) {
            getch_addr = ga; break;
        }
    }

    /* init vterm */
    vterm_clear();

    /* init ncurses */
    setlocale(LC_ALL, "");
    initscr();
    cbreak();
    noecho();
    nodelay(stdscr, TRUE);   /* non-blocking getch */
    keypad(stdscr, TRUE);
    curs_set(0);

    if (has_colors()) {
        start_color();
        init_pair(1, COLOR_GREEN,  COLOR_BLACK);
        init_pair(2, COLOR_CYAN,   COLOR_BLACK);
        init_pair(3, COLOR_YELLOW, COLOR_BLACK);
    }

    create_windows();

    /* check terminal is big enough */
    {
        int rows, cols;
        getmaxyx(stdscr, rows, cols);
        if (rows < TERM_ROWS+3 || cols < TERM_COLS+40) {
            endwin();
            fprintf(stderr,"Terminal too small. Need at least %dx%d, have %dx%d\n",
                    TERM_COLS+40, TERM_ROWS+3, cols, rows);
            return 1;
        }
    }

    /* ── main loop ─────────────────────────────────────────────────────── */
    long long cycles = 0;
    long long display_timer = 0;

    /* PC trace ring buffer — last 16 PCs before any halt */
    #define TRACE_N 16
    uint16_t trace_buf[TRACE_N]; int trace_pos = 0;
    memset(trace_buf, 0, sizeof(trace_buf));
    const long long DISPLAY_INTERVAL = 50000;   /* refresh every 50K cycles */
    int quit = 0;

    redraw_all(&cpu, cycles);

    while (!quit) {
        /* ── handle keyboard input ───────────────────────────────────── */
        int ch = wgetch(stdscr);
        if (ch != ERR) {
            switch (ch) {
            case KEY_F(1): panel_mode ^= 1; break;
            case KEY_F(5):
                /* reset CPU */
                memset(&cpu, 0, sizeof(cpu));
                cpu.SP = 0xFF; cpu.I = 1;
                cpu.PC = mem[0xFFFC] | (mem[0xFFFD] << 8);
                cycle_count = 0; cycles = 0;
                vterm_clear();
                break;
            case KEY_F(6):
                /* fire maskable IRQ (Break key) */
                wr(0xE007, 1);
                break;
            case 'q':
            case 'Q':
                keyq_push((uint8_t)ch); break;  /* q/Q = normal input, not quit */
            case 3:   /* Ctrl-C */
                quit = 1; break;
            case KEY_BACKSPACE:
            case 127:
            case 8:
                keyq_push('\b'); break;
            case KEY_ENTER:
            case '\n':
            case '\r':
                keyq_push('\r'); break;
            case KEY_UP:    keyq_push(0x1B); keyq_push('['); keyq_push('A'); break;
            case KEY_DOWN:  keyq_push(0x1B); keyq_push('['); keyq_push('B'); break;
            case KEY_LEFT:  keyq_push(0x1B); keyq_push('['); keyq_push('D'); break;
            case KEY_RIGHT: keyq_push(0x1B); keyq_push('['); keyq_push('C'); break;
            default:
                if (ch >= 0x20 && ch <= 0x7E) keyq_push((uint8_t)ch);
                else if (ch >= 1 && ch <= 26)  keyq_push((uint8_t)ch); /* ctrl chars */
                break;
            }
        }

        /* ── run CPU for a burst of cycles ──────────────────────────── */
        /* If GETCH is spinning and keyq is empty, slow down to avoid
           burning 100% CPU; otherwise run at full speed */
        int burst = 2000;
        if (getch_addr && cpu.PC == getch_addr && keyq_empty()) {
            burst = 10;   /* idle: run slowly, check keys often */
        }

        for (int i = 0; i < burst && !quit; i++) {
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
            cycles++;
            if (r) {
                /* BRK or unknown opcode — show trace then pause */
                char msg[512]; int mlen = 0;
                mlen += snprintf(msg+mlen, sizeof(msg)-mlen,
                    "\r\n[HALT $%04X op=$%02X SP=$%02X]\r\n"
                    "Stk: %02X %02X %02X %02X\r\nTrace:",
                    cpu.PC-1, mem[cpu.PC-1], cpu.SP,
                    mem[0x100+(uint8_t)(cpu.SP+1)], mem[0x100+(uint8_t)(cpu.SP+2)],
                    mem[0x100+(uint8_t)(cpu.SP+3)], mem[0x100+(uint8_t)(cpu.SP+4)]);
                for (int t = 0; t < TRACE_N; t++) {
                    int idx = (trace_pos - TRACE_N + t + TRACE_N*1000) % TRACE_N;
                    mlen += snprintf(msg+mlen, sizeof(msg)-mlen, " $%04X", trace_buf[idx]);
                }
                mlen += snprintf(msg+mlen, sizeof(msg)-mlen, "\r\n[press key]\r\n");
                for (char *p = msg; *p; p++) vterm_putch((uint8_t)*p);
                /* wait for keypress before continuing */
                nodelay(stdscr, FALSE);
                wgetch(stdscr);
                nodelay(stdscr, TRUE);
                /* re-init CPU at reset vector */
                memset(&cpu, 0, sizeof(cpu));
                cpu.SP = 0xFF; cpu.I = 1;
                cpu.PC = mem[0xFFFC] | (mem[0xFFFD] << 8);
                break;
            }
        }
        cycles = cycle_count;

        /* ── refresh display ─────────────────────────────────────────── */
        display_timer += burst;
        if (display_timer >= DISPLAY_INTERVAL) {
            display_timer = 0;
            redraw_all(&cpu, cycles);
        }
    }

    endwin();
    return 0;
}
