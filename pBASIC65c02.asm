; =============================================================================
; PicoBASIC6502 v2.0 -- Proof of Concept 1 KB Tiny BASIC for NMOS 6502
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; NMOS port of PicoBASIC65c02 v1.10: same language, same showcase output.
; Assembled with .opt proc6502, so any 65C02-only opcode is a hard error.
;
;   CPU    : NMOS 6502 (no 65C02 opcodes but will also run on a 65C02)
;   ROM    : 1 KB  $FC00-$FFFF - use 2kbyte for development, see ORIGIN label
;   RAM    : 1 KB  $0000-$03FF
;   I/O    : Kowalski emulation $E001 PUTCH, $E004 GETCH (memory mapped)
;   NMI/IRQ: Not used (all three vectors point at INIT)
;
; KOWALSKI build switch:
;   1 = Kowalski simulator: execution starts at $0000 (a JMP INIT trampoline that
;       T0/T1 then overwrite) and PE preloads the showcase program at PROG.
;   0 = real hardware: Reset vector -> INIT, empty program store.
KOWALSKI        = 1
;
; RAM layout for 1 KB target:
;   $0000-$006B  zero-page in use (T0-T3/IP/PE/LP/RUN/VARS/IBUF, see ZPEND)
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full word or 2-letter prefix):
;   <var>=<expr>  ASK <var>  END  GOTO <expr>  IF <expr> <stmt>  PRINT  WR <expr>
;   LIST  NEW  RUN
;
; ASK is INPUT's keyword -- 'I' already taken by IF, see TOK_CHARS.
; WR <expr> emits an ASCII char - replaces CHR$, not usable in PRINT.
;
; Arithmetic: + - * /  (unary -), strictly left to right
; Relops    : =  <  only -- see KNOWN LIMITATIONS
; Numbers   : signed 16-bit  (-32768 .. 32767)
; Print     : "literals", `;` - no string vars
;
; NMOS CONVENTIONS -- the always-taken branches (BNE/BEQ/BCS/BMI used as BRA) and the
; (zp),Y accesses depend on these.  Keep them true when editing:
;   - WPEEK, GETCI and BUMP_LP return with Y=0 (BUMP_IP leaves Y alone).  PNUM and
;     SKIP_KW rely on it; EL_CHK_CR's header store follows WPEEK with INY.
;     PE_CMP_LP and MATCH_DISPATCH set Y=1 for the hi-byte read, then DEY.
;   - PUTCH preserves flags (STA/RTS only).  LS_BODY, DP_STR, DO_ERROR and DO_INPUT
;     branch on flags set before a PUTCH.  A polling UART PUTCH must save/restore
;     the flags, or those four branches become JMPs (+4 bytes).
;   - GETCI and BUMP_IP return Z=0 (IP never points into page $FF).
;   - ROM is at $8000 or above (DO_GO's BMI tests a return-address high byte).
;   - T0 is zero-page $00 (LDX #T0 gives Z=1, LDY #T0 gives Y=0); >PROG is non-zero.
;
; KNOWN LIMITATIONS
;
; GETLINE - no Backspace support or range limits - too many characters will crash.
;
; DO_ERROR - minimal error handling: "!X", where X is the error code, no line number.
;
; EDITLN is append-only: a typed line is accepted only when its number is greater than
;   every stored line (appended) or equal to the LAST stored line (replaced in place,
;   or deleted if the body is empty).  A lower number is rejected with "!5", so order
;   stays sequential and no sorting is needed.
;
; No operator precedence: all operators (+,-,*,/,=,<) evaluate left to right,
;   same tier. Use parentheses to group, e.g. "A*A/64-B*B/64+C" must be written
;   "(A*A/64)-(B*B/64)+C" for standard-math meaning; "1+2*3" evaluates
;   as (1+2)*3=9, not 7. Same-operator chain (all */ or all +-,
;   e.g. "2*A*B/64") needs no parens.
;
; Relops: Only "<" and "=" are supported - use flipped operands
;   for ">", e.g. "A>B" as "B<A".  Results are $FFFF (true) / $0000 (false), so
;   "A<>B" is "(A<B)+(B<A)", "A<=B" is "A<(B+1)" and "A>=B" is "(B-1)<A".
;
; IF <expr> <stmt> - no THEN keyword "IF 3<5 PRINT 1" not "IF 3<5 THEN PRINT 1".
;   Nests freely since IF is itself a statement: "IF a IF b stmt".
;
; Keyword matching - only the first 2 letters are matched, then the rest of the
;   word is consumed up to the first non-letter.  Spaces are needed: "10 PRINT A"
;   and "10 PR A" both work, "10 PRINTA" does not.
;
; Char Case: All characters must be UPPERCASE apart from PRINT string literals
;
; To save space, LET, REM and THEN keywords are not used.
;
; DO_GO - "GO 10" as FIRST/immediate command (no active RUN) fails since
;   DO_GO discards caller's return address assuming RUNEND will eventually be
;   reached via a RUN session's call.
;
; Arithmetic overflow wraps silently (e.g. 32767+1 = -32768) - no error is raised.
;
; Error codes (printed as "!<code>")
;   !0  syntax / bad expression (not implemented)
;   !1  undefined line number
;   !2  division by zero
;   !3  out of memory (not implemented)
;   !4  bad variable name
;   !5  line editing error
;
; ---- program storage --------------------------------------------------------
;   Base $0180 to ceiling RAM_TOP ($0400 for 1 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; =============================================================================
; CHANGE HISTORY
; =============================================================================
;
; v2.0 - NMOS 6502 port of v1.10, 25 bytes free before vectors.
;   - No 65C02 opcodes (.opt proc6502).  Output identical to v1.10
;   - BRA (20): 15 are now always-taken 2-byte conditionals, each commented with the
;     flag guarantee it relies on; 5 stay JMP (REL_T, E1_POS, MAIN, EL_EXIT, DO_WR).
;   - LDA/STA (zp) (8 sites) -> (zp),Y.  WPEEK/GETCI/BUMP_LP leave Y=0, so PNUM,
;     SKIP_KW, CMP_PLP_X, MATCH_DISPATCH and EL_CHK_CR need at most a DEY/INY 
;   - STZ (8) -> LDA #0/STA, or STY where Y=0 is guaranteed (PNUM) (+8).
;   - BBR/SMB (5) -> BIT or LDA + BPL; RUN flag is INX/STX, tested with LDA 
;   - PHX/PLX (3) -> TXA,PHA / PLA,TAX 
;   - JMP (TOK_VECS,X) -> RTS dispatch: TOK_VECS split into TOK_LO/TOK_HI holding
;     handler-1.  LDA T1/CMP T0 now follow the pushes so their flags reach the
;     handler; X is the unscaled index, so TXA/ASL/TAX is gone 
;   - CLD added to INIT: NMOS reset leaves D undefined
;   - File Header updates rewritten.
;
; v1.10 - 62 bytes free before vectors - Golf Pass, features cut
;   - Relop '!' modifier removed, Showcase updated to -2<1 and 2*3=6.
;   - Unary '+' removed from EXPR2 (-4); E2_POS now only serves unary '-'.
;   - DIV by zero detected from NEG_T0's carry (C=1 only if operand was 0):
;     DIV_ENTRY zero test gone, BCS E1_OVFL in DIV_LOOP, E1_OVFL moved in range (-4).
;   - PE_CMP_LP split: PE_CMP_X (X = ZP pointer offset) also used by RUNLP (-3).
;   - GETLINE: X = absolute IBUF index, no LDA #IBUF / LDX #0 (-2).
;   - DO_INPUT joins DO_LET at DL_EXPR instead of own JSR EXPR / BRA STORE_VAR (-3).
;
; v1.9 - 25 bytes free before vectors - Golf Pass 
;   - CURLN deleted as RUN/GOTOL wrote it but nothing but EDITLN read it.
;     RL_GO now just skips the 2 header bytes; GOTOL no longer stores it;
;     T0_TO_CURLN (and its BIT-skip) gone.  ZP shrinks by 2 (IBUF/VARS move down).
;   - EDITLN keeps the target line number in T0 (not CURLN); the matched-last-line
;     start is pushed on the HW stack (restored into both LP and PE) instead of
;     T0 + two T0_TO_X calls.  T0_TO_X helper merged into STORE_VAR (only user).
;   - EDITLN no longer a subroutine: MAIN branches (BCC) to it and it ends BRA MAIN
;     (saves JSR/BRA/RTS).  Laid out right after MAIN, then the error stubs so its
;     rejection branches reach DO_ERR_EL directly (EL_ERR JMP gone).  DO_ERROR uses
;     EDITLN's closing BRA MAIN (EL_EXIT) as a relay (MAIN out of BRA range).
;   - EXPR_LOOP's shared out-of-tokens RTS (EL_RTS) is now NEG_X's RTS.
;   - PARSE_VAR tail is now JMP BUMP_IP (+1): out of BRA range after the re-layout.
;   - GOTOL leaves IP at the line *header*; DO_GO enters RL_GO (which skips it)
;     instead of RUNGO, dropping GT_OK's ADD2_LP.
;   - DO_LIST reads the line number with two BUMP_LPs (drops LDA/LDA,Y/ADD2_LP).
;   - MAIN no longer clears RUN: only DO_RUN reads it, after setting it (a stale 1
;     after an error mid-RUN is harmless).
;   - INIT: dropped CLD (65C02 reset clears D).  TXS stays: needed so early JSRs don't
;     push into the Kowalski preloaded showcase at PROG.
;   - Banner bumped to pBASIC1.9.
;
; v1.8 - 2 bytes free before vectors 
;   - Changed BANG's arm from "DEC BANG" to "LDA #$FF / STA BANG" (+2 bytes).
;   - Deleted Redundant CMP in STMT:
;
; v1.7 - 0 bytes free before vectors - Golf Pass 
;   - Restored banner (Yay!)
;   - Dropped MAINs blank-line CR check; STMT alreayd returns on CR via WPEEK
;   - 65c02 instruction BBR7 on MUL_ENTRY and PRT16 sign checks
;   - Removed RUNSP stack-pointer in DO_GO/RL_GO - DO_GO now cleans up stack with 
;     PLA/PLA instead of snapshotting/restoring SP.
;   - DO_LIST refactored to save 2 bytes by reordering CRLF at start 
;
; v1.6 - 6 bytes free before vectors
;   - SKIP_KW overun bug - loop consumed-then-checked each character
;   - Deleted Banner (again), replaced with simple Error code reporting. 
;
; v1.5 - 10 bytes free before vectors - bug fix on v1.4 
;   - SKIP_KW: restored a SEC before its inlined SBC #'A'.
;   - E2_PAR: removed a redundant JSR WSKIP after JSR EXPR

; v1.4 - Relop invert modifier '!' added; 8 bytes free before vectors
;   - EXPR_LOOP's OP_SCAN falls through to a '!' check when no operator matches,
;     REL_T/REL_F's exit does EOR.  
;   - CHK_CHAR inlined at its 3 call sites 
;   - DO_EQ/DO_LT/OP_HIT/DO_DISP reordered to keep branches BRA range.
;
; v1.3 - 6 bytes free before vectors -- code golf pass
;   - PE_CMP_LP sets Y=1 instead of locally.
;
; v1.2 — 2 bytes free before vectors -- regression fix, +2 bytes net
;   - EDITLN: restored the LDY #1 before the CURLN hi-byte store.
;   - CMP_PLP_X: reordered to compare high byte first.  Low-byte-first was fine
;     for GOTOL's equality but wrong for EDITLN's 
;
; v1.1 — 4 bytes free before vectors
;   - Inlined T0_CMPX in DO_EQ as only caller.
;   - Refactored ADD_T0_X as shortcut for ADD_Y_X as most common caller.
;   - Reordered for subroutine local BRA.
;   - Inlined NEG_T1 to NEG_X plus setup as only one caller.
;   - Shared some Relop setup with DO_DISP.
;   - Refactored *LP with X comparison CMP_PLP_X, hardly any benefit.
;   - Minor opcode tweaks here and there for a couple bytes.
;   - Restored Signon Banner (requires 21 bytes if you want to cut it)
;
; v1.0 - 1st version <1kbyte ($FC00 Origin, 2 bytes free)
;   - Control Flow: Reordered code blocks to convert multiple JMPs to 2-byte BRAs
;     (e.g., EL_ERR, GOTOL not-found path, PARSE_VAR tail call).
;   - EL_CPY: Reordered copy loop to use pre-increment and fall-through (-2 bytes).
;   - SKIP_KW: Merged SK_CONT and SKIP_KW into a single consume-then-check loop,
;     reusing GETCI's accumulator state (-2 bytes).
;   - EDITLN: Restructured EL_CPY payload copy to pre-increment. Reused X register
;     for PE/LP rewind to drop a redundant LDX.
;   - Docs: Cleaned Stale references to PUTSTR, INSLINE, DELINE, and updated
;     DO_ERROR limitations for append-only store, Fixed inverted CHK_CHAR carry flag.
;
; v0.10 — Append-Only Line Store ($FC00 Origin, 7 bytes over) 
;   - EDITLN Rewrite: Replaced arbitrary insertion with an append-only/tail-replace
;     model. New lines must be >= the last stored line.
;   - DELINE and INSLINE removed entirely, dead code T0_CMP_LP & LLEN variables.
;   - Optimization: Replaced inline LDA/STA pairs with X_TO_T0/T0_TO_X helpers.
;   - Deleted Banner to free 20 bytes.
;
; v0.9 — Size Optimization (954 bytes free, +2 saved)
;   - INSLINE: Simplified new PE calculation by adding gap length directly to PE
;     (using BCC/INC carry propagation) rather than copying via T0.
;
; v0.8 — Size Optimization (952 bytes free, +3 saved)
;   - DELINE: Replaced 13-byte inline PE subtraction with shared NEG_T1 + ADD_Y_X
;     helpers (10 bytes). Stashed Y register across helper call using PHY/PLY.
;
; v0.7 — Line Store Bug Fixes
;   - INSLINE (IN_CP) Bugfix: Replaced invalid LDA (IP),X syntax with LDA (IP),Y 
;     and updated assembler.
;   - DELINE: Fixed shift-down copy loop (was LDA (T0)/STA (T0) no-op). Updated loop
;     to close memory gaps properly.
;   - RUNLP: Added explicit IP == PE boundary check to prevent executing leftover data
;     past program end after line deletions.
;
; v0.6 — Dispatch Refactor (962 bytes free)
;   - Replaced UNI_TAB with flat dispatch tables: TOK_CHARS (1 byte/token for
;     6 operators + 9 unique statement first-letters) and TOK_VECS (2 bytes/token).
;   - Dispatched via JMP (TOK_VECS,X). Replaced full 2-character MTCHKW compare
;     with single-letter matching in MATCH_DISPATCH; inlined trailing skip loop.
;
; v0.5 — Continued Size Refactor (911 bytes free before vectors)
;   - Scope changes: Removed CHR$ and THEN. Added WR <expr> (writes ASCII char)
;     as a statement-level replacement for CHR$.
;   - DO_IF: Dropped optional THEN matching; IF now nests natively.
;   - MTCHKW: Removed trailing '$' special case.
;
; v0.4a — Refactor & Bug Fix (1186 bytes)
;   - ADD_Y_X: Generalized to add (T0,Y) into (T0,X) instead of hardcoding T1.
;   - PNUM: Reused ADD_Y_X in digit-accumulate loop, replacing redundant logic.
;
; v0.4 — Size Refactor (1181 bytes)
;   - Generalization: Replaced T0_CMP_LP with generalized T0_CMPX.
;   - DO_MD: Split into separate entry points for MUL and DIV.
;   - Fixes: Corrected DELINE shift loop. Added select 65C02 opcodes.
;
; v0.3 — Size Refactor (1294 bytes)
;   - EXPR: Replaced tiered parsing with EXPR/EXPR_LOOP (strict left-to-right
;     precedence, no tiers). Optimized MUL to O(n).
;   - Dispatch: Prepended 6 operator entries (stride 3) to UNI_TAB.
;   - Code Golf: Minimized GETLINE, DO_ERROR, DELINE, EDITLN, and INSLINE.
;
; v0.2 — Initial 1KB Target Pass
;   - Language Changes: Dropped % (MOD) and GOSUB/RETURN. Relational operators
;     narrowed to = and < only. Removed functions and argument extraction.
;   - MATCH_DISPATCH: Merged matched-handler and sentinel pushes into a shared tail.
;
; v0.1 — Initial Port
;   - Initial port from NMOS uBASIC 2kbyte V1.11.
; =============================================================================

; ---- assembler mode ---------------------------------------------------------
         .opt proc6502

; ---- Kowalski Emulated IO ---------------------------------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)

; Interpreter Defines
ORIGIN   = $FC00
RAM_TOP  = $0400             ; Assume 1k SRAM (1 KB: 2x 2114)
HWSTACK  = $7f               ; Give more space to PROG
PROG     = $101 + HWSTACK    ; Prog Start above Stack 
CR       = $0D               ; ASCII carriage return
LF       = $0A               ; ASCII line feed

; ---- error codes -------------------------------------------------------------
ERR_SN   = '0'                 ; syntax / bad expression
ERR_UL   = '1'                 ; undefined line number
ERR_OV   = '2'                 ; division by zero
ERR_OM   = '3'                 ; out of memory
ERR_UK   = '4'                 ; bad variable name
ERR_EL   = '5'                 ; Line editing error

; ---- zero-page symbols -------------------------------------------------------
        .ORG 0
; =============================================================================
; Program Start - 
; Kowalski executes from first byte not Reset, so trampoline over to INIT.
; Real hardware reaches INIT via Reset vector $FFFC instead.
; Overwritten as soon as program starts in Simulator.        
        .IF KOWALSKI
        JMP INIT	; 3 bytes
        NOP		; 1 byte
T0	     = 0		; Manually overwrite trampoline
T1          = 2
	.ELSE        
T0:         .RS 2              ; 16-bit: primary scratch word / expression result
T1:         .RS 2              ; 16-bit: secondary scratch word
        .ENDIF
        
; 16 bit regs should be sequential for helper subs
T2:         .RS 2              ; 16-bit: tertiary scratch word / STMT jump target
T3:         .RS 2              ; 16-bit: PNUM x10-multiply accumulator (lo/hi)
IP:         .RS 2              ; 16-bit: interpreter pointer
        .IF KOWALSKI
PE:         .DW SHOWCASE_END   ; Preload Showcase for testing
        .ELSE
PE:         .RS 2              ; 16-bit: program end (one past last byte)
        .ENDIF
LP:         .RS 2              ; 16-bit: line pointer / multi-purpose scratch
RUN:        .RS 1              ; 8-bit:  run flag, bit0=1 while RUN loop active; set by
                               ;         DO_RUN, cleared by END; read only in DO_RUN
VARS:       .RS 52             ; 52-byte variable store (A-Z, 2 bytes each)
IBUF:       .RS 41             ; Nominal Input line buffer but unbounded 

ZPEND:		               ; End of zero page audit

; ---- Zero-page lifetime notes -----------------------------------------
;   T0   : primary scratch / expression result -- live during nearly any
;          statement or expression evaluation
;   T1   : secondary scratch -- OP_HIT's left-operand stash (all six
;          operator handlers read it), also the MUL/DIV kernel's
;          dividend/multiplicand working value, PNUM Loop counter
;   T2   : tertiary scratch -- MUL/DIV kernel's product/quotient
;          accumulator (E1_P2/MD_DONE) 
;   T3   : PNUM's x10-multiply accumulator
;   LP   : line-store scan pointer -- shared by EDITLN, GOTOL, DO_LIST,
;          LSKIP, PE_CMP_LP; each call fully consumes LP before any
;          nested call that might also use it
; -------------------------------------------------------------------------

        .IF KOWALSKI
	.ORG PROG
; =============================================================================
; Pre-loaded showcase program
;
;   Stored as raw ASCII, mixed .DB format: <lineno_lo>,<lineno_hi>,"text",CR
;   Runs of plain characters are quoted strings; a literal `"` or `;` in the
;   BASIC text is emitted as a raw byte ($22 / $3B) instead of inside.
;   One statement per line throughout
; 
; =============================================================================

         .DB $14,$00,"PRINT ",$22,"-- Pico-BASIC SHOWCASE --",$22,CR ;
         .DB $1E,$00,"PRINT ",$22,"--- PRINT / WR ---",$22,CR ; 30 PRINT "--- PRINT / WR ---"
         .DB $28,$00,"WR 65",CR                             ; 40 WR 65
         .DB $29,$00,"WR 66",CR                             ; 41 WR 66
         .DB $2A,$00,"WR 67",CR                             ; 42 WR 67
         .DB $2B,$00,"PRINT",CR                              ; 43 PRINT
         .DB $32,$00,"PRINT ",$22,"--- ARITHMETIC ---",$22,CR ; 50 PRINT "--- ARITHMETIC ---"
         .DB $3C,$00,"PRINT ",$22,"3+4=",$22,$3B,"3+4",$3B,$22,"  10-3=",$22,$3B,"10-3",$3B,$22,"  6*7=",$22,$3B,"6*7",CR ; 60 PRINT "3+4=";3+4;"  10-3=";10-3;"  6*7=";6*7
         .DB $46,$00,"PRINT ",$22,"20/4=",$22,$3B,"20/4",CR ; 70 PRINT "20/4=";20/4
         .DB $50,$00,"PRINT ",$22,"--- COMPARISONS ---",$22,CR ; 80 PRINT "--- COMPARISONS ---"
         .DB $64,$00,"IF 3<5 PRINT ",$22,"3<5 ok",$22,CR    ; 100 IF 3<5 PRINT "3<5 ok"
         .DB $82,$00,"IF 3=3 PRINT ",$22,"3=3 ok",$22,CR    ; 130 IF 3=3 PRINT "3=3 ok"
         .DB $8C,$00,"IF -2<1 PRINT ",$22,"-2<1 ok",$22,CR  ; 140 IF -2<1 PRINT "-2<1 ok"
         .DB $96,$00,"IF 2*3=6 PRINT ",$22,"2*3=6 ok",$22,CR  ; 150 IF 2*3=6 PRINT "2*3=6 ok"
         .DB $FA,$00,"PRINT ",$22,"--- LOOP via GOTO ---",$22,CR ; 250 PRINT "--- LOOP via GOTO ---"
         .DB $04,$01,"I=1",CR                               ; 260 I=1
         .DB $0E,$01,"IF 5<I GOTO 310",CR                   ; 270 IF 5<I GOTO 310
         .DB $18,$01,"PRINT I",$3B,CR                       ; 280 PRINT I;
         .DB $22,$01,"I=I+1",CR                             ; 290 I=I+1
         .DB $2C,$01,"GOTO 270",CR                          ; 300 GOTO 270
         .DB $36,$01,"PRINT ",$22,$22,CR                    ; 310 PRINT ""
         .DB $40,$01,"PRINT ",$22,"--- NESTED LOOP ---",$22,CR ; 320 PRINT "--- NESTED LOOP ---"
         .DB $4A,$01,"I=1",CR                               ; 330 I=1
         .DB $54,$01,"IF 3<I GOTO 610",CR                   ; 340 IF 3<I GOTO 610
         .DB $5E,$01,"J=1",CR                               ; 350 J=1
         .DB $68,$01,"IF 3<J GOTO 400",CR                   ; 360 IF 3<J GOTO 400
         .DB $72,$01,"PRINT J",$3B,CR                       ; 370 PRINT J;
         .DB $7C,$01,"J=J+1",CR                             ; 380 J=J+1
         .DB $86,$01,"GOTO 360",CR                          ; 390 GOTO 360
         .DB $90,$01,"PRINT ",$22,$22,CR                    ; 400 PRINT ""
         .DB $9A,$01,"I=I+1",CR                             ; 410 I=I+1
         .DB $A4,$01,"GOTO 340",CR                          ; 420 GOTO 340
         .DB $62,$02,"PRINT ",$22,"--- MANDELBROT ---",$22,CR ; 610 PRINT "--- MANDELBROT ---"
         .DB $6C,$02,"I=-64",CR                             ; 620 I=-64
         .DB $76,$02,"IF 56<I GOTO 860",CR                  ; 630 IF 56<I GOTO 860
         .DB $80,$02,"D=I",CR                               ; 640 D=I
         .DB $8A,$02,"C=-120",CR                            ; 650 C=-120
         .DB $94,$02,"IF 4<C GOTO 830",CR                   ; 660 IF 4<C GOTO 830
         .DB $9E,$02,"A=C",CR                               ; 670 A=C
         .DB $A8,$02,"B=D",CR                               ; 680 B=D
         .DB $B2,$02,"E=0",CR                               ; 690 E=0
         .DB $BC,$02,"N=1",CR                               ; 700 N=1
         .DB $C6,$02,"IF 16<N GOTO 790",CR                  ; 710 IF 16<N GOTO 790
         .DB $D0,$02,"IF 0<E GOTO 770",CR                   ; 720 IF 0<E GOTO 770
         .DB $DA,$02,"T=(A*A/64)-(B*B/64)+C",CR             ; 730 T=(A*A/64)-(B*B/64)+C
         .DB $E4,$02,"B=2*A*B/64+D",CR                      ; 740 B=2*A*B/64+D
         .DB $EE,$02,"A=T",CR                               ; 750 A=T
         .DB $F8,$02,"IF 256<((A*A/64)+(B*B/64)) IF E=0 E=N",CR ; 760 IF 256<((A*A/64)+(B*B/64)) IF E=0 E=N
         .DB $02,$03,"N=N+1",CR                             ; 770 N=N+1
         .DB $0C,$03,"IF N<17 GOTO 710",CR                  ; 780 IF N<17 GOTO 710 (N<=16, integer-exact)
         .DB $16,$03,"IF 0<E WR E+32",CR                    ; 790 IF 0<E WR E+32
         .DB $20,$03,"IF E=0 WR 32",CR                      ; 800 IF E=0 WR 32
         .DB $2A,$03,"C=C+4",CR                             ; 810 C=C+4
         .DB $34,$03,"GOTO 660",CR                          ; 820 GOTO 660
         .DB $3E,$03,"PRINT ",$22,$22,CR                    ; 830 PRINT ""
         .DB $48,$03,"I=I+6",CR                             ; 840 I=I+6
         .DB $52,$03,"GOTO 630",CR                          ; 850 GOTO 630
         .DB $5C,$03,"END",CR                               ; 860 END
SHOWCASE_END:	.DW 0

        .ENDIF

; =============================================================================
; ROM START  
         .ORG ORIGIN
BANNER: .DB "pBASIC2.0",0                    ; Signon 

; =============================================================================
; TOK_CHARS / TOK_LO / TOK_HI -- match-char table + RTS-dispatch address tables.
;
;   TOK_CHARS: one raw byte per token, same index space as TOK_LO/TOK_HI.
;     Indices 0..OP_COUNT-1 (0-5)      : operator chars, "-+/*=<"
;     Indices OP_COUNT..MAX_TOK-1(6-14): statement 1st letters, "PIGLRNAEW"
;       (PRINT/IF/GOTO/LIST/RUN/NEW/ASK[INPUT]/END/WR -- 1st letters are
;       unique across all 9 statements by design -- ASK instead of INPUT)
;
;   TOK_LO/TOK_HI: handler address - 1 (low/high bytes), same order as TOK_CHARS.
;     NMOS has no JMP (abs,X), so DO_DISP pushes TOK_HI,TOK_LO and RTSes into the
;     handler.  Index MAX_TOK (15) is the default handler, DO_LET.
; =============================================================================
TOK_CHARS:
; -- operator chars --
          .DB "-+/*=<"        ; indices 0..5
OP_COUNT  = * - TOK_CHARS     ; 6

; -- statement 1st chars --
          .DB "PIGLRNAEW"     ; indices 6..14 (PR,IF,GO,LI,RU,NE,AS,EN,WR)
MAX_TOK   = * - TOK_CHARS     ; 15

; handler-1 for the RTS dispatch (plain EQUs: keeps '<(' / '>(' out of the source)
V_DO_SUB = DO_SUB-1
V_DO_ADD = DO_ADD-1
V_DIV_ENTRY = DIV_ENTRY-1
V_MUL_ENTRY = MUL_ENTRY-1
V_DO_EQ = DO_EQ-1
V_DO_LT = DO_LT-1
V_DO_PRINT = DO_PRINT-1
V_DO_IF = DO_IF-1
V_DO_GO = DO_GO-1
V_DO_LIST = DO_LIST-1
V_DO_RUN = DO_RUN-1
V_DO_NEW = DO_NEW-1
V_DO_INPUT = DO_INPUT-1
V_DO_END = DO_END-1
V_DO_WR = DO_WR-1
V_DO_LET = DO_LET-1
TOK_LO:   ; low bytes of handler-1
         .DB <V_DO_SUB
         .DB <V_DO_ADD
         .DB <V_DIV_ENTRY
         .DB <V_MUL_ENTRY
         .DB <V_DO_EQ
         .DB <V_DO_LT
         .DB <V_DO_PRINT
         .DB <V_DO_IF
         .DB <V_DO_GO
         .DB <V_DO_LIST
         .DB <V_DO_RUN
         .DB <V_DO_NEW
         .DB <V_DO_INPUT
         .DB <V_DO_END
         .DB <V_DO_WR
         .DB <V_DO_LET
TOK_HI:   ; high bytes of handler-1
         .DB >V_DO_SUB
         .DB >V_DO_ADD
         .DB >V_DIV_ENTRY
         .DB >V_MUL_ENTRY
         .DB >V_DO_EQ
         .DB >V_DO_LT
         .DB >V_DO_PRINT
         .DB >V_DO_IF
         .DB >V_DO_GO
         .DB >V_DO_LIST
         .DB >V_DO_RUN
         .DB >V_DO_NEW
         .DB >V_DO_INPUT
         .DB >V_DO_END
         .DB >V_DO_WR
         .DB >V_DO_LET

; =============================================================================
; DO_LIST  --  LIST  :  print all program lines in source form
;
;   In:  PE = current program end
;   Out: all lines printed as "<linenum> <body>"
;   Clobbers: A X Y T0 LP
; =============================================================================
DO_LIST:
         JSR PROG2LP
LS_EOL:  JSR PRNL              ; print CR+LF at start then end of each listed line
LS_LN:   JSR PE_CMP_LP           ; PE == LP (also sets Y=1, used below)
         BEQ LS_DONE          ; end of program: branches to shared RTS 
         ; T0 = line number
         JSR BUMP_LP          ; read line number lo
         STA T0
         JSR BUMP_LP          ; read line number hi
         STA T0+1
         ;
         JSR PRT16            ; print line number
         JSR PRTSPACE
LS_BODY: JSR BUMP_LP
         CMP #CR                ; A still has char
         BEQ LS_EOL
         JSR PUTCH
         BNE LS_BODY          ; always taken: Z=0 from CMP #CR (BEQ above fell through);
                              ; PUTCH is STA/RTS only, so it preserves flags

; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to the line HEADER (DO_GO enters RL_GO, which
;                      skips the 2 header bytes)
;        C=1  not found -- IP = PE
;   Clobbers: A X Y IP LP
;
;   Scans using LP (shared PE_CMP_LP/LSKIP routines with EDITLN, which also
;   scan via LP); only converts to IP once, at the success point, since
;   that's the only place the documented output contract needs it. Safe:
;   GOTOL's only caller (DO_GO) explicitly doesn't need LP preserved across
;   this call ("LP no longer needed" once EXPR has parsed the target line).
; =============================================================================
GOTOL:
         JSR PROG2LP
GT_SC:   JSR PE_CMP_LP        ; If LP == PE, Z=1 AND C=1
         BEQ COPY_LP_IP       ; End of program? Exit immediately! (Carry is already 1!)

        LDX #T0 ;compare with T0
        JSR CMP_PLP_X
         ;
         BEQ GT_OK            ; Found it        
         JSR LSKIP            ; advance LP to next line
         BEQ GT_SC            ; always taken: LSKIP exits on CMP #CR equal, so Z=1

GT_OK:   CLC                  ; C=0 means Success
         
COPY_LP_IP:
         LDA LP               ; Carry flag passes through these unchanged
         STA IP
         LDA LP+1
         STA IP+1
LS_DONE:
         RTS                  ; Exit. C=1 (Not Found) or C=0 (Found)

; =============================================================================
; EXPR  --  strictly left-to-right expression evaluator (no operator
;   precedence; use parentheses to group, e.g. "(A*A/64)-(B*B/64)+C" or
;   "256<((A*A/64)+(B*B/64))" -- see the showcase's Mandelbrot section for
;   real examples of exactly this).
;
;   Operators matched against TOK_CHARS's operator section (X counts down
;   from OP_COUNT-1 -- see TOK_CHARS header).
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================

; --- Relational: Equality ---
; LDA T1/ CMP T0 already done
DO_EQ:   BNE REL_F              ; 
         LDA T1+1               ; 
         CMP T0+1
         BEQ REL_T
         BNE REL_F            ; always taken: the BEQ above fell through, so Z=0

; =============================================================================
; OP_HIT  --  operator match handler: consume operator, shuffle operands
;
;   In:  X = matched operator's index into TOK_CHARS/TOK_LO/TOK_HI (0..5);
;        IP -> the matched operator char (not yet consumed); T0 = left
;        operand (from EXPR2/a prior OP_HIT)
;   Out: T1 = left operand, T0 = right operand; falls through into DO_DISP
;   Clobbers: A X T0 T1 IP (Y/T2/T3 via EXPR2)
; =============================================================================
OP_HIT:  JSR GETCI             ; consume the matched operator char
         TXA                  ; save matched index across EXPR2 (no PHX on NMOS)
         PHA
;
         LDA T0+1              ; push left operand (T0) hi
         PHA
         LDA T0                ; push left operand (T0) lo
         PHA
         JSR EXPR2             ; parse the right operand -> T0
         PLA
         STA T1                ; pop left operand lo -> T1
         PLA
         STA T1+1              ; pop left operand hi -> T1+1
;
         PLA                  ; restore matched index
         TAX
         ; falls through into DO_DISP

; =============================================================================
; DO_DISP  --  shared vector dispatch via RTS (TOK_HI/TOK_LO hold handler-1)
;
;   In:  X = matched index into TOK_CHARS/TOK_LO/TOK_HI (0..MAX_TOK)
;   Out: tail-jumps into the matched handler; never returns to caller here
;   Clobbers: A X
; =============================================================================
DO_DISP:
         LDA TOK_HI,X          ; NMOS has no JMP (abs,X): push handler-1, then RTS into it
         PHA                   ; (X is the unscaled index, so no TXA/ASL/TAX)
         LDA TOK_LO,X
         PHA
         ; Initial Relop setup - ignored by Arithmetic & Statements
         LDA T1                ; must come AFTER the pushes: the CMP flags have to
         CMP T0                ; survive to the handler, and RTS does not touch flags
         RTS                   ; "return" into the DO_xxx handler
         
; --- Relational: Less Than ---
; LDA T1/ CMP T0 already done
DO_LT:   LDA T1+1
         SBC T0+1
         BVC NO_FLIP          ; N XOR V trick for signed comparison
         EOR #$80
NO_FLIP: BMI REL_T            ; If N=1, condition is true

REL_F:   LDA #0               ; False: Result = $0000
         .DB $2C              ; BIT abs trick: skips the next 2 bytes (LDA #$FF)
REL_T:   LDA #$FF             ; True:  Result = $FFFF
         STA T0
         STA T0+1
         JMP EXPR_LOOP        ; no flag is common to REL_F (Z=1) and REL_T (Z=0)

; --- Addition & Subtraction ---
DO_SUB:  JSR NEG_T0            ; negate right operand (T0), fall through to ADD
DO_ADD:  LDX #T0              ; Target X=0 (T0). Sets Z flag
         BEQ DO_ADD_TAIL      ; always taken: LDX #T0 loads 0 (T0 is zero-page $00), so Z=1
         
EXPR:
         JSR EXPR2            ; parse the first atom -> T0
EXPR_LOOP:
         JSR WPEEK            ; peek next char (not consumed)
         LDX #OP_COUNT-1      ; 2 bytes (Starts at 5)
OP_SCAN: CMP TOK_CHARS,X      ; 3 bytes
         BEQ OP_HIT           ; 2 bytes
         DEX                  ; 1 byte
         BPL OP_SCAN          ; 2 bytes
         RTS                  ; not an operator char: expression ends (X=$FF)

; --- Multiplication & Division ---
DIV_ENTRY:
         LDY #1                ; remember: divide (Y survives the shared
         .DB $2C               ; sign-prep below untouched -- checked)
MUL_ENTRY:
         LDY #0                ; remember: multiply
         LDA T1+1
         EOR T0+1
         PHA                  ; Save result sign
         BIT T1+1             ; N = bit 7 of T1+1 (A untouched)
         BPL E1_P1            ; skip if T1 positive
         LDX #T1
         JSR NEG_X           ; Make T1 positive
E1_P1:   BIT T0+1             ; N = bit 7 of T0+1
         BPL E1_P2            ; skip if T0 positive
         JSR NEG_T0            ; Make T0 positive
E1_P2:   LDA #0               ; clear T2 (product/quotient accumulator)
         STA T2
         STA T2+1
         TYA                   ; which operator? (Y set above, still intact)
         BNE DIV_LOOP

MUL_LOOP:
         LDX #T2               ; Target X=4 (T2)
         ; Dec T0
         LDA T0               ; 16-bit decrement of T0 (multiplicand doubles as loop counter)
         BNE MLLP
         DEC T0+1
         BMI MD_DONE          ; Once T0+1 wraps from $00 to $FF, we're done
MLLP:    DEC T0
        ; --- SHARED INLINE ADDITION KERNEL ---
DO_ADD_TAIL:                  
         LDY #T1               ; Source Addend = T1 for ADD and MUL 
         JSR ADD_Y_X
         TXA                  ; 1-byte trick to check X
         BNE MUL_LOOP         ; If X=4, loop back to multiply
         BEQ EXPR_LOOP        ; always taken: TXA/BNE above fell through, so Z=1

; Back to ALU ops
DIV_LOOP:
        JSR NEG_T0            ; T0 = -T0 (negated divisor); C=1 only if T0 was 0
        BCS E1_OVFL           ; -> Division by zero error
DV_LP:
         LDX #T1               ; Dest = T1 (running dividend)
         JSR ADD_T0_X
         BCC MD_DONE          ; Stop once dividend < divisor
         ;
         INC T2               ; Quotient tally
         BNE DV_LP
         INC T2+1
         ;
         BNE DV_LP

MD_DONE: LDX #T2-VARS        ; Copy T2 to T0
         JSR X_TO_T0
         PLA                  ; Retrieve sign
         BPL E1_POS
         JSR NEG_T0            ; Apply sign
E1_POS:  JMP EXPR_LOOP        ; flags differ on the two paths in (BPL taken / after NEG_T0)
E1_OVFL: JMP DO_ERR_OV

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
         ; drop through

; =============================================================================
; NEG_T0/NEG_X  --  two's-complement negate
; In:  T0 or X = value to negate. Selected dynamically by offset mapping.
; Clobbers: A X
; =============================================================================
NEG_T0:  LDX #T0              ; in place negate
NEG_X:   SEC
         LDA #0
         SBC 0,X
         STA 0,X
         LDA #0
         SBC 1,X
         STA 1,X
         RTS

; =============================================================================
; EXPR2  --  atom level: parentheses, unary -, number literals, variables
;
;   In:  IP -> atom text
;   Out: T0 = atom value; IP advanced past atom
;   Clobbers: A X Y T0 T1 T2 IP
;
;   E2_POS: consumes the char just peeked then falls into EXPR2 (only user: E2_NEG).
;   E2_NEG: entry for unary '-' -- consumes '-' (via E2_POS) then negates result.
; =============================================================================
E2_POS:  JSR GETCI            ; consume '-', then fall through
EXPR2:
         JSR WPEEK
         CMP #'('
         BEQ E2_PAR
         CMP #'-'
         BEQ E2_NEG
         ; try number or var 
         EOR #'0'     ; Maps '0'-'9' to 0-9
         CMP #10      ; Anything else becomes >= 10
         BCS E2_VAR
         ; drop through
; =============================================================================
; PNUM  --  parse unsigned decimal integer from ASCII at IP into T0
;
;   In:  IP -> ASCII digits (leading spaces skipped automatically)
;   Out: T0 = parsed value; IP advanced past the last digit
;   Clobbers: A X Y T0 T1 T3
;   Stops at the first non-digit without consuming it.
; =============================================================================
PNUM:
         STY T0               ; Y=0: WPEEK/GETCI/BUMP_LP always leave Y=0, and every PNUM
                              ; caller peeked with WPEEK first
         STY T0+1
PN_LP:   LDA (IP),Y           ; Y=0 (see PNUM note)
         EOR #'0'              ; [OPT] Maps '0'-'9' to 0-9. Anything else maps >= 10
         CMP #10               ; [OPT] Check bounds
         BCS PN_DN             ; If A >= 10, not a digit -- done

         STA T3                ; seed running sum lo with digit
         STY T3+1             ; Y=0 here too (see above; ADD_T0_X loads Y=T0=0)
         LDX #T3               ; Destination T3:T3+1 = digit + 10*T0, via ADD_Y_X (X=T3
                                ; dest, Y=0/T0 addend
         LDA #10
         STA T1                ; loop counter 
PN_ML:
         JSR ADD_T0_X
         DEC T1
         BNE PN_ML
         ; Copy T3:T3+1 to T0
         LDX #T3-VARS         ; Copy T3 to T0
         JSR X_TO_T0
         JSR GETCI             ; consume digit, advances IP 16-bit
         BNE PN_LP            ; always taken: GETCI returns Z=0 (INC IP / INC IP+1 never yields
                              ; 0 as long as IP+1 != $FF, i.e. IP never points into page $FF)

; --------------------------------------------
E2_VAR:  JSR PARSE_VAR               ; variable name (single letter A-Z)?
         TAX
        ; Drop through
; =============================================================================
; X_TO_T0 - Helper to copy 16bit ZP to another
;  Reuses VARS so offset is VARS based MOD256 i.e. PE-VARS for PE  
; =============================================================================
X_TO_T0:         
         LDA VARS,X
         STA T0
         LDA VARS+1,X
         STA T0+1
PN_DN:
         RTS

E2_PAR:  JSR GETCI            ; consume '('
         JSR EXPR             ; evaluate sub-expression -- EXPR's only return
                               ; path already skipped spaces (EXPR_LOOP's own
                               ; WPEEK), so IP is already non-space here
         ; fall through to consume ')'
; =============================================================================
; GETCI  --  fetch char at IP and advance IP
;
;   In:  IP -> char to fetch
;   Out: A = char; IP incremented (16-bit)
;   Clobbers: A Y IP   (Y=0 on return)
; =============================================================================
GETCI:   LDY #0               ; NMOS has no LDA (zp): use (zp),Y with Y=0 -- GETCI/WPEEK/
         LDA (IP),Y           ; BUMP_LP all leave Y=0 (callers may rely on that)
BUMP_IP:         
         INC IP               ; 16-bit increment
         BNE GETCI_RTS
         INC IP+1
GETCI_RTS:        
         RTS

; =============================================================================
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or Kowalski JMP trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
;
;   Sets the stack, initialises PE, then falls into MAIN. 
; =============================================================================
INIT:
         LDX #HWSTACK
         TXS                  ; set stack (also keeps early JSRs out of the preloaded
                              ; showcase at PROG)
         CLD                  ; NMOS reset leaves D undefined (65C02 clears it)
        .IF KOWALSKI     
         JSR DO_END           ; setup RUN
        .ELSE
         JSR DO_NEW           ; setup PE, PROG, RUN
        .ENDIF

        ; Print signon Banner - delete frees 16 bytes for UART init code
         LDA #0               ; Banner Low byte - banner must be at $xx00
         STA IP
         LDA #>BANNER
         STA IP+1
         JSR DP_STR

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
;
;   In:  -- (entered by fall-through from INIT, or by JMP MAIN from its own loop
;        bottom and from EDITLN's EL_EXIT, which is also DO_ERROR's relay)
;   Out: never returns (loops back to itself indefinitely)
;   Clobbers: everything
;
;   Reads one line from the terminal.  Lines that start with a digit are
;   routed to EDITLN (program store editor); else executed via STMT.
; =============================================================================
MAIN:
         LDX #HWSTACK
         TXS                  ; Reset stack
         
         JSR GETLINE_M        ; print "> "; read line

         JSR WPEEK            ; skip spaces; peek first non-space char into A
                               ; blank line (CR) falls through: EOR/CMP below
                               ; sends it to STMT, which returns
                               ; immediately on CR via its own WPEEK/BCC check
         EOR #'0'             ; 2 bytes (Maps '0'-'9' to 0-9; all other ASCII wraps >= 10)
         CMP #10              ; 2 bytes
         BCC EDITLN           ; digit: store / delete numbered line (below)
         JSR STMT              ; execute as immediate statement
         JMP MAIN             ; flags after STMT are arbitrary

; =============================================================================
; EDITLN  --  MINIMAL append-only line-store editor
;
;   Entered by BCC from MAIN (NOT a subroutine: no JSR/RTS).
;   In:  IP -> line-number digits (MAIN has already confirmed the line
;        starts with a digit)
;   Out: accepted line appended to the end of the store, or the current
;        LAST line is replaced/deleted in place; PE/LP updated; exits through EL_EXIT
;        (JMP MAIN).  Any other target line number branches to DO_ERR_EL.
;   Clobbers: A X Y T0 T1 T3 IP PE LP (+ HW stack reset by MAIN)
;
;   Rule: a target line number is only accepted if it is greater than
;   every line currently stored (plain append), or if it exactly matches
;   the current LAST stored line (in-place replace, or delete when the
;   typed body is CR-only). Anything else -- a match on a non-last line,
;   or a number that falls before/between existing lines -- is rejected.
;   Because storage order is thereby kept == numeric order, GOTOL/DO_RUN/
;   DO_LIST need no changes: they already walk storage order top to
;   bottom and never assumed sorted order themselves.
; =============================================================================
EDITLN:
         JSR PNUM             ; parse line number -> T0; IP advances past digits
         JSR PROG2LP
         BNE EL_FL            ; always taken: PROG2LP's last LDA is #>PROG ($01), so Z=0
EL_SKIP: JSR LSKIP            ; advance LP to next line
EL_FL:   JSR PE_CMP_LP        ; reached end of store?
         BEQ EL_CHK_CR        ; yes: nothing to match against -- append
         LDX #T0                 ; compare T0 with *LP
         JSR CMP_PLP_X           ; returns with Y=1
         BCC EL_SKIP          ; stored line < target: keep scanning
         BNE DO_ERR_EL        ; stored line > target: out of order

         ; --- exact match - legal only if it's the LAST stored line ---
         LDA LP
         PHA                   ; push start of the matched line (lo, then hi)
         LDA LP+1
         PHA
         JSR LSKIP             ; advance LP past the matched line
         JSR PE_CMP_LP         ; did that land on the end of the store?
         BNE DO_ERR_EL         ; no: an earlier line -- reject (stack reset by MAIN)

         PLA                   ; LP = PE = start of matched line (ready to
         STA LP+1              ; overwrite in place / excise the matched line)
         STA PE+1
         PLA
         STA LP
         STA PE

EL_CHK_CR:
         JSR WPEEK             ; skip spaces + peek (no consume) first body char
         CMP #CR
         BEQ MAIN              ; CR only: delete-only, done
        
        ; *LP=T0
         LDA T0
         STA (LP),Y         ; write line number lo (Y=0: WPEEK above leaves Y=0)
         INY
         LDA T0+1
         STA (LP),Y         ; write line number hi
         ;      
         JSR ADD2_LP           ; LP += 2, past the header

         LDY #$FF
EL_CPY:  INY
         LDA (IP),Y            ; copy payload from IBUF
         STA (LP),Y
         CMP #CR
         BNE EL_CPY

        ; this is the only place PE arithmetic occurs 
EL_UPD:  TYA                   ; A = payload length (excluding CR)
         ; SEC                   ; carry set by the CMP #CR above
         ADC LP
         STA PE
         LDA LP+1
         ADC #0
         STA PE+1
EL_EXIT: JMP MAIN             ; done -- back to the prompt (also DO_ERROR's relay: MAIN is
                              ; out of its branch range)

; =============================================================================
; DO_ERROR  --  Essential Errors Stub, no line numbers, restarts MAIN
; =============================================================================
;DO_IN_SN:   LDX #ERR_SN ; Syntax Error
;DO_IN_OM:   LDX #ERR_OM ; Out of memory
DO_ERR_UK:  LDX #ERR_UK ; Unknown Var
         .DB $2C
DO_ERR_UL:  LDX #ERR_UL ; Unknown Line 
         .DB $2C
DO_ERR_OV:  LDX #ERR_OV ; Overflow/Div0
         .DB $2C
DO_ERR_EL:  LDX #ERR_EL ; Line Handling
DO_ERROR:
         ; Generic Error
         JSR PRNL             ; CR+LF before error message      
         LDA #'!'
         JSR PUTCH            ; print "!"
         TXA
         JSR PUTCH            ; print code
         JSR PRNL             ; CR+LF after error message
         BNE EL_EXIT          ; always taken: PRNL ends LDA #LF (Z=0) and PUTCH preserves flags

; =============================================================================
; DO_INPUT  --  ASK <var>  (routine name is historical; ASK is the actual
;   keyword -- "INPUT" would dispatch to IF instead, see top-of-file note
;   and TOK_CHARS header)
;
;   In:  IP -> variable name in source
;   Out: named variable updated; IP restored to position after variable name
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
DO_INPUT:
         JSR PARSE_VAR         ; skip spaces; peek var name uppercased
         PHA                  ; [S: var_offset]
         JSR GETLINE          ; Read user input; IP = IBUF
         BNE DL_EXPR          ; always taken: GETLINE ends in PRNL (LDA #LF, Z=0)

; =============================================================================
; PARSE_VAR  --  parse a single-letter variable name at IP
;
;   In:  IP -> variable name text (leading spaces are skipped)
;   Out: success: C=0, A = VARS offset (0,2,4..50 for A-Z), IP advanced past
;        the letter
;        failure (char not A-Z): never returns -- jumps straight to the
;        shared error stub (bare "!", back to MAIN). Callers don't need
;        (and shouldn't add) their own post-call error check.
;   Clobbers: A IP
; =============================================================================
PARSE_VAR:
         JSR WPEEK       ; (3)
         SBC #'A'         ; [inline CHK_CHAR -- 3 call sites, cheaper than a shared routine]
         CMP #26
         BCS DO_ERR_UK   ; (2) Nope - global error jump
         ASL             ; (1) double the index for VARS lookup
         JMP BUMP_IP     ; (3) increments IP, leaves Carry clear (C=0)

; =============================================================================
; DO_NEW  --  NEW  :  Set default program store
; DO_END  --  END  :  halt program execution and return to immediate mode
; =============================================================================
DO_NEW:
         LDX #PE-IP
         JSR PROG2X            ; PE = PROG
DO_END:
RUNEND:  LDA #0
         STA RUN
         RTS

; =============================================================================
; DO_LET  --  LET <var> = <expr>  or implicit  <var> = <expr>
;
;   In:  IP -> variable name (with optional leading spaces)
;   Out: variable assigned; IP advanced
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
DO_LET:
         JSR PARSE_VAR
         PHA
         JSR WPEEK
         CMP #'='
         BNE DO_ERR_UK           ; no '=': bad assignment
         JSR GETCI            ; consume '='
DL_EXPR: JSR EXPR             ; evaluate RHS -> T0
         ; falls through into STORE_VAR 
; =============================================================================
; STORE_VAR  --  shared tail: pop var_offset pushed by caller, store T0 there
;
;   In:  T0 = value to store; hardware stack top = var_offset (from PARSE_VAR)
;   Out: VARS[var_offset] = T0; RTS to caller's caller
;   Clobbers: A X
; =============================================================================
STORE_VAR:
         PLA                  ; restore offset (no PLX on NMOS)
         TAX
         LDA T0
         STA VARS,X
         LDA T0+1
         STA VARS+1,X
DO_IF_F:
STMT_RTS:
        RTS            

; =============================================================================
; DO_GO  --  GOTO <linenum>
;
;   In:  IP -> line number digits
;        NOTE: IP, PE and LP must be sequential in Zero Page (PROG2X).
;   Out: IP = header of target line; pending JSR STMT return address
;        discarded (RL_GO's JSR STMT replaces it); continues at RL_GO
;   Clobbers: A X Y T0 T1 T2 T3 IP LP SP  (T1-T3 via EXPR)
;
; =============================================================================
DO_GO:
         JSR EXPR             ; Parse target line number -> T0 (LP no longer needed)
         JSR GOTOL            ; find line: C=0 found, C=1 not found
         BCS DO_ERR_UL        ; Line not found error 
         PLA                  ; discard the pending JSR STMT return address --
         PLA                  ; RUNGO's own JSR STMT always returns to the
                              ; same place, so there's always exactly one
         BMI RL_GO            ; always taken: 2nd PLA left PCH of a ROM return address
                              ; (>= $FC) in A, so N=1; IP -> line header, RL_GO skips it
                              ; header; RL_GO skips it

; =============================================================================
; DO_RUN  --  RUN  :  execute program starting from the first line
;
;   In:  PE = current program end
;   Out: program executes; returns to MAIN on END/error/STOP
;   Clobbers: A X Y T0 T1 T2 T3 IP SP RUN
;
;   RUNLP: top of the per-line execution loop, reads the next line header.
;   RL_GO: mid-loop entry used by GOTO (IP already at the target's header) --
;          the JSR STMT at RUNGO is also the return point DO_GO's PLA/PLA
;          unwinds back to, which is what lets DO_GO discard exactly one frame.
; =============================================================================
DO_RUN:
         LDX #0
         JSR PROG2X           ; PROG to IP
         INX                  ; X=0 here (LDX #0 / PROG2X leaves it) -> 1
         STX RUN              ; set run flag (RUN is only ever 0 or 1)
RUNLP:   LDX #IP               ; IP == PE? (natural end of program)
         JSR PE_CMP_X
         BEQ RUNEND
RL_GO:   JSR GETCI            ; skip line-number lo
         JSR GETCI            ; skip line-number hi
RUNGO:   JSR STMT               ; execute the statement on this line
         LDA RUN              ; RUN cleared by END -- stop
         BEQ RUNEND
SK_LP:   JSR GETCI            ; advance IP past CR (SKIPEOL inlined)
         CMP #CR
         BNE SK_LP
         BEQ RUNLP            ; always taken: BNE SK_LP fell through, so Z=1

; =============================================================================
; DO_IF  --  IF <expr> <stmt>  (no THEN keyword -- see top-of-file spec)
;
;   In:  IP -> expression text
;   Out: if true, statement executed; if false, returns (STMT will SKIPEOL)
;   Clobbers: A X Y T0 T1 T2 T3 IP
;
;   Falls straight through into STMT to execute the consequent (no THEN).
;   On false: branches to nearest preceding RTS 
; =============================================================================
DO_IF:
         JSR EXPR             ; evaluate condition -> T0
         LDA T0
         ORA T0+1              ; check for zero
         BEQ DO_IF_F          ; false: return
         ; fall through into STMT to execute the consequent
; =============================================================================
; STMT  --  execute one statement from IP
;
;   In:  IP -> statement text (spaces will be skipped)
;   Out: statement executed; IP advanced
;   Clobbers: A X Y T0 T1 T2 T3 IP
;
; =============================================================================
STMT:
         JSR WPEEK
         BCC STMT_RTS         ; return via nearest preceding RTS
        ; drop through
; =============================================================================
; MATCH_DISPATCH -- statement parser: 1-char keyword lookup vs. implicit LET
;
;   Checks keyword from a single-letter variable by peeking 2nd character: 
;   vars are 1 letter, so a non-letter 2nd char (e.g. "X=5") means implicit LET. 
;   A letter 2nd char is a keyword ("PRINT ..."), matched on its 1st character
;   alone against TOK_CHARS's statement section (safe: all 9 statement
;   1st letters are unique, see TOK_CHARS header) -- SKIP_KW then consumes
;   the rest of the keyword's letters (including the already-matched 1st,
;   which the match itself only peeked, never consumed).
;
;   In:  IP -> statement text (STMT is the only caller)
;   Out: matched handler executed (tail call via DO_DISP); IP advanced
;   Clobbers: A X Y (plus DO_DISP's own A X)
; =============================================================================
MATCH_DISPATCH:
         LDY #1
         LDA (IP),Y            ; peek 2nd char (not consumed)
         SBC #'A'              ; [inline CHK_CHAR] -- carry-in is C=1 here,
                                ; guaranteed by STMT's own "CMP #' '/BCC
                                ; GETCI_SK" immediately above (STMT is the
                                ; only caller, falls through with nothing in
                                ; between that touches C). Deliberate reuse,
                                ; not the SKIP_KW-style stale-carry bug --
                                ; but it does mean this SBC is silently
                                ; coupled to STMT's guard; if that guard
                                ; ever changes, re-check this carry-in.
         CMP #26
         BCS DO_LET            ; not a letter: implicit LET (1-char var)
         DEY                  ; Y was 1 -> 0: Y stays 0 through MD_LP and SKIP_KW
         LDA (IP),Y

         LDX #OP_COUNT         ; skips operator chars
MD_LP:   CMP TOK_CHARS,X
         BEQ SKIP_KW           ; matched statement's 1st char
         INX
         CPX #MAX_TOK
         BNE MD_LP             ; loop until the last statement is checked

SKIP_KW: LDA (IP),Y           ; peek next char -- do NOT consume yet (Y=0)
         SEC
         SBC #'A'               ; must be fresh each pass -- carry left over
         CMP #26                ; from the previous iteration's CMP #26 is
         BCS SK_DONE            ; not safe here (wraps 'A' past 255)
         JSR BUMP_IP            ; it IS a letter -- consume it, keep going
         BNE SKIP_KW          ; always taken: BUMP_IP leaves Z=0 (see PNUM note)
SK_DONE: JMP DO_DISP            ; stopped on a non-letter, still unconsumed
                                ; (space or CR -- every handler self-skips
                                ; leading spaces via its own WPEEK, and CR
                                ; is left for SK_LP/DP_TOP to see intact)

; =============================================================================
; PRT16  --  print T0 as a signed decimal integer
;
;   In:  T0 = signed 16-bit value
;   Out: decimal digits printed to terminal; T0 destroyed
;   Clobbers: A Y T0
; =============================================================================
PRT16:
         LDA T0+1             ; (no BBR on NMOS)
         BPL PRT16GO          ; positive: skip sign handling
         LDA #'-'
         JSR PUTCH
         JSR NEG_T0
PRT16GO:
         LDY #16
         LDA #0
PRT16DIV:
         ASL T0
         ROL T0+1
         ROL                  ; shift MSB of T0 into remainder (in A)
         CMP #10
         BCC PRT16SKP
         SBC #10
         INC T0
PRT16SKP:
         DEY
         BNE PRT16DIV
         PHA                  ; push remainder digit
         LDA T0
         ORA T0+1
         BEQ PRT16PRNT        ; quotient zero: most-significant digit
         JSR PRT16GO          ; recurse to print more-significant digits first
PRT16PRNT:
         PLA
         ORA #'0'             ; convert 0-9 to ASCII '0'-'9'
         ; fall through into PUTCH
        .DB $2C ; consume next 2 bytes
PRTSPACE:
        LDA #' '
        ; drop through
; =============================================================================
; PUTCH  --  write one character to the terminal (Kowalski UART)
;
;   In:  A = character to output
;   Out: --
;   Clobbers: -- (STA doesn't touch flags either)
; =============================================================================
PUTCH:   STA IO_OUT
         RTS

; =============================================================================
; GETCH  --  read one character from Kowalski terminal (blocking)
;
;   In:  --
;   Out: A = character read and echo
;   Clobbers: A
; =============================================================================
GETCH:   LDA IO_IN
         BEQ GETCH          ; spin until a char is available
         BNE PUTCH            ; always taken: BEQ GETCH fell through, so Z=0

; =============================================================================
; DO_WR  --  WR <expr>  :  write one raw ASCII char (low byte of <expr>)
;
;   In:  IP -> expression text
;   Out: one character written to the terminal; IP advanced
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
DO_WR:   JSR EXPR             ; evaluate <expr> -> T0
         LDA T0               ; low byte
         JMP PUTCH            ; tail call (A = low byte; no known flag here)

; =============================================================================
; GETLINE  --  MINIMAL read one line from the terminal into IBUF; set IP = IBUF
;
;   Entry points sharing one body:
;     GETLINE_M  prints "> " (immediate-mode prompt)
;     GETLINE    no prompt
;
;   In:  --
;   Out: IBUF filled with input, CR-terminated; X is # chars
;   Clobbers: A Y, X is GETLINE's own buffer index
;   
;   Note: NO Range checking/Backspace support - Overflow could crash  
; =============================================================================
GETLINE_M:
         LDA #'>'            ; (2) Prompt for Direct Mode
         JSR PUTCH           ; (3) Print prompt character ('?' or '>')
GETLINE:
         JSR PRTSPACE        ; (3) Print trailing space
         ; Initialize IP to point at IBUF
         LDY #0               ; (no STZ on NMOS)
         STY IP+1             ; >IBUF 0 as ZP
         LDX #IBUF           ; (2) X = absolute zp index (IBUF is in zero page)
         STX IP              ; (2)
GL_LOOP:
         JSR GETCH      ; (3) Wait for and get keystroke in A
         STA 0,X        ; (2) Store raw character into buffer
         INX            ; (1) Advance index
         CMP #CR        ; (2) Was it a carriage return?
         BNE GL_LOOP    ; (2) If not, keep reading
        ; drop through
; =============================================================================
; DO_PRINT  --  PRINT [item [; item] ...]
;
;   In:  IP -> first character after "PRINT" keyword
;   Out: output written to terminal; IP advanced past statement
;   Clobbers: A X Y T0 T1 T2 T3 IP
;
;   Items: string literals ("..."), or numeric expressions.
;   Items separated by ';' suppress the inter-item space.
;   A trailing ';' suppresses the final CR/LF.
;   At end of items (or with no items) falls through into PRNL to emit CR/LF.
; =============================================================================
DP_NL:   
PRNL:    LDA #CR
         JSR PUTCH
         LDA #LF
         BNE PUTCH            ; always taken: LDA #LF gives Z=0
  
DO_PRINT:
DP_TOP:  JSR WPEEK
         CMP #CR+1            ; NUL(0) and CR(13) are both < CR+1 -- one check
         BCC DP_NL            ; catches both "end of line" cases at once
         CMP #'"'
         BNE DP_NORM
         JSR GETCI            ; consume opening '"'
DP_STR:  JSR GETCI            ; read string body char by char
         CMP #'"'
         BEQ DP_AFT           ; closing '"' -- go check for ';'
         CMP #CR+1
         BCC DP_NL            ; unterminated string -- print CR/LF and stop
         JSR PUTCH
         BCS DP_STR           ; always taken: C=1 from CMP #CR+1 (BCC above fell through);
                              ; PUTCH preserves flags

DP_NORM: JSR EXPR             ; numeric expression
         JSR PRT16
DP_AFT:  JSR WPEEK
         CMP #';'
         BNE DP_NL
         JSR GETCI            ; consume ';'
         JSR WPEEK
         CMP #CR+1            ; NUL(0) and CR(13) are both < CR+1 -- one check
         BCS DP_TOP           ; If >= CR+1, loop to top
         RTS                  ; Otherwise, return directly here

; =============================================================================
; HELPERS - All Helpers go at end as JSR not BRA - until they are...
; =============================================================================
; ADD_Y_X  --  (T0,X) += (T0,Y), 16-bit
;   In:  X = dest offset (0=T0, 4=T2); Y = addend offset (0=T0, 2=T1)
;   Out: (T0,X) = (T0,X) + (T0,Y); carry = result of high-byte ADC
;   Clobbers: A
; =============================================================================
ADD_T0_X: LDY #T0               ; 2 call sites
ADD_Y_X:
         LDA 0,X             ; If X=0, this is T0. If X=4, this is T2.
         CLC
         ADC 0,Y              ; Y picks the addend: T1 for ADD/MUL, T0 for DIV
         STA 0,X
         LDA 1,X
         ADC 1,Y
         STA 1,X
         RTS

; =============================================================================
; WPEEK  --  skip spaces; return first non-space in A
;
;   In:  IP -> text (may start with spaces)
;   Out: A = first non-space char; IP advanced past any leading spaces
;        (char is NOT consumed -- IP still points to it)
;   Clobbers: A Y      (Y=0 on return)
; =============================================================================
WSK_LP:  JSR BUMP_IP   ; directly increment IP 
WPEEK:   LDY #0
         LDA (IP),Y
         CMP #' '      
         BEQ WSK_LP    ; loop until non-space
         RTS

; =============================================================================
; ADD2_LP  --  LP += 2 (shared by EDITLN, DO_LIST, GOTOL, and LSKIP internally)
; BUMP_LP  --  A= *LP; LP++
;   In:  LP
;   Out: A = *LP, LP advanced by 2 or 1
;   Clobbers: A Y      (Y=0 on return)
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: LDY #0
         LDA (LP),Y           ; Read current character
         INC LP
         BNE *+4
         INC LP+1
         RTS

; =============================================================================
; Prog to IP/LP/PE helper -- IP,PE,LP are consecutive in zero page
; (IP+0, PE+2, LP+4), so one indexed routine covers all three targets.
; PROG2LP is the free entry (most call sites want LP); IP/PE go through
; PROG2X directly with an explicit LDX.
PROG2LP: LDX #LP-IP
PROG2X:  LDA #<PROG
         STA IP,X
         LDA #>PROG
         STA IP+1,X
         RTS

; =============================================================================
; PE_CMP_LP  --  compare LP against PE (shared by EDITLN, GOTOL, DO_LIST)
;
;   In:  LP
;   Out: Z=1 if LP == PE, Z=0 otherwise; Y=1 always (deliberate side effect --
;        EDITLN/DO_LIST/CMP_PLP_X all need Y=1 immediately after this call)
;   Clobbers: A Y
; =============================================================================
PE_CMP_LP:  
         LDX #LP
         LDY #1                ; also satisfies the Y=1 that EDITLN/DO_LIST
PE_CMP_X:                      ; need right after -- see call sites
         LDA 0,X               ; (X) == PE ?  (X = zp offset of a pointer)
         CMP PE
         BNE PC_NE
         LDA 1,X
         CMP PE+1
PC_NE:   RTS

; =============================================================================
; LSKIP  --  advance LP past the current line (shared by EDITLN, GOTOL)
;
;   In:  LP -> start of a line's 2-byte header
;   Out: LP -> start of the next line (past this line's CR terminator)
;   Clobbers: A Y LP
; =============================================================================
LSKIP:   JSR ADD2_LP    ; Skip the 2-byte line number header
LSK_LP:  JSR BUMP_LP    ; Advance LP to the next memory address
         CMP #CR        ; BUMP_LP does not touch A - was it a CR
         BNE LSK_LP     ; No, Loop back and check the next byte
         RTS            ; Done, LP points to the next line

; =============================================================================
; CMP_PLP_X - Compare *LP with X (true 16-bit ordering compare, hi byte first)
;
;   In:  X = zero-page address of the pair to compare against; Y=1 REQUIRED
;        on entry (both call sites reach this right after PE_CMP_LP, which
;        guarantees it -- this routine no longer sets Y itself)
;   Out: Z=1 if equal; C set/clear per a true 16-bit magnitude compare
;        (needed by EDITLN's BCC/BEQ/BNE ordering test, not just equality)
;   Clobbers: A Y      (Y=1 on entry, 0 on return)
; =============================================================================
CMP_PLP_X:
         LDA (LP),Y           ; Y=1 already, from PE_CMP_LP (both call sites
         CMP 1,X                ; call it immediately before this) -- compare
         BNE CPX_DN              ; high byte first for a true ordering test
         DEY                  ; Y=1 -> 0 (compare line-number lo)
         LDA (LP),Y
         CMP 0,X
CPX_DN:  RTS

ROMEND: ; for auditing

; =============================================================================
; Reset / IRQ / NMI vectors
; =============================================================================
         .ORG $FFFA
         .DW INIT         ; $FFFA: NMI vector (no NMI)
         .DW INIT         ; $FFFC: reset vector
         .DW INIT         ; $FFFE: IRQ/BRK vector (No IRQ)
