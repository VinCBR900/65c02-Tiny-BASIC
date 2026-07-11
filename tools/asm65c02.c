/*
 * asm65c02.c  —  Two-pass Toy 65C02 assembler  (v1.12, Jul 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Also used as an embedded assembler inside sim65c02.c (included directly).
 *
 * Changelog & Version History (Newest First)
 *
 * v1.12 (Jul 2026) — Expression Parsing Correction
 *   - FIXED: Reordered `eval_expr()` parsing sequence to scan for binary and 
 *     comparison operators before checking atoms, resolving expression truncation 
 *     bugs on literal-first inputs (e.g., "$10+$20" truncating to $10).
 *   - Relocated the unary minus evaluator directly into the atom processing block.
 *
 * v1.11 (Jul 2026) — Conditional Assembly
 *   - ADDED: Support for conditional assembly directives (.IF expr, .ELSE, .ENDIF) 
 *     following Kowalski conventions, supporting up to 16 nesting levels.
 *   - ADDED: Equality (==) and inequality (!=) comparison operators to `eval_expr()`.
 *   - Conditions are evaluated exactly once during Pass 1; forward-referenced 
 *     symbols within a conditional block trigger a hard error by design.
 *   * Note: Include file expansion (.INCLUDE) runs prior to conditional checking; 
 *     files within unexecuted conditional blocks are still processed.
 *
 * v1.10 (Jul 2026) — Directive Aliasing
 *   - ADDED: Support for the .RS storage reservation directive as a recognized alias 
 *     for .RES, fully integrated across pass sizing, emission, and listing pipelines.
 *
 * v1.9 (Jul 2026) — Audit Pass & Syntax Regression Fixes
 *   - ADDED: M_IND_X (zp,X) and M_IND_ABSX JMP (abs,X) addressing modes.
 *   - ADDED: Missing absolute indexed opcode mappings across ADC, CMP, SBC, AND, 
 *     EOR, ORA, ASL, LSR, ROL, ROR, DEC, INC, and LDY instruction groups.
 *   - Integrated TSB, TRB, and STZ abs,X ($9E) into the master OPTAB.
 *   - ADDED: Rockwell/WDC bit extensions: BBR0-7/BBS0-7 (zp,target) and RMB0-7/SMB0-7 (zp).
 *   - ADDED: Core file directives: .INCLUDE (depth-capped) and .INCBIN.
 *   - Assembling 65C02 opcodes outside of explicit target scopes now throws a warning.
 *   - ADDED: CLI flags: -NoWarn65c02 (suppress warnings) and -Strict6502 (warnings become errors).
 *   - Updated cpu_mode to tri-state; Pass 2 now explicitly resets target mode context.
 *   - FIXED: Explicit widths (e.g., $0000) now correctly force absolute addressing modes.
 *   - FIXED: LDX zp,Y entry corrected from mis-mapped M_ZPX ($96) to M_ZPY ($B6).
 *   - FIXED: Post-error diagnostic listings are now gated on successful assembly (ok==1).
 *   * Note: STP ($DB) and WAI ($CB) remain explicitly out of scope.
 *
 * v1.8 — Correctness & Compatibility Pass
 *   - FIXED: Explicit "A" operands (e.g., INC A) are now properly parsed as M_ACC.
 *   - FIXED: has_undef() now skips literal prefixes ($, %%, decimal), preventing hex digits 
 *     A-F in literals from being falsely evaluated as undefined forward symbols.
 *   - FIXED: Enforced consistent PC masking across all emissions and labels; integrated 
 *     check_pc_overflow() to convert image-wrapping faults into hard assembly errors.
 *   - FIXED: Resolved potential C undefined behavior by adding explicit NULL checks in derive_lst_path().
 *
 * v1.7 — Listing Output
 *   - Enabled sidecar .LST listing file generation by default.
 *   - Added -NoList CLI switch to suppress listing generation.
 *
 * v1.6 — CPU Target Switching
 *   - Added target control directives: .opt proc6502 / .opt proc65c02 and .setcpu.
 *   - In strict 6502 mode, the assembler flags all 65C02-specific opcodes, accumulator 
 *     syntax variations, immediate BIT modes, and no-index indirect zero-page modes as errors.
 *
 * v1.5 — CLI Refresh
 *   - Added -o <file> for custom output names and -r $HHHH-$HHHH for binary range extraction.
 *   - Enforced strict command-line parsing to explicitly reject unknown arguments.
 *   - Implemented the AsmStats tracking structure for transparent size reporting.
 *
 * v1.4 — Opcode Correction
 *   - Added the missing SED opcode ($F8, Set Decimal Mode) to the master instruction table.
 *
 * v1.3 — Forward-Reference Sizing
 *   - Any Pass 1 expression containing an undefined or forward symbol now automatically 
 *     forces absolute addressing modes (ABS/ABSX/ABSY) to safely guarantee size constraints.
 *
 * v1.2 — Stack Protection
 *   - Converted source_copy[] allocation to static, preventing a 1MB stack overflow crash on Windows.
 *
 * Build (standalone):
 *   gcc -O2 -DASM65C02_MAIN -o asm65c02 asm65c02.c
 *
 *   (The -DASM65C02_MAIN flag enables main(); without it the file is a
 *    pure library suitable for #include by sim65c02.c.)
 *
 * Usage:
 *   asm65c02 <file.asm> [options]
 *   asm65c02 --help
 *
 * Options:
 *   (none)          Assemble and print symbol report + ROM size summary to stdout.
 *                   Exit code 0 on success, 1 on assembly errors.
 *   --binary        Write raw 65 536-byte flat memory image to stdout.
 *                   Errors go to stderr.  Used internally by sim65c02.
 *   -o <file>       Write binary image to <file> (avoids stdout/binary issues on Win32).
 *   -r $HHHH-$HHHH  Limit binary output to address range (requires --binary or -o).
 *   -NoList        Suppress default sidecar .LST listing generation.
 *                   Preferred ROM extraction examples:
 *                     uBASIC (2 KB at $F800):   -r $F800-$FFFF
 *                     4K BASIC (4 KB at $F000): -r $F000-$FFFF
 *   -NoWarn65c02    Suppress the default warning issued whenever a 65C02-only
 *                   instruction is assembled in default (65C02) CPU mode.
 *   -Strict6502     Treat every 65C02-only instruction as a hard error even in
 *                   default (65C02) CPU mode, without needing .opt proc6502 in
 *                   the source. Overrides -NoWarn65c02 if both are given.
 *   --dump-all      After the key-symbol table, print every assembled symbol
 *                   sorted by address.  Useful for detailed size analysis.
 *   --help, -h      Print this help and exit.
 *
 * Supported syntax (Kowalski-compatible subset):
 *   Directives : .ORG addr
 *                .DB / .BYTE  val[,val,...]   (values or "string literals")
 *                .DW / .WORD  val[,val,...]   (16-bit little-endian)
 *                .RES / .RS  n[,fill]            (reserve n bytes, optional fill)
 *                .IF expr / .ELSE / .ENDIF     (conditional assembly; see
 *                                v1.11 changelog above for the forward-
 *                                reference restriction and other caveats)
 *                .opt proc6502 / .opt proc65c02
 *                .setcpu "6502" / .setcpu "65C02"
 *                                (switch CPU mode; proc6502 enables 6502-only checks)
 *   Equates    : NAME = expression
 *   Labels     : GLOBAL_LABEL:
 *                @local_label:   (scope resets at each new global label)
 *   Addressing : implied / accumulator / immediate (#)
 *                zero-page, zero-page,X, zero-page,Y
 *                absolute, absolute,X, absolute,Y
 *                (indirect), (zp indirect), (zp),Y, (zp,X), JMP (abs,X)
 *   65C02 bit ops: RMBn/SMBn zp   (n=0-7, single operand)
 *                  BBRn/BBSn zp,target  (n=0-7, TWO comma-separated operands)
 *                relative (branch instructions)
 *   Expressions: decimal  $hex  %binary  'char'  "char"  * (current PC)
 *                <lo-byte  >hi-byte  + - * /  == !=  ( )
 *                (== and != are for .IF conditions; lowest precedence)
 *   Comments   : ; to end of line
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>

/* ── limits ──────────────────────────────────────────────────────────────── */
#define MAX_LINES    8192
#define MAX_INCLUDE_DEPTH 16   /* v1.9: .INCLUDE recursion guard */
#define MAX_SYMS     2048
#define MAX_ERRORS   256
#define MAX_WARNINGS 256
#define SYM_NAME_LEN 64
#define LINE_LEN     512
#define ERR_LEN      128

/* ── addressing modes ────────────────────────────────────────────────────── */
/*
 * v1.9: added M_IND_X and M_IND_ABSX.
 *   M_IND_X    = (zp,X)   zero-page indexed indirect, 2 bytes.
 *                Used by adc/and/cmp/eor/lda/ora/sbc/sta. Present on both
 *                NMOS 6502 and 65C02 -- NOT 65C02-only.
 *   M_IND_ABSX = (abs,X)  16-bit indirect indexed jump, 3 bytes.
 *                Used only by JMP ($7C). 65C02-only.
 *   These are distinct modes despite similar "(...,X)" source syntax
 *   because they differ in operand width and in which mnemonics accept
 *   them; parse_operand() disambiguates by mnemonic (see below).
 */
typedef enum {
    M_IMP, M_ACC, M_IMM, M_ZP, M_ZPX, M_ZPY,
    M_ABS, M_ABSX, M_ABSY, M_IND, M_IND_ZP, M_IND_Y, M_IND_X, M_IND_ABSX, M_REL,
    M_UNKNOWN
} Mode;

static int mode_size[] = {
    1, 1, 2, 2, 2, 2,      /* IMP ACC IMM ZP ZPX ZPY */
    3, 3, 3, 3, 2, 2, 2, 3, 2 /* ABS ABSX ABSY IND IND_ZP IND_Y IND_X IND_ABSX REL */
};

/* ── opcode table entry ───────────────────────────────────────────────────── */
typedef struct {
    const char *mnem;
    Mode        mode;
    uint8_t     opcode;
} OpcodeEntry;

/* Full opcode table — one row per (mnemonic, mode) pair */
static const OpcodeEntry OPTAB[] = {
    {"adc",M_IMM,0x69},{"adc",M_ZP,0x65},{"adc",M_ZPX,0x75},
    {"adc",M_ABS,0x6D},{"adc",M_ABSX,0x7D},{"adc",M_ABSY,0x79},
    {"adc",M_IND_Y,0x71},{"adc",M_IND_ZP,0x72},{"adc",M_IND_X,0x61},
    {"and",M_IMM,0x29},{"and",M_ZP,0x25},{"and",M_ZPX,0x35},
    {"and",M_ABS,0x2D},{"and",M_ABSX,0x3D},{"and",M_ABSY,0x39},
    {"and",M_IND_Y,0x31},{"and",M_IND_ZP,0x32},{"and",M_IND_X,0x21},
    {"asl",M_ACC,0x0A},{"asl",M_ZP,0x06},{"asl",M_ZPX,0x16},{"asl",M_ABS,0x0E},{"asl",M_ABSX,0x1E},
    {"bcc",M_REL,0x90},{"bcs",M_REL,0xB0},{"beq",M_REL,0xF0},
    {"bmi",M_REL,0x30},{"bne",M_REL,0xD0},{"bpl",M_REL,0x10},
    {"bra",M_REL,0x80},{"bvs",M_REL,0x70},{"bvc",M_REL,0x50},
    {"bit",M_ZP,0x24},{"bit",M_ABS,0x2C},{"bit",M_IMM,0x89},
    {"bit",M_ZPX,0x34},{"bit",M_ABSX,0x3C},
    {"brk",M_IMP,0x00},
    {"clc",M_IMP,0x18},{"cld",M_IMP,0xD8},{"cli",M_IMP,0x58},{"clv",M_IMP,0xB8},
    {"sed",M_IMP,0xF8},
    {"cmp",M_IMM,0xC9},{"cmp",M_ZP,0xC5},{"cmp",M_ZPX,0xD5},
    {"cmp",M_ABS,0xCD},{"cmp",M_ABSX,0xDD},{"cmp",M_ABSY,0xD9},
    {"cmp",M_IND_Y,0xD1},{"cmp",M_IND_ZP,0xD2},{"cmp",M_IND_X,0xC1},
    {"cpx",M_IMM,0xE0},{"cpx",M_ZP,0xE4},{"cpx",M_ABS,0xEC},
    {"cpy",M_IMM,0xC0},{"cpy",M_ZP,0xC4},{"cpy",M_ABS,0xCC},
    {"dec",M_ACC,0x3A},{"dec",M_ZP,0xC6},{"dec",M_ZPX,0xD6},{"dec",M_ABS,0xCE},{"dec",M_ABSX,0xDE},
    {"dex",M_IMP,0xCA},{"dey",M_IMP,0x88},
    {"eor",M_IMM,0x49},{"eor",M_ZP,0x45},{"eor",M_ZPX,0x55},
    {"eor",M_ABS,0x4D},{"eor",M_ABSX,0x5D},{"eor",M_ABSY,0x59},
    {"eor",M_IND_Y,0x51},{"eor",M_IND_ZP,0x52},{"eor",M_IND_X,0x41},
    {"inc",M_ACC,0x1A},{"inc",M_ZP,0xE6},{"inc",M_ZPX,0xF6},{"inc",M_ABS,0xEE},{"inc",M_ABSX,0xFE},
    {"inx",M_IMP,0xE8},{"iny",M_IMP,0xC8},
    {"jmp",M_ABS,0x4C},{"jmp",M_IND,0x6C},{"jmp",M_IND_ABSX,0x7C},
    {"jsr",M_ABS,0x20},
    {"lda",M_IMM,0xA9},{"lda",M_ZP,0xA5},{"lda",M_ZPX,0xB5},
    {"lda",M_ABS,0xAD},{"lda",M_ABSX,0xBD},{"lda",M_ABSY,0xB9},
    {"lda",M_IND_Y,0xB1},{"lda",M_IND_ZP,0xB2},{"lda",M_IND_X,0xA1},
    {"ldx",M_IMM,0xA2},{"ldx",M_ZP,0xA6},{"ldx",M_ZPY,0xB6},
    {"ldx",M_ABS,0xAE},{"ldx",M_ABSY,0xBE},
    {"ldy",M_IMM,0xA0},{"ldy",M_ZP,0xA4},{"ldy",M_ZPX,0xB4},{"ldy",M_ABS,0xAC},{"ldy",M_ABSX,0xBC},
    {"lsr",M_ACC,0x4A},{"lsr",M_ZP,0x46},{"lsr",M_ZPX,0x56},{"lsr",M_ABS,0x4E},{"lsr",M_ABSX,0x5E},
    {"nop",M_IMP,0xEA},
    {"ora",M_IMM,0x09},{"ora",M_ZP,0x05},{"ora",M_ZPX,0x15},
    {"ora",M_ABS,0x0D},{"ora",M_ABSX,0x1D},{"ora",M_ABSY,0x19},
    {"ora",M_IND_Y,0x11},{"ora",M_IND_ZP,0x12},{"ora",M_IND_X,0x01},
    {"pha",M_IMP,0x48},{"php",M_IMP,0x08},
    {"pla",M_IMP,0x68},{"plp",M_IMP,0x28},
    {"phy",M_IMP,0x5A},{"ply",M_IMP,0x7A},
    {"phx",M_IMP,0xDA},{"plx",M_IMP,0xFA},
    {"rol",M_ACC,0x2A},{"rol",M_ZP,0x26},{"rol",M_ZPX,0x36},{"rol",M_ABS,0x2E},{"rol",M_ABSX,0x3E},
    {"ror",M_ACC,0x6A},{"ror",M_ZP,0x66},{"ror",M_ZPX,0x76},{"ror",M_ABS,0x6E},{"ror",M_ABSX,0x7E},
    {"rti",M_IMP,0x40},{"rts",M_IMP,0x60},
    {"sbc",M_IMM,0xE9},{"sbc",M_ZP,0xE5},{"sbc",M_ZPX,0xF5},
    {"sbc",M_ABS,0xED},{"sbc",M_ABSX,0xFD},{"sbc",M_ABSY,0xF9},
    {"sbc",M_IND_Y,0xF1},{"sbc",M_IND_ZP,0xF2},{"sbc",M_IND_X,0xE1},
    {"sec",M_IMP,0x38},{"sei",M_IMP,0x78},
    {"sta",M_ZP,0x85},{"sta",M_ZPX,0x95},{"sta",M_ABS,0x8D},
    {"sta",M_ABSX,0x9D},{"sta",M_ABSY,0x99},{"sta",M_IND_Y,0x91},{"sta",M_IND_ZP,0x92},
    {"sta",M_IND_X,0x81},
    {"stx",M_ZP,0x86},{"stx",M_ZPY,0x96},{"stx",M_ABS,0x8E},
    {"sty",M_ZP,0x84},{"sty",M_ZPX,0x94},{"sty",M_ABS,0x8C},
    {"stz",M_ZP,0x64},{"stz",M_ZPX,0x74},{"stz",M_ABS,0x9C},{"stz",M_ABSX,0x9E},
    {"tax",M_IMP,0xAA},{"tay",M_IMP,0xA8},
    {"tsx",M_IMP,0xBA},{"txa",M_IMP,0x8A},
    {"txs",M_IMP,0x9A},{"tya",M_IMP,0x98},
    /* v1.9: tsb/trb were already listed in is_65c02only()'s 65C02-only
     * mnemonic list, but had no OPTAB rows -- they were never actually
     * assemblable. Wired up here; sim65c02.c already executes both. */
    {"tsb",M_ZP,0x04},{"tsb",M_ABS,0x0C},
    {"trb",M_ZP,0x14},{"trb",M_ABS,0x1C},
    /* v1.9: RMB0-7/SMB0-7 (Rockwell/WDC 65C02 bit-reset/bit-set) -- single
     * zp operand, 2 bytes, so unlike BBRn/BBSn these fit the generic
     * single-operand model directly. Sim65c02.c already executes both. */
    {"rmb0",M_ZP,0x07},{"rmb1",M_ZP,0x17},{"rmb2",M_ZP,0x27},{"rmb3",M_ZP,0x37},
    {"rmb4",M_ZP,0x47},{"rmb5",M_ZP,0x57},{"rmb6",M_ZP,0x67},{"rmb7",M_ZP,0x77},
    {"smb0",M_ZP,0x87},{"smb1",M_ZP,0x97},{"smb2",M_ZP,0xA7},{"smb3",M_ZP,0xB7},
    {"smb4",M_ZP,0xC7},{"smb5",M_ZP,0xD7},{"smb6",M_ZP,0xE7},{"smb7",M_ZP,0xF7},
    {NULL, M_UNKNOWN, 0}
};

/* lookup opcode byte for (mnemonic, mode); returns -1 if not found */
static int opcode_lookup(const char *mn, Mode mode) {
    for (int i = 0; OPTAB[i].mnem; i++)
        if (!strcmp(OPTAB[i].mnem, mn) && OPTAB[i].mode == mode)
            return OPTAB[i].opcode;
    return -1;
}

/* check whether mnemonic exists at all */
static int mnem_known(const char *mn) {
    for (int i = 0; OPTAB[i].mnem; i++)
        if (!strcmp(OPTAB[i].mnem, mn)) return 1;
    return 0;
}

/*
 * is_bbr_bbs (v1.9)  --  recognize BBR0-BBR7 / BBS0-BBS7 (Rockwell/WDC
 *                        65C02 bit-branch mnemonics).
 *   In:  mn = lower-case mnemonic string
 *   Out: 1 if mn is "bbr0".."bbr7" or "bbs0".."bbs7", else 0.
 * These take two comma-separated operands (zp address, branch target) and
 * are always exactly 3 bytes -- not representable in the single-operand
 * Mode/Operand model the rest of OPTAB uses, so they're deliberately kept
 * out of OPTAB and handled as a self-contained special case in pass 1 and
 * pass 2 (see is_bbr_bbs() call sites in assemble()) rather than forcing
 * a two-value shape onto parse_operand() for just these 16 mnemonics.
 */
static int is_bbr_bbs(const char *mn) {
    if (strlen(mn) != 4) return 0;
    if (strncmp(mn, "bbr", 3) != 0 && strncmp(mn, "bbs", 3) != 0) return 0;
    return (mn[3] >= '0' && mn[3] <= '7');
}

/* ── symbol table ────────────────────────────────────────────────────────── */
typedef struct { char name[SYM_NAME_LEN]; int value; int used; } Symbol;
static Symbol   syms[MAX_SYMS];
static int      nsyms = 0;

static int sym_find(const char *name) {
    for (int i = 0; i < nsyms; i++)
        if (!strcmp(syms[i].name, name)) return i;
    return -1;
}
static void sym_set(const char *name, int value) {
    int i = sym_find(name);
    if (i >= 0) { syms[i].value = value; return; }
    if (nsyms < MAX_SYMS) {
        strncpy(syms[nsyms].name, name, SYM_NAME_LEN-1);
        syms[nsyms].value = value;
        syms[nsyms].used = 0;
        nsyms++;
    }
}
static int sym_get(const char *name, int *out) {
    int i = sym_find(name);
    if (i < 0) return 0;
    *out = syms[i].value;
    return 1;
}
static void sym_mark_used_index(int i) {
    if (i >= 0 && i < nsyms) syms[i].used = 1;
}

/* ── error list ──────────────────────────────────────────────────────────── */
static char errors[MAX_ERRORS][ERR_LEN];
static int  nerrors = 0;

/*
 * line_tag[] / n_line_tags (v1.9):
 *   Parallel to the flattened, post-.INCLUDE-expansion line array (see
 *   expand_includes()). line_tag[i] is the human-readable source location
 *   for flattened line i+1 ("12" for a top-level-file line, unchanged
 *   from pre-v1.9 output; "myinc.asm:5" for a line pulled in via
 *   .INCLUDE). add_error()/add_warning() consult this so messages about
 *   included content point at the right file, while messages about the
 *   top-level file are formatted byte-for-byte as before this feature.
 *   Populated once per assemble() call, before pass 1 begins.
 */
static char line_tag[MAX_LINES][LINE_LEN];
static int  n_line_tags = 0;

static void add_error(int lineno, const char *msg) {
    if (nerrors < MAX_ERRORS) {
        if (lineno >= 1 && lineno <= n_line_tags && line_tag[lineno-1][0]) {
            if (strchr(line_tag[lineno-1], ':'))
                snprintf(errors[nerrors], ERR_LEN, "%s: %s", line_tag[lineno-1], msg);
            else
                snprintf(errors[nerrors], ERR_LEN, "Line %s: %s", line_tag[lineno-1], msg);
        } else {
            snprintf(errors[nerrors], ERR_LEN, "Line %d: %s", lineno, msg);
        }
        nerrors++;
    }
}

/* ── warning list (v1.9) ─────────────────────────────────────────────────── */
/*
 * Parallel to errors[]/add_error() above, but non-fatal: warnings are
 * reported to the user but do not affect nerrors, the assemble() return
 * value, or whether a binary/report is produced. Populated by the
 * default-65C02-instruction-in-default-mode check (see g_nowarn65c02/
 * g_strict6502 below) at the pass-2 opcode-lookup site.
 */
static char warnings[MAX_WARNINGS][ERR_LEN];
static int  nwarnings = 0;
static void add_warning(int lineno, const char *msg) {
    if (nwarnings < MAX_WARNINGS) {
        if (lineno >= 1 && lineno <= n_line_tags && line_tag[lineno-1][0]) {
            if (strchr(line_tag[lineno-1], ':'))
                snprintf(warnings[nwarnings], ERR_LEN, "%s: %s", line_tag[lineno-1], msg);
            else
                snprintf(warnings[nwarnings], ERR_LEN, "Line %s: %s", line_tag[lineno-1], msg);
        } else {
            snprintf(warnings[nwarnings], ERR_LEN, "Line %d: %s", lineno, msg);
        }
        nwarnings++;
    }
}

/* ── CPU mode ────────────────────────────────────────────────────────────── */
/*
 * cpu_mode (v1.9: now tri-state):
 *   0 = unspecified (default; no .opt/.setcpu directive seen yet in the
 *       current scope). 65C02-only instructions are allowed; whether they
 *       warn or error is governed purely by the CLI flags g_nowarn65c02/
 *       g_strict6502 below.
 *   1 = explicit NMOS 6502 (.opt proc6502 / .setcpu "6502"). Every 65C02-
 *       only instruction is a hard error, unconditionally -- this has
 *       always been true and is unchanged. Also implies the same policy
 *       as -Strict6502 for conflict-detection purposes (see below).
 *   2 = explicit 65C02 (.opt proc65c02 / .setcpu "65C02"). 65C02-only
 *       instructions are allowed with NO portability warning -- the
 *       source has explicitly declared its target, so there is nothing
 *       to warn about. Implies the same policy as -NoWarn65c02.
 * Set by .opt proc6502|proc65c02 or .setcpu "6502"|"65C02" directives.
 * Reset to 0 at the start of each assemble() call AND at the start of
 * pass 2 (v1.9 bug fix: previously pass 2 inherited whatever cpu_mode
 * pass 1 ended on -- e.g. a proc6502 directive near the end of the file
 * would leave cpu_mode==1 active for pass 2's re-processing of the
 * *start* of the file, before pass 2 itself reached that directive).
 */
static int cpu_mode = 0;   /* 0=unspecified, 1=explicit 6502, 2=explicit 65C02 */

/*
 * g_nowarn65c02 / g_strict6502 (v1.9):
 *   These two globals hold the CLI-supplied -NoWarn65c02/-Strict6502
 *   flags. Set only by asm65c02's own CLI parser in main() and never
 *   changed afterward; sim65c02.c's single-argument assemble(source)
 *   call site never touches these, so the simulator always assembles
 *   with defaults (warn, non-strict). Reset to 0 at the start of each
 *   assemble() call.
 *
 *   They control 65C02-only-instruction handling ONLY while cpu_mode==0
 *   (no .opt proc6502/proc65c02 directive is currently in scope):
 *     g_nowarn65c02==0 (default): warn on every 65C02-only instruction.
 *     g_nowarn65c02==1 (-NoWarn65c02): suppress those warnings.
 *     g_strict6502==1 (-Strict6502): promote the same condition to a
 *       hard error instead of a warning.
 *   Mutually exclusive -- setting both on the command line is a usage
 *   error, checked in main() before assembly ever starts.
 *
 *   v1.9: .opt proc6502/proc65c02 now each imply one of these policies
 *   (proc6502 implies -Strict6502's *intent*, proc65c02 implies
 *   -NoWarn65c02), and it is a hard error for a directive's implied
 *   policy to contradict an explicit, opposite CLI flag -- e.g. .opt
 *   proc65c02 in a file assembled with -Strict6502 on the command line.
 *   That conflict is detected the moment the directive is processed
 *   (see the .opt/.setcpu handling in pass 2), not by silently picking
 *   a winner.
 */
static int g_nowarn65c02 = 0;
static int g_strict6502  = 0;

/*
 * is_65c02only  --  return 1 if the (mnemonic, mode) combination requires
 *                  a 65C02 and is therefore illegal in cpu_mode==1 (6502).
 *
 *   In:  mn   = lower-case mnemonic string
 *        mode = resolved addressing mode
 *   Out: 1 if 65C02-only, 0 if valid on NMOS 6502
 */
static int is_65c02only(const char *mn, Mode mode) {
    /* M_IND_ZP: (zp) zero-page indirect without index -- 65C02 only for all mnemonics */
    if (mode == M_IND_ZP) return 1;

    /* Mnemonics that simply do not exist on NMOS 6502 */
    static const char *c02_mnems[] = {
        "bra", "phx", "phy", "plx", "ply", "stz", "tsb", "trb", NULL
    };
    for (int i = 0; c02_mnems[i]; i++)
        if (!strcmp(mn, c02_mnems[i])) return 1;

    /* v1.9: RMB0-7/SMB0-7 -- 65C02-only, checked by prefix since they're
     * not carried through OPTAB's mode-based lookup for this purpose. */
    if (!strncmp(mn, "rmb", 3) || !strncmp(mn, "smb", 3)) return 1;

    /* INC A / DEC A ($1A / $3A) -- accumulator forms are 65C02 only */
    if ((!strcmp(mn, "inc") || !strcmp(mn, "dec")) && mode == M_ACC) return 1;

    /* BIT immediate, BIT zp,X, BIT abs,X -- 65C02 extensions */
    if (!strcmp(mn, "bit") &&
        (mode == M_IMM || mode == M_ZPX || mode == M_ABSX)) return 1;

    /* JMP (abs,X) -- 65C02 indirect indexed jump, $7C.
     * v1.9: now that M_IND_ABSX is a distinct mode (see parse_operand()),
     * this is a direct mode check instead of the old opcode-value stub. */
    if (mode == M_IND_ABSX) return 1;

    /* M_IND_X: (zp,X) indexed indirect is NOT 65C02-only -- it exists on
     * NMOS 6502 too (adc/and/cmp/eor/lda/ora/sbc/sta $x1 opcodes), so no
     * check needed here; falls through to the "return 0" below. */

    return 0;
}

/* ── string helpers ──────────────────────────────────────────────────────── */
static void str_lower(char *dst, const char *src) {
    while (*src) { *dst++ = (char)tolower((unsigned char)*src++); }
    *dst = '\0';
}
static void str_trim(char *s) {          /* trim trailing whitespace in-place */
    int n = (int)strlen(s);
    while (n > 0 && (s[n-1]==' '||s[n-1]=='\t'||s[n-1]=='\r'||s[n-1]=='\n')) n--;
    s[n] = '\0';
}
static const char *skip_ws(const char *s) {
    while (*s == ' ' || *s == '\t') s++;
    return s;
}
static int is_ident_start(char c) { return isalpha((unsigned char)c) || c=='_' || c=='@'; }
static int is_ident(char c)       { return isalnum((unsigned char)c) || c=='_' || c=='@'; }

/* ── scoped symbol name resolution ──────────────────────────────────────── */
/* scope = current global label.  @local names are stored as "GLOBAL@local". */
static char g_scope[SYM_NAME_LEN] = "";

static void scoped_name(char *out, const char *name) {
    if (name[0] == '@') {
        snprintf(out, SYM_NAME_LEN, "%s%s", g_scope, name);
    } else {
        strncpy(out, name, SYM_NAME_LEN-1);
        out[SYM_NAME_LEN-1] = '\0';
    }
}

/* look up a name with local-scope awareness */
static int scoped_get_index(const char *name) {
    if (name[0] == '@') {
        char full[SYM_NAME_LEN];
        scoped_name(full, name);
        int i = sym_find(full);
        if (i >= 0) return i;
    }
    return sym_find(name);
}

static int scoped_get(const char *name, int *out) {
    int i = scoped_get_index(name);
    if (i < 0) return 0;
    *out = syms[i].value;
    return 1;
}

/* ── expression evaluator ────────────────────────────────────────────────── */
/*
 * eval_expr: evaluate an assembler expression string.
 * pass2=1: undefined symbol is a hard error.
 * pass2=0: undefined symbol returns 0 (forward reference).
 * Returns the integer value; sets *err=1 on error.
 */
static int eval_expr(const char *raw, int pc, int pass2, int *err);

/* helper: find rightmost binary operator outside parentheses at given level */
static int find_binop(const char *s, int len, const char *ops) {
    int depth = 0;
    for (int i = len-1; i > 0; i--) {
        if (s[i] == ')') depth++;
        else if (s[i] == '(') depth--;
        if (depth == 0 && strchr(ops, s[i])) {
            /* ensure left side is non-empty (avoid unary minus) */
            const char *left = s;
            int llen = i;
            while (llen > 0 && (left[llen-1]==' '||left[llen-1]=='\t')) llen--;
            if (llen > 0) return i;
        }
    }
    return -1;
}

/*
 * find_cmpop (v1.11)  --  like find_binop() but for the two-character
 *   comparison operators "==" and "!=", used by .IF conditions.
 *   In:  s, len -- expression text and its length
 *   Out: return the index of the first character of the rightmost
 *        top-level (paren-depth-0) "==" or "!=", or -1 if none found.
 *        Scanning right-to-left with the rightmost match winning keeps
 *        this left-associative, matching find_binop()'s convention
 *        (not that repeated comparisons are common, but it's the
 *        consistent choice).
 *   Clobbers: none
 *
 *   No conflict with the existing single-char '<'/'>' low/high-byte
 *   PREFIX operators (checked earlier in eval_expr(), only at position
 *   0 of an expression): this only ever matches '=' or '!' followed by
 *   '=', never a bare '<' or '>'.
 */
static int find_cmpop(const char *s, int len) {
    int depth = 0;
    for (int i = len-2; i >= 1; i--) {
        if (s[i] == ')') depth++;
        else if (s[i] == '(') depth--;
        if (depth == 0 && s[i+1]=='=' && (s[i]=='=' || s[i]=='!')) return i;
    }
    return -1;
}

static int eval_expr(const char *raw, int pc, int pass2, int *err) {
    char s[LINE_LEN];
    strncpy(s, raw, LINE_LEN-1); s[LINE_LEN-1] = '\0';
    /* trim */
    str_trim(s);
    const char *p = skip_ws(s);
    int len = (int)strlen(p);
    if (len == 0) { *err = 1; return 0; }

    /* copy trimmed into s */
    memmove(s, p, len+1);

    /* current PC */
    if (len == 1 && s[0] == '*') return pc;

    /* lo/hi byte prefix */
    if (s[0] == '<') {
        int v = eval_expr(s+1, pc, pass2, err);
        return v & 0xFF;
    }
    if (s[0] == '>') {
        int v = eval_expr(s+1, pc, pass2, err);
        return (v >> 8) & 0xFF;
    }

    /* v1.12: binary and comparison operator searches must happen BEFORE the
     * atom checks below.  Previously they came after the $/%/decimal/paren
     * checks, so any expression whose LEFT side started with a literal was
     * silently truncated: "$10+$20" returned $10 (the literal was consumed
     * and the "+$20" tail discarded), "$10+LABEL" returned $10, and even
     * "($10+$20)" returned $10 (the bug recurred inside the recursive call).
     * The fix is to search for top-level binary operators first; only if no
     * operator is found does the expression reduce to a single atom, which
     * is then handled by the literal/paren/symbol checks below.
     *
     * Evaluation order (precedence low→high, checked first→last):
     *   1. == !=  (comparison, for .IF; lowest precedence)
     *   2. + -    (additive)
     *   3. * /    (multiplicative)
     * Each search scans right-to-left at depth-0 so the LEFT-most operator
     * wins (left-associative), matching the pre-fix behaviour for cases
     * that already worked.  The < > prefix operators and * PC-marker are
     * handled above and are never in the middle of an expression, so they
     * do not interfere with find_binop's '*' search. */

    /* comparison operators == and != (for .IF conditions) */
    {
        int ci = find_cmpop(s, len);
        if (ci >= 1) {
            char left[LINE_LEN], right[LINE_LEN];
            strncpy(left,  s,     ci); left[ci] = '\0'; str_trim(left);
            strncpy(right, s+ci+2, LINE_LEN-1); str_trim(right);
            int el=0, er=0;
            int L = eval_expr(left,  pc, pass2, &el);
            int R = eval_expr(right, pc, pass2, &er);
            if (!el && !er) {
                int eq = (L == R);
                return (s[ci]=='=') ? eq : !eq;
            }
        }
    }

    /* additive: + -  (scan right-to-left; i>0 guards against unary minus) */
    {
        int i = find_binop(s, len, "+-");
        if (i > 0) {
            char left[LINE_LEN], right[LINE_LEN];
            strncpy(left,  s,   i); left[i] = '\0'; str_trim(left);
            strncpy(right, s+i+1, LINE_LEN-1); str_trim(right);
            int el=0, er=0;
            int L = eval_expr(left,  pc, pass2, &el);
            int R = eval_expr(right, pc, pass2, &er);
            if (!el && !er) return s[i]=='+' ? L+R : L-R;
        }
    }

    /* multiplicative: * / */
    {
        int i = find_binop(s, len, "*/");
        if (i > 0) {
            char left[LINE_LEN], right[LINE_LEN];
            strncpy(left,  s,   i); left[i] = '\0'; str_trim(left);
            strncpy(right, s+i+1, LINE_LEN-1); str_trim(right);
            int el=0, er=0;
            int L = eval_expr(left,  pc, pass2, &el);
            int R = eval_expr(right, pc, pass2, &er);
            if (!el && !er) {
                if (s[i]=='*') return L*R;
                return R ? L/R : 0;
            }
        }
    }

    /* ── atom checks: expression is a single token ── */

    /* unary minus */
    if (s[0] == '-') {
        int v = eval_expr(s+1, pc, pass2, err);
        return -v;
    }

    /* hex literal $NNNN */
    if (s[0] == '$') {
        char *end; long v = strtol(s+1, &end, 16);
        if (end > s+1) return (int)v;
        *err = 1; return 0;
    }

    /* binary literal %NNNN */
    if (s[0] == '%') {
        char *end; long v = strtol(s+1, &end, 2);
        if (end > s+1) return (int)v;
        *err = 1; return 0;
    }

    /* decimal literal */
    if (isdigit((unsigned char)s[0])) {
        int alldig = 1;
        for (int i = 0; i < len; i++) if (!isdigit((unsigned char)s[i])) { alldig=0; break; }
        if (alldig) return atoi(s);
    }

    /* char literal 'x' or "x" */
    if ((s[0]=='\'' && len==3 && s[2]=='\'') ||
        (s[0]=='"'  && len==3 && s[2]=='"'))
        return (unsigned char)s[1];

    /* parenthesised sub-expression */
    if (s[0]=='(' && s[len-1]==')') {
        int depth=0, matched=1;
        for (int i=0; i<len-1; i++) {
            if (s[i]=='(') depth++;
            else if (s[i]==')') { depth--; if(depth==0){matched=0;break;} }
        }
        if (matched) {
            s[len-1] = '\0';
            return eval_expr(s+1, pc, pass2, err);
        }
    }

    /* symbol lookup */
    if (is_ident_start(s[0])) {
        int v = 0;
        int si = scoped_get_index(s);
        if (si >= 0) {
            v = syms[si].value;
            if (pass2) sym_mark_used_index(si);
            return v;
        }
        if (pass2) {
            char msg[ERR_LEN];
            snprintf(msg, ERR_LEN, "Undefined symbol: '%s'", s);
            *err = 1;
        }
        return 0; /* pass 1 forward reference */
    }

    *err = 1;
    return 0;
}

/* convenience wrapper: eval, return 0 on error */
static int ev(const char *expr, int pc, int pass2) {
    int e = 0;
    int v = eval_expr(expr, pc, pass2, &e);
    return v;
}

/* ── check if operand contains any undefined symbol ─────────────────────── */
static int has_undef(const char *expr) {
    const char *p = expr;
    while (*p) {
        /* v1.8: numeric literals must be skipped whole *before* the
           identifier scan below, or hex digits A-F inside a literal like
           "$AF" get misread as a one-character symbol reference "F" (or
           "A", "B", ... "F"). is_ident_start() treats any alpha char as a
           possible symbol start, with no awareness that it's sitting
           inside a $-prefixed hex literal. Pass 1 then wrongly believes
           the operand contains an undefined forward reference and forces
           3-byte M_ABS sizing, while pass 2 correctly resolves the
           literal and emits only 2 bytes (M_ZP) -- leaving a stray
           unwritten byte (typically 0) in the gap. This mirrors how
           eval_expr() itself already recognizes $/%% literals before
           ever reaching its own symbol-lookup branch; has_undef() must
           agree, since it exists purely to predict eval_expr()'s outcome
           for forward-reference sizing decisions on pass 1. */
        if (*p == '$') {
            p++;
            while (*p && isxdigit((unsigned char)*p)) p++;
            continue;
        }
        if (*p == '%') {
            p++;
            while (*p == '0' || *p == '1') p++;
            continue;
        }
        if (isdigit((unsigned char)*p)) {
            while (*p && isalnum((unsigned char)*p)) p++; /* decimal/etc run */
            continue;
        }
        if (is_ident_start(*p)) {
            char name[SYM_NAME_LEN]; int n = 0;
            while (*p && is_ident(*p) && n < SYM_NAME_LEN-1) name[n++] = *p++;
            name[n] = '\0';
            int dummy;
            if (!scoped_get(name, &dummy)) return 1;
        } else {
            p++;
        }
    }
    return 0;
}

/* ── operand parser → (mode, value) ─────────────────────────────────────── */
static int is_branch(const char *mn) {
    static const char *branches[] = {
        "bcc","bcs","beq","bmi","bne","bpl","bra","bvs","bvc", NULL
    };
    for (int i = 0; branches[i]; i++)
        if (!strcmp(mn, branches[i])) return 1;
    return 0;
}
static int is_acc_mnem(const char *mn) {
    static const char *accs[] = { "asl","lsr","rol","ror","inc","dec", NULL };
    for (int i = 0; accs[i]; i++)
        if (!strcmp(mn, accs[i])) return 1;
    return 0;
}

typedef struct { Mode mode; int value; } Operand;

/*
 * literal_forces_abs (v1.9 bug fix)
 *   Zero-page vs absolute sizing was previously decided purely by the
 *   numeric VALUE of an operand (<=0xFF -> zero page), ignoring how the
 *   literal was actually written. That silently mis-assembled explicit-
 *   width literals like "$0000" or "$00FF" as 2-byte zero-page ($00/
 *   $FF) instead of the 3-byte absolute form their digit count implies
 *   -- caught by a syntax-test file exercising "ORA $0000" and similar.
 *
 *   This recognizes a BARE hex literal (the entire trimmed expression is
 *   "$" followed by hex digits and nothing else) with 3 or 4 significant
 *   digits as forcing absolute width, matching the common assembler
 *   convention that digit count communicates intended operand width.
 *   Any other expression (labels, arithmetic, %binary or decimal
 *   literals) is NOT recognized here and falls back to the existing
 *   value-based sizing, since digit count doesn't carry the same
 *   meaning once arithmetic or symbols are involved.
 *
 *   In:  expr -- already-trimmed operand text (e.g. the base of "X,Y"
 *        before the register suffix is stripped, or the whole operand
 *        for a non-indexed case)
 *   Out: return 1 if expr is a bare hex literal with >=3 hex digits
 *        (i.e. explicitly written wide enough to mean "absolute" even
 *        if the value itself fits in a byte), else 0.
 */
static int literal_forces_abs(const char *expr) {
    if (expr[0] != '$') return 0;
    const char *d = expr + 1;
    int n = 0;
    while (isxdigit((unsigned char)*d)) { d++; n++; }
    if (*d != '\0') return 0;   /* trailing junk (e.g. "+2") -- not bare */
    return n >= 3;
}

static Operand parse_operand(const char *raw_op, const char *mn, int pc, int pass2) {
    char o[LINE_LEN];
    strncpy(o, raw_op, LINE_LEN-1); o[LINE_LEN-1] = '\0';
    str_trim(o);
    const char *p = skip_ws(o);
    memmove(o, p, strlen(p)+1);
    int len = (int)strlen(o);

    Operand res = {M_UNKNOWN, 0};

    /* empty operand */
    if (len == 0) {
        res.mode = is_acc_mnem(mn) ? M_ACC : M_IMP;
        return res;
    }

    /* explicit accumulator operand: "A" or "a" (single character only) —
       v1.8: previously only a totally empty operand was recognized as
       accumulator mode, so "INC A" silently fell through to expression
       parsing and was mis-assembled as "INC $00" (zero page), corrupting
       whatever lived at address $00. */
    if (len == 1 && (o[0] == 'A' || o[0] == 'a') && is_acc_mnem(mn)) {
        res.mode = M_ACC;
        return res;
    }

    /* immediate: #expr */
    if (o[0] == '#') {
        res.mode  = M_IMM;
        res.value = ev(o+1, pc, pass2) & 0xFF;
        return res;
    }

    /* indirect indexed (zp),Y */
    if (o[0] == '(') {
        /* find matching close paren */
        int depth = 0, close = -1;
        for (int i = 0; i < len; i++) {
            if (o[i]=='(') depth++;
            else if (o[i]==')') { depth--; if (depth==0){close=i;break;} }
        }
        if (close >= 0) {
            /* v1.9: (expr,X) -- indexed indirect. Trailing ",X" sits INSIDE
             * the parens, immediately before the close paren (as opposed to
             * "(expr),Y" below, where ",Y" sits AFTER the close paren).
             * jmp gets the 3-byte M_IND_ABSX ($7C); every other mnemonic
             * gets the 2-byte zero-page M_IND_X ($x1) form. Must be checked
             * before the ",Y" and bare "(expr)" cases below, and requires
             * nothing follow the close paren. */
            if (close >= 3 && o[close-2] == ',' &&
                toupper((unsigned char)o[close-1]) == 'X' &&
                *skip_ws(o + close + 1) == '\0') {
                char inner[LINE_LEN];
                int inner_len = close - 3; /* exclude leading '(' and trailing ",X" */
                if (inner_len < 0) inner_len = 0;
                strncpy(inner, o+1, inner_len); inner[inner_len] = '\0';
                str_trim(inner);
                int val = ev(inner, pc, pass2) & 0xFFFF;
                if (!strcmp(mn, "jmp")) {
                    res.mode = M_IND_ABSX; res.value = val; return res;
                }
                res.mode = M_IND_X; res.value = val & 0xFF; return res;
            }
            /* check what follows the close paren */
            const char *after = skip_ws(o + close + 1);
            if (*after == ',' && tolower((unsigned char)*(skip_ws(after+1))) == 'y') {
                /* (zp),Y */
                char inner[LINE_LEN];
                strncpy(inner, o+1, close-1); inner[close-1] = '\0';
                res.mode  = M_IND_Y;
                res.value = ev(inner, pc, pass2) & 0xFF;
                return res;
            }
            if (*after == '\0') {
                /* (expr) — JMP uses abs-indirect; LDA/STA use ind_zp */
                char inner[LINE_LEN];
                strncpy(inner, o+1, close-1); inner[close-1] = '\0';
                int val = ev(inner, pc, pass2) & 0xFFFF;
                if (!pass2 && has_undef(inner)) {
                    /* forward ref: assume abs indirect */
                    res.mode = M_IND; res.value = val; return res;
                }
                if (!strcmp(mn, "jmp")) {
                    res.mode = M_IND; res.value = val; return res;
                }
                if (val <= 0xFF) { res.mode = M_IND_ZP; res.value = val; return res; }
                res.mode = M_IND; res.value = val; return res;
            }
        }
    }

    /* indexed: expr,X  or  expr,Y  (check for trailing ,X or ,Y) */
    {
        /* find last comma not inside parens */
        int depth = 0, comma = -1;
        for (int i = len-1; i >= 0; i--) {
            if (o[i]==')') depth++;
            else if (o[i]=='(') depth--;
            if (depth==0 && o[i]==',') { comma=i; break; }
        }
        if (comma > 0 && comma == len-2) {
            char reg = (char)toupper((unsigned char)o[len-1]);
            if (reg=='X' || reg=='Y') {
                char base[LINE_LEN];
                strncpy(base, o, comma); base[comma] = '\0'; str_trim(base);
                int val = ev(base, pc, pass2) & 0xFFFF;
                Mode m;
                if (!pass2 && has_undef(base)) {
                    m = (reg=='X') ? M_ABSX : M_ABSY;  /* forward ref: always use ABS size */
                } else if (val <= 0xFF && !literal_forces_abs(base)) {
                    m = (reg=='X') ? M_ZPX : M_ZPY;
                } else {
                    m = (reg=='X') ? M_ABSX : M_ABSY;
                }
                res.mode = m; res.value = val; return res;
            }
        }
    }

    /* branch */
    if (is_branch(mn)) {
        res.mode  = M_REL;
        res.value = ev(o, pc, pass2) & 0xFFFF;
        return res;
    }

    /* plain value: zp or abs */
    {
        int val = ev(o, pc, pass2) & 0xFFFF;
        if (!pass2 && has_undef(o)) {
            res.mode = M_ABS; res.value = val; return res;  /* forward ref: always ABS size */
        }
        if (val <= 0xFF && !literal_forces_abs(o)) { res.mode = M_ZP;  res.value = val; return res; }
        res.mode = M_ABS; res.value = val; return res;
    }
}

/* ── mode promotion: zp→abs when mnemonic has no zp form ─────────────────── */
static Mode promote(const char *mn, Mode m) {
    if (m == M_ZP  && opcode_lookup(mn, M_ZP)  < 0 && opcode_lookup(mn, M_ABS)  >= 0) return M_ABS;
    if (m == M_ZPX && opcode_lookup(mn, M_ZPX) < 0 && opcode_lookup(mn, M_ABSX) >= 0) return M_ABSX;
    if (m == M_ZPY && opcode_lookup(mn, M_ZPY) < 0 && opcode_lookup(mn, M_ABSY) >= 0) return M_ABSY;
    return m;
}
static int instr_size(const char *mn, Mode m) {
    m = promote(mn, m);
    if (opcode_lookup(mn, m) < 0) return 1; /* unknown: guess 1 */
    return mode_size[m];
}

/* ── line parser ─────────────────────────────────────────────────────────── */
/*
 * Strip ';' comment, honouring quoted strings.
 * Writes result into buf (max buflen).
 */
static void strip_comment(const char *src, char *buf, int buflen) {
    int in_str = 0; char sq = 0;
    int j = 0;
    for (int i = 0; src[i] && j < buflen-1; i++) {
        char c = src[i];
        if (in_str) {
            if (c == sq) in_str = 0;
            buf[j++] = c;
        } else {
            if (c == '"' || c == '\'') { in_str = 1; sq = c; buf[j++] = c; }
            else if (c == ';') break;
            else buf[j++] = c;
        }
    }
    buf[j] = '\0';
}

/*
 * parse_line: split one source line into label, mnemonic, operand.
 * All three output buffers must be at least LINE_LEN bytes.
 * Returns 1 if line is an equate (NAME = expr), 0 otherwise.
 */
static int parse_line(const char *raw,
                      char *label, char *mnem, char *operand) {
    label[0] = mnem[0] = operand[0] = '\0';

    char line[LINE_LEN];
    strip_comment(raw, line, LINE_LEN);
    str_trim(line);
    if (!line[0]) return 0;

    const char *p = line;

    /* equate: NAME = expr  (NAME at column 0, no leading space) */
    if (line[0] != ' ' && line[0] != '\t') {
        /* check for NAME followed by optional spaces then '=' (not '==') */
        int ni = 0;
        while (line[ni] && is_ident(line[ni])) ni++;
        const char *after_name = skip_ws(line + ni);
        if (*after_name == '=' && *(after_name+1) != '=') {
            strncpy(label, line, ni); label[ni] = '\0';
            /* append '=' marker so caller knows it's an equate */
            strncat(label, "=", LINE_LEN-1);
            strncpy(operand, skip_ws(after_name+1), LINE_LEN-1);
            str_trim(operand);
            return 1;
        }
    }

    /* otherwise: [label:] [mnemonic [operand]] */
    int at_col0 = (p[0] != ' ' && p[0] != '\t');
    p = skip_ws(p);
    if (!*p) return 0;

    /* try to read a label (must be at col 0 for global, anywhere for @local) */
    if (is_ident_start(*p)) {
        const char *name_start = p;
        while (*p && is_ident(*p)) p++;
        const char *after_ident = p;
        p = skip_ws(p);
        if (*p == ':') {
            /* it's a label */
            int nlen = (int)(after_ident - name_start);
            int is_local = (name_start[0] == '@');
            if (!is_local && !at_col0) {
                /* indented non-@ identifier followed by ':' — treat as mnemonic */
                /* (rare edge case; fall through to mnemonic parse) */
                p = skip_ws(line);
            } else {
                strncpy(label, name_start, nlen); label[nlen] = '\0';
                p++;                /* skip ':' */
                p = skip_ws(p);
                at_col0 = 0;        /* reset: now reading mnemonic */
            }
        } else {
            /* not a label — rewind */
            p = skip_ws(line);
        }
    }

    /* mnemonic or directive */
    p = skip_ws(p);
    if (!*p) return 0;
    {
        const char *ms = p;
        if (*p == '.') p++;         /* directive */
        while (*p && !isspace((unsigned char)*p)) p++;
        int mlen = (int)(p - ms);
        strncpy(mnem, ms, mlen); mnem[mlen] = '\0';
        p = skip_ws(p);
    }

    /* rest is operand */
    strncpy(operand, p, LINE_LEN-1); str_trim(operand);
    return 0;
}

/* ── .byte directive parser ──────────────────────────────────────────────── */
/*
 * Parse a .byte operand list (comma-separated expressions and "strings").
 * Appends bytes to out[]; returns number of bytes added.
 */
static int parse_dot_byte(const char *operand, int pc, int pass2,
                          uint8_t *out, int max_out, int lineno) {
    const char *p = operand;
    int count = 0;
    while (*p) {
        p = skip_ws(p);
        if (!*p) break;
        if (*p == ',') { p++; continue; }

        if (*p == '"') {
            /* string literal */
            p++;
            while (*p && *p != '"') {
                if (count < max_out) out[count++] = (uint8_t)*p;
                p++;
            }
            if (*p == '"') p++;
        } else {
            /* expression: read until next comma outside parens */
            int depth = 0;
            const char *start = p;
            while (*p) {
                if (*p == '(') depth++;
                else if (*p == ')') depth--;
                else if (*p == ',' && depth == 0) break;
                p++;
            }
            /* evaluate */
            char expr[LINE_LEN];
            int elen = (int)(p - start);
            if (elen > LINE_LEN-1) elen = LINE_LEN-1;
            strncpy(expr, start, elen); expr[elen] = '\0';
            str_trim(expr);
            if (expr[0]) {
                int e = 0;
                int val = eval_expr(expr, pc+count, pass2, &e);
                if (e && pass2) {
                    char msg[ERR_LEN];
                    snprintf(msg, ERR_LEN, ".byte expr '%s': undefined symbol", expr);
                    add_error(lineno, msg);
                }
                if (count < max_out) out[count++] = (uint8_t)(val & 0xFF);
            }
        }
    }
    return count;
}

/* ── pc map entry (pass 1 → pass 2) ─────────────────────────────────────── */
typedef struct {
    int  lineno;
    int  pc;           /* PC at start of this line */
    char label[LINE_LEN];
    char mnem[LINE_LEN];
    char operand[LINE_LEN];
    int  is_equate;
    int  skip;          /* v1.11: 1 if inside a false .IF/.ELSE branch --
                          * pass 1.5 and pass 2 both skip these lines
                          * entirely (see if_active() header comment) */
} LineInfo;

static LineInfo pc_map[MAX_LINES];
static int      nlines = 0;

extern uint8_t mem[65536];

/* ── listing records (pass 2) ───────────────────────────────────────────── */
typedef struct {
    int     lineno;
    int     addr;
    int     nbytes;
    uint8_t bytes[LINE_LEN];
    char    source[LINE_LEN];
} ListingRecord;

static ListingRecord listing[MAX_LINES];
static int           nlisting = 0;
static uint8_t       mem_written[65536];

static ListingRecord *listing_begin_line(int lineno, int addr, const char *source) {
    if (nlisting >= MAX_LINES) return NULL;
    ListingRecord *rec = &listing[nlisting++];
    rec->lineno = lineno;
    rec->addr = addr & 0xFFFF;
    rec->nbytes = 0;
    strncpy(rec->source, source, LINE_LEN-1);
    rec->source[LINE_LEN-1] = '\0';
    return rec;
}

static void listing_capture_bytes(ListingRecord *rec, int start, int count) {
    if (!rec || count <= 0) return;
    if (count > LINE_LEN) count = LINE_LEN;
    rec->addr = start & 0xFFFF;
    rec->nbytes = count;
    for (int i = 0; i < count; i++)
        rec->bytes[i] = mem[(start + i) & 0xFFFF];
}

static void note_mem_write(int lineno, int addr) {
    addr &= 0xFFFF;
    if (mem_written[addr]) {
        char msg[ERR_LEN];
        snprintf(msg, ERR_LEN, "Address $%04X overwritten by relocated output", addr);
        add_error(lineno, msg);
    }
    mem_written[addr] = 1;
}

/* ── memory image ────────────────────────────────────────────────────────── */
/* Standalone build (ASM65C02_MAIN): we own mem[].
   Included by sim65c02.c: sim owns mem[], we use it via extern. */
#ifdef ASM65C02_MAIN
uint8_t mem[65536];
#else
extern uint8_t mem[65536];
#endif

/* ── assembly stats (for size_report) ───────────────────────────────────── */
typedef struct {
    int first_opcode_pc;               /* address of first emitted opcode byte */
    int last_code_pc_before_vectors;   /* address of last non-vector byte */
    int pc_overflow;                   /* v1.8: 1 if any true pre-mask pc/address
                                           exceeded $FFFF during assembly */
    int pc_overflow_lineno;            /* source line where overflow first detected */
    int pc_overflow_addr;              /* the unmasked (true) offending address */
} AsmStats;
static AsmStats asm_stats;

/* v1.8: call this with the TRUE (pre-mask) address/pc value, before any
   "& 0xFFFF" truncation, at every site that emits a byte, defines a label,
   or otherwise commits an address to memory or the symbol table. Records
   the first offending (line, address) pair and sets a sticky overflow
   flag; callers should keep using the masked value for mem[]/sym_set() so
   pass 1 and pass 2 continue to agree on layout, but the sticky flag turns
   "no errors" into a hard failure once assembly finishes. */
static void check_pc_overflow(int true_addr, int lineno) {
    if (true_addr > 0xFFFF && !asm_stats.pc_overflow) {
        asm_stats.pc_overflow = 1;
        asm_stats.pc_overflow_lineno = lineno;
        asm_stats.pc_overflow_addr = true_addr;
    }
}

/*
 * extract_quoted (v1.9)  --  pull the first "..."-quoted substring out of
 *   an operand string. Used by .INCLUDE/.INCBIN directive handling.
 *   In:  operand, outsz (size of out buffer)
 *   Out: out (NUL-terminated, truncated to outsz-1 chars if needed);
 *        returns 1 on success, 0 if no quoted substring was found (out
 *        is set to an empty string in that case).
 */
static int extract_quoted(const char *operand, char *out, size_t outsz) {
    const char *q1 = strchr(operand, '"');
    const char *q2 = q1 ? strchr(q1+1, '"') : NULL;
    if (!q1 || !q2) { if (outsz) out[0] = '\0'; return 0; }
    size_t len = (size_t)(q2 - (q1+1));
    if (len > outsz-1) len = outsz-1;
    strncpy(out, q1+1, len); out[len] = '\0';
    return 1;
}

/*
 * incbin_size (v1.9)  --  get a .INCBIN target file's size without
 *   loading it, for pass 1's PC-advance calculation.
 *   In:  path (already quote-stripped)
 *   Out: return file size in bytes, or -1 if the file cannot be opened.
 */
static long incbin_size(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    return sz;
}

/*
 * expand_includes (v1.9)  --  recursively flatten .INCLUDE "file" directives
 *   into a single line array before pass 1 ever runs.
 *
 *   In:  text         NUL-terminated source text for the file currently
 *                      being expanded (already loaded into memory)
 *        tag_prefix    NULL for the top-level file -- resulting lines are
 *                      tagged with a bare line number ("12"), producing
 *                      output byte-for-byte identical to pre-v1.9
 *                      behavior for any source that doesn't use
 *                      .INCLUDE. Otherwise the included file's display
 *                      name -- resulting lines are tagged "name:N".
 *        depth         current include nesting depth (0 = top level)
 *        stack/stack_depth
 *                      names of files currently open along the include
 *                      chain (stack[0..stack_depth-1]), for circular-
 *                      include detection
 *        out_lines/out_store/out_tags/out_count
 *                      caller-owned parallel arrays (mirroring the
 *                      pre-v1.9 raw_lines/line_store), appended to as
 *                      lines are accepted; capped at MAX_LINES
 *   Out: return 1 on success. Return 0 on a fatal expansion error
 *        (missing file, circular include, nesting too deep, or MAX_LINES
 *        exceeded) -- in that case a message has already been added to
 *        errors[] via add_error(), and the caller (assemble()) should
 *        abort immediately rather than attempt pass 1 on a partial/
 *        undefined line array.
 *   Clobbers: *out_count, out_lines[], out_store[][], out_tags[][],
 *             nerrors (via add_error)
 *
 *   .INCBIN "file" is deliberately NOT touched here -- it names binary
 *   data, not text lines, so it's passed through untouched and handled
 *   directly as a pass1/pass2 directive (reserving/emitting raw bytes),
 *   exactly like .RES/.DB already are.
 *
 *   Paths are resolved via a plain fopen(path,"r") relative to the
 *   process's current working directory -- the same convention already
 *   used for the top-level source file itself in main() -- so no change
 *   to assemble()'s single-argument signature is needed. This keeps
 *   sim65c02.c's embedded assemble(source) call site untouched.
 */
static int expand_includes(char *text, const char *tag_prefix, int depth,
                            const char *stack[], int stack_depth,
                            char *out_lines[], char out_store[][LINE_LEN],
                            char out_tags[][LINE_LEN], int *out_count)
{
    int file_lineno = 0;
    char *p = text;
    while (*p) {
        char *line_start = p;
        while (*p && *p != '\n') p++;
        int llen = (int)(p - line_start);
        if (*p) p++;
        file_lineno++;

        char linebuf[LINE_LEN];
        int clip = llen > LINE_LEN-1 ? LINE_LEN-1 : llen;
        strncpy(linebuf, line_start, clip); linebuf[clip] = '\0';

        /* lightweight directive sniff -- just enough to recognize
         * ".INCLUDE \"file\"" and pull its argument; full directive
         * parsing (parse_line()) happens later, in pass 1/2, for every
         * other line. */
        char trimmed[LINE_LEN];
        strncpy(trimmed, linebuf, LINE_LEN-1); trimmed[LINE_LEN-1] = '\0';
        const char *lead = skip_ws(trimmed);
        char body[LINE_LEN];
        strncpy(body, lead, LINE_LEN-1); body[LINE_LEN-1] = '\0';
        str_trim(body);
        char lower[LINE_LEN]; str_lower(lower, body);

        if (!strncmp(lower, ".include", 8) &&
            (lower[8]=='\0' || lower[8]==' ' || lower[8]=='\t' || lower[8]=='"')) {
            char *q1 = strchr(body, '"');
            char *q2 = q1 ? strchr(q1+1, '"') : NULL;
            if (!q1 || !q2) {
                add_error(*out_count+1, ".INCLUDE requires a quoted filename");
                return 0;
            }
            char incpath[LINE_LEN];
            int plen = (int)(q2 - (q1+1));
            if (plen > LINE_LEN-1) plen = LINE_LEN-1;
            strncpy(incpath, q1+1, plen); incpath[plen] = '\0';

            if (depth >= MAX_INCLUDE_DEPTH) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, ".INCLUDE nesting too deep (max %d): '%s'",
                         MAX_INCLUDE_DEPTH, incpath);
                add_error(*out_count+1, msg);
                return 0;
            }
            for (int i = 0; i < stack_depth; i++) {
                if (!strcmp(stack[i], incpath)) {
                    char msg[ERR_LEN];
                    snprintf(msg, ERR_LEN, "circular .INCLUDE detected: '%s'", incpath);
                    add_error(*out_count+1, msg);
                    return 0;
                }
            }

            FILE *f = fopen(incpath, "r");
            if (!f) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, ".INCLUDE: cannot open '%s'", incpath);
                add_error(*out_count+1, msg);
                return 0;
            }
            fseek(f, 0, SEEK_END);
            long fsz = ftell(f);
            fseek(f, 0, SEEK_SET);
            if (fsz < 0 || fsz > 1024*1024) {
                fclose(f);
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, ".INCLUDE: '%s' too large or unreadable", incpath);
                add_error(*out_count+1, msg);
                return 0;
            }
            char *buf = (char *)malloc((size_t)fsz + 1);
            if (!buf) {
                fclose(f);
                add_error(*out_count+1, ".INCLUDE: out of memory");
                return 0;
            }
            size_t rd = fread(buf, 1, (size_t)fsz, f);
            fclose(f);
            buf[rd] = '\0';

            const char *new_stack[MAX_INCLUDE_DEPTH];
            for (int i = 0; i < stack_depth; i++) new_stack[i] = stack[i];
            new_stack[stack_depth] = incpath;

            int ok = expand_includes(buf, incpath, depth+1, new_stack, stack_depth+1,
                                      out_lines, out_store, out_tags, out_count);
            free(buf);
            if (!ok) return 0;
            continue;  /* the .INCLUDE line itself is not emitted */
        }

        /* ordinary line: append as-is */
        if (*out_count >= MAX_LINES) {
            add_error(*out_count, "Source too large after .INCLUDE expansion (MAX_LINES exceeded)");
            return 0;
        }
        int idx = (*out_count)++;
        strncpy(out_store[idx], linebuf, LINE_LEN-1); out_store[idx][LINE_LEN-1] = '\0';
        out_lines[idx] = out_store[idx];
        if (tag_prefix)
            snprintf(out_tags[idx], LINE_LEN, "%s:%d", tag_prefix, file_lineno);
        else
            snprintf(out_tags[idx], LINE_LEN, "%d", file_lineno);
    }
    return 1;
}

/*
 * ── conditional assembly: .IF / .ELSE / .ENDIF (v1.11) ─────────────────────
 *
 * Design note (read this before touching any of this): this is a two-pass
 * assembler. If a .IF condition were evaluated independently in pass 1 and
 * pass 2, a forward-referenced or not-yet-finally-resolved symbol could
 * make the two passes disagree about which lines even exist -- silently
 * corrupting every address after that point in a way that's very hard to
 * diagnose. So the decision is made exactly ONCE, here, during pass 1, and
 * pass 1.5/pass 2 simply REPLAY the stored info->skip flag rather than
 * re-evaluating anything. The consequence: .IF conditions may only
 * reference symbols already fully and finally resolved earlier in the
 * source (numeric literals, or equates/labels defined via a plain,
 * non-forward-referencing definition) -- a forward reference in a .IF
 * condition is a hard error rather than a silent miscompile.
 *
 * Known interaction, not fixed here: .INCLUDE is expanded by
 * expand_includes() as a preprocessing step before pass 1 -- and therefore
 * before any .IF state exists. An .INCLUDE inside a false .IF branch will
 * still be opened and its contents spliced in (a missing file still
 * errors, even though the code it contains would never actually be
 * assembled). Fixing this would mean merging include-expansion and
 * conditional-tracking into a single pass; out of scope here.
 *
 * .REF(label) (a Kowalski feature checking whether a label was ever
 * referenced elsewhere) is NOT implemented -- it requires knowing the
 * answer before the rest of the file has even been scanned, an even worse
 * chicken-and-egg problem than the forward-reference restriction above.
 */
#define MAX_IF_DEPTH 16
typedef struct {
    int condition_true;     /* is THIS branch (before or after .ELSE) selected */
    int had_else;            /* has .ELSE already been seen at this level */
    int enclosing_active;    /* was the ENCLOSING context active when this .IF was reached */
} IfFrame;
static IfFrame if_stack[MAX_IF_DEPTH];
static int     if_sp = 0;

/*
 * if_active (v1.11)
 *   In:  none (reads if_stack/if_sp)
 *   Out: return 1 if lines at the current point in pass 1 should be
 *        processed normally (label registration, equates, instructions,
 *        directives); return 0 if they should be skipped entirely --
 *        inside a false .IF branch, or a branch nested inside one.
 *        With no open .IF at all (if_sp==0), always active.
 */
static int if_active(void) {
    if (if_sp == 0) return 1;
    IfFrame *f = &if_stack[if_sp-1];
    return f->enclosing_active && f->condition_true;
}

/*
 * if_push (v1.11)  --  handle a .IF line.
 *   In:  operand -- the .IF's condition expression text
 *        pc, lineno -- for expression evaluation / error reporting
 *   Out: none (pushes a new frame onto if_stack)
 *   Clobbers: if_stack, if_sp; may call add_error() on stack overflow or
 *             a condition that fails to evaluate (undefined symbol).
 *
 *   The condition is evaluated ONLY when the enclosing context is
 *   currently active. Inside an already-skipped block, a nested .IF's
 *   own condition is never evaluated at all (its symbols may not even
 *   exist -- e.g. dead code behind a platform check) and the whole
 *   nested block is simply skipped regardless.
 */
static void if_push(const char *operand, int pc, int lineno) {
    int enclosing = if_active();
    if (if_sp >= MAX_IF_DEPTH) {
        add_error(lineno, ".IF nesting too deep (max 16)");
        return;   /* don't push -- matching .ENDIF will underflow-guard too */
    }
    int cond = 0;
    if (enclosing) {
        int e = 0;
        cond = (eval_expr(operand, pc, 1, &e) != 0);
        if (e) {
            add_error(lineno, ".IF: undefined symbol in condition "
                               "(forward references are not supported in .IF)");
            cond = 0;
        }
    }
    if_stack[if_sp].condition_true   = cond;
    if_stack[if_sp].had_else         = 0;
    if_stack[if_sp].enclosing_active = enclosing;
    if_sp++;
}

/*
 * if_else (v1.11)  --  handle an .ELSE line.
 *   In:  lineno -- for error reporting
 *   Out: none (flips the top frame's condition_true)
 *   Clobbers: if_stack top frame; add_error() on unmatched/duplicate .ELSE.
 */
static void if_else(int lineno) {
    if (if_sp == 0) { add_error(lineno, ".ELSE without matching .IF"); return; }
    IfFrame *f = &if_stack[if_sp-1];
    if (f->had_else) { add_error(lineno, "duplicate .ELSE for the same .IF"); return; }
    f->had_else = 1;
    f->condition_true = !f->condition_true;
}

/*
 * if_pop (v1.11)  --  handle an .ENDIF line.
 *   In:  lineno -- for error reporting
 *   Out: none (pops if_stack)
 *   Clobbers: if_sp; add_error() on unmatched .ENDIF.
 */
static void if_pop(int lineno) {
    if (if_sp == 0) { add_error(lineno, ".ENDIF without matching .IF"); return; }
    if_sp--;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * ASSEMBLE  —  main two-pass entry point
 * ═══════════════════════════════════════════════════════════════════════════ */
static int assemble(const char *source) {
    /* split source into lines */
    static char source_copy[1024*1024];   /* static: avoids 1MB stack overflow on Windows */
    size_t srclen = strlen(source);
    if (srclen >= sizeof(source_copy)) {
        fprintf(stderr, "Source too large\n"); return 0;
    }
    memcpy(source_copy, source, srclen+1);

    memset(mem, 0, sizeof(mem));
    memset(mem_written, 0, sizeof(mem_written));
    nsyms = 0; nerrors = 0; nwarnings = 0; nlines = 0; nlisting = 0;
    g_scope[0] = '\0';
    cpu_mode = 0;   /* default: 65C02 mode */
    asm_stats.first_opcode_pc = -1;
    asm_stats.last_code_pc_before_vectors = -1;
    asm_stats.pc_overflow = 0;
    asm_stats.pc_overflow_lineno = 0;
    asm_stats.pc_overflow_addr = 0;

    /* collect raw lines, expanding any .INCLUDE directives as we go
     * (v1.9 -- see expand_includes() header comment). State resets above
     * are done first so add_error() works correctly if expansion itself
     * hits a fatal error (missing file, circular include, etc). */
    static char *raw_lines[MAX_LINES];
    static char  line_store[MAX_LINES][LINE_LEN];
    int nl = 0;
    n_line_tags = 0;
    {
        const char *stack[MAX_INCLUDE_DEPTH];
        if (!expand_includes(source_copy, NULL, 0, stack, 0,
                              raw_lines, line_store, line_tag, &nl)) {
            n_line_tags = nl;
            return 0;
        }
    }
    n_line_tags = nl;

    /* ── PASS 1: collect labels, compute addresses ── */
    int pc = 0;
    if_sp = 0;   /* v1.11: reset conditional-assembly stack for this assemble() call */
    for (int li = 0; li < nl; li++) {
        int lineno = li + 1;
        char label[LINE_LEN], mnem[LINE_LEN], operand[LINE_LEN];
        int is_eq = parse_line(raw_lines[li], label, mnem, operand);

        /* store in pc_map */
        LineInfo *info = &pc_map[nlines++];
        info->lineno   = lineno;
        info->pc       = pc;
        info->is_equate = is_eq;
        info->skip     = 0;
        strncpy(info->label,   label,   LINE_LEN-1);
        strncpy(info->mnem,    mnem,    LINE_LEN-1);
        strncpy(info->operand, operand, LINE_LEN-1);

        /* v1.11: .IF/.ELSE/.ENDIF -- recognized before anything else on the
         * line (label registration, equates, normal directive/instruction
         * dispatch), since these are pure flow-control pseudo-ops with no
         * label/value of their own. See the conditional-assembly block
         * above assemble() for the full design and its restrictions. */
        {
            char mnl[LINE_LEN]; str_lower(mnl, mnem);
            if (!strcmp(mnl, ".if"))   { if_push(operand, pc, lineno); info->skip = 1; continue; }
            if (!strcmp(mnl, ".else")) { if_else(lineno);              info->skip = 1; continue; }
            if (!strcmp(mnl, ".endif")){ if_pop(lineno);               info->skip = 1; continue; }
        }
        if (!if_active()) { info->skip = 1; continue; }

        /* equate */
        if (is_eq) {
            char name[LINE_LEN];
            strncpy(name, label, LINE_LEN-1);
            name[strlen(name)-1] = '\0'; /* strip trailing '=' */
            int e = 0;
            int val = eval_expr(operand, pc, 0, &e);
            sym_set(name, val);
            continue;
        }

        /* update scope for local labels */
        if (label[0] && label[0] != '@') strncpy(g_scope, label, SYM_NAME_LEN-1);

        /* define label */
        if (label[0]) {
            char full[SYM_NAME_LEN];
            scoped_name(full, label);
            /* v1.8: pc is the TRUE running address here (not yet masked).
               Check overflow before truncating, then store the masked
               value -- a label's visible address must agree with where
               its bytes actually land in mem[] (which is always indexed
               modulo 0x10000), not with an ever-growing accumulator that
               can exceed $FFFF. Previously this stored raw pc unmasked,
               so labels defined after total emitted size passed 64K got
               5-digit addresses like $10054 that disagreed with every
               other part of the assembler. */
            check_pc_overflow(pc, lineno);
            sym_set(full, pc & 0xFFFF);
        }

        if (!mnem[0]) continue;

        /* normalise mnemonic */
        char mn[LINE_LEN]; str_lower(mn, mnem);
        if (!strcmp(mn, ".db"))  strcpy(mn, ".byte");
        if (!strcmp(mn, ".dw"))  strcpy(mn, ".word");
        if (!strcmp(mn, ".rs"))  strcpy(mn, ".res");   /* v1.10: Kowalski-convention alias */

        /* store normalised mnem now — directives all 'continue' before line 800 */
        strncpy(info->mnem, mn, LINE_LEN-1);

        /* directives */
        if (!strcmp(mn, ".org")) {
            int e=0; pc = eval_expr(operand, pc, 0, &e) & 0xFFFF;
            info->pc = pc; continue;
        }
        if (!strcmp(mn, ".res")) {
            int e=0; int cnt = eval_expr(operand, pc, 0, &e); pc += cnt; continue;
        }
        if (!strcmp(mn, ".byte")) {
            uint8_t tmp[LINE_LEN]; int n = parse_dot_byte(operand, pc, 0, tmp, LINE_LEN, lineno);
            pc += n; continue;
        }
        if (!strcmp(mn, ".word")) {
            /* count comma-separated items */
            int cnt = 1;
            for (const char *q = operand; *q; q++) if (*q == ',') cnt++;
            if (!operand[0]) cnt = 0;
            pc += cnt * 2; continue;
        }
        if (!strcmp(mn, ".incbin")) {
            char path[LINE_LEN];
            if (!extract_quoted(operand, path, sizeof(path))) continue;
            /* v1.9: don't add_error here on a missing file -- pass 2 will
             * open it again and report the definitive error there (this
             * matches the existing convention elsewhere in pass 1 of not
             * duplicating error reports pass 2 already makes). A missing
             * file is simply treated as zero-size for PC-advance purposes;
             * pass 2's own error will fire regardless. */
            long sz = incbin_size(path);
            pc += (sz > 0) ? (int)sz : 0;
            continue;
        }
        if (!strcmp(mn,".opt")||!strcmp(mn,".setcpu")||
            !strcmp(mn,".code")||!strcmp(mn,".segment")) {
            /* .opt proc6502 / .opt proc65c02
               .setcpu "6502" / .setcpu "65C02"  -- set CPU mode for checking */
            char arg[LINE_LEN]; str_lower(arg, operand);
            char *ap = arg;
            if (*ap == '"') { ap++; char *eq = strchr(ap,'"'); if(eq) *eq='\0'; }
            if (!strcmp(ap,"proc6502") || !strcmp(ap,"6502"))    cpu_mode = 1;
            if (!strcmp(ap,"proc65c02")|| !strcmp(ap,"65c02"))   cpu_mode = 2;
            continue;
        }

        /* v1.9: BBRn/BBSn -- fixed 3-byte size regardless of operand
         * content (they take two operands, unlike everything else here;
         * see is_bbr_bbs() header comment). Must be checked before the
         * generic mnem_known()/parse_operand() path since they're
         * deliberately not in OPTAB. */
        if (is_bbr_bbs(mn)) { pc += 3; continue; }

        /* instruction */
        if (mnem_known(mn)) {
            Operand op = parse_operand(operand, mn, pc, 0);
            pc += instr_size(mn, op.mode);
        } else {
            char msg[ERR_LEN];
            snprintf(msg, ERR_LEN, "Unknown mnemonic '%s'", mnem);
            add_error(lineno, msg);
        }

        /* store updated mnem (normalised) */
        strncpy(info->mnem, mn, LINE_LEN-1);
    }

    /* v1.11: every .IF must be closed by a matching .ENDIF within the
     * same file/assemble() call -- an if_sp left non-zero here means at
     * least one is still open. Report against the last line, same
     * convention as other end-of-file structural checks. */
    if (if_sp != 0) {
        add_error(nl, ".IF without matching .ENDIF (unclosed at end of file)");
    }

    /* ── PASS 1.5: re-resolve equates now all labels known ── */
    g_scope[0] = '\0';
    for (int li = 0; li < nlines; li++) {
        LineInfo *info = &pc_map[li];
        if (info->skip) continue;   /* v1.11: never re-resolve a skipped equate */
        if (!info->is_equate) {
            if (info->label[0] && info->label[0] != '@')
                strncpy(g_scope, info->label, SYM_NAME_LEN-1);
            continue;
        }
        char name[LINE_LEN];
        strncpy(name, info->label, LINE_LEN-1);
        name[strlen(name)-1] = '\0';
        int e = 0;
        int val = eval_expr(info->operand, info->pc, 1, &e);
        if (!e) sym_set(name, val);
    }

    /* ── PASS 2: emit bytes ── */
    g_scope[0] = '\0';
    cpu_mode = 0;   /* v1.9 bug fix: don't inherit pass 1's trailing state */
    for (int li = 0; li < nlines; li++) {
        LineInfo *info = &pc_map[li];
        int lineno = info->lineno;
        pc = info->pc;
        ListingRecord *lrec = listing_begin_line(lineno, pc, raw_lines[li]);

        /* v1.11: replay pass 1's .IF/.ELSE decision -- never re-evaluate
         * here (see conditional-assembly design note above assemble()).
         * Lines inside a false branch still appear in the .LST (via
         * listing_begin_line above) but emit nothing and are otherwise
         * completely inert. */
        if (info->skip) continue;

        if (!info->label[0] && !info->mnem[0]) continue;

        /* update scope */
        if (info->label[0] && info->label[0]!='@' && !info->is_equate)
            strncpy(g_scope, info->label, SYM_NAME_LEN-1);

        if (info->is_equate || !info->mnem[0]) continue;

        const char *mn = info->mnem;
        const char *op = info->operand;

        if (!strcmp(mn, ".org")) { continue; }
        if (!strcmp(mn, ".res")) { continue; }
        if (!strcmp(mn, ".byte")) {
            uint8_t tmp[4096]; int n = parse_dot_byte(op, pc, 1, tmp, 4096, lineno);
            for (int i = 0; i < n; i++) {
                check_pc_overflow(pc + i, lineno);   /* v1.8: true addr, pre-mask */
                int addr = (pc + i) & 0xFFFF;
                note_mem_write(lineno, addr);
                mem[addr] = tmp[i];
                if (addr < 0xFFFA && addr > asm_stats.last_code_pc_before_vectors)
                    asm_stats.last_code_pc_before_vectors = addr;
                if (asm_stats.first_opcode_pc < 0)
                    asm_stats.first_opcode_pc = addr;
            }
            listing_capture_bytes(lrec, pc, n);
            continue;
        }
        if (!strcmp(mn, ".word")) {
            const char *q = op;
            int wpc = pc;
            while (*q) {
                q = skip_ws(q);
                if (!*q) break;
                /* read one comma-delimited item */
                int depth=0; const char *start=q;
                while (*q) {
                    if (*q=='(') depth++;
                    else if (*q==')') depth--;
                    else if (*q==',' && depth==0) break;
                    q++;
                }
                char expr[LINE_LEN];
                int elen=(int)(q-start); if(elen>LINE_LEN-1)elen=LINE_LEN-1;
                strncpy(expr,start,elen); expr[elen]='\0'; str_trim(expr);
                if (expr[0]) {
                    int e=0; int val=eval_expr(expr,wpc,1,&e)&0xFFFF;
                    if (e) { char msg[ERR_LEN]; snprintf(msg,ERR_LEN,".word '%s': undef",expr); add_error(lineno,msg); }
                    /* v1.8: wpc is the TRUE running address here, not yet
                       masked. The two mem[] writes below previously used
                       wpc and wpc+1 completely unmasked -- once wpc
                       exceeded 65536 (mem[] is declared uint8_t mem[65536])
                       this was an out-of-bounds write, not merely a
                       reporting glitch. Check overflow first, then always
                       index mem[] through the masked address. */
                    check_pc_overflow(wpc, lineno);
                    check_pc_overflow(wpc + 1, lineno);
                    int a0 = wpc & 0xFFFF;
                    int a1 = (wpc + 1) & 0xFFFF;
                    note_mem_write(lineno, a0);
                    note_mem_write(lineno, a1);
                    mem[a0] = val & 0xFF;
                    mem[a1] = (val >> 8) & 0xFF;
                    if (a0 < 0xFFFA && a0 > asm_stats.last_code_pc_before_vectors)
                        asm_stats.last_code_pc_before_vectors = a0;
                    if (a1 < 0xFFFA && a1 > asm_stats.last_code_pc_before_vectors)
                        asm_stats.last_code_pc_before_vectors = a1;
                    if (asm_stats.first_opcode_pc < 0)
                        asm_stats.first_opcode_pc = a0;
                    wpc += 2;
                }
                if (*q == ',') q++;
            }
            listing_capture_bytes(lrec, pc, wpc - pc);
            continue;
        }
        if (!strcmp(mn, ".incbin")) {
            char path[LINE_LEN];
            if (!extract_quoted(op, path, sizeof(path))) {
                add_error(lineno, ".INCBIN requires a quoted filename");
                continue;
            }
            FILE *bf = fopen(path, "rb");
            if (!bf) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, ".INCBIN: cannot open '%s'", path);
                add_error(lineno, msg);
                continue;
            }
            fseek(bf, 0, SEEK_END);
            long bsz = ftell(bf);
            fseek(bf, 0, SEEK_SET);
            if (bsz < 0) {
                fclose(bf);
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, ".INCBIN: cannot determine size of '%s'", path);
                add_error(lineno, msg);
                continue;
            }
            uint8_t *bbuf = (uint8_t *)malloc((size_t)bsz > 0 ? (size_t)bsz : 1);
            size_t brd = bbuf ? fread(bbuf, 1, (size_t)bsz, bf) : 0;
            fclose(bf);
            if (!bbuf) {
                add_error(lineno, ".INCBIN: out of memory");
                continue;
            }
            for (long i = 0; i < (long)brd; i++) {
                check_pc_overflow(pc + i, lineno);   /* true addr, pre-mask */
                int addr = (int)((pc + i) & 0xFFFF);
                note_mem_write(lineno, addr);
                mem[addr] = bbuf[i];
                if (addr < 0xFFFA && addr > asm_stats.last_code_pc_before_vectors)
                    asm_stats.last_code_pc_before_vectors = addr;
                if (asm_stats.first_opcode_pc < 0)
                    asm_stats.first_opcode_pc = addr;
            }
            listing_capture_bytes(lrec, pc, (int)brd);
            free(bbuf);
            continue;
        }
        if (!strcmp(mn,".opt")||!strcmp(mn,".setcpu")||
            !strcmp(mn,".code")||!strcmp(mn,".segment")) {
            /* v1.9: .opt proc6502 implies the same intent as -Strict6502;
             * .opt proc65c02 implies the same intent as -NoWarn65c02. A
             * directive whose implied policy contradicts an explicit,
             * opposite CLI flag is a hard error, reported at the
             * directive's own line rather than silently picking a winner. */
            char arg[LINE_LEN]; str_lower(arg, op);
            char *ap = arg;
            if (*ap == '"') { ap++; char *eq = strchr(ap,'"'); if(eq) *eq='\0'; }
            if (!strcmp(ap,"proc6502") || !strcmp(ap,"6502")) {
                if (g_nowarn65c02) {
                    add_error(lineno,
                        "'.opt proc6502' conflicts with -NoWarn65c02 on the command line");
                }
                cpu_mode = 1;
            }
            if (!strcmp(ap,"proc65c02")|| !strcmp(ap,"65c02")) {
                if (g_strict6502) {
                    add_error(lineno,
                        "'.opt proc65c02' conflicts with -Strict6502 on the command line");
                }
                cpu_mode = 2;
            }
            continue;
        }

        /* v1.9: BBRn/BBSn -- two comma-separated operands (zp, target),
         * always 3 bytes (opcode, zp, signed relative offset measured
         * from PC+3). Self-contained emission mirroring the generic
         * instruction path's overflow/masking/listing conventions, since
         * these mnemonics are deliberately not in OPTAB (see
         * is_bbr_bbs() header comment). */
        if (is_bbr_bbs(mn)) {
            int bit    = mn[3] - '0';
            int is_bbs = (mn[1] == 'b' && mn[2] == 's'); /* "bbs" vs "bbr" */
            int opc    = is_bbs ? (0x80 | (bit << 4) | 0x0F) : ((bit << 4) | 0x0F);

            if (cpu_mode == 1) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN,
                    "'%s' is a 65C02 instruction, not valid for NMOS 6502 target", mn);
                add_error(lineno, msg);
                continue;
            }
            if (cpu_mode == 0 && g_strict6502) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN,
                    "'%s' is a 65C02 instruction, rejected by -Strict6502", mn);
                add_error(lineno, msg);
                continue;
            } else if (cpu_mode == 0 && !g_nowarn65c02) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN,
                    "'%s' is a 65C02 instruction (not portable to NMOS 6502)", mn);
                add_warning(lineno, msg);
            }
            /* cpu_mode==2 (explicit .opt proc65c02): allowed, no warning --
             * source has explicitly declared its target. */

            /* split on the first top-level (depth-0) comma: "zp,target" */
            int depth = 0; const char *comma = NULL;
            for (const char *p = op; *p; p++) {
                if (*p == '(') depth++;
                else if (*p == ')') depth--;
                else if (*p == ',' && depth == 0) { comma = p; break; }
            }
            if (!comma) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, "%s requires two operands: zp,target", mn);
                add_error(lineno, msg);
                continue;
            }
            char zpexpr[LINE_LEN], tgtexpr[LINE_LEN];
            int zlen = (int)(comma - op); if (zlen > LINE_LEN-1) zlen = LINE_LEN-1;
            strncpy(zpexpr, op, zlen); zpexpr[zlen] = '\0'; str_trim(zpexpr);
            strncpy(tgtexpr, comma+1, LINE_LEN-1); tgtexpr[LINE_LEN-1] = '\0'; str_trim(tgtexpr);

            int e1 = 0, e2 = 0;
            int zp  = eval_expr(zpexpr, pc, 1, &e1) & 0xFF;
            int tgt = eval_expr(tgtexpr, pc, 1, &e2) & 0xFFFF;
            if (e1) { char msg[ERR_LEN]; snprintf(msg, ERR_LEN, "%s: bad zp operand '%s'", mn, zpexpr); add_error(lineno, msg); }
            if (e2) { char msg[ERR_LEN]; snprintf(msg, ERR_LEN, "%s: bad target operand '%s'", mn, tgtexpr); add_error(lineno, msg); }

            for (int i = 0; i < 3; i++) check_pc_overflow(pc + i, lineno);
            int pc0 = pc & 0xFFFF;
            for (int i = 0; i < 3; i++) note_mem_write(lineno, pc + i);
            mem[pc0] = (uint8_t)opc;
            if (asm_stats.first_opcode_pc < 0) asm_stats.first_opcode_pc = pc0;
            for (int i = 0; i < 3; i++) {
                int addr = (pc + i) & 0xFFFF;
                if (addr < 0xFFFA && addr > asm_stats.last_code_pc_before_vectors)
                    asm_stats.last_code_pc_before_vectors = addr;
            }
            mem[(pc+1) & 0xFFFF] = (uint8_t)zp;
            int next_pc = (pc + 3) & 0xFFFF;
            int offset  = tgt - next_pc;
            if (offset > 32767)  offset -= 65536;
            if (offset < -32768) offset += 65536;
            if (offset < -128 || offset > 127) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN, "Branch out of range at $%04X (offset %d)", pc, offset);
                add_error(lineno, msg);
            }
            mem[(pc+2) & 0xFFFF] = (uint8_t)(offset & 0xFF);
            listing_capture_bytes(lrec, pc, 3);
            continue;
        }

        if (!mnem_known(mn)) continue;

        Operand oper = parse_operand(op, mn, pc, 1);
        Mode m = promote(mn, oper.mode);

        /* v1.5: 6502 mode -- flag any 65C02-only instruction as an error */
        if (cpu_mode == 1 && is_65c02only(mn, m)) {
            char msg[ERR_LEN];
            snprintf(msg, ERR_LEN,
                "'%s' is a 65C02 instruction, not valid for NMOS 6502 target",
                mn);
            add_error(lineno, msg);
            continue;
        }

        /* v1.9: default (unspecified, cpu_mode==0) mode -- optionally flag
         * 65C02-only instructions even though they're legal here, since
         * the caller may want portability to NMOS 6502. -Strict6502
         * promotes this to a hard error; otherwise a warning is emitted
         * unless -NoWarn65c02 suppresses it. cpu_mode==2 (explicit .opt
         * proc65c02) intentionally falls through both checks below with
         * neither warning nor error -- the source has explicitly declared
         * its target, so there's nothing to flag (see cpu_mode comment). */
        if (cpu_mode == 0 && is_65c02only(mn, m)) {
            if (g_strict6502) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN,
                    "'%s' is a 65C02 instruction, rejected by -Strict6502", mn);
                add_error(lineno, msg);
                continue;
            } else if (!g_nowarn65c02) {
                char msg[ERR_LEN];
                snprintf(msg, ERR_LEN,
                    "'%s' is a 65C02 instruction (not portable to NMOS 6502)", mn);
                add_warning(lineno, msg);
            }
        }
        int opc = opcode_lookup(mn, m);
        if (opc < 0) {
            char msg[ERR_LEN];
            snprintf(msg, ERR_LEN, "%s: unsupported addressing mode for operand '%s'",
                     mn, op);
            add_error(lineno, msg);
            continue;
        }
        int val = oper.value;
        int sz  = mode_size[m];
        /* v1.8: pc is the TRUE running address here, not yet masked.
           mem[pc], mem[pc+1], mem[pc+2] below previously indexed with
           this unmasked value directly -- once pc exceeded 65536
           (mem[] is declared uint8_t mem[65536]) this was an
           out-of-bounds write, not merely a reporting glitch. Check
           overflow first, then always index mem[] through pc0 (the
           masked base address), computing each byte offset modulo
           0x10000 individually so a 3-byte instruction straddling the
           $FFFF/$0000 boundary still wraps consistently rather than
           running off the end of the array. */
        for (int i = 0; i < sz; i++)
            check_pc_overflow(pc + i, lineno);
        int pc0 = pc & 0xFFFF;
        for (int i = 0; i < sz; i++)
            note_mem_write(lineno, pc + i);
        mem[pc0] = (uint8_t)opc;
        if (asm_stats.first_opcode_pc < 0)
            asm_stats.first_opcode_pc = pc0;
        for (int i = 0; i < sz; i++) {
            int addr = (pc + i) & 0xFFFF;
            if (addr < 0xFFFA && addr > asm_stats.last_code_pc_before_vectors)
                asm_stats.last_code_pc_before_vectors = addr;
        }
        if (sz >= 2) {
            if (m == M_REL) {
                int next_pc = (pc + 2) & 0xFFFF; /* wrap at 64KB */
                int offset  = (val - next_pc);
                /* adjust for 64KB wrap: if target is just after $FFFF boundary */
                if (offset > 32767)  offset -= 65536;
                if (offset < -32768) offset += 65536;
                if (offset < -128 || offset > 127) {
                    char msg[ERR_LEN];
                    snprintf(msg, ERR_LEN, "Branch out of range at $%04X (offset %d)", pc, offset);
                    add_error(lineno, msg);
                }
                mem[(pc+1) & 0xFFFF] = (uint8_t)(offset & 0xFF);
            } else {
                mem[(pc+1) & 0xFFFF] = (uint8_t)(val & 0xFF);
                if (sz == 3) mem[(pc+2) & 0xFFFF] = (uint8_t)((val >> 8) & 0xFF);
            }
        }
        listing_capture_bytes(lrec, pc, sz);
    }

    /* v1.8: a wrapped/overflowed image must be a hard failure, not a
       silent "no errors" success with bogus footprint/symbol numbers.
       Folding this into the normal error list (rather than only printing
       it from size_report) means every caller that already gates on
       nerrors/assemble()'s return value gets this for free, including
       -o file writers that should refuse to emit a corrupted binary. */
    if (asm_stats.pc_overflow) {
        char msg[ERR_LEN];
        snprintf(msg, ERR_LEN,
            "ROM overflow: address $%05X exceeds 64KB address space "
            "(assembled image wrapped)", asm_stats.pc_overflow_addr);
        add_error(asm_stats.pc_overflow_lineno, msg);
    }

    return (nerrors == 0);
}

/* ── size report ─────────────────────────────────────────────────────────── */
static void size_report(void) {
    /* v1.8: a "no errors" assembly that silently wrapped past $FFFF is
       worse than an outright failure -- the footprint numbers below
       become meaningless (or even negative) once that happens, and the
       resulting binary may have overwritten its own low-memory bytes.
       Report this distinctly from the normal footprint summary and let
       the caller treat it as a hard error. */
    if (asm_stats.pc_overflow) {
        printf("\nROM overflow: assembled image exceeds the 64KB address "
               "space.\n");
        printf("  First true address $%05X reached on line %d "
               "(wrapped to $%04X in mem[]).\n",
               asm_stats.pc_overflow_addr, asm_stats.pc_overflow_lineno,
               asm_stats.pc_overflow_addr & 0xFFFF);
        printf("  Footprint/symbol addresses below this point are not "
               "reliable -- fix source layout before using this image.\n");
        return;
    }
    if (asm_stats.first_opcode_pc < 0 || asm_stats.last_code_pc_before_vectors < 0) {
        printf("\nROM footprint: no emitted code bytes before vectors.\n");
        return;
    }
    int start  = asm_stats.first_opcode_pc;
    int end    = asm_stats.last_code_pc_before_vectors;
    int used   = end - start + 1;
    int free_v = 0xFFFA - end - 1;
    if (free_v < 0) free_v = 0;
    printf("\nROM footprint: $%04X-$%04X = %d bytes (code before vectors)",
           start, end, used);
    if (free_v > 0)
        printf("  (%d bytes free before vectors)", free_v);
    printf("\n");
    if (used <= 2048)
        printf("(%d/2048 = %.1f%% of 2KB)\n", used, 100.0*used/2048);
    else if (used <= 4096)
        printf("(%d/4096 = %.1f%% of 4KB)\n", used, 100.0*used/4096);
}

/* ── CLI main (standalone build only) ───────────────────────────────────── */
#ifdef ASM65C02_MAIN

static char *derive_lst_path(const char *src_file) {
    size_t len = strlen(src_file);
    const char *slash1 = strrchr(src_file, '/');
    const char *slash2 = strrchr(src_file, '\\');
    /* v1.8: comparing slash1 > slash2 directly is undefined behavior in C
       whenever either pointer is NULL -- relational operators are only
       guaranteed well-defined between two pointers into the same array
       (or one-past-its-end), and NULL doesn't qualify. This runs on
       every invocation (including plain filenames with no path
       separator at all, e.g. "uBASIC.asm", where both are NULL, or a
       Unix-style path with no backslash, where slash2 is NULL), so the
       comparison was reachable on ordinary inputs, not just an edge
       case. Resolve the three NULL/non-NULL cases explicitly first, and
       only compare two non-NULL pointers (both known to point within
       src_file) when both separators are actually present. */
    const char *slash;
    if (slash1 && slash2)      slash = (slash1 > slash2) ? slash1 : slash2;
    else if (slash1)           slash = slash1;
    else if (slash2)           slash = slash2;
    else                       slash = NULL;
    const char *base = slash ? slash + 1 : src_file;
    const char *dot = strrchr(base, '.');
    size_t stem_len = dot ? (size_t)(dot - src_file) : len;
    char *out = (char *)malloc(stem_len + 5);
    if (!out) return NULL;
    memcpy(out, src_file, stem_len);
    memcpy(out + stem_len, ".LST", 5);
    return out;
}

static int write_lst_file(const char *lst_file) {
    FILE *f = fopen(lst_file, "w");
    if (!f) { perror(lst_file); return 0; }

    fprintf(f, "Line  Addr  Bytes                 Source\n");
    fprintf(f, "----  ----  --------------------  ------\n");
    for (int i = 0; i < nlisting; i++) {
        ListingRecord *rec = &listing[i];
        fprintf(f, "%4d  ", rec->lineno);
        if (rec->nbytes > 0) {
            fprintf(f, "%04X  ", rec->addr & 0xFFFF);
            int shown = rec->nbytes < 8 ? rec->nbytes : 8;
            for (int j = 0; j < shown; j++)
                fprintf(f, "%02X ", rec->bytes[j]);
            if (rec->nbytes > shown)
                fprintf(f, "...");
            int pad = 22 - (shown * 3) - (rec->nbytes > shown ? 3 : 0);
            while (pad-- > 0) fputc(' ', f);
        } else {
            fprintf(f, "      %-20s  ", "");
        }
        fprintf(f, "%s\n", rec->source);
    }

    fprintf(f, "\nSymbols:\n");
    fprintf(f, "--------\n");
    for (int i = 0; i < nsyms; i++)
        fprintf(f, "%-32s $%04X %s\n",
                syms[i].name, syms[i].value & 0xFFFF,
                syms[i].used ? "USED" : "UNUSED");

    fclose(f);
    return 1;
}

static int parse_hex_range(const char *s, int *start, int *end) {
    const char *dash = strchr(s, '-');
    if (!dash) return 0;
    char left[32], right[32];
    int ll = (int)(dash - s), rl = (int)strlen(dash+1);
    if (ll <= 0 || rl <= 0 || ll >= (int)sizeof(left) || rl >= (int)sizeof(right)) return 0;
    memcpy(left, s, ll); left[ll] = '\0';
    memcpy(right, dash+1, rl); right[rl] = '\0';
    str_trim(left); str_trim(right);
    const char *lp = left,  *rp = right;
    if (*lp == '$') lp++;  if (*rp == '$') rp++;
    if ((lp[0]=='0' && (lp[1]=='x'||lp[1]=='X'))) lp+=2;
    if ((rp[0]=='0' && (rp[1]=='x'||rp[1]=='X'))) rp+=2;
    if (!*lp || !*rp) return 0;
    char *ep1=NULL, *ep2=NULL;
    long a = strtol(lp, &ep1, 16), b = strtol(rp, &ep2, 16);
    if (!ep1||!ep2||*ep1||*ep2) return 0;
    if (a < 0 || a > 0xFFFF || b < 0 || b > 0xFFFF || a > b) return 0;
    *start = (int)a; *end = (int)b;
    return 1;
}

static void asm_usage(FILE *out) {
    fprintf(out,
        "asm65c02 v1.12 — Toy 65C02/6502 two-pass assembler\n"
        "\n"
        "Copyright Vincent Crabtree 2026, MIT License, See LICENSE file\n"
        "\n"
        "Usage:\n"
        "  asm65c02 <file.asm> [options]\n"
        "  asm65c02 --help\n"
        "\n"
        "Options:\n"
        "  (none)       Assemble and print symbol report + ROM size summary.\n"
        "               Exit 0 on success, 1 on error.\n"
        "  --binary     Write raw 65536-byte flat image to stdout; errors to stderr.\n"
        "  -o <file>    Write binary image to <file> (cleaner on Win32 than stdout).\n"
        "  -r <range>   Output only address range (requires --binary or -o).\n"
        "               e.g.  -r $F800-$FFFF   or   -r F000-FFFF\n"
        "               uBASIC:    asm65c02 uBASIC6502.asm -o rom.bin -r $F800-$FFFF\n"
        "               4K BASIC:  asm65c02 4kBASIC.asm -o rom.bin -r $F000-$FFFF\n"
        "  -NoList      Suppress default sidecar .LST listing generation.\n"
        "  -NoWarn65c02 Suppress the default warning issued whenever a 65C02-only\n"
        "               instruction is assembled with no .opt proc6502/proc65c02\n"
        "               directive in scope. Same effect as .opt proc65c02 (see\n"
        "               below); conflicts (hard error) with a .opt proc6502 in the\n"
        "               source, and cannot be combined with -Strict6502.\n"
        "  -Strict6502  Treat every 65C02-only instruction as a hard error when no\n"
        "               .opt proc6502/proc65c02 directive is in scope, without\n"
        "               needing .opt proc6502 in the source. Same effect as .opt\n"
        "               proc6502 (see below); conflicts (hard error) with a .opt\n"
        "               proc65c02 in the source, and cannot be combined with\n"
        "               -NoWarn65c02.\n"
        "  --dump-all   Print all assembled symbols after the key-symbol table.\n"
        "  --help, -h   Print this help and exit.\n"
        "\n"
        "Listing files:\n"
        "  A .LST file is generated by default,Use -NoList to suppress.\n"
        "\n"
        "CPU mode directives (in source):\n"
        "  .opt proc6502      Target NMOS 6502: flags 65C02-only instructions as\n"
        "                     errors. Implies the same intent as -Strict6502; it is\n"
        "                     a hard error to also pass -NoWarn65c02 on the command\n"
        "                     line.\n"
        "  .opt proc65c02     Target 65C02 (default): all instructions permitted,\n"
        "                     with no portability warning. Implies the same intent\n"
        "                     as -NoWarn65c02; it is a hard error to also pass\n"
        "                     -Strict6502 on the command line.\n"
        "  .setcpu \"6502\"     Equivalent to .opt proc6502.\n"
        "  .setcpu \"65C02\"    Equivalent to .opt proc65c02.\n"
        "  With no directive at all, 65C02-only instructions are allowed and warn\n"
        "  by default (see -NoWarn65c02/-Strict6502 above).\n"
        "\n") ;
     
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            asm_usage(stdout); return 0;
        }
    }
    if (argc < 2) { asm_usage(stderr); return 1; }

    const char *src_file = NULL;
    const char *out_file = NULL;
    int binary_mode  = 0;
    int dump_all     = 0;
    int range_on     = 0;
    int range_start  = 0;
    int range_end    = 0xFFFF;
    int end_opts     = 0;
    int list_on      = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--")) { end_opts = 1; continue; }
        if ((end_opts || argv[i][0] != '-') && !src_file) { src_file = argv[i]; continue; }
        if (end_opts || argv[i][0] != '-') {
            fprintf(stderr, "Unexpected argument: %s\n", argv[i]); return 1;
        }
        if      (!strcmp(argv[i], "--binary"))   binary_mode = 1;
        else if (!strcmp(argv[i], "--dump-all")) dump_all    = 1;
        else if (!strcmp(argv[i], "-NoList"))    list_on     = 0;
        else if (!strcmp(argv[i], "-NoWarn65c02")) g_nowarn65c02 = 1;
        else if (!strcmp(argv[i], "-Strict6502"))  g_strict6502  = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            asm_usage(stdout); return 0;
        }
        else if (!strcmp(argv[i], "-o")) {
            if (i+1 >= argc) { fprintf(stderr, "-o requires a filename\n"); return 1; }
            out_file = argv[++i]; binary_mode = 1;
        }
        else if (!strcmp(argv[i], "-r")) {
            if (i+1 >= argc) { fprintf(stderr, "-r requires a range like $F800-$FFFF\n"); return 1; }
            if (!parse_hex_range(argv[++i], &range_start, &range_end)) {
                fprintf(stderr, "Invalid range '%s' (expected $HHHH-$HHHH)\n", argv[i]); return 1;
            }
            range_on = 1;
        }
        else { fprintf(stderr, "Unknown option: %s\n", argv[i]); return 1; }
    }

    if (!src_file) { fprintf(stderr, "Missing input file.\n\n"); asm_usage(stderr); return 1; }
    if (range_on && !binary_mode) { fprintf(stderr, "-r requires --binary or -o\n"); return 1; }
    /* v1.9: -NoWarn65c02 and -Strict6502 are mutually exclusive policies;
     * catch this before assembling rather than letting one silently win. */
    if (g_nowarn65c02 && g_strict6502) {
        fprintf(stderr, "-NoWarn65c02 and -Strict6502 cannot both be given.\n");
        return 1;
    }

    FILE *f = fopen(src_file, "r");
    if (!f) { perror(src_file); return 1; }
    static char source[1024*1024];
    size_t n = fread(source, 1, sizeof(source)-1, f);
    fclose(f);
    source[n] = '\0';

    int ok = assemble(source);
    if (list_on) {
        char *lst_file = derive_lst_path(src_file);
        if (!lst_file) { fprintf(stderr, "Unable to allocate .LST filename\n"); return 1; }
        if (!write_lst_file(lst_file)) { free(lst_file); return 1; }
        free(lst_file);
    }

    if (binary_mode) {
        for (int i = 0; i < nwarnings; i++) fprintf(stderr, "Warning: %s\n", warnings[i]);
        for (int i = 0; i < nerrors; i++) fprintf(stderr, "%s\n", errors[i]);
        if (!ok) return 1;
        int out_s = range_on ? range_start : 0;
        int out_e = range_on ? range_end   : 0xFFFF;
        size_t out_len = (size_t)(out_e - out_s + 1);
        if (out_file) {
            FILE *of = fopen(out_file, "wb");
            if (!of) { perror(out_file); return 1; }
            fwrite(mem + out_s, 1, out_len, of);
            fclose(of);
            fprintf(stderr, "Assembled OK: %s -> %s  range=$%04X-$%04X  bytes=%zu  reset=$%04X\n",
                    src_file, out_file, out_s, out_e, out_len,
                    (unsigned)(mem[0xFFFC]|(mem[0xFFFD]<<8)));
        } else {
            fwrite(mem + out_s, 1, out_len, stdout);
            fprintf(stderr, "Assembled OK: range=$%04X-$%04X  bytes=%zu  reset=$%04X\n",
                    out_s, out_e, out_len,
                    (unsigned)(mem[0xFFFC]|(mem[0xFFFD]<<8)));
        }
        return 0;
    }

    /* human-readable report */
    if (nerrors) {
        printf("\nERRORS (%d):\n", nerrors);
        for (int i = 0; i < nerrors; i++) printf("  %s\n", errors[i]);
    } else {
        printf("No errors.\n");
    }
    if (nwarnings) {
        printf("\nWARNINGS (%d):\n", nwarnings);
        for (int i = 0; i < nwarnings; i++) printf("  %s\n", warnings[i]);
    }

    /* v1.9 (item H): Key symbols / Reset vector / --dump-all / ROM footprint
     * are only meaningful for a successfully assembled image -- on error,
     * mem[]/syms[] may be incomplete or reflect a truncated pass 2, so
     * showing them was misleading. Suppress the whole block on failure. */
    if (ok) {
        printf("\n------------------------------------------------------------\n");
        int rv = mem[0xFFFC] | (mem[0xFFFD]<<8);
        printf("\n  Reset vector         = $%04X\n", (unsigned)rv);

        if (dump_all) {
            printf("\n--- ALL SYMBOLS ---\n");
            for (int i = 0; i < nsyms; i++)
                printf("  $%04X  %s\n", (unsigned)syms[i].value, syms[i].name);
            printf("-------------------\n");
        }

        size_report();
    }
    return ok ? 0 : 1;
}
#endif /* ASM65C02_MAIN */
