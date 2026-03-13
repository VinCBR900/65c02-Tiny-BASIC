; =============================================================================
; 4K Integer BASIC v12.4 for the 65C02
;    
; A faily extensive self-contained Fixed Point BASIC interpreter in 4 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; NEW to clear and enter your own program).
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
; Credit to Oscar Toledo for his x86 BootBASIC inspiration.
;
; =============================================================================
;
; Statements:
;   PRINT [item [; item ...]]
;            item = "string" | AT(col,row) | CHR$(n) | expression
;            ';' between items suppresses newline; trailing ';' suppresses final CR
;   IF expr THEN stmt [ELSE stmt2]   single-line; ELSE is optional
;   FOR var = start TO end [STEP n]  ...  NEXT var
;   GOTO lineno        branch unconditionally
;   GOSUB lineno       call subroutine; RETURN to resume
;   ON expr GOTO line1 [, line2, ...]   computed branch (falls through if out of range)
;   INPUT [prompt;] var [, var ...]    read from keyboard
;   LET var = expr     explicit assignment (LET keyword optional)
;   POKE addr, val     write byte to memory
;   READ var [, var ...]   read next value from DATA sequence
;   DATA val [, val ...]   literal values in program (consumed by READ)
;   RESTORE            reset DATA pointer to start of program
;   REM ...            comment to end of line
;   RUN                execute program from first line
;   LIST               list stored program
;   NEW                clear program
;   END                stop execution
;   RETURN             return from GOSUB
;   FREE               print bytes of program RAM remaining
;   CLS                clear screen, cursor to (0,0)
;   HELP               show brief command list
;   GOTO expr          branch to line (expr may be variable or expression)
;   GOSUB expr         call subroutine at line (expr may be variable or expression)
;   ON expr GOTO line1 [, line2, ...]   computed branch
;   ON expr GOSUB line1 [, line2, ...]  computed subroutine call
;   Multi-statement:   ':' separates statements on one line. 
; 			Dont have FOR/NEXT or GOSUB/RETURN on same line
;
; Expressions  (left-to-right within tier):
;   Tier 1 (lowest): AND  OR  XOR       (bitwise / logical)
;   Tier 2:          =  <>  <  >  <=  >=  (comparisons: return -1=true, 0=false)
;   Tier 3:          +  -
;   Tier 4:          *  /  %  MOD       (% and MOD are identical: integer remainder)
;   Tier 5 (atoms):  literal  variable  (expr)  -expr  +expr  NOT expr
;                    ABS(n)              absolute value
;                    SGN(n)              sign: -1, 0, or 1
;                    CHR$(n)             character with ASCII code n  (PRINT only)
;                    HEX$(n)             4-digit uppercase hex of n   (PRINT only)
;                    ASC("c")            ASCII code of first char of string
;                    PEEK(addr)          read byte from memory address
;                    USR(addr)           call machine-code subroutine, A=lo T0
;                    RND                 pseudo-random 1..32767 (no argument)
;                    INKEY               non-blocking key poll; 0 if no key
;
; Numbers:     signed 16-bit integers  -32768 .. 32767
; Variables:   A .. Z  (26 x 2-byte, zero-page)
; Line range:  1 .. 32767
;
; Error codes  (printed as  XX ERR [IN line]):
;   SN  syntax / bad expression
;   UL  undefined line number
;   OV  division by zero (overflow)
;   OM  out of memory
;   NR  nesting error (GOSUB/FOR overflow or RETURN/NEXT without matching opener)
;   ST  zero STEP in FOR
;   UK  unknown statement
;   OD  out of DATA  (READ with no more values)
;
; I/O  (Kowalski virtual terminal):
;   $E000  write = TERMINAL_CLS     clear screen, cursor to (0,0)
;   $E001  write = character output (PUTCH)
;   $E004  read  = character input  (GETCH, non-blocking poll; 0 = no char)
;   $E005  write = TERMINAL_X_POS  cursor column  (0-based)
;   $E006  write = TERMINAL_Y_POS  cursor row     (0-based)
;
; Memory map:
;   $0000-$00BD  zero page  (see layout below)
;   $0200-$0FFF  program storage  (RAM_TOP = $1000, ~3.5 KB)
;   $F000        JMP INIT  (reset-vector workaround)
;   $F003-$F020  STMT_JT   statement jump table  (30 bytes, 15 entries)
;   $F021-$F0F5  KW_TABLE  keyword strings        (213 bytes, 38 keywords)
;   $F0F7-$F106  ERR_TABLE 9 x 2-char error codes
;   $F107+       interpreter code  (INIT, MAIN, GETLINE, STMT, EXPR ...)
;   $FF26+       string literals   (all on same ROM page ? PUTSTR constraint)
;   $FFFA-$FFFF  vectors  (all point to INIT)
;
; Assembler / simulator:
;   asm65c02.c  v1.0  ?  two-pass 65C02 C assembler (replaces assembler.py)
;   sim65c02.c  v5    ?  65C02 simulator with Kowalski-compatible I/O
;   Build:  gcc -O2 -DASM65C02_MAIN -o asm65c02 asm65c02.c
;           gcc -O2 -o sim65c02 sim65c02.c
;   Run:    ./asm65c02 4kbasic_v7.asm
;           ./sim65c02 4kbasic_v7.asm --input "PRINT 1+1" --maxcycles 500000
;
; v12.4 changes vs v12.3:
;   - BUG FIX: SGN(positive) returned 257 instead of 1.
;     The .BYTE $2C skip-trick was applied to commented-out code, so the skip
;     target was wrong: A=1 landed in E2_sgn_neg's STA T0+1, giving hi=1.
;     Fix: restore explicit  LDA #1 / STA T0 / STZ T0+1 / RTS  for the
;     positive path; drop the .BYTE $2C trick entirely.
;   - BUG FIX: HEX$(n) returned 0 / was not recognised.
;     TOK_HEXS=$A8 was defined but "HEX$" was missing from KW_TABLE and had
;     no handler. Fix: add .DB 4,"HEX$",0 to KW_TABLE after RND; add handler
;     in DO_PRINT that prints T0 as 4-digit uppercase hex via PRT_HEX.
;     PRT_HEX helper added (~20 bytes); also reachable from EXPR2 for
;     completeness (though documented as PRINT-only).
;
; v12.3 changes vs v12.2:
;   - IRQ handler extended: BREAK now prints "BREAK IN nnn" (line number)
;     by sharing DO_ERROR's " IN line\r\n" exit tail (DO_break_in label).
;     STR_BREAK trailing CRLF removed (-1B); CLI added to shared exit (+1B);
;     IRQ JMP DO_break_in replaces CLI+JMP MAIN (-1B). Net: -1 byte.
;
; v12.2 changes vs v12.1:
;   - PEEKC inlined at all 3 call sites (LDA (IP)) -- frees 6 bytes
;
; v12.1 changes vs v12.0:
;   - 65C02 zp-indirect (no Y) used in DO_LIST, GOTOL, TKEMIT, RD_body,
;     RD_f_go, RD_skip_ln, RD_uint -- saves 9 bytes total
;
; v12.0 changes vs v11.5:
;   - IRQ handler added.  Writing any value to $E007 (IO_IRQ) fires a
;     maskable IRQ.  If a program is running (RUN != 0), the handler clears
;     RUN / GRET / FSTK, unwinds the stack to RUNSP, prints "BREAK" and
;     returns to the MAIN prompt -- program store is fully intact.
;     If idle (RUN == 0), the IRQ is silently swallowed (RTI).
;   - CLI added to INIT so IRQs are active immediately at cold start.
;   - IO_IRQ = $E007 added as named I/O port constant.
;   - STR_BREAK added to string table.
;   - IRQ vector now points to IRQ_HANDLER instead of INIT.
;
; v11.4 changes vs v11.3:
;   - DO_GOTO / DO_GOSUB: CURLN now updated to target line number after GOTOL.
;     Bug: CURLN held the GOTO/GOSUB line's number, not the target's. Any FOR
;     loop at the jump target stored the wrong line number in its frame, so
;     NEXT could not find the FOR line to loop back to (loop exited after 1 pass).
;     Fix: 4 bytes in each handler (LDA T0/STA CURLN/LDA T0+1/STA CURLN+1)
;     before RUN_LINE. GOTOL always leaves T0 = the matched line number.
;   - Banner updated to v11.4.
;
; v11.3 changes vs v11.2:
;   - PRINT handler: ELSE token now treated as end-of-list after trailing ';'
;     (fixes spurious "0" when IF/THEN branch ends with PRINT CHR$(n); ELSE ...)
;   - Pre-loaded program replaced: full feature showcase (all statements + Mandelbrot)
;
; Zero-page layout:
;   $00-$01  IP      interpreter pointer  (token stream or program store)
;   $02-$03  PE      program end pointer
;   $04-$05  LP      scratch / line / keyword pointer
;   $06-$07  T0      expression result / scratch 0
;   $08-$09  T1      scratch 1
;   $0A-$0B  T2      scratch 2
;   $0C-$0D  CURLN   current executing line number
;   $0E      GRET    GOSUB nesting depth  (0-8)
;   $0F      RUN     non-zero while program is running
;   $10-$2F  IBUF    raw input buffer  (32 bytes)
;   $30-$4F  TBUF    tokenised buffer  (32 bytes)
;   $50-$8B  VARS    A-Z variables  (2 bytes each = 52 bytes)
;   $8C-$9B  GORET   GOSUB return-address stack  (8 x 2 bytes)
;   $9C      TKTOK   keyword scan index  (TRYKW scratch)
;   $9D      FSTK    FOR loop nesting depth  (0-4)
;   $9E-$B9  FOR_STK FOR stack frames  (4 x 7 bytes)
;   $BA      RUNSP    saved SP for GOTO/NEXT/GOSUB stack unwind
;   $BB      OP       saved MUL/DIV/MOD operator  ('*', '/' or '%')
;   $BC-$BD  DATA_PTR READ pointer into program store:
;              0    = reset/RESTORE'd ? rescan from PROG on next READ
;              PE   = exhausted, no more DATA values
;              else = position inside current DATA body (past TOK_DATA byte)
;
; Token stream format  (TBUF / program store):
;   Keywords    $80-$A5  (single byte)
;   Numbers     $FF <lo> <hi>  (3 bytes, little-endian)
;   Strings     passed through as-is, including surrounding quotes
;   End-of-line $0D followed by $00 sentinel
;
; Program storage line format:
;   <lineno_lo> <lineno_hi> <tokenised_body> $0D
; =============================================================================

; ---- assembler options -------------------------------------------------------
        .opt proc65c02

; ---- compile-time constants --------------------------------------------------
RAM_TOP  = $1000             ; first byte ABOVE usable RAM  (4 KB SRAM)
PROG     = $0200             ; program storage base address

; ---- Kowalski virtual I/O addresses ------------------------------------------
IO_CLS   = $E000             ; write any value to clear screen + home cursor
IO_PUTCH = $E001             ; write a character  (write only)
IO_GETCH = $E004             ; read a character   (read, 0 = no char)
IO_XPOS  = $E005             ; write column number  (0-based, write only)
IO_YPOS  = $E006             ; write row number     (0-based, write only)
IO_IRQ   = $E007             ; write any value to fire a maskable IRQ (Break key)

; ---- zero-page addresses -----------------------------------------------------
IP       = $00               ; 16-bit: interpreter pointer
PE       = $02               ; 16-bit: program end
LP       = $04               ; 16-bit: list/edit/scratch pointer
T0       = $06               ; 16-bit: expression result / scratch 0
T1       = $08               ; 16-bit: scratch 1
T2       = $0A               ; 16-bit: scratch 2
CURLN    = $0C               ; 16-bit: current executing line number
GRET     = $0E               ;  8-bit: GOSUB nesting depth
RUN      = $0F               ;  8-bit: 0 = idle, $FF = running
IBUF     = $10               ; 32 bytes: raw input buffer  ($10-$2F)
TBUF     = $30               ; 32 bytes: tokenised buffer  ($30-$4F)
VARS     = $50               ; 52 bytes: A-Z variables     ($50-$8B)
GORET    = $8C               ; 16 bytes: GOSUB return stack ($8C-$9B)
TKTOK    = $9C               ;  8-bit: TRYKW keyword index
FSTK     = $9D               ;  8-bit: FOR nesting depth
FOR_STK  = $9E               ; 28 bytes: FOR frames        ($9E-$B9)
FOR_FRSZ = 7                 ; bytes per FOR frame
RUNSP    = $BA               ;  8-bit: saved SP for stack unwind
OP       = $BB               ;  8-bit: MUL/DIV operator ('*' or '/')
DATA_PTR = $BC               ; 16-bit: pointer to next DATA value to READ ($BC-$BD)
RND_SEED = $BE               ; 16-bit: LFSR seed for RND  ($BE-$BF); init to $ACE1

; ---- token codes  ($80-$A8 range; $FF = inline number) ----------------------
TOK_PRINT  = $80
TOK_IF     = $81
TOK_GOTO   = $82
TOK_GOSUB  = $83
TOK_RETURN = $84
TOK_RUN    = $85
TOK_LIST   = $86
TOK_NEW    = $87
TOK_INPUT  = $88
TOK_REM    = $89
TOK_END    = $8A
TOK_FOR    = $8B
TOK_NEXT   = $8C
TOK_FREE   = $8D
TOK_POKE   = $8E
TOK_PEEK   = $8F
TOK_STEP   = $90
TOK_TO     = $91
TOK_CHRS   = $92
TOK_ASC    = $93
TOK_ABS    = $94
TOK_USR    = $95
TOK_AND    = $96
TOK_OR     = $97
TOK_NOT    = $98             ; NOT x  ? bitwise complement (unary prefix)
TOK_XOR    = $99             ; x XOR y ? bitwise exclusive-or
TOK_LET    = $9A
TOK_THEN   = $9B
TOK_CLS    = $9C
TOK_HELP   = $9D
TOK_AT     = $9E
TOK_ON     = $9F             ; ON n GOTO line1, line2, ...
TOK_INKEY  = $A0             ; INKEY ? non-blocking key poll
TOK_DATA   = $A1             ; DATA val, val, ...  (raw ASCII body stored verbatim)
TOK_READ   = $A2             ; READ var
TOK_RESTORE= $A3             ; RESTORE
TOK_ELSE   = $A4             ; ELSE clause of IF ... THEN ... ELSE ...
TOK_SGN    = $A5             ; SGN(n) ? sign: -1, 0, or 1
TOK_MOD    = $A6             ; MOD ? integer modulo operator (alias for %)
TOK_RND    = $A7             ; RND ? pseudo-random number 1..32767 (no argument)
TOK_HEXS   = $A8             ; HEX$(n) ? print n as 4-digit uppercase hex (PRINT only)
TOK_NUM    = $FF             ; inline 16-bit number follows

; ---- error codes  (byte index into ERR_TABLE; each entry is 2 chars) --------
ERR_SN   = 0                 ; syntax error
ERR_UL   = 2                 ; undefined line number
ERR_OV   = 4                 ; division by zero
ERR_OM   = 6                 ; out of memory
ERR_NR   = 8                 ; nesting error
ERR_ST   = 10                ; zero STEP
ERR_UK   = 12                ; unknown statement
ERR_OD   = 14                ; out of DATA

; =============================================================================
        .ORG $F000
	BRA INIT	; jump over table

; STRING TABLE  	; all strings on same page
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/kw addresses
STR_BANNER: .DB "4K BASIC v12.4"
STR_CRLF:   .DB	$0D,$0A,0
STR_BYTES:  .DB " BYTES FREE",$0D,$0A,0
STR_ERROR:  .DB " ERR",0
STR_IN:     .DB " IN ",0
STR_BREAK:  .DB $0D,$0A,"BREAK",0      ; trailing CRLF removed: shared exit provides PRNL

; =============================================================================
; INIT ? cold start: stack, zero page, load showcase end pointer, banner
;   In:  ? (reset entry point)
;   Out: ? (falls through to MAIN)
;   Clobbers: A X
; =============================================================================
INIT:
        LDX #$FF
        TXS                  ; initialise stack pointer
        CLD                  ; clear decimal mode
        CLI                  ; enable maskable IRQs (for $E007 Break key)
    ;    LDX #$BF             ; clear ZP $00-$FF inclusive (includes DATA_PTR at $BC-$BD)
INIT_z: STZ 0,x              ; 65C02 STZ zp,x  (no LDA #0 needed)
        DEX
        BPL INIT_z
        ; DATA_PTR ($BC-$BD) is zeroed by INIT_z above ? sentinel 0 = rescan from PROG
        LDA #$E1             ; seed RND LFSR to $ACE1 (must be non-zero)
        STA RND_SEED
        LDA #$AC
        STA RND_SEED+1
        LDA #<SHOWCASE_END  ; PE = end of pre-loaded showcase program
        STA PE
        LDA #>SHOWCASE_END
        STA PE+1
;        LDX #>STR_BANNER          ; hi byte for PUTSTR
        LDA #<STR_BANNER
        JSR PUTSTR            ; print banner
;        JSR CALC_FREE
	JSR DO_FREE
;        JSR PRT16
 ;       LDX #>STR_BYTES          ; hi byte for PUTSTR
;        LDA #<STR_BYTES
;        JSR PUTSTR            ; print "BYTES FREE\r\n"
        ; fall through to MAIN

; =============================================================================
; MAIN ? immediate-mode prompt loop
;   In:  ? (entered from INIT or after any statement completes)
;   Out: ? (loops forever)
;   Clobbers: everything (re-initialises per iteration)
; =============================================================================
MAIN:
        STZ RUN
        STZ FSTK
        LDA #'>'             ; prompt
        JSR PUTCH
        LDA #' '
        JSR PUTCH
        JSR GETLINE          ; fills IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        LDA #>TBUF
        STA IP+1
        JSR WPEEK
        CMP #$0D             ; empty line?
        BEQ MAIN
        CMP #TOK_NUM         ; starts with a number -> line edit
        BNE MAIN_direct
        JSR EDITLN
        BRA MAIN
MAIN_direct:
        JSR STMT
        BRA MAIN

; =============================================================================
; GETLINE ? read one raw-text line into IBUF, then tokenise it into TBUF
;   In:  ?
;   Out: IBUF  CR-terminated raw text
;        TBUF  tokenised equivalent  (via fall-through to TOKENIZE)
;        IP    clobbered (used by TOKENIZE)
;   Clobbers: A X Y T0 T1
; =============================================================================
GETLINE:
        LDX #0
GL_lp:  JSR GETCH
        CMP #$0D
        BEQ GL_done
        CMP #$08             ; backspace
        BNE GL_store
        CPX #0
        BEQ GL_lp
        DEX
        BRA GL_lp
GL_store:
        CPX #31              ; 31 + CR = 32 byte limit
        BCS GL_lp            ; buffer full: ignore char (no echo)
        JSR PUTCH            ; echo
        STA IBUF,x
        INX
        BRA GL_lp
GL_done:
        LDA #$0D
        STA IBUF,x           ; CR-terminate
        JSR PRNL             ; echo CR+LF, then fall through to TOKENIZE
        ; *** FALL THROUGH to TOKENIZE ***

; =============================================================================
; TOKENIZE ? translate raw text in IBUF into token stream in TBUF
;   In:  IBUF  CR-terminated ASCII source line
;   Out: TBUF  token stream (keywords $80-$9F, numbers $FF lo hi,
;              strings/punct passed through, $0D $00 sentinel at end)
;        CURLN set to parsed leading line number (0 if none)
;   Clobbers: A X Y T0 T1 T2
; =============================================================================
TOKENIZE:
        LDA #<IBUF
        STA T0
        LDA #>IBUF
        STA T0+1
        LDA #<TBUF
        STA T1
        LDA #>TBUF
        STA T1+1

TK_TOP: LDA (T0)             ; 65C02 zp-indirect
        CMP #$0D
        BEQ TK_EOL
        CMP #0
        BEQ TK_EOL
        CMP #' '             ; skip spaces
        BNE TK_NS
        JSR TKADV
        BRA TK_TOP

TK_NS:  CMP #'"'             ; string literal: pass through verbatim
        BNE TK_NSTR
        JSR TKEMIT           ; emit opening '"'
TK_SC:  JSR TKADV
        LDA (T0)             ; 65C02 zp-indirect
        JSR TKEMIT
        CMP #'"'
        BNE TK_SC_cont
        JSR TKADV            ; advance past closing '"'
        BRA TK_TOP
TK_SC_cont:
        CMP #$0D
        BNE TK_SC
        BRA TK_EOL           ; unterminated string: treat as EOL

TK_NSTR:
        CMP #'0'             ; decimal digit?
        BCC TK_NNUM
        CMP #'9'+1
        BCS TK_NNUM
        JSR TKPNUM           ; parse number into CURLN
        LDA #TOK_NUM
        JSR TKEMIT
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1
        JSR TKEMIT
        BRA TK_TOP

TK_NNUM:
        JSR UC
        CMP #'A'             ; possible keyword or variable?
        BCC TK_OTHER
        CMP #'Z'+1
        BCS TK_OTHER
        JSR TRYKW            ; try keyword match  (C=0 matched, C=1 not)
        BCC TK_TOP           ; keyword emitted: continue
TK_OTHER:                    ; punctuation / unrecognised: emit as-is
        LDA (T0)             ; 65C02 zp-indirect: re-read variable letter
        JSR UC
        JSR TKEMIT
        JSR TKADV
        BRA TK_TOP

; TK_OTHER:                    ; punctuation / unrecognised: emit as-is
;        LDA (T0)             ; 65C02 zp-indirect
;        JSR TKEMIT
;        JSR TKADV
;        BRA TK_TOP

TK_EOL: LDA #$0D             ; write $0D $00 end-of-line sentinel
        LDY #0
        STA (T1),y
        INY
        LDA #0
        STA (T1),y
        RTS

; =============================================================================
; TKADV ? advance source pointer T0 by one byte
;   In:  T0   source pointer
;   Out: T0   incremented
;   Clobbers: ?  (flags preserved across branch; does NOT touch A)
; =============================================================================
TKADV:  INC T0
        BNE TKADV_ok
        INC T0+1
TKADV_ok:
        RTS

; =============================================================================
; TKEMIT ? write A to token output at T1, advance T1
;   In:  A    byte to write;  T1  destination pointer
;   Out: T1   incremented
;   Clobbers: Y
; =============================================================================
TKEMIT: STA (T1)             ; 65C02 zp-indirect: no Y needed  ($92 opcode)
        INC T1
        BNE TKEMIT_ok
        INC T1+1
TKEMIT_ok:
TKPN_dn:
        RTS

; =============================================================================
; TKPNUM ? parse decimal digit run at T0 into CURLN (16-bit unsigned)
;   In:  T0   points at first decimal digit
;   Out: CURLN  parsed value;  T0  advanced past all digit characters
;   Clobbers: A X Y T2
; =============================================================================
TKPNUM: STZ CURLN            ; 65C02 STZ zp
        STZ CURLN+1
TKPN_lp:
        LDA (T0)             ; 65C02 zp-indirect
        SEC
        SBC #'0'
        BCC TKPN_dn          ; < '0': done
        CMP #10
        BCS TKPN_dn          ; > '9': done
        PHA                  ; save digit
        JSR TKADV
        ; CURLN = CURLN * 10  using  (CURLN<<3) + (CURLN<<1)
        ASL CURLN            ; x2
        ROL CURLN+1
        LDA CURLN            ; save x2 in X,Y
        TAX
        LDA CURLN+1
        TAY
        ASL CURLN            ; x4
        ROL CURLN+1
        ASL CURLN            ; x8
        ROL CURLN+1
        TXA                  ; x8 + x2 = x10
        CLC
        ADC CURLN
        STA CURLN
        TYA
        ADC CURLN+1
        STA CURLN+1
        PLA                  ; add digit
        CLC
        ADC CURLN
        STA CURLN
        BCC TKPN_lp
        INC CURLN+1
        BRA TKPN_lp


; =============================================================================
; TRYKW ? try to match a keyword at the current source position (T0)
;   In:  T0    points at first character of candidate (already UC'd by caller)
;   Out: C=0   matched: token byte emitted via TKEMIT, T0 advanced past keyword
;        C=1   no match: T0 unchanged, nothing emitted
;        TKTOK keyword scan index (scratch; caller must not rely on value)
;   Clobbers: A Y T2
;   Note: CURLN is temporarily used to save/restore T0 during comparison;
;         the value is not meaningful until TOKENIZE assigns it via TKPNUM.
; =============================================================================
TRYKW:
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        LDA #TOK_PRINT
        STA TKTOK

TRY_ent:
        LDA (T2)             ; 65C02 zp-indirect: length byte (0 = end of table)
        BEQ TRY_fail
        TAX                  ; X = char count
        LDA T0               ; save T0 (source pos) for possible backtrack
        STA CURLN
        LDA T0+1
        STA CURLN+1
        LDA T2               ; LP = T2 + 1  (point at keyword chars)
        CLC
        ADC #1
        STA LP
        LDA T2+1
        ADC #0
        STA LP+1

        LDY #0               ; Y must be 0 for CMP (LP),y throughout this loop
TRY_cmp:
        LDA (T0)             ; 65C02 zp-indirect
        JSR UC
        CMP (LP),y           ; compare char at source vs char in keyword table (Y=0)
        BNE TRY_miss
        JSR TKADV            ; advance source
        INC LP
        BNE TRY_cmp_ok
        INC LP+1
TRY_cmp_ok:
        DEX
        BNE TRY_cmp
        ; ---- full match ----
        LDA TKTOK
        PHA
        CMP #TOK_DATA        ; DATA: emit token FIRST, then raw body verbatim
        BNE TRY_chk_rem
        PLA
        JSR TKEMIT           ; emit TOK_DATA before the raw value list
TRY_raw:                     ; copy raw bytes until $0D (shared by DATA body loop)
        LDA (T0)
        CMP #$0D
        BEQ TRY_raw_done
        JSR TKEMIT
        JSR TKADV
        BRA TRY_raw
;TRY_raw_done:
;        CLC
;        RTS
        
TRY_chk_rem:
        CMP #TOK_REM         ; REM: absorb rest of line verbatim, token emitted after
        BNE TRY_emt
TRY_rem:
        LDA (T0)
        CMP #$0D
        BEQ TRY_emt
        JSR TKEMIT
        JSR TKADV
        BRA TRY_rem
TRY_emt:
        PLA
        JSR TKEMIT
TRY_raw_done:
        CLC
        RTS

TRY_miss:                    ; this keyword doesn't match: restore T0, try next
        LDA CURLN
        STA T0
        LDA CURLN+1
        STA T0+1
        JSR KW_NEXT
        INC TKTOK
        BRA TRY_ent

TRY_fail:
        SEC
        RTS

; =============================================================================
; KW_NEXT ? advance T2 to the next entry in KW_TABLE
;   In:  T2   points at the length byte of the current entry
;   Out: T2   advanced past: length + chars + NUL  (i.e. by length+2)
;        Y    = 0  (side-effect of LDA (T2))
;   Clobbers: A
; =============================================================================
KW_NEXT:
        LDA (T2)             ; 65C02 zp-indirect: entry length
        CLC
        ADC #2               ; skip: len byte + char bytes + NUL = len+2
        ADC T2
        STA T2
        BCC KW_next_ok
        INC T2+1
KW_next_ok:
        RTS

; =============================================================================
; EDITLN ? insert, replace, or delete a numbered program line
;   In:  IP   points at tokenised line in TBUF  ($FF lo hi body $0D)
;   Out: program store updated:
;          body non-empty ? INSLINE (insert or replace)
;          body empty     ? DELINE  (delete existing line)
;        CURLN set to the edited line number
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
EDITLN:
        JSR PNUM             ; consume $FF lo hi, place value in T0
        LDA T0
        STA CURLN
        LDA T0+1
        STA CURLN+1
        LDA #<PROG
        STA LP
        LDA #>PROG
        STA LP+1

EL_fl:  LDA LP               ; scan for insertion/replacement point
        CMP PE
        BNE EL_go
        LDA LP+1
        CMP PE+1
        BEQ EL_ins           ; reached end: insert here
EL_go:  LDY #1
        LDA (LP),y           ; stored line-number hi byte
        CMP CURLN+1
        BCC EL_skip          ; stored hi < target hi: keep scanning
        BNE EL_ins           ; stored hi > target hi: insert before this line
        DEY                  ; Y = 0
        LDA (LP),y           ; stored line-number lo byte
        CMP CURLN
        BCC EL_skip
        BEQ EL_found         ; exact match: replace (delete then insert)
        BRA EL_ins

EL_skip:                     ; advance LP past current line  (scan body for $0D)
        LDY #2
EL_len: LDA (LP),y
        INY
        CMP #$0D
        BNE EL_len
        TYA                  ; Y = offset just past $0D
        CLC
        ADC LP
        STA LP
        BCC EL_fl
        INC LP+1
        BRA EL_fl

EL_found:
        JSR DELINE           ; delete existing line before re-inserting
EL_ins: JSR WPEEK            ; check for empty body (just CR/sentinel)
        CMP #$0D
        BEQ EL_done
        CMP #0
        BEQ EL_done
        JSR INSLINE          ; insert the new line
EL_done:
        RTS

; =============================================================================
; PNUM ? consume an inline $FF lo hi number token from IP, place value in T0
;   In:  IP   points at $FF token  (or whitespace before it)
;   Out: T0   16-bit value  (little-endian)
;        IP   advanced past the 3-byte $FF lo hi sequence
;   Clobbers: A
; =============================================================================
PNUM:   JSR WEAT             ; skip whitespace, consume $FF token
        LDA (IP)             ; 65C02: lo byte
        STA T0
        JSR GETCI            ; advance IP
        LDA (IP)             ; 65C02: hi byte
        STA T0+1
        JMP GETCI            ; advance IP and return  (tail call)

; =============================================================================
; DELINE ? remove the program line whose 2-byte header starts at LP
;   In:  LP   points at <lo> <hi> of line to delete
;        PE   program end pointer
;   Out: program bytes [LP+size .. PE) shifted down to LP
;        PE   decremented by deleted line's byte count
;   Clobbers: A Y T0 T1 T2
; =============================================================================
DELINE:
        LDY #2
DL_ll:  LDA (LP),y           ; scan body for terminating $0D
        INY
        CMP #$0D
        BNE DL_ll
        STY T1               ; T1 = line size (header + body + CR)
        TYA                  ; T0 = LP + size  (source for compaction)
        CLC
        ADC LP
        STA T0
        LDA LP+1
        ADC #0
        STA T0+1
        LDA PE               ; T2 = bytes remaining after this line
        SEC
        SBC T0
        STA T2
        LDA PE+1
        SBC T0+1
        STA T2+1
        LDA T2
        ORA T2+1
        BEQ DL_upd           ; nothing to shift: just update PE
        LDY #0
DL_cp:  LDA (T0),y           ; shift bytes down
        STA (LP),y
        INY
        BNE DL_nhi
        INC T0+1
        INC LP+1
DL_nhi: LDA T2
        BNE DL_dc
        DEC T2+1
DL_dc:  DEC T2
        LDA T2
        ORA T2+1
        BNE DL_cp
DL_upd: LDA PE               ; update PE
        SEC
        SBC T1
        STA PE
        BCS DL_ok
        DEC PE+1
DL_ok:  RTS

; =============================================================================
; INSLINE ? insert (or replace) a tokenised line in the program store
;   In:  IP   source: <body> $0D  (no $FF prefix ? PNUM already consumed it)
;        LP   insertion point (bytes LP..PE shifted up to make room)
;        PE   current program end
;        CURLN line number for the 2-byte header
;   Out: new line written at LP with 2-byte header prepended
;        PE   advanced by inserted byte count
;   Clobbers: A Y T0 T1 T2
; =============================================================================
INSLINE:
        LDA IP
        STA T0
        LDA IP+1
        STA T0+1
        LDY #0
IN_cnt: LDA (T0),y           ; count body bytes up to and including $0D
        CMP #$0D
        BEQ IN_ce
        INY
        BRA IN_cnt
IN_ce:  INY                  ; include the $0D itself
        TYA
        CLC
        ADC #2               ; + 2-byte header
        PHA                  ; total byte count on stack

        ; OOM check: PE + total > RAM_TOP ?
        CLC
        ADC PE
        STA T2
        LDA PE+1
        ADC #0
        STA T2+1
        LDA T2
        CMP #<RAM_TOP        ; lo byte compare
        LDA T2+1
        SBC #>RAM_TOP        ; hi byte with borrow
        BCC IN_ok            ; new PE < RAM_TOP: fits
        PLA
        LDA #ERR_OM
        JMP DO_ERROR

IN_ok:  ; shift [LP..PE) up by total to make room
        LDA PE
        SEC
        SBC LP
        STA T0               ; T0 = bytes to shift
        LDA PE+1
        SBC LP+1
        STA T0+1
        LDA T0
        ORA T0+1
        BEQ IN_shift         ; nothing to shift

        LDA PE               ; T0 = PE - 1  (top of source range)
        SEC
        SBC #1
        STA T0
        LDA PE+1
        SBC #0
        STA T0+1
        TSX
        LDA $0101,x          ; peek total from stack (without popping)
        CLC
        ADC T0               ; T1 = T0 + total  (top of destination range)
        STA T1
        LDA T0+1
        ADC #0
        STA T1+1
        LDA PE               ; T2 = bytes to shift (PE - LP)
        SEC
        SBC LP
        STA T2
        LDA PE+1
        SBC LP+1
        STA T2+1
IN_bk:  LDY #0               ; copy backwards: high addresses first
        LDA (T0),y
        STA (T1),y
        LDA T0               ; decrement T0
        BNE IN_bk_d0
        DEC T0+1
IN_bk_d0:
        DEC T0
        LDA T1               ; decrement T1
        BNE IN_bk_d1
        DEC T1+1
IN_bk_d1:
        DEC T1
        LDA T2               ; decrement T2 (byte counter)
        BNE IN_bk_d2
        DEC T2+1
IN_bk_d2:
        DEC T2
        LDA T2
        ORA T2+1
        BNE IN_bk

IN_shift:
        PLA                  ; recover total byte count
        CLC
        ADC PE               ; update PE
        STA PE
        BCC IN_hdr
        INC PE+1
IN_hdr: LDY #0               ; write 2-byte line-number header at LP
        LDA CURLN
        STA (LP),y
        INY
        LDA CURLN+1
        STA (LP),y
        LDA LP               ; T0 = LP + 2  (body destination)
        CLC
        ADC #2
        STA T0
        LDA LP+1
        ADC #0
        STA T0+1
        LDY #0
IN_cp:  LDA (IP),y           ; copy body from IP to T0
        STA (T0),y
        CMP #$0D
        BEQ IN_done
        INY
        BRA IN_cp
IN_done:
        RTS

; =============================================================================
; STMT ? decode and execute one statement from the token stream at IP
;   In:  IP   points at first token of statement
;        RUN  0 = immediate mode, non-zero = program running
;   Out: IP   advanced past the executed statement
;   Clobbers: A X Y T0 T1 T2 and anything the dispatched handler clobbers
; =============================================================================
; =============================================================================
; STMT ? decode and execute one statement from the token stream at IP
;   In:  IP   points at first token of statement
;        RUN  0 = immediate mode, non-zero = program running
;   Out: IP   advanced past the executed statement (and any trailing ': stmt')
;   Clobbers: A X Y T0 T1 T2 and anything the dispatched handler clobbers
;   Multi-statement: after each statement, if ':' follows, executes next stmt
;   on same line. Implemented as a tail-recursive loop (bounded by line length).
; =============================================================================
STMT:
        JSR WPEEK
        CMP #$0D             ; empty / end-of-line
        BEQ ST_nop
        CMP #0
        BEQ ST_nop
        BMI ST_tok           ; $80+ = keyword token (checked FIRST, before colon)
        CMP #':'             ; colon separator: skip and loop
        BEQ ST_colon
        JSR DO_LET           ; else implicit assignment  varname = expr
        BRA ST_sep           ; check for trailing ':'
ST_tok: JSR GETCI            ; consume token
        ; Tokens above TOK_POKE ($8E) that are statements are handled
        ; explicitly here; expression-modifier tokens $8F-$99 create a gap.
        CMP #TOK_CLS
        BEQ ST_cls
        CMP #TOK_HELP
        BEQ ST_help
        CMP #TOK_ON
        BEQ ST_on
        CMP #TOK_DATA
        BEQ ST_data
        CMP #TOK_READ
        BEQ ST_read
        CMP #TOK_RESTORE
        BEQ ST_restore
        CMP #TOK_ELSE
        BEQ ST_else          ; bare ELSE at statement level: skip rest of line
        SEC
        SBC #TOK_PRINT       ; make zero-based index  (valid for $80-$8E)
        ASL                  ; word index
        TAX
        ; Push ST_sep-1 so handler RTS lands at ST_sep (JSR-via-stack trick)
        LDA #>ST_sep_m1
        PHA
        LDA #<ST_sep_m1
        PHA
        .DB $7C              ; JMP (STMT_JT,X)  ? 65C02 absolute indexed indirect
        .DW STMT_JT
ST_cls: JSR DO_CLS
        BRA ST_sep
ST_help:JSR DO_HELP
        BRA ST_sep
ST_on:  JSR DO_ON            ; ON GOTO: may JMP RUNGO internally (no return)
        BRA ST_sep
ST_data:JSR DO_DATA
        BRA ST_sep
ST_read:JSR DO_READ
        BRA ST_sep
ST_restore: JSR DO_RESTORE
        BRA ST_sep
ST_else:JSR SKIPEOL          ; bare ELSE: skip rest of line (tail via BRA ST_nop)
        BRA ST_nop
ST_colon:
        JSR GETCI            ; consume ':'
        BRA STMT             ; execute next statement on same line
ST_sep_m1:                   ; real label: RTS from handler adds 1 ? ST_sep
        NOP                  ; never executed ? anchor byte for RTS return trick
ST_sep: JSR WPEEK            ; after any statement: check for ':'
        CMP #':'
        BEQ ST_colon         ; another statement on same line: loop
DP_ret: ; RTS                  ; ? used by semicolon-suppress path; shares nearest RTS

ST_nop: RTS

; =============================================================================
; STATEMENT HANDLERS
; =============================================================================

; =============================================================================
; DO_PRINT ? PRINT [item [; item ...]]
;   item:  string literal ("...")  |  AT(col,row)  |  CHR$(n)  |  expression
;   ';'  between items suppresses the newline and continues the list.
;   Trailing ';' at end-of-line suppresses the final CR+LF entirely.
;   Bare PRINT (no items) prints a blank line.
;   Clobbers: A X Y T0 T1 T2
; =============================================================================

DO_PRINT:
DP_top: JSR WPEEK
        CMP #$0D
        BEQ DP_nl_near       ; bare PRINT (EOL): just print newline
        CMP #0
        BEQ DP_nl_near       ; bare PRINT (sentinel): just print newline
        CMP #'"'             ; string literal in PRINT
        BNE DP_expr
        JSR GETCI            ; consume opening '"'
DP_str: JSR GETCI
        CMP #'"'
        BEQ DP_aft
        CMP #$0D
        BEQ DP_nl_near
        JSR PUTCH
        BRA DP_str
DP_nl_near: JMP PRNL         ; trampoline: forward jump to PRNL (out of BEQ range)
DP_expr:
        JSR WPEEK
        CMP #TOK_AT          ; AT(col,row): position cursor, then loop back to print what follows
        BNE DP_chk_chrs
        JSR GETCI            ; consume AT token
        JSR EAT_EXPR         ; col -> T0  (EAT_EXPR consumes the '(' first)
        LDA T0
        STA IO_XPOS          ; set cursor column ($E005)
        JSR EAT_EXPR         ; consume ',' then row -> T0
        LDA T0
        STA IO_YPOS          ; set cursor row ($E006)
        JSR WEAT             ; consume ')'
        JMP DP_top           ; loop back (too far for BRA)
DP_chk_chrs:
        CMP #TOK_CHRS        ; CHR$(n): emit char directly without conversion
        BNE DP_chk_hexs
        JSR GETCI            ; consume TOK_CHRS
        JSR EAT_EXPR
        JSR WEAT             ; consume ')'
        LDA T0
        JSR PUTCH
        BRA DP_aft
DP_chk_hexs:
        CMP #TOK_HEXS        ; HEX$(n): print 4-digit uppercase hex
        BNE DP_norm
        JSR GETCI            ; consume TOK_HEXS
        JSR EAT_EXPR         ; evaluate n -> T0  (EAT_EXPR consumes '(' first)
        JSR WEAT             ; consume ')'
        JSR PRT_HEX          ; print 4-digit uppercase hex
        BRA DP_aft
DP_norm:
        JSR EXPR
        JSR PRT16
DP_aft: JSR WPEEK
        CMP #';'             ; semicolon suppresses newline, continues list
        BEQ DP_semi
        BNE DP_nl            ; not semicolon: print newline and return
DP_semi:        JSR GETCI
        JSR WPEEK
        CMP #$0D             ; trailing semicolon at EOL: suppress newline
        BEQ DP_semi_dn
        CMP #0
        BEQ DP_semi_dn
        CMP #TOK_ELSE        ; semicolon before ELSE: stop printing (IF handles ELSE)
        BEQ DP_semi_dn
        JMP DP_top           ; more items: loop (too far for BRA)
DP_semi_dn:
        RTS                  ; suppress newline: return without printing CR+LF
DP_nl:  JMP PRNL             ; print CR+LF and return  (tail call)

; =============================================================================
; DO_IF ? IF expr [THEN] stmt [ELSE stmt2]
;   Single-line only.  ELSE clause is optional.
;   True:  JMP STMT for true branch; RUNLP's SKIPEOL skips remainder (incl ELSE).
;   False: scan forward token-by-token to TOK_ELSE or EOL;
;          if ELSE found, JMP STMT for false branch.
;   Clobbers: A X Y T0 T1 T2
; =============================================================================
DO_IF:
        JSR EXPR
        LDA T0
        ORA T0+1
        BNE DO_IF_true       ; condition true: execute THEN branch
        BRA DO_IF_f          ; condition false: hunt for ELSE

        ; -- condition true: execute THEN branch ------------------------------
DO_IF_true:
        JSR WPEEK
        CMP #TOK_THEN        ; optional THEN keyword
        BNE DO_IF_t_stmt
        JSR GETCI
DO_IF_t_stmt:
        JMP STMT             ; tail call ? RUNLP's SKIPEOL handles any ELSE remainder
DO_IF_done:
        RTS

        ; -- condition false: scan for ELSE -----------------------------------
DO_IF_f:
        JSR WPEEK
        CMP #$0D             ; EOL with no ELSE: done
        BEQ DO_IF_done
        CMP #0
        BEQ DO_IF_done
        CMP #TOK_ELSE
        BNE DO_IF_f_skip
        JSR GETCI            ; consume TOK_ELSE
        JSR WPEEK
        CMP #TOK_THEN        ; optional THEN after ELSE (forgiving)
        BNE DO_IF_f_stmt
        JSR GETCI
DO_IF_f_stmt:
        JMP STMT             ; tail call ? RUNLP's SKIPEOL handles remainder
DO_IF_f_skip:
        JSR GETCI            ; consume token
        CMP #TOK_NUM         ; inline number? consume 2 more bytes
        BNE DO_IF_f
        JSR GETCI
        JSR GETCI
        BRA DO_IF_f

; =============================================================================
; DO_GOTO ? GOTO lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOTO:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        JSR GOTOL
        BCS DO_gosub_ul      ; seek failed: share DO_GOSUB's error stub
        LDA T0               ; update CURLN to target line (GOTOL leaves T0=line#)
        STA CURLN
        LDA T0+1
        STA CURLN+1
        BRA RUN_LINE         ; seek succeeded: unwind stack and run

; =============================================================================
; DO_GOSUB ? GOSUB lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOSUB:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        LDA GRET
        CMP #8               ; max 8 levels of nesting
        BCC DO_gosub_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_gosub_ok:
        ASL
        TAX
        LDA IP               ; push return address (IP after the GOSUB)
        STA GORET,x
        LDA IP+1
        STA GORET+1,x
        INC GRET
        JSR GOTOL
        BCS DO_gosub_ul
        LDA T0               ; update CURLN to target line (GOTOL leaves T0=line#)
        STA CURLN
        LDA T0+1
        STA CURLN+1
RUN_LINE:
        LDX RUNSP
        TXS
        JMP RUNGO
DO_gosub_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; =============================================================================
; DO_RETURN ? RETURN
;   Clobbers: A X
; =============================================================================
DO_RETURN:
        LDA GRET
        BNE DO_return_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_return_ok:
        DEC GRET
        LDA GRET
        ASL
        TAX
        LDA GORET,x
        STA IP
        LDA GORET+1,x
        STA IP+1
        RTS

; =============================================================================
; DO_INPUT ? INPUT var
;   Clobbers: A X Y T0 T1 T2
; =============================================================================
DO_INPUT:
        JSR WPEEK_UC
        CMP #'A'
        BCC DO_input_dn
        CMP #'Z'+1
        BCS DO_input_dn
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; x2: byte offset into VARS
        PHA                  ; save slot
        LDA #'?'
        JSR PUTCH
        LDA #' '
        JSR PUTCH
        LDA IP               ; save IP across GETLINE
        STA T2
        LDA IP+1
        STA T2+1
        JSR GETLINE          ; reads into IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        LDA #>TBUF
        STA IP+1
        JSR EXPR             ; evaluate expression from TBUF
        LDA T2               ; restore IP
        STA IP
        LDA T2+1
        STA IP+1
        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
DO_input_dn:
        RTS

; =============================================================================
; DO_REM ? REM (comment): body already absorbed into token stream by TOKENIZE
;   Clobbers: ?
; =============================================================================
DO_REM: RTS

; =============================================================================
; DO_RUN ? RUN: start program from first line
;   Clobbers: A X
; =============================================================================
DO_RUN:
        LDA #<PROG
        STA IP
        LDA #>PROG
        STA IP+1
        STZ DATA_PTR         ; reset DATA pointer (sentinel 0 = rescan from PROG)
        STZ DATA_PTR+1
        STZ FSTK
        LDA #$FF
        STA RUN

; --- inner run loop  (also entered from DO_GOTO / DO_GOSUB / DO_NEXT) ---
RUNLP:
        TSX                  ; save SP so GOTO / NEXT can unwind
        STX RUNSP
        LDA IP               ; check IP == PE  (end of program)
        CMP PE
        BNE RUNLP_go
        LDA IP+1
        CMP PE+1
        BEQ RUNEND

RUNLP_go:                    ; read 2-byte line number header, advance IP by 2
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INCIP
RUNLP_hi:
        LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INCIP
RUNGO:  JSR STMT
        LDA RUN
        BEQ RUNEND
        JSR SKIPEOL
        BRA RUNLP

; DO_END and RUNEND both just clear RUN and return.
; Two labels on one instruction: DO_END is the handler entry, RUNEND is the
; shared landing target used by DO_RUN and NEXT_END.
DO_END:
RUNEND: STZ RUN
        RTS

; =============================================================================
; DO_LIST ? list all program lines, de-tokenising on the fly
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_LIST:
        LDA #<PROG
        STA LP
        LDA #>PROG
        STA LP+1

LS_ln:  LDA LP               ; end of program?
        CMP PE
        BNE LS_go
        LDA LP+1
        CMP PE+1
        BNE LS_go
        RTS                  ; ? DONE: nearest RTS used as LS_DONE return point
LS_go:
        LDA (LP)             ; 65C02: lo byte of line number
        STA T0
        LDY #1
        LDA (LP),y           ; hi byte
        STA T0+1
        JSR PRT16            ; print line number
        LDA #' '
        JSR PUTCH
        LDA LP               ; advance LP past 2-byte header
        CLC
        ADC #2
        STA LP
        BCC LS_body
        INC LP+1

LS_body:
        LDA (LP)             ; 65C02 zp-indirect
        CMP #$0D
        BEQ LS_eol
        CMP #TOK_NUM
        BEQ LS_num
        CMP #TOK_PRINT
        BCC LS_lit           ; < TOK_PRINT: literal char

        ; keyword token: walk KW_TABLE to find printable name
        SEC
        SBC #TOK_PRINT
        TAX                  ; X = keyword index (0-based)
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
LS_skp: CPX #0
        BEQ LS_prk
        JSR KW_NEXT
        DEX
        BRA LS_skp
LS_prk: LDY #1               ; skip length byte; print chars until NUL
LS_pkl: LDA (T2),y
        BEQ LS_pkd
        JSR PUTCH
        INY
        BRA LS_pkl
LS_pkd: JSR LS_adv
        LDA #' '
        JSR PUTCH
        BRA LS_body

LS_lit: JSR PUTCH            ; literal character: print and advance
        JSR LS_adv
        BRA LS_body

LS_eol: JSR LS_adv
        JSR PRNL             ; CR+LF
        BRA LS_ln

LS_num: JSR LS_adv           ; skip $FF token
        LDA (LP)             ; 65C02: lo byte
        STA T0
        JSR LS_adv
        LDA (LP)             ; hi byte (Y=0 unchanged from LS_adv)
        STA T0+1
        JSR LS_adv
        JSR PRT16
        LDA #' '
        JSR PUTCH
        BRA LS_body


; =============================================================================
; LS_ADV ? advance list pointer LP by one byte
;   In:  LP   pointer into program store
;   Out: LP   incremented
;   Clobbers: ?
; =============================================================================
LS_adv: INC LP
        BNE LS_adv_ok
        INC LP+1
LS_adv_ok:
        RTS

; =============================================================================
; DO_NEW ? clear program store and variables
;   Clobbers: A X
; =============================================================================
DO_NEW:
        LDA #<PROG
        STA PE
        LDA #>PROG
        STA PE+1
        STZ DATA_PTR
        STZ DATA_PTR+1
        STZ GRET
        STZ FSTK
        LDX #$3B             ; clear VARS $50-$8B  (52 bytes = $3B+1)
DO_new_z:
        STZ VARS,x           ; 65C02 STZ zp,x
        DEX
        BPL DO_new_z
        RTS

; =============================================================================
; DO_FREE ? FREE: print free program-store bytes
; CALC_FREE ? compute free program-storage bytes
;   In:  PE   current program end pointer
;   Out: T0   = RAM_TOP - PE  (unsigned 16-bit free byte count)
;   Clobbers: A T0
; =============================================================================
DO_FREE:
        LDA #<RAM_TOP
        SEC
        SBC PE
        STA T0
        LDA #>RAM_TOP
        SBC PE+1
        STA T0+1
        JSR PRT16
        LDA #<STR_BYTES
        JMP PUTSTR           ; print " BYTES FREE\r\n" and return  (tail call)


; =============================================================================
; DO_HELP ? HELP: list available keywords one per line
; Assumptions: 
; 1. KW_TABLE is a list of null-terminated strings, ending with a double-null or a length byte of 0.
; 2. KW_NEXT simply adds the length of the current string to T2.
;   Clobbers: A X Y T2
; =============================================================================
DO_HELP:
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
HLP_kw: LDA (T2)
        BEQ HLP_done
        LDY #1
HLP_pl: LDA (T2),y
        BEQ HLP_nl
        JSR PUTCH
        INY
        BRA HLP_pl
HLP_nl: LDA #' '
        JSR PUTCH
        JSR KW_NEXT
        BRA HLP_kw
HLP_done:
        ; drop through
        
; =============================================================================
; PUTSTR  -  print a NUL-terminated string from the string table
;
;   In:  A = lo-byte of string address; hi-byte is always STR_PAGE
;   Out: characters written to terminal
;   Clobbers: A Y T2
;
;   All strings must reside on page STR_PAGE.  A single byte pointer suffices
;   because STR_PAGE is loaded as the hi-byte here.
;
; PUTSTRZP: Print a NULL-Terminated String at T2 indirect
;
;   Entry from DP_NL is a fall-through tail call: DO_PRINT loads A = <STR_CRLF
;   then drops into PUTSTR rather than JSR+RTS, saving 3 bytes.
;   LS_DONE (end of DO_LIST) is co-located with PS_DN so both share this RTS.
; =============================================================================
PRNL:   LDA #<STR_CRLF
PUTSTR:  STA T2
         LDA #STR_PAGE
         STA T2+1
PUTSTRZP:
         LDY #0
PS_LP:   LDA (T2),Y
         BEQ PS_DN            ; NUL terminator: done
         JSR PUTCH
         inc T2 ;INY
         BRA PS_LP
; LS_DONE and PS_DN are adjacent because DO_LIST (end-of-program path) and
; PUTSTR (end-of-string path) both want a plain RTS here.
PS_DN:   RTS

; =============================================================================
; FOR/NEXT  ?  helper: FSTK_BASE
; =============================================================================

; =============================================================================
; FSTK_BASE ? compute base address of a FOR stack frame into LP
;   In:  A    frame index  (0 = bottom, FSTK-1 = current top)
;   Out: LP   = FOR_STK + A*7
;   Clobbers: A T2
;   Frame layout  (7 bytes at LP):
;     [0]  var_slot  (byte offset into VARS, 0=$A, 2=$B, ?)
;     [1]  limit_lo
;     [2]  limit_hi
;     [3]  step_lo
;     [4]  step_hi
;     [5]  loop_line_lo   (CURLN when FOR was executed)
;     [6]  loop_line_hi
; =============================================================================
FSTK_BASE:
        STA T2
        ASL
        ASL
        ASL               ; A * 8
        SEC
        SBC T2            ; A * 8 - A = A * 7
        CLC
        ADC #<FOR_STK
        STA LP
        LDA #>FOR_STK
        STA LP+1
        RTS

; =============================================================================
; DO_FOR ? FOR var = start TO limit [STEP step]
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_FOR:
        JSR WPEEK_UC
        CMP #'A'
        BCC DO_for_sn
        CMP #'Z'+1
        BCC DO_for_ok
DO_for_sn:
        LDA #ERR_SN
        JMP DO_ERROR
DO_for_ok:
        JSR GETCI            ; consume variable letter
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var_slot
        JSR EAT_EXPR         ; evaluate start value -> T0
        PLA
        TAX
        PHA                  ; save var_slot again (needed after EAT_EXPR)
        LDA T0
        STA VARS,x           ; store start value in variable
        LDA T0+1
        STA VARS+1,x
        JSR EAT_EXPR         ; consume '=' then evaluate '=', then TO, then limit
        LDA T0               ; push limit onto hardware stack
        PHA
        LDA T0+1
        PHA
        JSR WPEEK
        CMP #TOK_STEP
        BNE DO_for_nostep
        JSR GETCI            ; consume STEP token
        JSR EXPR             ; evaluate step -> T0
        LDA T0
        STA T2
        LDA T0+1
        STA T2+1
        BRA DO_for_havestep
DO_for_nostep:
        LDA #1               ; default step = 1
        STA T2
        STZ T2+1
DO_for_havestep:
        LDA T2               ; step of zero is illegal
        ORA T2+1
        BNE DO_for_szok
        PLA
        PLA
        PLA                  ; clean limit hi, limit lo, var_slot from stack
        LDA #ERR_ST
        JMP DO_ERROR
DO_for_szok:
        LDA FSTK
        CMP #4               ; max 4 nested FOR loops
        BCC DO_for_push
        PLA
        PLA
        PLA
        JMP DO_ERR_NR        ; ? shared error stub

DO_for_push:
        LDA T2               ; save step before FSTK_BASE clobbers T2
        PHA
        LDA T2+1
        PHA
        LDA FSTK
        JSR FSTK_BASE        ; LP = FOR_STK + FSTK*7  (clobbers T2)
        PLA
        STA T2+1             ; restore step hi
        PLA
        STA T2               ; restore step lo
        PLA
        STA T0+1             ; limit hi  (popped in push order: hi first)
        PLA
        STA T0               ; limit lo
        PLA                  ; var_slot
        LDY #0
        STA (LP),y           ; [0] var_slot
        INY
        LDA T0
        STA (LP),y           ; [1] limit_lo
        INY
        LDA T0+1
        STA (LP),y           ; [2] limit_hi
        INY
        LDA T2
        STA (LP),y           ; [3] step_lo
        INY
        LDA T2+1
        STA (LP),y           ; [4] step_hi
        INY
        LDA CURLN
        STA (LP),y           ; [5] loop_line_lo
        INY
        LDA CURLN+1
        STA (LP),y           ; [6] loop_line_hi
        INC FSTK
        RTS

; =============================================================================
; DO_NEXT ? NEXT [var]
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_NEXT:
        JSR WPEEK_UC         ; consume optional variable name (ignored)
        CMP #'A'
        BCC DO_next_novar
        CMP #'Z'+1
        BCS DO_next_novar
        JSR GETCI
DO_next_novar:
        LDA FSTK
        BNE DO_next_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_next_ok:
        LDA FSTK
        SEC
        SBC #1
        JSR FSTK_BASE        ; LP = base of top frame

        LDA (LP)             ; 65C02 zp-indirect: [0] var_slot
        TAX

        ; add step to loop variable
        LDY #3
        LDA (LP),y           ; [3] step_lo
        CLC
        ADC VARS,x
        STA VARS,x
        INY
        LDA (LP),y           ; [4] step_hi
        ADC VARS+1,x
        STA VARS+1,x

        ; load limit into T0
        LDY #1
        LDA (LP),y           ; [1] limit_lo
        STA T0
        INY
        LDA (LP),y           ; [2] limit_hi
        STA T0+1

        ; signed compare ? direction depends on step sign
        LDY #4
        LDA (LP),y           ; [4] step_hi
        BMI DN_neg_step

DN_pos_step:                 ; positive step: loop while var <= limit
        LDA VARS,x
        SEC
        SBC T0
        LDA VARS+1,x
        SBC T0+1
        BMI DN_loop          ; var < limit: keep looping
        LDA VARS,x           ; var == limit: loop one more time
        CMP T0
        BNE DN_done
        LDA VARS+1,x
        CMP T0+1
        BEQ DN_loop
        BRA DN_done

DN_neg_step:                 ; negative step: loop while var >= limit
        LDA T0
        SEC
        SBC VARS,x
        LDA T0+1
        SBC VARS+1,x
        BMI DN_loop          ; limit < var: keep looping
        LDA T0
        CMP VARS,x
        BNE DN_done
        LDA T0+1
        CMP VARS+1,x
        BEQ DN_loop
        BRA DN_done

DN_loop:                     ; branch back to body: load loop line, run it
        LDY #5
        LDA (LP),y           ; [5] loop_line_lo
        STA T0
        INY
        LDA (LP),y           ; [6] loop_line_hi
        STA T0+1
        JSR GOTOL
        BCS DN_ul
        JSR SKIPEOL          ; skip past FOR statement on that line
        LDA IP
        CMP PE
        BNE DN_runbody
        LDA IP+1
        CMP PE+1
        BEQ DN_end           ; IP == PE: program ended inside loop

DN_runbody:                  ; read 2-byte line-number header, advance IP
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INCIP
DN_rh:  LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INCIP
DN_rb2: JMP RUN_LINE         ; restore S and jump to target

DN_done:
        DEC FSTK
        RTS

DN_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; DN_end and RUNEND share the same body (clear RUN and return).
; Two adjacent labels: DN_end is the NEXT-loop EOF landing, RUNEND is
; already defined earlier; we can't duplicate ? use RUNEND directly.
DN_end: DEC FSTK
        STZ RUN
        RTS

; =============================================================================
; DO_POKE ? POKE addr, value
;   Clobbers: A Y T0 T1
; =============================================================================
DO_POKE:
        JSR EXPR             ; addr -> T0
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EAT_EXPR         ; consume ',' then value -> T0
        PLA
        STA T1+1             ; T1 = address
        PLA
        STA T1
        LDA T0
        LDY #0
        STA (T1),y           ; POKE the value  (STA (zp),y with Y=0)
        RTS

; =============================================================================
; DO_CLS ? CLS: clear terminal screen and home the cursor
;   Clobbers: A
; =============================================================================
DO_CLS:
        STA IO_CLS           ; write any value to $E000 ? clear screen
DO_on_skip:                  ; fall through to DO_DATA ? RTS
        RTS

; =============================================================================
; DO_ON ? ON expr GOTO line1 [, line2, ...]
;   Evaluates expr. If result is 1, GOTOs line1; if 2, line2; etc.
;   Out-of-range or 0: falls through to next statement silently.
;   Clobbers: A X T0 T1
; =============================================================================
DO_ON:
        JSR EXPR             ; selector value -> T0
        LDA T0+1
        BEQ DO_on_hi_ok      ; hi byte zero: value fits in lo byte
DO_on_skip_tr:
        rts ; JMP DO_on_skip       ; hi byte set (>255 or negative): skip
DO_on_hi_ok:
        LDA T0               ; lo byte = countdown (1-based); 0 = skip
        BEQ DO_on_skip_tr    ; 0: out of range, skip  (trampoline to JMP below)
DO_on_cnt_ok:
        STA T1
        JSR WPEEK            ; expect GOTO or GOSUB token
        CMP #TOK_GOTO
        BEQ DO_on_got_verb
        CMP #TOK_GOSUB
        BEQ DO_on_got_verb
        JMP DO_on_skip
DO_on_got_verb:
        STA OP               ; save verb (TOK_GOTO or TOK_GOSUB)
        JSR GETCI            ; consume verb
DO_on_lp:
        LDA T1               ; EXPR clobbers T1 ? save countdown
        PHA
        JSR EXPR             ; parse line number -> T0
        PLA
        STA T1
        DEC T1
        BEQ DO_on_go         ; this is our target
        JSR WPEEK
        CMP #','
        BEQ DO_on_more       ; comma: more entries to scan
        rts ; JMP DO_on_skip       ; no comma: index out of range, fall through
DO_on_more:
        JSR GETCI            ; consume ','
        BRA DO_on_lp         ; loop (JMP; BRA out of range)
DO_on_go:
        ; T0 = target line.  For GOSUB: skip remaining entries (to get IP past
        ; the whole ON stmt) and save IP before GOTOL moves it.
        ; T0 and IP must both survive ? push T0 onto hw stack now.
        LDA T0               ; push target line number (skip_rest EXPR clobbers T0)
        PHA
        LDA T0+1
        PHA
        LDA OP
        CMP #TOK_GOSUB
        BNE DO_on_go_seek
DO_on_skip_rest:
        JSR WPEEK
        CMP #','
        BNE DO_on_save_ip
        JSR GETCI
        JSR EXPR             ; discard remaining entry
        BRA DO_on_skip_rest
DO_on_save_ip:
        LDA IP               ; save return IP (past ON stmt) before GOTOL
        STA T2
        LDA IP+1
        STA T2+1
DO_on_go_seek:
        PLA                  ; restore target line number
        STA T0+1
        PLA
        STA T0
        JSR GOTOL
        BCC DO_on_found
        JMP DO_ERR_UL
DO_on_found:
        LDA OP
        CMP #TOK_GOSUB
        BNE DO_on_goto
        LDA GRET
        CMP #8
        BCC DO_on_gosub_ok
        JMP DO_ERR_NR
DO_on_gosub_ok:
        ASL
        TAX
        LDA T2
        STA GORET,x
        LDA T2+1
        STA GORET+1,x
        INC GRET
DO_on_goto:
        JMP RUN_LINE         ; restore S and jump to target line

; =============================================================================
; DATA TABLES  (no page constraint ? placed here after main code)
; =============================================================================

; Keyword string table  (length byte, chars, NUL)
KW_TABLE:
        .DB 5,"PRINT",0
        .DB 2,"IF",0
        .DB 4,"GOTO",0
        .DB 5,"GOSUB",0
        .DB 6,"RETURN",0
        .DB 3,"RUN",0
        .DB 4,"LIST",0
        .DB 3,"NEW",0
        .DB 5,"INPUT",0
        .DB 3,"REM",0
        .DB 3,"END",0
        .DB 3,"FOR",0
        .DB 4,"NEXT",0
        .DB 4,"FREE",0
        .DB 4,"POKE",0
        .DB 4,"PEEK",0
        .DB 4,"STEP",0
        .DB 2,"TO",0
        .DB 4,"CHR$",0
        .DB 3,"ASC",0
        .DB 3,"ABS",0
        .DB 3,"USR",0
        .DB 3,"AND",0
        .DB 2,"OR",0
        .DB 3,"NOT",0
        .DB 3,"XOR",0
        .DB 3,"LET",0
        .DB 4,"THEN",0
        .DB 3,"CLS",0
        .DB 4,"HELP",0
        .DB 2,"AT",0
        .DB 2,"ON",0
        .DB 5,"INKEY",0
        .DB 4,"DATA",0
        .DB 4,"READ",0
        .DB 7,"RESTORE",0
        .DB 4,"ELSE",0
        .DB 3,"SGN",0
        .DB 3,"MOD",0
        .DB 3,"RND",0
        .DB 4,"HEX$",0       ; TOK_HEXS = $A8
        BRK
        ;.DB 0                ; end-of-table sentinel

; Statement dispatch table (used by STMT via JMP (STMT_JT,X))
; Entry order must match token values TOK_PRINT..$8E (indices 0..14)
STMT_JT:
        .DW DO_PRINT, DO_IF,   DO_GOTO, DO_GOSUB, DO_RETURN
        .DW DO_RUN,   DO_LIST, DO_NEW,  DO_INPUT,  DO_REM,   DO_END
        .DW DO_FOR,   DO_NEXT, DO_FREE, DO_POKE


;   The tokeniser copies the raw value list verbatim after TOK_DATA.
;   At runtime we just return; RUNLP's own SKIPEOL call advances past the body.
;   READ/RESTORE consume the raw bytes via DATA_PTR.  (Same pattern as DO_REM.)
;   Clobbers: ?
; =============================================================================
;        RTS

; =============================================================================
; DO_RESTORE ? RESTORE: reset DATA pointer (0 = rescan from PROG on next READ)
;   Clobbers: A
; =============================================================================
DO_RESTORE:
        STZ DATA_PTR         ; 65C02 STZ zp
        STZ DATA_PTR+1
RD_done:

DO_DATA:
        RTS

; =============================================================================
; DO_READ ? READ var [, var ...]
;   Reads the next value(s) from DATA lines into variable(s).
;
;   DATA line format in program store:
;     [lineno_lo][lineno_hi][TOK_DATA][raw ASCII: digits, commas, spaces][$0D]
;
;   DATA_PTR invariant:
;     0    reset/restored ? rescan from PROG on next READ
;     PE   exhausted ? no more DATA values exist
;     else points at current parse position INSIDE a DATA body (past TOK_DATA),
;          i.e. at a digit, comma, space, or $0D (body exhausted)
;
;   In:  IP        first token of READ statement (variable letter)
;        DATA_PTR  current position (see invariant)
;   Out: IP        advanced past consumed variable(s) and commas
;        DATA_PTR  advanced past consumed value(s)
;   Clobbers: A X Y T0 T1
; =============================================================================
DO_READ:
RD_var: JSR WPEEK_UC         ; peek at next IP token (uppercased)
        CMP #'A'
        BCC RD_sn
        CMP #'Z'+1
        BCS RD_sn
        JSR GETCI            ; consume variable letter
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var slot

        JSR RD_next_val      ; T0 = next data value; C=1 if out-of-data
        BCS RD_od

        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x

        JSR WPEEK            ; check for ', var' continuation
        CMP #','
        BNE RD_done
        JSR GETCI            ; consume ','
        BRA RD_var

RD_od:  PLA                  ; discard saved var slot
        LDA #ERR_OD
;        JMP DO_ERROR
        .BYTE $2C            ; BIT abs  ? consumes next 2 bytes as operand
RD_sn:  LDA #ERR_SN
        JMP DO_ERROR


; =============================================================================
; RD_NEXT_VAL ? find and parse the next value from DATA lines into T0
;   DATA_PTR invariant: see DO_READ header above.
;   Out: C=0  T0 = 16-bit signed value; DATA_PTR updated
;        C=1  out of data; DATA_PTR set to PE
;   Clobbers: A Y T1
; =============================================================================
RD_next_val:
        ; -- if DATA_PTR==0 (reset): start scanning from PROG ----------------
        LDA DATA_PTR
        ORA DATA_PTR+1
        BNE RD_chk_pe
        LDA #<PROG
        STA DATA_PTR
        LDA #>PROG
        STA DATA_PTR+1
        BRA RD_find          ; DATA_PTR now at first line header; find DATA

        ; -- if DATA_PTR==PE: out of data -------------------------------------
RD_chk_pe:
        LDA DATA_PTR
        CMP PE
        BNE RD_body
        LDA DATA_PTR+1
        CMP PE+1
        BEQ RD_ood

        ; -- DATA_PTR is inside a DATA body: skip separators ------------------
RD_body:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        CMP #','
        BEQ RD_sep_adv
        CMP #' '
        BEQ RD_sep_adv
        CMP #$0D
        BNE RD_parse         ; digit or '-': parse it
        ; $0D: this DATA body is exhausted ? advance past it and find next DATA
        JSR RD_adv_ptr       ; skip $0D
        ; fall through to RD_find (DATA_PTR now at next line header)

        ; -- scan from line header for next DATA line --------------------------
RD_find:
        LDA DATA_PTR
        CMP PE
        BNE RD_f_go
        LDA DATA_PTR+1
        CMP PE+1
        BEQ RD_ood           ; hit PE: no more DATA
RD_f_go:
        JSR RD_adv_ptr       ; skip lineno_lo
        JSR RD_adv_ptr       ; skip lineno_hi
        LDA (DATA_PTR)       ; first body token  (65C02 zp-indirect, no Y needed)
        CMP #TOK_DATA
        BEQ RD_found_data
        ; not DATA: scan forward to $0D then try next line
RD_skip_ln:
        LDA (DATA_PTR)       ; 65C02 zp-indirect
        CMP #$0D
        BEQ RD_skip_eol
        JSR RD_adv_ptr
        BRA RD_skip_ln
RD_skip_eol:
        JSR RD_adv_ptr       ; skip $0D ? at next line header
        BRA RD_find
RD_found_data:
        JSR RD_adv_ptr       ; skip TOK_DATA byte ? now inside body
        BRA RD_body          ; enter body (may be space/comma at start)

RD_sep_adv:
        JSR RD_adv_ptr
        BRA RD_body

        ; -- parse number at DATA_PTR -----------------------------------------
RD_parse:
        CMP #'-'
        BNE RD_pos
        JSR RD_adv_ptr       ; consume '-'
        JSR RD_uint
        LDA T0               ; negate
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
        INC T0
        BNE RD_neg_ok
        INC T0+1
RD_neg_ok:
        CLC
        RTS
RD_pos: JSR RD_uint
        CLC
        RTS
RD_ood: SEC
        RTS

; -- RD_ADV_PTR ? advance DATA_PTR by 1 ---------------------------------------
RD_adv_ptr:
        INC DATA_PTR
        BNE RD_ap_ok
        INC DATA_PTR+1
RD_ap_ok:
        RTS

; -- RD_UINT ? parse unsigned decimal at DATA_PTR into T0 ---------------------
;   Advances DATA_PTR past all consumed digit characters.
;   Clobbers: A Y T0 T1
RD_uint:
        STZ T0
        STZ T0+1
RD_u_lp:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        CMP #'0'
        BCC RD_u_done
        CMP #'9'+1
        BCS RD_u_done
        SEC
        SBC #'0'             ; digit 0-9
        PHA                  ; save digit
        ; T0 = T0*10:  save T0 in T1, shift T0 left 3 (?8), add T1*2
        LDA T0               ; copy T0 ? T1
        STA T1
        LDA T0+1
        STA T1+1
        ASL T0               ; T0 = T0*2
        ROL T0+1
        ASL T0               ; T0 = T0*4
        ROL T0+1
        ASL T0               ; T0 = T0*8
        ROL T0+1
        ASL T1               ; T1 = orig*2
        ROL T1+1
        LDA T0               ; T0 = T0*8 + T1*2 = orig*10
        CLC
        ADC T1
        STA T0
        LDA T0+1
        ADC T1+1
        STA T0+1
        PLA                  ; restore digit
        CLC
        ADC T0
        STA T0
        BCC RD_u_nc
        INC T0+1
RD_u_nc:
        JSR RD_adv_ptr
        BRA RD_u_lp
RD_u_done:
        RTS

; Two adjacent labels: DO_ERR_NR branches forward into DO_ERROR via BRA;
; DO_ERR_UL falls straight through into DO_ERROR.
; =============================================================================
DO_ERR_NR:
        LDA #ERR_NR
        BRA DO_err_entry     ; branch into DO_ERROR body  (skips TAX below)
DO_ERR_UL:
        LDA #ERR_UL
        ; *** FALL THROUGH to DO_ERROR ***

; =============================================================================
; DO_ERROR ? print error message and return to MAIN
;   In:  A    error code (ERR_xx constant = index into ERR_TABLE)
;   Out: ? (jumps to MAIN; does not return to caller)
;   Clobbers: A X T0
; =============================================================================
DO_ERROR:
DO_err_entry:
        PHA              ; save error code (survives PRNL which uses A)
        JSR PRNL         ; print CR+LF
        PLA
        TAX              ; X = error code ? ERR_TABLE index
        LDA ERR_TABLE,x  ; first char of 2-char code
        JSR PUTCH
        INX
        LDA ERR_TABLE,x      ; second char
        JSR PUTCH
   ;     LDX #>STR_ERROR          ; hi byte for PUTSTR
        LDA #<STR_ERROR
        JSR PUTSTR           ; " ERR"
        LDA RUN
        BEQ DO_err_noline
DO_break_in:                  ; IRQ handler jumps here to share " IN line\r\n" exit
   ;     LDX #>STR_IN          ; hi byte for PUTSTR
        LDA #<STR_IN
        JSR PUTSTR           ; " IN "
        LDA CURLN
        STA T0
        LDA CURLN+1
        STA T0+1
        JSR PRT16            ; line number
DO_err_noline:
        JSR PRNL
   ;     STZ RUN	; main has STZ RUN
        CLI                  ; re-enable IRQs (harmless from error path; needed from IRQ path)
        JMP MAIN

; Error code table  (pairs of ASCII chars, indexed by ERR_xx constants)
ERR_TABLE:
        .DB "SN"             ; ERR_SN  = 0
        .DB "UL"             ; ERR_UL  = 2
        .DB "OV"             ; ERR_OV  = 4
        .DB "OM"             ; ERR_OM  = 6
        .DB "NR"             ; ERR_NR  = 8
        .DB "ST"             ; ERR_ST  = 10
        .DB "UK"             ; ERR_UK  = 12
        .DB "OD"             ; ERR_OD  = 14  (out of DATA)

; =============================================================================
; GOTOL ? search program store for a line number; point IP at its body
;   In:  T0   target line number (16-bit)
;   Out: C=0  found: IP points at first token after the 2-byte header
;        C=1  not found (caller should raise ERR_UL)
;   Clobbers: A Y IP
; =============================================================================
GOTOL:
        LDA #<PROG
        STA IP
        LDA #>PROG
        STA IP+1
GT_sc:  LDA IP
        CMP PE
        BNE GT_go
        LDA IP+1
        CMP PE+1
        BEQ GT_err           ; reached end without finding it
GT_go:  LDA (IP)             ; line-number lo  (65C02 zp-indirect, no Y needed)
        CMP T0
        BNE GT_nx
        LDY #1
        LDA (IP),y           ; line-number hi
        CMP T0+1
        BEQ GT_ok
GT_nx:  LDY #2               ; skip to body, scan for $0D
GT_sk:  LDA (IP),y
        INY
        CMP #$0D
        BNE GT_sk
        TYA
        CLC
        ADC IP
        STA IP
        BCC GT_sc
        INC IP+1
        BRA GT_sc
GT_ok:  LDA IP               ; advance IP past 2-byte header
        CLC
        ADC #2
        STA IP
        BCC GT_r
        INC IP+1
GT_r:   CLC
        RTS                  ; C=0: found
GT_err: SEC
        RTS                  ; C=1: not found

; =============================================================================
; EXPRESSION EVALUATOR  ?  recursive descent, four tiers
;
;   EXPR     ? Tier 1 (lowest):  AND  OR  XOR
;   EXPR_ADD ? Tier 2:           +  -  and relational  = < > <= >= <>
;   EXPR1    ? Tier 3:           *  /
;   EXPR2    ? Tier 4 (atoms):   literals, variables, unary -, unary +, NOT, ABS, SGN, CHR$, ASC, PEEK, USR, INKEY
;
; All tiers share the same contract:
;   In:  IP   points at first token of (sub-)expression
;   Out: T0   16-bit signed result
;        IP   advanced past all consumed tokens
;   Clobbers: A X Y T1 T2  (hardware stack used for saved operands)
; =============================================================================

; =============================================================================
; EXPR ? Tier 1: AND / OR / XOR  (bitwise, lowest precedence)
; =============================================================================
EXPR:
        JSR EXPR_ADD
        JSR WPEEK
        CMP #'='
        BEQ EB_rel
        CMP #'<'
        BEQ EB_rel
        CMP #'>'
        BEQ EB_rel
        BRA EB_bool

EB_rel: JSR WPEEK            ; dispatch relational operator
        CMP #'='
        BEQ EQ_op
        CMP #'<'
        BEQ LT_op
        CMP #'>'
        JMP GT_op

EB_bool:                     ; boolean/bitwise operator loop
        JSR WPEEK
        CMP #TOK_AND
        BEQ EB_and
        CMP #TOK_OR
        BEQ EB_or
        CMP #TOK_XOR
        BEQ EB_xor
        RTS

EB_and: JSR GETCI            ; AND: bitwise and
        JSR REL_SETUP
        LDA T1
        AND T0
        STA T0
        LDA T1+1
        AND T0+1
        STA T0+1
        BRA EB_bool

EB_or:  JSR GETCI            ; OR: bitwise or
        JSR REL_SETUP
        LDA T1
        ORA T0
        STA T0
        LDA T1+1
        ORA T0+1
        STA T0+1
        BRA EB_bool

EB_xor: JSR GETCI            ; XOR: bitwise exclusive-or
        JSR REL_SETUP
        LDA T1
        EOR T0
        STA T0
        LDA T1+1
        EOR T0+1
        STA T0+1
        BRA EB_bool

; =============================================================================
; REL_SETUP ? shared prologue for relational, AND, OR, XOR operators
;   Saves left operand (T0), evaluates right operand, restores left into T1.
;   In:  T0   left operand; IP points at right-operand expression
;        (caller must have consumed the operator token before calling)
;   Out: T1   left operand;  T0   right operand
;   Clobbers: A T1 T2  (hardware stack)
; =============================================================================
REL_SETUP:
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EXPR_ADD
        PLA
        STA T1+1
        PLA
        STA T1
        RTS

; Relational operators  ?  all use REL_SETUP then compare T1 vs T0
; Result: REL_T = $FFFF (-1 / true),  REL_F = $0000 (0 / false)

EQ_op:  JSR GETCI
        JSR REL_SETUP
        LDA T1
        CMP T0
        BNE EQ_op_f
        LDA T1+1
        CMP T0+1
        BEQ REL_T
EQ_op_f:
        BRA REL_F

LT_op:  JSR GETCI
        LDA (IP)             ; peek: '<>' or '<=' ?
        CMP #'>'
        BEQ NE_op
        CMP #'='
        BEQ LE_op
        JSR REL_SETUP
        LDA T1
        SEC
        SBC T0
        LDA T1+1
        SBC T0+1
        BMI REL_T
        BRA REL_F

NE_op:  JSR GETCI
        JSR REL_SETUP
        LDA T1
        CMP T0
        BNE REL_T
        LDA T1+1
        CMP T0+1
        BNE REL_T
        BRA REL_F

LE_op:  JSR GETCI
        JSR REL_SETUP
        LDA T0
        SEC
        SBC T1
        LDA T0+1
        SBC T1+1
        BMI REL_F
        ; *** FALL THROUGH to REL_T ***

; Two adjacent labels: LE_op falls through here when T0 >= T1 (i.e. T1 <= T0 is true).
; REL_T is also the shared true-result target for all other relational ops.
REL_T:  LDA #$FF
        STA T0
        STA T0+1
        RTS

REL_F:  STZ T0
        STZ T0+1
        RTS

GT_op:  JSR GETCI
        LDA (IP)             ; peek: '>=' ?
        CMP #'='
        BEQ GE_op
        JSR REL_SETUP
        LDA T0
        SEC
        SBC T1
        LDA T0+1
        SBC T1+1
        BMI REL_T
        BRA REL_F

GE_op:  JSR GETCI
        JSR REL_SETUP
        LDA T1
        SEC
        SBC T0
        LDA T1+1
        SBC T0+1
        BMI REL_F
        BRA REL_T

; =============================================================================
; EXPR_ADD ? Tier 2: addition, subtraction  (also relational dispatch above)
; =============================================================================
EXPR_ADD:
        JSR EXPR1
EA_lp:  JSR WPEEK
        CMP #'+'
        BEQ EA_do
        CMP #'-'
        BNE EA_rts
EA_do:  PHA                  ; save operator  ('+' or '-')
        JSR GETCI            ; consume it
        LDA T0+1
        PHA                  ; push left hi
        LDA T0
        PHA                  ; push left lo
        JSR EXPR1            ; right operand -> T0
        PLA
        STA T1               ; pull left lo
        PLA
        STA T1+1             ; pull left hi
        PLA                  ; pull operator
        CMP #'-'
        BNE EA_sum
        JSR NEG16            ; subtraction: negate right then add
EA_sum: CLC
        LDA T1
        ADC T0
        STA T0
        LDA T1+1
        ADC T0+1
        STA T0+1
        BRA EA_lp
EA_rts: RTS

; =============================================================================
; EXPR1 ? Tier 3: multiply / divide  (merged sign-handling kernel)
; =============================================================================
EXPR1:
        JSR EXPR2
E1_lp:  JSR WPEEK
        CMP #'*'
        BEQ E1_md
        CMP #'/'
        BEQ E1_md
        CMP #'%'             ; % operator: MOD (remainder)
        BEQ E1_md
        CMP #TOK_MOD         ; MOD keyword: same as %
        BEQ E1_mod_kw
E1_rts: RTS                  ; not * / % MOD ? nearest RTS used as loop exit
E1_mod_kw:
        LDA #'%'             ; normalise: treat MOD token as '%' for OP save
E1_md:  STA OP               ; save operator
        JSR GETCI            ; consume it
        LDA T0               ; push left operand
        PHA
        LDA T0+1
        PHA
        JSR EXPR2            ; right operand -> T0
        PLA
        STA T1+1             ; pop left into T1  (hi first)
        PLA
        STA T1
        LDA OP
        CMP #'/'             ; zero-divisor check for / and %
        BEQ E1_divchk
        CMP #'%'
        BNE E1_nochk
E1_divchk:
        LDA T0               ; divisor zero?
        ORA T0+1
        BEQ E1_divchk_ovfl   ; zero: divide by zero error (in BEQ range: 5B ahead)
        BRA E1_nochk         ; non-zero: safe (skip inline error)
E1_divchk_ovfl:              ; inline ovfl stub ? reachable by BEQ above
        LDA #ERR_OV
        JMP DO_ERROR
E1_nochk:
        LDA T1+1
        EOR T0+1
        PHA                  ; push result sign  (XOR of sign bits)
        LDA T1+1             ; make T1 (left) positive
        BPL E1_p1
        JSR NEG_T1
E1_p1:  LDA T0+1             ; make T0 (right) positive
        BPL E1_p2
        JSR NEG16
E1_p2:  STZ T2               ; clear accumulator
        STZ T2+1
        LDY #16              ; 16-bit iteration count

        LDA OP
        CMP #'*'
        BEQ E1_mul_mb        ; '*' -> multiply
        BRA E1_div_kern      ; '/' or '%' -> divide (remainder also computed)

        ; ---- MUL kernel: T2 = |T1| * |T0|  (shift-and-add) ----
E1_mul_mb:
        LSR T1+1
        ROR T1
        BCC E1_mul_ms
        CLC
        LDA T2
        ADC T0
        STA T2
        LDA T2+1
        ADC T0+1
        STA T2+1
E1_mul_ms:
        ASL T0
        ROL T0+1
        DEY
        BNE E1_mul_mb
        LDA T2               ; result -> T0
        STA T0
        LDA T2+1
        STA T0+1
        BRA E1_sign

        ; ---- DIV kernel: T1 = |T1| / |T0|, remainder in T2  ----
E1_div_kern:
E1_div_db:
        ASL T1
        ROL T1+1
        ROL T2
        ROL T2+1
        LDA T2
        SEC
        SBC T0
        TAX
        LDA T2+1
        SBC T0+1
        BCC E1_div_ds
        STX T2
        STA T2+1
        INC T1
E1_div_ds:
        DEY
        BNE E1_div_db
        LDA OP               ; MOD: result is remainder (T2), not quotient (T1)
        CMP #'%'
        BEQ E1_mod_result
        LDA T1               ; quotient -> T0
        STA T0
        LDA T1+1
        STA T0+1
        BRA E1_sign
E1_mod_result:
        LDA T2               ; remainder -> T0
        STA T0
        LDA T2+1
        STA T0+1
        ; *** FALL THROUGH to E1_SIGN ***

        ; ---- shared sign postamble ----
E1_sign:
        PLA                  ; pull saved sign byte
        BPL E1_pos
        JSR NEG16            ; result should be negative
E1_pos: JMP E1_lp            ; tail jump to loop  (saves 1 RTS)

; =============================================================================
; EXPR2 ? Tier 4: atoms, unary operators, and functions
;   Handles: literals, variables, (expr), unary -, unary +, NOT, ABS, SGN,
;            CHR$, ASC, PEEK, USR, INKEY

; =============================================================================
; E2_RND ? RND: advance LFSR and return pseudo-random value 1..32767
;   No argument ? used as atom: R = RND  or  PRINT RND MOD 6 + 1
;   Algorithm: 16-bit Galois LFSR, taps $B400, period 65535 (never zero).
;   Seed at RND_SEED ($BE-$BF), initialised to $ACE1 by INIT.
;   Result is always positive (bit 15 cleared before return) ? 1..32767.
;   Clobbers: A T0
; =============================================================================
E2_rnd: JSR GETCI            ; consume RND token
        ; Advance LFSR: shift right 1; if bit fell out, XOR with $B400
        LDA RND_SEED
        LSR RND_SEED+1       ; shift hi byte right, MSB = 0
        ROR RND_SEED         ; shift lo byte right, MSB = old hi bit 0
        BCC E2_rnd_done      ; no feedback needed
        LDA RND_SEED+1
        EOR #$B4             ; apply feedback taps (x^16+x^14+x^13+x^11+1)
        STA RND_SEED+1
        ; lo byte tap is $00 so no EOR needed
E2_rnd_done:
        LDA RND_SEED
        STA T0
        LDA RND_SEED+1
        AND #$7F             ; force positive (clear bit 15) ? 1..32767
        STA T0+1
        RTS

; =============================================================================
; E2_INKEY ? INKEY: non-blocking keyboard poll  ?  char code, or 0 if no key
;   Clobbers: A T0
; =============================================================================
E2_inkey:
        JSR GETCI            ; consume INKEY token
        LDA IO_GETCH         ; non-blocking poll ($E004); 0 = no key
        STA T0
        STZ T0+1
        RTS

; =============================================================================
; E2_USR ? USR(addr): call machine-code subroutine at addr
;   On entry: A = T0 lo byte (low byte of last expression, for parameter passing)
;   Out: T0  (caller sets this before RETURN if returning a value)
;   Clobbers: A X Y (and anything the called routine touches)
; =============================================================================
E2_usr: JSR GETCI            ; consume USR token
        JSR EAT_EXPR
        JSR WEAT             ; consume ')'
       ; JMP USR_THUNK        ; tail call
	; fall through
; =============================================================================
; USR_THUNK ? indirect call to user machine-code routine via T0
;   In:  T0   16-bit address of user routine
;   Out: whatever the user routine returns (typically in T0)
;   Clobbers: A X Y (and anything the user routine touches)
; =============================================================================
USR_THUNK:
        JMP (T0)

; =============================================================================
; E2_SGN ? SGN(n): sign of n  ?  -1 (negative), 0 (zero), 1 (positive)
;   Clobbers: A T0
; =============================================================================
; =============================================================================
; E2_SGN ? SGN(n): sign of n  ?  -1 (negative), 0 (zero), 1 (positive)
;   In:  IP  points at SGN token
;   Out: T0  = -1, 0, or 1  (16-bit signed)
;        IP  advanced past SGN(expr)
;   Clobbers: A T0
; =============================================================================
E2_sgn: JSR GETCI            ; consume SGN token
        JSR EAT_EXPR         ; evaluate argument -> T0, consume '(' first
        JSR WEAT             ; consume closing ')'
        LDA T0
        ORA T0+1
        BEQ E2_sgn_zero      ; T0 == 0: return 0 (T0 already zero)
        LDA T0+1
        BMI E2_sgn_neg       ; hi byte negative: return -1
        LDA #1               ; positive: return 1
        STA T0               ;   T0 lo = 1
        STZ T0+1             ;   T0 hi = 0
        RTS
E2_sgn_neg:
        LDA #$FF             ; -1: both bytes $FF
        STA T0
        STA T0+1
E2_sgn_zero:
        RTS                  ; T0 already 0 from BEQ path

; =============================================================================
EXPR2:
        JSR WPEEK
        CMP #'('
        BEQ E2_par
        CMP #'-'
        BEQ E2_neg
        CMP #'+'
        BEQ E2_pos
        CMP #TOK_NOT
        BEQ E2_not
        CMP #TOK_NUM
        BEQ E2_num
; --- function tokens: check in reverse handler-placement order so closest handler = last checked ---
        CMP #TOK_RND
        BEQ E2_rnd
        CMP #TOK_INKEY
        BEQ E2_inkey
        CMP #TOK_USR
        BEQ E2_usr
        CMP #TOK_SGN
        BEQ E2_sgn
        CMP #TOK_ABS
        BEQ E2_abs
; --- remaining tokens: handlers too far for BEQ, use BNE/JMP ---
        CMP #TOK_PEEK
        BNE EXPR2_t1
        JMP E2_peek
EXPR2_t1:
        CMP #TOK_CHRS
        BNE EXPR2_t2
        JMP E2_chrs
EXPR2_t2:
        CMP #TOK_ASC
        BNE EXPR2_tvar_jmp
        JMP E2_asc
EXPR2_tvar_jmp:
        BRA EXPR2_tvar       ; not a function token: try as variable

; --- atom handlers (placed here so preamble BEQs above are in range) ---
E2_par: JSR GETCI            ; ( expr )
        JSR EXPR
        JMP WEAT             ; consume ')' and return  (tail call)

E2_neg: JSR GETCI            ; unary minus
        JSR EXPR2
        JMP NEG16            ; tail call

E2_pos: JSR GETCI            ; unary plus: no-op
        BRA EXPR2            ; tail call

E2_not: JSR GETCI            ; NOT: bitwise complement
        JSR EXPR2
        LDA T0
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
        RTS

E2_num: JMP PNUM             ; $FF lo hi inline number  (tail call)

E2_bad: STZ T0               ; unrecognised atom: return 0
        STZ T0+1
E2_abs_pos:
        RTS

; =============================================================================
; E2_ABS ? ABS(n): absolute value of n  ?  n if n=0, else -n
;   Clobbers: A T0
; =============================================================================
E2_abs: JSR GETCI            ; ABS(n)
        JSR EAT_EXPR
        JSR WEAT             ; consume ')'
        LDA T0+1
        BPL E2_abs_pos
        JMP NEG16            ; tail call: negate if negative
;        RTS

; =============================================================================
; EXPR2_tvar ? variable or unrecognised atom (BRA from dispatch above)
; =============================================================================
EXPR2_tvar:
        JSR UC
        CMP #'A'
        BCC E2_bad
        CMP #'Z'+1
        BCS E2_bad
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; x2: byte offset into VARS
        TAX
        LDA VARS,x
        STA T0
        LDA VARS+1,x
        STA T0+1
        RTS

; =============================================================================
; E2_PEEK ? PEEK(addr): read one byte from memory address  ?  0..255
;   Clobbers: A T0
; =============================================================================
E2_peek:
        JSR GETCI            ; PEEK(addr)
        JSR EAT_EXPR
        JSR WEAT             ; consume ')'
        LDA (T0)             ; 65C02 zp-indirect: read memory at addr
        STA T0
        STZ T0+1
        RTS

; =============================================================================
; E2_CHRS ? CHR$(n): numeric ASCII code to character value for PRINT
;   Returns n unchanged in T0; PRINT emits it directly via PUTCH.
;   Clobbers: A T0
; =============================================================================
E2_chrs:
        JSR GETCI            ; CHR$(n): result is just n (char value)
        JSR EAT_EXPR
        JMP WEAT             ; consume ')' and return  (tail call)

; =============================================================================
; E2_ASC ? ASC("str") or ASC(n): ASCII code of first character
;   String form: ASC("X") ? ASCII value of X.
;   Numeric form: ASC(n) ? n unchanged (identity, for symmetry with CHR$).
;   Clobbers: A T0
; =============================================================================
E2_asc: JSR GETCI            ; ASC("str") or ASC(n)
        JSR WEAT             ; consume '('
        JSR WPEEK
        CMP #'"'
        BNE E2_asc_num
        JSR GETCI            ; consume '"'
        JSR GETCI            ; first char -> A
        STA T0
        STZ T0+1
E2_asc_sk:
        LDA (IP)             ; peek: closing '"' or CR ?
        CMP #'"'
        BEQ E2_asc_dn
        CMP #$0D
        BEQ E2_asc_dn
        JSR GETCI
        BRA E2_asc_sk
E2_asc_dn:
        JSR GETCI            ; consume closing '"' or CR
        JMP WEAT             ; consume ')' and return  (tail call)
E2_asc_num:
        JSR EXPR
        JMP WEAT             ; consume ')' and return  (tail call)

; =============================================================================
; DO_LET ? LET var = expr  (or implicit assignment without LET keyword)
;   In:  IP   points at optional TOK_LET, then variable, '=', expression
;   Out: VARS[slot] updated
;        IP   advanced past assignment
;   Clobbers: A X T0 T1 T2
; =============================================================================
DO_LET:
        JSR WPEEK
        CMP #TOK_LET
        BNE DO_let_var
        JSR GETCI            ; consume optional LET keyword
DO_let_var:
        JSR WPEEK_UC
        CMP #'A'
        BCC DO_let_dn
        CMP #'Z'+1
        BCS DO_let_dn
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        ASL
        PHA                  ; save var slot
        JSR WPEEK
        CMP #'='
        BNE DO_let_pop
        JSR GETCI            ; consume '='
        JSR EXPR
        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
        RTS
        
DO_let_pop:
        PLA
        LDA #ERR_UK
        JMP DO_ERROR
DO_let_dn:
        RTS
        
; =============================================================================
; PRT_HEX  -  print T0 as 4-digit uppercase hexadecimal  (used by HEX$)
;
;   In:  T0  = 16-bit value
;   Out: 4 hex digits printed (e.g. T0=$FF -> "00FF")
;   Clobbers: A X Y
; =============================================================================
PRT_HEX:
    LDA T0+1        ; High byte
    JSR PH_byte
    LDA T0          ; Low byte (fall through)

PH_byte:
    PHA             ; Save byte
    LSR            ; High nibble to low
    LSR 
    LSR 
    LSR 
    JSR PH_nib      ; Process high nibble
    PLA             ; Restore for low nibble (fall through)

PH_nib:
    AND #$0F        ; Isolate nibble
    SED             ; <--- Set Decimal Mode (1 byte)
    CMP #$0A        ; <--- Set Carry if A >= 10 (2 bytes)
    ADC #$30        ; <--- The Magic Add (2 bytes)
    CLD             ; <--- Clear Decimal Mode (1 byte)
    BRA PUTCH       ; Tail call (2 bytes)

; =============================================================================
; PRT16  -  print T0 as a signed decimal integer
;
;   In:  T0 = signed 16-bit value
;   Out: decimal digits printed to terminal; T0 destroyed
;   Clobbers: A Y T0
;
;   Algorithm: 16-bit shift-and-subtract BCD extraction; recursive so digits
;   print highest-first without a digit buffer.
;   Falls through into PUTCH to print the final (lowest) digit.
;   Negative values: prints '-' then negates T0 before proceeding.
; =============================================================================
PRT16:
         ; BBR7 T0+1, PRT16GO  -- branch if bit 7 of T0+1 is clear (positive)
         ; Kowalski does not assemble BBR natively, so encoded as raw bytes:
         .DB $7F, T0+1, PRT16GO-*-1
         LDA #'-'
         JSR PUTCH
         JSR NEG16
PRT16GO:
         LDY #16
         LDA #0
PRT16DIV:
         ASL T0
         ROL T0+1
         ROL                  ; shift MSB of T0 into remainder (in A)
         CMP #10
         BCC PRT16SKP
         SBC #10              ; remainder >= 10: subtract and set quotient bit
         INC T0
PRT16SKP:
         DEY
         BNE PRT16DIV
         PHA                  ; push remainder digit
         LDA T0
         ORA T0+1
         BEQ PRT16PRNT        ; quotient zero: this is the most-significant digit
         JSR PRT16GO          ; recurse to print more-significant digits first
PRT16PRNT:
         PLA
         ORA #'0'             ; convert 0-9 to '0'-'9'
;         jmp PUTCH
; PUTCH ? character output  (PRNL drops through here for the LF)
;   In:  A    character to send
;   Out: ?
;   Clobbers: ?
PUTCH:  STA IO_PUTCH
        RTS

; =============================================================================
; NEG_T1 / NEG16 ? two's-complement negate T1 or T0  (BIT-trick deduplication)
;   NEG_T1: negate T1  (16-bit)
;   NEG16:  negate T0  (16-bit)
;   In:  T0 or T1  value to negate
;   Out: same location holds 0 - original_value
;   Clobbers: A X
;   Trick: NEG_T1 loads X=2 (offset to T1), then .BYTE $2C skips the
;   next 2 bytes (BIT absolute opcode); NEG16 loads X=0 (offset to T0).
;   Both paths execute the same negate body using T0,X / T0+1,X addressing.
; =============================================================================
NEG_T1:
        LDX #2               ; X=2: address offset to T1 from T0
        .BYTE $2C            ; BIT abs  ? consumes next 2 bytes as operand
NEG16:
        LDX #0               ; X=0: address offset to T0
        LDA #0
        SEC
        SBC T0,x
        STA T0,x
        LDA #0
        SBC T0+1,x
        STA T0+1,x
        RTS

; =============================================================================
; PEEKC ? read byte at IP without advancing IP
;   In:  IP   token stream pointer
;   Out: A    byte at (IP)
;   Clobbers: ?
; -----------------------------------------------------------------------------
; GETCI ? read byte at IP and advance IP by one
;   In:  IP   token stream pointer
;   Out: A    byte that was at (IP);  IP  incremented
;   Clobbers: ?
; -----------------------------------------------------------------------------
; UC ? convert A to uppercase if it is a lowercase ASCII letter
;   In:  A    any byte
;   Out: A    uppercased (a-z ? A-Z); all other bytes unchanged
;   Clobbers: ?  (flags are affected)
; =============================================================================
; (PEEKC inlined as LDA (IP) at all call sites)
GETCI:  LDA (IP)             ; 65C02 zp-indirect: fetch byte at IP, then advance
;        JMP INCIP            ; advance IP (16-bit) and return  (tail call)
	; drop through

; INCIP ? increment IP (16-bit pointer) by 1
;   In:  ?   Out: ?   Clobbers: ?
INCIP:  INC IP
        BNE INCIP_ok
        INC IP+1
INCIP_ok:
        RTS

WPEEK_UC:
        JSR WPEEK
;        BRA UC               ; tail call

UC:     CMP #'a'
        BCC UC_d
        CMP #'z'+1
        BCS UC_d
        AND #$DF
WPEEK_d:
SKIPEOL_d:
UC_d:   RTS

; =============================================================================
; WPEEK ? skip whitespace, peek at next non-space byte (do not consume it)
;   In:  IP   token stream pointer
;   Out: A    first non-space byte at or after (IP);  IP  unchanged
;   Clobbers: ?
; =============================================================================
WPEEK:  LDA (IP)             ; 65C02: PEEKC inlined for speed
        CMP #' '
        BNE WPEEK_d
        JSR GETCI
        BRA WPEEK
;        RTS

; =============================================================================
; WEAT ? skip whitespace, consume (eat) the next byte
;   In:  IP   token stream pointer
;   Out: A    the consumed byte;  IP  advanced one past the first non-space
;   Clobbers: ?
; -----------------------------------------------------------------------------
; EAT_EXPR ? skip whitespace, consume one byte, then evaluate an expression
;   Convenience wrapper: WEAT then EXPR.
;   In:  IP   points at optional whitespace then expression
;   Out: T0   expression result;  IP  advanced past expression
;   Clobbers: A X Y T1 T2
; -----------------------------------------------------------------------------
; WPEEK_UC ? skip whitespace, peek next byte, uppercase it
;   In:  IP   token stream pointer
;   Out: A    first non-space byte, uppercased;  IP  unchanged
;   Clobbers: ?
; -----------------------------------------------------------------------------
; SKIPEOL ? advance IP past the $0D end-of-line marker
;   In:  IP   anywhere in the current token stream line
;   Out: IP   points at first byte of the next line
;   Clobbers: A
; =============================================================================
WEAT:   JSR WPEEK
        BRA GETCI            ; consume the non-space byte and return  (tail call)

EAT_EXPR:
        JSR WEAT
        JMP EXPR             ; tail call

SKIPEOL:
        JSR GETCI
        CMP #$0D
        BEQ SKIPEOL_d
        BRA SKIPEOL
; SKIPEOL_d:
 ;       RTS

; =============================================================================
; I/O stubs ? Kowalski simulator virtual terminal
; =============================================================================

; GETCH ? blocking character input
;   In:  ?
;   Out: A    character received
;   Clobbers: ?
GETCH:  LDA IO_GETCH         ; poll Kowalski virtual port
        BEQ GETCH             ; 0 = no char yet: spin
        RTS

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;
;   Triggered by: write any value to IO_IRQ ($E007) in the simulator.
;
;   If RUN != 0  (program is executing):
;       Clear RUN, GRET, FSTK; restore stack to RUNSP; print BREAK; -> MAIN.
;       Program store is left intact -- the user can LIST or re-RUN.
;   If RUN == 0  (idle at prompt): silently ignored (RTI).
;
;   Called via hardware IRQ: CPU has already pushed PC-hi, PC-lo, P onto stack
;   and cleared the I flag.  We must not use RTS/JMP back -- either RTI (idle)
;   or we restore the stack ourselves and JMP MAIN (running).
;
;   Clobbers: A X  (stack is being deliberately abandoned when running)
; =============================================================================
IRQ_HANDLER:
        LDA RUN              ; running?
        BEQ IRQ_idle         ; no: ignore
  ;      STZ RUN              ; clear run flag - jump to main has this
	    CLD             ; just in case in prt_hex, Clear Decimal Mode 

        STZ GRET             ; clear GOSUB nesting depth
        STZ FSTK             ; clear FOR nesting depth
        LDX RUNSP            ; restore stack pointer (unwinds all call frames)
        TXS
     ;   LDX #>STR_BREAK      ; print "\r\nBREAK"
        LDA #<STR_BREAK
        JSR PUTSTR           ; "\r\nBREAK" (no trailing CRLF -- shared exit provides it)
        JMP DO_break_in      ; -> print " IN line\r\n", re-enable IRQs, back to MAIN
IRQ_idle:
        RTI                  ; idle: silently ignore

; =============================================================================
; PRE-LOADED FEATURE SHOWCASE  (program storage at $0200)
;
; Demonstrates every statement and function in 4K BASIC v11:
;   PRINT / CHR$ / ASC / REM / ABS / SGN / MOD / NOT / AND / OR / XOR / RND
;   PEEK / POKE / DATA / READ / RESTORE
;   FOR / NEXT / STEP (including negative step)
;   IF / THEN / ELSE / GOSUB / RETURN / ON n GOSUB
;   Mandelbrot set renderer (validates expression evaluator, nested FOR, GOTO)
;
; Mandelbrot: fixed-point integer arithmetic.
;   Real axis C: -128..16 step 4  (37 columns)
;   Imag axis I:  -64..56 step 6  (21 rows)
;   Max 16 iterations; CHR$(E+32) for escaped pixels, space inside.
;   Called as a GOSUB at line 600; uses IF/THEN/ELSE for pixel output.
;
; -- TO RUN WITHOUT PRE-LOADED PROGRAM (real ROM / no Kowalski) --------------
;   When burning to a 2732 EPROM for real hardware, replace the two lines in
;   INIT that load the showcase end address with the program storage base:
;
;     Change:   LDA #<SHOWCASE_END   ?   LDA #<PROG   ($00)
;               LDA #>SHOWCASE_END   ?   LDA #>PROG   ($02)
;
;   This sets PE = PROG = $0200 on cold start, meaning the interpreter starts
;   with an empty program.  Type NEW (redundant but harmless) then enter your
;   own program, or load it via USR() from external storage.
;
;   The SHOWCASE_END label and the .DB block below can then be deleted to save
;   the ~1275 bytes they occupy (though they do not affect ROM ? they assemble
;   into RAM at $0200 and are only initialised at simulator startup).
; =============================================================================
        .ORG $0200
        .DB $0A,$00,$89,$20,$34,$4B,$20,$42,$41,$53,$49,$43,$20,$76,$31,$31,$20,$2D,$20,$46,$45,$41,$54,$55,$52,$45,$20,$53,$48,$4F,$57,$43,$41,$53,$45,$0D  ; 10 REM 4K BASIC v11 - FEATURE SHOWCASE
        .DB $14,$00,$89,$20,$2D,$2D,$2D,$20,$50,$52,$49,$4E,$54,$20,$2F,$20,$43,$48,$52,$24,$20,$2F,$20,$41,$53,$43,$20,$2D,$2D,$2D,$0D  ; 20 REM --- PRINT / CHR$ / ASC ---
        .DB $1E,$00,$80,$92,$28,$FF,$3D,$00,$29,$3B,$92,$28,$FF,$3D,$00,$29,$3B,$22,$20,$34,$4B,$20,$42,$41,$53,$49,$43,$20,$53,$48,$4F,$57,$43,$41,$53,$45,$20,$22,$3B,$92,$28,$FF,$3D,$00,$29,$3B,$92,$28,$FF,$3D,$00,$29,$0D  ; 30 PRINT CHR$(61);CHR$(61);" 4K BASIC SHOWCASE ";CHR$(61);CHR$(61)
        .DB $28,$00,$80,$22,$43,$48,$52,$24,$28,$36,$35,$29,$3D,$22,$3B,$92,$28,$FF,$41,$00,$29,$3B,$22,$20,$20,$41,$53,$43,$28,$41,$29,$3D,$22,$3B,$93,$28,$22,$41,$22,$29,$0D  ; 40 PRINT "CHR$(65)=";CHR$(65);"  ASC(A)=";ASC("A")
        .DB $32,$00,$89,$20,$2D,$2D,$2D,$20,$41,$42,$53,$20,$2F,$20,$53,$47,$4E,$20,$2F,$20,$4D,$4F,$44,$20,$2D,$2D,$2D,$0D  ; 50 REM --- ABS / SGN / MOD ---
        .DB $3C,$00,$80,$22,$41,$42,$53,$28,$2D,$37,$29,$3D,$22,$3B,$94,$28,$2D,$FF,$07,$00,$29,$3B,$22,$20,$20,$53,$47,$4E,$28,$2D,$35,$29,$3D,$22,$3B,$A5,$28,$2D,$FF,$05,$00,$29,$3B,$22,$20,$20,$53,$47,$4E,$28,$30,$29,$3D,$22,$3B,$A5,$28,$FF,$00,$00,$29,$0D  ; 60 PRINT "ABS(-7)=";ABS(-7);"  SGN(-5)=";SGN(-5);"  SGN(0)=";SGN(0)
        .DB $46,$00,$80,$22,$31,$37,$20,$4D,$4F,$44,$20,$35,$3D,$22,$3B,$FF,$11,$00,$A6,$FF,$05,$00,$3B,$22,$20,$20,$41,$42,$53,$28,$33,$29,$3D,$22,$3B,$94,$28,$FF,$03,$00,$29,$0D  ; 70 PRINT "17 MOD 5=";17 MOD 5;"  ABS(3)=";ABS(3)
        .DB $50,$00,$89,$20,$2D,$2D,$2D,$20,$4E,$4F,$54,$20,$2F,$20,$41,$4E,$44,$20,$2F,$20,$4F,$52,$20,$2F,$20,$58,$4F,$52,$20,$2D,$2D,$2D,$0D  ; 80 REM --- NOT / AND / OR / XOR ---
        .DB $5A,$00,$80,$22,$4E,$4F,$54,$20,$30,$3D,$22,$3B,$98,$FF,$00,$00,$3B,$22,$20,$20,$36,$20,$41,$4E,$44,$20,$33,$3D,$22,$3B,$FF,$06,$00,$96,$FF,$03,$00,$0D  ; 90 PRINT "NOT 0=";NOT 0;"  6 AND 3=";6 AND 3
        .DB $64,$00,$80,$22,$35,$20,$4F,$52,$20,$32,$3D,$22,$3B,$FF,$05,$00,$97,$FF,$02,$00,$3B,$22,$20,$20,$37,$20,$58,$4F,$52,$20,$33,$3D,$22,$3B,$FF,$07,$00,$99,$FF,$03,$00,$0D  ; 100 PRINT "5 OR 2=";5 OR 2;"  7 XOR 3=";7 XOR 3
        .DB $6E,$00,$89,$20,$2D,$2D,$2D,$20,$52,$4E,$44,$20,$28,$47,$61,$6C,$6F,$69,$73,$20,$4C,$46,$53,$52,$2C,$20,$73,$65,$65,$64,$3D,$24,$41,$43,$45,$31,$29,$20,$2D,$2D,$2D,$0D  ; 110 REM --- RND (Galois LFSR, seed=$ACE1) ---
        .DB $78,$00,$80,$22,$52,$4E,$44,$3D,$22,$3B,$A7,$3B,$22,$20,$20,$52,$4E,$44,$20,$4D,$4F,$44,$20,$31,$30,$3D,$22,$3B,$A7,$A6,$FF,$0A,$00,$0D  ; 120 PRINT "RND=";RND;"  RND MOD 10=";RND MOD 10
        .DB $82,$00,$89,$20,$2D,$2D,$2D,$20,$50,$45,$45,$4B,$20,$2F,$20,$50,$4F,$4B,$45,$20,$2D,$2D,$2D,$0D  ; 130 REM --- PEEK / POKE ---
        .DB $8C,$00,$8E,$FF,$00,$02,$2C,$FF,$2A,$00,$0D  ; 140 POKE 512,42
        .DB $96,$00,$80,$22,$50,$4F,$4B,$45,$20,$35,$31,$32,$2C,$34,$32,$20,$20,$50,$45,$45,$4B,$3D,$22,$3B,$8F,$28,$FF,$00,$02,$29,$0D  ; 150 PRINT "POKE 512,42  PEEK=";PEEK(512)
        .DB $A0,$00,$89,$20,$2D,$2D,$2D,$20,$44,$41,$54,$41,$20,$2F,$20,$52,$45,$41,$44,$20,$2F,$20,$52,$45,$53,$54,$4F,$52,$45,$20,$2D,$2D,$2D,$0D  ; 160 REM --- DATA / READ / RESTORE ---
        .DB $AA,$00,$A2,$41,$3A,$A2,$42,$3A,$A2,$43,$0D  ; 170 READ A:READ B:READ C
        .DB $B4,$00,$80,$22,$44,$41,$54,$41,$3A,$20,$22,$3B,$41,$3B,$22,$2C,$22,$3B,$42,$3B,$22,$2C,$22,$3B,$43,$0D  ; 180 PRINT "DATA: ";A;",";B;",";C
        .DB $BE,$00,$A3,$0D  ; 190 RESTORE
        .DB $C8,$00,$A2,$41,$0D  ; 200 READ A
        .DB $D2,$00,$80,$22,$52,$45,$53,$54,$4F,$52,$45,$2D,$3E,$41,$3D,$22,$3B,$41,$0D  ; 210 PRINT "RESTORE->A=";A
        .DB $DC,$00,$A1,$20,$31,$31,$31,$2C,$32,$32,$32,$2C,$33,$33,$33,$0D  ; 220 DATA 111,222,333
        .DB $E6,$00,$89,$20,$2D,$2D,$2D,$20,$46,$4F,$52,$20,$2F,$20,$4E,$45,$58,$54,$20,$2F,$20,$53,$54,$45,$50,$20,$2D,$2D,$2D,$0D  ; 230 REM --- FOR / NEXT / STEP ---
        .DB $F0,$00,$8B,$49,$3D,$FF,$01,$00,$91,$FF,$05,$00,$0D  ; 240 FOR I=1 TO 5
        .DB $FA,$00,$80,$49,$3B,$0D  ; 250 PRINT I;
        .DB $04,$01,$8C,$49,$0D  ; 260 NEXT I
        .DB $0E,$01,$80,$22,$22,$0D  ; 270 PRINT ""
        .DB $18,$01,$8B,$49,$3D,$FF,$0A,$00,$91,$FF,$01,$00,$90,$2D,$FF,$03,$00,$0D  ; 280 FOR I=10 TO 1 STEP -3
        .DB $22,$01,$80,$49,$3B,$0D  ; 290 PRINT I;
        .DB $2C,$01,$8C,$49,$0D  ; 300 NEXT I
        .DB $36,$01,$80,$22,$22,$0D  ; 310 PRINT ""
        .DB $40,$01,$89,$20,$2D,$2D,$2D,$20,$49,$46,$20,$2F,$20,$54,$48,$45,$4E,$20,$2F,$20,$45,$4C,$53,$45,$20,$2D,$2D,$2D,$0D  ; 320 REM --- IF / THEN / ELSE ---
        .DB $4A,$01,$81,$FF,$03,$00,$3E,$FF,$01,$00,$80,$22,$49,$46,$20,$74,$72,$75,$65,$22,$0D  ; 330 IF 3>1 THEN PRINT "IF true"
        .DB $54,$01,$81,$FF,$01,$00,$3E,$FF,$03,$00,$80,$22,$57,$52,$4F,$4E,$47,$22,$A4,$80,$22,$45,$4C,$53,$45,$20,$6F,$6B,$22,$0D  ; 340 IF 1>3 THEN PRINT "WRONG" ELSE PRINT "ELSE ok"
        .DB $5E,$01,$89,$20,$2D,$2D,$2D,$20,$47,$4F,$53,$55,$42,$20,$2F,$20,$52,$45,$54,$55,$52,$4E,$20,$2D,$2D,$2D,$0D  ; 350 REM --- GOSUB / RETURN ---
        .DB $68,$01,$83,$FF,$F4,$01,$0D  ; 360 GOSUB 500
        .DB $72,$01,$89,$20,$2D,$2D,$2D,$20,$4F,$4E,$20,$6E,$20,$47,$4F,$53,$55,$42,$20,$2D,$2D,$2D,$0D  ; 370 REM --- ON n GOSUB ---
        .DB $7C,$01,$8B,$4B,$3D,$FF,$01,$00,$91,$FF,$03,$00,$0D  ; 380 FOR K=1 TO 3
        .DB $86,$01,$9F,$4B,$83,$FF,$FE,$01,$2C,$FF,$08,$02,$2C,$FF,$12,$02,$0D  ; 390 ON K GOSUB 510,520,530
        .DB $90,$01,$8C,$4B,$0D  ; 400 NEXT K
        .DB $9A,$01,$89,$20,$2D,$2D,$2D,$20,$4D,$61,$6E,$64,$65,$6C,$62,$72,$6F,$74,$20,$2D,$2D,$2D,$0D  ; 410 REM --- Mandelbrot (inline via GOTO) ---
        .DB $A4,$01,$80,$92,$28,$FF,$3D,$00,$29,$3B,$92,$28,$FF,$3D,$00,$29,$3B,$22,$20,$4D,$41,$4E,$44,$45,$4C,$42,$52,$4F,$54,$20,$22,$3B,$92,$28,$FF,$3D,$00,$29,$3B,$92,$28,$FF,$3D,$00,$29,$0D  ; 420 PRINT CHR$(61);CHR$(61);" MANDELBROT ";CHR$(61);CHR$(61)
        .DB $AE,$01,$82,$FF,$58,$02,$0D  ; 430 GOTO 600
        .DB $B8,$01,$8A,$0D  ; 440 END (not reached)
        .DB $F4,$01,$80,$22,$47,$4F,$53,$55,$42,$20,$6F,$6B,$22,$3A,$84,$0D  ; 500 PRINT "GOSUB ok":RETURN
        .DB $FE,$01,$80,$22,$4F,$4E,$20,$31,$22,$3A,$84,$0D  ; 510 PRINT "ON 1":RETURN
        .DB $08,$02,$80,$22,$4F,$4E,$20,$32,$22,$3A,$84,$0D  ; 520 PRINT "ON 2":RETURN
        .DB $12,$02,$80,$22,$4F,$4E,$20,$33,$22,$3A,$84,$0D  ; 530 PRINT "ON 3":RETURN
        .DB $58,$02,$8B,$49,$3D,$2D,$FF,$40,$00,$91,$FF,$38,$00,$90,$FF,$06,$00,$0D  ; 600 FOR I=-64 TO 56 STEP 6
        .DB $62,$02,$44,$3D,$49,$0D  ; 610 D=I
        .DB $6C,$02,$8B,$43,$3D,$2D,$FF,$80,$00,$91,$FF,$10,$00,$90,$FF,$04,$00,$0D  ; 620 FOR C=-128 TO 16 STEP 4
        .DB $76,$02,$41,$3D,$43,$3A,$42,$3D,$44,$3A,$45,$3D,$FF,$00,$00,$0D  ; 630 A=C:B=D:E=0
        .DB $80,$02,$8B,$4E,$3D,$FF,$01,$00,$91,$FF,$10,$00,$0D  ; 640 FOR N=1 TO 16
        .DB $8A,$02,$81,$45,$3E,$FF,$00,$00,$82,$FF,$A8,$02,$0D  ; 650 IF E>0 THEN GOTO 680
        .DB $94,$02,$54,$3D,$41,$2A,$41,$2F,$FF,$40,$00,$2D,$42,$2A,$42,$2F,$FF,$40,$00,$2B,$43,$0D  ; 660 T=A*A/64-B*B/64+C
        .DB $9E,$02,$42,$3D,$FF,$02,$00,$2A,$41,$2A,$42,$2F,$FF,$40,$00,$2B,$44,$3A,$41,$3D,$54,$0D  ; 670 B=2*A*B/64+D:A=T
        .DB $A8,$02,$81,$45,$3D,$FF,$00,$00,$81,$41,$2A,$41,$2F,$FF,$40,$00,$2B,$42,$2A,$42,$2F,$FF,$40,$00,$3E,$FF,$00,$01,$45,$3D,$4E,$0D  ; 680 IF E=0 THEN IF A*A/64+B*B/64>256 THEN E=N
        .DB $B2,$02,$8C,$4E,$0D  ; 690 NEXT N
        .DB $BC,$02,$81,$45,$3E,$FF,$00,$00,$80,$92,$28,$45,$2B,$FF,$20,$00,$29,$3B,$A4,$80,$92,$28,$FF,$20,$00,$29,$3B,$0D  ; 700 IF E>0 THEN PRINT CHR$(E+32); ELSE PRINT CHR$(32);
        .DB $C6,$02,$8C,$43,$0D  ; 710 NEXT C
        .DB $D0,$02,$80,$22,$22,$0D  ; 720 PRINT ""
        .DB $DA,$02,$8C,$49,$0D  ; 730 NEXT I
        .DB $E4,$02,$8A,$0D  ; 740 END
SHOWCASE_END:               ; INIT sets PE to this address ($06FB)

; =============================================================================
        .opt proc65c02
        .ORG $FFFC
        .DW INIT             ; RESET vector
        .DW IRQ_HANDLER      ; IRQ vector