; =============================================================================
; PicoBASIC65c02 v1.7  --  Proof of Concept 1 KB Tiny BASIC for 65c02 
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Note: Kowalski Memory Mapped IO for now.
KOWALSKI        = 1
;
;   CPU    : 65c02 (wanted NMOS but need extra code density)
;   ROM    : 1 KB  $FC00-$FFFF - use 2kbyte for development, see ORIGIN label 
;   RAM    : 1 KB  $0000-$03FF
;   I/O    : Kowalski emulation 0xE001 PUTCH, 0xE004 GETCH
;   NMI/IRQ: Not used
;
; RAM layout for 1 KB target:
;   $0000-$007F  zero-page (IP/CURLN/PE/LP/T0-T3/RUN/BANG/VARS/IBUF);
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full or 2-letter prefix):
;   ASK[=INPUT]  END  GOTO <expr> IF  PRINT  WR <expr>
;   LIST  NEW  RUN
;
; ASK is INPUT's keyword -- 'I' already taken by IF, see TOK_CHARS.
; WR <expr> emits an ASCII char - replaces CHR$, not usable in PRINT.

; Arithmetic: + - * /  (unary -) Left to Right Precidence 
; Relops: =  <  prefix with ! to invert: !=, !< -- see KNOWN LIMITATIONS
;
; Numbers : signed 16-bit  (-32768 .. 32767)
; Print   : "literals", `;` - no string vars
;
; KNOWN LIMITATIONS
;
; GETLINE - no Backspace support or range limits - too many characters will crash.
;
; DO_ERROR - minimal error handling: "!X", where X is error code, but no line number. 
;
; EDITLN is append-only: a typed line is only accepted when greater than every line
;   currently stored (appends), or if it matches the current LAST stored line i.e.
;   in-place replace or delete if empty body. Editing/deleting mid-program lines
;   is rejected with "!5" 
;
; No operator precedence: all operators (+,-,*,/,=,<) evaluate left to right,
;   same tier. Use parentheses to group, e.g. "A*A/64-B*B/64+C" must be written
;   "(A*A/64)-(B*B/64)+C" for standard-math meaning; "1+2*3" evaluates
;   as (1+2)*3=9, not 7. Same-operator chain (all */ or all +-,
;   e.g. "2*A*B/64") needs no parens.
;
; Relops: Only "<" and "=" are supported - use flipped operands
;   for ">", e.g. "A>B" as "B<A". A leading "!" inverts following relop:
;   "A!=B" is A<>B, "A!<B" is A>=B, and "B!<A" is A<=B.  "!" is only valid before
;   "=" or "<": if followed by an arithmetic op the invert will apply to the next
;   relop evaluated *within the same expression*, e.g. "3!*2=6" reads as false 
;   even though 3*2=6 is true. It does NOT cross statement or command boundary
;
; IF <expr> <stmt> - no THEN keyword "IF 3<5 PRINT 1" not "IF 3<5 THEN PRINT 1".
;   Nests freely since IF is itself a statement: "IF a IF b stmt".
;
; Two Character keyword matching - only 2 chars matched then rest of the word
;   is consumed until a space or `(`.  Spaces are needed: `10 PRINT A works,
;   `10 PR A` also works, but `10 PRINTA` does not.
;
; Char Case: All characters must be UPPERCASE apart from PRINT string literals
;
; To save Space, LET, REM and THEN keywords not used. 
;
; DO_GO - "GO 10" as FIRST/immediate command (no active RUN) fails since
;   DO_GO discards caller's return address assuming RUNEND will eventually be
;   reached via a RUN session's call.
;
; Numbers are signed 16-bit only (-32768..32767); arithmetic overflow
;   wraps silently (e.g. 32767+1 = -32768) -- it does not raise an error.
;
;
; Error codes 
;   0! syntax / bad expression (not implemented)
;   1! undefined line number
;   2! division by zero
;   3! out of memory (not implemented)
;   4! bad variable name 
;   5! Line editing error
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
; v1.7 - 0 bytes free before vectors - Golf Pass 
;   - Restored banner (Yay!)
;   - Dropped the blank-line CR check; STMT already returns on CR via WPEEK/BCC
;   - 65c02 instruction BBR7 on MUL_ENTRY and PRT16 sign checks
;   - Removed RUNSP stack-pointer in DO_GO/RL_GO - DO_GO now cleans up stack with 
;     PLA/PLA instead of snapshotting/restoring SP.
;   - DO_LIST refactored to save 2 byets by reordering CRLF at start 
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
         .opt proc65c02

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
ERR_OV   = '2'                 ; division or modulo by zero
ERR_OM   = '3'                 ; out of memory
ERR_UK   = '4'                 ; bad variable name in LET
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
CURLN:      .RS 2              ; 16-bit: currently-executing line number
        .IF KOWALSKI
PE:         .DW SHOWCASE_END   ; Preload Showcase for testing
        .ELSE
PE:         .RS 2              ; 16-bit: program end (one past last byte)
        .ENDIF
LP:         .RS 2              ; 16-bit: line pointer / multi-purpose scratch
RUN:        .RS 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
BANG:       .RS 1              ; 8-bit: relop invert flag ($00/$FF) -- see EXPR_LOOP/REL_T.
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
;   BANG : relop invert flag ($00/$FF) -- set by a leading '!' before a
;          relop, consumed and cleared at REL_T/REL_F (covers chaining,
;          e.g. "3!<2!<1") and at EL_RTS (every expression's normal end,
;          which also covers a trailing '!' with nothing after it). Also
;          cleared once at the top of MAIN as a backstop. The only gap is
;          a '!' stolen by an arithmetic op leaking into a later relop
;          within the SAME expression -- see KNOWN LIMITATIONS.
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
         .DB $8C,$00,"IF 5!<3 PRINT ",$22,"5!<3 ok",$22,CR  ; 140 IF 5!<3 PRINT "5!<3 ok"
         .DB $96,$00,"IF 3!=4 PRINT ",$22,"3!=4 ok",$22,CR  ; 150 IF 3!=4 PRINT "3!=4 ok"
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
BANNER: .DB "pBASIC1.7",0                ; Signon 

; =============================================================================
; TOK_CHARS / TOK_VECS -- combined match-char + dispatch-vector tables.
;
;   TOK_CHARS: one raw byte per token, same index space as TOK_VECS.
;     Indices 0..OP_COUNT-1 (0-5)      : operator chars, "-+/*=<"
;     Indices OP_COUNT..MAX_TOK-1(6-14): statement 1st letters, "PIGLRNAEW"
;       (PRINT/IF/GOTO/LIST/RUN/NEW/ASk[INPUT]/END/WR -- 1st letters are
;       unique across all 9 statements by design -- ASK instead of INPUT
;
;   TOK_VECS: one word per token same sequence as TOK_CHARS
; =============================================================================
TOK_CHARS:
; -- operator chars --
          .DB "-+/*=<"        ; indices 0..5
OP_COUNT  = * - TOK_CHARS     ; 6

; -- statement 1st chars --
          .DB "PIGLRNAEW"     ; indices 6..14 (PR,IF,GO,LI,RU,NE,AS,EN,WR)
MAX_TOK   = * - TOK_CHARS     ; 15

TOK_VECS:
; -- operator vectors --
          .DW DO_SUB
          .DW DO_ADD
          .DW DIV_ENTRY
          .DW MUL_ENTRY
          .DW DO_EQ
          .DW DO_LT
; -- statement vectors --
          .DW DO_PRINT
          .DW DO_IF
          .DW DO_GO
          .DW DO_LIST
          .DW DO_RUN
          .DW DO_NEW
          .DW DO_INPUT
          .DW DO_END
          .DW DO_WR
          .DW DO_LET          ; index 15: fallback vector for LET/assignment

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
         LDA (LP)             ; read line number lo
         STA T0
         LDA (LP),Y           ; read line number hi
         STA T0+1
         ;
         JSR PRT16            ; print line number
         JSR PRTSPACE
         JSR ADD2_LP
LS_BODY: JSR BUMP_LP
         CMP #CR                ; A still has char
         BEQ LS_EOL
         JSR PUTCH
         BRA LS_BODY          ; 

; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to body (past 2-byte header); CURLN = T0
;        C=1  not found -- IP = PE; CURLN unchanged
;   Clobbers: A X Y IP LP CURLN
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
         BRA GT_SC            ; Loop

GT_OK:   JSR T0_TO_CURLN
         JSR ADD2_LP          ; LP += 2, past the 2-byte header
         CLC                  ; C=0 means Success
         
COPY_LP_IP:
         LDA LP               ; Carry flag passes through these unchanged
         STA IP
         LDA LP+1
         STA IP+1
LS_DONE:
EL_DN:
         RTS                  ; Exit. C=1 (Not Found) or C=0 (Found)

; =============================================================================
; EDITLN  --  MINIMAL append-only line-store editor
;
;   In:  IP -> line-number digits (MAIN has already confirmed the line
;        starts with a digit)
;   Out: accepted line appended to the end of the store, or the current
;        LAST line is replaced/deleted in place; PE/LP updated. Any other
;        target line number falls through to DO_ERROR and does not return
;        here.
;   Clobbers: A X Y T0 T1 T3 IP CURLN PE LP
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
EL_ERR:  JMP DO_ERR_EL          ; out of order / mid-store edit rejected

EDITLN:
         JSR PNUM             ; parse line number -> T0; IP advances past digits
         JSR T0_TO_CURLN
         JSR PROG2LP
         BRA EL_FL            ; skip the LSKIP on first pass
EL_SKIP: JSR LSKIP            ; advance LP to next line
EL_FL:   JSR PE_CMP_LP        ; reached end of store?
         BEQ EL_CHK_CR        ; yes: nothing to match against -- append
         LDX #CURLN              ; compare CURLN with *LP
         JSR CMP_PLP_X           ; returns with Y=1
         BCC EL_SKIP          ; stored line < target: keep scanning
         BNE EL_ERR           ; stored line > target: out of order

         ; --- exact match - legal only if it's the LAST stored line ---
         LDX #LP-VARS
         JSR X_TO_T0           ; T0 = LP (start of the matched line)
         JSR LSKIP             ; advance LP past the matched line
         JSR PE_CMP_LP         ; did that land on the end of the store?
         BNE EL_ERR            ; no: an earlier line -- reject

         JSR T0_TO_X             ; LP = T0 (ready to overwrite in place)
         LDX #PE-VARS
         JSR T0_TO_X            ; PE = T0 (excise the matched line)

EL_CHK_CR:
         JSR WPEEK             ; skip spaces + peek (no consume) first body char
         CMP #CR
         BEQ EL_DN             ; CR only: delete-only, done
        
        ; *LP=CURLN
         LDA CURLN
         STA (LP)              ; write line number lo
         LDA CURLN+1            ; Y=1 guaranteed here via PE_CMP_LP (both
         STA (LP),Y            ; paths into here call it right beforehand)
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
EL_RTS:  STZ BANG              ; Expression Loop out of tokens (harmless
         RTS                   ; here too, on EDITLN's line-store fallthrough)

; =============================================================================
; EXPR  --  strictly left-to-right expression evaluator (no operator
;   precedence; use parentheses to group, e.g. "(A*A/64)-(B*B/64)+C" or
;   "256<((A*A/64)+(B*B/64))" -- see the showcase's Mandelbrot section for
;   real examples of exactly this).
;
;   Operators matched against TOK_CHARS's operator section (X counts up
;   from -1 -- see TOK_CHARS/TOK_VECS header).
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
E1_OVFL:  JMP DO_ERR_OV

; --- Relational: Equality ---
; LDA T1/ CMP T0 already done
DO_EQ:   BNE REL_F              ; 
         LDA T1+1               ; 
         CMP T0+1
         BEQ REL_T
         BRA REL_F              ; 

; =============================================================================
; OP_HIT  --  operator match handler: consume operator, shuffle operands
;
;   In:  X = matched operator's index into TOK_CHARS/TOK_VECS (0..5);
;        IP -> the matched operator char (not yet consumed); T0 = left
;        operand (from EXPR2/a prior OP_HIT)
;   Out: T1 = left operand, T0 = right operand; falls through into DO_DISP
;   Clobbers: A X T0 T1 IP (Y/T2/T3 via EXPR2)
; =============================================================================
OP_HIT:  JSR GETCI             ; consume the matched operator char
         PHX                   ; save matched index across EXPR2
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
         PLX                   ; restore matched index
         ; falls through into DO_DISP

; =============================================================================
; DO_DISP  --  shared vector dispatch via 65C02 absolute indexed-indirect JMP
;
;   In:  X = matched index into TOK_CHARS/TOK_VECS (0..MAX_TOK)
;   Out: tail-jumps into the matched handler; never returns to caller here
;   Clobbers: A X
; =============================================================================
DO_DISP:
         TXA
         ASL                  ; *2 for word offset into TOK_VECS
         TAX
         ; Initial Relop setup - ignored by Arithmetic & Statements
         LDA T1
         CMP T0
         ; And Jump
         JMP (TOK_VECS,X)       ; and jump to DO_xxx
         
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
         EOR BANG             ; A and BANG are always $00/$FF, so this is
         STA T0
         STA T0+1
CLR_BANG:         
         STZ BANG              ; a conditional invert; then reset for next relop
         BRA EXPR_LOOP

; --- Addition & Subtraction ---
DO_SUB:  JSR NEG_T0            ; negate right operand (T0), fall through to ADD
DO_ADD:  LDX #T0              ; Target X=0 (T0). Sets Z flag
         BRA DO_ADD_TAIL      ; Jumps straight into shared ADD logic      
         
EXPR:
         JSR EXPR2            ; parse the first atom -> T0
EXPR_LOOP:
         JSR WPEEK            ; peek next char (not consumed)
         LDX #OP_COUNT-1      ; 2 bytes (Starts at 5)
OP_SCAN: CMP TOK_CHARS,X      ; 3 bytes
         BEQ OP_HIT           ; 2 bytes
         DEX                  ; 1 byte
         BPL OP_SCAN          ; 2 bytes (Falls through here when X drops to $FF)
         CMP #'!'             ; not an operator char -- check for relop invert
         BNE EL_RTS           ; not relop invert
         DEC BANG             ; INVERT - set BANG to $FF  
         JSR BUMP_IP          ; consume `!`
         BRA EXPR_LOOP        ; loop

; --- Multiplication & Division ---
DIV_ENTRY:
         LDA T0
         ORA T0+1
         BEQ E1_OVFL          ; T0 == 0 -> Division by zero error
         LDY #1                ; remember: divide (Y survives the shared
         .DB $2C               ; sign-prep below untouched -- checked)
MUL_ENTRY:
         LDY #0                ; remember: multiply
         LDA T1+1
         EOR T0+1
         PHA                  ; Save result sign
         BBR #7,T1+1,E1_P1    ; skip if T1 positive (bit-test, no LDA needed)
         LDX #T1
         JSR NEG_X           ; Make T1 positive
E1_P1:   BBR #7,T0+1,E1_P2    ; skip if T0 positive
         JSR NEG_T0            ; Make T0 positive
E1_P2:   STZ T2               ; Clear T2 (product/quotient accumulator)
         STZ T2+1
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
         BRA EXPR_LOOP        ; If X=0, addition is done 

; Back to ALU ops
DIV_LOOP:
        JSR NEG_T0            ; T0 = -T0 (negated divisor)
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
E1_POS:  BRA EXPR_LOOP         ; 

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
; EXPR2  --  atom level: parentheses, unary +/-, number literals, variables
;
;   In:  IP -> atom text
;   Out: T0 = atom value; IP advanced past atom
;   Clobbers: A X Y T0 T1 T2 IP
;
;   E2_POS: entry for unary '+' -- consumes the '+' then falls into EXPR2.
;   E2_NEG: entry for unary '-' -- consumes '-(via E2_POS) then negates result.
; =============================================================================
E2_POS:  JSR GETCI            ; consume unary '+', then fall through
EXPR2:
         JSR WPEEK
         CMP #'('
         BEQ E2_PAR
         CMP #'-'
         BEQ E2_NEG
         CMP #'+'
         BEQ E2_POS
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
         STZ T0                ; clear result lo
         STZ T0+1              ; clear result hi
PN_LP:   LDA (IP)              ; peek without consuming
         EOR #'0'              ; [OPT] Maps '0'-'9' to 0-9. Anything else maps >= 10
         CMP #10               ; [OPT] Check bounds
         BCS PN_DN             ; If A >= 10, not a digit -- done

         STA T3                ; seed running sum lo with digit
         STZ T3+1               ; seed running sum hi with 0
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
         BRA PN_LP             

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
;   Clobbers: A IP
; =============================================================================
GETCI:   LDA (IP)
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
         TXS                  ; set stack to top of page 1
         CLD                  ; ensure binary (not decimal) mode

        .IF KOWALSKI     
         JSR DO_END           ; setup RUN
        .ELSE
         JSR DO_NEW           ; setup PE, PROG, RUN
        .ENDIF

        ; Print signon Banner - delete frees 19 bytes for UART init code
         STZ IP                  ; Banner Low byte - banner must be at $xx00
         LDA #>BANNER
         STA IP+1
         JSR DP_STR

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
;
;   In:  -- (entered by fall-through from INIT/DO_END, or JMP from DO_ERROR)
;   Out: never returns (loops back to itself indefinitely)
;   Clobbers: everything
;
;   Reads one line from the terminal.  Lines that start with a digit are
;   routed to EDITLN (program store editor); else executed via STMT.
; =============================================================================
MAIN:
         LDX #HWSTACK
         TXS                  ; Reset stack
         STZ RUN              ; not running
         STZ BANG             ; Clear relops invert from OP_SCAN
         
         JSR GETLINE_M        ; print "> "; read line

         JSR WPEEK            ; skip spaces; peek first non-space char into A
                               ; blank line (CR) falls through: EOR/CMP below
                               ; sends it to MAIN_DIR -> STMT, which returns
                               ; immediately on CR via its own WPEEK/BCC check
         EOR #'0'             ; 2 bytes (Maps '0'-'9' to 0-9; all other ASCII wraps >= 10)
         CMP #10              ; 2 bytes
         BCS MAIN_DIR
         JSR EDITLN           ; digit: store / delete numbered line
         BRA MAIN
MAIN_DIR:
         JSR STMT              ; execute as immediate statement
         BRA MAIN

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
         JSR EXPR             ; evaluate expression -> T0
         BRA STORE_VAR         ; tail call: pop var_offset, store T0, RTS

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
         BRA BUMP_IP     ; (2) increments IP, leaves Carry clear (C=0)

; =============================================================================
; DO_NEW  --  NEW  :  Set default program store
; DO_END  --  END  :  halt program execution and return to immediate mode
; =============================================================================
DO_NEW:
         LDX #PE-IP
         JSR PROG2X            ; PE = PROG
DO_END:
RUNEND:  STZ RUN
         RTS

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
         BRA MAIN

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
         JSR EXPR             ; evaluate RHS -> T0
         ; falls through into STORE_VAR 
; =============================================================================
; STORE_VAR  --  shared tail: pop var_offset pushed by caller, store T0 there
;
;   In:  T0 = value to store; hardware stack top = var_offset (from PARSE_VAR)
;   Out: VARS[var_offset] = T0; RTS to caller's caller
;   Clobbers: A X
; =============================================================================
STORE_VAR:
         PLX            ; restore offset
         .DB $2c         ; consume next 2 bytes
T0_TO_CURLN:
         LDX #CURLN-VARS         ; wraps
T0_TO_X:         
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
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: IP = body of target line; pending JSR STMT return address
;        discarded (RUNGO's own JSR STMT replaces it); RUNGO
;   Clobbers: A X Y T0 T1 T2 T3 IP SP CURLN  (T1-T3 via EXPR; CURLN via GOTOL
;             on a successful lookup)
;
; =============================================================================
DO_GO:
         JSR EXPR             ; Parse target line number -> T0 (LP no longer needed)
         JSR GOTOL            ; find line: C=0 found, C=1 not found
         BCS DO_ERR_UL        ; Line not found error 
         PLA                  ; discard the pending JSR STMT return address --
         PLA                  ; RUNGO's own JSR STMT always returns to the
                              ; same place, so there's always exactly one
         BRA RUNGO            ; frame to drop, no snapshot needed

; =============================================================================
; DO_RUN  --  RUN  :  execute program starting from the first line
;
;   In:  PE = current program end
;   Out: program executes; returns to MAIN on END/error/STOP
;   Clobbers: A X Y T0 T1 T2 T3 IP SP RUN CURLN
;
;   RUNLP: top of the per-line execution loop, reads the next line header.
;   RUNGO: mid-loop entry used by GOTO (after IP is already set to body) --
;          also the return point its own JSR STMT unwinds back to, which is
;          what lets DO_GO discard exactly one frame with a bare PLA/PLA.
; =============================================================================
DO_RUN:
         LDX #0
         JSR PROG2X           ; PROG to IP
         SMB #0,RUN           ; set run flag (only bit0 is ever tested --
RUNLP:   LDA IP                ; IP == PE? (natural end of program --
         CMP PE                ; may not be a hard stop otherwise: a
         BNE RL_GO             ; deleted/replaced last line leaves old,
         LDA IP+1              ; well-formed data sitting past the new
         CMP PE+1               ; PE, which would otherwise look like
         ;
         BEQ RUNEND             ; one more real line to execute)
RL_GO:   JSR GETCI            ; read line-number lo
         STA CURLN
         JSR GETCI            ; read line-number hi
         STA CURLN+1
RUNGO:   JSR STMT               ; execute the statement on this line
         BBR #0,RUN,RUNEND     ; RUN cleared by END/error -- stop
SK_LP:   JSR GETCI            ; advance IP past CR (SKIPEOL inlined)
         CMP #CR
         BNE SK_LP
 	 BRA RUNLP		; always taken

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
         CMP #' '             ; anything below space (CR, NUL) means empty line
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
         LDA (IP)              ; 1st char (not yet consumed)

         LDX #OP_COUNT         ; skips operator chars
MD_LP:   CMP TOK_CHARS,X
         BEQ SKIP_KW           ; matched statement's 1st char
         INX
         CPX #MAX_TOK
         BNE MD_LP             ; loop until the last statement is checked

SKIP_KW: LDA (IP)              ; peek next char -- do NOT consume yet
         SEC
         SBC #'A'               ; must be fresh each pass -- carry left over
         CMP #26                ; from the previous iteration's CMP #26 is
         BCS SK_DONE            ; not safe here (wraps 'A' past 255)
         JSR BUMP_IP            ; it IS a letter -- consume it, keep going
         BRA SKIP_KW
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
         BBR #7,T0+1,PRT16GO  ; positive: skip sign handling (bit-test, no LDA)
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
         BRA PUTCH

; =============================================================================
; DO_WR  --  WR <expr>  :  write one raw ASCII char (low byte of <expr>)
;
;   In:  IP -> expression text
;   Out: one character written to the terminal; IP advanced
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
DO_WR:   JSR EXPR             ; evaluate <expr> -> T0
         LDA T0               ; low byte
         BRA PUTCH            ; tail call: PUTCH's own RTS returns to caller

; =============================================================================
; GETLINE  --  MINIMAL read one line from the terminal into IBUF; set IP = IBUF
;
;   Entry points sharing one body:
;     GETLINE_M  prints "> " (immediate-mode prompt)
;     GETLINE    no prompt
;
;   In:  --
;   Out: IBUF filled with input, CR-terminated; X is # chars
;   Clobbers: A, X is GETLINE's own buffer index
;   
;   Note: NO Range checking/Backspace support - Overflow could crash  
; =============================================================================
GETLINE_M:
         LDA #'>'            ; (2) Prompt for Direct Mode
         JSR PUTCH           ; (3) Print prompt character ('?' or '>')
GETLINE:
         JSR PRTSPACE        ; (3) Print trailing space
         ; Initialize IP to point at IBUF
         STZ IP+1            ; (2) >IBUF 0 as ZP
         LDA #IBUF           ; (2)
         STA IP              ; (2)
         ; Clear char counter
         LDX #0
GL_LOOP:
         JSR GETCH      ; (3) Wait for and get keystroke in A
         STA IBUF,X     ; (2) Store raw character into buffer
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
         BRA PUTCH              ; always taken
  
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
         BRA DP_STR           ; Loop

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
;   Clobbers: A
; =============================================================================
WSK_LP:  JSR BUMP_IP   ; directly increment IP 
WPEEK:   LDA (IP)      
         CMP #' '      
         BEQ WSK_LP    ; loop until non-space
         RTS

; =============================================================================
; ADD2_LP  --  LP += 2 (shared by EDITLN, DO_LIST, GOTOL, and LSKIP internally)
; BUMP_LP  --  A= *LP; LP++
;   In:  LP
;   Out: A = *LP, LP advanced by 2 or 1
;   Clobbers: A
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: LDA (LP)       ; Read current character
         INC LP
         BNE *+4
         INC LP+1
         RTS

; =============================================================================
; Prog to IP/LP/PE helper -- IP,CURLN,PE,LP are consecutive in zero page
; (IP+0, PE+4, LP+6), so one indexed routine covers all three targets.
; PROG2LP is the free entry (most call sites want LP); IP/PE go through
; PROG2X directly with an explicit LDX.
PROG2LP: LDX #6
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
         LDY #1                ; also satisfies the Y=1 that EDITLN/DO_LIST
         LDA LP                ; need right after -- see call sites
         CMP PE
         BNE PC_NE
         LDA LP+1
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
;   Clobbers: A
; =============================================================================
CMP_PLP_X:
         LDA (LP),Y           ; Y=1 already, from PE_CMP_LP (both call sites
         CMP 1,X                ; call it immediately before this) -- compare
         BNE CPX_DN              ; high byte first for a true ordering test
         LDA (LP)             ; 65C02: implied Y=0 (compare line-number lo)
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
