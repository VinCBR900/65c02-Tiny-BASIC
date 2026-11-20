; =============================================================================
; 4K Integer BASIC v15.34 for the 65C02
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; A fully-featured, self-contained integer Tiny BASIC interpreter in 4 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; LIST to view, NEW to clear and enter your own program).
;
; Credit to Oscar Toledo for his x86 BootBASIC inspiration.
;
; USAGE
;   Assemble : asm65c02 4kBASIC65c02.asm       (ROM $F000-$FFFF, showcase image at $0200)
;   Simulate : sim65c02 4kBASIC65c02.asm       (terminal I/O at $E000/$E001/$E004, see below)
;   At the '>' prompt: type a numbered line to store it, or a bare statement to run it
;   immediately. RUN starts the program, LIST shows it, NEW clears it, FREE shows the
;   RAM left. The pre-loaded showcase starts out as the stored program.
; =============================================================================
; Statements:
;   PRINT [item [; item ...]]
;            item = "string" | TAB(n) | CHR$(n) | expression
;            ';' between items suppresses newline; trailing ';' suppresses final CR
;   IF expr THEN stmt [ELSE stmt2]   single-line; ELSE is optional
;   FOR var = start TO end [STEP n]  ...  NEXT var
;   GOTO expr          branch to line (expr may be a literal, variable, or
;                      any other expression)
;   GOSUB expr         call subroutine at line (same); RETURN to resume
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
;
;   Multi-statement:   ':' separates statements on one line.
;
; Expressions  (left to right within a level):
;   Level 1: =  <>  <  >  <=  >=   one comparison (-1 true, 0 false); or
;            AND  OR  XOR          bitwise, chained left to right
;            (one level: a comparison and AND/OR/XOR do not chain; parenthesise each side)
;   Level 2: +  -
;   Level 3: *  /  %  MOD          (% and MOD give the remainder)
;   Level 4: ^                     (power; see EXPR_POW)
;   Level 5 (atoms): literal  variable  (expr)  -expr  +expr  NOT expr
;                    ABS(n)              absolute value
;                    SGN(n)              sign of n: -1, 0, or +1
;                    SIN(deg)            sine   * 1000  (0-360 degrees, CORDIC)
;                    COS(deg)            cosine * 1000  (0-360 degrees, CORDIC)
;                    ASIN(v)             arcsine   of v*1000, -90..90 degrees
;                    ACOS(v)             arccosine of v*1000, 0..180 degrees
;                    TAB(n)              print n spaces (PRINT only; expr argument)
;                    CHR$(n)             character with ASCII code n  (PRINT only)
;                    HEX$(n)             n as 4-digit hex, MSB first  (PRINT only)
;                    PEEK(addr)          read byte from memory address
;                    USR(addr)           call machine-code subroutine, A = low byte of T0
;                    RND                 pseudo-random 0..32767 (no argument)
; Numbers:     signed 16-bit integers  -32768 .. 32767
;              decimal, or hex literal $HHHH (1-4 hex digits)
; Variables:   A .. Z  (26 x 2-byte, zero-page)
; Line range:  1 .. 32767
;
; KNOWN LIMITATIONS
;
; Comparisons and AND/OR/XOR sit at one level and do not chain with each other:
;   IF A=1 AND B=2 ignores everything from AND on. Parenthesise each side:
;   IF (A=1) AND (B=2).
;
; ASIN(x)/ACOS(x) clamp |x| >= 1000 to the boundary (not an error).
;
; ^ (power): a negative exponent, or a result outside -32768..32767, raises OV ERR
;   (checked before the multiply loop; the general * wraps silently instead).
;
; DATA must be the sole statement on its line (only the line's first token is checked).
;
; FOR nesting is limited to 4 levels and GOSUB nesting to 8; one more raises NR ERR.
;   A FOR may share a line with other statements and FORs may be chained, e.g.
;   FOR I=1 TO 2: FOR J=1 TO 3.
;
; NEXT's variable name is not checked: NEXT closes the innermost open FOR whatever
;   name (or none) follows it.
;
; RETURN does not restore the line number: an error later on the SAME line as the GOSUB
;   is reported "IN" the subroutine's last line. GOTO/GOSUB cope: a stale line number
;   only costs a slower search from the start of the program.
;
; A backward GOTO/GOSUB (target line <= the current line) searches from the start of the
;   program; forward targets search ahead from the current line. Either search hops from
;   line to line by the stored length byte, so a long program costs lines, not bytes.
;
; A stored line is <lo> <hi> <len> <tokens> $00. <len> is one byte (the whole record,
;   header and NUL included). 
;
; Tokenised output can be longer than its input (a bare "$" becomes 3 bytes, a leading
;   line number is always 3): a line that tokenises to more than IBUF_MAX+1 bytes runs
;   past TBUF into IBUF and crashes.
;
; PRINT; (semicolon directly after PRINT, no item) evaluates an empty expression and
;   prints 0; bare PRINT, PRINT: and PRINT ELSE print a blank line.
;
; Input line limit is IBUF_MAX (41) characters; IBUF and TBUF are IBUF_MAX+1 bytes (NUL
;   included). Each key past the limit sounds BELL and is discarded: not stored, not
;   echoed, and the buffer position does not advance.
;
; GOTO/GOSUB executed directly from the prompt (not from a running program) corrupt
;   execution once the target line finishes.
;
; Error codes  (printed as  XX ERR [IN line]):
;   SN  syntax / bad expression
;   UL  undefined line number
;   OV  division by zero; ^ with a negative exponent or overflowing result
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
;   NOTE: Real system likely requiree UART setup - bytes free to do so.
;
; Routine headers give In / Out / Clobbers. Clobbers lists the registers and scratch cells
;   a routine (or anything it calls) may change; documented outputs are not repeated.
;   EXPR = A X Y T0 T1 T2 OP and the CORDIC/ASIN scratch CX CY CZ CX_SAV CIDX ATEMP AAV
;   ALO AHI AMID AMODE (the scratch overlays IBUF).
;
; =============================================================================
; TOKEN ENCODING
;
; Number literals encoded as below:
;   0-9        1 byte:  ascii digit itself, no marker
;   10-255     2 bytes: TOK_BYTE ($FD) + value
;   256-65535  3 bytes: TOK_NUM ($FF) + lo + hi
;   hex $HHHH  3 bytes: TOK_HEX ($FE) + lo + hi   
;   leading line number: always the 3-byte TOK_NUM form, whatever its value (TOKENIZE sees
;     that nothing is emitted yet: T1 still at <TBUF), so MAIN and EDITLN need no change.
;
; LIST reflects storage: a 0-9 literal lists as a bare digit with no trailing space; the
;   other literals list with one. Small constants next to a keyword can therefore look
;   cramped (e.g. "1TO") but re-tokenise identically.
;
; SHARED RAM OVERLAYS 
; Overlaid on IBUF (18 bytes of zero page):
;   - CX CY CZ CX_SAV CIDX ATEMP AAV ALO AHI AMID AMODE LP (1 bytes) 
;     CORDIC and ASIN/ACOS never live when getline is. LP is list/edit/FOR-NEXT-frame pointer
;
; =============================================================================
; CHANGE HISTORY
;
; v15.34 (Nov 2026) - 3 ROM bytes free - COMPACT CONSTANTS + RAM OVERLAY + CORDIC SPEED
;   - Constant literals encoded for compact single digits (See above), Showcase regenerated 
;     for new encoding. Token numbering closed up to eliminate dead space.
;   - RAM overlay (See above) 
;   - Size/speed pass, RUN saves SP once per run and tests end-of-program inline; NEXT loops
;     back without a scan; EXPR_ADD/EXPR1 return A = (IP), take single digits and variables
;     inline, and EXPR_ADD subtracts inline; MUL16_U and GT_SC inlined; DIV_KERN keeps 
;     remainder in A for divisors < 256; ERR_TABLE moved tostring page so DO_ERROR prints 
;     using PUTSTR; shared RD_CURLN/IPADD3/ADD_IP and LP_HOP; GETCI replaced by INC_IP;
;   - Removed SHL/SHR IRQ_HANDLER for space. 
;   - FIXED unary +: EXPR2 consumes the "+" and re-dispatches on the operand (+5, +A, 3++4 were
;     misparsed as "(" ")" pairs, which could swallow the rest of the line). 
;   - CORDIC speed pass: new CK_SH copies and shifts in one loop with the high byte in A 
;     and replaces TO_T0 + ASR16 in the loop; ASR16 removed 
;   - 8 x 8 multiply fast path: MUL16_U takes a fixed 8-pass shift-right multiply when both
;     operands are < 256, with no swap.

; v15.33 (Nov 2026) - 29 bytes free - EXECUTION SPEED: INLINING PASS
;   Speed only, behaviour unchanged (+84 bytes ROM). Inlined: RUNLP CMP16, RD_CURLN and
;   SKIPEOL fast path; DO_NEXT CMP16; EXPR1's EXPR_POW front and variable-atom fast path;
;   DO_LET PARSE_VAR. RUN_LINE now ends in JMP RUNGO.
;   Instructions per pass v15.32 -> v15.33: empty FOR/NEXT 342 -> ~297 (-13%), nested loops
;   3859 -> 3351 (-13%), expression loop 944 -> 841 (-11%), GOSUB/RETURN 627 -> 571 (-9%).

; v15.32 (Nov 2026) - 113 bytes free - FIX: NEXT STACK LEAK
;   Bug reportedby SOCI on 6502.org: FOR/NEXT on multi statement line memory leak. 
;   (10 FOR A=0 TO 100:PRINT A:NEXT) Fix: DN_SAMEL leaves IP at the ':' and RTSes into 
;   ST_SEP. No stack growth, works inimmediate mode

; v15.31 (Nov 2026) - 108 bytes free - LINE FORMAT + SIZE PASS
;   - Lines stored as <lo> <hi> <len> <tokens> $00 (was <lo> <hi> <tokens> $0D). NUL line
;     ends (-56). GOTO/GOSUB search, DELINE, EDITLN, LIST and DATA/READ hop by <len>;
;     TOKSKIP_LP removed. Backward GOTO in a 40-line program 8973 -> 1283 instructions,
;     forward 9446 -> 1748.
;   - TRYKW is one pass over KW_TABLE (-24); DELINE is a forward copy (-25); the tokenizer
;     saves a call via PHA/PLA (-3).
;   - Fixes: IP is parked on a NUL after RUN/END (a stale ':' in free RAM ran as a statement);
;     an unterminated PRINT string no longer consumes the line's NUL.
;   - Showcase image +99 bytes (one <len> per line); it lives in RAM.

; v15.30 (Nov 2026) - 1 byte free - EXECUTION SPEED + FIXES
;   Instructions per iteration v15.29 -> v15.30: FOR/NEXT + assignment 705 -> 344, expression-
;   heavy 1762 -> 946, NEXT in a 40-line program 9058 -> 346, GOSUB 20 lines ahead 17982 ->
;   696, REM skip 11095 -> 1558, 16x16 multiply 883 -> 490, divide by 7 932 -> 579.
;   - FOR frame is 9 bytes: it saves the IP past the FOR clause, so NEXT no longer re-runs
;     GOTOL. FOR may share a line and FORs may chain.
;   - GOTOL scans forward from the current line when the target is ahead. MUL16_U swaps to
;     the smaller multiplier and exits early; DIV_KERN uses 8 passes when the dividend's high
;     byte < divisor.
;   - EXPR2 tests numbers and variables first; PNUM and PARSE_VAR inlined; WPEEK/WPEEK_UC/
;     WEAT removed; DO_REM scans with TOKSKIP_IP; FSTK_BASE needs no CLC.
;   - Fixes: INPUT always raised UK ERR (IP and CURLN now saved on the hardware stack);
;     REM text starting with ':' ran as a statement; GOSUB stack held 1 level (now 8);
;     showcase DATA line was raw ASCII; bare PRINT: and PRINT ELSE printed a spurious 0.
;   - Removed DPEEK/DPOKE.
;   - Showcase: banner, lines 71-79 and 81 (MUL/DIV, chained FOR, bare PRINT:, forward
;     GOTO, REM:, backward GOTO); ~300 bytes of RAM.

; v15.29 (Sep 2026) - 34 bytes free - Golf Pass
;   - BBR deployed. Added DPEEK/DPOKE (removed in v15.30).
;   - Showcase: SGN, SHL, SHR, HEX$ and all relational operators.

; v15.28 (Aug 2026) - 61 bytes free - FUNCTIONALITY FIX
;   Replaced EAT_EXPR with EXPECT_EQ/EXPECT_TO/EXPECT_COMMA/EXPECT_LPAREN +
;   shared EXPECT. EAT_EXPR consumed the next byte via WEAT unconditionally,
;   never checking it matched the expected delimiter

; v15.27 (Aug 2026) - 86 bytes free 
;   - E1_shl/E1_shr share one prologue (E1_sh_pre); SHIFT_L16_T0 inlined
;     into E1_shl (its only caller). +24 bytes.
;   - DBL_CURLN: shared "double CURLN", replacing 3+4 occurrences in
;     TKPNUM/TKPHEX. +2 bytes.
;   - EMIT_CURLN: shared "emit CURLN's 2 bytes", replacing 1+1 occurrences
;     in TOKENIZE. +4 bytes.

; v15.26 (Aug 2026) - 55 bytes free 
;   - PROG2IP/PROG2P: shared "reset ZP pointer pair to PROG", replacing 5
;     duplicate sites (DO_RUN, DO_NEW, LS_SCAN, GOTOL, EDITLN). Byte-
;     neutral as built; kept for the single source of truth.
;   - EDITLN's line-number comparison reworked to reuse one CMP's flags
;     across both branch decisions, reaching exact-match by fall-through.

; v15.25 (Aug 2026) - 51 bytes free 
;   Traded ASC for SGN + SHL/SHR.
;   - Removed ASC: only real use was ASC() of a string literal (no string
;     variables exist). KW_TABLE slot ($99) is a placeholder byte, not a
;     deletion -- token values are assigned by table position. +51 bytes.
;   - Added SGN(n): restored into its old placeholder slot (TOK_SGN=$A3,
;     removed v15.0). Branchless via existing ASR16 sign-extension.
;   - Added SHL/SHR: new tokens TOK_SHL/TOK_SHR ($AC/$AD). Not folded into
;     E1_MD's shared path (wrong semantics for a shift). SHR reuses ASR16;
;     SHL used a new SHIFT_L16_T0 (later inlined, v15.27). +83 bytes.
;

; v15.24 (Aug 2026) - 110 bytes free - CORRECTNESS FIX
;   E1_MD stashed the */,/,%/MOD operator in a fixed ZP byte (OP) across
;   its own recursive JSR EXPR_POW -- a parenthesized right operand with
;   another */,/,%/MOD clobbered it before the outer op was read back,
;   e.g. PRINT 2*(10/5) printed 1, not 4. Fixed by holding the operator
;   on the hardware stack across the recursive call instead. Byte-neutral.

; v15.23 (Aug 2026) - 110 bytes free 
;   Size-reduction pass, ported/adapted from uBASIC6502 techniques.
;   - E2_NOT: reuses NEG16 via -(x+1) instead of its own EOR #$FF pair.
;   - Pooled ERR_SN (DO_FOR -> RD_SN) and ERR_OV (E1_DIVCHK_OVFL ->
;     EP_OVFL), same pattern as the existing ERR_NR/ERR_UL pooling.
;   - RD_CURLN: shared CURLN-header read, replacing identical code in
;     DO_RUN and DO_NEXT.
;   - EB_AND/EB_OR/EB_XOR rewritten to share one combine loop via a
;     BIT-trick ($2C) entry chain and REL_SETUP, mirroring uBASIC6502's
;     BITOP2_PREFIX/BITOP_LP.

; v15.22 (Aug 2026) - 73 bytes free 
;   - EXPR_POW (EP_MUL, EP_SIGN): two inline 16-bit copies into T0 (from CX,
;     from CY) converted to the shared TO_T0 helper.
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
;     DO_PRINT dispatches it directly via CMP, reusing E2_CHRS to parse
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
;   - E2_SIN/E2_COS angle-fold/negate/scale pipeline reviewed and rewritten
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
;   - RD_uint/RD_NEXT_VAL: shared $0D-exhaustion handling between RD_BODY
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
;   Keywords    $80-$A7  (single byte)
;   Numbers     ascii digit 0-9 (1 byte) | $FD <value> (10-255) | $FF <lo> <hi>
;   Hex numbers $FE <lo> <hi>
;   Strings     passed through as-is, including the surrounding quotes
;   End-of-line $00 (NUL). Payload bytes may be $00 too, so every scanner skips the payload
;               after $FD/$FE/$FF and never tests it.
;   TBUF holds  $FF <lo> <hi> <tokenised_body> $00  for a numbered line being entered.
; Program storage line format:
;   <lineno_lo> <lineno_hi> <len> <tokenised_body> $00
;   <len> = total record length in bytes (3 header + body + NUL); next line = this line + <len>.
;   Records are packed back to back from PROG up to PE.

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

; ---- token codes  ($80-$A7 keywords; $FD-$FF inline numbers) ------------------
; Statements: contiguous block $80..$92 (19 entries), dispatched via STMT_JT.
; Expr atoms: $93..$A7.  LET ($9A) is also checked by STMT as a fallback.
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
TOK_DATA    = $8F            ; DATA val, val, ...
TOK_READ    = $90            ; READ var
TOK_RESTORE = $91            ; RESTORE
TOK_ELSE    = $92            ; ELSE
; ---- expression-atom tokens: $93..$A7 (never in STMT_JT) -------------------
; Function tokens are contiguous for table dispatch: Group B (RND, 0-arg) at $A0,
; Group A (ABS PEEK USR SIN COS ASIN ACOS, 1-arg) at $A1-$A7. Infix ops (AND OR
; XOR MOD), statement-context keywords (STEP TO LET THEN) and the PRINT-only
; CHR$ TAB HEX$ are checked individually. TRYKW/DO_LIST derive token<->text
; from KW_TABLE position.
TOK_STEP    = $93            ; STEP
TOK_TO      = $94            ; TO
TOK_CHRS    = $95            ; CHR$(n)  (PRINT-only)
TOK_AND     = $96            ; AND
TOK_OR      = $97            ; OR
TOK_NOT     = $98            ; NOT expr
TOK_XOR     = $99            ; XOR
TOK_LET     = $9A            ; LET
TOK_THEN    = $9B            ; THEN
TOK_TAB     = $9C            ; TAB(n)  (PRINT-only)
TOK_MOD     = $9D            ; MOD
TOK_HEXS    = $9E            ; HEX$(n)  4-digit hex, PRINT-only
TOK_SGN     = $9F            ; SGN(n)
; ---- Group B (0-arg, no parens) -- FUNC_JT dispatch starts here (FUNC_LO) --
TOK_RND     = $A0            ; RND
; ---- Group A (uniform 1-arg, paren-wrapped) -- FUNC_JT indices 0..6 --------
TOK_ABS     = $A1            ; ABS(n)
TOK_PEEK    = $A2            ; PEEK(addr)
TOK_USR     = $A3            ; USR(addr)
TOK_SIN     = $A4            ; SIN(deg) -> deg*1000 (0-360)
TOK_COS     = $A5            ; COS(deg) -> deg*1000 (0-360)
TOK_ASIN    = $A6            ; ASIN(v)  v in -1000..1000 -> degrees -90..90
TOK_ACOS    = $A7            ; ACOS(v)  v in -1000..1000 -> degrees 0..180
TOK_FEND    = $A8            ; first non-function token; EXPR2_T1B rejects >= TOK_FEND
TOK_BYTE    = $FD            ; inline 8-bit unsigned constant (10-255) follows
TOK_HEX     = $FE            ; inline 16-bit unsigned hex literal follows, e.g. $1234
TOK_NUM     = $FF            ; inline 16-bit number follows

; ---- error codes  (lo byte of the 2-char string in ERR_TABLE, on the string page)
ERR_SN   = <ERR_TABLE        ; syntax error
ERR_UL   = <ERR_TABLE+2      ; undefined line number
ERR_OV   = <ERR_TABLE+4      ; division by zero
ERR_OM   = <ERR_TABLE+6      ; out of memory
ERR_NR   = <ERR_TABLE+8      ; nesting error
ERR_ST   = <ERR_TABLE+10     ; zero STEP
ERR_UK   = <ERR_TABLE+12     ; unknown statement
ERR_OD   = <ERR_TABLE+14     ; out of DATA

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
; FVAR,FLIM,FSTEP,FIP,CURLN are contiguous
; on purpose: DO_FOR copies this 9-byte block into
; a FOR_STK frame with one indexed loop instead of
; unrolled stores (CURLN already holds the correct
; loop_line value, so no separate copy is needed).
FVAR     = $02               ;  8-bit: FOR staging: var_slot (VARS offset)
FLIM:
        .RS 2                ; 16-bit: FOR staging: limit
FSTEP:
        .RS 2                ; 16-bit: FOR staging: step
FIP:
        .RS 2                ; 16-bit: FOR staging: IP just past the FOR clause (NEXT resumes here)
CURLN:
        .RS 2                ; 16-bit: current executing line number
; LP is overlaid on IBUF (defined below); see RAM OVERLAY ANALYSIS in the header.
T0:
        .RS 2                ; 16-bit: expression result / scratch 0
T1:
        .RS 2                ; 16-bit: scratch 1
T2:
        .RS 2                ; 16-bit: scratch 2
PE:
        .DW SHOWCASE_END     ; 16-bit: program end (pre-loaded: the end of the showcase image)
GRET:
        .RS 1                ;  8-bit: GOSUB nesting depth
RUN:
        .RS 1                ;  8-bit: 0 = idle, $FF = running
GORET:
        .RS 16               ; 16 bytes: GOSUB return stack (8 levels x 2)
TKTOK:
        .RS 1                ;  8-bit: TRYKW keyword index
FSTK:
        .RS 1                ;  8-bit: FOR nesting depth
FOR_STK:
        .RS 36               ; 36 bytes: 4 FOR frames x 9
FOR_FRSZ = 9                 ; bytes per FOR frame
RUNSP:
        .RS 1                ;  8-bit: saved SP for stack unwind
OP:
        .RS 1                ;  8-bit: MUL/DIV operator ('*' or '/')
DATA_PTR:
        .RS 2                ; 16-bit: pointer to next DATA value to READ
RND_SEED:
        .DW $ACE1            ; 16-bit: LFSR seed for RND (pre-loaded; NEW reseeds it)

; CX..AMODE (CORDIC and ASIN/ACOS bisection scratch) are overlaid on IBUF below;
; see RAM OVERLAY ANALYSIS in the header. ATEMP is the SIN/COS selector ($00 / $80):
; E2_ASIN/E2_ACOS preset it and SC_GO reads it on every bisection step.

; ZP0 - permanent $0000 pointer for (zp),Y addressing. Zero in the RAM image (and
;   cleared by DO_NEW) and never written, so (ZP0),Y always resolves to
;   address Y itself: lets CMP16 etc. use Y as a direct zero-page address.
ZP0:
        .RS 2

; Buffers/BASIC VARS
VARS:
        .RS 52                ; 52 bytes: A-Z variables
TBUF:
        .RS IBUF_MAX+1        ; Tokenised buffer
IBUF:
        .RS IBUF_MAX+1        ; Raw input buffer

; RAM overlay: CORDIC and ASIN/ACOS bisection scratch (16 bytes) share the first 16
; bytes of IBUF. IBUF is live only from the first keystroke through TOKENIZE; this
; scratch is live only while a SIN/COS/ASIN/ACOS/^ is evaluated, i.e. during
; statement execution. See RAM OVERLAY ANALYSIS in the header.
CX       = IBUF+0             ; 16-bit: CORDIC X accumulator
CY       = IBUF+2             ; 16-bit: CORDIC Y accumulator
CZ       = IBUF+4             ; 16-bit: CORDIC Z angle accumulator
CX_SAV   = IBUF+6             ; 16-bit: saved CX per iteration
CIDX     = IBUF+8             ;  8-bit: CORDIC iteration counter
ATEMP    = IBUF+9             ;  8-bit: angle quadrant temp
AAV      = IBUF+10            ; 16-bit: target value v, signed
ALO      = IBUF+12            ;  8-bit: bisection low bound (degrees)
AHI      = IBUF+13            ;  8-bit: bisection high bound (degrees)
AMID     = IBUF+14            ;  8-bit: current midpoint candidate (degrees)
AMODE    = IBUF+15            ;  8-bit: bit0 0=ASIN/1=ACOS; bit7 orig sign of v

; RAM overlay: LP (list/edit/FOR-NEXT scratch pointer) sits at IBUF+16, clear of the
; group above. Safe for the same reason: DO_FOR sets LP only after its expressions
; are evaluated, and DO_NEXT evaluates none while LP is in use.
LP       = IBUF+16            ; 16-bit: list/edit/scratch pointer

ZPEND    = *                    ; audit

; =============================================================================
; PRE-LOADED SHOWCASE  (program storage at $0200)
; Self-checking program exercising:
;   PRINT / CHR$ / REM / ABS / SGN / HEX$ / MOD / NOT / AND / OR / XOR / RND
;   PEEK / POKE / DATA / READ / RESTORE / FOR / NEXT / STEP (incl. negative)
;   IF / THEN / ELSE / GOSUB / RETURN / forward and backward GOTO
;   all relational operators; signed MUL/DIV incl. 16-bit wrap and remainder sign;
;   chained FOR on one line; bare PRINT:; REM starting with a colon.
;   Expected: MUL -84 900 -2786 | DIV -42 100 -6 | 123246 | CHAINED FOR OK | ... | ...OK 3
; Mandelbrot renderer (lines 600+): fixed-point integer arithmetic; validates the
;   expression evaluator, nested FOR and GOTO; GOSUB from line 600, IF/THEN/ELSE per pixel.
;   Real axis C: -128..16 step 4  (37 columns)
;   Imag axis I:  -64..56 step 6  (21 rows)
;   Max 16 iterations; CHR$(E+32) for escaped pixels, space inside.
; Integer spiral vortex (lines 750-1150): SIN/COS/ASIN/ACOS plot.
; =============================================================================
        .ORG $0200
        .DB $0A, $00, $1F, $89, $20, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $33, $34, $20, $53, $48, $4F, $57, $43, $41, $53, $45, $00  ; 10 REM  4K BASIC v15.34 SHOWCASE
        .DB $14, $00, $1C, $80, $22, $3D, $3D, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $33, $34, $20, $3D, $3D, $22, $00  ; 20 PRINT "== 4K BASIC v15.34 =="
        .DB $1E, $00, $1E, $80, $22, $43, $48, $52, $22, $3B, $95, $28, $FD, $24, $29, $3B, $22, $28, $36, $35, $29, $3D, $22, $3B, $95, $28, $FD, $41, $29, $00  ; 30 PRINT "CHR";CHR$(36);"(65)=";CHR$(65)
        .DB $28, $00, $29, $80, $22, $31, $37, $20, $4D, $4F, $44, $20, $35, $3D, $22, $3B, $FD, $11, $9D, $35, $3B, $22, $20, $20, $41, $42, $53, $20, $6E, $65, $67, $37, $3D, $22, $3B, $A1, $28, $2D, $37, $29, $00  ; 40 PRINT "17 MOD 5=";17 MOD 5;"  ABS neg7=";ABS(-7)
        .DB $32, $00, $21, $80, $22, $4E, $4F, $54, $20, $30, $3D, $22, $3B, $98, $30, $3B, $22, $20, $20, $36, $20, $41, $4E, $44, $20, $33, $3D, $22, $3B, $36, $96, $33, $00  ; 50 PRINT "NOT 0=";NOT 0;"  6 AND 3=";6 AND 3
        .DB $3C, $00, $23, $80, $22, $35, $20, $4F, $52, $20, $32, $3D, $22, $3B, $35, $97, $32, $3B, $22, $20, $20, $37, $20, $58, $4F, $52, $20, $33, $3D, $22, $3B, $37, $99, $33, $00  ; 60 PRINT "5 OR 2=";5 OR 2;"  7 XOR 3=";7 XOR 3
        .DB $41, $00, $15, $80, $22, $53, $47, $4E, $28, $2D, $35, $29, $3D, $22, $3B, $9F, $28, $2D, $35, $29, $00  ; 65 PRINT "SGN(-5)=";SGN(-5)
        .DB $42, $00, $17, $80, $22, $48, $45, $58, $24, $28, $32, $35, $35, $29, $3D, $22, $3B, $9E, $28, $FD, $FF, $29, $00  ; 66 PRINT "HEX$(255)=";HEX$(255)
        .DB $43, $00, $20, $80, $22, $35, $3C, $31, $30, $3D, $22, $3B, $35, $3C, $FD, $0A, $3B, $22, $20, $20, $35, $3C, $3E, $33, $3D, $22, $3B, $35, $3C, $3E, $33, $00  ; 67 PRINT "5<10=";5<10;"  5<>3=";5<>3
        .DB $44, $00, $20, $80, $22, $33, $3C, $3D, $33, $3D, $22, $3B, $33, $3C, $3D, $33, $3B, $22, $20, $20, $35, $3E, $3D, $36, $3D, $22, $3B, $35, $3E, $3D, $36, $00  ; 68 PRINT "3<=3=";3<=3;"  5>=6=";5>=6
        .DB $45, $00, $1C, $80, $22, $2B, $35, $3D, $22, $3B, $2B, $35, $3B, $22, $20, $20, $33, $2B, $2B, $34, $3D, $22, $3B, $33, $2B, $2B, $34, $00  ; 69 PRINT "+5=";+5;"  3++4=";3++4
        .DB $46, $00, $17, $80, $22, $52, $4E, $44, $20, $4D, $4F, $44, $20, $31, $30, $3D, $22, $3B, $A0, $9D, $FD, $0A, $00  ; 70 PRINT "RND MOD 10=";RND MOD 10
        .DB $47, $00, $3B, $80, $22, $4D, $55, $4C, $20, $31, $32, $2A, $2D, $37, $3D, $22, $3B, $FD, $0C, $2A, $28, $2D, $37, $29, $3B, $22, $20, $33, $2A, $33, $30, $30, $3D, $22, $3B, $33, $2A, $FF, $2C, $01, $3B, $22, $20, $32, $35, $30, $2A, $32, $35, $31, $3D, $22, $3B, $FD, $FA, $2A, $FD, $FB, $00  ; 71 PRINT "MUL 12*-7=";12*(-7);" 3*300=";3*300;" 250*251=";250*251
        .DB $48, $00, $47, $80, $22, $44, $49, $56, $20, $2D, $33, $30, $30, $2F, $37, $3D, $22, $3B, $2D, $FF, $2C, $01, $2F, $37, $3B, $22, $20, $33, $30, $30, $30, $30, $2F, $33, $30, $30, $3D, $22, $3B, $FF, $30, $75, $2F, $FF, $2C, $01, $3B, $22, $20, $33, $30, $30, $20, $4D, $4F, $44, $20, $2D, $37, $3D, $22, $3B, $FF, $2C, $01, $9D, $28, $2D, $37, $29, $00  ; 72 PRINT "DIV -300/7=";-300/7;" 30000/300=";30000/300;" 300 MOD -7=";300 MOD(-7)
        .DB $49, $00, $11, $8B, $49, $3D, $31, $94, $32, $3A, $8B, $4A, $3D, $31, $94, $33, $00  ; 73 FOR I=1 TO 2:FOR J=1 TO 3
        .DB $4A, $00, $09, $80, $49, $2A, $4A, $3B, $00  ; 74 PRINT I*J;
        .DB $4B, $00, $09, $8C, $4A, $3A, $8C, $49, $00  ; 75 NEXT J:NEXT I
        .DB $4C, $00, $1B, $80, $3A, $80, $22, $43, $48, $41, $49, $4E, $45, $44, $20, $46, $4F, $52, $20, $4F, $4B, $22, $3A, $82, $FD, $4E, $00  ; 76 PRINT :PRINT "CHAINED FOR OK":GOTO 78
        .DB $4D, $00, $13, $80, $22, $42, $41, $44, $20, $46, $57, $44, $20, $47, $4F, $54, $4F, $22, $00  ; 77 PRINT "BAD FWD GOTO"
        .DB $4E, $00, $16, $89, $20, $3A, $50, $52, $49, $4E, $54, $20, $22, $42, $41, $44, $20, $52, $45, $4D, $22, $00  ; 78 REM :PRINT "BAD REM"
        .DB $4F, $00, $12, $51, $3D, $51, $2B, $31, $3A, $81, $51, $3C, $33, $9B, $82, $FD, $4F, $00  ; 79 Q=Q+1:IF Q<3 THEN GOTO 79
        .DB $50, $00, $1B, $8E, $FE, $FF, $00, $2C, $FD, $2A, $3A, $80, $22, $50, $4F, $4B, $45, $3D, $22, $3B, $A2, $28, $FE, $FF, $00, $29, $00  ; 80 POKE $00FF,42:PRINT "POKE=";PEEK($00FF)
        .DB $51, $00, $26, $80, $22, $42, $41, $43, $4B, $20, $47, $4F, $54, $4F, $2C, $20, $46, $57, $44, $20, $47, $4F, $54, $4F, $2C, $20, $52, $45, $4D, $3A, $20, $4F, $4B, $20, $22, $3B, $51, $00  ; 81 PRINT "BACK GOTO, FWD GOTO, REM: OK ";Q
        .DB $52, $00, $2E, $5A, $3D, $30, $3A, $8B, $59, $3D, $31, $94, $FD, $64, $3A, $5A, $3D, $5A, $2B, $31, $3A, $8C, $3A, $80, $22, $46, $4F, $52, $3A, $4E, $45, $58, $54, $20, $78, $31, $30, $30, $20, $4F, $4B, $20, $22, $3B, $5A, $00  ; 82 Z=0:FOR Y=1 TO 100:Z=Z+1:NEXT:PRINT "FOR:NEXT x100 OK ";Z
        .DB $5A, $00, $24, $90, $41, $2C, $42, $2C, $43, $3A, $80, $22, $44, $41, $54, $41, $20, $20, $22, $3B, $41, $3B, $22, $20, $20, $22, $3B, $42, $3B, $22, $20, $20, $22, $3B, $43, $00  ; 90 READ A,B,C:PRINT "DATA  ";A;"  ";B;"  ";C
        .DB $64, $00, $18, $91, $3A, $90, $41, $3A, $80, $22, $52, $45, $53, $54, $4F, $52, $45, $20, $41, $3D, $22, $3B, $41, $00  ; 100 RESTORE :READ A:PRINT "RESTORE A=";A
        .DB $6E, $00, $0E, $8F, $FD, $6F, $2C, $FD, $DE, $2C, $FF, $4D, $01, $00  ; 110 DATA 111,222,333
        .DB $78, $00, $0A, $8B, $49, $3D, $31, $94, $35, $00  ; 120 FOR I=1 TO 5
        .DB $82, $00, $07, $80, $49, $3B, $00  ; 130 PRINT I;
        .DB $8C, $00, $06, $8C, $49, $00  ; 140 NEXT I
        .DB $96, $00, $05, $80, $00  ; 150 PRINT
        .DB $A0, $00, $0E, $8B, $49, $3D, $FD, $0A, $94, $31, $93, $2D, $33, $00  ; 160 FOR I=10 TO 1 STEP -3
        .DB $AA, $00, $07, $80, $49, $3B, $00  ; 170 PRINT I;
        .DB $B4, $00, $06, $8C, $49, $00  ; 180 NEXT I
        .DB $BE, $00, $05, $80, $00  ; 190 PRINT
        .DB $C8, $00, $13, $81, $33, $3E, $31, $9B, $80, $22, $49, $46, $20, $74, $72, $75, $65, $22, $00  ; 200 IF 3>1 THEN PRINT "IF true"
        .DB $D2, $00, $1C, $81, $31, $3E, $33, $9B, $80, $22, $57, $52, $4F, $4E, $47, $22, $92, $80, $22, $45, $4C, $53, $45, $20, $6F, $6B, $22, $00  ; 210 IF 1>3 THEN PRINT "WRONG"ELSE PRINT "ELSE ok"
        .DB $DC, $00, $08, $83, $FF, $F4, $01, $00  ; 220 GOSUB 500
        .DB $E6, $00, $23, $89, $20, $20, $73, $69, $6E, $65, $20, $77, $61, $76, $65, $20, $20, $54, $41, $42, $28, $32, $30, $2B, $53, $49, $4E, $28, $58, $29, $2F, $35, $30, $29, $00  ; 230 REM  sine wave  TAB(20+SIN(X)/50)
        .DB $F0, $00, $0F, $8B, $58, $3D, $30, $94, $FF, $67, $01, $93, $FD, $0F, $00  ; 240 FOR X=0 TO 359 STEP 15
        .DB $FA, $00, $16, $80, $9C, $28, $FD, $14, $2B, $A4, $28, $58, $29, $2F, $FD, $32, $29, $3B, $22, $2A, $22, $00  ; 250 PRINT TAB(20+SIN(X)/50);"*"
        .DB $04, $01, $06, $8C, $58, $00  ; 260 NEXT X
        .DB $0E, $01, $08, $82, $FF, $58, $02, $00  ; 270 GOTO 600
        .DB $18, $01, $05, $8A, $00  ; 280 END
        .DB $F4, $01, $11, $80, $22, $47, $4F, $53, $55, $42, $20, $6F, $6B, $22, $3A, $84, $00  ; 500 PRINT "GOSUB ok":RETURN
        .DB $58, $02, $0F, $8B, $49, $3D, $2D, $FD, $40, $94, $FD, $38, $93, $36, $00  ; 600 FOR I=-64 TO 56 STEP 6
        .DB $62, $02, $07, $44, $3D, $49, $00  ; 610 D=I
        .DB $6C, $02, $0F, $8B, $43, $3D, $2D, $FD, $80, $94, $FD, $10, $93, $34, $00  ; 620 FOR C=-128 TO 16 STEP 4
        .DB $76, $02, $0F, $41, $3D, $43, $3A, $42, $3D, $44, $3A, $45, $3D, $30, $00  ; 630 A=C:B=D:E=0
        .DB $80, $02, $0B, $8B, $4E, $3D, $31, $94, $FD, $10, $00  ; 640 FOR N=1 TO 16
        .DB $8A, $02, $0D, $81, $45, $3E, $30, $9B, $82, $FF, $A8, $02, $00  ; 650 IF E>0 THEN GOTO 680
        .DB $94, $02, $15, $54, $3D, $41, $2A, $41, $2F, $FD, $40, $2D, $42, $2A, $42, $2F, $FD, $40, $2B, $43, $00  ; 660 T=A*A/64-B*B/64+C
        .DB $9E, $02, $14, $42, $3D, $32, $2A, $41, $2A, $42, $2F, $FD, $40, $2B, $44, $3A, $41, $3D, $54, $00  ; 670 B=2*A*B/64+D:A=T
        .DB $A8, $02, $1F, $81, $45, $3D, $30, $9B, $81, $41, $2A, $41, $2F, $FD, $40, $2B, $42, $2A, $42, $2F, $FD, $40, $3E, $FF, $00, $01, $9B, $45, $3D, $4E, $00  ; 680 IF E=0 THEN IF A*A/64+B*B/64>256 THEN E=N
        .DB $B2, $02, $06, $8C, $4E, $00  ; 690 NEXT N
        .DB $BC, $02, $1A, $81, $45, $3E, $30, $9B, $80, $95, $28, $45, $2B, $FD, $20, $29, $3B, $92, $80, $95, $28, $FD, $20, $29, $3B, $00  ; 700 IF E>0 THEN PRINT CHR$(E+32);ELSE PRINT CHR$(32);
        .DB $C6, $02, $06, $8C, $43, $00  ; 710 NEXT C
        .DB $D0, $02, $07, $80, $22, $22, $00  ; 720 PRINT ""
        .DB $DA, $02, $06, $8C, $49, $00  ; 730 NEXT I
        .DB $EE, $02, $32, $80, $22, $3D, $3D, $3D, $20, $52, $65, $6E, $64, $65, $72, $20, $31, $36, $2D, $42, $69, $74, $20, $49, $6E, $74, $65, $67, $65, $72, $20, $53, $70, $69, $72, $61, $6C, $20, $56, $6F, $72, $74, $65, $78, $20, $3D, $3D, $3D, $22, $00  ; 750 PRINT "=== Render 16-Bit Integer Spiral Vortex ==="
        .DB $F8, $02, $34, $80, $22, $54, $45, $53, $54, $53, $3A, $20, $53, $49, $4E, $2C, $20, $43, $4F, $53, $2C, $20, $41, $53, $49, $4E, $2C, $20, $41, $43, $4F, $53, $20, $28, $4E, $4F, $20, $53, $51, $52, $54, $2F, $54, $41, $4E, $2F, $41, $54, $4E, $29, $22, $00  ; 760 PRINT "TESTS: SIN, COS, ASIN, ACOS (NO SQRT/TAN/ATN)"
        .DB $02, $03, $3C, $89, $20, $4C, $20, $54, $52, $41, $43, $4B, $53, $20, $4C, $41, $53, $54, $20, $43, $4F, $4C, $55, $4D, $4E, $20, $53, $49, $4E, $43, $45, $20, $54, $41, $42, $28, $6E, $29, $20, $48, $45, $52, $45, $20, $50, $52, $49, $4E, $54, $53, $20, $6E, $20, $73, $70, $61, $63, $65, $73, $00  ; 770 REM L TRACKS LAST COLUMN SINCE TAB(n) HERE PRINTS n spaces
        .DB $20, $03, $33, $89, $20, $48, $20, $41, $4E, $44, $20, $56, $20, $43, $4F, $4E, $53, $54, $41, $4E, $54, $53, $20, $48, $41, $52, $44, $43, $4F, $44, $45, $44, $20, $54, $4F, $20, $53, $41, $56, $45, $20, $56, $41, $52, $49, $41, $42, $4C, $45, $53, $00  ; 800 REM H AND V CONSTANTS HARDCODED TO SAVE VARIABLES
        .DB $2A, $03, $0B, $8B, $52, $3D, $30, $94, $FD, $1A, $00  ; 810 FOR R=0 TO 26
        .DB $34, $03, $08, $9A, $4C, $3D, $30, $00  ; 820 LET L=0
        .DB $3E, $03, $0B, $8B, $43, $3D, $30, $94, $FD, $3C, $00  ; 830 FOR C=0 TO 60
        .DB $48, $03, $0B, $9A, $58, $3D, $43, $2D, $FD, $1E, $00  ; 840 LET X=C-30
        .DB $52, $03, $33, $89, $20, $53, $43, $41, $4C, $45, $20, $59, $20, $42, $59, $20, $32, $20, $46, $4F, $52, $20, $41, $53, $43, $49, $49, $20, $43, $48, $41, $52, $41, $43, $54, $45, $52, $20, $41, $53, $50, $45, $43, $54, $20, $52, $41, $54, $49, $4F, $00  ; 850 REM SCALE Y BY 2 FOR ASCII CHARACTER ASPECT RATIO
        .DB $5C, $03, $0F, $9A, $59, $3D, $28, $52, $2D, $FD, $0D, $29, $2A, $32, $00  ; 860 LET Y=(R-13)*2
        .DB $66, $03, $33, $89, $20, $27, $44, $27, $20, $49, $53, $20, $53, $51, $55, $41, $52, $45, $44, $20, $44, $49, $53, $54, $41, $4E, $43, $45, $2E, $20, $41, $56, $4F, $49, $44, $53, $20, $4E, $45, $45, $44, $49, $4E, $47, $20, $53, $51, $52, $54, $21, $00  ; 870 REM 'D' IS SQUARED DISTANCE. AVOIDS NEEDING SQRT!
        .DB $70, $03, $0E, $9A, $44, $3D, $58, $5E, $32, $2B, $59, $5E, $32, $00  ; 880 LET D=X^2+Y^2
        .DB $7A, $03, $0F, $81, $44, $3E, $FF, $84, $03, $9B, $82, $FF, $60, $04, $00  ; 890 IF D>900 THEN GOTO 1120
        .DB $84, $03, $34, $89, $20, $53, $43, $41, $4C, $45, $20, $54, $4F, $20, $2D, $31, $30, $30, $30, $20, $54, $4F, $20, $2B, $31, $30, $30, $30, $20, $52, $41, $4E, $47, $45, $20, $46, $4F, $52, $20, $49, $4E, $56, $45, $52, $53, $45, $20, $54, $52, $49, $47, $00  ; 900 REM SCALE TO -1000 TO +1000 RANGE FOR INVERSE TRIG
        .DB $8E, $03, $3A, $89, $20, $33, $30, $2A, $31, $30, $30, $30, $3D, $33, $30, $30, $30, $30, $20, $57, $48, $49, $43, $48, $20, $53, $41, $46, $45, $4C, $59, $20, $46, $49, $54, $53, $20, $49, $4E, $20, $31, $36, $2D, $42, $49, $54, $20, $53, $49, $47, $4E, $45, $44, $20, $49, $4E, $54, $00  ; 910 REM 30*1000=30000 WHICH SAFELY FITS IN 16-BIT SIGNED INT
        .DB $98, $03, $11, $9A, $55, $3D, $28, $58, $2A, $FF, $E8, $03, $29, $2F, $FD, $1E, $00  ; 920 LET U=(X*1000)/30
        .DB $A2, $03, $11, $9A, $57, $3D, $28, $59, $2A, $FF, $E8, $03, $29, $2F, $FD, $1E, $00  ; 930 LET W=(Y*1000)/30
        .DB $AC, $03, $2A, $89, $20, $2D, $2D, $2D, $20, $54, $45, $53, $54, $20, $41, $53, $49, $4E, $2F, $41, $43, $4F, $53, $20, $43, $4F, $4F, $52, $44, $20, $4D, $41, $50, $50, $49, $4E, $47, $20, $2D, $2D, $2D, $00  ; 940 REM --- TEST ASIN/ACOS COORD MAPPING ---
        .DB $B6, $03, $0B, $9A, $45, $3D, $A6, $28, $55, $29, $00  ; 950 LET E=ASIN(U)
        .DB $C0, $03, $0B, $9A, $46, $3D, $A7, $28, $57, $29, $00  ; 960 LET F=ACOS(W)
        .DB $CA, $03, $21, $89, $20, $2D, $2D, $2D, $20, $54, $45, $53, $54, $20, $43, $4F, $52, $44, $49, $43, $20, $53, $49, $4E, $2F, $43, $4F, $53, $20, $2D, $2D, $2D, $00  ; 970 REM --- TEST CORDIC SIN/COS ---
        .DB $D4, $03, $3A, $89, $20, $4D, $55, $4C, $54, $49, $50, $4C, $59, $20, $44, $20, $54, $4F, $20, $4D, $41, $4B, $45, $20, $52, $49, $4E, $47, $53, $2C, $20, $53, $55, $42, $54, $52, $41, $43, $54, $20, $41, $4E, $47, $4C, $45, $53, $20, $46, $4F, $52, $20, $53, $50, $49, $52, $41, $4C, $00  ; 980 REM MULTIPLY D TO MAKE RINGS, SUBTRACT ANGLES FOR SPIRAL
        .DB $DE, $03, $11, $9A, $49, $3D, $A4, $28, $44, $2A, $32, $2D, $45, $2A, $35, $29, $00  ; 990 LET I=SIN(D*2-E*5)
        .DB $E8, $03, $0F, $9A, $4A, $3D, $A5, $28, $44, $2B, $46, $2A, $33, $29, $00  ; 1000 LET J=COS(D+F*3)
        .DB $F2, $03, $1F, $89, $20, $2D, $2D, $2D, $20, $4E, $45, $53, $54, $45, $44, $20, $54, $52, $49, $47, $20, $54, $45, $53, $54, $53, $20, $2D, $2D, $2D, $00  ; 1010 REM --- NESTED TRIG TESTS ---
        .DB $FC, $03, $3A, $89, $20, $49, $20, $41, $4E, $44, $20, $4A, $20, $41, $52, $45, $20, $2D, $31, $30, $30, $30, $20, $54, $4F, $20, $2B, $31, $30, $30, $30, $2C, $20, $50, $45, $52, $46, $45, $43, $54, $20, $46, $4F, $52, $20, $49, $4E, $56, $45, $52, $53, $45, $20, $54, $52, $49, $47, $00  ; 1020 REM I AND J ARE -1000 TO +1000, PERFECT FOR INVERSE TRIG
        .DB $06, $04, $0B, $9A, $41, $3D, $A6, $28, $4A, $29, $00  ; 1030 LET A=ASIN(J)
        .DB $10, $04, $0B, $9A, $42, $3D, $A7, $28, $49, $29, $00  ; 1040 LET B=ACOS(I)
        .DB $1A, $04, $35, $89, $20, $2D, $2D, $2D, $20, $4D, $41, $54, $48, $20, $53, $48, $41, $44, $45, $20, $56, $41, $4C, $55, $45, $20, $28, $52, $45, $53, $55, $4C, $54, $53, $20, $49, $4E, $20, $30, $20, $54, $4F, $20, $7E, $32, $37, $30, $29, $20, $2D, $2D, $2D, $00  ; 1050 REM --- MATH SHADE VALUE (RESULTS IN 0 TO ~270) ---
        .DB $24, $04, $0D, $9A, $5A, $3D, $A1, $28, $41, $2D, $42, $29, $00  ; 1060 LET Z=ABS(A-B)
        .DB $2E, $04, $20, $89, $20, $2D, $2D, $2D, $20, $4D, $41, $50, $20, $54, $4F, $20, $41, $53, $43, $49, $49, $20, $43, $48, $41, $52, $53, $20, $2D, $2D, $2D, $00  ; 1070 REM --- MAP TO ASCII CHARS ---
        .DB $38, $04, $09, $9A, $53, $3D, $FD, $20, $00  ; 1080 LET S=32
        .DB $3D, $04, $0F, $81, $5A, $3E, $FD, $1E, $9B, $9A, $53, $3D, $FD, $2E, $00  ; 1085 IF Z>30 THEN LET S=46
        .DB $42, $04, $0F, $81, $5A, $3E, $FD, $46, $9B, $9A, $53, $3D, $FD, $2B, $00  ; 1090 IF Z>70 THEN LET S=43
        .DB $47, $04, $0F, $81, $5A, $3E, $FD, $6E, $9B, $9A, $53, $3D, $FD, $4F, $00  ; 1095 IF Z>110 THEN LET S=79
        .DB $4C, $04, $0F, $81, $5A, $3E, $FD, $96, $9B, $9A, $53, $3D, $FD, $40, $00  ; 1100 IF Z>150 THEN LET S=64
        .DB $51, $04, $11, $80, $9C, $28, $43, $2D, $4C, $29, $3B, $95, $28, $53, $29, $3B, $00  ; 1105 PRINT TAB(C-L);CHR$(S);
        .DB $56, $04, $0A, $9A, $4C, $3D, $43, $2B, $31, $00  ; 1110 LET L=C+1
        .DB $60, $04, $06, $8C, $43, $00  ; 1120 NEXT C
        .DB $6A, $04, $05, $80, $00  ; 1130 PRINT
        .DB $74, $04, $06, $8C, $52, $00  ; 1140 NEXT R
        .DB $7E, $04, $05, $8A, $00  ; 1150 END
SHOWCASE_END = *               ; end of the showcase image: initial PE

; =============================================================================
        .ORG $F000      ; 4 KB ROM
; STRING TABLE (all strings on same page)
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/kw addresses
STR_BANNER:
        .DB "4K BASIC v15.34"
STR_CRLF:
        .DB $0D,$8A                 ; CR, LF|$80 = $8A
STR_BYTES:
        .DB " BYTES FREE",$0D,$8A      ; last LF has high-bit
STR_ERROR:
        .DB " ER",$D2               ; 'R'|$80 = $D2
STR_IN:
        .DB " IN ",$A0              ; last space|$80 = $A0

; =============================================================================
; Keyword string table  (chars only; bit 7 set on last char marks end of entry)
; No length byte, no NUL.  $00 sentinel terminates whole table.
; TRYKW, KW_NEXT and DO_LIST detect end-of-entry via bit 7.
; High-bit values = last_char | $80 (e.g. 'T'=$54 -> $D4, '$'=$24 -> $A4)
; Order MUST match token values: entry[0] = TOK_PRINT ($80), entry[1] = TOK_IF ($81) ...
KW_TABLE:
; ---- statement tokens $80..$92 (must appear first in this order) ------------
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
        .DB "DAT",$C1         ; $8F TOK_DATA    ('A'|$80=$C1)
        .DB "REA",$C4         ; $90 TOK_READ    ('D'|$80=$C4)
        .DB "RESTOR",$C5      ; $91 TOK_RESTORE ('E'|$80=$C5)
        .DB "ELS",$C5         ; $92 TOK_ELSE    ('E'|$80=$C5)
; ---- expression-atom tokens $93..$A7 (in KW_TABLE for the tokeniser only) ------
; Token value = table position. Group B (RND) and Group A (ABS PEEK USR SIN COS
; ASIN ACOS) are contiguous at $A0-$A7 for FUNC_JT dispatch.
        .DB "STE",$D0         ; $93 TOK_STEP    ('P'|$80=$D0)
        .DB "T",$CF           ; $94 TOK_TO      ('O'|$80=$CF)
        .DB "CHR",$A4         ; $95 TOK_CHRS    ('$'|$80=$A4)  PRINT-only
        .DB "AN",$C4          ; $96 TOK_AND     ('D'|$80=$C4)
        .DB "O",$D2           ; $97 TOK_OR      ('R'|$80=$D2)
        .DB "NO",$D4          ; $98 TOK_NOT     ('T'|$80=$D4)
        .DB "XO",$D2          ; $99 TOK_XOR     ('R'|$80=$D2)
        .DB "LE",$D4          ; $9A TOK_LET     ('T'|$80=$D4)
        .DB "THE",$CE         ; $9B TOK_THEN    ('N'|$80=$CE)
        .DB "TA",$C2          ; $9C TOK_TAB     ('B'|$80=$C2)
        .DB "MO",$C4          ; $9D TOK_MOD     ('D'|$80=$C4)
        .DB "HEX",$A4         ; $9E TOK_HEXS    ('$'|$80=$A4)  PRINT-only
        .DB "SG",$CE          ; $9F TOK_SGN     ('N'|$80=$CE)
        .DB "RN",$C4          ; $A0 TOK_RND     ('D'|$80=$C4)  Group B: 0-arg, FUNC_LO
        .DB "AB",$D3          ; $A1 TOK_ABS     ('S'|$80=$D3)  Group A: FUNC_JT[0]
        .DB "PEE",$CB         ; $A2 TOK_PEEK    ('K'|$80=$CB)  Group A: FUNC_JT[1]
        .DB "US",$D2          ; $A3 TOK_USR     ('R'|$80=$D2)  Group A: FUNC_JT[2]
        .DB "SI",$CE          ; $A4 TOK_SIN     ('N'|$80=$CE)  Group A: FUNC_JT[3]
        .DB "CO",$D3          ; $A5 TOK_COS     ('S'|$80=$D3)  Group A: FUNC_JT[4]
        .DB "ASI",$CE         ; $A6 TOK_ASIN    ('N'|$80=$CE)  Group A: FUNC_JT[5]
        .DB "ACO",$D3         ; $A7 TOK_ACOS    ('S'|$80=$D3)  Group A: FUNC_JT[6]
        .DB 0                 ; end-of-table sentinel

; Error code table: 2-char codes in PUTSTR format (last char | $80), so DO_ERROR
; prints one with PUTSTR. Must stay on the string page. ERR_xx = lo byte of entry.
ERR_TABLE:
        .DB "S",$CE           ; "SN"  syntax error
        .DB "U",$CC           ; "UL"  undefined line number
        .DB "O",$D6           ; "OV"  division by zero
        .DB "O",$CD           ; "OM"  out of memory
        .DB "N",$D2           ; "NR"  nesting error
        .DB "S",$D4           ; "ST"  zero STEP
        .DB "U",$CB           ; "UK"  unknown statement
        .DB "O",$C4           ; "OD"  out of DATA

; Statement dispatch table (used by STMT via JMP (STMT_JT,X)).
; Entry order matches token values TOK_PRINT ($80) .. TOK_ELSE ($92).
; The ELSE handler (index 18) calls SKIPEOL to discard the rest of the line.
STMT_JT:
        .DW DO_PRINT,   DO_IF,      DO_GOTO,    DO_GOSUB,  DO_RETURN  ; $80-$84
        .DW DO_RUN,     DO_LIST,    DO_NEW,     DO_INPUT,  DO_REM     ; $85-$89
        .DW DO_END,     DO_FOR,     DO_NEXT,    DO_FREE,   DO_POKE    ; $8A-$8E
        .DW DO_DATA,    DO_READ,    DO_RESTORE, DO_ELSE_SK             ; $8F-$92
; DATA returns at run time (RUNLP's SKIPEOL steps past the body); READ parses the
; body tokens (TOK_BYTE/TOK_NUM/TOK_HEX/digit, ',') via RD_READNUM.

; =============================================================================
; INIT - cold start: banner and free-byte count
;   In:  Reset vector entry; zero page pre-loaded by the RAM image
;   Out: falls through to MAIN
;   Clobbers: everything (falls into MAIN)
; =============================================================================
INIT:
        CLD                  ; clear decimal mode
        ; Zero page comes from the RAM image: zeros, with PE = SHOWCASE_END and
        ; RND_SEED = $ACE1 pre-loaded. A ROM without that image needs JSR DO_NEW here.
        LDA #<STR_BANNER
        JSR PUTSTR            ; print banner
        JSR DO_FREE
        ; fall through to MAIN

; =============================================================================
; MAIN - immediate-mode prompt loop
;   In:  from INIT, or jumped to after a statement or error
;   Out: never returns
;   Clobbers: everything (re-initialised per pass)
; =============================================================================
MAIN:
        LDX #HWSTACK
        TXS                  ; reset SP: unwinds any debris left by DO_ERROR
        STZ RUN
        STZ FSTK
        JSR GETLINE_M          ; fills IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
        LDA (IP)
        CMP #TOK_NUM         ; starts with a number -> line edit
        BNE MAIN_DIRECT
        JSR EDITLN
        BRA MAIN
MAIN_DIRECT:
        JSR STMT
        BRA MAIN

; =============================================================================
; DO_ERR_NR / DO_ERR_UL - load an error code and fall into DO_ERROR
;   DO_ERR_NR loads ERR_NR and skips the next LDA (BIT abs); DO_ERR_UL loads ERR_UL.
;   Out: A = ERR_NR or ERR_UL, then DO_ERROR
;   Clobbers: A X Y T0 (falls into DO_ERROR)
; =============================================================================
DO_ERR_NR:
        LDA #ERR_NR
        .DB $2C
DO_ERR_UL:
        LDA #ERR_UL
        ; drop through
; =============================================================================
; DO_ERROR - print "XX ERR [IN line]" and restart at MAIN
;   In:  A = error code (ERR_xx = lo byte of its ERR_TABLE entry)
;   Out: message printed; jumps to MAIN, never returns
;   Clobbers: A X Y T0 T2
; =============================================================================
DO_ERROR:
        PHA              ; save error code (survives PRNL which uses A)
        JSR PRNL         ; print CR+LF
        PLA
        JSR PUTSTR       ; 2-char code
        LDA #<STR_ERROR
        JSR PUTSTR           ; " ERR"
        BBR #0,RUN,DO_ERR_NOLINE  ; idle: no " IN line"
        LDA #<STR_IN
        JSR PUTSTR           ; " IN "
        LDX #CURLN-T0
        JSR TO_T0
        JSR PRT16            ; line number
DO_ERR_NOLINE:
        JSR PRNL
        BRA MAIN

; =============================================================================
; GETLINE_M / GETLINE_I / GETLINE - read one line of input into IBUF, then tokenise
;   GETLINE_M prints "> ", GETLINE_I prints "? "; both fall into GETLINE.
;   Backspace edits; characters past IBUF_MAX are discarded with a BELL.
;   In:  keyboard input via GETCH
;   Out: IBUF = typed line (NUL-terminated); falls through to TOKENIZE
;   Clobbers: A X Y T0 T1 T2 CURLN TKTOK (via TOKENIZE)
; =============================================================================
GETLINE_M:
         LDA #'>'
         .DB $2C
GETLINE_I:
         LDA #'?'
         JSR PUTCH
         JSR PRTSP
GETLINE:
        LDX #0
GLL:
        JSR GETCH              ; raw read, no echo
         CMP #CR
         BEQ GLD
         CMP #BS
         BNE GLS
         JSR PUTCH             ; echo the backspace byte
         TXA                   ; test X=0 (A is dead: GETCH reloads it)
         BEQ GLL
         DEX
         BRA GLL
GLS:
        CPX #IBUF_MAX
         BCS GLFULL
         STA IBUF,X
         JSR PUTCH             ; echo the stored character (A unaffected by the STA above)
         INX
         BRA GLL
GLFULL:
        LDA #BELL               ; buffer full: discard the char, beep instead
         JSR PUTCH
         BRA GLL
GLD:
        JSR PUTCH               ; echo the raw CR
         STZ IBUF,X             ; NUL-terminate IBUF
         JSR PRNL
        ; falls through to TOKENIZE
; =============================================================================
; TOKENIZE - translate the raw text in IBUF into a token stream in TBUF
;   In:  IBUF = NUL-terminated ASCII source line
;   Out: TBUF = token stream: keywords $80-$A7, numbers (digit | TOK_BYTE b | TOK_NUM lo hi),
;               TOK_HEX lo hi, strings and punctuation as-is, one $00 terminator
;        CURLN = last number parsed
;   Clobbers: A X Y T0 T1 T2 TKTOK CURLN
; =============================================================================
TOKENIZE:
        LDA #<IBUF
        STA T0
        STZ T0+1
        LDA #<TBUF
        STA T1
        STZ T1+1

TK_TOP:
        LDA (T0)             ; 65C02 zp-indirect
        BNE TK_NOTEOL         ; TK_EOL is out of BEQ range
        JMP TK_EOL
TK_NOTEOL:
        CMP #' '             ; Skip spaces
        BEQ INC_TOP

        CMP #'"'             ; String literal?
        BNE TK_NSTR
        JSR TKEMIT           ; Emit opening '"'
TK_SC:
        JSR INC_T0
        LDA (T0)
        BEQ TK_EOL           ; Unterminated string ($00) -> EOL
        JSR TKEMIT
        CMP #'"'
        BEQ INC_TOP          ; Closing '"' -> advance T0 & resume loop
        BRA TK_SC            ; Keep copying string bytes

TK_NSTR:
        CMP #'$'             ; Hex literal? $HHHH (1-4 hex digits)
        BNE TK_NDLR
        JSR INC_T0            ; consume '$'
        JSR TKPHEX            ; parse hex digit run into CURLN (advances T0)
        LDA #TOK_HEX
        JSR TKEMIT
        JSR EMIT_CURLN
        BRA TK_TOP

TK_NDLR:
        CMP #'0'             ; Decimal digit?
        BCC TK_NNUM
        CMP #'9'+1
        BCS TK_NNUM
        JSR TKPNUM           ; Parse number into CURLN (advances T0)
        ; A leading line number (nothing emitted yet: T1 still at <TBUF) always uses
        ; the 3-byte TOK_NUM form, so MAIN/EDITLN/INSLINE need no change. Only the low
        ; byte of T1 is tested: TBUF is well under 256 bytes.
        LDA T1
        CMP #<TBUF
        BEQ TK_EMITNUM
TK_BODYNUM:
        LDA CURLN+1
        BNE TK_EMITNUM        ; >=256: 3-byte TOK_NUM
        LDA CURLN
        CMP #10
        BCS TK_EMITBYTE       ; 10-255: 2-byte TOK_BYTE
        ORA #'0'              ; 0-9: ascii digit, 1 byte, no token
        BRA TK_TAIL            ; shares the TOK_BYTE tail below
TK_EMITBYTE:
        LDA #TOK_BYTE
        JSR TKEMIT
        LDA CURLN
TK_TAIL:
        JSR TKEMIT
        BRA TK_TOP
TK_EMITNUM:
        LDA #TOK_NUM
        JSR TKEMIT
        JSR EMIT_CURLN
        BRA TK_TOP

TK_NNUM:
        JSR UC
        CMP #'A'             ; Keyword or variable letter?
        BCC TK_OTHER
        CMP #'Z'+1
        BCS TK_OTHER
        PHA                  ; keep the uppercased char across TRYKW
        JSR TRYKW
        PLA                  ; PLA leaves the carry from TRYKW alone
        BCS TK_OTHER         ; no keyword: emit the char
        BRA TK_TOP           ; matched

TK_OTHER:  ; A = uppercased char: variable letter / punctuation
        JSR TKEMIT
INC_TOP:
        JSR INC_T0           ; Shared helper: advance T0 and loop
        JMP TK_TOP

TK_EOL:
        LDA #0               ; write the $00 end-of-line terminator
        BRA TKEMIT           ; Tail call: emits $00 and RTS

; =============================================================================
; INC_T0 - advance source pointer T0 by one
;   In:  T0
;   Out: T0+=1; A unchanged
;   Clobbers: flags
; =============================================================================
INC_T0:
        INC T0
        BNE INC_T0_OK
        INC T0+1
INC_T0_OK:
        RTS

; =============================================================================
; DATAPTRADD3 / INC_DATA_PTR - advance DATA_PTR by 3 (record header) / by 1
;   In:  DATA_PTR
;   Out: DATA_PTR+=3 or +=1; A unchanged
;   Clobbers: flags
; =============================================================================
DATAPTRADD3:  ; DATA_PTR += 3 (lo, hi, len)
        JSR INC_DATA_PTR
        JSR INC_DATA_PTR
INC_DATA_PTR:
        INC DATA_PTR
        BNE RD_AP_OK
        INC DATA_PTR+1
RD_AP_OK:
        RTS

; =============================================================================
; GETCI / INC_IP - read-and-advance / advance IP by 1
;   GETCI falls into INC_IP.
;   In:  IP = token stream pointer
;   Out: GETCI: A=(IP), IP+=1    INC_IP: IP+=1
;   Clobbers: GETCI: A; INC_IP: flags
; =============================================================================
GETCI:
        LDA (IP)             ; fetch the byte at IP, then advance
INC_IP:
        INC IP
        BNE INC_IP_OK
        INC IP+1
INC_IP_OK:
        RTS

; =============================================================================
; LPADD3 / INC_LP - advance LP by 3 (record header) / by 1
;   In:  LP
;   Out: LP+=3 or +=1; A unchanged
;   Clobbers: flags
; =============================================================================
LPADD3:
        JSR INC_LP              ; LP += 3 (lo, hi, len)
        JSR INC_LP
INC_LP:
        INC LP
        BNE INC_LP_OK
        INC LP+1
INC_LP_OK:
        RTS

; =============================================================================
; EMIT_CURLN - emit CURLN (lo, hi) via TKEMIT
;   Emits the lo byte, then falls into TKEMIT with the hi byte.
;   In:  CURLN; T1 = token output pointer
;   Out: T1+=2
;   Clobbers: A
; =============================================================================
EMIT_CURLN:
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1          ; falls into TKEMIT: emit hi byte, then RTS
; =============================================================================
; TKEMIT - store A at the token output pointer T1 and advance T1
;   In:  A = byte; T1 = output pointer
;   Out: T1+=1; A unchanged
;   Clobbers: flags
; =============================================================================
TKEMIT:
        STA (T1)             ; 65C02 zp-indirect: no Y needed
INC_T1:
        INC T1
        BNE TKEMIT_OK
        INC T1+1
TKEMIT_OK:
TKPN_DN:
        RTS

; =============================================================================
; CURLNX4 / DBL_CURLN - CURLN <<= 2 / CURLN <<= 1
;   CURLNX4 calls DBL_CURLN once and falls into it for the second shift.
;   In:  CURLN
;   Out: CURLN shifted left
;   Clobbers: flags
; =============================================================================
CURLNX4:
        JSR DBL_CURLN
DBL_CURLN:
        ASL CURLN
        ROL CURLN+1
        RTS

; =============================================================================
; TKPNUM - parse a decimal digit run at T0 into CURLN (16-bit unsigned, wraps)
;   In:  T0 = first digit
;   Out: CURLN = value; T0 advanced past the digits
;   Clobbers: A X Y
; =============================================================================
TKPNUM:
        STZ CURLN            ; 65C02 STZ zp
        STZ CURLN+1
TKPN_LP:
        LDA (T0)             ; Get ASCII character
        EOR #'0'             ; '0'-'9' -> $00-$09, anything else >= $0A
        CMP #10
        BCS TKPN_DN          ; >= 10: not a digit, done

        PHA                  ; save the digit (0-9)
        JSR INC_T0           ; Advance pointer

        ; CURLN = CURLN * 10 (via x*2 + x*8)
        JSR DBL_CURLN         ; CURLN = x*2
        LDA CURLN
        TAX
        LDA CURLN+1
        TAY                  ; X,Y = x*2

        JSR CURLNX4          ; CURLN = x*8

        TXA
        CLC
        ADC CURLN
        STA CURLN
        TYA
        ADC CURLN+1
        STA CURLN+1          ; CURLN = x*2 + x*8 = x*10

        PLA                  ; A = digit
        ADC CURLN
        STA CURLN
        BCC TKPN_LP
        INC CURLN+1
        BRA TKPN_LP

; =============================================================================
; TKPHEX - parse a hex digit run at T0 into CURLN (16-bit unsigned)
;   In:  T0 = just past the "$"
;   Out: CURLN = value (digits beyond the 4th shift out; a bare "$" gives 0)
;        T0 advanced past the hex digits
;   Clobbers: A
; =============================================================================
TKPHEX:
        STZ CURLN
        STZ CURLN+1
TKPH_LP:
        LDA (T0)
        JSR UC                ; fold a-f to A-F
        CMP #'0'
        BCC TKPH_DN            ; < '0': not a digit, done
        CMP #'9'+1
        BCC TKPH_DEC           ; '0'-'9'
        CMP #'A'
        BCC TKPH_DN            ; in gap ':'..'@': not hex, done
        CMP #'F'+1
        BCS TKPH_DN            ; > 'F': not hex, done
        SBC #'A'-11           ; 'A'-'F' -> 10-15 (C=0 here: SBC subtracts one more)
        BRA TKPH_DIG
TKPH_DEC:
        SBC #'0'-1            ; '0'-'9' -> 0-9 (C=0 from the BCC that got us here)
TKPH_DIG:
        PHA                    ; save the binary digit (0-15)
        JSR INC_T0
        JSR CURLNX4          ; CURLN <<= 2
        JSR CURLNX4          ; CURLN <<= 2 (total x16)
        PLA
        ORA CURLN
        STA CURLN
        BRA TKPH_LP
TKPH_DN:
        RTS

; =============================================================================
; TRYKW - match a keyword at T0 against KW_TABLE
;   Entries carry bit 7 on their last character. Source (T0) and entry (T2) share one
;   index Y, so a miss needs no backtrack; a hit adds Y+1 to T0 once. Compare is
;   src ^ table: 0 = equal, $80 = equal on the flagged last char, else miss. (A source
;   byte >= $80 cannot be told from a flagged char; the terminal never sends one.)
;   In:  T0 = candidate text
;   Out: C=0: matched; token emitted via TKEMIT (REM copies the rest of the line); T0 past it
;        C=1: no match; T0 unchanged, nothing emitted
;   Clobbers: A Y T2 TKTOK (T1 advanced by TKEMIT)
; =============================================================================
TRYKW:
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        LDA #TOK_PRINT
        STA TKTOK
TRY_ENT:
        LDA (T2)             ; first char of entry ($00 = end of table)
        BEQ TRY_FAIL         ; $00 sentinel = end of table: no match
        LDY #0               ; Y = index into the source text AND the table entry
TRY_CMP:
        LDA (T0),y           ; source char
        JSR UC               ; uppercase it
        EOR (T2),y           ; 0 = equal; $80 = equal, entry's last char; else mismatch
        BEQ TRY_NXT          ; equal, more chars follow
        CMP #$80
        BNE TRY_MISS         ; mismatch: try next keyword
        ; ---- full match: advance T0 past the Y+1 matched chars ----
        TYA
        SEC
        ADC T0
        STA T0
        BCC TRY_HIT
        INC T0+1
TRY_HIT:
        LDA TKTOK
        JSR TKEMIT           ; emit the token (TKEMIT leaves A alone)
        CMP #TOK_REM         ; REM: token first, then absorb rest of line verbatim
        BNE TRY_OK
TRY_RAW:  ; copy raw bytes until the NUL terminator (REM body)
        LDA (T0)
        BEQ TRY_OK
        JSR TKEMIT
        JSR INC_T0
        BRA TRY_RAW
TRY_OK:
        CLC
        RTS
TRY_NXT:
        INY                  ; next char pair
        BNE TRY_CMP          ; always (no keyword >= 256 chars)
TRY_MISS:  ; this keyword doesn't match: next entry (T0 untouched)
        JSR KW_NEXT          ; advance T2 past current entry
        INC TKTOK
        BRA TRY_ENT
TRY_FAIL:
        SEC
        RTS

; =============================================================================
; KW_NEXT - advance T2 to the next KW_TABLE entry
;   In:  T2 = first char of the current entry
;   Out: T2 = first char of the next entry
;   Clobbers: A Y
; =============================================================================
KW_NEXT:
        LDY #$FF             ; start at -1
KW_NX_LP:
        INY                  ; On first pass, Y rolls over to 0
        LDA (T2),Y           ; Sets the N flag
        BPL KW_NX_LP         ; loop until bit 7 (last char) is set
        TYA                  ; A = index of the last character
        SEC                  ; Set carry = 1 (acts as a +1 for the addition)
        ADC T2               ; A = T2 + Y + 1
        STA T2
        BCC KW_NEXT_OK       ; If we didn't overflow 255, skip the high-byte inc
        INC T2+1
KW_NEXT_OK:
EL_DONE:
        RTS

; =============================================================================
; EDITLN - insert, replace or delete a numbered program line
;   In:  IP = TBUF ($FF lo hi body $00)
;   Out: body non-empty: line inserted or replaced (INSLINE); empty: line deleted (DELINE)
;        CURLN = line number; LP = its position; PE adjusted
;   Clobbers: A X Y T0 T1 LP
; =============================================================================
EDITLN:
        JSR PNUM             ; consume $FF lo hi, place value in T0
        JSR T0_TO_CURLN
        LDX #LP-IP
        JSR PROG2P
        BRA EL_FL             ; skip EL_SKIP's own body on the first pass
EL_SKIP:  ; advance LP past current line (hop by its length byte)
        JSR LP_HOP
EL_FL:
        LDX #LP               ; scan for insertion/replacement point
        LDY #PE
        JSR CMP16
        BEQ EL_INS           ; reached end: insert here
EL_GO:
        LDY #1
        LDA (LP),y           ; stored line-number hi byte
        CMP CURLN+1
        BNE EL_CK            ; hi bytes differ: this compare alone decides it
        DEY                  ; hi bytes equal: fall through, compare lo bytes
        LDA (LP),y           ; stored line-number lo byte
        CMP CURLN
EL_CK:
        BCC EL_SKIP          ; stored < target (whichever CMP fired): keep scanning
        BNE EL_INS           ; stored > target: insert before this line
        ; neither branch taken -> exact match: fall through to replace
EL_FOUND:
        JSR DELINE           ; delete existing line before re-inserting
EL_INS:
        LDA (IP)            ; check for empty body (just the NUL terminator)
        BEQ EL_DONE
        ; drop through
; =============================================================================
; INSLINE - insert a tokenised line into the program store at LP
;   OOM test compares only the new PE high byte with RAM_TOP's: exact, RAM_TOP is page-aligned.
;   In:  TBUF = $FF lo hi body $00 (IP is rewound to TBUF here)
;        LP = insertion point (bytes LP..PE shift up); PE = program end; CURLN = line number
;   Out: record [lo hi len body NUL] written at LP; PE += record length; IP = TBUF
;        OM ERR if the new PE would reach RAM_TOP
;   Clobbers: A X Y T0 T1
; =============================================================================
INSLINE:
        LDA #<TBUF           ; rewind IP to TBUF (zero page: IP+1 is already 0)
        STA IP               ; source and destination share one index: Y=3 is the
        LDY #3               ; first body byte on both sides
        JSR TOKSKIP_IP       ; returns Y = offset past the NUL = total record length
        PHY                  ; save the length for the header write below
        TYA
        CLC
        ADC PE                ; new PE = PE + total size
        STA T1
        LDA PE+1
        ADC #0
        STA T1+1
        CMP #>RAM_TOP        ; would this cross RAM_TOP? (hi-byte only:
        BCC IN_OK            ;  exact since RAM_TOP is page-aligned)
        LDA #ERR_OM
        JMP DO_ERROR
IN_OK:
        LDX #PE-T0          ; T0 = old PE
        JSR TO_T0
        LDA T1                ; commit new PE now (OOM check already passed)
        STA PE
        LDA T1+1
        STA PE+1
        LDY #0
        JSR CMP_T0_LP        ; if old PE == LP, nothing to shift upward
        BEQ IN_HDR
IN_BK:
        LDA T0                ; pre-decrement source (T0)
        BNE IN_D0
        DEC T0+1
IN_D0:
        DEC T0
        LDA T1                ; pre-decrement destination (T1)
        BNE IN_D1
        DEC T1+1
IN_D1:
        DEC T1
        LDA (T0),y            ; backward copy loop
        STA (T1),y
        JSR CMP_T0_LP        ; stop exactly when T0 == LP
        BNE IN_BK
IN_HDR:
        LDA CURLN             ; write 3-byte header at LP: line number lo, hi, record length
        STA (LP),y            ; Y is 0 here
        INY
        LDA CURLN+1
        STA (LP),y
        INY
        PLA                   ; record length saved at entry
        STA (LP),y
        INY                   ; Y = 3: body offset (same in source TBUF and destination)
IN_CP:
        LDA (IP),y            ; copy payload from TBUF
        STA (LP),y
        BEQ IN_DONE            ; NUL terminator copied: done (Z is still from the LDA)
        ; Payload: TOK_BYTE has 1 extra byte, TOK_HEX/TOK_NUM 2. A loop, not unrolled:
        ; INSLINE is off the RUN path, so ROM beats cycles.
        LDX #1                 ; assume 1 extra byte (TOK_BYTE) if >= TOK_BYTE
        CMP #TOK_BYTE
        BCC IN_NX               ; < TOK_BYTE: plain byte, no payload to copy
        BEQ IN_PAY                ; == TOK_BYTE: X=1 is right
        INX                        ; TOK_HEX/TOK_NUM: X=2
IN_PAY:
        INY
        LDA (IP),y
        STA (LP),y
        DEX
        BNE IN_PAY
IN_NX:
        INY
        BRA IN_CP             ; always taken for bounded line lengths (<256)

; =============================================================================
; DELINE - remove the program line whose header is at LP
;   Forward copy: source T0 runs up to PE while LP walks as the destination
;   (saved on the stack).
;   In:  LP = <lo> <hi> <len> of the line to delete; PE = program end
;   Out: bytes [LP+len .. PE) shifted down to LP; PE -= len
;        LP unchanged (INSLINE needs it as the insertion point on the replace path)
;   Clobbers: A X Y T0 T1
; =============================================================================
DELINE:
        LDY #2
        LDA (LP),y           ; A = record length
        STA T1               ; T1 = line size (header + body + NUL); hi byte never needed
        CLC                  ; T0 = LP + size  (source for compaction)
        ADC LP
        STA T0
        LDA LP+1
        ADC #0
        STA T0+1
        LDA LP               ; save LP: it walks as the destination below
        PHA
        LDA LP+1
        PHA
DL_CP:
        LDX #T0              ; source reached PE? then everything above the hole is moved
        LDY #PE
        JSR CMP16
        BEQ DL_DONE
        LDA (T0)             ; shift one byte down
        STA (LP)
        JSR INC_T0
        JSR INC_LP
        BRA DL_CP
DL_DONE:
        PLA                  ; restore LP
        STA LP+1
        PLA
        STA LP
        LDA PE               ; PE -= size
        SEC
        SBC T1
        STA PE
        BCS DL_OK
        DEC PE+1
IN_DONE:
DL_OK:
        RTS

; =============================================================================
; STMT - decode and execute one statement, then any ": stmt" after it
;   Handlers are entered by JSR ST_DISP and return to ST_SEP, so the stack does not grow.
;   In:  IP = first token of the statement; RUN = 0 immediate, non-zero in a program
;   Out: IP past the statement and any chained statements
;   Clobbers: A X Y T0 T1 T2 and whatever the handler clobbers
; =============================================================================
STMT:
        LDA (IP)
        BMI ST_TOK           ; $80+ = keyword token: the commonest case, tested first
        BEQ ST_NOP           ; NUL = empty / end-of-line
        CMP #':'             ; colon separator: skip and loop
        BEQ ST_COLON
ST_LET:
        JSR DO_LET           ; implicit assignment  varname = expr, or after a LET token
        BRA ST_SEP           ; check for trailing ':'
ST_TOK:
        JSR INC_IP           ; consume the token (A = token, preserved)
        ; The 19 statement tokens $80..$92 index STMT_JT. TOK_PRINT = $80, so ASL alone
        ; gives the word index (bit 7 shifts out). Any token >= $93 (expr atoms, LET etc.)
        ; goes to DO_LET.
        CMP #TOK_ELSE+1
        BCS ST_LET
        ASL                  ; word index
        TAX
        JSR ST_DISP          ; handler's RTS returns to ST_SEP
ST_SEP:
        LDA (IP)             ; after any statement: check for ':'
        CMP #':'
        BEQ ST_COLON         ; another statement on same line: loop
ST_NOP:
        RTS
ST_COLON:
        JSR INC_IP           ; consume ':'
        BRA STMT             ; execute next statement on same line
ST_DISP:
        JMP (STMT_JT,X)      ; 65C02 absolute indexed indirect

; =============================================================================
; STATEMENT HANDLERS
; =============================================================================
; DO_PRINT - PRINT [item [; item ...]]
;   item = "string" | TAB(n) | CHR$(n) | HEX$(n) | $HHHH (hex, when alone) | expression
;   ";" between items suppresses the newline; a trailing ";" suppresses the final CR LF.
;   Bare PRINT prints a blank line.
;   In:  IP = just past PRINT
;   Out: IP past the item list
;   Clobbers: EXPR
; =============================================================================
DO_PRINT:
DP_TOP:
        LDA (IP)            ; Peek next token -> A
        JSR DP_END           ; bare PRINT (EOL / ':' / ELSE / sentinel)?
        BEQ DP_NL            ; yes: just print newline
        CMP #'"'             ; string literal?
        BNE DP_EXPR
        JSR INC_IP            ; consume opening '"'

DP_STR:
        LDA (IP)             ; peek first: an unterminated string must not consume
        BEQ DP_NL            ; the NUL line terminator
        JSR INC_IP
        CMP #'"'
        BEQ DP_AFT
        JSR PUTCH
        BRA DP_STR

DP_EXPR:
        CMP #TOK_TAB         ; TAB(n)?
        BNE DP_CHK_CHRS

        JSR E2_CHRS          ; Consumes TAB token and get (n) into T0
        LDX T0               ; Loop count
        BEQ DP_AFT
DP_TAB_LP:
        JSR PRTSP
        DEX
        BNE DP_TAB_LP
        BRA DP_AFT

DP_CHK_CHRS:
        CMP #TOK_CHRS        ; CHR$(n)?
        BNE DP_CHK_HEXS

        JSR E2_CHRS          ; Consumes CHR$ token get (n) -> T0
        LDA T0
        JSR PUTCH
        BRA DP_AFT

DP_CHK_HEXS:
        CMP #TOK_HEXS        ; HEX$(n)?
        BNE DP_CHK_HEX
        JSR E2_CHRS          ; Consumes HEX$ token, get (n) -> T0
        JSR PRT_HEX          ; print T0 as 4-digit hex, MSB first
        BRA DP_AFT

DP_NORM:
        JSR EXPR
        JSR PRT16
        ; Falls through to DP_AFT

DP_AFT:
        LDA (IP)
        CMP #';'
        BEQ DP_SEMI
DP_NL:
        JMP PRNL             ; tail call: print newline and return

DP_SEMI:
        JSR INC_IP            ; consume ';'
        LDA (IP)
        JSR DP_END           ; trailing ';' at EOL / before ':' / before ELSE / sentinel?
        BNE DP_TOP           ; no: more items, keep printing
        RTS                  ; yes: suppress the newline

; =============================================================================
; DP_END - end-of-item-list test shared by DP_TOP and DP_SEMI
;   In:  A = token at IP
;   Out: Z=1 if A is NUL, ":" or ELSE; Z=0 otherwise; A preserved
;   Clobbers: X (TAX sets Z on the NUL test)
; =============================================================================
DP_END:
        CMP #':'
        BEQ DP_END_X
        CMP #TOK_ELSE
        BEQ DP_END_X
        TAX                  ; TAX sets Z iff A=0 and leaves A unchanged
DP_END_X:
        RTS

; Bare $HHHH literal: printed as hex only when it is the whole item (nothing but
; NUL / ";" / ":" / ELSE follows its 3-byte encoding); otherwise it is part of a
; larger expression and goes through DP_NORM.
DP_CHK_HEX:
        CMP #TOK_HEX
        BNE DP_NORM
        LDY #3                ; peek past marker+lo+hi, don't consume
        LDA (IP),y
        BEQ DP_HEX_ONLY
        CMP #';'
        BEQ DP_HEX_ONLY
        CMP #':'
        BEQ DP_HEX_ONLY
        CMP #TOK_ELSE
        BNE DP_NORM            ; more follows: treat as general expression

DP_HEX_ONLY:
        JSR PNUM               ; consume marker+lo+hi -> T0
        JSR PRT_HEX
        BRA DP_AFT

; =============================================================================
; DO_IF - IF expr [THEN] stmt [ELSE stmt2]   (single line, ELSE optional)
;   True: runs stmt via STMT; RUNLP's SKIPEOL skips the rest of the line (incl. ELSE).
;   False: scans token by token for ELSE or end of line; runs stmt2 if found.
;   In:  IP = just past IF
;   Out: IP past the executed branch
;   Clobbers: EXPR
; =============================================================================
DO_IF:
        JSR EXPR
        LDA T0
        ORA T0+1
        BNE DO_IF_EXEC       ; condition true: skip the ELSE hunt entirely

        ; -- condition false: scan for ELSE -----------------------------------
DO_IF_F:
        LDA (IP)
        BEQ DO_IF_DONE       ; NUL = EOL with no ELSE: done

        CMP #TOK_ELSE
        BEQ DO_IF_ELSE       ; found the ELSE: consume it and fall into exec

        JSR INC_IP            ; consume ignored token
        JSR SKIP_LIT          ; skip its payload, if any
        BRA DO_IF_F

        ; -- condition true / ELSE block found --------------------------------
DO_IF_ELSE:
        JSR INC_IP            ; consume TOK_ELSE and fall through to exec

DO_IF_EXEC:  ; shared execution block for both True and ELSE
        LDA (IP)
        CMP #TOK_THEN        ; optional THEN keyword (forgiving for both IF and ELSE)
        BNE DO_IF_STMT
        JSR INC_IP             ; consume TOK_THEN
DO_IF_STMT:
        JMP STMT              ; tail call -> RUNLP's SKIPEOL handles any remainder

DO_IF_DONE:
        RTS

; =============================================================================
; SKIP_LIT - advance IP past a literal's payload, if any
;   BCC exits share DO_IF_DONE's RTS above; the last INC_IP is a tail call.
;   In:  A = token byte (the caller steps over the token byte itself)
;   Out: IP advanced by the payload length: 0 for a plain token/char, 1 for TOK_BYTE,
;        2 for TOK_HEX/TOK_NUM; A unchanged
;   Clobbers: flags
; =============================================================================
SKIP_LIT:
        CMP #TOK_BYTE
        BCC DO_IF_DONE
        JSR INC_IP
        CMP #TOK_HEX
        BCC DO_IF_DONE
        JMP INC_IP

; =============================================================================
; DO_GOTO - GOTO expr: continue at the line numbered expr
;   In:  IP = just past GOTO
;   Out: SP unwound to RUNSP, run loop resumes at the target line; does not return
;        UL ERR if there is no such line
;   Clobbers: EXPR
; =============================================================================
DO_GOTO:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        BRA DO_GO_COMMON     ; GOTO has no frame to push -- skip straight to the tail

; =============================================================================
; DO_GOSUB - GOSUB expr: call the subroutine at line expr
;   In:  IP = just past GOSUB
;   Out: return address pushed on GORET, then as GOTO; RETURN resumes after the GOSUB
;        NR ERR when 8 levels are already open; UL ERR if there is no such line
;   Clobbers: EXPR
; =============================================================================
DO_GOSUB:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        LDA GRET
        CMP #8               ; max 8 levels of nesting
        BCC DO_GOSUB_OK
GOSRET_ERR:
        JMP DO_ERR_NR        ; shared error stub
DO_GOSUB_OK:
        ASL
        TAX
        LDA IP               ; push return address (IP after the GOSUB)
        STA GORET,x
        LDA IP+1
        STA GORET+1,x
        INC GRET
        ; fall through into the shared GOTO/GOSUB tail
DO_GO_COMMON:  ; shared by DO_GOTO and DO_GOSUB
        JSR GOTOL
        BCS DO_GOSUB_UL
        JSR T0_TO_CURLN      ; update CURLN to target line (GOTOL leaves T0=line#)
RUN_LINE:
        LDX RUNSP
        TXS
        BRA RUNGO            ; resume the run loop
DO_GOSUB_UL:
        JMP DO_ERR_UL        ; shared error stub

; =============================================================================
; DO_RETURN - RETURN: pop the GOSUB return address into IP
;   Out: IP = address after the GOSUB; GRET -= 1; NR ERR if no GOSUB is open
;   Clobbers: A X
; =============================================================================
DO_RETURN:
        LDA GRET
        BEQ GOSRET_ERR
DO_RETURN_OK:
        DEC GRET
        LDA GRET
        ASL
        TAX
        LDA GORET,x
        STA IP
        LDA GORET+1,x
        STA IP+1
DO_INPUT_DN:                 ; shared RTS: DO_INPUT jumps here when PARSE_VAR fails
        RTS

; =============================================================================
; DO_INPUT - INPUT var: read a line, evaluate it, store it in var
;   In:  IP = just past INPUT
;   Out: var assigned; IP and CURLN preserved (saved on the hardware stack across the prompt)
;   Clobbers: EXPR TKTOK (IBUF and TBUF are overwritten)
; =============================================================================
DO_INPUT:
        JSR PARSE_VAR
        BCS DO_INPUT_DN
        PHA                  ; save slot
        LDA IP+1             ; save IP across GETLINE on the hardware stack
        PHA
        LDA IP
        PHA
        LDA CURLN+1          ; save CURLN too: TOKENIZE (TKPNUM) clobbers it
        PHA
        LDA CURLN
        PHA
        JSR GETLINE_I          ; reads into IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
        JSR EXPR             ; evaluate expression from TBUF
        PLA
        STA CURLN
        PLA
        STA CURLN+1
        PLA                  ; restore IP
        STA IP
        PLA
        STA IP+1
        PLX
        JMP STORE_VAR        ; tail call: its RTS returns to our caller

; =============================================================================
; DO_REM - REM: skip the comment text up to (not past) the NUL
;   TOKSKIP_IP does the scan; REM text is raw ASCII, so its payload test never fires.
;   Leaving IP on the NUL stops ST_SEP treating a leading ":" in the comment as a separator.
;   In:  IP = just past the REM token
;   Out: IP = the line's NUL
;   Clobbers: A X Y
; =============================================================================
DO_REM:
        LDY #0
        JSR TOKSKIP_IP        ; Y = offset just past the NUL
        DEY                   ; -> offset of the NUL itself
        TYA
        BRA ADD_IP            ; IP += offset: tail call

; =============================================================================
; DO_RUN - RUN: execute the program from its first line
;   Out: returns through RUNEND when the program ends: RUN=0, IP=0
;        DATA_PTR and FOR depth reset
;   Clobbers: everything (runs the program)
; =============================================================================
DO_RUN:
        JSR PROG2IP
        STZ DATA_PTR         ; reset DATA pointer (sentinel 0 = rescan from PROG)
        STZ DATA_PTR+1
        STZ FSTK
        SMB #0,RUN           ; RUN only needs to be non-zero: set bit 0
        TSX                  ; save SP so GOTO / NEXT can unwind; the same at every RUNLP
        STX RUNSP            ;  pass, so it is saved once per RUN
; --- inner run loop  (also entered from DO_GOTO / DO_GOSUB / DO_NEXT) ---
RUNLP:
        ; end of program (IP == PE)?  CMP16 is inlined here: the low bytes differ on all
        ; but the last line, so the common case costs three instructions.
        LDA IP
        CMP PE
        BNE RUN_RD
        LDA IP+1
        CMP PE+1
        BEQ RUNEND
RUN_RD:
        ; read the line header into CURLN, step IP past it
        JSR RD_CURLN
RUNGO:
        JSR STMT
        BBR #0,RUN,RUNEND
        ; skip whatever is left of the line
        JSR SKIPEOL
        BRA RUNLP

; =============================================================================
; RD_CURLN / IPADD3 / ADD_IP - read the line header at IP into CURLN / IP += 3 / IP += A
;   RD_CURLN falls into IPADD3, which falls into ADD_IP.
;   In:  RD_CURLN, IPADD3: IP = record header (lo hi len);  ADD_IP: A = amount
;   Out: RD_CURLN: CURLN = line number, IP += 3 (first token)
;        IPADD3: IP += 3 (GOTOL)    ADD_IP: IP += A (DO_REM)
;   Clobbers: RD_CURLN: A Y;  IPADD3, ADD_IP: A
; =============================================================================
RD_CURLN:
        LDA (IP)              ; lo byte
        STA CURLN
        LDY #1
        LDA (IP),y            ; hi byte
        STA CURLN+1
IPADD3:
        LDA #3                ; skip lo, hi, len
ADD_IP:
        CLC
        ADC IP
        STA IP
        BCC ADD_IP_OK
        INC IP+1
ADD_IP_OK:
        RTS

; =============================================================================
; PROG2IP / PROG2P - point a zero-page pointer pair at PROG
;   PROG2IP resets IP. PROG2P resets the pair at IP+X (IP sits at $00, so IP,X reaches
;   any zero-page pair): X = LP-IP or PE-IP.
;   In:  X = offset from IP (PROG2P only)
;   Out: pointer pair = PROG
;   Clobbers: A; PROG2IP also sets X=0
; =============================================================================
PROG2IP:
        LDX #0
PROG2P:
        STZ IP,X
        LDA #>PROG
        STA IP+1,X
        RTS

; =============================================================================
; DO_NEW - NEW: clear zero page and the program store, seed RND
;   Out: zero page cleared, PE = PROG, RND_SEED = $ACE1; falls into RUNEND (RUN=0, IP=0)
;   Clobbers: A X
; =============================================================================
DO_NEW:
        ; clear zero page
        LDX #0
INIT_Z:
        STZ 0,x              ; 65C02 STZ zp,x: no LDA #0 needed
        DEX
        BNE INIT_Z
        ; DATA_PTR is zeroed above: sentinel 0 = rescan from PROG
        ; reset program store
        LDX #PE-IP
        JSR PROG2P

        ; Seed RND
        LDA #$E1             ; seed RND LFSR to $ACE1 (must be non-zero)
        STA RND_SEED
        LDA #$AC
        STA RND_SEED+1
        ; falls into RUNEND (re-clears RUN and IP: harmless, saves an RTS)

; =============================================================================
; DO_END / RUNEND - END: stop the program; RUNEND is also the landing point for DO_RUN and NEXT
;   IP is parked on $0000, a NUL (its own zeroed low byte), so the caller's ST_SEP
;   cannot mistake stale text after the program for a ":" or a statement.
;   Out: RUN=0, IP=0
;   Clobbers: flags
; =============================================================================
DO_END:
RUNEND:
        STZ RUN
        STZ IP
        STZ IP+1
LS_DONE:
        RTS

; =============================================================================
; DO_LIST - LIST [n,m]: list lines n..m (default all), de-tokenising on the fly
;   Lo-bound in T1, hi-bound in CY (defaults 0 and $7FFF, or set by GET_TWO_ARGS; n,m may be
;   expressions). Lines below the lo-bound are hopped by their length byte; lines ascend, so one
;   above the hi-bound ends the scan.
;   In:  IP = just past LIST; PE = program end
;   Out: matching lines printed
;   Clobbers: A X Y T0 T1 T2 LP CY (EXPR when a range is given)
; =============================================================================
DO_LIST:
        STZ T1                ; default lo-bound = 0
        STZ T1+1
        LDA #$FF
        STA CY                ; default hi-bound = $7FFF
        LDA #$7F
        STA CY+1
        LDA (IP)
        BEQ LS_SCAN           ; bare LIST? defaults stand

        JSR GET_TWO_ARGS      ; args present: T1 = n (lo), T0 = m
        LDA T0
        STA CY                ; move m into hi-bound (CY)
        LDA T0+1
        STA CY+1
LS_SCAN:
        LDX #LP-IP
        JSR PROG2P

LS_LN:
        LDX #LP               ; end of program?
        LDY #PE
        JSR CMP16
        BEQ LS_DONE           ; inverted branch (saves 3 bytes)

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
        BCC LS_DONE           ; yes: passed hi-bound, STOP execution entirely

        LDA T0                ; current < lo-bound? (T0 - T1 borrows)
        CMP T1
        LDA T0+1
        SBC T1+1
        BCC LS_SKIP_HDR       ; yes: below lo-bound, silently skip this line!

        ; -- Print Valid Line --
        JSR PRT16             ; print line number
        JSR PRTSP
        JSR LPADD3            ; advance LP past the 3-byte header (lo, hi, length)

LS_BODY:
        LDA (LP)
        BEQ LS_EOL
        CMP #TOK_HEX          ; hex literal?
        BEQ LS_HEX
        CMP #TOK_NUM
        BEQ LS_NUM
        CMP #TOK_BYTE         ; 1-byte constant (10-255)?
        BEQ LS_BYTE
        CMP #TOK_PRINT
        BCC LS_LIT            ; < TOK_PRINT: literal char

        ; -- Keyword Lookup --
        SEC
        SBC #TOK_PRINT
        TAX                   ; X = keyword index (0-based)
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        TXA
        BEQ LS_PRK            ; X = 0: print at once
LS_SKP_LP:
        JSR KW_NEXT
        DEX
        BNE LS_SKP_LP         ; DEX sets Z, no CPX needed (saves 4 bytes)

LS_PRK:
        LDY #0
LS_PKL:
        LDA (T2),Y
        PHA                   ; Save original char with bit 7 intact
        AND #$7F              ; Strip high-bit for printing
        JSR PUTCH
        PLA                   ; Restore original char
        BMI LS_PKD            ; bit 7 set: last character, done (saves 3 bytes)
        INY
        BRA LS_PKL

LS_PKD:
        JSR INC_LP
        JSR PRTSP
        BRA LS_BODY

LS_LIT:
        JSR PUTCH
        JSR INC_LP
        BRA LS_BODY

LS_NUM:
        JSR LOAD_T0_INC      ; consume marker+lo+hi -> T0
        JSR PRT16             ; print as decimal
        BRA LS_TAIL

LS_EOL:
        JSR PRNL              ; fall-through EOL handler (saves 1 byte)
        JSR INC_LP            ; step past the NUL
LS_GO:
        JMP LS_LN              ; loop back to next line

; -- below the lo-bound: hop over the whole record by its length byte --
LS_SKIP_HDR:
        JSR LP_HOP
        BRA LS_GO

; =============================================================================
; LP_HOP - hop LP to the next stored line (shared by EDITLN and LIST)
;   In:  LP = record header (lo hi len)
;   Out: LP += len
;   Clobbers: A Y
; =============================================================================
LP_HOP:
        LDY #2
        LDA (LP),y            ; A = record length
        CLC
        ADC LP
        STA LP
        BCC LP_HOP_OK
        INC LP+1
LP_HOP_OK:
        RTS

LS_HEX:
        JSR LOAD_T0_INC       ; consume marker+lo+hi -> T0
        JSR PRT_HEX            ; print as $HHHH
LS_TAIL:
        JSR PRTSP              ; both paths print a trailing space
        BRA LS_BODY             ; both return to LS_BODY

LS_BYTE:
        JSR LOAD_T0_INC        ; consume marker+1 byte -> T0
        JSR PRT16               ; print as decimal
        BRA LS_TAIL

; =============================================================================
; LOAD_T0_INC - consume a literal at LP into T0 (shared by LS_NUM, LS_HEX, LS_BYTE)
;   In:  LP = TOK_BYTE / TOK_HEX / TOK_NUM marker
;   Out: T0 = 16-bit value; LP advanced past the marker and its payload
;   Clobbers: A
; =============================================================================
LOAD_T0_INC:
        LDA (LP)              ; reload marker (LP hasn't moved since dispatch)
        CMP #TOK_HEX
        JSR INC_LP
        LDA (LP)
        STA T0
        BCS LTI_WIDE           ; TOK_HEX/TOK_NUM: a hi byte follows too
        STZ T0+1                ; TOK_BYTE: hi = 0
        JMP INC_LP
LTI_WIDE:
        JSR INC_LP
        LDA (LP)
        STA T0+1
        JMP INC_LP            ; tail call: its own RTS returns to our caller

; =============================================================================
; DO_FREE - FREE: print the free program bytes
;   In:  PE = program end
;   Out: "n BYTES FREE" printed; T0 = RAM_TOP - PE
;   Clobbers: A X Y T0 T2
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
        .DB $2C               ; BIT abs: skip PRNL's LDA, fall into PUTSTR with A loaded
; =============================================================================
; PRNL / PUTSTR / PUTSTRZP - print CR LF / a table string / the string at T2
;   Strings end at a character with bit 7 set. PUTSTR's hi byte is always STR_PAGE, so
;   every table string must sit on that page. DO_FREE reaches PUTSTR through BIT abs;
;   DP_NL tail-calls PRNL.
;   In:  PUTSTR: A = lo byte of the string address;  PUTSTRZP: T2 = string address
;   Out: characters sent to PUTCH
;   Clobbers: A Y T2 (PUTSTRZP: A Y)
; =============================================================================
PRNL:
        LDA #<STR_CRLF
PUTSTR:
        STA T2
         LDA #STR_PAGE
         STA T2+1
PUTSTRZP:
         LDY #0
PS_LP:
        LDA (T2),y            ; fetch char (bit 7 set = last char)
        BMI PS_LAST
        JSR PUTCH
        INY                   ; advance index to next char
        BRA PS_LP
PS_LAST:
        AND #$7F              ; strip the terminator flag
        JMP PUTCH             ; tail call: its RTS returns to our caller

; =============================================================================
; FSTK_BASE - compute the address of a FOR_STK frame
;   Frame (9 bytes at LP): [0] var_slot (VARS byte offset)  [1,2] limit  [3,4] step
;     [5,6] resume IP (just past the FOR clause)  [7,8] loop line (CURLN at FOR time)
;   In:  A = frame index (0 = bottom, FSTK-1 = top)
;   Out: LP = FOR_STK + A*9
;   Clobbers: A T2
; =============================================================================
FSTK_BASE:
        STA T2
        ASL
        ASL
        ASL               ; A * 8 (A <= 3: no carry out)
        ADC T2            ; + A = A*9; carry is clear from the shifts and A*9 <= 27
        ADC #<FOR_STK     ; cannot carry either: no CLC needed
        STA LP
        STZ LP+1
        RTS

; =============================================================================
; DO_FOR - FOR var = start TO limit [STEP step]
;   var_slot, limit, step and resume IP are staged in FVAR/FLIM/FSTEP/FIP, which sit just
;   before CURLN in zero page: [FVAR FLIM FSTEP FIP CURLN] is the 9-byte FOR_STK frame, pushed
;   by one indexed loop. CURLN already holds the loop line. NEXT resumes at the saved IP
;   (just past the FOR clause), so a FOR may share its line and FORs may chain.
;   The variable letter is consumed before validation: safe, DO_ERROR never returns.
;   In:  IP = variable letter
;   Out: frame pushed on FOR_STK, FSTK += 1; VARS[var] = start
;        SN ERR bad variable; ST ERR zero STEP; NR ERR beyond 4 nested loops
;   Clobbers: EXPR LP
; =============================================================================
DO_FOR:
        JSR GETVARC          ; consume variable letter directly, A = char-'A'
        CMP #26               ; 0-25 = valid letter
        BCS DO_FOR_SN
        ASL                  ; byte offset into VARS
        STA FVAR             ; stage var_slot directly (no stack juggling)
        JSR EXPECT_EQ        ; require '=', then evaluate start value -> T0
        LDX FVAR
        JSR STORE_VAR         ; store start value in variable
        JSR EXPECT_TO         ; require TO, then evaluate limit -> T0
        LDA T0
        STA FLIM             ; stage limit directly
        LDA T0+1
        STA FLIM+1
        LDA (IP)
        CMP #TOK_STEP
        BNE DO_FOR_NOSTEP
        JSR INC_IP            ; consume STEP token
        JSR EXPR             ; evaluate step -> T0
        LDA T0
        LDX T0+1
        BRA DO_FOR_HAVESTEP
DO_FOR_NOSTEP:
        LDA #1               ; default step = 1
        LDX #0
DO_FOR_HAVESTEP:
        STA FSTEP            ; stage step (shared store for both paths)
        STX FSTEP+1
        ORA FSTEP+1          ; step of zero is illegal
        BNE DO_FOR_SZOK
        LDA #ERR_ST
        JMP DO_ERROR
DO_FOR_SZOK:
        LDA FSTK
        CMP #4               ; max 4 nested FOR loops
        BCS DO_FOR_NR
        JSR FSTK_BASE        ; LP = FOR_STK + FSTK*9 (A already holds FSTK)
        LDA IP               ; stage resume point: IP is just past the FOR clause
        STA FIP              ;  (at ':' or the NUL) -- this is where NEXT jumps back to
        LDA IP+1
        STA FIP+1
        LDY #8
DO_FOR_CP:
        LDA FVAR,y           ; copy FVAR,FLIM(2),FSTEP(2),FIP(2),CURLN(2)
        STA (LP),y           ; into the frame in one pass (offsets match exactly)
        DEY
        BPL DO_FOR_CP
        INC FSTK
        RTS
DO_FOR_SN:
        JMP RD_SN            ; shared ERR_SN stub (RD_SN in DO_READ, below)
DO_FOR_NR:
        JMP DO_ERR_NR        ; shared error stub; DO_NEXT branches here too

; =============================================================================
; DO_NEXT - NEXT [var]
;   The variable name is consumed but not checked: NEXT closes the innermost loop.
;   One signed test: diff = var - limit. diff = 0: limit met exactly, loop once more.
;   Otherwise diff and step of differing sign mean the limit is not yet crossed (loop);
;   matching signs mean it is crossed (stop). One path serves both step directions.
;   In:  IP = optional variable name
;   Out: var += step; loops back (IP, CURLN restored from the frame), or once the limit is
;        crossed FSTK -= 1 and execution continues after NEXT; at the end of the program
;        inside a loop FSTK -= 1 and RUN = 0; NR ERR if no FOR is open
;   Clobbers: A X Y T0 T2 LP
; =============================================================================
DO_NEXT:
        LDA (IP)             ; consume optional variable name (ignored)
        SEC
        SBC #'A'
        CMP #26               ; 0-25 = valid letter
        BCS DO_NEXT_NOVAR
        JSR INC_IP
DO_NEXT_NOVAR:
        LDA FSTK
        BEQ DO_FOR_NR        ; no FOR open: NR ERR through DO_FOR's stub
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
        BEQ DN_LOOP          ; var == limit: always loop once more
        TXA                  ; restore diff hi byte (restores N flag)
        LDY #4
        EOR (LP),y           ; XOR with [4] step_hi
        BMI DN_LOOP          ; differing signs: limit not yet crossed
        DEC FSTK             ; matching signs: limit crossed, done
        RTS
DN_LOOP:  ; branch back to body: restore IP from the frame
        ; The frame holds the IP just past the FOR clause, so loop-back needs no program
        ; search. A FOR may share its line and FORs may chain: the resume point is the FOR
        ; clause itself. CURLN is restored only on the colon path: when the FOR is alone on
        ; its line the body starts on the next line, and RD_CURLN sets CURLN.
        LDY #5
        LDA (LP),y           ; [5] resume_ip_lo
        STA IP
        INY
        LDA (LP),y           ; [6] resume_ip_hi
        STA IP+1
        LDA (IP)
        BEQ DN_ALONE         ; NUL right after the FOR clause: the usual case, no scan needed
        JSR SKIP_STMT        ; step over any junk after the FOR clause (stop at ':' or NUL)
        BCS DN_ALONE         ; C=1: NUL found: the FOR is alone on its line
        ; C=0: ':' found -- body is colon-chained on this line. Y is still 6 (SKIP_STMT
        ; leaves Y alone): INY steps to [7] loop_line_lo.
        INY
        LDA (LP),y           ; [7] loop_line_lo
        STA CURLN
        INY
        LDA (LP),y           ; [8] loop_line_hi
        STA CURLN+1
        ; Leave IP at the ':' and RTS into ST_SEP, which consumes it and loops to the body
        ; through STMT's own loop: no stack growth, and it works in immediate mode, where
        ; RUNSP is stale.
        RTS
DN_ALONE:
        ; INC_IP and CMP16 are inlined here: this is the per-iteration path of every loop
        ; whose FOR is alone on its line.
        INC IP               ; consume the NUL
        BNE DN_EC
        INC IP+1
DN_EC:
        ; end of program (IP == PE)?
        LDA IP
        CMP PE
        BNE DN_GO
        LDA IP+1
        CMP PE+1
        BEQ DN_END           ; IP == PE: program ended inside loop
DN_GO:
        JSR RD_CURLN         ; read line-number header, advance IP past it
        JMP RUN_LINE         ; restore S and jump to target

; DN_END: FSTK-- as well as RUN=0 (RUNEND alone would leave the FOR depth wrong).
DN_END:
        DEC FSTK
        STZ RUN
        RTS

; =============================================================================
; GET_TWO_ARGS - parse "expr , expr" (shared by DO_POKE and DO_LIST)
;   The first value waits on the hardware stack: the second EXPR uses T1 for its left operand.
;   In:  IP = first expression
;   Out: T1 = first value; T0 = second value; IP past both
;   Clobbers: EXPR
; =============================================================================
GET_TWO_ARGS:
        JSR EXPR              ; first arg -> T0
        LDA T0+1
        PHA                   ; save hi byte
        LDA T0
        PHA                   ; save lo byte
        JSR EXPECT_COMMA       ; require ',', then evaluate second arg -> T0
        PLA
        STA T1                ; pull first arg lo
        PLA
        STA T1+1              ; pull first arg hi
        RTS

; =============================================================================
; DO_POKE - POKE addr, value
;   In:  IP = just past POKE
;   Out: (addr) = value
;   Clobbers: EXPR
; =============================================================================
DO_POKE:
        JSR GET_TWO_ARGS      ; T1 = addr, T0 = value
        LDA T0
        STA (T1)            ; POKE the value
        RTS

; =============================================================================
; DO_RESTORE / DO_DATA - RESTORE resets the DATA pointer; DATA does nothing at run time
;   DATA's body is stepped over by RUNLP's SKIPEOL.
;   Out: RESTORE: DATA_PTR = 0 (the next READ rescans from PROG)
;   Clobbers: flags
; =============================================================================
DO_RESTORE:
        STZ DATA_PTR         ; 65C02 STZ zp
        STZ DATA_PTR+1
RD_VAR_DONE:
DO_DATA:
        RTS

; =============================================================================
; DO_READ - READ var [, var ...]: take the next DATA values into variables
;   DATA record: [lo hi len TOK_DATA value-list $00]; value = ['-'] literal (digit |
;   TOK_BYTE b | TOK_NUM lo hi | TOK_HEX lo hi), separated by ','.
;   DATA_PTR: 0 = rescan from PROG on the next READ; PE = out of DATA; otherwise the
;   parse position inside a DATA body (past TOK_DATA): at '-', a literal, ',' or the NUL.
;   In:  IP = first variable letter; DATA_PTR
;   Out: variables set; IP past the variables and commas; DATA_PTR past the consumed values
;        OD ERR out of data; SN ERR if a variable letter is missing
;   Clobbers: A X Y T0
; =============================================================================
DO_READ:
RD_VAR:
        LDA (IP)             ; peek at next IP token
        CMP #'A'
        BCC RD_SN
        CMP #'Z'+1
        BCS RD_SN
        JSR GETVARC          ; consume variable letter, A = char-'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var slot
        JSR RD_NEXT_VAL      ; T0 = next data value; C=1 if out-of-data
        BCS RD_OD
        PLX
        JSR STORE_VAR
        LDA (IP)            ; check for ', var' continuation
        CMP #','
        BNE RD_VAR_DONE
        JSR INC_IP            ; consume ','
        BRA RD_VAR

RD_OD:
        PLA                  ; discard saved var slot
        LDA #ERR_OD
        .BYTE $2C            ; BIT abs: skip the next LDA
RD_SN:
        LDA #ERR_SN
        JMP DO_ERROR

; =============================================================================
; RD_NEXT_VAL - find and parse the next DATA value into T0
;   DATA_PTR invariant: see DO_READ.
;   Out: C=0: T0 = signed 16-bit value, DATA_PTR advanced
;        C=1: out of data, DATA_PTR = PE
;   Clobbers: A X Y
; =============================================================================
RD_NEXT_VAL:
        ; -- if DATA_PTR==0 (reset): start scanning from PROG ----------------
        LDA DATA_PTR
        ORA DATA_PTR+1
        BNE RD_CHK_PE
        LDA #>PROG
        STA DATA_PTR+1        ; DATA_PTR lo already 0 (ORA above proved it)
        BRA RD_FIND          ; DATA_PTR now at first line header; find DATA

        ; -- NUL exhaustion (RD_BODY): advance past it, then find the next DATA
        ;    line ------------------------------------------------------------
RD_EXH:
        JSR INC_DATA_PTR       ; skip the NUL
        ; fall through to RD_FIND (DATA_PTR now at next record header)
        ; -- scan record headers for the next DATA line (a non-DATA line is skipped by its length byte)
RD_FIND:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
        BEQ RD_OOD           ; hit PE: no more DATA
        LDY #3
        LDA (DATA_PTR),y     ; first body token (header is lo, hi, length)
        CMP #TOK_DATA
        BEQ RD_FOUND_DATA
        LDY #2               ; not DATA: DATA_PTR += record length, try next line
        LDA (DATA_PTR),y
        CLC
        ADC DATA_PTR
        STA DATA_PTR
        BCC RD_FIND
        INC DATA_PTR+1
        BRA RD_FIND

        ; -- if DATA_PTR==PE: out of data -------------------------------------
RD_CHK_PE:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
        BEQ RD_OOD
        ; -- DATA_PTR is inside a DATA body: skip separators ------------------
RD_BODY:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        BEQ RD_EXH            ; NUL: exhausted -> shared advance+find
        CMP #','
        BEQ RD_SEP_ADV
        BRA RD_PARSE         ; '-' or TOK_NUM/TOK_HEX: parse it

GT_ERR:
RD_OOD:
        SEC
        RTS

RD_FOUND_DATA:
        JSR DATAPTRADD3        ; skip lo, hi, length: DATA_PTR now at the TOK_DATA byte
RD_SEP_ADV:
        JSR INC_DATA_PTR       ; skip TOK_DATA (or a ',' separator) -- now inside body
        BRA RD_BODY          ; enter body (may be space/comma at start)

        ; -- parse the value at DATA_PTR --------------------------------------
RD_PARSE:
        CMP #'-'             ; minus sign? (Z=1 if so)
        PHP                  ; Push the processor flags to the stack
        BNE RD_POS           ; If not a minus, skip advancing the pointer
        JSR INC_DATA_PTR     ; Consume '-'
RD_POS:
        JSR RD_READNUM        ; Both paths share the literal read
        PLP                  ; Pull the flags back from the stack
        BNE RD_DONE          ; not a minus: skip the negation
        JSR NEG16            ; Negate T0 in place
RD_DONE:
        CLC                  ; Clear carry (required by both paths)
        RTS


; =============================================================================
; RD_READNUM - consume a numeric literal at DATA_PTR into T0
;   In:  DATA_PTR -> an ascii digit, or a TOK_BYTE / TOK_HEX / TOK_NUM marker
;   Out: T0 = 16-bit value (every form gives the same binary value)
;        DATA_PTR past the literal (1 to 3 bytes)
;   Clobbers: A
; =============================================================================
RD_READNUM:
        LDA (DATA_PTR)
        CMP #'0'
        BCC RD_RN_LIT
        CMP #'9'+1
        BCS RD_RN_LIT
        SEC                    ; ascii digit: value = A-'0', 1 byte, no marker
        SBC #'0'
        STA T0
        STZ T0+1
        JMP INC_DATA_PTR
RD_RN_LIT:
        CMP #TOK_HEX           ; TOK_BYTE and TOK_HEX/NUM share the marker skip and lo-byte read
        JSR INC_DATA_PTR
        LDA (DATA_PTR)
        STA T0
        BCS RD_RN_WIDE          ; TOK_HEX/TOK_NUM: a hi byte follows too
        STZ T0+1                 ; TOK_BYTE: hi = 0
        JMP INC_DATA_PTR
RD_RN_WIDE:
        JSR INC_DATA_PTR        ; skip the lo byte just read
        LDA (DATA_PTR)
        STA T0+1
        JMP INC_DATA_PTR      ; tail call: its own RTS returns to our caller

; =============================================================================
; GOTOL - find a line number in the program store
;   Lines ascend. While a program runs and the target is above CURLN, it lies ahead: skip
;   the rest of the current line (TOKSKIP_IP) and scan forward. Backward or same-line targets,
;   and immediate mode, scan from PROG. If the forward scan runs off the end (CURLN is stale
;   after RETURN) it retries from PROG, so a stale CURLN only costs time. GT_SK is the
;   forward entry (Y = 0, IP mid-line).
;   In:  T0 = target line; RUN, CURLN, IP = current position (used only while RUN != 0)
;   Out: C=0: found, IP = first token after the 3-byte header
;        C=1: not found (caller raises UL ERR)
;   Clobbers: A X Y IP
; =============================================================================
GOTOL:
        BBR #0,RUN,GT_FRESH  ; immediate mode: no valid program position
        LDA CURLN            ; 16-bit CURLN - T0: borrow (C=0) iff CURLN < T0,
        CMP T0               ;  i.e. target strictly ahead of the current line
        LDA CURLN+1
        SBC T0+1
        BCS GT_FRESH         ; target is this line or behind us: fresh scan
        LDY #0               ; fast path: skip rest of current line...
        JSR GT_SK            ;  ...then scan forward (returns C=0 found / C=1 off the end)
        BCS GT_FRESH         ; off the end: CURLN is stale, retry from PROG
        RTS                  ; C=0: found (IP already past the header)
GT_FRESH:
        JSR PROG2IP
GT_SC:
        LDA IP               ; IP = PE? (inlined compare: the common case exits at the lo byte)
        CMP PE
        BNE GT_GO
        LDA IP+1
        CMP PE+1
        BEQ GT_ERR           ; reached end without finding it
GT_GO:
        LDA (IP)             ; line-number lo  (65C02 zp-indirect, no Y needed)
        CMP T0
        BNE GT_NX
        LDY #1
        LDA (IP),y           ; line-number hi
        CMP T0+1
        BEQ GT_OK
GT_NX:
        LDY #2               ; not this line: hop over the whole record using its
        LDA (IP),y           ; length byte
        BRA GT_ADV
GT_SK:
        JSR TOKSKIP_IP       ; (fast path enters here with Y=0: IP is mid-line, so the
        TYA                  ;  rest of the current line must still be scanned for its NUL)
GT_ADV:
        CLC                  ; IP += A
        ADC IP
        STA IP
        BCC GT_SC
        INC IP+1
        BRA GT_SC
GT_OK:  ; advance IP past the 3-byte header (lo, hi, length)
        JSR IPADD3
GT_R:
        CLC
        RTS                  ; C=0: found

; =============================================================================
; EXPECT_EQ / EXPECT_TO / EXPECT_COMMA / EXPECT_LPAREN - load the byte a call site requires, then fall into EXPECT
;   Entries chain through BIT abs ($2C), each hiding the next entry's LDA.
;   Out: A = "=" / TOK_TO / "," / "("
;   Clobbers: EXPR (falls into EXPECT)
; =============================================================================
EXPECT_EQ:
        LDA #'='
               .DB $2C          ; BIT abs: swallows EXPECT_TO's LDA #TOK_TO
EXPECT_TO:
        LDA #TOK_TO
               .DB $2C          ; BIT abs: swallows EXPECT_COMMA's LDA #','
EXPECT_COMMA:
        LDA #','
               .DB $2C          ; BIT abs: swallows EXPECT_LPAREN's LDA #'('
EXPECT_LPAREN:
        LDA #'('
               ; falls into EXPECT

; =============================================================================
; EXPECT - require a byte at IP, then evaluate an expression
;   Peeks first: on a mismatch IP is left at the offending byte.
;   In:  A = expected byte; IP -> that byte, then an expression
;   Out: T0 = expression value; IP past both; SN ERR on a mismatch (via RD_SN)
;   Clobbers: EXPR
; =============================================================================
EXPECT:
        STA T2                ; stash the expected byte
        LDA (IP)              ; peek only -- IP unchanged either way
        CMP T2
        BNE EXPECT_SN
        JSR INC_IP                ; matched: consume it for real
        BRA EXPR                   ; tail call: evaluate the expression
EXPECT_SN:
        JMP RD_SN

; AND / OR / XOR: the entry chain selects Y = 0/1/2 through BIT-trick fallthrough and
; falls into REL_SETUP. The left operand stays on the hardware stack; EB_LOOP combines
; both bytes.
EB_AND:
        LDY #0                ; op 0 = AND
        .DB $2C               ; BIT abs: swallows EB_OR's LDY #1 (2 bytes)
EB_OR:
        LDY #1                ; op 1 = OR
        .DB $2C               ; BIT abs: swallows EB_XOR's LDY #2 (2 bytes)
EB_XOR:
        LDY #2                ; op 2 = XOR
        ; falls into REL_SETUP

; =============================================================================
; REL_SETUP - combine T0 with the next operand by AND / OR / XOR
;   In:  T0 = left operand; Y = 0 AND / 1 OR / 2 XOR; IP at the operator token (consumed here)
;   Out: T0 = result; loops to EB_BOOL for chained operators
;   Clobbers: EXPR
; =============================================================================
REL_SETUP:
        JSR INC_IP       ; consume token
        LDA T0
        PHA
        LDA T0+1
        PHA
        PHY             ; stash op selector across the recursive parse
        JSR EXPR_ADD
        PLY             ; restore op selector
        LDX #1          ; byte offset: 1 (hi) then 0 (lo)
EB_LOOP:
        PLA                   ; left operand byte, hi first then lo
        CPY #1
        BCC EB_A              ; Y=0 -> AND
        BEQ EB_O               ; Y=1 -> OR
        EOR T0,X                ; Y=2 -> XOR
        .DB $2C                  ; BIT abs: swallows EB_A's AND T0,X
EB_A:
        AND T0,X
        .DB $2C                   ; BIT abs: swallows EB_O's ORA T0,X
EB_O:
        ORA T0,X
        STA T0,X
        DEX
        BPL EB_LOOP
        ; falls into EB_BOOL: look for a chained AND / OR / XOR
EB_BOOL:  ; boolean/bitwise operator loop (entered with the byte at IP not yet loaded)
        LDA (IP)
EB_BOOL_A:  ; EXPR enters here with A = the byte at IP
        CMP #TOK_AND
        BEQ EB_AND
        CMP #TOK_OR
        BEQ EB_OR
        CMP #TOK_XOR
        BEQ EB_XOR
        RTS

; =============================================================================
; EXPRESSION EVALUATOR - recursive descent
;   EXPR      one relational operator (= < > <= >= <>) or a chain of AND / OR / XOR
;             (a single tier: the two kinds do not chain, so parenthesise each side)
;   EXPR_ADD  + -
;   EXPR1     * / % MOD   (^ via EXPR_POW)
;   EXPR2     atoms: literals, variables, (expr), unary - + NOT, ABS SGN PEEK USR RND
;             SIN COS ASIN ACOS; CHR$ TAB HEX$ (PRINT only, via E2_CHRS)
; Every level:  In: IP = first token   Out: T0 = signed 16-bit result, IP past it
;   Clobbers: EXPR (see "Clobbers notation" in the file header). Left operands wait
;   on the hardware stack.
; EXPR_ADD and EXPR1 also return A = the byte at IP, so the caller's operator test needs
;   no reload.
; =============================================================================
; EXPR - relational or AND / OR / XOR level
;   Relational: one operator over two EXPR_ADD operands, result -1 / 0.
;   Boolean: AND / OR / XOR over EXPR_ADD operands, left to right.
;   In:  IP = first token
;   Out: T0 = result; IP past it
;   Clobbers: EXPR
; =============================================================================
EXPR:
        JSR EXPR_ADD         ; returns with A = the byte at IP
        CMP #'<'
        BCC REL_F            ; below '<': no operator (the usual case); REL_F is an RTS
        CMP #'>'+1
        BCS EB_BOOL_A        ; above '>': AND / OR / XOR, or nothing
        ; '<' '=' '>': falls into EB_REL

; =============================================================================
; Relational operator evaluator - bitmask algorithm
;   Operator mask accumulated in X: LT=1 EQ=2 GT=4. The left operand (in T0) is saved
;   on the hardware stack, the mask goes above it, and the right operand is evaluated
;   by EXPR_ADD (safe: EXPR_ADD/EXPR1/EXPR2 use the stack only for balanced local saves).
;   Signed compare: N XOR V (BVC / EOR #$80 / BMI), no extra scratch storage.
; =============================================================================
EB_REL:
        ; Save left operand on stack
        LDA T0
        PHA
        LDA T0+1
        PHA

        ; Scan relational operator chars, building bitmask in X.
        ; ASCII '<','=','>' are contiguous ($3C,$3D,$3E); subtract $3C to map
        ; to 0,1,2 and look up the bit via REL_MASK. Out-of-range chars (incl.
        ; wraparound for chars below '<') make SBC/CMP set carry -> BCS exits
        ; without consuming, since only the GETCI below (not reached) advances IP.
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
        STZ T0+1
        AND T2               ; Result bit AND operator mask
        BEQ REL_F            ; No overlap -> false
REL_T:
        DEC T0              ; Set True (-1)
        DEC T0+1             ; Set True
REL_F:
        RTS
REL_MASK:
        .DB 1, 2, 4          ; bit for <,=,> respectively (indexed by RL_LOOP)

; =============================================================================
; EXPR_ADD - addition and subtraction, left to right
;   In:  IP = first token
;   Out: T0 = result; IP past it
;   Clobbers: EXPR
; =============================================================================
EXPR_ADD:
        JSR EXPR1            ; returns with A = the byte at IP
EA_LP:
        CMP #'+'
        BEQ EA_DO
        CMP #'-'
        BEQ EA_DO
        RTS                  ; A = the byte at IP
EA_DO:
        PHA                  ; save operator  ('+' or '-')
        JSR INC_IP           ; consume it (A is the operator already: no reload needed)
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
        BEQ EA_SUB
        ; T0 = T1 + T0, inlined: no ADDT0_TO / TO_T0 calls
        CLC
        LDA T1
        ADC T0
        STA T0
        LDA T1+1
        ADC T0+1
        STA T0+1
EA_NX:
        LDA (IP)             ; next operator, or the byte EXPR_ADD returns in A
        BRA EA_LP
EA_SUB:
        ; T0 = T1 - T0, inlined: no NEG16 call (same 16-bit wrap as negate-then-add)
        SEC
        LDA T1
        SBC T0
        STA T0
        LDA T1+1
        SBC T0+1
        STA T0+1
        BRA EA_NX

; =============================================================================
; EXPR1 - multiply, divide, remainder (* / % MOD), left to right
;   The operator waits on the hardware stack: a fixed OP byte would not survive EXPR_POW
;   recursing into this routine for a parenthesised operand.
;   In:  IP = first token
;   Out: T0 = result; IP past it; OV ERR on division by zero
;   Clobbers: EXPR
; =============================================================================
EXPR1:
        ; Atom: a plain A-Z variable or a one-digit literal (the commonest cases) is loaded
        ; here; anything else goes through EXPR2. The front of EXPR_POW is inlined as well:
        ; EP_HAVE runs only when a '^' follows.
        LDA (IP)
        CMP #'A'
        BCC E1_NV               ; below 'A': a digit, or something EXPR2 handles
        SBC #'A'                ; C=1 from the CMP
        CMP #26
        BCS E1_GEN              ; not a variable letter
        ASL                     ; byte offset into VARS
        TAX
        LDA VARS,x
        STA T0
        LDA VARS+1,x
        STA T0+1
E1_INC:
        INC IP                  ; consume the letter or digit
        BNE E1_PW
        INC IP+1
        BRA E1_PW
E1_NV:
        EOR #'0'                ; '0'-'9' -> 0-9
        CMP #10
        BCS E1_GEN              ; not a digit (EXPR2 reloads the byte)
        STA T0
        STZ T0+1
        BRA E1_INC
E1_GEN:
        JSR EXPR2
E1_PW:
        LDA (IP)
        CMP #'^'
        BNE E1_CK            ; no '^': A is already the byte at IP
        JSR EP_HAVE
E1_LP:
        LDA (IP)
E1_CK:
        CMP #'*'
        BEQ E1_MD
        CMP #'/'
        BEQ E1_MD
        CMP #'%'             ; % operator: MOD (remainder)
        BEQ E1_MD
        CMP #TOK_MOD         ; MOD keyword: same as %
        BEQ E1_MOD_KW
E1_RTS:
        RTS                  ; not * / % MOD: nearest RTS is the loop exit; A = the byte at IP

E1_MOD_KW:
        LDA #'%'             ; normalise: treat MOD token as '%' for OP save
E1_MD:
        PHA                  ; stash operator on the hw stack (a fixed OP byte would not
        JSR INC_IP           ; survive EXPR_POW recursing into this routine via "(...)")
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EXPR_POW         ; right operand -> T0
        PLA
        STA T1+1             ; pop left into T1  (hi first)
        PLA
        STA T1
        PLA                  ; restore operator (safe now: recursion is done)
        STA OP
        CMP #'/'             ; zero-divisor check for / and %  (A already = OP)
        BEQ E1_DIVCHK
        CMP #'%'
        BNE E1_NOCHK
E1_DIVCHK:
        LDA T0               ; divisor zero?
        ORA T0+1
        BNE E1_NOCHK         ; non-zero: safe
E1_DIVCHK_OVFL:  ; zero: shared ERR_OV stub: EP_OVFL in EXPR_POW, below
        JMP EP_OVFL

E1_MOD_RESULT:
        LDX #T2-T0          ; remainder -> T0
        JSR TO_T0
        ; *** FALL THROUGH to E1_SIGN ***
        ; ---- shared sign postamble ----
E1_SIGN:
        PLA                  ; pull saved sign byte
        BPL E1_POS
        JSR NEG16            ; result should be negative
E1_POS:
        BRA E1_LP            ; tail jump to loop  (saves 1 RTS)

E1_NOCHK:
        LDA T1+1
        EOR T0+1
        PHA                  ; push result sign  (XOR of sign bits)
        BBR #7,T1+1,E1_P1    ; make T1 (left) positive
        JSR NEG_T1
E1_P1:
        BBR #7,T0+1,E1_P2    ; make T0 (right) positive
        JSR NEG16
E1_P2:
        LDA OP
        CMP #'*'
        BEQ E1_MUL_GO        ; '*' -> multiply
        ; ---- DIV: T1 = |T1| / |T0|, remainder in T2  ----
        JSR DIV_KERN
        LDA OP               ; MOD: result is remainder (T2), not quotient (T1)
        CMP #'%'
        BEQ E1_MOD_RESULT
        LDX #T1-T0          ; quotient -> T0
        JSR TO_T0
        BRA E1_SIGN

E1_MUL_GO:
        JSR MUL16_U           ; T2 = |T1| * |T0|
        LDX #T2-T0          ; result -> T0
        JSR TO_T0
        BRA E1_SIGN


; =============================================================================
; MUL16_U - unsigned 16-bit multiply
;   Both operands < 256: classic 8 x 8 shift-right multiply (8 fixed passes, product built in
;   A:T1, accumulator add is 8-bit). Otherwise shift-add costs one pass per significant bit
;   of the multiplier T1, so T1 is made the smaller operand first (the low 16 bits of the
;   product are the same either way) and the loop ends as soon as T1 = 0. Only the high
;   bytes are compared: with equal non-zero high bytes both operands have the same bit length.
;   In:  T0, T1 (both consumed as scratch)
;   Out: T2 = T0 * T1 mod 65536; T0 and T1 undefined
;   Clobbers: A X T0 T1 T2    Callers: EXPR1 (signed wrapper), EXPR_POW
; =============================================================================
MUL16_U:
        LDA T0+1             ; both operands < 256? (A = 0 on fall-through)
        ORA T1+1
        BNE MU_BIG
        LDX #8
        LSR T1               ; C = multiplier bit 0
MU8:
        BCC MU8S
        CLC
        ADC T0               ; A = high product byte
MU8S:
        ROR                  ; product shifts right through A into T1, replacing the
        ROR T1               ; multiplier bits as they are consumed
        DEX
        BNE MU8
        STA T2+1
        LDA T1
        STA T2
        RTS
MU_BIG:
        LDA T0+1             ; unsigned: T0 hi >= T1 hi -> T1 is already the smaller
        CMP T1+1
        BCS MU_GO
        LDA T0               ; swap T0 <-> T1
        LDX T1
        STX T0
        STA T1
        LDA T0+1
        LDX T1+1
        STX T0+1
        STA T1+1
MU_GO:
        STZ T2               ; clear accumulator
        STZ T2+1
MU_LP:
        LSR T1+1
        ROR T1
        BCC MU_MS
        CLC                  ; T2 += T0, inlined: no ADDT0_TO call in the hot loop
        LDA T2
        ADC T0
        STA T2
        LDA T2+1
        ADC T0+1
        STA T2+1
MU_MS:
        ASL T0
        ROL T0+1
        LDA T1               ; multiplier exhausted? (early exit)
        ORA T1+1
        BNE MU_LP
        RTS

; =============================================================================
; DIV_KERN - unsigned 16-bit restoring divide
;   If the dividend's high byte is below the divisor, the first 8 passes would only shift it
;   into the remainder: skip them (remainder = T1 hi, T1 lo moves up, 8 passes not 16).
;   This covers every divisor >= 256 and every dividend < 256.
;   Divisors < 256 use a loop that keeps the 8-bit remainder in A (DK_NLP); wider ones use
;   the 16-bit remainder loop (DK_LP).
;   In:  T1 = dividend, T0 = divisor (unsigned)
;   Out: T1 = quotient, T2 = remainder; T0 unchanged
;   Clobbers: A X Y T1 T2    Callers: EXPR1 (signed wrapper), EXPR_POW, SC_GO (angle mod 360)
; =============================================================================
DIV_KERN:
        STZ T2+1             ; remainder hi = 0 (the narrow loop never changes it)
        LDY #16
        LDA T0+1
        BNE DK_PRE           ; divisor >= 256: quotient < 256, take the fast path
        LDA T1+1
        CMP T0               ; divisor < 256: fast path iff dividend hi < divisor
        LDA #0               ; remainder = 0 for the full path (LDA keeps the CMP carry)
        BCS DK_NLP           ; no: full 16 passes
DK_PRE:
        LDY #8               ; 8 passes
        LDX T1
        LDA T1+1             ; remainder = dividend hi (already < divisor)
        STA T2
        STX T1+1             ; dividend lo moves into the shifter's top byte
        STZ T1               ; quotient accumulator
        LDX T0+1
        BEQ DK_NLP           ; divisor < 256: narrow loop, A = remainder
DK_LP:
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
        BCC DK_DS
        STX T2
        STA T2+1
        INC T1
DK_DS:
        DEY
        BNE DK_LP
        RTS
        ; Narrow divisor (< 256): the remainder stays below the divisor, so it lives in A.
        ; After the shift, carry = a 9th remainder bit: that always means remainder >= divisor.
        ; Both routes into DK_NSB have C = 1, so SBC needs no SEC.
DK_NLP:
        ASL T1
        ROL T1+1
        ROL                  ; A = remainder * 2 + next dividend bit; C = bit 8
        BCS DK_NSB
        CMP T0
        BCC DK_NDS           ; remainder < divisor: quotient bit stays 0
DK_NSB:
        SBC T0
        INC T1               ; quotient bit = 1
DK_NDS:
        DEY
        BNE DK_NLP
        STA T2               ; remainder
        RTS

; =============================================================================
; E2_RND - RND: next pseudo-random value (no argument)
;   16-bit Galois LFSR, taps $B400, period 65535, seed RND_SEED ($ACE1 after NEW).
;   Bit 15 is cleared, so the result is 0..32767 (0 occurs when the seed is $8000).
;   In:  IP at the RND token
;   Out: T0 = value; RND_SEED advanced; IP past RND
;   Clobbers: A
; =============================================================================
E2_RND:
        JSR INC_IP            ; consume RND token
        LDA RND_SEED
        STA T0
        LDA RND_SEED+1
        AND #$7F             ; force positive (clear bit 15)
        STA T0+1
        ; falls into RND_SHUFFLE
; =============================================================================
; RND_SHUFFLE - advance the LFSR one step (tap $B4: x^16+x^14+x^13+x^11+1)
;   Also called from GETCH's keyboard-wait loop, so the sequence depends on input timing.
;   Out: RND_SEED advanced
;   Clobbers: A
; =============================================================================
RND_SHUFFLE:
         LSR RND_SEED+1
         ROR RND_SEED
         BCC RS_SK
         LDA RND_SEED+1
         EOR #$B4
         STA RND_SEED+1
RS_SK:
        RTS

; =============================================================================
; E2_USR - USR(addr): call a machine-code routine
;   In:  T0 = addr (evaluated by EXPR2's function dispatch)
;   Out: routine entered with A = T0 lo; its RTS returns to EXPR2's caller; it may set T0
;   Clobbers: A X Y and whatever the routine changes
; =============================================================================
E2_USR:
        LDA T0                ; A = T0 lo on entry
        JMP (T0)            ; tail call

; =============================================================================
; E2_GRP - parenthesised sub-expression (expr)
;   Consumes the "(", evaluates the inner expression, then consumes the closing ")" by
;   tail call.
;   In:  IP at "("
;   Out: T0 = value; IP past ")"
;   Clobbers: EXPR
; =============================================================================
E2_GRP:
        JSR INC_IP            ; consume '('
        JSR EXPR             ; evaluate inner expression
        JMP INC_IP             ; consume ")" and return (tail call, out of BRA range)

; =============================================================================
; EXPR_POW - power (^), left to right
;   Binds tighter than * / % MOD, looser than atoms: unary - + NOT recurse into EXPR2 first, so
;   -2^2 = (-2)^2 = 4 and 2^3^2 = (2^3)^2 = 64. 0^0 = 1. A negative exponent, or a result
;   outside the signed 16-bit range, raises OV ERR (one 32767/|base| division before the
;   multiply loop; no silent wraparound as with "*"). Scratch: CZ exponent counter, CX |base|,
;   CY result, CX_SAV max safe base power, ATEMP negate flag.
;   Entries: EXPR_POW fetches the base; EP_HAVE is entered with the base in T0 and IP at "^".
;   In:  IP = base atom
;   Out: T0 = result; IP past the operand chain
;   Clobbers: EXPR
; =============================================================================
EXPR_POW:
        JSR EXPR2               ; base -> T0
EP_LP:
        LDA (IP)
        CMP #'^'
        BEQ EP_HAVE
        RTS                     ; not '^': loop exit (EP_HAVE is close, no JMP needed)
EP_HAVE:
        JSR INC_IP               ; consume '^'
        LDA T0                  ; save base on stack
        PHA
        LDA T0+1
        PHA
        JSR EXPR2               ; exponent -> T0

        LDA T0+1                ; negative exponent: undefined, error
        BPL EP_POS
EP_OVFL:
        LDA #ERR_OV             ; shared error stub: negative exponent OR
        JMP DO_ERROR            ;   overflow during the multiply loop below

EP_POS:
        STA CZ+1                ; A still holds T0+1 (exponent hi) from above
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

        BCC EP_ABS               ; exponent even: leave ATEMP = 0
        LDA T0+1
        STA ATEMP                ; exponent odd: ATEMP = base's original sign

EP_ABS:
        BBR #7,T0+1,EP_BASE_SET
        JSR NEG16                ; T0 = |base|

EP_BASE_SET:
        LDA T0                   ; |base| -> CX
        STA CX
        LDA T0+1
        STA CX+1

        LDA #1                   ; result magnitude starts at 1 -> CY
        STA CY
        STZ CY+1

        LDA CZ                   ; exponent == 0: result stays 1, done
        ORA CZ+1
        BEQ EP_SIGN

        LDA CX                   ; base == 0 (exponent > 0): result is 0, done
        ORA CX+1
        BNE EP_MAXSAFE
        STZ CY                   ; CY+1 already 0 from init above
        BRA EP_SIGN

EP_MAXSAFE:
        ; max_safe = 32767 / |base|  (T0 still holds |base| from EP_BASE_SET,
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

EP_LOOP:
        LDA CX_SAV+1             ; overflow check: CY > max_safe?
        CMP CY+1
        BCC EP_OVFL
        BNE EP_MUL
        LDA CX_SAV
        CMP CY
        BCC EP_OVFL
EP_MUL:
        LDX #CX-T0             ; CY *= CX  (safe: checked above)
        JSR TO_T0
        LDA CY
        STA T1
        LDA CY+1
        STA T1+1
        JSR MUL16_U
        LDA T2
        STA CY
        LDA T2+1
        STA CY+1

        LDA CZ                   ; exponent counter -= 1 (16-bit)
        BNE EP_DLO
        DEC CZ+1
EP_DLO:
        DEC                      ; 65C02 DEC A -- A still holds CZ's old low byte
        STA CZ
        ORA CZ+1
        BNE EP_LOOP

EP_SIGN:
        LDX #CY-T0
        JSR TO_T0

        BBR #7,ATEMP,EP_DONE  ; negate? (base negative and exponent odd)
        JSR NEG16                ; negate the result
EP_DONE:
        JMP EP_LP                ; loop back for chained ^ (left-associative)

; =============================================================================
; PNUM - consume an inline TOK_BYTE / TOK_HEX / TOK_NUM literal at IP
;   ASCII digits 0-9 never reach PNUM (EXPR2 decodes them). PNUM loads its own marker byte:
;   EDITLN and DP_HEX_ONLY call it that way. It sits just above EXPR2 so EXPR2's literal
;   test reaches it with a short BCS.
;   In:  IP -> marker ($FD TOK_BYTE, $FE TOK_HEX, $FF TOK_NUM)
;   Out: T0 = 16-bit value (hi = 0 for TOK_BYTE)
;        IP past the marker and payload (2 bytes for TOK_BYTE, 3 for TOK_HEX / TOK_NUM)
;   Clobbers: A Y
; =============================================================================
PNUM:
        LDA (IP)              ; load the marker byte
        CMP #TOK_HEX          ; C=1: TOK_HEX/TOK_NUM, C=0: TOK_BYTE
        LDY #1
        LDA (IP),y            ; lo byte (present in every form)
        STA T0
        LDA #2                ; advance amount if short (TOK_BYTE) form
        BCC PN_ADV             ; < TOK_HEX: TOK_BYTE confirmed, hi=0, advance 2
        INY                     ; TOK_HEX/TOK_NUM: a hi byte follows too
        LDA (IP),y
        STA T0+1
        LDA #3                   ; advance amount for the wide form
        .DB $2C                   ; swallow STZ T0+1 (BIT abs trick, saves 1 byte)
PN_ADV:
        STZ T0+1                 ; short form only: hi = 0
        CLC
        ADC IP
        STA IP
        BCC PN_DN
        INC IP+1
PN_DN:
        RTS

; =============================================================================
; EXPR2 - atoms: literals, variables, (expr), unary - + NOT, functions
;   The marker test comes first, on the unmodified byte: the digit and variable tests share
;   one subtraction (byte - "0"), which would wrap every byte below "0" (NUL, "(", ",", '"' ...)
;   into the marker range and misroute it to PNUM. A plain variable normally never gets here:
;   EXPR1 loads it inline.
;   In:  IP -> atom
;   Out: T0 = value; IP advanced
;   Clobbers: EXPR
; =============================================================================
EXPR2:
        LDA (IP)
        ; Marker check first, on the unmodified byte (see the header): the one subtraction
        ; below is then reused for both the digit and variable tests.
        CMP #TOK_BYTE         ; $FD/$FE/$FF: byte/dec/hex literal marker
        BCS PNUM
        SEC
        SBC #'0'              ; ch-'0' -- reused below for both digit and variable
        CMP #10
        BCC EXPR2_DIGIT       ; 0-9: ascii digit
        CMP #'A'-'0'
        BCC EXPR2_NV          ; catches punctuation between '9' and 'A'
        SBC #'A'-'0'        ; carry still set from the CMP above
        CMP #26               ; 0-25: variable letter
        BCS EXPR2_NV
        ASL                   ; byte offset into VARS
        TAX
        LDA VARS+1,x
        STA T0+1
        LDA VARS,x
        .DB $2C               ; swallow STZ T0+1 (BIT abs trick): the variable
                               ;  path already set T0+1 above, only the digit
                               ;  path below needs to zero it
EXPR2_DIGIT:
        STZ T0+1
        STA T0
        JMP INC_IP            ; consume the digit/letter and return
EXPR2_NV:
        LDA (IP)             ; reload the byte (the range test above consumed A)
        CMP #'('
        BNE EXPR2_NG
        JMP E2_GRP
EXPR2_NG:
        CMP #'-'
        BNE EXPR2_NG2
        BRA E2_NEG
EXPR2_NG2:
        CMP #'+'
        BNE EXPR2_NP
        JSR INC_IP            ; unary plus: no-op, the operand is an atom of its own
        BRA EXPR2
EXPR2_NP:
        CMP #TOK_NOT
        BNE EXPR2_NP2
        BRA E2_NOT
EXPR2_NP2:
        CMP #TOK_SGN
        BNE EXPR2_T1
        BRA E2_SGN

; =============================================================================
; EXPR2_T1 - function tokens, table-dispatched
;   TOK_RND ($A0) .. TOK_ACOS ($A7) are contiguous: RND (0-arg, no parens) sits at FUNC_LO;
;   ABS PEEK USR SIN COS ASIN ACOS (1-arg, in parens) follow and index FUNC_JT. Below FUNC_LO
;   the byte is not an atom (E2_BAD returns 0, consuming nothing); TOK_FEND and above raise
;   SN ERR before the table is indexed.
;   In:  A = token byte at IP
;   Out: T0 = value; IP past the call
;   Clobbers: EXPR
; =============================================================================
EXPR2_T1:
        CMP #TOK_RND          ; FUNC_LO
        BCS EXPR2_T1A         ; in range (>= FUNC_LO): continue below
; E2_BAD: not an atom (variables and numbers are handled at the top of EXPR2):
;   return 0 and consume nothing.
E2_BAD:
        STZ T0
        STZ T0+1
        RTS
EXPR2_T1A:
        BNE EXPR2_T1B          ; != FUNC_LO: not RND, continue below
        JMP E2_RND              ; == FUNC_LO: RND (0-arg, no parens)
EXPR2_T1B:
        CMP #TOK_FEND          ; upper bound: TOK_FEND and above is not a function token
        BCC EXPR2_T1C
        JMP RD_SN
EXPR2_T1C:
        ; TOK_ABS..TOK_ACOS: consume the token and eat "(" expr ")" into T0 here, then
        ; index FUNC_JT (word index = (token - TOK_ABS) * 2).
        SEC
        SBC #TOK_ABS
        ASL
        PHA                   ; stash word-index across the recursive JSR E2_CHRS below
        JSR E2_CHRS            ; consume token, eat '(' expr ')' -> T0
        PLX
        JMP (FUNC_JT,X)        ; 65C02 absolute indexed indirect

FUNC_JT:
        .DW E2_ABS, E2_PEEK, E2_USR, E2_SIN, E2_COS, E2_ASIN, E2_ACOS  ; TOK_ABS..TOK_ACOS ($A1-$A7)

; =============================================================================
; E2_PEEK - PEEK(addr): read one byte
;   In:  T0 = addr (evaluated by EXPR2_T1)
;   Out: T0 = byte, 0..255
;   Clobbers: A
; =============================================================================
E2_PEEK:
        LDA (T0)             ; 65C02 zp-indirect: read memory at addr
        STA T0
        STZ T0+1
        RTS

; =============================================================================
; E2_CHRS / E2_ARG1 - consume a function token and its "(" expr ")" argument
;   E2_CHRS steps over the token at IP, then falls into E2_ARG1. DO_PRINT uses it for TAB,
;   CHR$ and HEX$ (the value comes back unchanged in T0 for PRINT to emit); EXPR2_T1 and
;   E2_SGN use it for the other functions. CHR$, TAB and HEX$ are PRINT-only, not atoms.
;   In:  IP at the token (E2_CHRS) or at "(" (E2_ARG1)
;   Out: T0 = argument value; IP past ")"
;   Clobbers: EXPR
; =============================================================================
E2_CHRS:
        JSR INC_IP            ; consume the token
        ; falls into E2_ARG1
E2_ARG1:
        JSR EXPECT_LPAREN     ; require '(', then evaluate argument
        JMP INC_IP             ; consume the closing ")" (tail call)

; --- atom handlers (placed here so preamble BEQs above are in range) ---

; NOT: bitwise complement. No parens (like unary -): consume the token and recurse
; into EXPR2 for the operand. Going through E2_CHRS/E2_ARG1 would take the operand's
; first byte as "(".
E2_NOT:
        JSR INC_IP    ; consume NOT token
        JSR EXPR2    ; evaluate operand directly (no paren expected)
        ; NOT x  ==  -(x+1); reuse NEG16 instead of a fresh EOR #$FF pair
        INC T0
        BNE E2_NOT_SK
        INC T0+1
E2_NOT_SK:
        BRA N16TRAMP  ; tail call: negate (shared trampoline, see E2_NEG/E2_ABS)


E2_NEG:
        JSR INC_IP            ; unary minus
        JSR EXPR2
        BRA N16TRAMP         ; NEG16 tail call trampoline

; =============================================================================
; SHIFT_R16_T0 - logical right shift of T0
;   E2_ABS_POS is the RTS shared with E2_ABS.
;   In:  T0 = value; X = count (> 0)
;   Out: T0 shifted right X times, no sign extension
;   Clobbers: X
; =============================================================================
SHIFT_R16_T0:
        LSR T0+1
        ROR T0
        DEX
        BNE SHIFT_R16_T0
E2_ABS_POS:
        RTS

; =============================================================================
; E2_ABS - ABS(n): absolute value
;   In:  T0 = n (evaluated by EXPR2_T1)
;   Out: T0 = |n|
;   Clobbers: A X
; =============================================================================
E2_ABS:
        BBR #7,T0+1,E2_ABS_POS
N16TRAMP:
        JMP NEG16            ; tail call: negate if negative

; =============================================================================
; CK_SH - arithmetic right shift of a 16-bit zero-page word into T0
;   The high byte stays in A for the whole loop: CMP #$80 puts the sign in C, so each
;   shift is CMP / ROR A / ROR lo, with no high-byte memory traffic.
;   In:  X = (source - T0); CIDX = shift count (0..15); source may be T0 itself
;   Out: T0 = source >> CIDX, sign-extended (0 = plain copy); X = 0 (callers rely on it)
;   Clobbers: A X
; =============================================================================
CK_SH:
        LDA T0,x
        STA T0
        LDA T0+1,x
        LDX CIDX
        BEQ CK_SD
CK_SL:
        CMP #$80              ; C = sign bit
        ROR                   ; high byte
        ROR T0                ; low byte
        DEX
        BNE CK_SL
CK_SD:
        STA T0+1
        RTS

; =============================================================================
; E2_SGN - SGN(n): -1, 0 or 1
;   A 15-place arithmetic shift (CK_SH) gives $0000 or $FFFF; OR-ing the low byte with 1
;   turns that into +1 or leaves -1.
;   In:  IP at the SGN token
;   Out: T0 = -1, 0 or 1; IP past ")"
;   Clobbers: EXPR CIDX
; =============================================================================
E2_SGN:
        JSR E2_CHRS           ; consume token, eat '(' expr ')' -> T0
        LDA T0
        ORA T0+1
        BEQ E2_SGN_RTS        ; zero -> T0 already 0, nothing to do
        LDA #15
        STA CIDX
        LDX #0
        JSR CK_SH             ; T0 = n >> 15 = $0000 if n > 0, $FFFF if n < 0
        LDA T0
        ORA #1
        STA T0                ; +1 if positive; stays $FF (-1) if negative
E2_SGN_RTS:
        RTS

; =============================================================================
; CORDIC_KERN - rotation-mode CORDIC, 12 iterations
;   In:  CX = 6042, CY = 0, CZ = angle in CORDIC units (0..16380 = 0..90 degrees)
;   Out: CX = cos * 9949, CY = sin * 9949 (signed 16-bit)
;   Clobbers: A X T0 CX CY CZ CX_SAV CIDX
; =============================================================================
CORDIC_KERN:
        LDX #0
CK_IT:
        STX CIDX
        LDA CX
        STA CX_SAV
        LDA CX+1
        STA CX_SAV+1

        ; 1) CX = CX -/+ (CY >> i)
        LDX #CY-T0
        JSR CK_SH            ; T0 = CY >> i
        BBS #7,CZ+1,CK_P1    ; CZ<0: want ADD, skip negate
        JSR NEG_X            ; CZ>=0: want SUB, negate T0 (X = 0 from CK_SH) then add
CK_P1:
        LDX #CX-T0
        JSR ADDT0_TO

        ; 2) CY = CY +/- (CX_SAV >> i)
        LDX #CX_SAV-T0
        JSR CK_SH            ; T0 = CX_SAV >> i
        BBR #7,CZ+1,CK_P2    ; CZ>=0: want ADD, skip negate
        JSR NEG_X            ; CZ<0: want SUB, negate T0 (X = 0 from CK_SH) then add
CK_P2:
        LDX #CY-T0
        JSR ADDT0_TO

        ; 3) CZ = CZ -/+ ATAN_TBL[i], branchless: CZ + (ATAN EOR M) + C, where M = $FF and
        ;    C = 1 (two's complement subtract) for CZ >= 0, M = 0 and C = 0 (add) for CZ < 0
        LDA CIDX
        ASL
        TAX
        LDA CZ+1
        ASL                  ; C = sign of CZ
        LDA #0
        SBC #0               ; A = $FF if CZ >= 0, else $00
        CMP #$FF             ; C = 1 if CZ >= 0 (A unchanged)
        STA T0               ; T0 = mask M
        LDA ATAN_TBL,x
        EOR T0
        ADC CZ
        STA CZ
        LDA ATAN_TBL+1,x
        EOR T0
        ADC CZ+1
        STA CZ+1

        LDX CIDX
        INX
        CPX #12
        BNE CK_IT
        RTS

; =============================================================================
; E2_COS / E2_SIN / SC_GO - COS(deg) * 1000 / SIN(deg) * 1000
;   E2_COS sets ATEMP = $80 (COS), E2_SIN sets ATEMP = $00 (SIN); SC_GO is also entered
;   directly by E2_ASIN/E2_ACOS with ATEMP already set, and reads it to pick CX or CY.
;   Any signed 16-bit angle is reduced by one DIV_KERN by 90: Q = |angle| / 90 gives the
;   quadrant Y = Q mod 4 (4 * 90 = 360, so angles past 360 wrap), R = |angle| mod 90 the
;   fold angle (R for even Y, 90 - R for odd Y). Quadrant flags (bit0 negate CX/cos, bit1
;   negate CY/sin) are the Gray code Y EOR (Y>>1); a final EOR #2 flips the sin flag for a
;   negative input (sin is odd, cos is even). T1 holds the flags.
;   In:  T0 = angle in degrees (evaluated by EXPR2_T1)
;   Out: T0 = result, -1000..1000
;   Clobbers: A X Y T0 T1 T2 CX CY CZ CX_SAV CIDX (E2_SIN/E2_COS also ATEMP)
; =============================================================================
E2_COS:
        LDA #$80            ; $80 = COS engine
        STA ATEMP
        .DB $2C             ; BIT abs opcode (skips STZ ATEMP)
E2_SIN:
        STZ ATEMP           ; $00 = SIN engine
SC_GO:
        ; ---- one DIV_KERN call gives the quadrant (Q mod 4 -> Y) and the fold angle R ----
        LDA T0+1
        PHA                  ; save original sign (bit 7) for the sin(-x) fixup
        BPL SC_ABS
        JSR NEG16            ; T0 = |angle|
SC_ABS:
        LDA T0               ; angle -> T1 (dividend for DIV_KERN)
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

        LDX #T2-T0
        JSR TO_T0            ; T0 = R (0..89)

        TYA
        LSR                  ; odd quadrant? (bit0 -> Carry)
        BCC SC_EVEN
        LDA #90              ; odd: fold = 90 - R
        SBC T0               ; Carry is set (from BCC above): exactly 90-T0
        STA T0               ; T0+1 already 0 from TO_T0
SC_EVEN:
        TYA                  ; Gray code: flags = Y EOR (Y>>1)
        STA T1
        LSR
        EOR T1

        PLX                  ; original sign back (65C02 PLX sets N)
        BPL SC_FLAGS
        EOR #2               ; negative input: sin is odd -> flip CY flag
SC_FLAGS:
        STA T1              ; save quadrant flags
        ; Multiply T0 (0-90) * 182 -> CZ (182=0b10110110)
        LDA #182
        STA T2              ; use T2 as multiplier shift reg
        STZ CZ
        STZ CZ+1
        LDX #8
SC_ML:
        LSR T2              ; bit -> C
        BCC SC_MN
        LDX #CZ-T0
        JSR ADDT0_TO
SC_MN:
        ASL T0
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
SC_NCX:
        LSR T1              ; bit1 -> C: negate CY?
        BCC SC_NCY
        LDX #CY-T0
        JSR NEG_X
SC_NCY:
        ; Result select: ATEMP=0->SIN(CY), ATEMP=$80->COS(CX)
        LDX #CY-T0        ; default: SIN
        LDA ATEMP
        BEQ SC_SEL
        LDX #CX-T0        ; switch to COS
SC_SEL:
        JSR TO_T0
SC_SCALE:
        ; Absolute value (preserve sign on stack to avoid clobbering ATEMP)
        LDA T0+1
        PHA                 ; Push sign byte
        BPL SC_SDO
        JSR NEG16           ; make positive for scaling
SC_SDO:  ; >>4 (logical; val positive here)
        LDX #4
        JSR SHIFT_R16_T0
        ; *103 -> T2 (16-bit: max 63963)
        LDA #103
        STA T1
        STZ T2
        STZ T2+1
        LDX #8
SC_SML:
        LSR T1
        BCC SC_SMN
        LDX #T2-T0
        JSR ADDT0_TO
SC_SMN:
        ASL T0
        ROL T0+1
        DEX
        BNE SC_SML
        ; >>6: T0 = T2>>6
        LDX #T2-T0
        JSR TO_T0
        LDX #6
        JSR SHIFT_R16_T0
        ; Apply sign
        PLA                 ; Pull sign byte
        BPL SC_DONE
        ; drop through

; =============================================================================
; NEG16 / NEG_T1 / NEG_X - two's-complement negate T0 / T1 / the pair at T0+X
;   NEG16 loads X=0 and NEG_T1 loads X=2 (BIT abs hides the other LDX); NEG_X is entered
;   with X preloaded: LDX #CX-T0 / JSR NEG_X negates CX. SC_DONE is the shared RTS.
;   In:  the value at T0, T1 or T0+X
;   Out: that location holds 0 - value
;   Clobbers: A X
; =============================================================================
NEG16:
        LDX #0               ; X=0: address offset to T0
        .DB $2C            ; BIT abs: skips NEG_T1's LDX #2
NEG_T1:
        LDX #2               ; X=2: address offset to T1 from T0
NEG_X:  ; entry with X pre-loaded by caller
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
; E2_ASIN / E2_ACOS - ASIN(v) / ACOS(v), v = -1000..1000 (the SIN/COS x 1000 scale)
;   No sqrt and no new CORDIC mode: an integer degree is binary-searched (8 iterations) with
;   SC_GO as the angle -> scaled value oracle, one 12-iteration CORDIC per step. The result is
;   a whole degree, so ASIN(SIN(d)) = d up to CORDIC rounding noise. |v| > 1000 is clamped to
;   1000 (not an error). AMODE: bit0 = ACOS, bit7 = v negative. ATEMP ($00 ASIN / $80
;   ACOS) is set once and read by SC_GO.
;   In:  T0 = v (evaluated by EXPR2_T1)
;   Out: T0 = angle in degrees: ASIN -90..90, ACOS 0..180
;   Clobbers: A X Y T0 T1 T2 CX CY CZ CX_SAV CIDX ATEMP AAV ALO AHI AMID AMODE
; =============================================================================
E2_ASIN:
        LDA #0              ; bit0=0: ASIN
        .DB $2C             ; BIT abs opcode (skips LDA #0)
E2_ACOS:
        LDA #1              ; bit0=1: ACOS
        STA AMODE
EA_BODY:
        ; Extract sign, reduce T0 to |v|
        BBR #7,T0+1,EA_NONNEG
        LDA #$80
        TSB AMODE           ; 65C02 TSB: sets bit 7 for a negative input
        JSR NEG16           ; T0 = |v|
EA_NONNEG:
        ; -- clamp |v| to 1000 --
        LDA #<1000
        CMP T0
        LDA #>1000
        SBC T0+1
        BCS CL_OK      ; If Carry is set (no borrow), 1000 >= T0. We are good!

CL_CLAMP:
        LDA #<1000
        STA T0
        LDA #>1000
        STA T0+1
CL_OK:

        ; Search range: 0..90 for ASIN, 0..180 for ACOS
        LDA AMODE
        LSR                ; bit 0 -> Carry (1=ACOS, 0=ASIN)
        LDA #90
        BCC EA_R_DN
        ASL                ; 90 -> 180
EA_R_DN:
        STA AHI
        STZ ALO

        ; ACOS negative input ($81): invert target sign
        LDA AMODE
        CMP #$81
        BNE EA_TARGET
        JSR NEG16

EA_TARGET:
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
EA_LOOP:
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
        BEQ EA_FEAS         ; D == 0 is always feasible

        LDA T1+1
        EOR ATEMP           ; Invert sign bit for ACOS ($80)
        BMI EA_INFEAS

EA_FEAS:
        LDA AMID
        STA ALO
        BRA EA_NEXT

EA_INFEAS:
        LDA AMID
        BEQ EA_NEXT         ; Guard: mid==0
        DEC                ; 65C02 DEC A
        STA AHI

EA_NEXT:
        DEX
        BNE EA_LOOP

        ; Result: ALO is converged degree
        LDA ALO
        STA T0
        STZ T0+1
        LDA AMODE
        CMP #$80            ; ASIN with negative input is $80
        BNE EA_DONE
        JMP NEG16           ; Negate result for ASIN

; =============================================================================
; 16-bit zero-page helpers: TO_T0, T0_TO_CURLN, ADDT0_TO, GETVARC, CMP16, CMP_T0_LP, STORE_VAR
;   Indexed ones take X = (zero-page address - T0), preloaded by the caller; zero-page,X
;   wraps mod 256, so they reach any zero-page location.
; =============================================================================

; =============================================================================
; TO_T0 - copy a 16-bit zero-page value into T0
;   EA_DONE is the RTS shared with E2_ASIN's exit.
;   In:  X = (source - T0)
;   Out: T0 = source
;   Clobbers: A
; =============================================================================
TO_T0:
        LDA T0,x
        STA T0
        LDA T0+1,x
        STA T0+1
EA_DONE:
        RTS

; =============================================================================
; T0_TO_CURLN - copy T0 into CURLN (fixed operands, no X)
;   In:  T0
;   Out: CURLN = T0
;   Clobbers: A
; =============================================================================
T0_TO_CURLN:
        LDA T0
        STA CURLN
        LDA T0+1
        STA CURLN+1
        RTS

; =============================================================================
; ADDT0_TO - add T0 into a 16-bit zero-page accumulator
;   In:  X = (destination - T0); T0 = addend
;   Out: destination += T0 (16-bit, wraps)
;   Clobbers: A (and C)
; =============================================================================
ADDT0_TO:
        CLC
        LDA T0,x
        ADC T0
        STA T0,x
        LDA T0+1,x
        ADC T0+1
        STA T0+1,x
        RTS

; =============================================================================
; GETVARC - read the next char, uppercase it, subtract "A"
;   In:  IP
;   Out: A = char - "A" (0-25 for a letter); flags from the SBC; IP advanced
;   Clobbers: A
; =============================================================================
GETVARC:
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        RTS

; =============================================================================
; CMP16 - compare two 16-bit zero-page values for equality
;   Uses ZP0 (a permanent $0000 pointer): (ZP0),Y addresses zero-page byte Y, since CMP has
;   no zp,Y form. Exits early when the low bytes differ.
;   In:  X = zero-page address of the first value; Y = address of the second
;   Out: Z=1 iff equal; Y is incremented when the low bytes matched, so reload it before reuse
;   Clobbers: A Y
; =============================================================================
CMP16:
        LDA $00,x
        CMP (ZP0),y
        BNE CMP16_NE
        INY
        LDA $01,x
        CMP (ZP0),y
CMP16_NE:
        RTS

; =============================================================================
; CMP_T0_LP - compare T0 with LP for equality
;   Does not touch Y (unlike CMP16): both call sites are in INSLINE's backward copy loop,
;   which holds Y = 0 for its (T0),Y / (T1),Y addressing.
;   Out: Z=1 iff T0 = LP
;   Clobbers: A
; =============================================================================
CMP_T0_LP:
        LDA T0
        CMP LP
        BNE CMP_T0_LP_NE
        LDA T0+1
        CMP LP+1
CMP_T0_LP_NE:
        RTS


; =============================================================================
; DO_LET - LET var = expr (the LET keyword is optional)
;   In:  IP at the optional LET, then the variable, "=" and the expression
;   Out: VARS[var] = value; IP past the assignment
;        no letter: nothing happens; a letter not followed by "=": UK ERR
;   Clobbers: EXPR
; =============================================================================
DO_LET:
        LDA (IP)
        CMP #TOK_LET
        BNE DO_LET_VAR
        JSR INC_IP            ; consume optional LET keyword
DO_LET_VAR:
        JSR PARSE_VAR
        BCS DO_LET_DN        ; not a letter: nothing to assign
        PHA                  ; save var slot
        LDA (IP)
        CMP #'='
        BNE DO_LET_POP
        JSR INC_IP            ; consume '='
        JSR EXPR
        PLX
        ; falls into STORE_VAR
; =============================================================================
; STORE_VAR - store T0 into VARS[X]
;   In:  T0; X = variable slot * 2
;   Out: VARS[X] = T0
;   Clobbers: A
; =============================================================================
STORE_VAR:
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
DO_LET_DN:
        RTS

DO_LET_POP:
        PLA
        LDA #ERR_UK
        JMP DO_ERROR

; =============================================================================
; PRT16 - print T0 as a signed decimal integer
;   Shift-and-subtract division by 10 extracts a digit; recursion prints the most significant
;   digit first without a digit buffer. A negative value prints "-" and is negated. The last
;   digit falls through (BIT abs over PRTSP) into PUTCH. PRT16GO is the recursion entry
;   (sign already handled).
;   In:  T0 = signed 16-bit value
;   Out: digits printed; T0 destroyed
;   Clobbers: A X Y T0
; =============================================================================
PRT16:
         BBR #7,T0+1,PRT16GO  ; positive: skip sign handling
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
; PRTSP - print a space
;   Out: space sent to PUTCH
;   Clobbers: A
; =============================================================================
PRTSP:
        LDA #' '
        ; drop through
; =============================================================================
; PUTCH - send A to the terminal
;   In:  A = character
;   Out: character written to IO_PUTCH
;   Clobbers: none
; =============================================================================
PUTCH:
        STA IO_PUTCH
        RTS

; =============================================================================
; PRT_HEX / PRT_HEXB / PRT_HEXN - print "$" and T0 as 4 hex digits / A as 2 / A's low nibble as 1
;   PRT_HEX falls into PRT_HEXB (lo byte), which falls into PRT_HEXN (lo nibble);
;   PRT_HEXN tail-calls PUTCH. Digits are upper case, MSB first, leading zeros kept.
;   In:  T0 (PRT_HEX) or A (PRT_HEXB, PRT_HEXN)
;   Out: characters sent to PUTCH
;   Clobbers: A
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
; SKIP_STMT - advance IP to the end of the current statement
;   Exits through PARSE_VAR's tails: SKST_COLON (C=0) and SKST_EOL (C=1).
;   In:  IP anywhere within a statement's tokens
;   Out: IP at the terminating byte (":" or NUL), not past it; C=0 stopped at ":", C=1 at NUL
;   Clobbers: A
; =============================================================================
SKIP_STMT:
        LDA (IP)
        BEQ SKST_EOL
        CMP #':'
        BEQ SKST_COLON
        JSR SKIP_LIT          ; skip literal payload, if any
        JSR INC_IP            ; Shared increment (applies to all non-terminal tokens)
        BRA SKIP_STMT

; =============================================================================
; PARSE_VAR - parse one A-Z variable letter at IP
;   Token-stream letters are always upper case (TOKENIZE uppercases them).
;   In:  IP at the letter
;   Out: C=0: A = VARS byte offset (0, 2 .. 50); IP past the letter
;        C=1: not a letter; IP unchanged, A undefined
;   Clobbers: A
; =============================================================================
PARSE_VAR:
        LDA (IP)             ; token-stream letters are always upper case (TOKENIZE UCs them)
        SEC
        SBC #'A'
        CMP #26              ; 0-25 = valid letter
        BCS PV_FAIL          ; C=1 on this path too
        JSR INC_IP           ; consume the letter (INC_IP leaves A and C alone)
        ASL                  ; x2: byte offset into VARS
SKST_COLON:
        CLC
        RTS
SKST_EOL:
PV_FAIL:
        SEC
        RTS

; =============================================================================
; UC - uppercase A if it is a-z
;   In:  A = any byte
;   Out: A uppercased; every other byte unchanged
;   Clobbers: flags
; =============================================================================
UC:
        CMP #'a'
        BCC UC_D
        CMP #'z'+1
        BCS UC_D
        AND #$DF
UC_D:
        RTS

; =============================================================================
; TOKSKIP_IP - scan (IP),Y for the NUL line terminator, skipping number payloads
;   Payload bytes (the lo/hi of TOK_NUM/TOK_HEX, the value of TOK_BYTE) may be $00.
;   In:  Y = starting offset
;   Out: Y = offset just past the NUL
;   Clobbers: A X Y
; =============================================================================
TOKSKIP_IP:
TSIP:
        LDA (IP),y
        INY
        CMP #TOK_BYTE          ; TOK_BYTE/TOK_HEX/TOK_NUM marker?
        BCC TSIP_CHK
        INY                     ; at least 1 payload byte (TOK_BYTE/HEX/NUM)
        CMP #TOK_HEX
        BCC TSIP_CHK             ; TOK_BYTE: done after its 1 payload byte
        INY                       ; TOK_HEX/TOK_NUM: a 2nd payload byte
TSIP_CHK:
        TAX                   ; Z iff NUL terminator
        BNE TSIP
        RTS

; =============================================================================
; DO_ELSE_SK / SKIPEOL - skip the rest of the line, past its NUL
;   DO_ELSE_SK is the bare-ELSE handler: the false branch of an IF has consumed the THEN
;   body, so RUNLP's next STMT call sees ELSE first and just discards the line.
;   SKIPEOL loops over ":"-separated statements with SKIP_STMT.
;   In:  IP anywhere in a line's tokens
;   Out: IP = first byte of the next line
;   Clobbers: A
; =============================================================================
DO_ELSE_SK:
SKIPEOL:
        JSR SKIP_STMT         ; C=0 at ':', C=1 at NUL
        JSR INC_IP              ; advance past whichever terminator we stopped at
        BCC SKIPEOL            ; ':' -> more statements on this line: keep scanning
        RTS                     ; NUL -> IP now points past it

; =============================================================================
; I/O STUBS - Kowalski virtual terminal
; =============================================================================
; GETCH - wait for a character
;   Polls IO_GETCH and advances the RND LFSR while it waits, so RND depends on key timing.
;   Out: A = character
;   Clobbers: A (RND_SEED advances)
; =============================================================================
GETCH:
        JSR RND_SHUFFLE
        LDA IO_GETCH         ; poll Kowalski virtual port
        BEQ GETCH             ; 0 = no char yet: spin
        RTS

; =============================================================================
; DATA TABLES
; CORDIC atan table: Value[i] = round(16384 * atan(2^-i) / 90), i.e. atan(2^-i) in units
;   where 16384 = 90 degrees. 12 entries x 2 bytes.
ATAN_TBL:
        .DW 8192, 4836, 2555, 1297, 651, 326, 163, 81, 41, 20, 10, 5

ROMEND = *                   ; first byte after executable ROM code

; =============================================================================
; Vectors
        .ORG $FFFC
        .DW INIT             ; $FFFC RESET
        .DW INIT             ; $FFFE IRQ/BRK (no interrupt handler: IRQs stay masked)
