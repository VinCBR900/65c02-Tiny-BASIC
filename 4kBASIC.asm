; =============================================================================
; 4K Integer BASIC v15.22 for the 65C02
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; A fully-featured, self-contained integer Tiny BASIC interpreter in 4 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; LIST to view, NEW to clear and enter your own program).
;
; Credit to Oscar Toledo for his x86 BootBASIC inspiration.
; =============================================================================
; Statements:
;   PRINT [item [; item ...]]
;            item = "string" | TAB(n) | CHR$(n) | expression
;            ';' between items suppresses newline; trailing ';' suppresses final CR
;   IF expr THEN stmt [ELSE stmt2]   single-line; ELSE is optional
;   FOR var = start TO end [STEP n]  ...  NEXT var
;   GOTO lineno        branch unconditionally
;   GOSUB lineno       call subroutine; RETURN to resume
;   INPUT var          read from keyboard
;   LET var = expr     explicit assignment (LET keyword optional)
;   POKE addr, val     write byte to memory
;   READ var [, var ...]   read next value from DATA sequence
;   DATA val [, val ...]   literal values in program (consumed by READ)
;   RESTORE            reset DATA pointer to start of program
;   REM ...            comment to end of line
;   RUN                execute program from first line
;   LIST [n,m]         list stored program, optional line-number range
;   NEW                clear program
;   END                stop execution
;   RETURN             return from GOSUB
;   FREE               print bytes of program RAM remaining
;   GOTO expr          branch to line (expr may be variable or expression)
;   GOSUB expr         call subroutine at line (expr may be variable or expression)
;
;   Multi-statement:   ':' separates statements on one line.
;
; Expressions  (left-to-right within tier):
;   Tier 1 (lowest): AND  OR  XOR       (bitwise / logical)
;   Tier 2:          =  <>  <  >  <=  >=  (comparisons: return -1=true, 0=false)
;   Tier 3:          +  -
;   Tier 4:          *  /  %  MOD       (% and MOD are identical: integer remainder)
;   Tier 4.5:        ^                  (power; see EXPR_POW for precedence notes)
;   Tier 5 (atoms):  literal  variable  (expr)  -expr  +expr  NOT expr
;                    ABS(n)              absolute value
;                    SIN(deg)            sine   * 1000  (0-360 degrees, CORDIC)
;                    COS(deg)            cosine * 1000  (0-360 degrees, CORDIC)
;                    ASIN(v)             arcsine   of v*1000, -90..90 degrees
;                    ACOS(v)             arccosine of v*1000, 0..180 degrees
;                    TAB(n)              print n spaces (PRINT only; expr argument)
;                    CHR$(n)             character with ASCII code n  (PRINT only)
;                    HEX$(n)             n as 4-digit hex, MSB first  (PRINT only)
;                    ASC("c")            ASCII code of first char of string
;                    PEEK(addr)          read byte from memory address
;                    USR(addr)           call machine-code subroutine, A=lo T0
;                    RND                 pseudo-random 1..32767 (no argument)
; Numbers:     signed 16-bit integers  -32768 .. 32767
;              decimal, or hex literal $HHHH (1-4 hex digits)
; Variables:   A .. Z  (26 x 2-byte, zero-page)
; Line range:  1 .. 32767
;
; KNOWN LIMITATIONS
;
; ASIN(x)/ACOS(x) for |x| >= 1000 clamp to the boundary (not an error) --
;   this includes the exact |x|==1000 case and the out-of-range |x|>1000 case.
;
; ^ (power): negative exponent is undefined and raises OV ERR. Overflow of
;   the signed 16-bit result also raises OV ERR (checked before the multiply
;   loop starts -- not a silent wraparound like the general '*' operator).
;
; DATA must be the sole statement on its line (the line's first token is the
;   only one checked when scanning for DATA lines).
;
; Multi-FOR headers sharing a single colon-chained line are not supported --
;   each FOR must be alone on its line (matching NEXT/GOSUB/RETURN).
;
; Input buffer is 41 bytes (40 usable chars + CR terminator). Each keypress
;   past the limit sounds BELL and is discarded outright -- not stored, not
;   echoed, buffer position does not advance.
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
;
; =============================================================================
; CHANGE HISTORY
;
; v15.22 (Aug 2026) - 73 bytes free (confirmed by build)
;   - EXPR_POW (EP_mul, EP_sign): two inline 16-bit copies into T0 (from CX,
;     from CY) converted to the shared TO_T0 helper.
;   - Showcase (RAM at $0200, not part of the $F000 ROM budget above): line
;     880 (Spiral Vortex) changed from X*X+Y*Y to X^2+Y^2 to exercise the
;     `^` operator.
;   - Showcase lines 660/680 (Mandelbrot escape test) were tried as
;     A^2/B^2 but REVERTED back to A*A/B*B: the escape-time algorithm
;     relies on A/B growing past +-181 (sqrt(32767)) once a point starts
;     diverging, which `^`'s explicit 16-bit overflow guard correctly
;     rejects (OV ERR IN 680) where `*`'s silent mod-65536 wraparound
;     did not. The demo depends on `*`'s wraparound behaviour here.
;
; v15.21 (Aug 2026) - 67 bytes free
;   - Cleaned up file header to match house style.
;   - Added guards to the `^` power operator: negative exponent and
;     signed 16-bit overflow now both raise OV ERR (see Known Limitations).
;
; v15.20 (Aug 2026) - 261 bytes free
;   - NEW: $HHHH hex literal syntax (1-4 hex digits), usable anywhere a
;     decimal number literal is (expressions, assignments, IF/FOR/DATA...).
;     New TOK_HEX ($FE, just below TOK_NUM); reused the ~9 existing
;     "CMP #TOK_NUM" skip-sites as range checks instead of exact matches.
;     Bare $HHHH literals also PRINT as hex when they're the whole item.
;   - DATA/READ retokenized: DATA bodies are now real tokens (TOK_NUM/
;     TOK_HEX), same as any other statement
;   - SC_GO (SIN/COS engine) angle reduction rewritten to a single mod-90
;     DIV_KERN call: quadrant = Q mod 4, fold = R or 90-R -- supports any
;     signed 16-bit angle, not just 0-360. DIV_KERN extracted as a
;     standalone subroutine, shared by */,%,MOD and SC_GO.
;   - FIXED: NOT truncated the rest of its statement ("PRINT NOT 0;X" dropped X).
;   - FIXED: generic (expr) grouping returned wrong results ("PRINT (1+2)*3" -> 0).
;
; v15.19 (Aug 2026)
;   - NEW: ASIN(v)/ACOS(v) -- binary-search bisection over SC_GO, no new
;     CORDIC mode needed. Out-of-range input clamps to +-1000 (see Known
;     Limitations). Extended FUNC_JT (below) to cover them.
;   - HEX$ token relocated from $AA to the former $A2 (INKEY) placeholder,
;     freeing $AA/$AB (contiguous after TOK_COS) for ASIN/ACOS in FUNC_JT.
;
; v15.18 (Aug 2026) - 508 bytes free
;   - RESTORED: HEX$(n) as a PRINT-only item (4-digit hex, MSB first),
;     mirroring CHR$/TAB's PRINT-only scoping. New TOK_HEXS token;
;     DO_PRINT dispatches it directly via CMP, reusing E2_chrs to parse
;     the (n) argument (same helper ABS/PEEK/USR already share).
;
; v15.17 (Aug 2026) - 521 bytes free
;   - EXPR2 function dispatch (ABS/PEEK/USR/SIN/COS) converted from a
;     CMP/BEQ chain to an indexed FUNC_JT jump table; renumbered tokens
;     contiguous ($A5-$A9 Group A, $A4 Group B/RND) to support it.
;     Centralized the "consume token, eat (expr)" step into the
;     dispatcher itself instead of each handler's own call.
;   - CHR$ scoped to PRINT-only (removed from general EXPR2 dispatch), -4 bytes.
;
; v15.16 (Aug 2026) - 453 bytes free
;   - E2_sin/E2_cos angle-fold/negate/scale pipeline reviewed and rewritten
;     (completing the CORDIC_KERN review started in v15.15): four explicit
;     quadrant branches replaced with a two-step geometric fold; quadrant
;     negation reads T1 directly instead of a stale register copy; SIN/COS
;     result select unified through TO_T0 with a dynamic offset; sign
;     handling stores T0+1's raw byte directly (bit 7 = sign) instead of
;     an explicit 0/1 flag.
;
; v15.15 (Aug 2026) - 395 bytes free (SIZE PASS 4 + REM bug fix)
;   - CORDIC_KERN restructured: unified the separate +1/-1 branches into
;     one conditional-negate-then-add shape, removing 3 now-unused helpers.
;   - RD_uint/RD_next_val: shared $0D-exhaustion handling between RD_body
;     and RD_skip_ln; digit-to-value via AND #$0F instead of SBC.
;   - FIXED: TOKENIZE emitted TOK_REM *after* the comment text instead of
;     before it -- LIST showed garbled REM lines and RUN threw UK ERR on
;     any line containing REM. Fixed by mirroring DATA's already-correct
;     token-first pattern.
;
; v15.14 (Aug 2026) - 321 bytes free
;   - Refactored for size: KW_TABLE/STMT_JT/DO_ERROR relocated, several
;     routines renamed, expression-atom tokens renumbered, removed
;     commands (CLS/HELP/ON/INKEY/SGN) replaced with STMT_JT placeholder
;     entries. Verified via full regression suite.
;
; v15.10 - v15.13 (Aug 2026) - 194 -> 209 bytes free
;   - Extracted shared 16-bit helpers (TO_T0, T0_TO_CURLN, STORE_VAR,
;     ADDT0_TO, GETVARC, CMP16, TOKSKIP_LP/TOKSKIP_IP) for ZP copy/add/
;     store/compare/scan idioms repeated across the file.
;   - FIXED: DELINE could corrupt the program store on a page-crossing
;     delete (found via handoff-doc bug inventory of $0D-scan sites that
;     didn't treat TOK_NUM's 2-byte payload as skippable).
;   - FIXED: converting two of INSLINE's compares to CMP16 left Y non-zero
;     afterward, corrupting the byte-shift-on-insert loop on the 2nd+ line
;     insert -- reverted those two sites to inline compares (CMP16's
;     (ZP0),y trick clobbers Y; unsafe wherever Y is live across the call).
;
; v15.9 (Aug 2026) - 77 bytes free
;   - Refactored zero page to use .RS instead of hard-coded addresses.
;   - Refactored GETLINE to a shared prompt + Max-chars limit.
;   - SIZE PASS 1/N: LDA #0+STA -> STZ (11x), JMP-in-range -> BRA (7x),
;     PLA+TAX -> PLX (4x), TXA+PHA -> PHX (1x).
;
; v15.8 (Aug 2026) - BUG FIX (line-terminator scanning)
;   - FIXED: several scan/copy loops (EDITLN, DELINE, INSLINE, READ/DATA,
;     GOTOL, SKIP_STMT, SKIPEOL) compared every raw byte to $0D without
;     recognising a TOK_NUM's 2-byte payload -- any number literal with a
;     lo/hi byte equal to 13 (e.g. 13, 269, 525, 3328-3583...) was
;     misread as end-of-line/statement, corrupting program-store scans.
;     Fixed by giving each loop the same token-aware skip shape.
;
; v15.7 (Jul 2026) - 110 bytes free
;   - OPTIMISED: DO_FOR variable-letter validation (SEC/SBC/CMP range
;     check instead of two absolute bounds checks); step storage merged
;     to one shared store point.
;   - OPTIMISED (largest single change): DO_NEXT's comparison logic
;     replaced with a single unified signed compare (diff = var - limit;
;     sign-XOR against step decides continue/stop) instead of separate
;     positive-step/negative-step branches.
;
; v15.6
;   - NEW: LIST n,m -- optional line-number range (bare LIST unchanged),
;     via a minimal token-aware skip loop for lines below n.
;   - NEW: GET_TWO_ARGS -- shared <expr>,<expr> parser for LIST, POKE.
;
; v15.5
;   - Ported INSLINE from uBASIC6502b: shift-up loop compares moving
;     pointers directly against LP instead of a counted decrement helper.
;   - Deleted T2DEC; OOM check simplified to a hi-byte-only compare.
;
; v15.4
;   - Reordered zero page so FVAR/FLIM/FSTEP/CURLN form one contiguous
;     7-byte run matching the FOR_STK frame layout; DO_FOR pushes the
;     frame with one indexed copy loop instead of 7 unrolled stores.
;   - Merged DO_GOTO/DO_GOSUB's duplicated GOTOL/error/CURLN-update tail.
;
; v15.3
;   - FIXED: cold-start zero-page clear loop condition (BPL -> BNE).
;   - FIXED: single-line colon-chained FOR/NEXT execution.
;   - FIXED: trailing colon evaluation bug in PRINT statement output.
;
; v15.2 (Jul 2026) - 67 bytes free
;   - Rewrote pre-loaded RAM showcase to a self-checking test suite.
;   - Added SIN/COS wave-plot demo routines.
;
; v15.1 (Jul 2026) - 67 bytes free
;   - REMOVED: INKEY statement to reclaim ~16 bytes of ROM space.
;   - Added NEG_X / SHIFT_R16_T0 for centralized ZP negate/shift.
;
; v15.0 (Jul 2026) - 0 bytes free (ROM maxed out)
;   - ADDED: 16-bit fixed-point CORDIC engine for SIN(deg) and COS(deg).
;   - ADDED: TAB(n) print control via simple space-loop generator.
;   - REMOVED: CLS, HELP, AT, ON...GOTO/GOSUB, HEX$, SGN to fit CORDIC engine.
;
; v14.0 - v14.2 (Size Optimizations)
;   - Factored out 16-bit loop-decrement operations into centralized T2DEC.
;   - Redesigned relational engine using unified bitmasks and N XOR V logic.
;   - Grouped statement tokens into a contiguous block ($80-$95).
;
; v13.0 (Size Optimizations)
;   - Switched strings and KW_TABLE to high-bit last-character termination.
;   - Dropped keyword length bytes; TRYKW scans for high-bit flags instead.
;
; v12.0 - v12.4 (IRQ & Stability Pass)
;   - ADDED: Maskable IRQ support on $E007 supporting runtime BREAK recovery.
;   - FIXED: SGN(pos) sign-extension bug and restored missing uppercase PRT_HEX.
;
; v11.3 - v11.4
;   - FIXED: target line tracking during GOTO/GOSUB to prevent nested loop corruption.
; =============================================================================
;
; Token stream format  (TBUF / program store):
;   Keywords    $80-$A5  (single byte)
;   Numbers     $FF <lo> <hi>  (3 bytes, little-endian)
;   Strings     passed through as-is, including surrounding quotes
;   End-of-line $0D followed by $00 sentinel
; Program storage line format:
;   <lineno_lo> <lineno_hi> <tokenised_body> $0D

; =============================================================================
; ---- compile-time constants --------------------------------------------------
RAM_TOP  = $1000             ; first byte ABOVE usable RAM  (4 KB SRAM)
HWSTACK  =$FF
PROG     = HWSTACK+$101             ; program storage base address
IBUF_MAX = 41
BELL     = 7
BS       = 8
CR       = $0D

; ---- Kowalski virtual I/O addresses ------------------------------------------
IO_CLS   = $E000             ; write any value to clear screen + home cursor
IO_PUTCH = $E001             ; write a character  (write only)
IO_GETCH = $E004             ; read a character   (read, 0 = no char)
IO_IRQ   = $E007             ; write any value to fire a maskable IRQ (Break key)

; ---- token codes  ($80-$A8 range; $FF = inline number) ----------------------
; Statements: contiguous block $80..$95 (22 entries) -- all dispatched via STMT_JT.
; Expr atoms: $96..$A8.  LET ($A1) is also checked by STMT as a fallback.
TOK_PRINT   = $80            ; PRINT [item [; item ...]]
TOK_IF      = $81            ; IF expr [THEN] stmt [ELSE stmt2]
TOK_GOTO    = $82            ; GOTO lineno
TOK_GOSUB   = $83            ; GOSUB lineno
TOK_RETURN  = $84            ; RETURN
TOK_RUN     = $85            ; RUN
TOK_LIST    = $86            ; LIST
TOK_NEW     = $87            ; NEW
TOK_INPUT   = $88            ; INPUT [prompt;] var [, var ...]
TOK_REM     = $89            ; REM comment
TOK_END     = $8A            ; END
TOK_FOR     = $8B            ; FOR var = start TO end [STEP n]
TOK_NEXT    = $8C            ; NEXT [var]
TOK_FREE    = $8D            ; FREE  (print free bytes)
TOK_POKE    = $8E            ; POKE addr, val
TOK_CLS     = $8F            ; CLS  
TOK_HELP    = $90            ; HELP  
; TOK_ON ($91) removed v15.0 -- slot is now a KW_TABLE placeholder
TOK_DATA    = $92            ; DATA val, val, ...  
TOK_READ    = $93            ; READ var
TOK_RESTORE = $94            ; RESTORE 
TOK_ELSE    = $95            ; ELSE  
; ---- expression-atom tokens: $96..$A8 (never in STMT_JT) -------------------
; ---- v15.17: renumbered so table-dispatched function tokens (Group A:
;      ABS/PEEK/USR/SIN/COS, uniform 1-arg; Group B: RND, 0-arg) are
;      contiguous at the top ($A4-$A9). Everything else here stays
;      individually checked (infix ops AND/OR/XOR/MOD, statement-context
;      keywords STEP/TO/LET/THEN, or PRINT-only CHR$/ASC/TAB) -- unaffected
;      by the FUNC_JT dispatch change. TRYKW/DO_LIST derive token<->text
;      purely from KW_TABLE position, so this reorder needs no other fix.
TOK_STEP    = $96            ; STEP 
TOK_TO      = $97            ; TO  
TOK_CHRS    = $98            ; CHR$(n)  (PRINT-only, v15.17)
TOK_ASC     = $99            ; ASC("c") 
TOK_AND     = $9A            ; AND  
TOK_OR      = $9B            ; OR   
TOK_NOT     = $9C            ; NOT expr 
TOK_XOR     = $9D            ; XOR  
TOK_LET     = $9E            ; LET  
TOK_THEN    = $9F            ; THEN 
TOK_TAB     = $A0            ; TAB(n)  (replaces AT; same token slot)
TOK_MOD     = $A1            ; MOD     
TOK_HEXS    = $A2            ; HEX$(n)  4-digit hex, PRINT-only (v15.19: moved
                              ; from $AA into former TOK_INKEY placeholder slot
                              ; to free $AA/$AB, contiguous after TOK_COS, for
                              ; ASIN/ACOS in the FUNC_JT group)
; TOK_SGN ($A3) removed v15.0 -- still free
; ---- Group B (0-arg, no parens) -- FUNC_JT dispatch starts here (FUNC_LO) --
TOK_RND     = $A4            ; RND     
; ---- Group A (uniform 1-arg, paren-wrapped) -- FUNC_JT indices 0..6 --------
TOK_ABS     = $A5            ; ABS(n)  
TOK_PEEK    = $A6            ; PEEK(addr)  
TOK_USR     = $A7            ; USR(addr)  
TOK_SIN     = $A8            ; SIN(deg) -> deg*1000 (0-360)
TOK_COS     = $A9            ; COS(deg) -> deg*1000 (0-360)
TOK_ASIN    = $AA            ; ASIN(v)  v in -1000..1000 -> degrees -90..90 (v15.19)
TOK_ACOS    = $AB            ; ACOS(v)  v in -1000..1000 -> degrees 0..180  (v15.19)
TOK_HEX     = $FE            ; inline 16-bit unsigned hex literal follows, e.g. $1234 (v15.20)
TOK_NUM     = $FF            ; inline 16-bit number follows

; ---- error codes  (byte index into ERR_TABLE; each entry is 2 chars) --------
ERR_SN   = 0                 ; syntax error
ERR_UL   = 2                 ; undefined line number
ERR_OV   = 4                 ; division by zero
ERR_OM   = 6                 ; out of memory
ERR_NR   = 8                 ; nesting error
ERR_ST   = 10                ; zero STEP
ERR_UK   = 12                ; unknown statement
ERR_OD   = 14                ; out of DATA

; ---- assembler options -------------------------------------------------------
        .opt proc65c02

; =============================================================================
; Program Start - Kowalski trampoline, which executes from the first byte not 
; reset vector.  Real hardware reaches INIT via Reset vector $FFFC instead.
; Technically in Zero page but overwritten as soon as program starts
         .ORG 0 
         JMP INIT        

; ---- zero-page addresses -----------------------------------------------------
IP       = $00               ; 16-bit: interpreter pointer
; FVAR,FLIM,FSTEP,CURLN are contiguous
; on purpose: DO_FOR copies this 7-byte block into
; a FOR_STK frame with one indexed loop instead of
; unrolled stores (CURLN already holds the correct
; loop_line value, so no separate copy is needed).
FVAR     = $02               ;  8-bit: FOR staging: var_slot (VARS offset)
FLIM:    .RS 2               ; 16-bit: FOR staging: limit
FSTEP:   .RS 2               ; 16-bit: FOR staging: step
CURLN:   .RS 2               ; 16-bit: current executing line number
; --- 
LP:      .RS 2               ; 16-bit: list/edit/scratch pointer
T0:      .RS 2               ; 16-bit: expression result / scratch 0
T1:      .RS 2               ; 16-bit: scratch 1
T2:      .RS 2               ; 16-bit: scratch 2
PE:      .RS 2               ; 16-bit: program end
GRET:    .RS 1               ;  8-bit: GOSUB nesting depth
RUN:     .RS 1               ;  8-bit: 0 = idle, $FF = running
GORET:   .RS 2               ; 16 bytes: GOSUB return stack 
TKTOK:   .RS 1               ;  8-bit: TRYKW keyword index
FSTK:    .RS 1               ;  8-bit: FOR nesting depth
FOR_STK: .RS 28              ; 28 bytes: FOR frames        
FOR_FRSZ = 7                 ; bytes per FOR frame
RUNSP:   .RS 1               ;  8-bit: saved SP for stack unwind
OP:      .RS 1               ;  8-bit: MUL/DIV operator ('*' or '/')
DATA_PTR: .RS 2              ; 16-bit: pointer to next DATA value to READ 
RND_SEED: .RS 2              ; 16-bit: LFSR seed for RND, init to $ACE1

; CORDIC scratch (zeroed by INIT_z with rest of ZP):
CX:      .RS 2               ; 16-bit: CORDIC X accumulator
CY:      .RS 2               ; 16-bit: CORDIC Y accumulator
CZ:      .RS 2               ; 16-bit: CORDIC Z angle accumulator
CX_SAV:  .RS 2               ; 16-bit: saved CX per iteration
CIDX:    .RS 1               ;  8-bit: CORDIC iteration counter
ATEMP:   .RS 1               ;  8-bit: angle quadrant temp

; ASIN/ACOS bisection scratch (v15.19). Separate from ATEMP/T0-T2 above
; because SC_GO clobbers all of those on every call, and the bisection
; loop needs state that survives repeated SC_GO calls.
AAV:     .RS 2               ; 16-bit: target value v, signed
ALO:     .RS 1               ;  8-bit: bisection low bound (degrees)
AHI:     .RS 1               ;  8-bit: bisection high bound (degrees)
AMID:    .RS 1               ;  8-bit: current midpoint candidate (degrees)
AMODE:   .RS 1               ;  8-bit: bit0 0=ASIN/1=ACOS; bit7 orig sign of v (ASIN only)

; ZP0 - permanent $0000 pointer for (zp),Y indirect-indexed addressing.
; Zeroed once by INIT's cold-boot DO_NEW clear (X=$FF entry covers all of
; zero page $01-$FF) and never written again, so (ZP0),Y always resolves
; to address Y itself -- lets CMP16/etc. use Y as a direct dest zp address
; the way zp,X already lets X be a direct src zp address (STA doesn't
; support zp,Y, so this is the equivalent trick for the write/compare side).
ZP0:     .RS 2

; Buffers/BASIC VARS
VARS:    .RS 52               ; 52 bytes: A-Z variables     
TBUF:    .RS IBUF_MAX+1       ; Tokenised buffer  
IBUF:    .RS IBUF_MAX+1       ; Raw input buffer  


ZPEND    = *                    ; audit

; =============================================================================
; PRE-LOADED FEATURE SHOWCASE  (program storage at $0200)
; Demonstrates every statement and function in 4K BASIC v14:
;   PRINT / CHR$ / ASC / REM / ABS / SGN / MOD / NOT / AND / OR / XOR / RND
;   PEEK / POKE / DATA / READ / RESTORE
;   FOR / NEXT / STEP (including negative step)
;   IF / THEN / ELSE / GOSUB / RETURN / ON n GOSUB
;   Mandelbrot set renderer (validates expression evaluator, nested FOR, GOTO)
; Mandelbrot: fixed-point integer arithmetic.
;   Real axis C: -128..16 step 4  (37 columns)
;   Imag axis I:  -64..56 step 6  (21 rows)
;   Max 16 iterations; CHR$(E+32) for escaped pixels, space inside.
;   Called as a GOSUB at line 600; uses IF/THEN/ELSE for pixel output.
; =============================================================================
        .ORG $0200
        .DB $0A, $00, $89, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $31, $20, $53, $48, $4F, $57, $43, $41, $53, $45, $0D  ; 10 REM  4K BASIC v15.1 SHOWCASE
        .DB $14, $00, $80, $22, $3D, $3D, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $31, $20, $3D, $3D, $22, $0D  ; 20 PRINT "== 4K BASIC v15.1 =="
        .DB $1E, $00, $80, $22, $43, $48, $52, $22, $3B, $98, $28, $FF, $24, $00, $29, $3B, $22, $28, $36, $35, $29, $3D, $22, $3B, $98, $28, $FF, $41, $00, $29, $3B, $22, $20, $20, $41, $53, $43, $3D, $22, $3B, $99, $28, $22, $41, $22, $29, $0D  ; 30 PRINT "CHR";CHR$ (36 );"(65)=";CHR$ (65 );"  ASC=";ASC ("A")
        .DB $28, $00, $80, $22, $31, $37, $20, $4D, $4F, $44, $20, $35, $3D, $22, $3B, $FF, $11, $00, $A1, $FF, $05, $00, $3B, $22, $20, $20, $41, $42, $53, $20, $6E, $65, $67, $37, $3D, $22, $3B, $A5, $28, $2D, $FF, $07, $00, $29, $0D  ; 40 PRINT "17 MOD 5=";17 MOD 5 ;"  ABS neg7=";ABS (-7 )
        .DB $32, $00, $80, $22, $4E, $4F, $54, $20, $30, $3D, $22, $3B, $9C, $FF, $00, $00, $3B, $22, $20, $20, $36, $20, $41, $4E, $44, $20, $33, $3D, $22, $3B, $FF, $06, $00, $9A, $FF, $03, $00, $0D  ; 50 PRINT "NOT 0=";NOT 0 ;"  6 AND 3=";6 AND 3 
        .DB $3C, $00, $80, $22, $35, $20, $4F, $52, $20, $32, $3D, $22, $3B, $FF, $05, $00, $9B, $FF, $02, $00, $3B, $22, $20, $20, $37, $20, $58, $4F, $52, $20, $33, $3D, $22, $3B, $FF, $07, $00, $9D, $FF, $03, $00, $0D  ; 60 PRINT "5 OR 2=";5 OR 2 ;"  7 XOR 3=";7 XOR 3 
        .DB $46, $00, $80, $22, $52, $4E, $44, $20, $4D, $4F, $44, $20, $31, $30, $3D, $22, $3B, $A4, $A1, $FF, $0A, $00, $0D  ; 70 PRINT "RND MOD 10=";RND MOD 10 
        .DB $50, $00, $8E, $FE, $FF, $00, $2C, $FF, $2A, $00, $3A, $80, $22, $50, $4F, $4B, $45, $3D, $22, $3B, $A6, $28, $FE, $FF, $00, $29, $0D  ; 80 POKE $00FF ,42 :PRINT "POKE=";PEEK ($00FF )
        .DB $5A, $00, $93, $41, $2C, $42, $2C, $43, $3A, $80, $22, $44, $41, $54, $41, $20, $20, $22, $3B, $41, $3B, $22, $20, $20, $22, $3B, $42, $3B, $22, $20, $20, $22, $3B, $43, $0D  ; 90 READ A,B,C:PRINT "DATA  ";A;"  ";B;"  ";C
        .DB $64, $00, $94, $3A, $93, $41, $3A, $80, $22, $52, $45, $53, $54, $4F, $52, $45, $20, $41, $3D, $22, $3B, $41, $0D  ; 100 RESTORE :READ A:PRINT "RESTORE A=";A
        .DB $6E, $00, $92, $20, $31, $31, $31, $2C, $32, $32, $32, $2C, $33, $33, $33, $0D  ; 110 DATA  111,222,333
        .DB $78, $00, $8B, $49, $3D, $FF, $01, $00, $97, $FF, $05, $00, $0D  ; 120 FOR I=1 TO 5 
        .DB $82, $00, $80, $49, $3B, $0D  ; 130 PRINT I;
        .DB $8C, $00, $8C, $49, $0D  ; 140 NEXT I
        .DB $96, $00, $80, $0D  ; 150 PRINT 
        .DB $A0, $00, $8B, $49, $3D, $FF, $0A, $00, $97, $FF, $01, $00, $96, $2D, $FF, $03, $00, $0D  ; 160 FOR I=10 TO 1 STEP -3 
        .DB $AA, $00, $80, $49, $3B, $0D  ; 170 PRINT I;
        .DB $B4, $00, $8C, $49, $0D  ; 180 NEXT I
        .DB $BE, $00, $80, $0D  ; 190 PRINT 
        .DB $C8, $00, $81, $FF, $03, $00, $3E, $FF, $01, $00, $9F, $80, $22, $49, $46, $20, $74, $72, $75, $65, $22, $0D  ; 200 IF 3 >1 THEN PRINT "IF true"
        .DB $D2, $00, $81, $FF, $01, $00, $3E, $FF, $03, $00, $9F, $80, $22, $57, $52, $4F, $4E, $47, $22, $95, $80, $22, $45, $4C, $53, $45, $20, $6F, $6B, $22, $0D  ; 210 IF 1 >3 THEN PRINT "WRONG"ELSE PRINT "ELSE ok"
        .DB $DC, $00, $83, $FF, $F4, $01, $0D  ; 220 GOSUB 500 
        .DB $E6, $00, $89, $20, $73, $69, $6E, $65, $20, $77, $61, $76, $65, $20, $20, $54, $41, $42, $28, $32, $30, $2B, $53, $49, $4E, $28, $58, $29, $2F, $35, $30, $29, $0D  ; 230 REM  sine wave  TAB(20+SIN(X)/50)
        .DB $F0, $00, $8B, $58, $3D, $FF, $00, $00, $97, $FF, $67, $01, $96, $FF, $0F, $00, $0D  ; 240 FOR X=0 TO 359 STEP 15 
        .DB $FA, $00, $80, $A0, $28, $FF, $14, $00, $2B, $A8, $28, $58, $29, $2F, $FF, $32, $00, $29, $3B, $22, $2A, $22, $0D  ; 250 PRINT TAB (20 +SIN (X)/50 );"*"
        .DB $04, $01, $8C, $58, $0D  ; 260 NEXT X
        .DB $0E, $01, $82, $FF, $58, $02, $0D  ; 270 GOTO 600 
        .DB $18, $01, $8A, $0D  ; 280 END 
        .DB $F4, $01, $80, $22, $47, $4F, $53, $55, $42, $20, $6F, $6B, $22, $3A, $84, $0D  ; 500 PRINT "GOSUB ok":RETURN 
        .DB $58, $02, $8B, $49, $3D, $2D, $FF, $40, $00, $97, $FF, $38, $00, $96, $FF, $06, $00, $0D  ; 600 FOR I=-64 TO 56 STEP 6 
        .DB $62, $02, $44, $3D, $49, $0D  ; 610 D=I
        .DB $6C, $02, $8B, $43, $3D, $2D, $FF, $80, $00, $97, $FF, $10, $00, $96, $FF, $04, $00, $0D  ; 620 FOR C=-128 TO 16 STEP 4 
        .DB $76, $02, $41, $3D, $43, $3A, $42, $3D, $44, $3A, $45, $3D, $FF, $00, $00, $0D  ; 630 A=C:B=D:E=0 
        .DB $80, $02, $8B, $4E, $3D, $FF, $01, $00, $97, $FF, $10, $00, $0D  ; 640 FOR N=1 TO 16 
        .DB $8A, $02, $81, $45, $3E, $FF, $00, $00, $9F, $82, $FF, $A8, $02, $0D  ; 650 IF E>0 THEN GOTO 680 
        .DB $94, $02, $54, $3D, $41, $2A, $41, $2F, $FF, $40, $00, $2D, $42, $2A, $42, $2F, $FF, $40, $00, $2B, $43, $0D  ; 660 T=A*A/64 -B*B/64 +C
        .DB $9E, $02, $42, $3D, $FF, $02, $00, $2A, $41, $2A, $42, $2F, $FF, $40, $00, $2B, $44, $3A, $41, $3D, $54, $0D  ; 670 B=2 *A*B/64 +D:A=T
        .DB $A8, $02, $81, $45, $3D, $FF, $00, $00, $9F, $81, $41, $2A, $41, $2F, $FF, $40, $00, $2B, $42, $2A, $42, $2F, $FF, $40, $00, $3E, $FF, $00, $01, $9F, $45, $3D, $4E, $0D  ; 680 IF E=0 THEN IF A*A/64 +B*B/64 >256 THEN E=N
        .DB $B2, $02, $8C, $4E, $0D  ; 690 NEXT N
        .DB $BC, $02, $81, $45, $3E, $FF, $00, $00, $9F, $80, $98, $28, $45, $2B, $FF, $20, $00, $29, $3B, $95, $80, $98, $28, $FF, $20, $00, $29, $3B, $0D  ; 700 IF E>0 THEN PRINT CHR$ (E+32 );ELSE PRINT CHR$ (32 );
        .DB $C6, $02, $8C, $43, $0D  ; 710 NEXT C
        .DB $D0, $02, $80, $22, $22, $0D  ; 720 PRINT ""
        .DB $DA, $02, $8C, $49, $0D  ; 730 NEXT I
        .DB $EE, $02, $80, $22, $3D, $3D, $3D, $20, $52, $65, $6E, $64, $65, $72, $20, $31, $36, $2D, $42, $69, $74, $20, $49, $6E, $74, $65, $67, $65, $72, $20, $53, $70, $69, $72, $61, $6C, $20, $56, $6F, $72, $74, $65, $78, $20, $3D, $3D, $3D, $22, $0D  ; 750 PRINT "=== Render 16-Bit Integer Spiral Vortex ==="
        .DB $F8, $02, $80, $22, $54, $45, $53, $54, $53, $3A, $20, $53, $49, $4E, $2C, $20, $43, $4F, $53, $2C, $20, $41, $53, $49, $4E, $2C, $20, $41, $43, $4F, $53, $20, $28, $4E, $4F, $20, $53, $51, $52, $54, $2F, $54, $41, $4E, $2F, $41, $54, $4E, $29, $22, $0D  ; 760 PRINT "TESTS: SIN, COS, ASIN, ACOS (NO SQRT/TAN/ATN)"
        .DB $02, $03, $89, $4C, $20, $54, $52, $41, $43, $4B, $53, $20, $4C, $41, $53, $54, $20, $43, $4F, $4C, $55, $4D, $4E, $20, $53, $49, $4E, $43, $45, $20, $54, $41, $42, $28, $6E, $29, $20, $48, $45, $52, $45, $20, $50, $52, $49, $4E, $54, $53, $20, $6E, $20, $73, $70, $61, $63, $65, $73, $0D  ; 770 REM L TRACKS LAST COLUMN SINCE TAB(n) HERE PRINTS n spaces
        .DB $20, $03, $89, $48, $20, $41, $4E, $44, $20, $56, $20, $43, $4F, $4E, $53, $54, $41, $4E, $54, $53, $20, $48, $41, $52, $44, $43, $4F, $44, $45, $44, $20, $54, $4F, $20, $53, $41, $56, $45, $20, $56, $41, $52, $49, $41, $42, $4C, $45, $53, $0D  ; 800 REM H AND V CONSTANTS HARDCODED TO SAVE VARIABLES
        .DB $2A, $03, $8B, $52, $3D, $FF, $00, $00, $97, $FF, $1A, $00, $0D  ; 810 FOR R=0 TO 26
        .DB $34, $03, $9E, $4C, $3D, $FF, $00, $00, $0D  ; 820 LET L=0
        .DB $3E, $03, $8B, $43, $3D, $FF, $00, $00, $97, $FF, $3C, $00, $0D  ; 830 FOR C=0 TO 60
        .DB $48, $03, $9E, $58, $3D, $43, $2D, $FF, $1E, $00, $0D  ; 840 LET X=C-30
        .DB $52, $03, $89, $53, $43, $41, $4C, $45, $20, $59, $20, $42, $59, $20, $32, $20, $46, $4F, $52, $20, $41, $53, $43, $49, $49, $20, $43, $48, $41, $52, $41, $43, $54, $45, $52, $20, $41, $53, $50, $45, $43, $54, $20, $52, $41, $54, $49, $4F, $0D  ; 850 REM SCALE Y BY 2 FOR ASCII CHARACTER ASPECT RATIO
        .DB $5C, $03, $9E, $59, $3D, $28, $52, $2D, $FF, $0D, $00, $29, $2A, $FF, $02, $00, $0D  ; 860 LET Y=(R-13)*2
        .DB $66, $03, $89, $27, $44, $27, $20, $49, $53, $20, $53, $51, $55, $41, $52, $45, $44, $20, $44, $49, $53, $54, $41, $4E, $43, $45, $2E, $20, $41, $56, $4F, $49, $44, $53, $20, $4E, $45, $45, $44, $49, $4E, $47, $20, $53, $51, $52, $54, $21, $0D  ; 870 REM 'D' IS SQUARED DISTANCE. AVOIDS NEEDING SQRT!
        .DB $70, $03, $9E, $44, $3D, $58, $5E, $FF, $02, $00, $2B, $59, $5E, $FF, $02, $00, $0D  ; 880 LET D=X^2+Y^2
        .DB $7A, $03, $81, $44, $3E, $FF, $84, $03, $9F, $82, $FF, $60, $04, $0D  ; 890 IF D>900 THEN GOTO 1120 (v15.20 fix: skip the L=C+1 update too, else TAB(C-L) is always 0 -- see changelog)
        .DB $84, $03, $89, $53, $43, $41, $4C, $45, $20, $54, $4F, $20, $2D, $31, $30, $30, $30, $20, $54, $4F, $20, $2B, $31, $30, $30, $30, $20, $52, $41, $4E, $47, $45, $20, $46, $4F, $52, $20, $49, $4E, $56, $45, $52, $53, $45, $20, $54, $52, $49, $47, $0D  ; 900 REM SCALE TO -1000 TO +1000 RANGE FOR INVERSE TRIG
        .DB $8E, $03, $89, $33, $30, $2A, $31, $30, $30, $30, $3D, $33, $30, $30, $30, $30, $20, $57, $48, $49, $43, $48, $20, $53, $41, $46, $45, $4C, $59, $20, $46, $49, $54, $53, $20, $49, $4E, $20, $31, $36, $2D, $42, $49, $54, $20, $53, $49, $47, $4E, $45, $44, $20, $49, $4E, $54, $0D  ; 910 REM 30*1000=30000 WHICH SAFELY FITS IN 16-BIT SIGNED INT
        .DB $98, $03, $9E, $55, $3D, $28, $58, $2A, $FF, $E8, $03, $29, $2F, $FF, $1E, $00, $0D  ; 920 LET U=(X*1000)/30
        .DB $A2, $03, $9E, $57, $3D, $28, $59, $2A, $FF, $E8, $03, $29, $2F, $FF, $1E, $00, $0D  ; 930 LET W=(Y*1000)/30
        .DB $AC, $03, $89, $2D, $2D, $2D, $20, $54, $45, $53, $54, $20, $41, $53, $49, $4E, $2F, $41, $43, $4F, $53, $20, $43, $4F, $4F, $52, $44, $20, $4D, $41, $50, $50, $49, $4E, $47, $20, $2D, $2D, $2D, $0D  ; 940 REM --- TEST ASIN/ACOS COORD MAPPING ---
        .DB $B6, $03, $9E, $45, $3D, $AA, $28, $55, $29, $0D  ; 950 LET E=ASIN(U)
        .DB $C0, $03, $9E, $46, $3D, $AB, $28, $57, $29, $0D  ; 960 LET F=ACOS(W)
        .DB $CA, $03, $89, $2D, $2D, $2D, $20, $54, $45, $53, $54, $20, $43, $4F, $52, $44, $49, $43, $20, $53, $49, $4E, $2F, $43, $4F, $53, $20, $2D, $2D, $2D, $0D  ; 970 REM --- TEST CORDIC SIN/COS ---
        .DB $D4, $03, $89, $4D, $55, $4C, $54, $49, $50, $4C, $59, $20, $44, $20, $54, $4F, $20, $4D, $41, $4B, $45, $20, $52, $49, $4E, $47, $53, $2C, $20, $53, $55, $42, $54, $52, $41, $43, $54, $20, $41, $4E, $47, $4C, $45, $53, $20, $46, $4F, $52, $20, $53, $50, $49, $52, $41, $4C, $0D  ; 980 REM MULTIPLY D TO MAKE RINGS, SUBTRACT ANGLES FOR SPIRAL
        .DB $DE, $03, $9E, $49, $3D, $A8, $28, $44, $2A, $FF, $02, $00, $2D, $45, $2A, $FF, $05, $00, $29, $0D  ; 990 LET I=SIN(D*2-E*5)
        .DB $E8, $03, $9E, $4A, $3D, $A9, $28, $44, $2B, $46, $2A, $FF, $03, $00, $29, $0D  ; 1000 LET J=COS(D+F*3)
        .DB $F2, $03, $89, $2D, $2D, $2D, $20, $4E, $45, $53, $54, $45, $44, $20, $54, $52, $49, $47, $20, $54, $45, $53, $54, $53, $20, $2D, $2D, $2D, $0D  ; 1010 REM --- NESTED TRIG TESTS ---
        .DB $FC, $03, $89, $49, $20, $41, $4E, $44, $20, $4A, $20, $41, $52, $45, $20, $2D, $31, $30, $30, $30, $20, $54, $4F, $20, $2B, $31, $30, $30, $30, $2C, $20, $50, $45, $52, $46, $45, $43, $54, $20, $46, $4F, $52, $20, $49, $4E, $56, $45, $52, $53, $45, $20, $54, $52, $49, $47, $0D  ; 1020 REM I AND J ARE -1000 TO +1000, PERFECT FOR INVERSE TRIG
        .DB $06, $04, $9E, $41, $3D, $AA, $28, $4A, $29, $0D  ; 1030 LET A=ASIN(J)
        .DB $10, $04, $9E, $42, $3D, $AB, $28, $49, $29, $0D  ; 1040 LET B=ACOS(I)
        .DB $1A, $04, $89, $2D, $2D, $2D, $20, $4D, $41, $54, $48, $20, $53, $48, $41, $44, $45, $20, $56, $41, $4C, $55, $45, $20, $28, $52, $45, $53, $55, $4C, $54, $53, $20, $49, $4E, $20, $30, $20, $54, $4F, $20, $7E, $32, $37, $30, $29, $20, $2D, $2D, $2D, $0D  ; 1050 REM --- MATH SHADE VALUE (RESULTS IN 0 TO ~270) ---
        .DB $24, $04, $9E, $5A, $3D, $A5, $28, $41, $2D, $42, $29, $0D  ; 1060 LET Z=ABS(A-B)
        .DB $2E, $04, $89, $2D, $2D, $2D, $20, $4D, $41, $50, $20, $54, $4F, $20, $41, $53, $43, $49, $49, $20, $43, $48, $41, $52, $53, $20, $2D, $2D, $2D, $0D  ; 1070 REM --- MAP TO ASCII CHARS ---
        .DB $38, $04, $9E, $53, $3D, $FF, $20, $00, $0D  ; 1080 LET S=32
        .DB $3D, $04, $81, $5A, $3E, $FF, $1E, $00, $9F, $9E, $53, $3D, $FF, $2E, $00, $0D  ; 1085 IF Z>30 THEN LET S=46
        .DB $42, $04, $81, $5A, $3E, $FF, $46, $00, $9F, $9E, $53, $3D, $FF, $2B, $00, $0D  ; 1090 IF Z>70 THEN LET S=43
        .DB $47, $04, $81, $5A, $3E, $FF, $6E, $00, $9F, $9E, $53, $3D, $FF, $4F, $00, $0D  ; 1095 IF Z>110 THEN LET S=79
        .DB $4C, $04, $81, $5A, $3E, $FF, $96, $00, $9F, $9E, $53, $3D, $FF, $40, $00, $0D  ; 1100 IF Z>150 THEN LET S=64
        .DB $51, $04, $80, $A0, $28, $43, $2D, $4C, $29, $3B, $98, $28, $53, $29, $3B, $0D  ; 1105 PRINT TAB(C-L);CHR$(S);
        .DB $56, $04, $9E, $4C, $3D, $43, $2B, $FF, $01, $00, $0D  ; 1110 LET L=C+1
        .DB $60, $04, $8C, $43, $0D  ; 1120 NEXT C
        .DB $6A, $04, $80, $0D  ; 1130 PRINT
        .DB $74, $04, $8C, $52, $0D  ; 1140 NEXT R
        .DB $7E, $04, $8A, $0D  ; 1150 END
SHOWCASE_END = *               ; v15.20: extended with Integer Spiral Vortex demo (lines 750-1150) after Mandelbrot; regenerate this comment

; =============================================================================
        .ORG $F000      ; 4kbyte 
; STRING TABLE (all strings on same page)
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/kw addresses
STR_BANNER: .DB "4K BASIC v15.22"       ; same length as v15.16/v15.20/v15.21
STR_CRLF:   .DB $0D,$8A             ; CR, LF|$80 = $8A
STR_BYTES:  .DB " BYTES FREE",$0D,$8A  ; last LF has high-bit
STR_ERROR:  .DB " ER",$D2           ; 'R'|$80 = $D2
STR_IN:     .DB " IN ",$A0          ; last space|$80 = $A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB  ; 'K'|$80 = $CB

; =============================================================================
; Keyword string table  (chars only; bit 7 set on last char marks end of entry)
; No length byte, no NUL.  $00 sentinel terminates whole table.
; TRYKW, KW_NEXT, DO_LIST, DO_HELP all detect end-of-entry via bit 7.
; High-bit values = last_char | $80 (e.g. 'T'=$54 -> $D4, '$'=$24 -> $A4)
; Keyword string table  (chars only; bit 7 set on last char marks end of entry)
; No length byte, no NUL.  $00 sentinel terminates whole table.
; TRYKW, KW_NEXT, DO_LIST, DO_HELP all detect end-of-entry via bit 7.
; High-bit values = last_char | $80 (e.g. 'T'=$54 -> $D4, '$'=$24 -> $A4)
; Order MUST match token values: entry[0] = TOK_PRINT ($80), entry[1] = TOK_IF ($81) ...
KW_TABLE:
; ---- statement tokens $80..$95 (must appear first in this order) ------------
; NOTE: $8F (CLS) and $90 (HELP) removed. Placeholder $80 bytes keep TKTOK
; in sync. STMT_JT entries for those slots point to DO_DATA (RTS stub).
        .DB "PRIN",$D4        ; $80 TOK_PRINT   ('T'|$80=$D4)
        .DB "I",$C6           ; $81 TOK_IF      ('F'|$80=$C6)
        .DB "GOT",$CF         ; $82 TOK_GOTO    ('O'|$80=$CF)
        .DB "GOSU",$C2        ; $83 TOK_GOSUB   ('B'|$80=$C2)
        .DB "RETUR",$CE       ; $84 TOK_RETURN  ('N'|$80=$CE)
        .DB "RU",$CE          ; $85 TOK_RUN     ('N'|$80=$CE)
        .DB "LIS",$D4         ; $86 TOK_LIST    ('T'|$80=$D4)
        .DB "NE",$D7          ; $87 TOK_NEW     ('W'|$80=$D7)
        .DB "INPU",$D4        ; $88 TOK_INPUT   ('T'|$80=$D4)
        .DB "RE",$CD          ; $89 TOK_REM     ('M'|$80=$CD)
        .DB "EN",$C4          ; $8A TOK_END     ('D'|$80=$C4)
        .DB "FO",$D2          ; $8B TOK_FOR     ('R'|$80=$D2)
        .DB "NEX",$D4         ; $8C TOK_NEXT    ('T'|$80=$D4)
        .DB "FRE",$C5         ; $8D TOK_FREE    ('E'|$80=$C5)
        .DB "POK",$C5         ; $8E TOK_POKE    ('E'|$80=$C5)
        .DB $80               ; $8F placeholder (CLS removed, STMT_JT -> RTS stub)
        .DB $80               ; $90 placeholder (HELP removed, STMT_JT -> RTS stub)
        .DB $80               ; $91 placeholder (ON removed, STMT_JT -> RTS stub)
        .DB "DAT",$C1         ; $92 TOK_DATA    ('A'|$80=$C1)  was $A1
        .DB "REA",$C4         ; $93 TOK_READ    ('D'|$80=$C4)  was $A2
        .DB "RESTOR",$C5      ; $94 TOK_RESTORE ('E'|$80=$C5)  was $A3
        .DB "ELS",$C5         ; $95 TOK_ELSE    ('E'|$80=$C5)  was $A4
; ---- expression-atom tokens $96..$AB (in KW_TABLE for tokeniser only) ------
; v15.17: reordered so Group A (ABS,PEEK,USR,SIN,COS) + Group B (RND) are
; contiguous at $A4-$A9 for FUNC_JT indexed dispatch. Non-grouped tokens
; (individually checked, unaffected) fill $96-$A1; 1 placeholder at $A3.
; v15.19: HEX$ moved into the former $A2 (INKEY) placeholder -- table
; position, not byte offset, determines token value, so this doesn't
; renumber anything else. That frees $AA/$AB, contiguous right after
; TOK_COS, for ASIN/ACOS -- extending Group A to FUNC_JT indices 0..6.
        .DB "STE",$D0         ; $96 TOK_STEP    ('P'|$80=$D0)
        .DB "T",$CF           ; $97 TOK_TO      ('O'|$80=$CF)
        .DB "CHR",$A4         ; $98 TOK_CHRS    ('$'|$80=$A4)  PRINT-only
        .DB "AS",$C3          ; $99 TOK_ASC     ('C'|$80=$C3)
        .DB "AN",$C4          ; $9A TOK_AND     ('D'|$80=$C4)
        .DB "O",$D2           ; $9B TOK_OR      ('R'|$80=$D2)
        .DB "NO",$D4          ; $9C TOK_NOT     ('T'|$80=$D4)
        .DB "XO",$D2          ; $9D TOK_XOR     ('R'|$80=$D2)
        .DB "LE",$D4          ; $9E TOK_LET     ('T'|$80=$D4)
        .DB "THE",$CE         ; $9F TOK_THEN    ('N'|$80=$CE)
        .DB "TA",$C2          ; $A0 TOK_TAB     ('B'|$80=$C2)
        .DB "MO",$C4          ; $A1 TOK_MOD     ('D'|$80=$C4)
        .DB "HEX",$A4         ; $A2 TOK_HEXS    ('$'|$80=$A4)  PRINT-only (moved from $AA, v15.19)
        .DB $80               ; $A3 placeholder (SGN removed, expr atom not statement -- no STMT_JT impact)
        .DB "RN",$C4          ; $A4 TOK_RND     ('D'|$80=$C4)  Group B: 0-arg, FUNC_LO
        .DB "AB",$D3          ; $A5 TOK_ABS     ('S'|$80=$D3)  Group A: FUNC_JT[0]
        .DB "PEE",$CB         ; $A6 TOK_PEEK    ('K'|$80=$CB)  Group A: FUNC_JT[1]
        .DB "US",$D2          ; $A7 TOK_USR     ('R'|$80=$D2)  Group A: FUNC_JT[2]
        .DB "SI",$CE          ; $A8 TOK_SIN     ('N'|$80=$CE)  Group A: FUNC_JT[3]
        .DB "CO",$D3          ; $A9 TOK_COS     ('S'|$80=$D3)  Group A: FUNC_JT[4]
        .DB "ASI",$CE         ; $AA TOK_ASIN    ('N'|$80=$CE)  Group A: FUNC_JT[5]  (v15.19)
        .DB "ACO",$D3         ; $AB TOK_ACOS    ('S'|$80=$D3)  Group A: FUNC_JT[6]  (v15.19)
        .DB 0                 ; end-of-table sentinel

; Statement dispatch table (used by STMT via JMP (STMT_JT,X))
; Entry order must match token values TOK_PRINT ($80) .. TOK_ELSE ($95).
; Indices 0..14 = original statements; 15..21 = moved-up statements.
; ELSE handler (index 21) calls SKIPEOL to discard the rest of the line.
STMT_JT:
        .DW DO_PRINT,   DO_IF,      DO_GOTO,    DO_GOSUB,  DO_RETURN  ; $80-$84
        .DW DO_RUN,     DO_LIST,    DO_NEW,     DO_INPUT,  DO_REM     ; $85-$89
        .DW DO_END,     DO_FOR,     DO_NEXT,    DO_FREE,   DO_POKE    ; $8A-$8E
        .DW DO_DATA,    DO_DATA,    DO_DATA,    DO_DATA,   DO_READ    ; $8F(nop),$90(nop),$91(nop),$92-$93
        .DW DO_RESTORE, DO_ELSE_SK                                     ; $94-$95
;   v15.20: DATA is now tokenized normally (no more raw-copy special case);
;   at runtime we still just return -- RUNLP's own SKIPEOL call advances
;   past the body -- but that body is now real tokens (TOK_NUM/TOK_HEX/','),
;   consumed by READ via RD_readnum instead of an ASCII-only parser.
        
; =============================================================================
; INIT ? cold start: stack, zero page, load showcase end pointer, banner
;   In:  Reset vector entry.
;   Out: Program state initialised, then falls through to MAIN.
;   Clobbers: A X
; =============================================================================
INIT:
        LDX #HWSTACK
        TXS                  ; initialise stack pointer
        CLD                  ; clear decimal mode
        CLI                  ; enable maskable IRQs (for IRQ Break key)

        ; Clear zero page
        JSR DO_NEW

        ; --- Showcase setup - Delete for actual ROM
        LDA #<SHOWCASE_END  ; PE = end of pre-loaded showcase program
        STA PE
        LDA #>SHOWCASE_END
        STA PE+1
        ; ---
        LDA #<STR_BANNER
        JSR PUTSTR            ; print banner
        JSR DO_FREE
        ; fall through to MAIN

; =============================================================================
; MAIN ? immediate-mode prompt loop
;   In:  Returns from statement handlers, or falls through from INIT.
;   Out: Never returns; loops at interactive prompt.
;   Clobbers: everything (re-initialises per iteration)
; =============================================================================
MAIN:
        STZ RUN
        STZ FSTK
        JSR GETLINE_M          ; fills IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
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
; Two adjacent labels: DO_ERR_NR branches forward into DO_ERROR via BRA;
; DO_ERR_UL falls straight through into DO_ERROR.
; =============================================================================
DO_ERR_NR:
        LDA #ERR_NR
        .DB $2C
DO_ERR_UL:
        LDA #ERR_UL
        ; drop through
; =============================================================================
; DO_ERROR ? print error message and return to MAIN
;   In:  A    error code (ERR_xx constant = index into ERR_TABLE)
;   Out: Character emitted to terminal device. (jumps to MAIN; does not return to caller)
;   Clobbers: A X T0
; =============================================================================
DO_ERROR:
        PHA              ; save error code (survives PRNL which uses A)
        JSR PRNL         ; print CR+LF
        PLX              ; X = error code ? ERR_TABLE index
        LDA ERR_TABLE,x  ; first char of 2-char code
        JSR PUTCH
        INX
        LDA ERR_TABLE,x      ; second char
        JSR PUTCH
        LDA #<STR_ERROR
        JSR PUTSTR           ; " ERR"
        LDA RUN
        BEQ DO_err_noline
DO_break_in:                  ; IRQ handler jumps here to share " IN line\r\n" exit
        LDA #<STR_IN
        JSR PUTSTR           ; " IN "
        LDX #(CURLN-T0)
        JSR TO_T0
        JSR PRT16            ; line number
DO_err_noline:
        JSR PRNL
        CLI                  ; re-enable IRQs (harmless from error path; needed from IRQ path)
        BRA MAIN

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
; GETLINE_M / GETLINE_I / GETLINE  --  read one line of input into IBUF
;
;   In:  GETLINE_M prints "> " (main prompt); GETLINE_I prints "? " (INPUT
;        prompt); both then fall into GETLINE, which just reads.
;   Out: IBUF holds the typed line (CR-terminated, backspace-editable,
;        truncated past IBUF_MAX -- each keypress past the limit sounds
;        BELL); IP -> IBUF
;   Clobbers: A, X, IP
; =============================================================================
GETLINE_M:
         LDA #'>'
         .DB $2C
GETLINE_I:
         LDA #'?'
         JSR PUTCH
         JSR PRTSP
GETLINE: LDX #0
GLL:     JSR GETCH             ; raw read, no echo (see header note)
         CMP #CR
         BEQ GLD
         CMP #BS
         BNE GLS
         JSR PUTCH             ; echo the backspace byte
         TXA                   ; was CPX #0 -- saves 1 byte; A clobbered but GETCH overwrites it
         BEQ GLL
         DEX
         BRA GLL
GLS:     CPX #IBUF_MAX
         BCS GLFULL
         STA IBUF,X
         JSR PUTCH             ; echo the stored character (A unaffected by the STA above)
         INX
         BRA GLL
GLFULL:  LDA #BELL              ; buffer full: discard the char (X
         JSR PUTCH               ; doesn't move), beep instead of echoing it
         BRA GLL                 ; -- the character itself is never printed
GLD:     STA IBUF,X
         JSR PUTCH              ; echo the raw CR (mirrors the old GETCH echo)
         JSR PRNL
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
        STZ T0+1
        LDA #<TBUF
        STA T1
        STZ T1+1

TK_TOP: LDA (T0)             ; 65C02 zp-indirect
        BEQ TK_EOL           ; Null sentinel ($00) -> EOL
        CMP #$0D
        BEQ TK_EOL           ; CR ($0D) -> EOL
        CMP #' '             ; Skip spaces
        BEQ INC_TOP

        CMP #'"'             ; String literal?
        BNE TK_NSTR
        JSR TKEMIT           ; Emit opening '"'
TK_SC:  JSR INC_T0
        LDA (T0)
        BEQ TK_EOL           ; Unterminated string ($00) -> EOL
        JSR TKEMIT
        CMP #'"'
        BEQ INC_TOP          ; Closing '"' -> advance T0 & resume loop
        CMP #$0D
        BNE TK_SC            ; Keep copying string bytes
        BRA TK_EOL           ; Unterminated string ($0D) -> EOL

TK_NSTR:
        CMP #'$'             ; Hex literal? $HHHH (1-4 hex digits, v15.20)
        BNE TK_NDLR
        JSR INC_T0            ; consume '$'
        JSR TKPHEX            ; parse hex digit run into CURLN (advances T0)
        LDA #TOK_HEX
        JSR TKEMIT
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1
        JSR TKEMIT
        BRA TK_TOP

TK_NDLR:
        CMP #'0'             ; Decimal digit?
        BCC TK_NNUM
        CMP #'9'+1
        BCS TK_NNUM
        JSR TKPNUM           ; Parse number into CURLN (advances T0)
        LDA #TOK_NUM
        JSR TKEMIT
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1
        JSR TKEMIT
        BRA TK_TOP

TK_NNUM:
        JSR UC
        CMP #'A'             ; Keyword or variable letter?
        BCC TK_OTHER
        CMP #'Z'+1
        BCS TK_OTHER
        JSR TRYKW            ; Try keyword match (C=0 matched, C=1 not)
        BCC TK_TOP           ; Keyword matched & emitted: continue

TK_OTHER:
        LDA (T0)             ; Re-read char for variable/punctuation
        JSR UC
        JSR TKEMIT
INC_TOP:
        JSR INC_T0           ; Shared helper: advance T0 and loop
        BRA TK_TOP

TK_EOL: LDA #$0D             ; Write $0D $00 end-of-line sentinel
        JSR TKEMIT
        LDA #0
        BRA TKEMIT           ; Tail call: emits $00 and RTS

; =============================================================================
; INC_T0 ? advance source pointer T0 by one byte
;   Out: T0   incremented
;   Clobbers: Flags only (A unchanged).
; =============================================================================
INC_T0: INC T0
        BNE INC_T0_ok
        INC T0+1
INC_T0_ok:
        RTS

; =============================================================================
; INC_DATA_PTR ? advance DATA_PTR by 1 ---------------------------------------
;   Clobbers: Flags only (A unchanged).
; =============================================================================
DATAPTRADD2:
        JSR INC_DATA_PTR
INC_DATA_PTR:
        INC DATA_PTR
        BNE RD_ap_ok
        INC DATA_PTR+1
RD_ap_ok:
        RTS

; =============================================================================
; IPADD2 ? skip a 2-byte payload at IP (e.g. a TOK_NUM's lo/hi bytes), then
;   fall through into GETCI for the byte now at IP
;   In:  IP   points at the first of the 2 bytes to skip
;   Out: A    byte now at (IP), i.e. two bytes past the original IP;  IP+=2
;   Clobbers: None.
;
; GETCI ? read byte at IP and advance IP by one
;   In:  IP   token stream pointer
;   Out: A    byte that was at (IP);  IP  incremented
;   Clobbers: None.
; =============================================================================
IPADD2: JSR INC_IP
        .DB $2C                 ; Swallow LDA (IP)
GETCI:  LDA (IP)             ; 65C02 zp-indirect: fetch byte at IP, then advance
    ; drop through
; =============================================================================
; INC_IP ? increment IP (16-bit pointer) by 1
;   In:  IP points at current token byte.
;   Out: IP advanced by one byte.
;   Clobbers: Flags.
; =============================================================================
INC_IP: INC IP
        BNE INC_IP_ok
        INC IP+1
INC_IP_ok:
        RTS

; =============================================================================
; INC_LP ? advance list pointer LP by one byte
;   In:  LP   pointer into program store
;   Out: LP   incremented
;   Clobbers: None.
; =============================================================================
LPADD2: JSR INC_LP
INC_LP: INC LP
        BNE INC_LP_ok
        INC LP+1
INC_LP_ok:
        RTS

; =============================================================================
; TKEMIT ? write A to token output at T1, advance T1
;   In:  A    byte to write;  T1  destination pointer
;   Out: T1   incremented
;   Clobbers: Y
; =============================================================================
TKEMIT: STA (T1)             ; 65C02 zp-indirect: no Y needed  ($92 opcode)
INC_T1:
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
        LDA (T0)             ; Get ASCII character
        EOR #'0'             ; MAGIC: Maps '0'-'9' to $00-$09. Everything else goes to >= $0A!
        CMP #10              
        BCS TKPN_dn          ; If >= 10, it wasn't a digit. We are done!
        
        PHA                  ; Save the exact binary digit (0-9)
        JSR INC_T0           ; Advance pointer
        
        ; CURLN = CURLN * 10 (via x*2 + x*8)
        ASL CURLN
        ROL CURLN+1          ; CURLN = x*2
        LDA CURLN
        TAX
        LDA CURLN+1
        TAY                  ; X,Y = x*2
        
        ASL CURLN
        ROL CURLN+1
        ASL CURLN
        ROL CURLN+1          ; CURLN = x*8
        
        TXA
        CLC
        ADC CURLN
        STA CURLN
        TYA
        ADC CURLN+1
        STA CURLN+1          ; CURLN = x*2 + x*8 = x*10
        
        PLA                  ; A = digit
        ; CLC                ; 
        ADC CURLN
        STA CURLN
        BCC TKPN_lp
        INC CURLN+1
        BRA TKPN_lp

TKPN_dn: 
        RTS

; =============================================================================
; TKPHEX ? parse hex digit run at T0 into CURLN (16-bit unsigned) (v15.20)
;   In:  T0   points just past the '$' (caller already consumed it)
;   Out: CURLN  parsed value, high digits shifted out on a 5th+ digit
;              (same no-guard wraparound convention as TKPNUM); 0 if no
;              hex digit follows (bare '$' tokenises as $0000)
;        T0   advanced past all hex digit characters
;   Clobbers: A T2
; =============================================================================
TKPHEX: STZ CURLN
        STZ CURLN+1
TKPH_lp:
        LDA (T0)
        JSR UC                ; fold a-f to A-F
        CMP #'0'
        BCC TKPH_dn            ; < '0': not a digit, done
        CMP #'9'+1
        BCC TKPH_dec           ; '0'-'9'
        CMP #'A'
        BCC TKPH_dn            ; in gap ':'..'@': not hex, done
        CMP #'F'+1
        BCS TKPH_dn            ; > 'F': not hex, done
        SEC
        SBC #'A'-10           ; 'A'-'F' -> 10-15
        BRA TKPH_dig
TKPH_dec:
        SEC
        SBC #'0'              ; '0'-'9' -> 0-9
TKPH_dig:
        PHA                    ; save the binary digit (0-15)
        JSR INC_T0
        ASL CURLN              ; CURLN <<= 4
        ROL CURLN+1
        ASL CURLN
        ROL CURLN+1
        ASL CURLN
        ROL CURLN+1
        ASL CURLN
        ROL CURLN+1
        PLA
        ORA CURLN
        STA CURLN
        BRA TKPH_lp
TKPH_dn:
        RTS

; =============================================================================
; TRYKW ? try to match a keyword at the current source position (T0)
;   In:  T0    points at first character of candidate (already UC'd by caller)
;   Out: C=0   matched: token byte emitted via TKEMIT, T0 advanced past keyword
;        C=1   no match: T0 unchanged, nothing emitted
;        TKTOK keyword scan index (scratch; caller must not rely on value)
;   Clobbers: A X Y T2 LP OP
;   Note: CURLN is temporarily used to save/restore T0 during comparison;
;         the value is not meaningful until TOKENIZE assigns it via TKPNUM.
;         OP ($BB) is used as a single-byte temp in TRY_cmp loop -- safe because
;         OP is only set during expression evaluation (mul/div), not tokenise.
; =============================================================================
TRYKW:
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        LDA #TOK_PRINT
        STA TKTOK
TRY_ent:
        LDA (T2)             ; 65C02 zp-indirect: first char of entry ($00 = end of table)
        BEQ TRY_fail         ; $00 sentinel = end of table: no match
        JSR T0_TO_CURLN      ; save source pos for possible backtrack
        LDA T2               ; LP = T2 (point at start of keyword chars)
        STA LP
        LDA T2+1
        STA LP+1
        LDY #0               ; Y = index into keyword entry
TRY_cmp:
        LDA (LP),y           ; char from keyword table (bit 7 = last-char flag)
        TAX                  ; X = raw table byte (preserves bit 7 for end-check)
        AND #$7F             ; strip high-bit: get printable char for comparison
        STA OP               ; OP ($BB) = masked table char temp (safe: not used in tokenise)
        LDA (T0)             ; char from source (IBUF); T0=source ptr, T1=dest ptr -- NEVER STA T1 here!
        JSR UC               ; uppercase source char
        CMP OP               ; compare: Z=1 on match -- MUST NOT touch Z before BNE
        BNE TRY_miss         ; Z=0: mismatch -> try next keyword
        ; matched -- is this the last char? bit 7 is in X
        TXA                  ; restore raw byte to A; TXA sets N=bit7, does not affect Z
        BMI TRY_matched_adv  ; N=1: high-bit set -> last char of keyword, full match
        ; not last char: advance source pointer and loop
        JSR INC_T0            ; advance T0 (source ptr); clobbers flags but not X or Y
        INY                  ; next table char index
        BNE TRY_cmp          ; always (no keyword >= 256 chars)
TRY_matched_adv:
        JSR INC_T0            ; advance source past the final matched char
        ; ---- full match ----
        LDA TKTOK
        PHA
TRY_chk_rem:
        CMP #TOK_REM         ; REM: emit token FIRST, then absorb rest of line verbatim
        BNE TRY_emt
        PLA
        JSR TKEMIT           ; emit TOK_REM before the raw comment text
TRY_raw:                     ; copy raw bytes until $0D (REM body)
        LDA (T0)
        CMP #$0D
        BEQ TRY_raw_done
        JSR TKEMIT
        JSR INC_T0
        BRA TRY_raw
TRY_emt:
        PLA
        JSR TKEMIT
TRY_raw_done:
        CLC
        RTS
TRY_miss:                    ; this keyword doesn't match: restore T0, try next
        LDX #(CURLN-T0)
        JSR TO_T0
        JSR KW_NEXT          ; advance T2 past current entry
        INC TKTOK
        BRA TRY_ent
TRY_fail:
        SEC
        RTS

; =============================================================================
; KW_NEXT ? advance T2 to the next entry in KW_TABLE
;   In:  T2   points at first char of current entry (high-bit last-char format)
;   Out: T2   advanced past all chars of this entry (including the high-bit one)
;   Clobbers: A Y
; =============================================================================
KW_NEXT:
        LDY #$FF             ; Start at -1
KW_nx_lp:
        INY                  ; On first pass, Y rolls over to 0
        LDA (T2),Y           ; Sets the N flag
        BPL KW_nx_lp         ; N is untouched Branch back if high-bit is 0
        TYA                  ; A = index of the last character
        SEC                  ; Set carry = 1 (acts as a +1 for the addition)
        ADC T2               ; A = T2 + Y + 1 
        STA T2
        BCC KW_next_ok       ; If we didn't overflow 255, skip the high-byte inc
        INC T2+1
KW_next_ok:
EL_done:
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
        JSR T0_TO_CURLN
        STZ LP
        LDA #>PROG
        STA LP+1
EL_fl:  LDX #LP               ; scan for insertion/replacement point
        LDY #PE
        JSR CMP16
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
        JSR TOKSKIP_LP
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
        TAX                  ; CMP #0 replacement: TAX sets Z for free (X dead here)
        BEQ EL_done
        ; drop through
; =============================================================================
; INSLINE ? insert (or replace) a tokenised line in the program store
;   In:  IP   source: <body> $0D  (no $FF prefix ? PNUM already consumed it)
;        LP   insertion point (bytes LP..PE shifted up to make room)
;        PE   current program end
;        CURLN line number for the 2-byte header
;   Out: new line written at LP with 2-byte header prepended
;        PE   advanced by inserted byte count
;   Clobbers: A X Y T0 T1
;   Ported from uBASIC6502b (v15.5): the NMOS original counted the shift
;   distance into a scratch register and called a shared decrement-and-test
;   helper (T2DEC) once per byte copied. Replaced with a direct pointer
;   comparison (does the moving pointer equal LP yet?) each iteration,
;   which needs no scratch counter at all and removes T2DEC's last
;   remaining caller after DELINE's own copy of the same pattern was
;   inlined (see DELINE) -- T2DEC itself is deleted. OOM check compares
;   only the new PE's high byte against RAM_TOP's high byte, which is
;   exactly correct (not approximate) because RAM_TOP=$1000 is page-aligned.
; =============================================================================
INSLINE:
        LDY #0
        JSR TOKSKIP_IP
        INY                  ; +2 for the 2-byte line-number header
        INY
        TYA                  ; A = total line size
        CLC
        ADC PE                ; new PE = PE + total size
        STA T1
        LDA PE+1
        ADC #0
        STA T1+1
        CMP #>RAM_TOP        ; would this cross RAM_TOP? (hi-byte only:
        BCC IN_ok            ;  exact since RAM_TOP is page-aligned)
        LDA #ERR_OM
        JMP DO_ERROR
IN_ok:  LDX #(PE-T0)          ; T0 = old PE
        JSR TO_T0
        LDA T1                ; commit new PE now (OOM check already passed)
        STA PE
        LDA T1+1
        STA PE+1
        LDY #0
        JSR CMP_T0_LP        ; if old PE == LP, nothing to shift upward
        BEQ IN_hdr
IN_bk:  LDA T0                ; pre-decrement source (T0)
        BNE IN_d0
        DEC T0+1
IN_d0:  DEC T0
        LDA T1                ; pre-decrement destination (T1)
        BNE IN_d1
        DEC T1+1
IN_d1:  DEC T1
        LDA (T0),y            ; backward copy loop
        STA (T1),y
        JSR CMP_T0_LP        ; stop exactly when T0 == LP
        BNE IN_bk
IN_hdr: LDA CURLN             ; write 2-byte line-number header at LP
        STA (LP),y            ; Y is 0 here
        INY
        LDA CURLN+1
        STA (LP),y
        ; advance LP by 2 for the payload destination
        JSR LPADD2
IN_l2:  LDY #0
IN_cp:  LDA (IP),y            ; copy payload from IP
        STA (LP),y
        CMP #TOK_HEX           ; inline number (dec or hex, v15.20): copy its
        BCC IN_cp_chk          ;  2-byte lo/hi payload unconditionally --
                                ;  must not test them for $0D
        INY
        LDA (IP),y
        STA (LP),y
        INY
        LDA (IP),y
        STA (LP),y
        INY
        BRA IN_cp
IN_cp_chk:
        CMP #$0D
        BEQ IN_done
        INY
        BRA IN_cp             ; always taken for bounded line lengths (<256)

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
        JSR TOKSKIP_LP
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
        LDA LP               ; save LP: the shift loop's own page-boundary
        PHA                  ;  INC LP+1 must not leak to the caller -- INSLINE
        LDA LP+1             ;  (called right after DELINE, on the replace-line
        PHA                  ;  path) needs LP to still be the insertion point.
        LDY #0
DL_cp:  LDA (T0),y           ; shift bytes down
        STA (LP),y
        INY
        BNE DL_nhi
        INC T0+1
        INC LP+1
DL_nhi: LDA T2               ; decrement T2 (inlined; T2DEC removed, single caller)
        BNE DL_declo
        DEC T2+1
DL_declo:
        DEC T2
        LDA T2
        ORA T2+1
        BNE DL_cp
        PLA                  ; restore LP
        STA LP+1
        PLA
        STA LP
DL_upd: LDA PE               ; update PE
        SEC
        SBC T1
        STA PE
        BCS DL_ok
        DEC PE+1
IN_done:
DL_ok:  RTS

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
        TAX                  ; CMP #0 replacement: TAX sets Z for free (X dead here)
        BEQ ST_nop
        BMI ST_tok           ; $80+ = keyword token (checked FIRST, before colon)
        CMP #':'             ; colon separator: skip and loop
        BEQ ST_colon
        JSR DO_LET           ; else implicit assignment  varname = expr
        BRA ST_sep           ; check for trailing ':'
ST_tok: JSR GETCI            ; consume token
        ; All 22 statement tokens ($80..$95) are dispatched via STMT_JT.
        ; Any token >= $96 (expr atoms, LET etc.) falls through to DO_LET.
        CMP #TOK_ELSE+1      ; $96: tokens above table range -> LET / implicit assign
        BCS ST_let
        SEC
        SBC #TOK_PRINT       ; make zero-based index  (valid for $80..$95)
        ASL                  ; word index
        TAX
        ; Push ST_sep-1 so handler RTS lands at ST_sep (JSR-via-stack trick)
        LDA #>ST_sep_m1
        PHA
        LDA #<ST_sep_m1
        PHA
        .DB $7C              ; JMP (STMT_JT,X)  -- 65C02 absolute indexed indirect
        .DW STMT_JT
ST_let: JSR DO_LET           ; LET varname = expr (or implicit assignment)
        BRA ST_sep
ST_colon:
        JSR GETCI            ; consume ':'
        BRA STMT             ; execute next statement on same line
ST_sep_m1:                   ; real label: RTS from handler adds 1 ? ST_sep
        NOP                  ; never executed ? anchor byte for RTS return trick
ST_sep: JSR WPEEK            ; after any statement: check for ':'
        CMP #':'
        BEQ ST_colon         ; another statement on same line: loop
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
DP_top: JSR WPEEK            ; Peek next token -> A
        TAX                  ; CMP #0 replacement (sets Z flag if A=0)
        BEQ DP_nl            ; bare PRINT (sentinel): just print newline
        CMP #CR
        BEQ DP_nl            ; bare PRINT (EOL): just print newline
        CMP #'"'             ; string literal?
        BNE DP_expr    
        JSR GETCI            ; consume opening '"'

DP_str: JSR GETCI
        CMP #'"'
        BEQ DP_aft
        CMP #CR
        BEQ DP_nl
        JSR PUTCH
        BRA DP_str

DP_expr:
        CMP #TOK_TAB         ; TAB(n)?
        BNE DP_chk_chrs
        
        JSR E2_chrs          ; Consumes TAB token and get (n) into T0
        LDX T0               ; Loop count
        BEQ DP_aft           
DP_tab_lp:
        JSR PRTSP            
        DEX
        BNE DP_tab_lp
        BRA DP_aft

DP_chk_chrs:
        CMP #TOK_CHRS        ; CHR$(n)?
        BNE DP_chk_hexs
        
        JSR E2_chrs          ; Consumes CHR$ token get (n) -> T0 
        LDA T0
        JSR PUTCH
        BRA DP_aft

DP_chk_hexs:
        CMP #TOK_HEXS        ; HEX$(n)?
        BNE DP_chk_hex
        JSR E2_chrs          ; Consumes HEX$ token, get (n) -> T0
        JSR PRT_HEX          ; print T0 as 4-digit hex, MSB first
        BRA DP_aft

DP_norm:
        JSR EXPR             
        JSR PRT16
        ; Falls through to DP_aft

DP_aft: JSR WPEEK
        CMP #';'
        BEQ DP_semi
DP_nl:  JMP PRNL             ; Tail call: Print newline and return (No trampoline needed!)

DP_semi:
        JSR GETCI            ; consume ';'
        JSR WPEEK
        CMP #CR             
        BEQ DP_semi_dn       ; trailing semicolon at EOL
        CMP #':'             
        BEQ DP_semi_dn       ; semicolon before ':'
        CMP #TOK_ELSE        
        BEQ DP_semi_dn       ; semicolon before ELSE      
        TAX                  ; Is A == 0 (sentinel)? Sets Z flag.
        BNE DP_top           ; If NOT zero, keep printing! If zero, falls through to RTS.

DP_semi_dn:
        RTS

; -- bare $HHHH literal (v15.20): print as hex ONLY when it is the whole
;    item (nothing but CR/;/:/  ELSE follows its 3-byte encoding) --
;    otherwise it's part of a larger expression: fall through to DP_norm
;    like any other atom, so "$10+1" etc. still evaluate/print normally.
DP_chk_hex:
        CMP #TOK_HEX
        BNE DP_norm
        LDY #3                ; peek past marker+lo+hi, don't consume
        LDA (IP),y
        CMP #CR
        BEQ DP_hex_only
        CMP #';'
        BEQ DP_hex_only
        CMP #':'
        BEQ DP_hex_only
        CMP #TOK_ELSE
        BNE DP_norm            ; more follows: treat as general expression

DP_hex_only:
        JSR PNUM               ; consume marker+lo+hi -> T0
        JSR PRT_HEX
        BRA DP_aft

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
        BNE DO_IF_exec       ; condition true: skip the ELSE hunt entirely

        ; -- condition false: scan for ELSE -----------------------------------
DO_IF_f:
        JSR WPEEK
        CMP #CR              ; EOL with no ELSE: done
        BEQ DO_IF_done
        TAX                  ; 1-byte CMP #0 replacement
        BEQ DO_IF_done

        CMP #TOK_ELSE
        BEQ DO_IF_else       ; found the ELSE: consume it and fall into exec

        JSR GETCI            ; consume ignored token
        CMP #TOK_HEX         ; inline number (dec or hex, v15.20)?
        BCC DO_IF_f
        JSR IPADD2            ; consume the 2-byte payload
        BRA DO_IF_f

        ; -- condition true / ELSE block found --------------------------------
DO_IF_else:
        JSR GETCI            ; consume TOK_ELSE and fall through to exec

DO_IF_exec:                  ; shared execution block for both True and ELSE
        JSR WPEEK
        CMP #TOK_THEN        ; optional THEN keyword (forgiving for both IF and ELSE)
        BNE DO_IF_stmt
        JSR GETCI             ; consume TOK_THEN
DO_IF_stmt:
        JMP STMT              ; tail call -> RUNLP's SKIPEOL handles any remainder

DO_IF_done:
        RTS

; =============================================================================
; DO_GOTO ? GOTO lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOTO:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        BRA DO_go_common     ; GOTO has no frame to push -- skip straight to the tail

; =============================================================================
; DO_GOSUB ? GOSUB lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOSUB:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        LDA GRET
        CMP #8               ; max 8 levels of nesting
        BCC DO_gosub_ok
GOSRET_ERR:
        JMP DO_ERR_NR        ; ? shared error stub
DO_gosub_ok:
        ASL
        TAX
        LDA IP               ; push return address (IP after the GOSUB)
        STA GORET,x
        LDA IP+1
        STA GORET+1,x
        INC GRET
        ; fall through into the shared GOTO/GOSUB tail
DO_go_common:                ; shared by DO_GOTO and DO_GOSUB
        JSR GOTOL
        BCS DO_gosub_ul
        JSR T0_TO_CURLN      ; update CURLN to target line (GOTOL leaves T0=line#)
RUN_LINE:
        LDX RUNSP
        TXS
        BRA RUNGO
DO_gosub_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; =============================================================================
; DO_RETURN ? RETURN
;   Clobbers: A X
; =============================================================================
DO_RETURN:
        LDA GRET
        BEQ GOSRET_ERR
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
        JSR PARSE_VAR
        BCS DO_input_dn
        PHA                  ; save slot
        LDA IP               ; save IP across GETLINE
        STA T2
        LDA IP+1
        STA T2+1
        JSR GETLINE_I          ; reads into IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
        JSR EXPR             ; evaluate expression from TBUF
        LDA T2               ; restore IP
        STA IP
        LDA T2+1
        STA IP+1
        PLX
        JSR STORE_VAR
DO_input_dn:    ; drop through

; =============================================================================
; DO_REM ? REM (comment): body already absorbed into token stream by TOKENIZE
;   Clobbers: None.
; =============================================================================
DO_REM: RTS

; =============================================================================
; DO_RUN ? RUN: start program from first line
;   Clobbers: A X Y
; =============================================================================
DO_RUN:
        STZ IP
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
        LDX #IP               ; check IP == PE  (end of program)
        LDY #PE
        JSR CMP16
        BEQ RUNEND
RUNLP_go:                    ; read 2-byte line number header, advance IP by 2
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INC_IP
RUNLP_hi:
        LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INC_IP
RUNGO:  JSR STMT
        LDA RUN
        BEQ RUNEND
        JSR SKIPEOL
        BRA RUNLP

; =============================================================================
; DO_NEW ? clear ZP and reste Program store
;   Clobbers: A X
; =============================================================================
DO_NEW:
        ; clear zero page
        LDX #0
INIT_z: STZ 0,x              ; 65C02 STZ zp,x  (no LDA #0 needed)
        DEX
        BNE INIT_z           
        ; DATA_PTR ($BC-$BD) is zeroed by INIT_z above ? sentinel 0 = rescan from PROG  
        ; reset program store
        STZ PE  ; since page aligned
        LDA #>PROG
        STA PE+1

        ; Seed RND
        LDA #$E1             ; seed RND LFSR to $ACE1 (must be non-zero)
        STA RND_SEED
        LDA #$AC
        STA RND_SEED+1
        ; drop through - alreayd cleared but harmless and saves a RET

; Two labels on one instruction: DO_END is the handler entry, RUNEND is the
; shared landing target used by DO_RUN and NEXT_END.
DO_END:
RUNEND: STZ RUN
LS_done:
        RTS

; =============================================================================
; DO_LIST ? LIST [n,m] : list program lines, optional line-number range,
; de-tokenising on the fly
;   Syntax:  LIST         -- all lines
;            LIST n,m     -- lines n..m inclusive (n,m may be expressions)
;   In:  IP -> first char after "LIST"; PE = program end
;   Out: matching lines printed; IP advanced
;   Clobbers: A X Y T0 T1 T2 LP
;   T1 = lo-bound, T2 = hi-bound; defaulted to the full range (0..$7FFF) for
;   a bare LIST, or set via GET_TWO_ARGS.
;   Lines below the lo-bound are walked (to correctly locate the next line)
;   via a separate, minimal token-aware skip loop (LS_skip_body) that never
;   calls PUTCH/PRT16/PRNL, so the shared print primitives need no
;   suppression flag. Lines are stored in ascending order, so a current
;   line number above the hi-bound stops the whole scan immediately.
; =============================================================================
DO_LIST:
        STZ T1                ; default lo-bound = 0
        STZ T1+1
        LDA #$FF
        STA CY                ; default hi-bound = $7FFF
        LDA #$7F
        STA CY+1
        JSR WPEEK
        CMP #$0E
        BCC LS_scan           ; bare LIST? defaults stand

        JSR GET_TWO_ARGS      ; args present: T1 = n (lo), T0 = m
        LDA T0
        STA CY                ; move m into hi-bound (CY)
        LDA T0+1
        STA CY+1
LS_scan:
        STZ LP
        LDA #>PROG
        STA LP+1

LS_ln:  LDX #LP               ; end of program?
        LDY #PE
        JSR CMP16
        BEQ LS_done           ; inverted branch (saves 3 bytes)

        LDA (LP)              ; read lo byte of line number
        STA T0
        LDY #1
        LDA (LP),y            ; read hi byte
        STA T0+1

        ; -- Bound Checks --
        LDA CY                ; current > hi-bound? (CY - T0 borrows)
        CMP T0
        LDA CY+1
        SBC T0+1
        BCC LS_done           ; yes: passed hi-bound, STOP execution entirely

        LDA T0                ; current < lo-bound? (T0 - T1 borrows)
        CMP T1
        LDA T0+1
        SBC T1+1
        BCC LS_skip_hdr       ; yes: below lo-bound, silently skip this line!

        ; -- Print Valid Line --
        JSR PRT16             ; print line number
        JSR PRTSP
        JSR LPADD2            ; advance LP past 2-byte header

LS_body:
        LDA (LP)
        CMP #CR
        BEQ LS_eol
        CMP #TOK_HEX          ; hex literal? (v15.20)
        BEQ LS_hex
        CMP #TOK_NUM
        BEQ LS_num
        CMP #TOK_PRINT
        BCC LS_lit            ; < TOK_PRINT: literal char

        ; -- Keyword Lookup --
        SEC
        SBC #TOK_PRINT
        TAX                   ; X = keyword index (0-based)
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        TXA
        BEQ LS_prk            ; If X was 0, jump right to printing
LS_skp_lp:
        JSR KW_NEXT
        DEX
        BNE LS_skp_lp         ; DEX sets Z, no CPX needed (saves 4 bytes)

LS_prk: LDY #0
LS_pkl: LDA (T2),Y
        PHA                   ; Save original char with bit 7 intact
        AND #$7F              ; Strip high-bit for printing
        JSR PUTCH
        PLA                   ; Restore original char
        BMI LS_pkd            ; if bit 7 was set, we are done (saves 3 bytes)
        INY
        BRA LS_pkl

LS_pkd: JSR INC_LP
        JSR PRTSP
        BRA LS_body

LS_lit: JSR PUTCH
        JSR INC_LP
        BRA LS_body

LS_num: JSR load_t0_inc      ; consume marker+lo+hi -> T0
        JSR PRT16             ; print as decimal
        BRA LS_tail

; -- below-lo-bound path: advance LP past header, then skip body silently --
LS_skip_hdr:
        JSR LPADD2
LS_skip_body:
        LDA (LP)
        CMP #CR
        BEQ LS_skip_eol
        CMP #TOK_HEX          ; dec or hex literal, v15.20
        BCC LS_skip_adv
        JSR LPADD2            ; skip the marker, skip lo byte
LS_skip_adv:
        JSR INC_LP            ; skip this byte (or the literal's hi byte)
        BRA LS_skip_body

LS_eol: JSR PRNL              ; fall-through EOL handler (saves 1 byte)
LS_skip_eol:
        JSR INC_LP
        JMP LS_ln              ; loop back to next line

LS_hex: JSR load_t0_inc       ; hex literal (v15.20): consume marker+lo+hi -> T0
        JSR PRT_HEX            ; print as $HHHH
LS_tail:
        JSR PRTSP              ; both paths print a trailing space
        BRA LS_body             ; both return to LS_body

; -- shared loader for LS_num/LS_hex: consume a 3-byte literal at LP -------
;   In:  LP  points at the TOK_NUM/TOK_HEX marker byte
;   Out: T0  16-bit value; LP advanced past marker+lo+hi
;   Clobbers: A
load_t0_inc:
        JSR INC_LP
        LDA (LP)
        STA T0
        JSR INC_LP
        LDA (LP)
        STA T0+1
        JMP INC_LP            ; tail call: its own RTS returns to our caller

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
        ;BRA PUTSTR           ; print " BYTES FREE\r\n" and return  (tail call)
        .DB $2C               ; eat next 2 bytes
        ; drop through
; =============================================================================
; PUTSTR  -  print a NUL-terminated string from the string table
;   In:  A = lo-byte of string address; hi-byte is always STR_PAGE
;   Out: characters written to terminal
;   Clobbers: A Y T2
;   All strings must reside on page STR_PAGE.  A single byte pointer suffices
;   because STR_PAGE is loaded as the hi-byte here.
; PUTSTRZP: Print a NULL-Terminated String at T2 indirect
;   Entry from DP_NL is a fall-through tail call: DO_PRINT loads A = <STR_CRLF
;   then drops into PUTSTR rather than JSR+RTS, saving 3 bytes.
;   LS_DONE (end of DO_LIST) is co-located with PS_DN so both share this RTS.
; =============================================================================
PRNL:    LDA #<STR_CRLF
PUTSTR:  STA T2
         LDA #STR_PAGE
         STA T2+1
PUTSTRZP:
         LDY #0
PS_LP:   LDA (T2),Y           ; fetch char (may have bit 7 set = last char)
         BPL PS_norm           ; bit 7 clear: normal char, print and loop
         AND #$7F              ; strip high-bit terminator flag before printing last char
         JSR PUTCH
         INY                   ; advance Y (not strictly needed, but keeps state clean)
         BRA PS_DN             ; done
PS_norm: JSR PUTCH
         INY                   ; advance index to next char
         BRA PS_LP

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
        STZ LP+1
PS_DN:   RTS

; =============================================================================
; DO_FOR ? FOR var = start TO limit [STEP step]
;   In:  IP -> variable letter
;   Out: loop frame pushed onto FOR_STK; VARS[var] = start
;   Clobbers: A X Y T0 T2 LP
;   Stages var_slot/limit/step into FVAR/FLIM/FSTEP, which sit immediately
;   before CURLN in zero page (see equates) forming one contiguous 7-byte
;   run [FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1,CURLN,CURLN+1] matching the FOR_STK
;   frame layout exactly. CURLN already holds the correct loop_line value
;   (set once per line before STMT runs), so no separate copy is needed for
;   it. The final push is one indexed loop instead of 7 unrolled stores.
;   Variable letter is consumed before validation (not peeked): safe because
;   DO_ERROR never returns to its caller (ends in JMP MAIN), so IP's exact
;   position after an aborted statement is never examined.
; =============================================================================
DO_FOR:
        JSR GETVARC          ; consume variable letter directly, A = char-'A'
        CMP #26               ; 0-25 = valid letter
        BCC DO_for_ok
        LDA #ERR_SN
        JMP DO_ERROR
DO_for_ok:
        ASL                  ; byte offset into VARS
        STA FVAR             ; stage var_slot directly (no stack juggling)
        JSR EAT_EXPR         ; evaluate start value -> T0
        LDX FVAR
        JSR STORE_VAR         ; store start value in variable
        JSR EAT_EXPR         ; consume '=' then evaluate '=', then TO, then limit
        LDA T0
        STA FLIM             ; stage limit directly
        LDA T0+1
        STA FLIM+1
        JSR WPEEK
        CMP #TOK_STEP
        BNE DO_for_nostep
        JSR GETCI            ; consume STEP token
        JSR EXPR             ; evaluate step -> T0
        LDA T0
        LDX T0+1
        BRA DO_for_havestep
DO_for_nostep:
        LDA #1               ; default step = 1
        LDX #0
DO_for_havestep:
        STA FSTEP            ; stage step (shared store for both paths)
        STX FSTEP+1
        ORA FSTEP+1          ; step of zero is illegal
        BNE DO_for_szok
        LDA #ERR_ST
        JMP DO_ERROR
DO_for_szok:
        LDA FSTK
        CMP #4               ; max 4 nested FOR loops
        BCC DO_for_push
        JMP DO_ERR_NR        ; ? shared error stub
DO_for_push:
        JSR FSTK_BASE        ; LP = FOR_STK + FSTK*7 (A already holds FSTK)
        LDY #6
DO_for_cp:
        LDA FVAR,y           ; copy FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1,CURLN,CURLN+1
        STA (LP),y           ; into the frame in one pass (offsets match exactly)
        DEY
        BPL DO_for_cp
        INC FSTK
        RTS

; =============================================================================
; DO_NEXT ? NEXT [var]
;   In:  IP -> optional variable name (consumed but not checked against the
;        FOR variable; NEXT always closes the innermost active loop)
;   Out: loop variable advanced; branches back into the loop body or falls
;        through to the statement after NEXT once the limit is crossed
;   Clobbers: A X Y T0 T2 LP
;   Comparison is a single unified signed test: diff = var - limit. If
;   diff==0 the limit is met exactly (inclusive: always loop once more).
;   Otherwise XOR diff's sign with the step's sign -- differing signs means
;   the limit has not yet been reached (keep looping); matching signs means
;   it has been crossed (stop). Replaces separate mirrored branches for
;   positive- and negative-step loops with one shared path.
; =============================================================================
DO_NEXT:
        JSR WPEEK_UC         ; consume optional variable name (ignored)
        SEC
        SBC #'A'
        CMP #26               ; 0-25 = valid letter
        BCS DO_next_novar
        JSR GETCI
DO_next_novar:
        LDA FSTK
        BNE DO_next_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_next_ok:
        DEC                 ; 65C02: top frame index = FSTK - 1 (A already
                              ;  holds FSTK from the check above)
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
        ; unified signed compare: diff = var - limit
        LDY #1
        LDA VARS,x
        SEC
        SBC (LP),y           ; [1] limit_lo
        STA T0
        INY
        LDA VARS+1,x
        SBC (LP),y           ; [2] limit_hi
        TAX                  ; X = diff hi byte
        ORA T0               ; Z reflects 16-bit "diff == 0"
        BEQ DN_loop          ; var == limit: always loop once more
        TXA                  ; restore diff hi byte (restores N flag)
        LDY #4
        EOR (LP),y           ; XOR with [4] step_hi
        BMI DN_loop          ; differing signs: limit not yet crossed
        DEC FSTK             ; matching signs: limit crossed, done
        RTS
DN_loop:                     ; branch back to body: load loop line, run it
        LDY #5
        LDA (LP),y           ; [5] loop_line_lo
        STA T0
        INY
        LDA (LP),y           ; [6] loop_line_hi
        STA T0+1
        JSR GOTOL
        BCS DN_ul
        JSR SKIP_STMT        ; skip past FOR clause only (stop at ':' or $0D)
        BCC DN_samel         ; C=0: ':' found -- body is colon-chained on this line
        ; C=1: $0D found -- FOR was alone on its line (original behaviour)
        JSR INC_IP            ; consume the $0D
        LDX #IP
        LDY #PE
        JSR CMP16
        BEQ DN_end           ; IP == PE: program ended inside loop
DN_runbody:                  ; read 2-byte line-number header, advance IP
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INC_IP
DN_rh:  LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INC_IP
DN_rb2: JMP RUN_LINE         ; restore S and jump to target
DN_samel:                    ; colon-chained: resume right after ':' on same line
        JSR INC_IP            ; consume the ':'
        JSR T0_TO_CURLN      ; T0 still holds loop_line (GOTOL doesn't clobber it)
        JMP RUNGO             ; re-enter statement dispatch mid-line (no header)
DN_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; DN_end must stay separate from RUNEND: RUNEND only clears RUN, it does
; NOT decrement FSTK. A program ending on the last line of a bare FOR/NEXT
; needs FSTK decremented here; branching to RUNEND directly would leave
; the FOR-nesting counter permanently wrong for the rest of execution.
DN_end: DEC FSTK
        STZ RUN
        RTS

; =============================================================================
; GET_TWO_ARGS ? parse two comma-separated expressions; shared by DO_POKE
; and DO_LIST
;   Syntax: <expr> , <expr>
;   In:  IP -> first expression
;   Out: T1 = first argument (16-bit); T0 = second argument (16-bit)
;   Clobbers: A T0 T1
;   The first result is carried across the second EXPR call via the
;   hardware stack rather than left in T1 directly, because EXPR's own
;   binary-operator evaluation (relational/add-sub/mul-div tiers) uses T1
;   as scratch for its left operand.
; =============================================================================
GET_TWO_ARGS:
        JSR EXPR              ; first arg -> T0
        LDA T0+1
        PHA                   ; save hi byte
        LDA T0
        PHA                   ; save lo byte
        JSR EAT_EXPR          ; consume ',' then evaluate second arg -> T0
        PLA
        STA T1                ; pull first arg lo
        PLA
        STA T1+1              ; pull first arg hi
        RTS

; =============================================================================
; DO_POKE ? POKE addr, value
;   Clobbers: A Y T0 T1
; =============================================================================
DO_POKE:
        JSR GET_TWO_ARGS      ; T1 = addr, T0 = value
        LDA T0
        STA (T1)            ; POKE the value
        RTS

; =============================================================================
; DO_RESTORE ? RESTORE: reset DATA pointer (0 = rescan from PROG on next READ)
;   READ/RESTORE consume the raw bytes via DATA_PTR.  (Same pattern as DO_REM.)
;   Clobbers: None.  (STZ does not touch A/X/Y)
; =============================================================================
DO_RESTORE:
        STZ DATA_PTR         ; 65C02 STZ zp
        STZ DATA_PTR+1
RD_var_done:
DO_DATA:
        RTS

; =============================================================================
; DO_READ ? READ var [, var ...]
;   Reads the next value(s) from DATA lines into variable(s).
;   DATA line format in program store (v15.20: DATA is tokenized normally,
;   same as any other statement -- no more raw-ASCII special case):
;     [lineno_lo][lineno_hi][TOK_DATA][value list: '-'? (TOK_NUM|lo|hi), ','...][$0D]
;   DATA_PTR invariant:
;     0    reset/restored ? rescan from PROG on next READ
;     PE   exhausted ? no more DATA values exist
;     else points at current parse position INSIDE a DATA body (past TOK_DATA),
;          i.e. at '-', TOK_NUM/TOK_HEX, a comma, or $0D (body exhausted)
;   In:  IP        first token of READ statement (variable letter)
;        DATA_PTR  current position (see invariant)
;   Out: IP        advanced past consumed variable(s) and commas
;        DATA_PTR  advanced past consumed value(s)
;   Clobbers: A X Y T0
; =============================================================================
DO_READ:
RD_var: JSR WPEEK_UC         ; peek at next IP token (uppercased)
        CMP #'A'
        BCC RD_sn
        CMP #'Z'+1
        BCS RD_sn
        JSR GETVARC          ; consume variable letter, A = char-'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var slot
        JSR RD_next_val      ; T0 = next data value; C=1 if out-of-data
        BCS RD_od
        PLX
        JSR STORE_VAR
        JSR WPEEK            ; check for ', var' continuation
        CMP #','
        BNE RD_var_done
        JSR GETCI            ; consume ','
        BRA RD_var

RD_od:  PLA                  ; discard saved var slot
        LDA #ERR_OD
        .BYTE $2C            ; BIT abs  ? consumes next 2 bytes as operand
RD_sn:  LDA #ERR_SN
        JMP DO_ERROR

; =============================================================================
; RD_NEXT_VAL ? find and parse the next value from DATA lines into T0
;   DATA_PTR invariant: see DO_READ header above.
;   Out: C=0  T0 = 16-bit signed value; DATA_PTR updated
;        C=1  out of data; DATA_PTR set to PE
;   Clobbers: A X Y
; =============================================================================
RD_next_val:
        ; -- if DATA_PTR==0 (reset): start scanning from PROG ----------------
        LDA DATA_PTR
        ORA DATA_PTR+1
        BNE RD_chk_pe
        LDA #>PROG
        STA DATA_PTR+1        ; DATA_PTR lo already 0 (ORA above proved it)
        BRA RD_find          ; DATA_PTR now at first line header; find DATA

        ; -- $0D exhaustion (shared by RD_body and RD_skip_ln below): advance
        ;    past it, then find the next DATA line ---------------------------
RD_exh: JSR INC_DATA_PTR       ; skip $0D
        ; fall through to RD_find (DATA_PTR now at next line header)
        ; -- scan from line header for next DATA line --------------------------
RD_find:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
        BEQ RD_ood           ; hit PE: no more DATA
        JSR DATAPTRADD2       ; skip lineno_lo and hi
        LDA (DATA_PTR)       ; first body token  (65C02 zp-indirect, no Y needed)
        CMP #TOK_DATA
        BEQ RD_found_data
        ; not DATA: scan forward to $0D then try next line
RD_skip_ln:
        LDA (DATA_PTR)       ; 65C02 zp-indirect
        CMP #CR
        BEQ RD_exh           ; share exhaustion advancement
        CMP #TOK_HEX          ; inline number (dec or hex, v15.20): unconditionally
        BCC RD_ADV            ;  skip its 3-byte marker+lo+hi -- must not test lo/hi for $0D
        JSR DATAPTRADD2       ; skip lo/hi payload
RD_ADV:
        JSR INC_DATA_PTR
        BRA RD_skip_ln

        ; -- if DATA_PTR==PE: out of data -------------------------------------
RD_chk_pe:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
        BEQ RD_ood
        ; -- DATA_PTR is inside a DATA body: skip separators ------------------
RD_body:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        CMP #','
        BEQ RD_sep_adv
        CMP #$0D
        BNE RD_parse         ; '-' or TOK_NUM/TOK_HEX: parse it
        BRA RD_exh            ; $0D: exhausted -> shared advance+find

GT_err:
RD_ood: SEC
        RTS

RD_sep_adv:
RD_found_data:
        JSR INC_DATA_PTR       ; skip TOK_DATA byte ? now inside body
        BRA RD_body          ; enter body (may be space/comma at start)

        ; -- parse value at DATA_PTR (v15.20: TOK_NUM/TOK_HEX, not ASCII) -----
RD_parse:
        CMP #'-'             ; Was it a minus sign? (Sets Z flag if true)
        PHP                  ; Push the processor flags to the stack
        BNE RD_pos           ; If not a minus, skip advancing the pointer      
        JSR INC_DATA_PTR     ; Consume '-'
RD_pos: JSR RD_readnum        ; Both paths share the literal read
        PLP                  ; Pull the flags back from the stack
        BNE RD_done          ; If Z flag is 0 (wasn't a minus), skip negation        
        JSR NEG16            ; Negate T0 in place
RD_done:
        CLC                  ; Clear carry (required by both paths)
        RTS


; -- RD_READNUM ? consume a TOK_NUM/TOK_HEX literal at DATA_PTR into T0 ------
;   In:  DATA_PTR  points at the TOK_NUM/TOK_HEX marker byte
;   Out: T0        16-bit value (whichever base it was entered in --
;                   dec/hex both produce the same binary payload)
;        DATA_PTR  advanced past marker+lo+hi (3 bytes)
;   Clobbers: A
RD_readnum:
        JSR INC_DATA_PTR      ; skip the TOK_NUM/TOK_HEX marker byte
        LDA (DATA_PTR)
        STA T0
        JSR INC_DATA_PTR
        LDA (DATA_PTR)
        STA T0+1
        JMP INC_DATA_PTR      ; tail call: its own RTS returns to our caller (-1 byte)

; =============================================================================
; GOTOL ? search program store for a line number; point IP at its body
;   In:  T0   target line number (16-bit)
;   Out: C=0  found: IP points at first token after the 2-byte header
;        C=1  not found (caller should raise ERR_UL)
;   Clobbers: A X Y IP
; =============================================================================
GOTOL:
        STZ IP
        LDA #>PROG
        STA IP+1
GT_sc:  LDX #IP
        LDY #PE
        JSR CMP16
        BEQ GT_err           ; reached end without finding it
GT_go:  LDA (IP)             ; line-number lo  (65C02 zp-indirect, no Y needed)
        CMP T0
        BNE GT_nx
        LDY #1
        LDA (IP),y           ; line-number hi
        CMP T0+1
        BEQ GT_ok
GT_nx:  LDY #2               ; skip to body, scan for $0D
        JSR TOKSKIP_IP
        TYA
        CLC
        ADC IP
        STA IP
        BCC GT_sc
        INC IP+1
        BRA GT_sc
GT_ok:   ; advance IP past 2-byte header
        JSR IPADD2
GT_r:   CLC
        RTS                  ; C=0: found

; =============================================================================
; EAT_EXPR ? skip whitespace, consume one byte, then evaluate an expression
;   Convenience wrapper: WEAT then EXPR.
;   In:  IP   points at optional whitespace then expression
;   Out: T0   expression result;  IP  advanced past expression
;   Clobbers: A X Y T1 T2
; =============================================================================
EAT_EXPR:
        JSR WEAT
        ; drop through
; =============================================================================
; EXPRESSION EVALUATOR  ?  recursive descent, four tiers
;   EXPR     ? Tier 1 (lowest):  AND  OR  XOR
;   EXPR_ADD ? Tier 2:           +  -  and relational  = < > <= >= <>
;   EXPR1    ? Tier 3:           *  /
;   EXPR2    ? Tier 4 (atoms):   literals, variables, unary -, unary +, NOT, ABS, SGN, CHR$, ASC, PEEK, USR, INKEY
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

; =============================================================================
; Relational operator evaluator -- bitmask algorithm
;
;   Operator bitmask accumulated in X:  LT=1  EQ=2  GT=4
;   Left operand (already in T0) saved on hardware stack before scanning.
;   Mask pushed on stack above the left operand after scanning.
;   Right operand evaluated via EXPR_ADD (which is safe: EXPR_ADD/EXPR1/EXPR2
;   do not use the hardware stack for inter-level saves, only local PHA/PLAs
;   that are balanced within each call -- so our saved values are preserved).
;   Signed comparison: N XOR V trick (BVC / EOR #$80 / BMI) -- same technique
;   as the 8088 JL/JG signed branches, no extra scratch storage needed.
;   65C02 opcodes used: LDA (IP) for zero-overhead peek, STZ for REL_F, BRA.
; =============================================================================
REL_MASK: .DB 1, 2, 4        ; bit for <,=,> respectively (indexed by RL_LOOP)
EB_rel:
        ; Save left operand on stack
        LDA T0
        PHA
        LDA T0+1
        PHA

        ; Scan relational operator chars, building bitmask in X.
        ; ASCII '<','=','>' are contiguous ($3C,$3D,$3E); subtract $3C to map
        ; to 0,1,2 and look up the bit via REL_MASK. Out-of-range chars (incl.
        ; wraparound for chars below '<') make SBC/CMP set carry -> BCS exits
        ; without consuming, since only GETCI (not reached) advances IP.
        LDX #0               ; mask = 0
RL_LOOP:
        LDA (IP)             ; peek next char without consuming (65C02 zp-indirect)
        SEC
        SBC #'<'             ; map <,=,> to 0,1,2 (wraps high for chars below '<')
        CMP #3
        BCS RL_DONE          ; not a relational operator: exit loop
        TAY                  ; Y = 0, 1, or 2
        TXA                  ; running mask so far
        .DB $19               ; ORA REL_MASK,y  (opcode $19; assembler lacks the mnemonic form)
        .DW REL_MASK
        TAX
        JSR GETCI            ; consume operator (A = '<'/'='/'>' afterward, never 0)
        BNE RL_LOOP          ; always taken

RL_DONE:
        ; Push mask; evaluate right operand; restore left into T1
        PHX                  ; mask -> stack: mask | left-hi | left-lo | ...
        JSR EXPR_ADD         ; right operand -> T0
        PLA                  ; pop mask -> A
        STA T2               ; stash mask in T2-lo (T2 is free at this point)
        PLA                  ; left hi
        STA T1+1
        PLA                  ; left lo
        STA T1               ; T1=left, T0=right, T2=mask

        ; --- Classify T1 vs T0: produce result bit LT(1)/EQ(2)/GT(4) in A ---

        ; Equality check first (cheaper: two CMPs, no subtract)
        LDX #T1
        LDY #T0
        JSR CMP16
        BNE RL_NOT_EQ
        LDA #2               ; EQ
        BRA RL_TEST

RL_NOT_EQ:
        ; 16-bit signed T1 - T0.  N XOR V = 1 means T1 < T0 (signed less-than).
        ; Trick: if V is set, EOR #$80 flips bit 7 (the N source), so that
        ; BMI always correctly indicates signed less-than regardless of overflow.
        LDA T1
        SEC
        SBC T0
        LDA T1+1
        SBC T0+1
        BVC RL_NO_FLIP
        EOR #$80             ; flip N when V set -> N=1 now reliably means LT
RL_NO_FLIP:
        BMI RL_IS_LT
        LDA #4               ; GT
        BRA RL_TEST

RL_IS_LT:
        LDA #1               ; LT
RL_TEST:
	STZ T0               ; Default False 
	STZ T0+1	     ; 
        AND T2               ; Result bit AND operator mask
        BEQ REL_F            ; No overlap -> false
REL_T:  DEC T0	             ; Set True (-1)
        DEC T0+1	     ; Set True
REL_F:  
        RTS		      

EB_bool:                     ; boolean/bitwise operator loop
        JSR WPEEK
        CMP #TOK_AND
        BEQ EB_and
        CMP #TOK_OR
        BEQ EB_or
        CMP #TOK_XOR
        BEQ EB_xor
        RTS

; AND: bitwise and
EB_and: JSR REL_SETUP
        LDA T1
        AND T0
        STA T0
        LDA T1+1
        AND T0+1
;        STA T0+1
;        BRA EB_bool
        BRA EB_EPILOG

; OR: bitwise or
EB_or:  JSR REL_SETUP
        LDA T1
        ORA T0
        STA T0
        LDA T1+1
        ORA T0+1
;        STA T0+1
;        BRA EB_bool
        BRA EB_EPILOG

; XOR: bitwise exclusive-or
EB_xor: JSR REL_SETUP
        LDA T1
        EOR T0
        STA T0
        LDA T1+1
        EOR T0+1
EB_EPILOG:
        STA T0+1
        BRA EB_bool

; =============================================================================
; REL_SETUP -- shared prologue for AND / OR / XOR operators
;   (Relational operators no longer use REL_SETUP; it is retained for the
;    bitwise boolean operators which call it via EB_and / EB_or / EB_xor.)
;   In:  T0   left operand; IP points at right-operand expression
;        (caller must have consumed the operator token before calling)
;   Out: T1   left operand;  T0   right operand
;   Clobbers: A T1  (hardware stack)
; =============================================================================
REL_SETUP:
        JSR GETCI       ; consume token
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EXPR_ADD
        PLA
        STA T1+1
        PLA
        STA T1
EA_rts: RTS

; =============================================================================
; EXPR_ADD ? Tier 2: addition, subtraction  (also relational dispatch above)
;   Clobbers: A X Y T0 T1 T2  (and anything EXPR1/NEG16 clobber)
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
EA_sum: 
        LDX #(T1-T0)    ; 2
        JSR ADDT0_TO    ; 3
        JSR TO_T0       ; 3 = 8
        BRA EA_lp

; =============================================================================
; EXPR1 ? Tier 3: multiply / divide  (merged sign-handling kernel)
;   Clobbers: A X Y OP T0 T1 T2  (and anything EXPR_POW/MUL16_u/DIV_KERN/
;   NEG16/NEG_T1/TO_T0 clobber)
; =============================================================================
EXPR1:
        JSR EXPR_POW
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
        JSR EXPR_POW         ; right operand -> T0
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

E1_mod_result:
        LDX #(T2-T0)          ; remainder -> T0
        JSR TO_T0
        ; *** FALL THROUGH to E1_SIGN ***
        ; ---- shared sign postamble ----
E1_sign:
        PLA                  ; pull saved sign byte
        BPL E1_pos
        JSR NEG16            ; result should be negative
E1_pos: BRA E1_lp            ; tail jump to loop  (saves 1 RTS)

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
E1_p2:  LDA OP
        CMP #'*'
        BEQ E1_mul_go        ; '*' -> multiply
        ; ---- DIV: T1 = |T1| / |T0|, remainder in T2  ----
        JSR DIV_KERN
        LDA OP               ; MOD: result is remainder (T2), not quotient (T1)
        CMP #'%'
        BEQ E1_mod_result
        LDX #(T1-T0)          ; quotient -> T0
        JSR TO_T0
        BRA E1_sign

E1_mul_go:
        JSR MUL16_u           ; T2 = |T1| * |T0|
        LDX #(T2-T0)          ; result -> T0
        JSR TO_T0
        BRA E1_sign

; =============================================================================
; MUL16_u -- unsigned 16-bit multiply (standalone, self-contained)
;   In:  T0, T1  (both consumed as scratch during the shift-add)
;   Out: T2 = T0 * T1, truncated mod 65536;  T0, T1 left in an undefined state
;   Clobbers: A X Y T0 T1 T2
;   Callers: EXPR1 (signed '*' wrapper does sign handling); EXPR_POW
; =============================================================================
MUL16_u:
        STZ T2               ; clear accumulator
        STZ T2+1
        LDY #16              ; 16-bit iteration count
MU_lp:  LSR T1+1
        ROR T1
        BCC MU_ms
        LDX #(T2-T0)
        JSR ADDT0_TO
MU_ms:  ASL T0
        ROL T0+1
        DEY
        BNE MU_lp
        RTS

; =============================================================================
; DIV_KERN -- unsigned 16-bit restoring divide (standalone, self-contained)
;   In:  T1 = dividend, T0 = divisor  (both unsigned magnitudes)
;   Out: T1 = quotient, T2 = remainder;  T0 unchanged
;   Clobbers: A X Y T1 T2
;   Callers: EXPR1 (signed */,%,MOD wrapper does sign handling); SC_GO
;            (SIN/COS angle-mod-360 reduction)
; =============================================================================
DIV_KERN:
        STZ T2
        STZ T2+1
        LDY #16
DK_lp:  ASL T1
        ROL T1+1
        ROL T2
        ROL T2+1
        LDA T2
        SEC
        SBC T0
        TAX
        LDA T2+1
        SBC T0+1
        BCC DK_ds
        STX T2
        STA T2+1
        INC T1
DK_ds:  DEY
        BNE DK_lp
        RTS

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
        LDA RND_SEED
        STA T0
        LDA RND_SEED+1
        AND #$7F             ; force positive (clear bit 15) ? 1..32767
        STA T0+1
        ; drop through
; RND_SHUFFLE -- advance the 16-bit Galois LFSR one step (tap $B4:
;   x^16+x^14+x^13+x^11+1). Called both from GETCH's keyboard-wait loop
;   Out: RND_SEED advanced  Clobbers: A
RND_SHUFFLE:
         LSR RND_SEED+1
         ROR RND_SEED
         BCC RS_SK
         LDA RND_SEED+1
         EOR #$B4
         STA RND_SEED+1
RS_SK:   RTS

; =============================================================================
; E2_USR ? USR(addr): call machine-code subroutine at addr
;   In:  T0 = addr (consumed centrally by EXPR2_t1 dispatcher)
;   On entry: A = T0 lo byte (low byte of last expression, for parameter passing)
;   Out: T0  (caller sets this before RETURN if returning a value)
;   Clobbers: A X Y (and anything the called routine touches)
; =============================================================================
E2_usr: LDA T0                ; restore documented "A = T0 lo byte" entry invariant
        JMP (T0)            ; tail call

; =============================================================================
; E2_SGN ? SGN(n): sign of n  ?  -1 (negative), 0 (zero), 1 (positive)
; E2_sgn removed (v15.0, space for CORDIC)
; =============================================================================
E2_pos: JSR GETCI            ; unary plus: no-op
        ; drop through
; =============================================================================
; E2_GRP -- generic parenthesized sub-expression: (expr)
;   Distinct from E2_chrs/E2_ARG1: those expect a function TOKEN first,
;   consumed by GETCI, then a '(' consumed by WEAT. Here the '(' itself is
;   what GETCI consumes, so there is no separate opening delimiter left to
;   eat -- go straight to EXPR, then eat the closing ')' (same JMP WEAT
;   tail-call idiom as E2_asc_exit).
;   Was previously routed through E2_chrs, which double-consumed and ate
;   the first byte of the inner expression instead of a delimiter (bug).
;   Clobbers: A T0 (+ whatever EXPR clobbers)
; =============================================================================
E2_grp: JSR GETCI            ; consume '('
        JSR EXPR             ; evaluate inner expression
        JMP WEAT              ; consume ')' and return (tail call, out of BRA range)

; =============================================================================
; EXPR_POW -- Tier 3.5: power (^)
;   Binds tighter than * / % MOD, looser than atoms -- unary -/+/NOT still
;   recurse straight into EXPR2 (unchanged), so they bind tighter than ^
;   too, matching this file's existing atom-tier precedence for them:
;   -2^2 == (-2)^2 == 4, not -(2^2). Left-associative like every other
;   tier (2^3^2 == (2^3)^2 == 64).
;   0^0 == 1 (standard convention). Negative exponent -> ERR_OV (undefined
;   for an integer-only result). Overflow of the 16-bit signed range ->
;   ERR_OV too (checked via one 32767/|base| division before the multiply
;   loop starts, not a silent wraparound like the general '*' operator).
;   Clobbers: A X Y T0 T1 T2 CX CY CZ CX_SAV ATEMP
; =============================================================================
EXPR_POW:
        JSR EXPR2               ; base -> T0
EP_lp:  JSR WPEEK
        CMP #'^'
        BEQ EP_have
        RTS                     ; not '^': loop exit (EP_have is close, no JMP needed)
EP_have:
        JSR GETCI               ; consume '^'
        LDA T0                  ; save base on stack
        PHA
        LDA T0+1
        PHA
        JSR EXPR2               ; exponent -> T0

        LDA T0+1                ; negative exponent: undefined, error
        BPL EP_pos
EP_ovfl:LDA #ERR_OV             ; shared error stub: negative exponent OR
        JMP DO_ERROR            ;   overflow during the multiply loop below

EP_pos: STA CZ+1                ; A still holds T0+1 (exponent hi) from above
        LDA T0
        STA CZ                  ; CZ = exponent (16-bit down-counter)

        ; ATEMP will directly encode "negate the final result": set to the
        ; base's sign, but ONLY if the exponent is odd (even exponent on a
        ; negative base is always positive, no negation needed either way).
        ; LSR here shifts A (still = CZ's low byte, i.e. the exponent's low
        ; byte) right, putting its bit0 (odd/even) into Carry -- and PLA
        ; does not touch Carry, so it survives both pops below intact.
        STZ ATEMP
        LSR                     ; exponent bit0 -> Carry
        PLA                     ; pull base hi (Carry unaffected)
        STA T0+1
        PLA                     ; pull base lo (Carry unaffected)
        STA T0

        BCC EP_abs               ; exponent even: leave ATEMP = 0
        LDA T0+1
        STA ATEMP                ; exponent odd: ATEMP = base's original sign

EP_abs: LDA T0+1
        BPL EP_base_set
        JSR NEG16                ; T0 = |base|

EP_base_set:
        LDA T0                   ; |base| -> CX
        STA CX
        LDA T0+1
        STA CX+1

        LDA #1                   ; result magnitude starts at 1 -> CY
        STA CY
        STZ CY+1

        LDA CZ                   ; exponent == 0 ? result stays 1, done
        ORA CZ+1
        BEQ EP_sign

        LDA CX                   ; base == 0 (exponent>0) ? result is 0, done
        ORA CX+1
        BNE EP_maxsafe
        STZ CY                   ; CY+1 already 0 from init above
        BRA EP_sign

EP_maxsafe:
        ; max_safe = 32767 / |base|  (T0 still holds |base| from EP_base_set,
        ; untouched since -- no need to reload it from CX)
        LDA #<32767
        STA T1
        LDA #>32767
        STA T1+1
        JSR DIV_KERN
        LDA T1
        STA CX_SAV
        LDA T1+1
        STA CX_SAV+1

EP_loop:
        LDA CX_SAV+1             ; overflow check: CY > max_safe ?
        CMP CY+1
        BCC EP_ovfl
        BNE EP_mul
        LDA CX_SAV
        CMP CY
        BCC EP_ovfl
EP_mul: LDX #(CX-T0)             ; CY *= CX  (safe: checked above)
        JSR TO_T0
        LDA CY
        STA T1
        LDA CY+1
        STA T1+1
        JSR MUL16_u
        LDA T2
        STA CY
        LDA T2+1
        STA CY+1

        LDA CZ                   ; exponent counter -= 1 (16-bit)
        BNE EP_dlo
        DEC CZ+1
EP_dlo: DEC                      ; 65C02 DEC A -- A still holds CZ's old low byte
        STA CZ
        ORA CZ+1
        BNE EP_loop

EP_sign:
        LDX #(CY-T0)
        JSR TO_T0

        BIT ATEMP                ; base was negative and exponent was odd?
        BPL EP_done
        JSR NEG16                ; negate the result
EP_done:
        JMP EP_lp                ; loop back for chained ^ (left-associative)

EXPR2:
        JSR WPEEK
        CMP #'('
        BNE EXPR2_ng
        JMP E2_grp
EXPR2_ng:
        CMP #'-'
        BEQ E2_neg
        CMP #'+'
        BNE EXPR2_np
        JMP E2_pos
EXPR2_np:
        CMP #TOK_NOT
        BEQ E2_not
        CMP #TOK_HEX          ; dec or hex literal, v15.20
        BCS PNUM
        CMP #TOK_ASC
        BNE EXPR2_t1
        JMP E2_asc

; =============================================================================
; EXPR2_t1 -- Group A/B function tokens: table-dispatched (v15.17, extended v15.19)
;   TOK_RND..TOK_ACOS ($A4-$AB) are contiguous by design (see TOK_* block).
;   RND (Group B: 0-arg, no parens) sits at FUNC_LO; ABS/PEEK/USR/SIN/COS/
;   ASIN/ACOS (Group A: uniform 1-arg, paren-wrapped) sit immediately above
;   it and are indexed into FUNC_JT. Replaces the old per-token CMP/BEQ chain.
;   Anything below FUNC_LO here is not a function token -> try as variable.
;   No upper-bound check: relies on TOK_NUM ($FF) being intercepted earlier
;   in EXPR2 and nothing else valid sitting above TOK_ACOS. HEX$ was moved
;   below FUNC_LO (v15.19) specifically to preserve this invariant.
; =============================================================================
EXPR2_t1:
        CMP #TOK_RND          ; FUNC_LO
        BCS EXPR2_t1a         ; in range (>= FUNC_LO): continue below
        JMP EXPR2_tvar        ; below range: not a function token, try as variable
EXPR2_t1a:
        BNE EXPR2_t1b          ; != FUNC_LO: not RND, continue below
        JMP E2_rnd              ; == FUNC_LO: RND (0-arg, no parens)
EXPR2_t1b:
        ; else: TOK_ABS..TOK_COS -- consume token + eat '(' expr ')' into T0
        ; centrally (was done per-handler via each's own JSR E2_chrs), then
        ; index into FUNC_JT (word index = (token - TOK_ABS) * 2).
        SEC
        SBC #TOK_ABS
        ASL
        PHA                   ; stash word-index across the recursive JSR E2_chrs below
        JSR E2_chrs            ; consume token, eat '(' expr ')' -> T0
        PLX
        .DB $7C                ; JMP (FUNC_JT,X)  -- 65C02 absolute indexed indirect
        .DW FUNC_JT

FUNC_JT:
        .DW E2_abs, E2_peek, E2_usr, E2_sin, E2_cos, E2_asin, E2_acos  ; TOK_ABS..TOK_ACOS ($A5-$AB)

; =============================================================================
; E2_PEEK ? PEEK(addr): read one byte from memory address  ?  0..255
;   In:  T0 = address (consumed centrally by EXPR2_t1 dispatcher)
;   Clobbers: A T0
; =============================================================================
E2_peek:
        LDA (T0)             ; 65C02 zp-indirect: read memory at addr
        STA T0
        STZ T0+1
        RTS

; =============================================================================
; E2_CHRS ? CHR$(n): numeric ASCII code to character value for PRINT
;   Returns n unchanged in T0; PRINT emits it directly via PUTCH.
;   PRINT-scoped only (v15.17): called directly by DO_PRINT's own TOK_CHRS
;   check, and reused as the shared "consume token, eat (expr)" helper by
;   E2_abs/E2_peek/E2_usr. No longer reachable as a general EXPR2 atom --
;   CHR$() outside a PRINT item is not recognized (smaller binary; TAB has
;   the same PRINT-only scope already).
;   Clobbers: A T0
; =============================================================================
E2_chrs:
        JSR GETCI            ; CHR$(n): result is just n (char value)
        ; drop through
; =============================================================================
; E2_ARG1 ? shared parser helper for single-argument functions
;   In:  IP points at '('
;   Out: T0 = argument value; IP advanced past closing ')'
; =============================================================================
E2_ARG1:
        JSR EAT_EXPR         ; consume '(' then evaluate argument
        ; drop through
; =============================================================================
; WEAT ? skip whitespace, consume (eat) the next byte
;   In:  IP   token stream pointer
;   Out: A    the consumed byte;  IP  advanced one past the first non-space
;   Clobbers: None.
; =============================================================================
WEAT:   JSR WPEEK
        JMP GETCI            ; consume the non-space byte and return  (tail call)

; --- atom handlers (placed here so preamble BEQs above are in range) ---

; NOT: bitwise complement.  No parens (like unary -/+): consume token,
; then recurse straight into EXPR2 for the operand -- do NOT route through
; E2_chrs/E2_ARG1, which assumes a following '(' and would eat one byte
; of the operand instead (this was a real bug: "NOT 0;X" truncated the
; rest of the statement because E2_ARG1's WEAT ate the operand's leading
; byte). Mirrors E2_neg's shape exactly.
E2_not: JSR GETCI    ; consume NOT token
        JSR EXPR2    ; evaluate operand directly (no paren expected)
        LDA T0
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
        RTS

; =============================================================================
; PNUM ? consume an inline $FF lo hi number token from IP, place value in T0
;   In:  IP   points at $FF token  (or whitespace before it)
;   Out: T0   16-bit value  (little-endian)
;        IP   advanced past the 3-byte $FF lo hi sequence
;   Clobbers: A
; =============================================================================
PNUM:   JSR WEAT             ; skip whitespace, consume $FF token
        JSR GETCI            ; fetch lo byte and advance IP
        STA T0
        JSR GETCI            ; fetch hi byte and advance IP
        STA T0+1
        RTS

E2_neg: JSR GETCI            ; unary minus
        JSR EXPR2
        BRA N16TRAMP         ; NEG16 tail call trampoline

; =============================================================================
; SHIFT_R16_T0 -- logical right-shift T0 by X positions (X > 0)
;   In : T0  16-bit value; X = shift count (must be >0)
;   Out: T0  shifted right X times (logical, no sign extension)
;   Clobbers: A X
; =============================================================================
SHIFT_R16_T0:
        LSR T0+1
        ROR T0
        DEX
        BNE SHIFT_R16_T0
E2_abs_pos:
        RTS

; =============================================================================
; E2_ABS ? ABS(n): absolute value of n  ?  n if n=0, else -n
;   In:  T0 = n (consumed centrally by EXPR2_t1 dispatcher)
;   Clobbers: A T0
; =============================================================================
E2_abs: LDA T0+1
        BPL E2_abs_pos
N16TRAMP:
        JMP NEG16            ; tail call: negate if negative

; =============================================================================
; ASR16 -- arithmetic right shift T0 by X positions (X=0..11)
;   In : T0 signed 16-bit; X = count
;   Out: T0 shifted, sign-extended
;   Clobbers: A X
; =============================================================================
ASR16:
        TXA ; CPX #0    ; save 1 byte
        BEQ ASR16_R
ASR16_L:
        LDA T0+1
        ASL                ; sign bit -> C (1 byte; faster than CMP #$80)
        ROR T0+1
        ROR T0
        DEX
        BNE ASR16_L
ASR16_R:
        RTS

; =============================================================================
; CORDIC_KERN -- rotation-mode CORDIC, 12 iterations
;   In : CX=6042, CY=0, CZ=angle_in_CORDIC_units (0..16380 = 0..90 deg)
;   Out: CX = cos*9949, CY = sin*9949  (signed 16-bit)
;   Clobbers: A X T0 T1 CX_SAV CIDX
; =============================================================================
CORDIC_KERN:
        LDX #0
CK_IT:  STX CIDX
        LDA CX
        STA CX_SAV
        LDA CX+1
        STA CX_SAV+1

        ; 1) CX = CX -/+ (CY >> i)
        LDX #(CY-T0)
        JSR TO_T0
        LDX CIDX
        JSR ASR16
        LDA CZ+1
        BMI CK_P1            ; CZ<0: want ADD, skip negate
        JSR NEG16            ; CZ>=0: want SUB, negate T0 then add
CK_P1:  LDX #(CX-T0)
        JSR ADDT0_TO

        ; 2) CY = CY +/- (CX_SAV >> i)
        LDX #(CX_SAV-T0)
        JSR TO_T0
        LDX CIDX
        JSR ASR16
        LDA CZ+1
        BPL CK_P2            ; CZ>=0: want ADD, skip negate
        JSR NEG16            ; CZ<0: want SUB, negate T0 then add
CK_P2:  LDX #(CY-T0)
        JSR ADDT0_TO

        ; 3) CZ = CZ -/+ ATAN_TBL[i]
        LDX CIDX
        TXA
        ASL
        TAX
        LDA ATAN_TBL,x
        STA T0
        LDA ATAN_TBL+1,x
        STA T0+1
        LDA CZ+1
        BMI CK_P3            ; CZ<0: want ADD, skip negate
        JSR NEG16            ; CZ>=0: want SUB, negate T0 then add
CK_P3:  LDX #(CZ-T0)
        JSR ADDT0_TO

        LDX CIDX
        INX
        CPX #12
        BNE CK_IT
        RTS

; =============================================================================
; E2_sin / E2_cos  --  SIN(deg)*1000 / COS(deg)*1000
;   In : T0 = angle in degrees (consumed centrally by EXPR2_t1 dispatcher)
;   Out: T0 = result (signed 16-bit, -1000..+1000)
;   Uses ATEMP as SIN=$00/COS=$80 selector (bit7 encoding -- E2_ASIN/E2_ACOS's
;   bisection loop below reuses this value directly via EOR, so ATEMP must
;   survive the whole call unclobbered); T1 as quadrant negation flags.
;   v15.20: any signed 16-bit angle (negative, or arbitrarily large) is
;   reduced via a single JSR DIV_KERN with divisor 90: Q=|angle|/90 gives
;   the quadrant as Q mod 4 (Y), R=|angle| mod 90 gives the fold angle
;   directly (no separate mod-360 step needed -- 4*90=360, so Y already
;   wraps correctly past 360). Fold = R for even Y, 90-R for odd Y.
;   Quadrant flags (bit0=negate CX/cos, bit1=negate CY/sin) are the Gray
;   code Y EOR (Y>>1): Y=0->00, Y=1->01, Y=2->11, Y=3->10. A final EOR #2
;   flips the CY flag alone for negative input (sin is odd, cos is even).
;   Clobbers: A X Y T0 T1 T2 CX CY CZ CX_SAV CIDX ATEMP
; =============================================================================
E2_cos:
        LDA #$80            ; $80 = COS engine
        STA ATEMP
        .DB $2C             ; BIT abs opcode (skips STZ ATEMP)
E2_sin:
        STZ ATEMP           ; $00 = SIN engine
SC_GO:
        ; ---- mod-90 reduction + quadrant extraction in one DIV_KERN call ----
        ;   Q = |angle|/90, Y = Q mod 4 (quadrant), R = |angle| mod 90 (0..89).
        ;   Since 4*90=360, Y already accounts for angles past 360 too -- no
        ;   separate mod-360 step needed. Fold angle: R when Y even, 90-R
        ;   when Y odd. Quadrant flags (bit0=negate CX/cos, bit1=negate
        ;   CY/sin) are exactly the Gray code Y EOR (Y>>1) -- verified
        ;   against all 4 quadrants: Y=0->00, Y=1->01, Y=2->11, Y=3->10.
        LDA T0+1
        PHA                  ; save original sign (bit 7) for the sin(-x) fixup
        BPL SC_ABS
        JSR NEG16            ; T0 = |angle|
SC_ABS: LDA T0               ; angle -> T1 (dividend for DIV_KERN)
        STA T1
        LDA T0+1
        STA T1+1
        LDA #90              ; 90 -> T0 (divisor)
        STA T0
        STZ T0+1
        JSR DIV_KERN         ; T1 = quotient (Q), T2 = remainder (R)

        LDA T1               ; Q's low byte is all we need
        AND #3               ; Y = Q mod 4  (quadrant)
        TAY

        LDX #(T2-T0)
        JSR TO_T0            ; T0 = R (0..89)

        TYA
        LSR                  ; odd quadrant? (bit0 -> Carry)
        BCC SC_even
        LDA #90              ; odd: fold = 90 - R
        SBC T0               ; Carry is set (from BCC above): exactly 90-T0
        STA T0               ; T0+1 already 0 from TO_T0
SC_even:
        TYA                  ; Gray code: flags = Y EOR (Y>>1)
        STA T1
        LSR
        EOR T1

        PLX                  ; original sign back (65C02 PLX sets N)
        BPL SC_FLAGS
        EOR #2               ; input was negative: sin is odd -> flip CY flag
SC_FLAGS:
        STA T1              ; save quadrant flags
        ; Multiply T0 (0-90) * 182 -> CZ (182=0b10110110)
        LDA #182
        STA T2              ; use T2 as multiplier shift reg
        STZ CZ
        STZ CZ+1
        LDX #8
SC_ML:  LSR T2              ; bit -> C
        BCC SC_MN
        LDX #(CZ-T0)
        JSR ADDT0_TO
SC_MN:  ASL T0
        ROL T0+1
        DEX
        BNE SC_ML
        ; Init CORDIC
        LDA #<6042
        STA CX
        LDA #>6042
        STA CX+1
        STZ CY
        STZ CY+1
        JSR CORDIC_KERN     ; -> CX=cos*9949, CY=sin*9949
        ; Apply quadrant negations from T1
        LSR T1              ; bit0 -> C: negate CX?
        BCC SC_NCX
        LDX #CX-T0
        JSR NEG_X
SC_NCX: LSR T1              ; bit1 -> C: negate CY?
        BCC SC_NCY
        LDX #CY-T0
        JSR NEG_X
SC_NCY:
        ; Result select: ATEMP=0->SIN(CY), ATEMP=$80->COS(CX)
        LDX #(CY-T0)        ; default: SIN
        LDA ATEMP
        BEQ SC_SEL
        LDX #(CX-T0)        ; switch to COS
SC_SEL: JSR TO_T0
SC_SCALE:
        ; Absolute value (preserve sign on stack to avoid clobbering ATEMP)
        LDA T0+1
        PHA                 ; Push sign byte
        BPL SC_SDO
        JSR NEG16           ; make positive for scaling
SC_SDO: ; >>4 (logical; val positive here)
        LDX #4
        JSR SHIFT_R16_T0
        ; *103 -> T2 (16-bit: max 63963)
        LDA #103
        STA T1
        STZ T2
        STZ T2+1
        LDX #8
SC_SML: LSR T1
        BCC SC_SMN
        LDX #(T2-T0)
        JSR ADDT0_TO
SC_SMN: ASL T0
        ROL T0+1
        DEX
        BNE SC_SML
        ; >>6: T0 = T2>>6
        LDX #(T2-T0)
        JSR TO_T0
        LDX #6
        JSR SHIFT_R16_T0
        ; Apply sign
        PLA                 ; Pull sign byte
        BPL SC_DONE
        ; drop through

; =============================================================================
; NEG_T1 / NEG16 ? two's-complement negate T1 or T0  (BIT-trick deduplication)
;   NEG_T1: negate T1  (16-bit)
;   NEG16:  negate T0  (16-bit)
;   In:  T0 or T1  value to negate
;   Out: same location holds 0 - original_value
;   Clobbers: A X
;   NEG_T1: loads X=2, .BYTE $2C skips next 2 bytes, shares body.
;   NEG16:  loads X=0, shares body.
;   NEG_X:  caller pre-loads X with (target_zp - T0), jumps directly to body.
;           e.g. LDX #(CX-T0) / JSR NEG_X  to negate CX in-place.
; =============================================================================
NEG16:
        LDX #0               ; X=0: address offset to T0
        .DB $2C            ; BIT abs  ? consumes next 2 bytes as operand
NEG_T1:
        LDX #2               ; X=2: address offset to T1 from T0
NEG_X:                       ; entry with X pre-loaded by caller
        LDA #0
        SEC
        SBC T0,x
        STA T0,x
        LDA #0
        SBC T0+1,x
        STA T0+1,x
SC_DONE:
        RTS

; =============================================================================
; E2_ASIN / E2_ACOS -- ASIN(v) / ACOS(v), v = -1000..1000 (sin/cos*1000 scale,
; same scale SIN()/COS() use)
;   Out: T0 = angle in degrees. ASIN: signed, -90..90. ACOS: 0..180.
;   No sqrt, no new CORDIC mode: binary-searches an integer degree and
;   reuses SC_GO (the shared SIN/COS body) as the "angle -> scaled value"
;   oracle -- 8 iterations of bisection x the existing 12-iteration CORDIC
;   kernel per call. Result is quantized to the nearest whole degree (same
;   resolution SIN()/COS() themselves use), so ASIN(SIN(d))==d for this
;   engine, modulo CORDIC's own few-unit rounding noise.
;   v15.19: out-of-range v is clamped to +-1000 (not an error), matching
;   SC_GO's own "out of range angle -> return 0" precedent.
;   In:  T0 = v (consumed centrally by EXPR2_t1a dispatcher)
;   Clobbers: A X T0 T1 T2 CX CY CZ CX_SAV CIDX ATEMP AAV ALO AHI AMID AMODE
; =============================================================================
E2_asin:
        LDA #0              ; bit0=0: ASIN
        .DB $2C             ; BIT abs opcode (skips LDA #0)
E2_acos:
        LDA #1              ; bit0=1: ACOS
        STA AMODE
EA_body:
        ; Extract sign, reduce T0 to |v|
        LDA T0+1
        BPL EA_nonneg
        LDA #$80
        TSB AMODE           ; 65C02 TSB: sets bit 7 if input was negative
        JSR NEG16           ; T0 = |v|
EA_nonneg:
        ; -- clamp unsigned T0 to a max of 1000 (was a standalone CLAMP1000
        ;    routine; inlined here since E2_asin/E2_acos is its only caller --
        ;    see the E2_asin header above for the full clobber list) --------
        LDA #<1000
        CMP T0
        LDA #>1000
        SBC T0+1
        BCS CL_ok      ; If Carry is set (no borrow), 1000 >= T0. We are good!

CL_clamp:
        LDA #<1000
        STA T0
        LDA #>1000
        STA T0+1
CL_ok:
;        RTS

        ; Search range: 0..90 for ASIN, 0..180 for ACOS
        LDA AMODE
        LSR                ; bit 0 -> Carry (1=ACOS, 0=ASIN)
        LDA #90
        BCC EA_r_dn
        ASL                ; 90 -> 180
EA_r_dn:
        STA AHI
        STZ ALO

        ; ACOS negative input ($81): invert target sign
        LDA AMODE
        CMP #$81
        BNE EA_target
        JSR NEG16

EA_target:
        LDA T0
        STA AAV
        LDA T0+1
        STA AAV+1

        ; Set ATEMP once: $80 for ACOS, $00 for ASIN
        LDA AMODE
        LSR                ; bit 0 -> Carry
        LDA #0
        ROR                ; Carry -> bit 7 ($80 or $00)
        STA ATEMP

        ; Bisection: 8 iterations
        LDX #8
EA_loop:
        SEC                 ; AMID = ALO + ((AHI-ALO+1) >> 1)
        LDA AHI
        SBC ALO
        INC                ; 65C02 INC A replaces CLC + ADC #1
        LSR
        CLC
        ADC ALO
        STA AMID
        STA T0
        STZ T0+1

        PHX                 ; Preserve loop counter across SC_GO
        JSR SC_GO           ; T0 = scaled sin/cos(AMID), signed
        PLX                 ; Restore loop counter

        ; Unified comparison: D = AAV - T0
        SEC
        LDA AAV
        SBC T0
        STA T1
        LDA AAV+1
        SBC T0+1
        STA T1+1            ; High byte of D
        ORA T1              ; 16-bit zero check
        BEQ EA_feas         ; D == 0 is always feasible

        LDA T1+1
        EOR ATEMP           ; Invert sign bit for ACOS ($80)
        BMI EA_infeas

EA_feas:
        LDA AMID
        STA ALO
        BRA EA_next

EA_infeas:
        LDA AMID
        BEQ EA_next         ; Guard: mid==0
        DEC                ; 65C02 DEC A
        STA AHI

EA_next:
        DEX
        BNE EA_loop

        ; Result: ALO is converged degree
        LDA ALO
        STA T0
        STZ T0+1
        LDA AMODE
        CMP #$80            ; ASIN with negative input is $80
        BNE EA_done
        JMP NEG16           ; Negate result for ASIN

; =============================================================================
; TO_T0 / T0_TO_CURLN / STORE_VAR / ADDT0_TO / GETVARC
;   Size-optimization pass 2: shared bodies for the 16-bit copy/add/store/
;   var-index idioms asmdup.py found repeated across the file. Same NEG_X
;   convention as above (caller pre-loads X with (source_zp - T0); zero-
;   page,X wraps mod 256 so this reaches any zero-page location regardless
;   of how far it sits from T0).
; =============================================================================

; TO_T0 ? copy a 16-bit zero-page value into T0
;   In:  X = (src_zp - T0), pre-loaded by caller
;   Out: T0 = src (16-bit)
;   Clobbers: A
TO_T0:
        LDA T0,x
        STA T0
        LDA T0+1,x
        STA T0+1
EA_done:
        RTS

; T0_TO_CURLN ? copy T0 into CURLN  (fixed src/dst, no X needed)
;   In:  T0
;   Out: CURLN = T0 (16-bit)
;   Clobbers: A
T0_TO_CURLN:
        LDA T0
        STA CURLN
        LDA T0+1
        STA CURLN+1
        RTS

; ADDT0_TO ? add T0 into a 16-bit zero-page accumulator
;   In:  X = (dst_zp - T0), pre-loaded by caller; T0 = addend
;   Out: dst += T0 (16-bit, wraps)
;   Clobbers: A
ADDT0_TO:
        CLC
        LDA T0,x
        ADC T0
        STA T0,x
        LDA T0+1,x
        ADC T0+1
        STA T0+1,x
        RTS

; GETVARC ? read next char, uppercase, subtract 'A'
;   In:  IP (via GETCI)
;   Out: A = char - 'A'  (0-25 if a valid letter; caller checks range/carry)
;        flags set by the SBC (same as inline SEC/SBC #'A' would leave)
;   Clobbers: A
GETVARC:
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        RTS

; CMP16 ? compare two 16-bit zero-page values for equality
;   In:  X = zp addr of A, Y = zp addr of B (both pre-loaded by caller)
;   Out: Z flag set iff A==B (16-bit); same early-exit-on-low-byte-mismatch
;        semantics as the inline LDA/CMP/BNE/LDA/CMP it replaces, so the
;        caller's existing BEQ/BNE after the JSR works unchanged.
;   Clobbers: A Y  (Y is incremented by 1 on the low-byte-equal path, so it
;   no longer holds the caller's "B" address after the call -- reload it
;   before reusing Y as a pointer)
;   Uses ZP0 (permanent $0000 zp pointer) so Y can address B directly via
;   (ZP0),Y -- STA/CMP don't support zp,Y, this is the equivalent trick.
CMP16:
        LDA $00,x
        CMP (ZP0),y
        BNE CMP16_ne
        INY
        LDA $01,x
        CMP (ZP0),y
CMP16_ne:
        RTS

; CMP_T0_LP ? compare 16-bit T0 vs LP for equality, Z set iff equal
;   Same early-exit-on-low-byte-mismatch semantics as the inline code it
;   replaces, so the caller's BEQ/BNE after the JSR works unchanged.
;   Fixed operands (not X/Y-parameterized like CMP16) and does NOT touch
;   Y -- needed because both call sites live inside INSLINE's backward
;   copy loop, which holds Y at a constant 0 for its own (T0),y/(T1),y
;   addressing; CMP16's (ZP0),y trick would clobber that.
;   Clobbers: A
CMP_T0_LP:
        LDA T0
        CMP LP
        BNE CMP_T0_LP_ne
        LDA T0+1
        CMP LP+1
CMP_T0_LP_ne:
        RTS

; =============================================================================
; EXPR2_tvar ? variable or unrecognised atom (BRA from dispatch above)
;   Clobbers: A X T0
; =============================================================================
EXPR2_tvar:
        JSR PARSE_VAR        ; harmless redundant WPEEK_UC re-peek (IP unmoved so far)
        BCC ET_ok            ; C=0: matched
;        JMP E2_bad           ; C=1: no match (E2_bad too far for BCS)
E2_bad: STZ T0               ; unrecognised atom: return 0
        STZ T0+1
        RTS   

ET_ok:  TAX
        LDA VARS,x
        STA T0
        LDA VARS+1,x
        STA T0+1
        RTS

; =============================================================================
; E2_ASC ? ASC("str") or ASC(n): ASCII code of first character
;   String form: ASC("X") ? ASCII value of X.
;   Numeric form: ASC(n) ? n unchanged (identity, for symmetry with CHR$).
;   Clobbers: A T0
; =============================================================================
E2_asc: JSR GETCI            ; ASC("str") or ASC(n)      get token
        JSR WEAT             ; consume '('
        JSR WPEEK            ; peek next char
        CMP #'"'             ; is it a string?
        BEQ E2_asc_str       ; yes -> jump to string handler

        JSR EXPR             ; no -> evaluate as numeric expression
        BRA E2_asc_exit      ; (65C02) skip over string handler

E2_asc_str:
        JSR GETCI            ; consume opening '"'
        JSR GETCI            ; first char -> A
        STA T0               ; save ASCII value to low byte
        STZ T0+1             ; (65C02) zero high byte

E2_asc_sk:
        JSR GETCI            ; consume next char
        CMP #'"'             
        BEQ E2_asc_exit      ; if '"', we are done
        CMP #$0D             
        BNE E2_asc_sk        ; if not CR, keep looping
                             ; if CR, naturally fall through!
E2_asc_exit:
        JMP WEAT             ; consume ')' and return (tail call)

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
        JSR PARSE_VAR
        BCS DO_let_dn
        PHA                  ; save var slot
        JSR WPEEK
        CMP #'='
        BNE DO_let_pop
        JSR GETCI            ; consume '='
        JSR EXPR
        PLX
        ; drop through
; STORE_VAR ? store T0 into VARS[x]
;   In:  T0, X = var slot*2 (pre-loaded by caller, e.g. via PLX or LDX FVAR)
;   Out: VARS[x] = T0 (16-bit)
;   Clobbers: A
STORE_VAR:
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
DO_let_dn:
        RTS

DO_let_pop:
        PLA
        LDA #ERR_UK
        JMP DO_ERROR

; =============================================================================
; PRT16  -  print T0 as a signed decimal integer
;   In:  T0 = signed 16-bit value
;   Out: decimal digits printed to terminal; T0 destroyed
;   Clobbers: A Y T0
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
        .DB $2C                 ; consume Space
        ; drop through
; =============================================================================
; PRTSP ? Print Space
;   Out: Space  emitted to terminal device.
;   Clobbers: A
PRTSP: 
        LDA #' '
        ; drop through
; =============================================================================
; PUTCH ? character output  
;   In:  A    character to send
;   Out: Character emitted to terminal device.
;   Clobbers: None.
; =============================================================================
PUTCH:  STA IO_PUTCH
        RTS

; =============================================================================
; PRT_HEX ? print T0 as 4 upper-case hex digits, MSB first (leading zeros)
;   In:  T0   16-bit value
;   Out: 4 hex characters emitted to terminal
;   Clobbers: A T0
;   PRT_HEXB/PRT_HEXN are shared, byte/nibble-level tail-call helpers:
;   PRT_HEX  -> JSR PRT_HEXB (hi byte) -> falls into PRT_HEXB (lo byte)
;   PRT_HEXB -> JSR PRT_HEXN (hi nibble) -> falls into PRT_HEXN (lo nibble)
;   PRT_HEXN ends with a JMP PUTCH tail call (no RTS needed).
; =============================================================================
PRT_HEX:
        LDA #'$'
        JSR PUTCH
        LDA T0+1
        JSR PRT_HEXB
        LDA T0
        ; drop through: print lo byte
PRT_HEXB:
        PHA
        LSR
        LSR
        LSR
        LSR
        JSR PRT_HEXN
        PLA
        ; drop through: print lo nibble
PRT_HEXN:
        AND #$0F
        ORA #$30              ; '0'..'9' / ':'..'?' for 10-15
        CMP #$3A
        BCC PRT_HEXN_OK
        ADC #$06              ; carry set from CMP above -> 'A'..'F'
PRT_HEXN_OK:
        BRA PUTCH              ; tail call: emit digit and return

; =============================================================================
; SKIP_STMT ? advance IP to the end of the current statement
;   In:  IP   anywhere within a statement's tokens
;   Out: IP   points AT the terminating byte (':' or $0D), not past it
;        C=0  stopped at ':'  (more statements follow on this line)
;        C=1  stopped at $0D  (end of line)
;   Clobbers: A
; =============================================================================
SKIP_STMT:
        LDA (IP)
        CMP #':'
        BEQ SKST_colon
        CMP #$0D
        BEQ SKST_eol
        CMP #TOK_HEX          ; dec or hex literal, v15.20
        BCC SKST_adv          ; If not a number, skip ahead to the single increment
        JSR IPADD2            ; If it IS a number, skip the 2 extra bytes first
SKST_adv:
        JSR INC_IP            ; Shared increment (applies to all non-terminal tokens)
        BRA SKIP_STMT

; -----------------------------------------------------------------------------
; PARSE_VAR ? parse a single A-Z variable letter at (IP) into a VARS offset
;   In:  IP   points at the variable letter (may be preceded by whitespace)
;   Out: C=0  matched: A = VARS byte offset (0,2,4,...50); IP advanced past it
;        C=1  no match: A,IP unchanged (other than WPEEK_UC's non-destructive peek)
;   Clobbers: A
; =============================================================================
PARSE_VAR:
        JSR WPEEK_UC
        CMP #'A'
        BCC PV_fail
        CMP #'Z'+1
        BCS PV_fail
        JSR GETVARC
        ASL                  ; x2: byte offset into VARS
SKST_colon:
        CLC
        RTS
SKST_eol:
PV_fail:
        SEC
        RTS

; =============================================================================
; WPEEK_UC ? skip whitespace, peek next byte, uppercase it
;   In:  IP   token stream pointer
;   Out: A    first non-space byte, uppercased;  IP  unchanged
;   Clobbers: None.
;
; UC ? convert A to uppercase if it is a lowercase ASCII letter
;   In:  A    any byte
;   Out: A    uppercased (a-z ? A-Z); all other bytes unchanged
;   Clobbers: None.  (flags are affected)
; =============================================================================
WPEEK_UC:
        JSR WPEEK
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
;   Clobbers: None.
; =============================================================================
WPEEK:  LDA (IP)             ; 65C02: PEEKC inlined for speed
        CMP #' '
        BNE WPEEK_d
        JSR GETCI
        BRA WPEEK
        
; -----------------------------------------------------------------------------
; TOKSKIP_LP/IP ? scan (LP),Y for $0D, skipping TOK_NUM payloads
;   In:  Y   starting offset (caller sets it, e.g. LDY #2 to skip a header)
;   Out: Y   offset just past the $0D
;   Clobbers: A
; =============================================================================
TOKSKIP_LP:
TSLP:   LDA (LP),y
        INY
        CMP #TOK_HEX          ; dec or hex literal, v15.20
        BCC TSLP_chk
        INY
        INY
;        BRA TSLP ; not needed as A is a token
TSLP_chk:
        CMP #$0D
        BNE TSLP
        RTS

; TOKSKIP_IP ? identical, but via (IP),Y
;   In:  Y   starting offset (caller sets it)
;   Out: Y   offset just past the $0D
;   Clobbers: A
TOKSKIP_IP:
TSIP:   LDA (IP),y
        INY
        CMP #TOK_HEX          ; dec or hex literal, v15.20
        BCC TSIP_chk
        INY
        INY
;        BRA TSIP ; not needed as A is a token
TSIP_chk:
        CMP #$0D
        BNE TSIP
        RTS

; =============================================================================
; DO_ELSE_SK -- bare ELSE at statement level: skip rest of line
;   Reached via STMT_JT when ELSE appears as a bare statement (i.e. the false
;   branch of IF already consumed the THEN body and RUNLP calls STMT again,
;   which sees ELSE first).  We simply discard everything to end-of-line.
;
; SKIPEOL ? advance IP past the $0D end-of-line marker
;   In:  IP   anywhere in the current token stream line
;   Out: IP   points at first byte of the next line
;   Clobbers: A
; =============================================================================
DO_ELSE_SK:
SKIPEOL:
        JSR SKIP_STMT         ; C=0 at ':', C=1 at $0D
        JSR INC_IP              ; advance past whichever terminator we stopped at
        BCC SKIPEOL            ; ':' -> more statements on this line: keep scanning
        RTS                     ; $0D -> IP now points past it

; =============================================================================
; I/O stubs ? Kowalski simulator virtual terminal
; =============================================================================
; GETCH ? blocking character input
;   In:  None.
;   Out: A    character received
;   Clobbers: None.
GETCH:  JSR RND_SHUFFLE
        LDA IO_GETCH         ; poll Kowalski virtual port
        BEQ GETCH             ; 0 = no char yet: spin
        RTS

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;   Triggered by: write any value to IO_IRQ ($E007) in the simulator.
;   If RUN != 0  (program is executing):
;       Clear RUN, GRET, FSTK; restore stack to RUNSP; print BREAK; -> MAIN.
;       Program store is left intact -- the user can LIST or re-RUN.
;   If RUN == 0  (idle at prompt): silently ignored (RTI).
;   Called via hardware IRQ: CPU has already pushed PC-hi, PC-lo, P onto stack
;   and cleared the I flag.  We must not use RTS/JMP back -- either RTI (idle)
;   or we restore the stack ourselves and JMP MAIN (running).
;   Clobbers: A X  (stack is being deliberately abandoned when running)
; =============================================================================
IRQ_HANDLER:
        LDA RUN              ; running?
        BEQ IRQ_idle         ; no: ignore
        CLD
        STZ GRET             ; clear GOSUB nesting depth
        STZ FSTK             ; clear FOR nesting depth
        LDX RUNSP            ; restore stack pointer (unwinds all call frames)
        TXS
        LDA #<STR_BREAK
        JSR PUTSTR           ; "\r\nBREAK" (no trailing CRLF -- shared exit provides it)
        JMP DO_break_in      ; -> print " IN line\r\n", re-enable IRQs, back to MAIN
IRQ_idle:
        RTI                  ; idle: silently ignore

; =============================================================================
; DATA TABLES  (no page constraint ? placed here after main code)
; CORDIC atan table: atan(2^-i) in units where 16384 = 90 degrees
; Value[i] = round(16384 * atan(2^-i) / 90).  12 entries x 2 bytes = 24 bytes.
ATAN_TBL:
        .DW 8192, 4836, 2555, 1297, 651, 326, 163, 81, 41, 20, 10, 5

ROMEND = *                   ; first byte after executable ROM code 

; =============================================================================
; Vector page notes:
        .ORG $FFFC
        .DW INIT             ; RESET vector
