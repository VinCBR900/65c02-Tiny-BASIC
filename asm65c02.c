/*
 * asm65c02.c  —  Two-pass Toy 65C02 assembler  (v1.5, Mar 2026)
 *
 * Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
 *
 * Also used as an embedded assembler inside sim65c02.c (included directly).
 *
 * v1.2: source_copy[] made static — prevents 1MB stack overflow on Windows.
 * v1.3: Forward-reference sizing fix: any expression containing an undefined
 *       symbol now forces ABS/ABSX/ABSY mode on pass 1.
 * v1.4: Added missing SED ($F8, Set Decimal Mode) to opcode table and
 *       fixed pass-1 sizing when expressions contain undefined symbols.
 *       Any expression containing an undefined symbol now forces ABS/ABSX/ABSY
 *       mode on pass 1, regardless of the
 *       partially-evaluated value.  Previously "SYM+1" with SYM undefined
 *       evaluated to 1 on pass 1, was sized as ZP (2 bytes), then on pass 2
 *       resolved to e.g. $FFCD (3 bytes), corrupting subsequent instruction
 *       addresses and producing a wrong ROM.
 * v1.5: CLI refreshed and hardened: header/help synced with current options
 *       (-o, -r, -h), unknown/extra arguments now rejected with clear errors.
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
 *   -o <file>       Write binary output to a file (implies --binary).
 *   -r $HHHH-$HHHH  Limit binary output to an address range (requires --binary or -o).
 *                   Preferred for ROM extraction:
 *                     uBASIC (2 KB at $F800):   -r $F800-$FFFF
 *                     4K BASIC (4 KB at $F000): -r $F000-$FFFF
 *   --dump-all      After the key-symbol table, print every assembled symbol
 *                   sorted by address.  Useful for detailed size analysis.
 *   --help, -h      Print this help and exit.
 *
 * Supported syntax (Kowalski-compatible subset):
 *   Directives : .ORG addr
 *                .DB / .BYTE  val[,val,...]   (values or "string literals")
 *                .DW / .WORD  val[,val,...]   (16-bit little-endian)
 *                .RES  n[,fill]               (reserve n bytes, optional fill)
 *                .opt / .setcpu               (accepted, ignored)
 *   Equates    : NAME = expression
 *   Labels     : GLOBAL_LABEL:
 *                @local_label:   (scope resets at each new global label)
 *   Addressing : implied / accumulator / immediate (#)
 *                zero-page, zero-page,X, zero-page,Y
 *                absolute, absolute,X, absolute,Y
 *                (indirect), (zp indirect), (zp),Y
 *                relative (branch instructions)
 *   Expressions: decimal  $hex  %binary  'char'  "char"  * (current PC)
 *                <lo-byte  >hi-byte  + - * /  ( )
 *   Comments   : ; to end of line
 *
 * Output (normal mode):
 *   No errors.                   (or error list)
 *   Key symbols:
 *     INIT             = $F003
 *     MAIN             = $F006
 *     ...
 *   Reset vector       = $F003
 *   ROM: $F000-$FFFF  (4096 bytes)  3 bytes free before vectors
 *
 * Version history (newest first):
 *   v1.5  (Mar 2026)  CLI docs aligned with implementation and argument parsing
 *                     made strict for unknown/extra option handling.
 *   v1.4  (Mar 2026)  Added SED opcode and pass-1 sizing fix for expressions
 *                     with undefined symbols.
 *   v1.3  (Mar 2026)  Forward-reference sizing fix for undefined symbols.
 *   v1.2  (Mar 2026)  source_copy[] made static to avoid Windows stack overflow.
 *   v1.1  (Mar 2026)  Header updated: full option docs, --help flag, corrected
 *                     project version references.
 *   v1.0  (Mar 2026)  Initial C port of assembler.py v1.6.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>

/* ── limits ──────────────────────────────────────────────────────────────── */
#define MAX_LINES    8192
#define MAX_SYMS     2048
#define MAX_ERRORS   256
#define SYM_NAME_LEN 64
#define LINE_LEN     512
#define ERR_LEN      128

/* ── addressing modes ────────────────────────────────────────────────────── */
typedef enum {
    M_IMP, M_ACC, M_IMM, M_ZP, M_ZPX, M_ZPY,
    M_ABS, M_ABSX, M_ABSY, M_IND, M_IND_ZP, M_IND_Y, M_REL,
    M_UNKNOWN
} Mode;

static int mode_size[] = {
    1, 1, 2, 2, 2, 2,   /* IMP ACC IMM ZP ZPX ZPY */
    3, 3, 3, 3, 2, 2, 2 /* ABS ABSX ABSY IND IND_ZP IND_Y REL */
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
    {"adc",M_ABS,0x6D},{"adc",M_ABSX,0x7D},{"adc",M_IND_Y,0x71},{"adc",M_IND_ZP,0x72},
    {"and",M_IMM,0x29},{"and",M_ZP,0x25},{"and",M_ZPX,0x35},
    {"and",M_ABS,0x2D},{"and",M_IND_Y,0x31},{"and",M_IND_ZP,0x32},
    {"asl",M_ACC,0x0A},{"asl",M_ZP,0x06},{"asl",M_ZPX,0x16},{"asl",M_ABS,0x0E},
    {"bcc",M_REL,0x90},{"bcs",M_REL,0xB0},{"beq",M_REL,0xF0},
    {"bmi",M_REL,0x30},{"bne",M_REL,0xD0},{"bpl",M_REL,0x10},
    {"bra",M_REL,0x80},{"bvs",M_REL,0x70},{"bvc",M_REL,0x50},
    {"bit",M_ZP,0x24},{"bit",M_ABS,0x2C},{"bit",M_IMM,0x89},
    {"bit",M_ZPX,0x34},{"bit",M_ABSX,0x3C},
    {"brk",M_IMP,0x00},
    {"clc",M_IMP,0x18},{"cld",M_IMP,0xD8},{"cli",M_IMP,0x58},{"clv",M_IMP,0xB8},
    {"sed",M_IMP,0xF8},
    {"cmp",M_IMM,0xC9},{"cmp",M_ZP,0xC5},{"cmp",M_ZPX,0xD5},
    {"cmp",M_ABS,0xCD},{"cmp",M_ABSX,0xDD},{"cmp",M_IND_Y,0xD1},{"cmp",M_IND_ZP,0xD2},
    {"cpx",M_IMM,0xE0},{"cpx",M_ZP,0xE4},{"cpx",M_ABS,0xEC},
    {"cpy",M_IMM,0xC0},{"cpy",M_ZP,0xC4},{"cpy",M_ABS,0xCC},
    {"dec",M_ACC,0x3A},{"dec",M_ZP,0xC6},{"dec",M_ZPX,0xD6},{"dec",M_ABS,0xCE},
    {"dex",M_IMP,0xCA},{"dey",M_IMP,0x88},
    {"eor",M_IMM,0x49},{"eor",M_ZP,0x45},{"eor",M_ZPX,0x55},
    {"eor",M_ABS,0x4D},{"eor",M_IND_Y,0x51},{"eor",M_IND_ZP,0x52},
    {"inc",M_ACC,0x1A},{"inc",M_ZP,0xE6},{"inc",M_ZPX,0xF6},{"inc",M_ABS,0xEE},
    {"inx",M_IMP,0xE8},{"iny",M_IMP,0xC8},
    {"jmp",M_ABS,0x4C},{"jmp",M_IND,0x6C},
    {"jsr",M_ABS,0x20},
    {"lda",M_IMM,0xA9},{"lda",M_ZP,0xA5},{"lda",M_ZPX,0xB5},
    {"lda",M_ABS,0xAD},{"lda",M_ABSX,0xBD},{"lda",M_ABSY,0xB9},
    {"lda",M_IND_Y,0xB1},{"lda",M_IND_ZP,0xB2},
    {"ldx",M_IMM,0xA2},{"ldx",M_ZP,0xA6},{"ldx",M_ZPX,0x96},
    {"ldx",M_ABS,0xAE},{"ldx",M_ABSY,0xBE},
    {"ldy",M_IMM,0xA0},{"ldy",M_ZP,0xA4},{"ldy",M_ZPX,0xB4},{"ldy",M_ABS,0xAC},
    {"lsr",M_ACC,0x4A},{"lsr",M_ZP,0x46},{"lsr",M_ZPX,0x56},{"lsr",M_ABS,0x4E},
    {"nop",M_IMP,0xEA},
    {"ora",M_IMM,0x09},{"ora",M_ZP,0x05},{"ora",M_ZPX,0x15},
    {"ora",M_ABS,0x0D},{"ora",M_IND_Y,0x11},{"ora",M_IND_ZP,0x12},
    {"pha",M_IMP,0x48},{"php",M_IMP,0x08},
    {"pla",M_IMP,0x68},{"plp",M_IMP,0x28},
    {"phy",M_IMP,0x5A},{"ply",M_IMP,0x7A},
    {"phx",M_IMP,0xDA},{"plx",M_IMP,0xFA},
    {"rol",M_ACC,0x2A},{"rol",M_ZP,0x26},{"rol",M_ZPX,0x36},{"rol",M_ABS,0x2E},
    {"ror",M_ACC,0x6A},{"ror",M_ZP,0x66},{"ror",M_ZPX,0x76},{"ror",M_ABS,0x6E},
    {"rti",M_IMP,0x40},{"rts",M_IMP,0x60},
    {"sbc",M_IMM,0xE9},{"sbc",M_ZP,0xE5},{"sbc",M_ZPX,0xF5},
    {"sbc",M_ABS,0xED},{"sbc",M_ABSX,0xFD},{"sbc",M_IND_Y,0xF1},{"sbc",M_IND_ZP,0xF2},
    {"sec",M_IMP,0x38},{"sei",M_IMP,0x78},
    {"sta",M_ZP,0x85},{"sta",M_ZPX,0x95},{"sta",M_ABS,0x8D},
    {"sta",M_ABSX,0x9D},{"sta",M_ABSY,0x99},{"sta",M_IND_Y,0x91},{"sta",M_IND_ZP,0x92},
    {"stx",M_ZP,0x86},{"stx",M_ZPY,0x96},{"stx",M_ABS,0x8E},
    {"sty",M_ZP,0x84},{"sty",M_ZPX,0x94},{"sty",M_ABS,0x8C},
    {"stz",M_ZP,0x64},{"stz",M_ZPX,0x74},{"stz",M_ABS,0x9C},
    {"tax",M_IMP,0xAA},{"tay",M_IMP,0xA8},
    {"tsx",M_IMP,0xBA},{"txa",M_IMP,0x8A},
    {"txs",M_IMP,0x9A},{"tya",M_IMP,0x98},
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

/* ── symbol table ────────────────────────────────────────────────────────── */
typedef struct { char name[SYM_NAME_LEN]; int value; } Symbol;
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
        nsyms++;
    }
}
static int sym_get(const char *name, int *out) {
    int i = sym_find(name);
    if (i < 0) return 0;
    *out = syms[i].value;
    return 1;
}

/* ── error list ──────────────────────────────────────────────────────────── */
static char errors[MAX_ERRORS][ERR_LEN];
static int  nerrors = 0;
static void add_error(int lineno, const char *msg) {
    if (nerrors < MAX_ERRORS) {
        snprintf(errors[nerrors], ERR_LEN, "Line %d: %s", lineno, msg);
        nerrors++;
    }
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
static int scoped_get(const char *name, int *out) {
    if (name[0] == '@') {
        char full[SYM_NAME_LEN];
        scoped_name(full, name);
        if (sym_get(full, out)) return 1;
    }
    return sym_get(name, out);
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
        /* check all chars are digits */
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
        /* make sure outer parens match */
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

    /* binary operators: try + - first (lowest precedence), then * / */
    /* scan right-to-left so left-most operator wins (left-assoc) */
    {
        /* + and - : but not a leading sign */
        int i = find_binop(s, len, "+-");
        if (i > 0) {
            char left[LINE_LEN], right[LINE_LEN];
            strncpy(left,  s,   i); left[i] = '\0'; str_trim(left);
            strncpy(right, s+i+1, LINE_LEN-1); str_trim(right);
            int el=0, er=0;
            int L = eval_expr(left,  pc, pass2, &el);
            int R = eval_expr(right, pc, pass2, &er);
            if (!el && !er) {
                return s[i]=='+' ? L+R : L-R;
            }
        }
        i = find_binop(s, len, "*/");
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

    /* unary minus */
    if (s[0] == '-') {
        int v = eval_expr(s+1, pc, pass2, err);
        return -v;
    }

    /* symbol lookup */
    if (is_ident_start(s[0])) {
        int v = 0;
        if (scoped_get(s, &v)) return v;
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
                } else if (val <= 0xFF) {
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
        if (val <= 0xFF) { res.mode = M_ZP;  res.value = val; return res; }
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
} LineInfo;

static LineInfo pc_map[MAX_LINES];
static int      nlines = 0;

typedef struct {
    int first_opcode_pc;
    int last_code_pc_before_vectors;
} AsmStats;

static AsmStats asm_stats;

/* ── memory image ────────────────────────────────────────────────────────── */
/* Standalone build (ASM65C02_MAIN): we own mem[].
   Included by sim65c02.c: sim owns mem[], we use it via extern. */
#ifdef ASM65C02_MAIN
uint8_t mem[65536];
#else
extern uint8_t mem[65536];
#endif

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

    /* collect raw lines */
    static char *raw_lines[MAX_LINES];
    static char  line_store[MAX_LINES][LINE_LEN];
    int nl = 0;
    char *p = source_copy;
    while (*p && nl < MAX_LINES) {
        raw_lines[nl] = p;
        while (*p && *p != '\n') p++;
        int llen = (int)(p - raw_lines[nl]);
        if (llen > LINE_LEN-1) llen = LINE_LEN-1;
        strncpy(line_store[nl], raw_lines[nl], llen);
        line_store[nl][llen] = '\0';
        raw_lines[nl] = line_store[nl];
        if (*p) p++;
        nl++;
    }

    memset(mem, 0, sizeof(mem));
    nsyms = 0; nerrors = 0; nlines = 0;
    asm_stats.first_opcode_pc = -1;
    asm_stats.last_code_pc_before_vectors = -1;
    g_scope[0] = '\0';

    /* ── PASS 1: collect labels, compute addresses ── */
    int pc = 0;
    for (int li = 0; li < nl; li++) {
        int lineno = li + 1;
        char label[LINE_LEN], mnem[LINE_LEN], operand[LINE_LEN];
        int is_eq = parse_line(raw_lines[li], label, mnem, operand);

        /* store in pc_map */
        LineInfo *info = &pc_map[nlines++];
        info->lineno   = lineno;
        info->pc       = pc;
        info->is_equate = is_eq;
        strncpy(info->label,   label,   LINE_LEN-1);
        strncpy(info->mnem,    mnem,    LINE_LEN-1);
        strncpy(info->operand, operand, LINE_LEN-1);

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
            sym_set(full, pc);
        }

        if (!mnem[0]) continue;

        /* normalise mnemonic */
        char mn[LINE_LEN]; str_lower(mn, mnem);
        if (!strcmp(mn, ".db"))  strcpy(mn, ".byte");
        if (!strcmp(mn, ".dw"))  strcpy(mn, ".word");

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
        if (!strcmp(mn,".opt")||!strcmp(mn,".setcpu")||
            !strcmp(mn,".code")||!strcmp(mn,".segment")) continue;

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

    /* ── PASS 1.5: re-resolve equates now all labels known ── */
    g_scope[0] = '\0';
    for (int li = 0; li < nlines; li++) {
        LineInfo *info = &pc_map[li];
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
    for (int li = 0; li < nlines; li++) {
        LineInfo *info = &pc_map[li];
        int lineno = info->lineno;
        pc = info->pc;

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
                int addr = (pc + i) & 0xFFFF;
                mem[addr] = tmp[i];
                if (addr < 0xFFFA && addr > asm_stats.last_code_pc_before_vectors)
                    asm_stats.last_code_pc_before_vectors = addr;
            }
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
                    mem[wpc]   = val & 0xFF;
                    mem[wpc+1] = (val >> 8) & 0xFF;
                    if (wpc < 0xFFFA && wpc > asm_stats.last_code_pc_before_vectors)
                        asm_stats.last_code_pc_before_vectors = wpc;
                    if ((wpc + 1) < 0xFFFA && (wpc + 1) > asm_stats.last_code_pc_before_vectors)
                        asm_stats.last_code_pc_before_vectors = wpc + 1;
                    wpc += 2;
                }
                if (*q == ',') q++;
            }
            continue;
        }
        if (!strcmp(mn,".opt")||!strcmp(mn,".setcpu")||
            !strcmp(mn,".code")||!strcmp(mn,".segment")) continue;

        if (!mnem_known(mn)) continue;

        Operand oper = parse_operand(op, mn, pc, 1);
        Mode m = promote(mn, oper.mode);
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
        mem[pc] = (uint8_t)opc;
        if (asm_stats.first_opcode_pc < 0)
            asm_stats.first_opcode_pc = pc;
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
                mem[pc+1] = (uint8_t)(offset & 0xFF);
            } else {
                mem[pc+1] = (uint8_t)(val & 0xFF);
                if (sz == 3) mem[pc+2] = (uint8_t)((val >> 8) & 0xFF);
            }
        }
    }

    return (nerrors == 0);
}

/* ── size report ─────────────────────────────────────────────────────────── */
static void size_report(void) {
    if (asm_stats.first_opcode_pc < 0 || asm_stats.last_code_pc_before_vectors < 0) {
        printf("\nROM footprint: no emitted code bytes before vectors.\n");
        return;
    }

    int used = asm_stats.last_code_pc_before_vectors - asm_stats.first_opcode_pc + 1;
    printf("\nROM footprint: $%04X-$%04X = %d bytes (up to vectors at $FFFA-$FFFF)\n",
           asm_stats.first_opcode_pc,
           asm_stats.last_code_pc_before_vectors,
           used);
    if (used <= 2048)
        printf("(%d/2048 = %.1f%% of 2KB)\n", used, 100.0*used/2048);
    else if (used <= 4096)
        printf("(%d/4096 = %.1f%% of 4KB)\n", used, 100.0*used/4096);
}

static int parse_hex_range(const char *s, int *start, int *end) {
    const char *dash = strchr(s, '-');
    if (!dash) return 0;

    char left[64], right[64];
    int llen = (int)(dash - s);
    int rlen = (int)strlen(dash + 1);
    if (llen <= 0 || rlen <= 0 || llen >= (int)sizeof(left) || rlen >= (int)sizeof(right)) return 0;

    memcpy(left, s, llen); left[llen] = '\0';
    memcpy(right, dash + 1, rlen); right[rlen] = '\0';

    while (*left == ' ' || *left == '\t') memmove(left, left + 1, strlen(left));
    while (*right == ' ' || *right == '\t') memmove(right, right + 1, strlen(right));
    str_trim(left);
    str_trim(right);

    const char *lp = left;
    const char *rp = right;
    if (*lp == '$') lp++;
    if (*rp == '$') rp++;
    if ((lp[0] == '0' && (lp[1] == 'x' || lp[1] == 'X'))) lp += 2;
    if ((rp[0] == '0' && (rp[1] == 'x' || rp[1] == 'X'))) rp += 2;
    if (*lp == '\0' || *rp == '\0') return 0;

    char *endp1 = NULL, *endp2 = NULL;
    long a = strtol(lp, &endp1, 16);
    long b = strtol(rp, &endp2, 16);
    if (!endp1 || !endp2 || *endp1 != '\0' || *endp2 != '\0') return 0;
    if (a < 0 || a > 0xFFFF || b < 0 || b > 0xFFFF || a > b) return 0;

    *start = (int)a;
    *end = (int)b;
    return 1;
}

/* ── CLI main (standalone build only) ───────────────────────────────────── */
#ifdef ASM65C02_MAIN
static void asm_usage(FILE *out) {
    fprintf(out,
        "asm65c02 v1.5 — Toy 65C02 two-pass assembler\n"
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
        "  -o <file>    Write binary image to <file> (avoids stdout/binary issues on Win32).\n"
        "  -r <range>   Output only address range for binary output, e.g. -r $F000-$FFFF.\n"
        "               Also accepts F000-FFFF or 0xF000-0xFFFF.\n"
        "               Preferred ROM extraction examples:\n"
        "                 asm65c02 uBASIC.asm -o rom.bin -r $F800-$FFFF\n"
        "                 asm65c02 4kBASIC.asm -o rom.bin -r $F000-$FFFF\n"
        "  --dump-all   Print all assembled symbols after the key-symbol table.\n"
        "  --help, -h   Print this help and exit.\n"
        "\n"
        "Projects:\n"
        "  uBASIC.asm    uBASIC    (2 KB ROM at $F800-$FFFF)\n"
        "  4kBASIC.asm   4K BASIC  (4 KB ROM at $F000-$FFFF)\n"
        "\n"
        "Build:\n"
        "  gcc -O2 -DASM65C02_MAIN -o asm65c02 asm65c02.c\n"
    );
}

int main(int argc, char **argv) {
    /* --help (or -h) anywhere in args */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            asm_usage(stdout);
            return 0;
        }
    }

    if (argc < 2) {
        asm_usage(stderr);
        return 1;
    }

    const char *src_file = NULL;
    int binary_mode = 0;
    int dump_all    = 0;
    const char *out_file = NULL;
    int range_enabled = 0;
    int range_start = 0;
    int range_end = 0xFFFF;
    int end_of_options = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--")) {
            end_of_options = 1;
            continue;
        }

        if ((end_of_options || argv[i][0] != '-') && !src_file) {
            src_file = argv[i];
            continue;
        }

        if (end_of_options || argv[i][0] != '-') {
            fprintf(stderr, "Unexpected extra input file: %s\n", argv[i]);
            return 1;
        }

        if      (!strcmp(argv[i], "--binary"))   binary_mode = 1;
        else if (!strcmp(argv[i], "--dump-all")) dump_all    = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            asm_usage(stdout);
            return 0;
        }
        else if (!strcmp(argv[i], "-o")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "-o requires a filename\n");
                return 1;
            }
            out_file = argv[++i];
            binary_mode = 1;
        }
        else if (!strcmp(argv[i], "-r")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "-r requires a range like $F000-$FFFF (or F000-FFFF)\n");
                return 1;
            }
            if (!parse_hex_range(argv[++i], &range_start, &range_end)) {
                fprintf(stderr, "Invalid range '%s' (expected $HHHH-$HHHH or HHHH-HHHH)\n", argv[i]);
                return 1;
            }
            range_enabled = 1;
        }
        else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        }
    }

    if (!src_file) {
        fprintf(stderr, "Missing input file.\n\n");
        asm_usage(stderr);
        return 1;
    }

    if (range_enabled && !binary_mode) {
        fprintf(stderr, "-r requires --binary (or -o) output mode\n");
        return 1;
    }

    /* read source file */
    FILE *f = fopen(src_file, "r");
    if (!f) { perror(src_file); return 1; }
    static char source[1024*1024];
    size_t n = fread(source, 1, sizeof(source)-1, f);
    fclose(f);
    source[n] = '\0';

    int ok = assemble(source);

    if (binary_mode) {
        /* write flat 65536-byte image to stdout; errors to stderr */
        for (int i = 0; i < nerrors; i++) fprintf(stderr, "%s\n", errors[i]);
        if (!ok) return 1;
        int out_start = range_enabled ? range_start : 0;
        int out_end = range_enabled ? range_end : 0xFFFF;
        size_t out_len = (size_t)(out_end - out_start + 1);
        int rv = mem[0xFFFC] | (mem[0xFFFD] << 8);
        if (out_file) {
            FILE *of = fopen(out_file, "wb");
            if (!of) {
                perror(out_file);
                return 1;
            }
            fwrite(mem + out_start, 1, out_len, of);
            fclose(of);
        } else {
            fwrite(mem + out_start, 1, out_len, stdout);
        }
        fprintf(stderr,
                "Assembled OK: input=%s output=%s range=$%04X-$%04X bytes=%zu reset=$%04X\n",
                src_file,
                out_file ? out_file : "stdout",
                (unsigned)out_start,
                (unsigned)out_end,
                out_len,
                (unsigned)rv);
        return 0;
    }

    /* human-readable report */
    if (nerrors) {
        printf("\nERRORS (%d):\n", nerrors);
        for (int i = 0; i < nerrors; i++) printf("  %s\n", errors[i]);
    } else {
        printf("No errors.\n");
    }

    /* key symbols */
    static const char *key_syms[] = {
        "INIT","MAIN","GETLINE","STMT","EXPR","STR_BANNER",
        "DO_PRINT","DO_LET","DO_IF","DO_GOTO","DO_INPUT",
        "DO_END","DO_LIST","DO_RUN","DO_NEW","PRT16","PNUM",
        NULL
    };
    printf("\n------------------------------------------------------------\n");
    printf("Key symbols:\n");
    for (int i = 0; key_syms[i]; i++) {
        int sv;
        if (sym_get(key_syms[i], &sv))
            printf("  %-16s = $%04X\n", key_syms[i], (unsigned)sv);
    }
    int rv = mem[0xFFFC] | (mem[0xFFFD]<<8);
    printf("\n  Reset vector         = $%04X\n", (unsigned)rv);

    if (dump_all) {
        printf("\n--- ALL SYMBOLS ---\n");
        for (int i = 0; i < nsyms; i++)
            printf("  $%04X  %s\n", (unsigned)syms[i].value, syms[i].name);
        printf("-------------------\n");
    }

    size_report();
    return ok ? 0 : 1;
}
#endif /* ASM65C02_MAIN */
