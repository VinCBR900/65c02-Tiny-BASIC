/*
 * sim65c02.c  —  Toy 65C02 simulator  (v8, Jun 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Canonical simulator for:
 *   uBASIC6502.asm  v1.4  John Bell Engineering PN 80-153 port
 *                         (2 KB ROM at $F800-$FFFF, 1 KB RAM $0000-$03FF)
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
 *   --maxcycles N      Cycle limit before forced exit (default 500 000 000).
 *   --plain            Suppress ANSI escape sequences; CR→LF.
 *   --verbose          Print every instruction as it executes.  Very slow.
 *   --stats            Print cycle count and key zero-page values on exit.
 *   --load-addr 0xNNNN Override auto-detected load address for .bin files.
 *   --help             Print this help and exit.
 *
 * Bell SBC I/O model (6522 VIA bitbang UART):
 *   $1C03  write  VIA_DDRA   silently accepted (direction register)
 *   $1C0F  write  VIA_ORA    bitbang TX: accumulate start+8 data+stop bits,
 *                             reconstruct byte, print to stdout
 *   $1C0F  read   VIA_ORA    bitbang RX: return $02 (PA1=mark/idle) when no
 *                             char ready; serve one char per GETCH call cycle
 *
 * Bitbang timing bypass:
 *   After assembly, sym_get() locates DELAY_BIT and DELAY_HALF symbols.
 *   JSR to either address is intercepted and treated as an instant RTS,
 *   making IO fast without altering any other behaviour.
 *
 * GETCH idle detection:
 *   Scans ROM for the Bell GETCH spin pattern:
 *     LDA $1C0F ($AD $0F $1C) / AND #$02 ($29 $02) / BNE ...
 *   When input is exhausted and PC is at this address for 50 000 consecutive
 *   cycles the simulator terminates gracefully.
 *
 * Reset vector at $FFFC/$FFFD is used to set the initial PC on startup.
 *
 * Typical invocations:
 *   ./sim65c02 uBASIC6502.asm --plain --input "PRINT 6*7"
 *   ./sim65c02 uBASIC6502.asm --plain --input "10 PRINT 42" --input "RUN"
 *   ./sim65c02 uBASIC6502.asm --plain --input "LIST"
 *
 * Version history:
 *   v1-v6  Kowalski/uBASIC simulator (see sim65c02_kowalski_archive.c).
 *   v7     Header updated; --plain documented.
 *   v8     Ported to John Bell Engineering PN 80-153 I/O model.
 *          Replaced Kowalski virtual ports ($E000-$E007) with 6522 VIA
 *          bitbang UART at $1C03/$1C0F.  Added TX bit accumulator,
 *          DELAY_BIT/DELAY_HALF symbol interception, updated GETCH pattern scan.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* ── terminal cursor state ───────────────────────────────────────────────── */
static int plain_mode = 0;   /* --plain: suppress ANSI escapes; CR→LF */

/* ── memory ──────────────────────────────────────────────────────────────── */
uint8_t mem[65536];   /* shared with embedded asm65c02.c */

/* ── Bell SBC 6522 VIA bitbang UART model ───────────────────────────────── */
/*
 * TX state machine: tracks start + 8 data + stop bit sequence on VIA_ORA.
 * State values: 0=idle, 1=start bit seen, 2-9=data bits 0-7, 10=stop.
 * Each wr($1C0F) call advances the machine by one bit.
 */
#define VIA_ORA_ADDR  0x1C0F
#define VIA_DDRA_ADDR 0x1C03
#define VIA_RX_BIT    0x02   /* PA1 = RX */
#define VIA_TX_BIT    0x01   /* PA0 = TX */

static int     tx_state = 0;      /* 0=idle, 1=start, 2-9=bit0-7, 10=stop */
static uint8_t tx_shift = 0;      /* accumulates received data bits */

/* RX state: serve one character per GETCH call.
 * rx_serving=1 once we've triggered on the start-bit poll transition.
 * rx_bit_phase counts which bit the GETCH loop is about to sample (0-7). */
static int     rx_serving  = 0;   /* 1 while a byte is being 'received' */
static int     rx_bit_phase= 0;   /* 0-7: next bit to deliver to ROR TEMP */
static uint8_t rx_char     = 0;   /* character currently being received */

/* Delay loop addresses - populated after assembly */
static uint16_t delay_bit_addr  = 0;
static uint16_t delay_half_addr = 0;

static uint8_t rd(uint16_t a) {
    if (a == VIA_ORA_ADDR) {
        /* GETCH polls VIA_ORA, ANDs with VIA_RX_BIT ($02), BNEs if set.
         * Idle (mark) = PA1=1 → return $02.  Start bit = PA1=0 → return $00.
         * Once a start bit is signalled, rx_serving drives the byte delivery. */
        if (!rx_serving) {
            if (inbuf_pos < inbuf_len) {
                /* Start bit: PA1 goes low.  Latch the char and begin serving. */
                rx_char      = (uint8_t)inbuf[inbuf_pos++];
                rx_serving   = 1;
                rx_bit_phase = 0;
                return 0x00;   /* PA1=0: start bit detected */
            }
            return VIA_RX_BIT; /* PA1=1: idle/mark, no char */
        } else {
            /* Mid-receive: return the current data bit on PA1 (bit 1).
             * GETCH does: LDA VIA_ORA / LSR A / LSR A / ROR TEMP
             * Two LSRs shift PA1 into carry for ROR.  So we set PA1 = data bit. */
            uint8_t bit = (rx_char >> rx_bit_phase) & 1;
            rx_bit_phase++;
            if (rx_bit_phase >= 8) {
                rx_serving = 0;  /* byte complete; back to idle after stop bit */
            }
            return bit ? VIA_RX_BIT : 0x00;  /* PA1 = data bit */
        }
    }
    return mem[a];
}

static void wr(uint16_t a, uint8_t v) {
    if (a == VIA_DDRA_ADDR) {
        /* DDRA write: direction setup - silently accept */
        return;
    }
    if (a == VIA_ORA_ADDR) {
        /* Bitbang TX: accumulate bits, reconstruct byte on stop bit */
        switch (tx_state) {
        case 0:  /* idle - expect start bit (PA0=0) */
            if ((v & VIA_TX_BIT) == 0) {
                tx_state = 1;
                tx_shift = 0;
            }
            break;
        case 1:  /* start bit consumed, now data bits 0-7 */
        case 2: case 3: case 4: case 5:
        case 6: case 7: case 8:
            /* data bit: PA0 is the bit value */
            tx_shift |= (uint8_t)((v & VIA_TX_BIT) << (tx_state - 1));
            tx_state++;
            break;
        case 9:  /* stop bit (PA0=1): byte complete */
            if (plain_mode) {
                if (tx_shift == '\r') putchar('\n');
                else if (tx_shift >= 0x20 && tx_shift <= 0x7E) putchar(tx_shift);
            } else {
                putchar(tx_shift);
            }
            fflush(stdout);
            tx_state = 0;
            tx_shift = 0;
            break;
        }
        return;
    }
    mem[a] = v;
}


/* ── CPU state ───────────────────────────────────────────────────────────── */
typedef struct {
    uint16_t PC;
    uint8_t  A, X, Y, SP;
    /* flags */
    uint8_t  N, V, D, I, Z, C; /* each 0 or 1 */
} CPU;

#define PUSH(cpu,v)  mem[0x100 + (cpu)->SP--] = (v)
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
        /* Intercept JSR to DELAY_BIT or DELAY_HALF: treat as instant RTS.
         * Without this the bitbang timing loops consume millions of simulated
         * cycles per character making IO unusably slow. */
        if ((delay_bit_addr  && target == delay_bit_addr) ||
            (delay_half_addr && target == delay_half_addr)) {
            cpu->PC += 2;   /* skip the 2-byte operand; PC now past JSR */
            return 0;        /* no push/pop: instant return */
        }
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
        "sim65c02 v8 -- 65C02 simulator for uBASIC6502 v1.4 (John Bell Engineering SBC)\n"
        "\n"
        "Usage:\n"
        "  sim65c02 <file.asm | file.bin> [options]\n"
        "  sim65c02 --help\n"
        "\n"
        "Options:\n"
        "  --input \"line\"     Queue a line of input (CR appended); repeatable.\n"
        "  --maxcycles N      Cycle limit before forced exit (default 500000000).\n"
        "  --plain            CR->LF translation; drop non-printable (for piped output).\n"
        "  --verbose          Print every instruction executed (very slow).\n"
        "  --stats            Print cycle count and ZP state on exit.\n"
        "  --load-addr 0xNNNN Override auto-detected load address for .bin files.\n"
        "  --help             Print this help and exit.\n"
        "\n"
        "Examples:\n"
        "  sim65c02 uBASIC6502.asm --plain --input \"PRINT 6*7\"\n"
        "  sim65c02 uBASIC6502.asm --plain --input \"10 PRINT 42\" --input \"RUN\"\n"
        "  sim65c02 uBASIC6502.asm --plain --input \"10 FOR I=1 TO 5\" --input \"20 PRINT I\" --input \"30 NEXT I\" --input \"RUN\"\n"
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
        else if(!strcmp(argv[i],"--plain"))    { plain_mode=1; }
        else if(!strcmp(argv[i],"--verbose")) { verbose=1; }
        else if(!strcmp(argv[i],"--stats"))   { show_stats=1; }
        else if(!strcmp(argv[i],"--load-addr") && i+1<argc) { bin_load_addr=(uint32_t)strtoul(argv[++i],NULL,0); }
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
    fprintf(stderr,"[SIM] Reset PC=$%04X  maxcycles=%lld\n",cpu.PC,maxcycles);

    /* locate DELAY_BIT and DELAY_HALF via symbol table (populated by assembler).
     * JSR to these addresses is intercepted in step() and treated as instant RTS,
     * making bitbang IO fast without altering any other behaviour. */
    {
        int v = 0;
        if (sym_get("DELAY_BIT",  &v)) {
            delay_bit_addr  = (uint16_t)v;
            fprintf(stderr,"[SIM] DELAY_BIT  at $%04X (intercepted)\n", delay_bit_addr);
        } else {
            fprintf(stderr,"[SIM] DELAY_BIT  not found - bitbang IO will be slow\n");
        }
        if (sym_get("DELAY_HALF", &v)) {
            delay_half_addr = (uint16_t)v;
            fprintf(stderr,"[SIM] DELAY_HALF at $%04X (intercepted)\n", delay_half_addr);
        } else {
            fprintf(stderr,"[SIM] DELAY_HALF not found - bitbang IO will be slow\n");
        }
    }

    /* detect GC_WAIT: scan ROM for Bell GETCH spin pattern
     *   LDA $1C0F ($AD $0F $1C) / AND #$02 ($29 $02) / BNE ... ($D0)  */
    uint16_t getch_addr = 0;
    for(int ga=0xF000; ga<0xFFFF-5; ga++) {
        if(mem[ga  ]==0xAD && mem[ga+1]==0x0F && mem[ga+2]==0x1C &&
           mem[ga+3]==0x29 && mem[ga+4]==0x02 &&
           mem[ga+5]==0xD0) {
            getch_addr = ga;
            break;
        }
    }
    if (getch_addr)
        fprintf(stderr,"[SIM] GC_WAIT detected at $%04X\n", getch_addr);
    else
        fprintf(stderr,"[SIM] GC_WAIT not found - idle termination disabled\n");

    /* run */
    long long cycles=0;
    long long getch_idle=0;
    while(cycles < maxcycles){
        /* detect spinning in GC_WAIT with empty input queue -> terminate.
         * The GETCH function spans getch_addr .. delay_bit_addr-1; we count
         * idle cycles whenever PC is anywhere in that range with no input left,
         * and only reset the counter when PC leaves the function entirely. */
        if(getch_addr && inbuf_pos >= inbuf_len && !rx_serving &&
           cpu.PC >= getch_addr && (delay_bit_addr==0 || cpu.PC < delay_bit_addr)) {
            if(++getch_idle > 50000) {
                fprintf(stderr,"\n[SIM] Input exhausted after %lld cycles\n",cycles);
                break;
            }
        } else if(delay_bit_addr && cpu.PC >= delay_bit_addr) {
            getch_idle = 0;  /* PC left the GETCH region */
        }

        int r=step(&cpu);
        cycles++;
        if(r) {
            fprintf(stderr,"\n[SIM] Halted (BRK/unknown) at $%04X after %lld cycles\n",
                    cpu.PC-1,cycles);
            break;
        }
        /* NMI/IRQ: Bell port uses NMI for Break pushbutton, IRQ for 6522 peripherals.
         * Simulator does not generate either; vectors are intact in ROM if needed. */
    }
    if(cycles>=maxcycles)
        fprintf(stderr,"\n[SIM] Cycle limit %lld reached\n",maxcycles);

    if(show_stats){
        fprintf(stderr,"[SIM] Total cycles: %lld\n",cycles);
        fprintf(stderr,"[SIM] ZP dump: IP=%02X%02X PE=%02X%02X RUN=%02X\n",
                mem[1],mem[0],mem[3],mem[2],mem[0x0E]);
    }
    return 0;
}
