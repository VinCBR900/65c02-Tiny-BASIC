; =============================================================================
; PicoBASIC65c02 v0.9  --  Proof of Concept 1 KB Tiny BASIC for 65c02 
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Note: Kowalski Memory Mapped IO for now.
KOWALSKI        = 1
;
;   CPU    : 65c02 (wanted NMOS but need extra code density)
;   ROM    : Currently 2 KB  $F800-$FFFF for developmetn but will be $FC00-FFFF
;   RAM    : 1 KB  $0000-$03FF
;   I/O    : Kowalski emulation 0xE001 PUTCH, 0xE004 GETCH
;   NMI/IRQ: Not used
;
; RAM layout for 1 KB target:
;   $0000-$007F  zero-page (IP/CURLN/PE/LP/T0-T3/RUN/IBUF/VARS/RUNSP);
;                ZPEND=$7F, fits the $80-$FF/$180-$1FF hardware-stack RAM
;                alias constraint. No GOSUB so no GS stack 
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full or 2-letter prefix):
;   INPUT  END  GOTO <expr> IF  PRINT  WR <expr>
;   LIST  NEW  RUN
; WR <expr> emits an ASCII char - replaces CHR$, not usable in PRINT

; Arithmetic: + - * /  (unary -) Left to Right Precidence 
; Relops: =  <
;
; Numbers : signed 16-bit  (-32768 .. 32767)
; Print   : "literals", `;` - no string vars
;
; KNOWN LIMITATIONS
;
; GETLINE - no Backspace support or range limits - too many characters will crash.
;
; DO_ERROR - minimal error stub, shows error number, no line
;
; DO_GO - "GO 10" as FIRST command of a session fails since RUNSP is 0 from NEW.
;
; No operator precedence: all six operators (+,-,*,/,=,<) evaluate left to right,
;   same tier. Use parentheses to group, e.g. "A*A/64-B*B/64+C" must be written
;   "(A*A/64)-(B*B/64)+C" for standard-math meaning; "1+2*3" evaluates
;   as (1+2)*3=9, not 7. Same-operator chain (all */ or all +-,
;   e.g. "2*A*B/64") needs no parens.
;
; Relops: Only "<" and "=" are supported - use flipped operands for ">", e.g.
;   "A>B" as "B<A".  Hence ">=", "<=", "<>" not supported.
;
; IF <expr> <stmt> : no THEN keyword "IF 3<5 PRINT 1" not "IF 3<5 THEN PRINT 1".
;   Nests freely since IF is itself a statement: "IF a IF b stmt".
;
; Two Character keyword matching - only 2 chars matched then rest of the word
;   is consumed until a space or `(`.  Spaces are needed: `10 PRINT A works,
;   `10 PR A` also works, but `10 PRINTA` does not.
;
; Char Case: All commands must be UPPERCASE apart from PRINt string literals
;
; No `:` multi-statement support, no GOSUB?RETURN, FOR/NEXT, no arrays/DIM/strings
;
; Numbers are signed 16-bit only (-32768..32767); arithmetic overflow
;   wraps silently (e.g. 32767+1 = -32768) -- it does not raise an error.
;
; Input buffer is 35 usable chars + CR terminator
;
; To save Space, LET keyword not used. 
;
; Error codes
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division by zero
;   ?3  out of memory
;   ?4  bad variable name 
;
; ---- program storage --------------------------------------------------------
;   Base $0180 to ceiling RAM_TOP ($0400 for 1 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; ---- version lineage --------------------------------------------------------
;   v0.1              Initial port from NMOS uBASIC 2kbyte V1.11 
;   v0.2              Initial Size reduction pass toward 1 KB target:
;                        - Dropped `%` (MOD), GOSUB/RETURN 
;                          Relops narrowed to `=` and `<` only
;                        - Removed Functions and args extraction
;                        - MATCH_DISPATCH: folded matched-handler push
;                          and sentinel/no-match push into shared tail.
;                        - Initial update of Showcase for new functionality
;   v0.3              Refactor for size, now 1294 Bytes 
;                        - EXPR/EXPR_ADD/EXPR1 replaced with EXPR/EXPR_LOOP,
;                          left to right precedence, no tiers.
;                        - UNI_TAB gained an operator section (6 entries,
;                          stride 3) ahead of the statement section
;                        - GETLINE, DO-ERROR minimized.  
;                        - DELINE/EDITLN/INSLINE code-golfed.
;                        - EXPR code golfed for O(n) MUL
;   v0.4              Refactor for Size - 1181 bytes
;                       - Generalized T0_CMP_LP -> T0_CMPX 
;                       - Bugfix DELINE's shift loop.
;                       - Added few 65c02 opcodes
;                       - Refactor DO_MD for seperate entry points for MUL/DIV
;   v0.4a             Refactor/Bug Fix - 1186 bytes 
;                       - Generalized ADD_X_Y to add (T0,Y) into (T0,X)
;                         instead of hardcoding T1 as the addend. 
;                       - Reused ADD_X_Y in PNUM's digit-accumulate
;                         loop (T3 += T0 x10): X=T3, Y=0/T0 fixed for the
;                         whole loop (ADD_X_Y clobbers neither)
;   v0.5              Continued Refactor for Size - 911 bytes before vectors
;                        - Removed CHR$ and THEN; added WR <expr> - writes a
;                          ASCII char, statement-level replacement for CHR$
;                        - DO_IF: dropped optional-THEN JSR MTCHKW.  IF still
;                          nestsas its own statement ("IF a IF b stmt").
;                        - MTCHKW: dropped trailing-'$' special case for CHR$
;                        - Showcase updated: "THEN" dropped from every IF;
;                          CHR$(expr) converted to WR expr
;                        - ASK/INPUT broken - late breaking.
;   v0.6              Dispatch refactor - 962 bytes free before vectors
;                      Replaced UNI_TAB (stride-3 operator + stride-4
;                      2-char-keyword KW_TAB, RTS-trick dispatch) with
;                      TOK_CHARS (flat 1 byte/token: 6 operator chars +
;                      9 statement 1st-letters, unique by design -- see
;                      the "ASK" rename note from v0.5^) + TOK_VECS (flat
;                      2 bytes/token, exact addresses) dispatched via
;                      JMP (TOK_VECS,X). MATCH_DISPATCH now matches a
;                      statement on its 1st letter alone (was: full
;                      MTCHKW 2-char compare) -- MTCHKW removed, its
;                      trailing-letter-skip loop now inlined as SKIP_KW.
;   v0.7              Debugged a hand-optimized rewrite of EDITLN/INSLINE/
;                      DELINE (submitted with "adding new lines" broken --
;                      hung on the very first line typed after NEW). Found
;                      and fixed 3 bugs, all in the same line-store area:
;                        - INSLINE's IN_CP copy loop: source, written as
;                          "LDA (IP),X" / "STA (LP),X", isn't valid 6502/
;                          65C02 syntax -- indirect-indexed addressing only
;                          exists as ",Y" (indexed-indirect "(zp,X)" is a
;                          different mode entirely, computed before the
;                          dereference). The assembler silently accepted it
;                          as plain zero-page,X instead of erroring, so it
;                          compiled to reading/writing raw zero page at
;                          IP+X / LP+X -- corrupting IP/CURLN/PE/LP/RUN as
;                          X counted up. This alone was the reported hang.
;                          Rewritten with Y (free at that point in the
;                          routine) as proper indirect-indexed addressing.
;                        - DELINE's shift-down copy was "LDA (T0)/STA (T0)"
;                          -- same address both sides, a no-op. PE shrank
;                          by the deleted line's length but the following
;                          lines' bytes never actually moved down to close
;                          the gap, desyncing the store from PE (visible
;                          as a stale duplicate line surviving past the
;                          new PE, and worse corruption once a 2nd delete
;                          or insert compounded on top of the first).
;                          Rewritten to genuinely shift: reads the byte
;                          `length` bytes ahead (Y, held constant as an
;                          actual value for the whole loop -- unlike T1
;                          just above it, which is reused as an address)
;                          and writes it to T0, walking T0 up to the new
;                          PE.
;                        - DO_RUN/RUNLP had no boundary check: after the
;                          last real line's CR, it would unconditionally
;                          try to read "the next line" header regardless
;                          of whether IP had reached PE. Harmless before
;                          this session (DELINE's shift was a no-op, so
;                          deleting never left well-formed leftover data
;                          behind to misread as a phantom extra line) and
;                          harmless for a program ending in a real END.
;                          Became a real, reproducible bug once DELINE's
;                          shift was fixed to actually shift: the freed
;                          tail past the new PE is left as-is (not
;                          cleared), and for a multi-line delete-then-RUN
;                          that tail can be a genuine well-formed leftover
;                          line, which RUNLP would then execute as if it
;                          were really there. Added an explicit IP==PE
;                          check at the top of RUNLP; RUN now also exits
;                          cleanly (no spurious "!") when a program simply
;                          runs off the end without an explicit END.
;                      All 3 verified via sim65c02: single insert,
;                      out-of-order insert (mid-store shift), exact-match
;                      replace, delete-only (both list-preserving and
;                      with multiple trailing lines needing to shift),
;                      GOTO/IF loop, and the full preloaded showcase.
;   v0.8              Code golf: DELINE's "PE -= length" was an inline
;                      SEC/LDA/SBC/STA pair (13 bytes) -- swapped for the
;                      already-shared NEG_T1+ADD_X_Y helpers (10 bytes at
;                      the call site, paid for elsewhere already). Length
;                      (in Y from the DL_LL scan) survives untouched
;                      through X_TO_T0 and NEG_T1 -- neither clobbers Y --
;                      so it only needs stashing across the ADD_X_Y call
;                      itself, which repurposes Y as T1's address, not a
;                      value; 65C02 PHY/PLY (1 byte each, no TYA/TAY
;                      needed) instead of stack-via-A. Net 3 bytes: 952
;                      free (was 949). Full regression re-verified
;                      unchanged (same 6 cases as v0.7's entry above).
;   v0.9               954 bytes free before vectors
;                      Code golf: INSLINE's "new PE = old PE + gap length"
;                      computed via T0 (a copy of old PE, taken moments
;                      earlier for the shift loop below) then stored to
;                      PE (12 bytes: TYA/CLC/ADC T0/STA PE/LDA T0+1/
;                      ADC #0/STA PE+1). PE's own storage is still the
;                      old value untouched at that point (T0 is only a
;                      copy of it), so the add can target PE directly --
;                      and the high-byte step can drop from an
;                      unconditional LDA/ADC #0/STA to the standard
;                      BCC/INC carry-propagate idiom, since the addend's
;                      (gap length's) own high byte is always 0. 10 bytes.
;                      Checked ADD_X_Y/ADD_A_X_Y first (same idea as
;                      DELINE's v0.8 entry above): no win here -- Y (gap
;                      length) is needed again right after by the shift
;                      loop's STA (T0),Y, and ADD_X_Y's calling
;                      convention repurposes Y as the addend's address,
;                      so surviving the call costs a mandatory PHY/PLY
;                      with no free ride this time (DELINE's NEG_T1
;                      detour didn't touch Y; nothing does here) --
;                      would've been 13 bytes, 1 *worse* than the
;                      original, so skipped in favor of the direct form.
;                      Net 2 bytes: 954 free (was 952). Regression
;                      re-verified (same 6 cases, plus a new 7th: 30
;                      sequential single-line inserts, chosen to force
;                      PE's low byte through a page-boundary carry and
;                      specifically exercise the new BCC/INC path).
; ---- assembler mode ---------------------------------------------------------
         .opt proc65c02

; ---- Kowalski Emulated IO ---------------------------------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)

; Interpreter Defines
ORIGIN   = $F800
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
RUNSP:      .RS 1              ; 8-bit:  stack-pointer snapshot for GOTO/BREAK unwind
VARS:       .RS 52             ; 52-byte variable store (A-Z, 2 bytes each)
LLEN:       .RS 1              ; Line length counter 
IBUF:       .RS IBUF_MAX+1     ; Input line buffer 
ZPEND:		; audit
; ---- Zero-page lifetime notes -----------------------------------------
; Most of these bytes serve a single, obvious purpose. Where a byte serves
; more than one at different times, that's safe only because this is a
; single-threaded interpreter with no reentrancy between the uses. If that
; ever changes (e.g. an IRQ-driven path that touches these), re-check.
;   T0   : primary scratch / expression result -- live during nearly any
;          statement or expression evaluation; the most heavily reused byte
;   T1   : secondary scratch -- OP_HIT's left-operand stash (all six
;          operator handlers read it), also the MUL/DIV kernel's
;          dividend/multiplicand working value
;   T2   : tertiary scratch -- PUTSTR/PRNL's string pointer; historically
;          also a STMT jump target (no longer true since the RTS-trick
;          dispatch was retired -- MATCH_DISPATCH doesn't touch T2 at all)
;   T3   : PNUM's x10-multiply accumulator -- a proper 16-bit pair (T3 lo,
;          T3+1 hi), live only during decimal parsing/printing, adjacent
;          so its final value can be copied to T0 via X_TO_T0. (DO_MD used
;          to stash the raw '*'/'/' char here too, checked twice at
;          runtime; TOK_CHARS/TOK_VECS give '*' and '/' separate entry
;          points -- MUL_ENTRY/DIV_ENTRY -- so the operator is encoded by
;          which one got jumped to, and DO_MD instead threads it through
;          as Y (0=multiply, 1=divide) across its shared sign-computation
;          body, which doesn't otherwise touch Y)
;   LP   : line-store scan pointer -- shared by EDITLN, GOTOL, DO_LIST,
;          LSKIP, DELINE, PE_CMP_LP, INSLINE; each call fully consumes LP
;          before any nested call that might also use it
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
; TO-DO: Finalize showcase once BASIC functionality stabilizes 
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
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or Kowalski JMP trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
;
;   clears all zero-page RAM, sets the stack, enables IRQs, initialises PE
;   to PROG (empty program store), prints the banner, then falls into MAIN.
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

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
;
;   In:  -- (entered by fall-through from INIT/DO_END, or JMP from EDITLN)
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

         JSR GETLINE_M        ; print "> "; read line

         JSR WPEEK            ; skip spaces; peek first non-space char into A
         CMP #CR
         BEQ MAIN             ; blank line: restart prompt
         SEC
         SBC #'0'             ; map '0'..'9' to 0..9; anything outside -> not a digit
         CMP #10
         BCS MAIN_DIR         ; >= 10: not a digit -- treat as direct statement
         JSR EDITLN           ; digit: store / delete numbered line
         BRA MAIN
MAIN_DIR:
         JSR STMT              ; execute as immediate statement
         BRA MAIN

; =============================================================================
; DO_LET  --  LET <var> = <expr>  or implicit  <var> = <expr>
;
;   In:  IP -> variable name (with optional leading spaces)
;   Out: variable assigned; IP advanced
;   Clobbers: A X T0 IP
;
; =============================================================================
DO_LET:
         JSR PARSE_VAR
         BCS DL_DN
         PHA
         JSR WPEEK
         CMP #'='
         BNE DL_POP           ; no '=': bad assignment
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
DL_DN:   
        RTS            

DL_POP:  PLA
        ; drop through
; =============================================================================
; DO_ERROR  --  Useless Error Stub
; =============================================================================
DO_ERR_UK:  ;LDA #ERR_UK ; Unknown Var
;DO_IN_DN:   LDA #ERR_SN ; Syntax Error
DO_ERR_UL:  ;LDA #ERR_UL ; Unknown Line 
DO_ERR_OV:  ;LDA #ERR_OV ; Overflow/Div0
DO_ERROR:
         ; Generic Error
         LDA #'!'
         JSR PUTCH            ; print "N"
         JSR PRNL             ; CR+LF after error message
         BRA MAIN

; =============================================================================
; PARSE_VAR  --  parse a single-letter variable name at IP
;
;   In:  IP -> variable name text (leading spaces are skipped)
;   Out: success: C=0, A = VARS offset (0,2,4..50 for A-Z), IP advanced past
;        the letter
;        failure (char not A-Z): C=1, IP unchanged
;   Clobbers: A
; =============================================================================
PARSE_VAR:
         JSR WPEEK       ; (3)
         JSR CHK_CHAR    ; Is it a char
         BCS DO_ERR_UL   ; (2) Nope 
         ASL             ; (1) double the index for VARS lookup
         JMP BUMP_IP     ; (3) increments IP, leaves Carry clear (C=0)

; =============================================================================
; DO_INPUT  --  INPUT <var>
;
;   In:  IP -> variable name in source
;   Out: named variable updated; IP restored to position after variable name
;   Clobbers: A X Y T0 T1 T2 IP
; =============================================================================
DO_INPUT:
         JSR PARSE_VAR         ; skip spaces; peek var name uppercased
	 BCS DO_ERR_UK
         PHA                  ; [S: var_offset]
         JSR GETLINE          ; Read user input; IP = IBUF
         JSR EXPR             ; evaluate expression -> T0
         BRA STORE_VAR         ; tail call: pop var_offset, store T0, RTS

; =============================================================================
; DO_GO  --  GOTO <linenum>
;
;   In:  IP -> line number digits
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: IP = body of target line; stack unwound to RUNSP; RUNGO
;   Clobbers: A X Y T0 IP SP CURLN  (CURLN via GOTOL on a successful lookup)
;
; =============================================================================
DO_GO:
         JSR EXPR             ; Parse target line number -> T0 (LP no longer needed)
         JSR GOTOL            ; find line: C=0 found, C=1 not found
         BCS DO_ERR_UL        ; Line not found error 
         LDX RUNSP
         TXS                  ; restore SP to pre-statement state
         BRA RUNGO            ; Always taken jump into run loop

; =============================================================================
; DO_RUN  --  RUN  :  execute program starting from the first line
;
;   In:  PE = current program end
;   Out: program executes; returns to MAIN on END/error/STOP
;   Clobbers: A X Y T0 T1 T2 IP SP RUN CURLN RUNSP
;
;   RUNLP: top of the per-line execution loop.  Saves SP so GOTO can unwind.
;   RUNGO: mid-loop entry used by GOTO (after IP is already set to body).
; =============================================================================
DO_RUN:
         LDX #0
         JSR PROG2X           ; PROG to IP
         SMB #0,RUN           ; set run flag (only bit0 is ever tested --
RUNLP:   LDA IP                ; IP == PE? (natural end of program --
         CMP PE                ; may not be a hard stop otherwise: e.g.
         BNE RL_GO             ; DELINE's compaction leaves old, well-
         LDA IP+1              ; formed data sitting past the new PE,
         CMP PE+1               ; which would otherwise look like one
         BEQ RUNEND             ; more real line to execute)
RL_GO:   TSX
         STX RUNSP            ; snapshot SP for GOTO / error recovery
         JSR GETCI            ; read line-number lo
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
; DO_NEW  --  NEW  :  Set default program store
; DO_END  --  END  :  halt program execution and return to immediate mode
; =============================================================================
DO_NEW:
         LDX #4
         JSR PROG2X            ; PE = PROG
DO_END:
RUNEND:  STZ RUN
EL_DN:
DL_DONE: RTS

; =============================================================================
; DELINE  --  remove the line at LP from the program store; adjust PE
;
;   In:  LP -> start of line to delete (the line-number lo byte)
;        PE -> one past the last program byte
;   Out: line removed; PE = new end of program
;        LP is PRESERVED (unlike the original routine -- callers no longer
;        need to save/restore it around this call)
;   Clobbers: A X Y T0 T1 PE
;
; =============================================================================
DELINE:
         LDY #2
DL_LL:   LDA (LP),Y
         INY
         CMP #CR
         BNE DL_LL            ; Y = length (this line's full size, incl.
                               ; header+CR) -- stays fixed as the loop's
                               ; constant source-ahead offset throughout
         LDX #LP-VARS
         JSR X_TO_T0           ; T0 = LP (single shifting pointer)
         STY T1                ; T1 = length (plain byte value, 0 hi --
         STZ T1+1              ; a line is always well under 256 bytes)
         PHY                   ; stash length -- ADD_X_Y is about to
                                ; repurpose Y as T1's address, not a value
         JSR NEG_T1            ; T1 = -length
         LDX #PE
         LDY #T1
         JSR ADD_X_Y           ; PE += T1 (= PE - length)
         PLY                   ; Y = length again: fixed read-ahead
                                ; offset for the whole loop below
         LDX #PE
         ; Top-tested loop: test BEFORE copying.
DL_CP:   JSR T0_CMPX           ; T0 == (new, already-shrunk) PE ?
         BEQ DL_DONE
         LDA (T0),Y            ; read the byte `length` ahead (source)
         STA (T0)              ; write to T0 itself (dest)
         ; Bump T0
         INC T0
         BNE DL_CP
         INC T0+1
         BRA DL_CP

; =============================================================================
; EDITLN  --  insert, replace, or delete a numbered line in the program store
; =============================================================================
EDITLN:
         JSR PNUM             ; parse line number -> T0; IP advances past digits
         JSR T0_TO_CURLN
         JSR PROG2LP
         BRA EL_FL            ; skip the LSKIP on first pass
EL_SKIP: JSR LSKIP            ; advance LP to next line (Z=1 on return)
EL_FL:   JSR PE_CMP_LP        ; is LP == PE? (reached end of store)
         BEQ EL_INS           ; yes: insert at end

         ; --- 16-BIT COMPARISON BLOCK ---
         LDY #1
         LDA (LP),Y           ; Compare high bytes first
         CMP CURLN+1
         BNE EL_CK_LO         ; If different, flags are ready for evaluation
         LDA (LP)             ; 
         CMP CURLN            ; Compare low bytes
         
EL_CK_LO:BCC EL_SKIP          ; stored line < target: keep scanning
         BNE EL_INS           ; stored line > target: insert before here (skip DELINE)
         JSR DELINE           ; exact match: delete existing (LP preserved)
EL_INS:  JSR WPEEK            ; skip spaces + peek (no consume) first body char
         CMP #CR
         BEQ EL_DN            ; CR only: delete-only
         ; fall through into INSLINE to insert the body

; =============================================================================
; INSLINE  --  insert one line at LP; body text comes from IP (in IBUF)
; NOTE - MINIMAL, no Out of memory/RAM checks
; =============================================================================
INSLINE:
         ; Calculate new line length and store in Y
         SEC
         LDA LLEN
         SBC IP               ; IP is ZP pointer, subtracts IP_LO
         CLC
         ADC #<IBUF+2         ; +2 for the 2-byte line number header
         TAY                  ; Y = Gap Length (Insertion size)

         ; Set T0 = Old PE
         LDX #PE-VARS
         JSR X_TO_T0

         ; New PE = old PE (still sitting in PE, untouched so far) + Y
         TYA
         CLC
         ADC PE
         STA PE
         BCC IN_NC             ; gap length's own hi byte is always 0 --
         INC PE+1              ; only a carry can reach PE+1
IN_NC:

         ; Check if we are inserting at the very end of the file
         JSR T0_CMP_LP          ; If old PE == LP, nothing to shift
         BEQ IN_HDR
         
         ; --- 65C02 ONE-POINTER SHIFT LOOP ---
IN_BK:   LDA T0               ; 16-bit pre-decrement source (T0)
         BNE IN_D0
         DEC T0+1
IN_D0:   DEC T0

         LDA (T0)             ; 65C02: Read from Source
         STA (T0),Y           ; 65C02: Write to Dest (Source + Gap Length)
         
         JSR T0_CMP_LP        ; Stop when T0 has shifted the byte at LP
         BNE IN_BK
         
         ; --- INSERTION ---
IN_HDR:  LDA CURLN            
         STA (LP)             ; write line number lo
         LDY #1
         LDA CURLN+1          
         STA (LP),Y           ; write line number hi
         JSR ADD2_LP          ; advance LP by 2 for the payload
         
         LDY #0
IN_CP:   LDA (IP),Y           ; copy payload from IBUF
         STA (LP),Y
         INY
         CMP #CR
         BNE IN_CP
LS_DONE:
         RTS

; =============================================================================
; DO_LIST  --  LIST  :  print all program lines in source form
;
;   In:  PE = current program end
;   Out: all lines printed as "<linenum> <body>"
;   Clobbers: A X Y T0 LP
; =============================================================================
DO_LIST:
         JSR PROG2LP
LS_LN:   JSR PE_CMP_LP           ; PE == LP
         BEQ LS_DONE          ; end of program: branches to shared RTS above
         LDY #1
         LDA (LP)             ; read line number lo
         STA T0
         LDA (LP),Y           ; read line number hi
         STA T0+1
         JSR PRT16            ; print line number
         JSR PRTSPACE
         JSR ADD2_LP
LS_BODY: LDA (LP)
         JSR BUMP_LP
         CMP #CR                ; A still has char
         BEQ LS_EOL
         JSR PUTCH
         BRA LS_BODY          ; always taken here (listing walks RAM pages, never wraps to $00)

LS_EOL:  JSR PRNL              ; print CR+LF at end of each listed line
         BRA LS_LN            ; always taken here


; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to body (past 2-byte header); CURLN = T0
;        C=1  not found -- IP = PE; CURLN unchanged
;   Clobbers: A Y IP LP CURLN
;
;   Scans using LP (shared PE_CMP_LP/LSKIP routines with EDITLN, which also
;   scan via LP); only converts to IP once, at the success point, since
;   that's the only place the documented output contract needs it. Safe:
;   GOTOL's only caller (DO_GO) explicitly doesn't need LP preserved across
;   this call ("LP no longer needed" once EXPR has parsed the target line).
; =============================================================================
GOTOL:
         JSR PROG2LP
GT_SC:   JSR PE_CMP_LP            ; test LP == PE (end of store)
         BEQ GT_FAIL           ; not found
         LDA (LP)              ; read line-number lo
         CMP T0                ; compare line-number lo
         BNE GT_NX
         LDY #1
         LDA (LP),Y
         CMP T0+1             ; compare line-number hi
         BEQ GT_OK
GT_NX:   JSR LSKIP             ; advance LP to next line (shared w/ EDITLN)
         BEQ GT_SC              ; LSKIP's only exit is via CMP #CR -- Z=1 guaranteed

GT_OK:   ; Copy T0 to CURLN
         JSR T0_TO_CURLN
         JSR ADD2_LP          ; LP += 2, past the 2-byte header
         CLC                  ; C=0: found
COPY_LP_IP:
         LDA LP               ; IP = LP (Carry flag passes through these unchanged)
         STA IP
         LDA LP+1
         STA IP+1
         RTS                  ; Exit with C=0 (from GT_OK) or C=1 (from GT_FAIL)

GT_FAIL: SEC                  ; C=1: not found
         BRA COPY_LP_IP

; =============================================================================
; EXPR  --  strictly left-to-right expression evaluator (no operator
;   precedence; use parentheses to group, e.g. "(A*A/64)-(B*B/64)+C" or
;   "256<((A*A/64)+(B*B/64))" -- see the showcase's Mandelbrot section for
;   real examples of exactly this).
;
;   Operators matched against TOK_CHARS's operator section (X counts up
;   from -1 -- see TOK_CHARS/TOK_VECS header). OP_HIT plays DO_OP's old
;   role: consumes the operator, stashes the left operand (T0) on the
;   hardware stack, parses the right operand via EXPR2 into T0, then pops
;   the left operand into T1 -- before falling into the DO_DISP trampoline
;   shared with MATCH_DISPATCH.
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================
E1_OVFL:  JMP DO_ERR_OV

; --- Relational: Equality ---
DO_EQ:   LDX #T1
         JSR T0_CMPX          ; equality is symmetric: T0 vs T1 == T1 vs T0
         BEQ REL_T
         BRA REL_F            ; always taken (Z=0 here)

; --- Relational: Less Than ---
DO_LT:   LDA T1
         CMP T0               ; Replaces SEC + SBC T0
         LDA T1+1
         SBC T0+1
         BVC NO_FLIP          ; N XOR V trick for signed comparison
         EOR #$80
NO_FLIP: BMI REL_T            ; If N=1, condition is true

REL_F:   LDA #0               ; False: Result = $0000
         .DB $2C              ; BIT abs trick: skips the next 2 bytes (LDA #$FF)
REL_T:   LDA #$FF             ; True:  Result = $FFFF
         STA T0
         STA T0+1
         BRA EXPR_LOOP

; --- Addition & Subtraction ---
DO_SUB:  JSR NEG16            ; negate right operand (T0), fall through to ADD
DO_ADD:  LDX #T0              ; Target X=0 (T0). Sets Z flag
         BRA DO_ADD_TAIL      ; Jumps straight into shared ADD logic      

; =============================================================================
; OP_HIT  --  operator match handler: consume operator, shuffle operands
;
;   In:  X = matched operator's index into TOK_CHARS/TOK_VECS (0..5);
;        IP -> the matched operator char (not yet consumed); T0 = left
;        operand (from EXPR2/a prior OP_HIT)
;   Out: T1 = left operand, T0 = right operand; falls through into DO_DISP
;   Clobbers: A X T0 T1 IP (T2/T3 via EXPR2)
; =============================================================================
OP_HIT:  JSR GETCI             ; consume the matched operator char
         PHX                   ; save matched index across EXPR2
         LDA T0+1              ; push left operand (T0) hi
         PHA
         LDA T0                ; push left operand (T0) lo
         PHA
         JSR EXPR2             ; parse the right operand -> T0
         PLA
         STA T1                ; pop left operand lo -> T1
         PLA
         STA T1+1              ; pop left operand hi -> T1+1
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
         JMP (TOK_VECS,X)
EXPR:
         JSR EXPR2            ; parse the first atom -> T0
EXPR_LOOP:
         JSR WPEEK            ; peek next char (not consumed)
         LDX #$FF             ; pre-decremented for INX
OP_SCAN: INX
         CMP TOK_CHARS,X
         BEQ OP_HIT           ; found a matching operator
         CPX #OP_COUNT-1
         BNE OP_SCAN
         RTS                  ; no operator matched: result in T0, exit cleanly

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
         LDA T1+1
         BPL E1_P1
         JSR NEG_T1           ; Make T1 positive
E1_P1:   LDA T0+1
         BPL E1_P2
         JSR NEG16            ; Make T0 positive
E1_P2:   STZ T2               ; Clear T2 (product/quotient accumulator)
         STZ T2+1
         TYA                   ; which operator? (Y set above, still intact)
         BNE DIV_LOOP

MUL_LOOP:
         LDX #T2               ; Target X=4 (T2)
         ;
         LDA T0               ; 16-bit decrement of T0 (multiplicand doubles as loop counter)
         BNE MLLP
         DEC T0+1
         BMI MD_DONE          ; Once T0+1 wraps from $00 to $FF, we're done
MLLP:    DEC T0
        ; --- SHARED INLINE ADDITION KERNEL ---
DO_ADD_TAIL:                  
         LDY #T1               ; Source Addend = T1 for ADD and MUL 
         JSR ADD_X_Y
         TXA                  ; 1-byte trick to check X
         BNE MUL_LOOP         ; If X=4, loop back to multiply
         BRA EXPR_LOOP        ; If X=0, addition is done 

DIV_LOOP:
        JSR NEG16            ; T0 = -T0 (negated divisor)
        LDY #T0               ; Source Addend = T0 (negated divisor)
DV_LP:
         LDX #T1               ; Dest = T1 (running dividend)
         JSR ADD_X_Y
         BCC MD_DONE          ; Stop once dividend < divisor
         ;
         INC T2               ; Quotient tally
         BNE DV_LP
         INC T2+1
         BNE DV_LP

MD_DONE: LDX #T2-VARS        ; Copy T2 to T0
         JSR X_TO_T0
         PLA                  ; Retrieve sign
         BPL E1_POS
         JSR NEG16            ; Apply sign
E1_POS:  BRA EXPR_LOOP         ; 

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
         ; drop through

; =============================================================================
; NEG_T1 / NEG16  --  two's-complement negate
; In:  T0 or T1 = value to negate. Selected dynamically by offset mapping.
; Clobbers: A X
; =============================================================================
NEG16:   LDX #T0              ; in place negate
         .DB $2C              ; BIT abs: skips next 2 bytes (the LDX #2)
NEG_T1:  LDX #T1
         SEC
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
;
;   Note: E2_BAD returns T0=0 for unrecognised atoms (no error raised).
; =============================================================================
E2_BAD:  JMP REL_F              ; return zero

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
         LDY #T0               ; Source
         STZ T0                ; clear result lo
         STZ T0+1              ; clear result hi
PN_LP:   LDA (IP)              ; peek without consuming
         EOR #'0'              ; [OPT] Maps '0'-'9' to 0-9. Anything else maps >= 10
         CMP #10               ; [OPT] Check bounds
         BCS PN_DN             ; If A >= 10, not a digit -- done

         STA T3                ; seed running sum lo with digit
         STZ T3+1               ; seed running sum hi with 0
         LDX #T3               ; Destination T3:T3+1 = digit + 10*T0, via ADD_X_Y (X=T3
                                ; dest, Y=0/T0 addend -- both fixed all loop,
                                ; ADD_X_Y clobbers neither)
         LDA #10
         STA T1                ; loop counter (T1 free here: PNUM only runs
                                ; while parsing an atom, before OP_HIT stashes
                                ; anything there -- see OP_HIT's stack save)
PN_ML:
         JSR ADD_X_Y
         DEC T1
         BNE PN_ML
         ; Copy T3:T3+1 to T0
         LDX #T3-VARS         ; Copy T3 to T0
         JSR X_TO_T0
         JSR GETCI             ; consume digit, advances IP 16-bit
         BRA PN_LP              ; guaranteed to branch since A != 0

; --------------------------------------------
E2_VAR:  JSR PARSE_VAR               ; variable name (single letter A-Z)?
	 BCS E2_BAD
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
         JSR EXPR             ; evaluate sub-expression
         JSR WSKIP            ; skip spaces, then fall through
         ; fall through to consume ')'
; =============================================================================
; GETCI  --  fetch char at IP and advance IP
;
;   In:  IP -> char to fetch
;   Out: A = char; IP incremented (16-bit)
;   Clobbers: A Y IP
; =============================================================================
GETCI:   LDA (IP)
BUMP_IP:         
         INC IP               ; 16-bit increment
         BNE GETCI_SK
         INC IP+1
DO_IF_F:
GETCI_SK: RTS
         
; =============================================================================
; DO_IF  --  IF <expr> THEN <stmt>  (THEN keyword is optional)
;
;   In:  IP -> expression text
;   Out: if true, statement executed; if false, returns (STMT will SKIPEOL)
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Falls straight through into STMT to execute the consequent (no THEN).
;   On false: branches to nearest preceding RTS (DO_IF_F = GETCI_SK).
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
;   Clobbers: A X Y T0 T1 T2 IP
;
; =============================================================================
STMT:
         JSR WPEEK
         CMP #' '             ; anything below space (CR, NUL) means empty line
         BCC GETCI_SK         ; return via nearest preceding RTS
        ; drop through
; =============================================================================
; MATCH_DISPATCH -- statement parser: 1-char keyword lookup vs. implicit LET
;
;   Checks akeyword from a single-letter variable by peeking 2nd character: 
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
         JSR CHK_CHAR
         BCS DO_LET_IDX        ; not a letter: implicit LET (1-char var)
         LDA (IP)              ; 1st char (not yet consumed)
         LDX #OP_COUNT-1       ; pre-decremented for INX; skips operator chars
MD_LP:   INX
         CMP TOK_CHARS,X
         BEQ SKIP_KW           ; matched statement's 1st char
         CPX #MAX_TOK-1
         BNE MD_LP             ; loop until the last statement is checked
DO_LET_IDX:
        JMP DO_LET

SK_CONT: JSR GETCI
SKIP_KW: LDA (IP)              ; consume the keyword's letters (starting
         JSR CHK_CHAR
         BCC SK_CONT           ; still a letter: keep skipping
         JMP DO_DISP           ; not a letter: done skipping, dispatch

; =============================================================================
; PRT16  --  print T0 as a signed decimal integer
;
;   In:  T0 = signed 16-bit value
;   Out: decimal digits printed to terminal; T0 destroyed
;   Clobbers: A Y T0
; =============================================================================
PRT16:
         LDA T0+1
         BPL PRT16GO          ; positive: skip sign handling
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
;   Clobbers: --  (flags may change)
; =============================================================================
PUTCH:   STA IO_OUT
DP_RET:
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
;   Clobbers: A X Y T0 T1 T2 IP
; =============================================================================
DO_WR:   JSR EXPR             ; evaluate <expr> -> T0
         LDA T0
         BRA PUTCH            ; tail call: PUTCH's own RTS returns to caller

; =============================================================================
; GETLINE  --  MINIMAL read one line from the terminal into IBUF; set IP = IBUF
;
;   Entry points sharing one body:
;     GETLINE_M  prints "> " (immediate-mode prompt)
;     GETLINE    no prompt
;
;   In:  --
;   Out: IBUF filled with input, CR-terminated; X is # chars; LLEN is # chars
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
         STX LLEN       ; save Line Len for whoever wants it 
        ; drop through
; =============================================================================
; DO_PRINT  --  PRINT [item [; item] ...]
;
;   In:  IP -> first character after "PRINT" keyword
;   Out: output written to terminal; IP advanced past statement
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Items: string literals ("..."), or numeric expressions.
;   Items separated by ';' suppress the inter-item space.
;   A trailing ';' suppresses the final CR/LF.
;   At end of items (or with no items) falls through into PUTSTR to emit CR/LF.
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
         BRA DP_STR           ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional

DP_NORM: JSR EXPR             ; numeric expression
         JSR PRT16
DP_AFT:  JSR WPEEK
         CMP #';'
         BNE DP_NL
         JSR GETCI            ; consume ';'
         JSR WPEEK
         CMP #CR+1            ; NUL(0) and CR(13) are both < CR+1 -- one check
         BCC DP_RET           ; trailing ';': suppress CR/LF (DP_RET = IN_DN = RTS above)
         BRA DP_TOP            ; always taken (just proved carry set, i.e. A >= CR+1)

; =============================================================================
; HELPERS - All Helpers go at end as JSR not BRA/JMP - until they are...
; =============================================================================
; ADD_X_Y  --  (T0,X) += (T0,Y), 16-bit
;   In:  X = dest offset (0=T0, 4=T2); Y = addend offset (0=T0, 2=T1)
;   Out: (T0,X) = (T0,X) + (T0,Y); carry = result of high-byte ADC
;   Clobbers: A
; =============================================================================
ADD_X_Y:
         LDA 0,X             ; If X=0, this is T0. If X=4, this is T2.
ADD_A_X_Y:
         CLC
         ADC 0,Y              ; Y picks the addend: T1 for ADD/MUL, T0 for DIV
         STA 0,X
         LDA 1,X
         ADC 1,Y
         STA 1,X
         RTS

; =============================================================================
; CHK_CHAR - Carry set if its a letter
;   In:  A = Letter to check
;   Out: carry = set if a letter
;   Clobbers: Flags
; =============================================================================
CHK_CHAR:
         SEC                   ; with the matched-but-not-yet-consumed 1st)
         SBC #'A'
         CMP #26
         RTS

; =============================================================================
; WSKIP / WPEEK  --  skip spaces; return first non-space in A
;
;   In:  IP -> text (may start with spaces)
;   Out: A = first non-space char; IP advanced past any leading spaces
;        (char is NOT consumed -- IP still points to it)
;   Clobbers: A Y  (Y via GETCI when a space is skipped)
;
;   Two labels for the same entry point (names document caller intent):
;     WSKIP     -- skip side-effect is desired
;     WPEEK     -- intent is to inspect without consuming
; =============================================================================
WSKIP:
WPEEK:   LDA (IP)
         CMP #' '
         BNE WP_RTS            ; non-space: return
         JSR GETCI            ; consume space and loop
         BRA WSKIP            ; always taken (' ' = $20, nonzero)

; =============================================================================
; ADD2_LP  --  LP += 2 (shared by INSLINE and DO_LIST, skip a 2-byte header)
;
;   In:  LP
;   Out: LP advanced by 2
;   Clobbers: LP  (the documented Out: change; no registers touched)
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: INC LP
         BNE *+4
         INC LP+1
WP_RTS:
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
; PE_CMP_LP  --  compare LP against PE (shared by EDITLN, GOTOL, DO_LIST/FETCH)
;
;   In:  LP
;   Out: Z=1 if LP == PE, Z=0 otherwise
;   Clobbers: A
; =============================================================================
PE_CMP_LP:  
         LDA LP
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
LSK_LP:  LDA (LP)       ; Read current character
         JSR BUMP_LP    ; Advance LP to the next memory address
         CMP #CR        ; BUMP LP does not touch A - was it a ?
         BNE LSK_LP     ; No? Loop back and check the next byte
         RTS            ; Done, LP points to the next line

; =============================================================================
; T0_CMPX  --  compare T0 against a 16-bit zero-page pair selected by X
;
;   In:  T0; X = zero-page address of the pair to compare against
;   Out: Z=1 if T0 == (X,X+1), Z=0 otherwise
;   Clobbers: A
; =============================================================================
T0_CMP_LP:
         LDX #LP
T0_CMPX:
         LDA T0
         CMP 0,X
         BNE TCX_NE
         LDA T0+1
         CMP 1,X
TCX_NE:  RTS

ROMEND: ; for auditing

; =============================================================================
; Reset / IRQ / NMI vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT         ; $FFFC: reset vector
         .DW INIT      ; $FFFE: IRQ vector   (No IRQ)
