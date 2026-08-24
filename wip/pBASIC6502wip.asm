; =============================================================================
; PicoBASIC6502 v0.3  --  1 KB Tiny BASIC for NMOS 6502 
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Note: Kowalski Memory Mapped IO for now.
KOWALSKI        = 1
;
;   CPU    : NMOS 6502 @ 1 MHz
;   ROM    : 2758 EPROM  2 KB  $F800-$FFFF (interpreter targets <=1 KB of this)
;   RAM    : 2x2114 SRAM 1 KB  $0000-$03FF
;   I/O    : Kowalski emulation 0xE001 PUTCH, 0xE004 Getch
;   NMI/IRQ: Not used
;
; RAM layout for 1 KB target:
;   $0000-$007F  zero-page (IP/CURLN/PE/LP/T0-T3/RUN/IBUF/VARS/RUNSP);
;                ZPEND=$7F, fits the $80-$FF/$180-$1FF hardware-stack RAM
;                alias constraint. No GOSUB stack -- GOSUB isn't implemented.
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full or 2-letter prefix):
;   INPUT  END  GOTO  IF..THEN  PRINT      
;   LIST  NEW  RUN
;
; Arithmetic: + - * /  (unary -) Left to Right Precidence 
; Relops: =  <
;
; Numbers : signed 16-bit  (-32768 .. 32767)
; Print   : "literals", `;`, CHR$(char) - no string vars
;
; KNOWN LIMITATIONS
;
; GETLINE - no Backspace support or range limits - too many characters will crash
;
; DO_ERROR - minimal error stub, shows error number, no line
;
; No operator precedence: all six operators (+,-,*,/,=,<) evaluate left to right,
;   same tier. Use parentheses to group, e.g. "A*A/64-B*B/64+C" must be written
;   "(A*A/64)-(B*B/64)+C" for standard-math meaning; "1+2*3" evaluates
;   as (1+2)*3=9, not 7. A pure same-operator chain (all */ or all +-,
;   e.g. "2*A*B/64") needs no parens -- left-to-right already matches
;   the usual meaning there.
;
; Relops: Only "<" and "=" are supported - use flipped operands for ">", e.g.
;   "A>B" as "B<A".  Hence ">=", "<=", "<>" not supported.
;
; Two Character keyword matching - only 2 chars matched then rest of the word
;   is consumed until a space or `(`.  Spaces are needed: `10 PRINT CHR$(65);"Hello"`
;   works, `10 PR CH(65);"Hello"` also works, but `10 PRINTCHR$(65);"Hello"` prints
;   "65Hello", not `AHello`.
;
; Char Case: All commands must be UPPERCASE apart from PRINt string literals
;
; No `:` multi-statement separator, no FOR/NEXT, no arrays/DIM, no string
;   variables -- see the above list above for the full set.
;
; Numbers are signed 16-bit only (-32768..32767); arithmetic overflow
;   wraps silently (e.g. 32767+1 = -32768) -- it does not raise an error.
;
; Input buffer is 35 usable chars + CR terminator
;
; CHR$(n) only valid only in PRINT line 
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
; ---- assembler mode ---------------------------------------------------------
         .opt proc6502

; ---- Kowalski Emulated IO ---------------------------------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)

; Interpreter Defines
ORIGIN   = $F800
RAM_TOP  = $0400             ; Assume 1k SRAM (1 KB: 2x 2114)
HWSTACK  = $7f               ; Give more space to PROG
PROG     = $101 + HWSTACK    ; Prog Start above Stack 
IBUF_MAX = 36                ; highest valid index into IBUF
CR       = $0D               ; ASCII carriage return
LF       = $0A               ; ASCII line feed
BS       = $08               ; ASCII backspace
BELL     = $07               ; ASCII bell -- GETLINE buffer-full feedback

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
        
; Note IP and CURLN must be sequential for GOSUB/RETURN stack push
T2:         .RS 2              ; 16-bit: tertiary scratch word / STMT jump target
T3:         .RS 1              ; 8-bit:  PNUM x10-multiply scratch hi, RXCHAR/TXCHAR
IP:         .RS 2              ; 16-bit: interpreter pointer
CURLN:      .RS 2              ; 16-bit: currently-executing line number
PE:         .RS 2              ; 16-bit: program end (one past last byte)
LP:         .RS 2              ; 16-bit: line pointer / multi-purpose scratch
RUN:        .RS 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
RUNSP:      .RS 1              ; 8-bit:  stack-pointer snapshot for GOTO/BREAK unwind
VARS:       .RS 52             ; 52-byte variable store (A-Z, 2 bytes each)
IBUF:       .RS IBUF_MAX+1     ; Input line buffer 
ZPEND:		; audit
; ---- Zero-page lifetime notes -----------------------------------------
; T3 serve two unrelated purposes at different times; safe only
; because this is a single-threaded interpreter with no reentrancy between
; the two uses of either byte. If that ever changes (e.g. an IRQ-driven
; path that touches these), re-check these pairings.
;   T0   : primary scratch / expression result -- live during nearly any
;          statement or expression evaluation; the most heavily reused byte
;   T1   : secondary scratch -- DO_OP's left-operand stash (all six
;          operator handlers read it), also the MUL/DIV kernel's
;          dividend/multiplicand working value
;   T2   : tertiary scratch -- PUTSTR/PRNL's string pointer; historically
;          also a STMT jump target (no longer true after the RTS-trick
;          dispatch rewrite -- MATCH_DISPATCH doesn't touch T2 at all now)
;   T3   : (a) PNUM's x10-multiply scratch, live only during decimal
;          parsing/printing; (b) bitbang GETCH/PUTCH's RXCHAR/TXCHAR shift
;          register, live only during serial I/O; (c) DO_MD's raw
;          operator char ('*' vs '/'), live only after DO_OP's recursive
;          right-operand evaluation has fully returned -- the operator
;          itself is held on the hardware stack (as its UNI_TAB table
;          offset, not the raw char) during that recursive call, which is
;          what fixes v1.10's "2*(10/5)" nested-parens bug (a fixed ZP
;          byte there got clobbered by the inner re-entry through
;          EXPR2/EXPR/EXPR_LOOP/DO_OP for the parenthesized sub-expr).
;          Never concurrent with (a)/(b): no PNUM or serial I/O call
;          happens between DO_OP popping the operator and DO_MD's last
;          use of T3.
;   LP   : line-store scan pointer -- shared by EDITLN, GOTOL, DO_LIST,
;          LSKIP, DELINE, PE_CMP, INSLINE; each call fully consumes LP
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
         .DB $1E,$00,"PRINT ",$22,"--- PRINT / CHR$ ---",$22,CR ; 30 PRINT "--- PRINT / CHR$ ---"
         .DB $28,$00,"PRINT CHR$(65)",$3B,"CHR$(66)",$3B,"CHR$(67)",CR ; 40 PRINT CHR$(65);CHR$(66);CHR$(67)
         .DB $32,$00,"PRINT ",$22,"--- ARITHMETIC ---",$22,CR ; 50 PRINT "--- ARITHMETIC ---"
         .DB $3C,$00,"PRINT ",$22,"3+4=",$22,$3B,"3+4",$3B,$22,"  10-3=",$22,$3B,"10-3",$3B,$22,"  6*7=",$22,$3B,"6*7",CR ; 60 PRINT "3+4=";3+4;"  10-3=";10-3;"  6*7=";6*7
         .DB $46,$00,"PRINT ",$22,"20/4=",$22,$3B,"20/4",CR ; 70 PRINT "20/4=";20/4
         .DB $50,$00,"PRINT ",$22,"--- COMPARISONS ---",$22,CR ; 80 PRINT "--- COMPARISONS ---"
         .DB $64,$00,"IF 3<5 THEN PRINT ",$22,"3<5 ok",$22,CR ; 100 IF 3<5 THEN PRINT "3<5 ok"
         .DB $82,$00,"IF 3=3 THEN PRINT ",$22,"3=3 ok",$22,CR ; 130 IF 3=3 THEN PRINT "3=3 ok"
         .DB $FA,$00,"PRINT ",$22,"--- LOOP via GOTO ---",$22,CR ; 250 PRINT "--- LOOP via GOTO ---"
         .DB $04,$01,"I=1",CR                               ; 260 I=1
         .DB $0E,$01,"IF 5<I THEN GOTO 310",CR              ; 270 IF 5<I THEN GOTO 310
         .DB $18,$01,"PRINT I",$3B,CR                       ; 280 PRINT I;
         .DB $22,$01,"I=I+1",CR                             ; 290 I=I+1
         .DB $2C,$01,"GOTO 270",CR                          ; 300 GOTO 270
         .DB $36,$01,"PRINT ",$22,$22,CR                    ; 310 PRINT ""
         .DB $40,$01,"PRINT ",$22,"--- NESTED LOOP ---",$22,CR ; 320 PRINT "--- NESTED LOOP ---"
         .DB $4A,$01,"I=1",CR                               ; 330 I=1
         .DB $54,$01,"IF 3<I THEN GOTO 610",CR              ; 340 IF 3<I THEN GOTO 610
         .DB $5E,$01,"J=1",CR                               ; 350 J=1
         .DB $68,$01,"IF 3<J THEN GOTO 400",CR              ; 360 IF 3<J THEN GOTO 400
         .DB $72,$01,"PRINT J",$3B,CR                       ; 370 PRINT J;
         .DB $7C,$01,"J=J+1",CR                             ; 380 J=J+1
         .DB $86,$01,"GOTO 360",CR                          ; 390 GOTO 360
         .DB $90,$01,"PRINT ",$22,$22,CR                    ; 400 PRINT ""
         .DB $9A,$01,"I=I+1",CR                             ; 410 I=I+1
         .DB $A4,$01,"GOTO 340",CR                          ; 420 GOTO 340
         .DB $62,$02,"PRINT ",$22,"--- MANDELBROT ---",$22,CR ; 610 PRINT "--- MANDELBROT ---"
         .DB $6C,$02,"I=-64",CR                             ; 620 I=-64
         .DB $76,$02,"IF 56<I THEN GOTO 860",CR             ; 630 IF 56<I THEN GOTO 860
         .DB $80,$02,"D=I",CR                               ; 640 D=I
         .DB $8A,$02,"C=-120",CR                            ; 650 C=-120
         .DB $94,$02,"IF 4<C THEN GOTO 830",CR              ; 660 IF 4<C THEN GOTO 830
         .DB $9E,$02,"A=C",CR                               ; 670 A=C
         .DB $A8,$02,"B=D",CR                               ; 680 B=D
         .DB $B2,$02,"E=0",CR                               ; 690 E=0
         .DB $BC,$02,"N=1",CR                               ; 700 N=1
         .DB $C6,$02,"IF 16<N THEN GOTO 790",CR             ; 710 IF 16<N THEN GOTO 790
         .DB $D0,$02,"IF 0<E THEN GOTO 770",CR              ; 720 IF 0<E THEN GOTO 770
         .DB $DA,$02,"T=(A*A/64)-(B*B/64)+C",CR             ; 730 T=(A*A/64)-(B*B/64)+C
         .DB $E4,$02,"B=2*A*B/64+D",CR                      ; 740 B=2*A*B/64+D
         .DB $EE,$02,"A=T",CR                               ; 750 A=T
         .DB $F8,$02,"IF 256<((A*A/64)+(B*B/64)) THEN IF E=0 THEN E=N",CR ; 760 IF 256<((A*A/64)+(B*B/64)) THEN IF E=0 THEN E=N
         .DB $02,$03,"N=N+1",CR                             ; 770 N=N+1
         .DB $0C,$03,"IF N<17 THEN GOTO 710",CR             ; 780 IF N<17 THEN GOTO 710 (N<=16, integer-exact)
         .DB $16,$03,"IF 0<E THEN PRINT CHR$(E+32)",$3B,CR  ; 790 IF 0<E THEN PRINT CHR$(E+32);
         .DB $20,$03,"IF E=0 THEN PRINT CHR$(32)",$3B,CR    ; 800 IF E=0 THEN PRINT CHR$(32);
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
; STRING TABLE 
;

; ---- human-readable strings -------------------------------------------------
STR_BANNER: .DB "pBASIC v0.1",0  ; startup banner

; =============================================================================
; UNI_TAB -- unified operator + statement dispatch table.
;
;   Operator section (offsets 0-17, stride 3: 1 raw char, (handler-1)_lo,
;   (handler-1)_hi), 6 entries. Scanned by EXPR_LOOP/OP_SCAN (X counts down
;   by 3 from 15). '*' and '/' share one handler (DO_MD), which
;   distinguishes them itself.
;
;   KW_TAB (statement section, offsets 18+, stride 4: 2 raw ASCII keyword
;   chars, (handler-1)_lo, (handler-1)_hi), terminated by a 3-byte $FF
;   sentinel ($FF, (resume-1)_lo, (resume-1)_hi) that resumes at DO_LET
;   (implicit "X=..." assignment). Scanned by MATCH_DISPATCH (X counts up
;   by 4 from KW_TAB-UNI_TAB).
;
;   Addresses are stored as (target-1), not target: both scanners push
;   them hi/lo and RTS -- DO_OP tail-calls into MATCH_DISPATCH's own
;   MD_FAIL for this (see EXPR's header), so there is exactly one copy of
;   that push/RTS gadget shared by all three cases (operator match,
;   statement match, statement sentinel).
;   All 2-char statement prefixes are unique, and distinct from every
;   operator's 1 char. KW_THEN/KW_CHRS below are matched the same way
;   (via a standalone JSR MTCHKW, X = <label>-UNI_TAB) but aren't part of
;   either scan loop -- see MATCH_DISPATCH/MTCHKW for the mechanics.
;
; =============================================================================
UNI_TAB:
; -- operator table --
          .DB "-"
          .DW DO_SUB-1
          .DB "+"
          .DW DO_ADD-1
          .DB "/"
          .DW DO_MD-1
          .DB "*"
          .DW DO_MD-1
          .DB "="
          .DW DO_EQ-1
          .DB "<"
          .DW DO_LT-1
KW_TAB:
; -- statement table --
KW_PRINT: .DB "PR"
          .DW DO_PRINT-1
KW_IF:    .DB "IF"
          .DW DO_IF-1
KW_GO:    .DB "GO"
          .DW DO_GO-1
KW_LIST:  .DB "LI"
          .DW DO_LIST-1
KW_RUN:   .DB "RU"
          .DW DO_RUN-1
KW_NEW:   .DB "NE"
          .DW DO_NEW-1
KW_INPUT: .DB "IN"      
          .DW DO_INPUT-1
KW_END:   .DB "EN"
          .DW DO_END-1
          .DB $FF               ; sentinel: no-match -> DO_LET
          .DW DO_LET-1

; ---- Special one-off keywords: NOT part of the dispatch walk above; matched
; directly via a standalone JSR MTCHKW with X = <label>-UNI_TAB (must stay
; within 256 bytes of UNI_TAB -- true here by a wide margin).
KW_THEN:  .DB "TH"
KW_CHRS:  .DB "CH"

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

         JSR DO_NEW           ; setup PE and PROG

         ; --- Setup showcase  
         LDA #<SHOWCASE_END   ; point PE at end of pre-loaded showcase program
         STA PE               ; Replace with `JSR DO_NEW` for clean program (ROM)
         LDA #>SHOWCASE_END
         STA PE+1

         LDA #<STR_BANNER   ; point PE at end of pre-loaded showcase program
         STA IP               ; Replace with `JSR DO_NEW` for clean program (ROM)
         LDA #>STR_BANNER
         STA IP+1
         JSR DP_STR
         ; fall through into MAIN

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
         TXS                  ; set stack to top of page 1
         JSR DO_END             ; Sets A to zero

         ; Initialize IP pointer to point to IBUF
         STA IP+1            ; (2) >IBUF 0 as ZP
         LDA #IBUF           ; (2)
         STA IP              ; (2)

         JSR GETLINE_M        ; print "> "; read line; set IP = IBUF

         JSR WPEEK            ; skip spaces; peek first non-space char into A
         CMP #CR
         BEQ MAIN             ; blank line: restart prompt
         SEC
         SBC #'0'             ; map '0'..'9' to 0..9; anything outside -> not a digit
         CMP #10
         BCS MAIN_DIR         ; >= 10: not a digit -- treat as direct statement
         JSR EDITLN           ; digit: store / delete numbered line
         JMP MAIN
MAIN_DIR:
         JSR STMT              ; execute as immediate statement
         JMP MAIN

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
         SEC             ; (1)
         SBC #'A'        ; (2) map 'A'-'Z' to 0-25
         CMP #26         ; (2) sets Carry if out of bounds
         BCS PV_FAIL     ; (2) 
         ASL             ; (1) double the index for VARS lookup
         JMP BUMP_IP     ; (3) increments IP, leaves Carry clear (C=0)
PV_FAIL:
DO_IN_DN: RTS            ; (1) Carry is naturally 1 here from CMP

; =============================================================================
; DO_INPUT  --  INPUT <var>
;
;   In:  IP -> variable name in source
;   Out: named variable updated; IP restored to position after variable name
;   Clobbers: A X Y T0 T1 T2 IP
; =============================================================================
DO_INPUT:
         JSR PARSE_VAR         ; skip spaces; peek var name uppercased
	 BCS DO_IN_DN
         PHA                  ; [S: var_offset]
         JSR GETLINE          ; Read user input; IP = IBUF
         JSR EXPR             ; evaluate expression -> T0
         JMP STORE_VAR         ; tail call: pop var_offset, store T0, RTS

; =============================================================================
; DELINE  --  remove the line at LP from the program store; adjust PE
;
;   In:  LP -> start of line to delete (the line-number lo byte)
;        PE -> one past the last program byte
;   Out: line removed; PE = new end of program
;        LP is PRESERVED (unlike the original routine -- callers no longer
;        need to save/restore it around this call)
;   Clobbers: A Y T0 T1 PE
;
; =============================================================================
DELINE:
         LDY #2
DL_LL:   LDA (LP),Y           ; scan body + CR
         INY
         CMP #CR
         BNE DL_LL            ; Y now = length of line
         TYA
         ;
        ; A = length (upon entry)
         CLC
         ADC LP
         STA T0       ; T0(lo) = LP(lo) + length. Carry is set if page boundary crossed.        
         LDA LP+1
         STA T1+1     ; T1(hi) = LP(hi). (Carry flag survives these instructions untouched)
         ADC #0       
         STA T0+1     ; T0(hi) = LP(hi) + Carry.         
         LDA LP
         STA T1       ; T1(lo) = LP(lo).
         ;
DL_CP:   JSR T0_CMP_LP  ; check if we reached PE
         BEQ DL_UPD           ; T0 == PE: nothing more to copy
DL_DO:   LDY #0
         LDA (T0),Y           ; forward copy: (T0) -> (T1)
         STA (T1),Y
         ; Bump T0
         INC T0               ; advance source
         BNE DL_NX
         INC T0+1
         ; Bump T1
DL_NX:   INC T1                ; advance destination
         BNE DL_CP
         INC T1+1
         BNE DL_CP            ; unconditional loop back
        ; T1 to PE
DL_UPD:  LDA T1               ; T1 naturally rests exactly at the new PE
         STA PE
         LDA T1+1
         STA PE+1
EL_DN:
         RTS

; =============================================================================
; EDITLN  --  insert, replace, or delete a numbered line in the program store
;
;   In:  IP -> line-number digits in IBUF (spaces already skipped by MAIN)
;   Out: program store updated; IP, LP, PE adjusted
;   Clobbers: A X Y T0 T1 T2 IP LP PE CURLN
;   Falls through into INSLINE when there is a body to insert.
;
; =============================================================================
EDITLN:
         JSR PNUM             ; parse line number -> T0; IP advances past digits
         ; T0 to CURLN
         LDA T0
         STA CURLN
         LDA T0+1
         STA CURLN+1
         ;
         JSR PROG2LP
EL_FL:   JSR PE_CMP           ; is LP == PE? (reached end of store)
         BEQ EL_INS           ; yes: insert at end

         LDY #1
         LDA (LP),Y           
         CMP CURLN+1
         BNE EL_CK_LO
         DEY
         LDA (LP),Y
         CMP CURLN
EL_CK_LO:BCC EL_SKIP          ; stored line < target: keep scanning
         BEQ EL_FND           ; exact match: delete existing then (re)insert
         BNE EL_INS           ; stored line > target: insert before here (always taken)

EL_SKIP: JSR LSKIP            ; advance LP to next line (shared w/ GOTOL)
         BEQ EL_FL            ; Z=1 guaranteed by LSKIP's internal CMP #CR

EL_FND:  JSR DELINE           ; LP is now preserved, no PHA/PLA needed
         ; falls through into EL_INS to write the replacement

EL_INS:  JSR WPEEK            ; skip spaces + peek (no consume) first body char
         CMP #CR
         BEQ EL_DN            ; CR only: delete-only (no body to insert)
         ; fall through into INSLINE to insert the body

; =============================================================================
; INSLINE  --  insert one line at LP; body text comes from IP (in IBUF)
;
;   In:  LP -> insertion point in program store
;        IP -> first byte of body text in IBUF (after the line number)
;        CURLN = 16-bit line number to store in the 2-byte header
;        PE -> one past the last current program byte
;   Out: new line written; PE advanced by line size
;   Clobbers: A Y T0 T1 IP LP PE
;
; =============================================================================
INSLINE:
         LDY #0
IN_CNT:  LDA (IP),Y           ; find body length
         INY
         CMP #CR
         BNE IN_CNT
         INY                  ; +2 for the 2-byte line number header
         INY
         TYA                  ; Y = total line size
        ; T1 = PE + Akku
         CLC
         ADC PE               ; calculate new PE = PE + total size
         STA T1
         LDA PE+1
         ADC #0
         STA T1+1
         ;
         CMP #>RAM_TOP        ; would we cross RAM_TOP?
         BCC IN_OK
         LDA #ERR_OM
         JMP DO_ERROR

         ; PE to T0
IN_OK:   LDA PE               ; T0 = old PE
         STA T0
         LDA PE+1
         STA T0+1
         ; T1 to PE
         JSR DL_UPD
         LDY #0
         JSR T0_CMP_LP        ; if old PE == LP, nothing to shift upward
         BEQ IN_HDR
        ; dec T0
IN_BK:   LDA T0               ; pre-decrement source (T0)
         BNE IN_D0
         DEC T0+1
IN_D0:   DEC T0
         ; Dec T1
         LDA T1               ; pre-decrement destination (T1)
         BNE IN_D1
         DEC T1+1
IN_D1:   DEC T1
        ;
         LDA (T0),Y           ; backward copy loop
         STA (T1),Y
         JSR T0_CMP_LP        ; stop exactly when T0 == LP
         BNE IN_BK
IN_HDR:  LDA CURLN            ; write line number lo
         STA (LP),Y           ; Y is 0 here
         INY
         LDA CURLN+1          ; write line number hi
         STA (LP),Y
         JSR ADD2_LP          ; advance LP by 2 for the payload
         LDY #0
IN_CP:   LDA (IP),Y           ; copy payload from IBUF
         STA (LP),Y
         CMP #CR
         BEQ DL_DN
         INY
         BNE IN_CP            ; always taken for bounded line lengths (<256)
DL_DN:   RTS

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
         PLA            ; restore offset
         TAX
         LDA T0
         STA VARS,X
         LDA T0+1
         STA VARS+1,X
         RTS
DL_POP:  PLA
         LDA #ERR_UK
        .DB $2c
        ; drop through
; =============================================================================
; DO_ERROR  --  Minimal Error Stub - Prints Error number
; =============================================================================
DO_ERR_UL:  
         LDA #ERR_UL          ; 
DO_ERROR:
         JSR PUTCH            ; print "N"
         JSR PRNL             ; CR+LF after error message
         JMP MAIN
         
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
         BCS DO_ERR_UL        ; Branch on Carry Set to shared error exit
         LDX RUNSP
         TXS                  ; restore SP to pre-statement state
         BNE RUNGO            ; Always taken jump into run loop

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
         DEX            
         STX RUN              ; set run flag ($FF = running)
RUNLP:   TSX
         STX RUNSP            ; snapshot SP for GOTO / error recovery
         ; IP 
         LDA IP               ; test IP >= PE (16-bit unsigned)
         CMP PE
         LDA IP+1
         SBC PE+1
         BCS RUNEND           ; IP >= PE: end of program
         JSR GETCI            ; read line-number lo
         STA CURLN
         JSR GETCI            ; read line-number hi
         STA CURLN+1
RUNGO:   JSR STMT               ; execute the statement on this line
         LDA RUN
         BEQ RUNEND           ; RUN cleared by END/error -- stop
SK_LP:   JSR GETCI            ; advance IP past CR (SKIPEOL inlined)
         CMP #CR
         BNE SK_LP
 	 BEQ RUNLP		; always taken

; =============================================================================
; DO_NEW  --  NEW  :  clear program store and all variables
;
;   In:  --
;   Out: PE = PROG; Zero Page cleared, gosub stack reset   
;   Clobbers: A X PE Zero Page(e.g. VARS)
; =============================================================================
DO_NEW:
         LDA #0
         TAX
INIT_Z:  STA 0,X              ; clear zero-page byte at X
         DEX
         BNE INIT_Z

         LDX #4
         JSR PROG2X            ; PE = PROG

         ; drop through - harmless but saves a RET
; =============================================================================
; DO_END  --  END  :  halt program execution and return to immediate mode
;
;   In:  --
;   Out: RUN = 0; returns to STMT -> RUNLP which exits to MAIN
;   Clobbers: A RUN
;
;   DO_END is the STMT dispatch handler.  RUNEND is the internal label reached
;   when the program runs off the end of the store, or when RUN is cleared by
;   another path.  Both converge here: LDA #0 / STA RUN then RTS.
; =============================================================================
DO_END:
RUNEND:  LDA #0
         STA RUN
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
LS_LN:   JSR PE_CMP           ; PE == LP
         BEQ LS_DONE          ; end of program: branches to shared RTS above
LS_GO:   LDY #0
         LDA (LP),Y           ; read line number lo
         STA T0
         INY                  ; Y=1
         LDA (LP),Y           ; read line number hi
         STA T0+1
         JSR PRT16            ; print line number
         JSR PRTSPACE
         JSR ADD2_LP
LS_BODY: LDY #0
         JSR PE_CMP
         BEQ LS_DONE          ; LP==PE: end cleanly rather than overrunning
         LDA (LP),Y
         CMP #CR
         BEQ LS_EOL
         JSR PUTCH
         JSR BUMP_LP
         BNE LS_BODY          ; always taken here (listing walks RAM pages, never wraps to $00)

LS_EOL:  JSR PRNL              ; print CR+LF at end of each listed line
         JSR BUMP_LP
         BNE LS_LN            ; always taken here

; =============================================================================
; ADD2_LP  --  LP += 2 (shared by INSLINE and DO_LIST, skip a 2-byte header)
;
;   In:  LP
;   Out: LP advanced by 2
;   Clobbers: LP  (the documented Out: change; no registers touched)
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: INC LP
         BNE BUMP_RTS
         INC LP+1
LS_DONE: 
BUMP_RTS: RTS

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
; PE_CMP  --  compare LP against PE (shared by EDITLN, GOTOL, DO_LIST/FETCH)
;
;   In:  LP
;   Out: Z=1 if LP == PE, Z=0 otherwise
;   Clobbers: A
; =============================================================================
PE_CMP:  LDA LP
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
         LDY #0         ; Clear Y to use as a static 0 index
LSK_LP:  LDA (LP),Y     ; Read current character
         JSR BUMP_LP    ; Advance LP to the next memory address
         CMP #CR        ; BUMP LP does not touch A - was it a ?
         BNE LSK_LP     ; No? Loop back and check the next byte
         RTS            ; Done, LP points to the next line

; =============================================================================
; T0_CMP_LP  --  compare T0 against LP (shared by INSLINE's two checks)
;
;   In:  T0
;   Out: Z=1 if T0 == LP, Z=0 otherwise
;   Clobbers: A
; =============================================================================
T0_CMP_LP:
         LDA T0
         CMP LP
         BNE TCL_NE
         LDA T0+1
         CMP LP+1
TCL_NE:  RTS

; =============================================================================
; MTCHKW  --  case-insensitive match of a 2-char keyword prefix at IP against
;             UNI_TAB entry X, then consumes any further trailing letters/'$'.
;
;   In:  X = byte offset of the keyword entry within UNI_TAB (its first two
;        bytes are the raw keyword chars); the special one-off keywords
;        KW_THEN/KW_CHRS are matched the same way, X = <label>-UNI_TAB
;   Out: match:    C=0, IP advanced past the keyword. X unchanged.
;        no match: C=1, IP restored to entry value, X unchanged.
;   Clobbers: A Y  (T2 is NOT clobbered -- caller may hold a jump target)
;
;   IP is saved in LP on entry and restored on failure. Shares its fail exit
;   (MK_FAIL/MK_SEC) with GOTOL -- do not rename.
;
; =============================================================================
MTCHKW:
         LDA IP
         STA LP               ; save IP in LP for restore on failure
         LDA IP+1
         STA LP+1

         ; compare first keyword character (direct against UNI_TAB,X)
         JSR GETCI
         CMP UNI_TAB,X
         BNE MK_FAIL

         ; compare second keyword character (no space-skip: must be adjacent)
         JSR GETCI
         CMP UNI_TAB+1,X
         BNE MK_FAIL

         ; matched prefix: skip remaining letters for full BASIC keywords
MK_SKIP: 
         LDA (IP),Y
         SEC
         SBC #'A'              ; shift 'A'-'Z' down to 0-25; remainder kept in A
         CMP #26
         BCS MK_OK             ; not a letter: exit, A still holds the remainder
         JSR GETCI
         BNE MK_SKIP           ; always taken (token chars are nonzero)
MK_OK:   CMP #$E3              ; remainder == '$'-'A' (mod 256)? reuses A, no re-peek
         BNE MK_RTS            ; not '$': fall through to return success
         JSR GETCI             ; it IS '$': consume it
MK_RTS:  CLC                  ; N flag survives CLC untouched (inline saves 2 bytes)
         RTS

MK_FAIL: SEC                  ; C=1: no match
         BCS COPY_LP_IP       ; unconditional jump to the shared LP->IP copy

; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to body (past 2-byte header); CURLN = T0
;        C=1  not found -- IP = PE; CURLN unchanged
;   Clobbers: A Y IP LP CURLN
;
;   Scans using LP (shared PE_CMP/LSKIP routines with EDITLN, which also
;   scan via LP); only converts to IP once, at the success point, since
;   that's the only place the documented output contract needs it. Safe:
;   GOTOL's only caller (DO_GO) explicitly doesn't need LP preserved across
;   this call ("LP no longer needed" once EXPR has parsed the target line).
; =============================================================================
GOTOL:
         JSR PROG2LP
GT_SC:   JSR PE_CMP            ; test LP == PE (end of store)
         BEQ MK_FAIL            ; not found
         LDY #0
         LDA (LP),Y           ; read line-number lo
         CMP T0               ; compare line-number lo
         BNE GT_NX
         LDY #1
         LDA (LP),Y
         CMP T0+1             ; compare line-number hi
         BEQ GT_OK
GT_NX:   JSR LSKIP             ; advance LP to next line (shared w/ EDITLN)
         BEQ GT_SC              ; LSKIP's only exit is via CMP #CR -- Z=1 guaranteed

GT_OK:   ; Copy T0 to CURLN
         LDA T0               ; T0 already == the matched line number
         STA CURLN
         LDA T0+1
         STA CURLN+1
         ;
         JSR ADD2_LP          ; LP += 2, past the 2-byte header
         CLC                  ; C=0: found
COPY_LP_IP:
         LDA LP               ; IP = LP (Carry flag passes through these unchanged)
         STA IP
         LDA LP+1
         STA IP+1
         RTS                  ; Exit with C=0 (from GT_OK) or C=1 (from MK_FAIL)

; =============================================================================
; EAT_EXPR  --  skip spaces, consume one char (e.g. '('), evaluate expression
;   Consumes one char (e.g. opening '('), then falls through into EXPR.
;   In:  IP -> char to consume (leading spaces skipped first)
;   Out: T0 = expression result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 IP
; =============================================================================
EAT_EXPR:
         JSR WEAT             ; skip spaces then consume one char
         ; fall through into EXPR

; =============================================================================
; EXPR  --  strictly left-to-right expression evaluator (no operator
;   precedence; use parentheses to group, e.g. "(A*A/64)-(B*B/64)+C" or
;   "256<((A*A/64)+(B*B/64))" -- see the showcase's Mandelbrot section for
;   real examples of exactly this).
;
;   Operators scanned directly against UNI_TAB's operator section (X=15
;   down to 0, stride 3 -- see UNI_TAB header). DO_OP tail-calls into
;   MATCH_DISPATCH's MD_FAIL, reusing its push-hi/push-lo/RTS gadget
;   instead of owning a second copy: with X already sitting on the
;   matched operator's own char byte (stride-3 layout: char at +0,
;   handler lo/hi at +1/+2), MD_FAIL's "+2,X / +1,X" reads line up with
;   no index shift needed (contrast MATCH_DISPATCH's own successful
;   match, which INX's once first to shift its stride-4 layout into the
;   same alignment).
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 T3 IP
; =============================================================================

; --- Relational: Equality ---
DO_EQ:   LDA T1
         CMP T0
         BNE REL_F
         LDA T1+1
         CMP T0+1
         BNE REL_F
         BEQ REL_T            ; Exact match -> true (BEQ branches over DO_LT)

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
         JMP EXPR_LOOP

DO_OP:
         TXA
         PHA                  ; save operator's table offset (0,3,6,9,12,15)
         JSR GETCI            ; consume the operator character
         LDA T0+1             ; push left operand (T0) hi
         PHA
         LDA T0               ; push left operand (T0) lo
         PHA
         JSR EXPR2            ; parse the right operand -> T0
         PLA
         STA T1               ; pop left operand lo -> T1
         PLA
         STA T1+1             ; pop left operand hi -> T1+1
         PLA
         TAX                  ; pop operator's table offset -> X

         LDA UNI_TAB,X        ; recover the raw operator char (DO_MD needs
         STA T3               ; it to tell '*' from '/'); harmless for the
                              ; other four handlers, which ignore T3
         JMP MD_FAIL          ; tail call into MATCH_DISPATCH's RTS gadget

EXPR:
         JSR EXPR2            ; parse the first atom -> T0
EXPR_LOOP:
         JSR WPEEK            ; peek next char (not consumed)
         LDX #15              ; offset of the last operator ("<") in UNI_TAB
OP_SCAN: CMP UNI_TAB,X
         BEQ DO_OP            ; found a matching operator
         DEX                  ; stride is 3 bytes (char + address)
         DEX
         DEX
         BPL OP_SCAN          ; BPL falls through once X goes below 0
         RTS                  ; no operator matched: result in T0, exit cleanly

; --- Multiplication & Division ---
DO_MD:   LDA T3
         LSR                  ; Bit 0 into carry: '*' ($2A) -> C=0, '/' ($2F) -> C=1
         BCC E1_NOCHK
         LDA T0
         ORA T0+1
         BEQ E1_OVFL          ; T0 == 0 -> Division by zero error
E1_NOCHK:
         LDA T1+1
         EOR T0+1
         PHA                  ; Save result sign
         LDA T1+1
         BPL E1_P1
         JSR NEG_T1           ; Make T1 positive
E1_P1:   LDA T0+1
         BPL E1_P2
         JSR NEG16            ; Make T0 positive
E1_P2:   LDA #0
         STA T2               ; Clear T2 (product/quotient accumulator)
         STA T2+1
         LDA T3
         LSR                  ; Re-evaluate operator char
         BCS DIV_LOOP

MUL_LOOP:
         LDA T0               ; 16-bit decrement of T0 (multiplicand doubles as loop counter)
         BNE MLLP
         DEC T0+1
         BMI MD_DONE          ; Once T0+1 wraps from $00 to $FF, we're done
MLLP:    DEC T0
         LDX #4               ; Target X=4 (T2)
DO_ADD_TAIL:                  ; --- SHARED INLINE ADDITION KERNEL ---
         CLC
         LDA T0,X             ; If X=0, this is T0. If X=4, this is T2.
         ADC T1               ; T1 is the other operand for BOTH add and multiply
         STA T0,X
         LDA T0+1,X
         ADC T1+1
         STA T0+1,X
         TXA                  ; 1-byte trick to check X
         BNE MUL_LOOP         ; If X=4, loop back to multiply
         BEQ EXPR_LOOP        ; If X=0, addition is done - always taken

; --- Addition & Subtraction ---
DO_SUB:  JSR NEG16            ; negate right operand (T0), fall through to ADD
DO_ADD:  LDX #0               ; Target X=0 (T0). Sets Z flag
         BEQ DO_ADD_TAIL      ; Unconditional branch jumps straight into the shared ADD logic
         
E1_OVFL: LDA #ERR_OV
         JMP DO_ERROR

DIV_LOOP:
         SEC                  ; Repeated subtraction: T1 -= T0
         LDA T1
         SBC T0
         STA T1               ; Unconditional write avoids TAX + STX 
         LDA T1+1
         SBC T0+1
         STA T1+1             ; We don't care if T1 is corrupted on the final over-subtract
         BCC MD_DONE          ; Stop once T1 < T0
         INC T2               ; Quotient tally
         BNE DIV_LOOP
         INC T2+1
         BNE DIV_LOOP

MD_DONE: LDA T2
         STA T0
         LDA T2+1
E1_SIGN: STA T0+1
         PLA                  ; Retrieve sign
         BPL E1_POS
         JSR NEG16            ; Apply sign
E1_POS:  JMP EXPR_LOOP

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
         ; drop through

; =============================================================================
; NEG_T1 / NEG16  --  two's-complement negate
; In:  T0 or T1 = value to negate. Selected dynamically by offset mapping.
; Clobbers: A X
; =============================================================================
NEG16:   LDX #0
         .DB $2C              ; BIT abs: skips next 2 bytes (the LDX #2)
NEG_T1:  LDX #2
         SEC
         LDA #0
         SBC T0,X
         STA T0,X
         LDA #0
         SBC T0+1,X
         STA T0+1,X
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
E2_POS:  JSR GETCI            ; consume unary '+', then fall through
EXPR2:
         JSR WPEEK
         CMP #'('
         BEQ E2_PAR
E2_NOTPAR:
         CMP #'-'
         BEQ E2_NEG
         CMP #'+'
         BEQ E2_POS
; =============================================================================
; try number or var 
E2_LIT:  LDA (IP),Y
         EOR #'0'     ; Maps '0'-'9' to 0-9
         CMP #10      ; Anything else becomes >= 10
         BCS E2_VAR
         ; drop through

; =============================================================================
; PNUM  --  parse unsigned decimal integer from ASCII at IP into T0
;
;   In:  IP -> ASCII digits (leading spaces skipped automatically)
;   Out: T0 = parsed value; IP advanced past the last digit
;   Clobbers: A X Y T0 T2 T3
;   Stops at the first non-digit without consuming it.
; =============================================================================
PNUM:
         LDY #0                ; Y stays 0 for the whole routine
         STY T0                ; clear result lo
         STY T0+1              ; clear result hi
PN_LP:   LDA (IP),Y            ; peek without consuming
         EOR #'0'              ; [OPT] Maps '0'-'9' to 0-9. Anything else maps >= 10
         CMP #10               ; [OPT] Check bounds
         BCS PN_DN             ; If A >= 10, not a digit -- done

         STA T2                ; seed running sum lo with digit
         STY T3                ; seed running sum hi with 0
         LDX #10               ; T2:T3 = digit + 10*T0
         ; [OPT] CMP #10 guaranteed Carry is CLEAR here (No CLC needed)
PN_ML:   
         LDA T2
         ADC T0
         STA T2
         LDA T3
         ADC T0+1
         STA T3
         DEX
         BNE PN_ML
         ; Copy ?? to T0 
         LDA T2
         STA T0
         LDA T3
         STA T0+1

         ; [OPT] GETCI does the identical 16-bit IP increment and returns the
         ; raw digit char ($30-$39) in A, which is always nonzero.
         JSR GETCI             ; consume digit, advances IP 16-bit
         BNE PN_LP              ; guaranteed to branch since A != 0

E2_BAD:  JMP REL_F              ; return zero

E2_VAR:  JSR PARSE_VAR               ; variable name (single letter A-Z)?
	 BCS E2_BAD
         TAX
         LDA VARS,X
         STA T0
         LDA VARS+1,X
         STA T0+1
PN_DN:
         RTS

E2_PAR:  JSR GETCI            ; consume '('
         JSR EXPR             ; evaluate sub-expression
         ; fall through into WEAT to consume ')'

; =============================================================================
; WEAT  --  skip spaces then consume one char from IP; return char in A
;
;   In:  IP -> char (with possible leading spaces)
;   Out: A = char consumed; IP advanced past it
;   Clobbers: A IP
;
;   Falls through into GETCI after skipping spaces. E2_PAR falls through
;   into this directly from above -- do not insert anything between them.
; =============================================================================
WEAT:    JSR WSKIP            ; skip spaces, then fall through

; =============================================================================
; GETCI  --  fetch char at IP and advance IP
;
;   In:  IP -> char to fetch
;   Out: A = char; IP incremented (16-bit)
;   Clobbers: A Y IP
; =============================================================================
GETCI:   LDY #0
         LDA (IP),Y
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
;   On true: consumes optional THEN, then falls through into STMT.
;   On false: branches to nearest preceding RTS (DO_IF_F = GETCI_SK).
; =============================================================================
DO_IF:
         JSR EXPR             ; evaluate condition -> T0
         LDA T0
         ORA T0+1              ; check for zero
         BEQ DO_IF_F          ; false: return
         LDX #KW_THEN-UNI_TAB
         JSR MTCHKW           ; consume optional THEN keyword
         ; fall through into STMT to execute the consequent

; =============================================================================
; STMT  --  execute one statement from IP
;
;   In:  IP -> statement text (spaces will be skipped)
;   Out: statement executed; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Falls through directly into MATCH_DISPATCH; a match runs the handler
;   and RTS's to STMT's caller, no match falls through to DO_LET
;   (implicit "X=...") via the sentinel. Nothing may be inserted between
;   here and MATCH_DISPATCH.
; =============================================================================
STMT:
         JSR WPEEK
         CMP #' '             ; anything below space (CR, NUL) means empty line
         BCC GETCI_SK         ; return via nearest preceding RTS
        ; drop through
; =============================================================================
; MATCH_DISPATCH -- linear search of UNI_TAB's statement section (KW_TAB),
;   dispatches on first match.
;   Table ends with a 3-byte $FF sentinel whose next 2 bytes ARE the
;   no-match resume address (read directly, no loop-back -- see UNI_TAB
;   header).
;
;   In:  -- (STMT is the only caller; sets no register of its own -- X is
;        set right below instead, since EXPR's DO_OP also jumps into this
;        block further down, at MD_FAIL, with its own X already set)
;   Out: matched handler executed (tail call, RTS's to MATCH_DISPATCH's
;        caller); IP advanced
;   Clobbers: A, X, Y  (plus MTCHKW's own: A, Y)
; =============================================================================
MATCH_DISPATCH:
         LDX #(KW_TAB-UNI_TAB) ; start of the statement section (skips the
                                ; operator section UNI_TAB itself begins with)
MD_LP:   LDA UNI_TAB,X
         BMI MD_FAIL           ; $FF sentinel: no match, X unchanged
         JSR MTCHKW            ; X = entry offset, passed straight through
         BCS MD_NX             ; not matched
         INX                   ; matched: shift X by 1 so the +2/+1 reads
                                ; below line up with this entry's own +3/+2
                                ; (handler hi/lo) -- folds this path into
                                ; MD_FAIL's push/RTS instead of duplicating it
MD_FAIL:                       ; also reached directly from the sentinel above
                                ; (X unchanged there); +2/+1 are then the
                                ; sentinel's own (resume-1) hi/lo instead --
                                ; and from EXPR's DO_OP, with X set to an
                                ; operator's own offset (stride-3 layout
                                ; needs no INX to align, see EXPR's header)
         LDA UNI_TAB+2,X
         PHA
         LDA UNI_TAB+1,X
         PHA
         RTS                   ; pulls lo,hi -> PC = (handler-1 or resume-1)+1

MD_NX:   INX
         INX
         INX
         INX
         BNE MD_LP             ; always taken (table well under 256 bytes)

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
;
; =============================================================================
WSKIP:
WPEEK:   LDY #0
         LDA (IP),Y
         CMP #' '
         BNE RTS_1            ; non-space: return
         JSR GETCI            ; consume space and loop
         BNE WSKIP            ; always taken (' ' = $20, nonzero)
RTS_1:   RTS

; =============================================================================
; PRT16  --  print T0 as a signed decimal integer
;
;   In:  T0 = signed 16-bit value
;   Out: decimal digits printed to terminal; T0 destroyed
;   Clobbers: A Y T0
;
;   Algorithm: 16-bit shift-and-subtract BCD extraction; recursive so digits
;   print highest-first without a digit buffer.
;   Falls through into PUTCH to print the final (lowest) digit.
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
         TAX ; this is in case we are using BNE instead of BRA
DP_RET:
         RTS

; =============================================================================
; GETLINE  --  MINIMAL read one line from the terminal into IBUF; set IP = IBUF
;
;   Three entry points sharing one body:
;     GETLINE_M  prints "> " (immediate-mode prompt)
;     GETLINE    no prompt
;
;   In:  --
;   Out: IBUF filled with input, CR-terminated; IP = IBUF, Y is # chars
;   Clobbers: A X Y IP T3 (Y is GETLINE's own buffer index)
;   
;   Note: NO Range checking/Backspace support - Overflow could crash  
;   
; =============================================================================
GETLINE_M:
         LDA #'>'            ; (2) Prompt for Direct Mode
         JSR PUTCH           ; (3) Print prompt character ('?' or '>')
GETLINE:
         JSR PRTSPACE        ; (3) Print trailing space
         LDX #0
GL_LOOP:
         JSR GETCH      ; (3) Wait for and get keystroke in A
         STA IBUF,X     ; (2) Store raw character into buffer
         INX            ; (1) Advance index
         CMP #CR        ; (2) Was it a carriage return?
         BNE GL_LOOP    ; (2) If not, keep reading
      ;   JMP PRNL       ; (3) Tail-call print LF / newline and RTS
        ; drop through
; =============================================================================
; DO_PRINT  --  PRINT [item [; item] ...]
;
;   In:  IP -> first character after "PRINT" keyword
;   Out: output written to terminal; IP advanced past statement
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Items: string literals ("..."), CHR$(expr), or numeric expressions.
;   Items separated by ';' suppress the inter-item space.
;   A trailing ';' suppresses the final CR/LF.
;   At end of items (or with no items) falls through into PUTSTR to emit CR/LF.
; =============================================================================
DP_NL:   
PRNL:    LDA #CR
         JSR PUTCH
         LDA #LF
         BNE PUTCH              ; always taken
  
DO_PRINT:
DP_TOP:  JSR WPEEK
         CMP #CR+1            ; NUL(0) and CR(13) are both < CR+1 -- one check
         BCC DP_NL            ; catches both "end of line" cases at once
         CMP #'"'
         BNE DP_CHR
         JSR GETCI            ; consume opening '"'
DP_STR:  JSR GETCI            ; read string body char by char
         CMP #'"'
         BEQ DP_AFT           ; closing '"' -- go check for ';'
         CMP #CR+1
         BCC DP_NL            ; unterminated string -- print CR/LF and stop
         JSR PUTCH
         BNE DP_STR           ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional

DP_CHR: LDX #KW_CHRS-UNI_TAB
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_NORM
         JSR E2_PAR           ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         LDA T0
         JSR PUTCH
         BNE DP_AFT            ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional

DP_NORM: JSR EXPR             ; numeric expression
         JSR PRT16
DP_AFT:  JSR WPEEK
         CMP #';'
         BNE DP_NL
         JSR GETCI            ; consume ';'
         JSR WPEEK
         CMP #CR+1            ; NUL(0) and CR(13) are both < CR+1 -- one check
         BCC DP_RET           ; trailing ';': suppress CR/LF (DP_RET = IN_DN = RTS above)
         BCS DP_TOP            ; always taken (just proved carry set, i.e. A >= CR+1)
       
; =============================================================================
; GETCH  --  read one character from Kowalski terminal (blocking)
;
;   In:  --
;   Out: A = character read
;   Clobbers: A
;
;   No longer echoes -- GETLINE (its only caller) echoes explicitly so it
;   can substitute BELL for the echo on a full input buffer. See GETLINE.
; =============================================================================
GETCH:   LDA IO_IN
         BEQ GETCH          ; spin until a char is available
         RTS

ROMEND: ; for auditing

; =============================================================================
; Reset / IRQ / NMI vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT         ; $FFFC: reset vector
         .DW INIT      ; $FFFE: IRQ vector   (No IRQ)
