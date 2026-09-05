; =============================================================================
; uBASIC6502 v1.15  --  2 KB Tiny BASIC (NMOS 6502) for John Bell 80-153 SBC
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Note: Due to bitbang serial IO, either use the JB-Sim65c02 simulator for 
; bitbang ROM size testing, or set KOWALSKI for testing in Kowalski 6502 simulator. 
;
KOWALSKI   = 1
;
;   CPU    : NMOS 6502 @ 1 MHz
;   ROM    : 2716 EPROM  2 KB  $F800-$FFFF
;   RAM    : 2x2114 SRAM 1 KB  $0000-$03FF
;   I/O    : 6522 VIA  PA0=TX (bitbang), PA1=RX (bitbang), 1200 baud
;   IRQ    : 6522 IRQ line NOT connected to CPU on PN 80-153.
;            Instead Break key (pushbutton) wires directly to IRQ pin.
;   NMI    : NMI is unused. 
;
; RAM layout for 1 KB target:
;   $0000-$007F  zero-page (IP/CURLN/PE/LP/T0-T4/RUN/IBUF
;                VARS/RUNSP/GOSUB_SP/GOSUB stack); ZPEND=$7F, fits the
;                $80-$FF/$180-$1FF hardware-stack RAM alias constraint
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full or 2-letter prefix):
;   END  GOSUB  GOTO  IF..THEN  INPUT  LET  DPOKE  POKE  PRINT  REM  RETURN    
;   LIST [n,m]  NEW  RUN
;
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   ABS(val)   FREE   PEEK(addr)   DPEEK(addr)   RND   USR(addr)   A-Z variables
;   XOR(a,b)   AND(a,b)   OR(a,b)  NOT(a)
;
; Numbers : signed 16-bit  (-32768 .. 32767)
; Print   : "literals", `;`, TAB(n), HEX$(val), CHR$(char); no string vars
;
; KNOWN LIMITATIONS
;
; UPPERCASE required everywhere except inside PRINT string literals.
;
; Two Character keyword matching - only 2 chars matched then rest of the word
;   is consumed until a space or `(`.  Spaces are needed: `10 PRINT TAB(5);"Hello"`
;   works, `10 PR TA(5);"Hello"` also works, but `10 PRINTTAB(5);"Hello"` prints
;   "5Hello", not 5 spaces.
;
; Variables: 26 single-letter A-Z only; anything else (e.g. "LET AB=5")
;   raises "?4 bad variable name".
;
; No `:` multi-statement separator, no FOR/NEXT, no arrays/DIM, no string
;   variables -- see the above list above for the full set.
;
; Numbers are signed 16-bit only (-32768..32767); arithmetic overflow
;   wraps silently (e.g. 32767+1 = -32768) -- it does not raise an error.
;
; Division and modulo by zero both raise "?2"; modulo follows the sign of
;   the dividend (truncating, C-style), not floored: (0-7)%3 = -1.
;
; GOTO/GOSUB accepts expressions 
;   GOSUB nesting is limited to 4 levels; a 5th nested call raises "?3 out
;   of memory" rather than corrupting the return-frame stack.
;   GOTO/GOSUB to an undefined line number raises "?1".
;
; Input buffer is 35 usable chars + CR terminator. Each keypress past the
;   limit sounds BELL ($07) and is discarded -- not stored, not
;   echoed, index does not advance. Backspace deletes normally when buffer full
;
; No recursion-depth limit on nested parentheses. EXPR/EXPR2 recurse fully
;   for each '(', ~8 hardware-stack bytes/level with nothing to cap it --
;   a single line with ~22+ nested '(' (well within the input-buffer limit
;   above) overflows the 127-byte hardware stack and wraps into PROG memory,
;   silently corrupting the stored program. Confirmed with write-watchpoints
;   (Sep 2026); not fixed by the V1.15 RUNSP change, which only removed an
;   unnecessary snapshot/restore -- it never bounded recursion depth.
;
; TAB(n), CHR$(n), HEX$(val) are valid only in PRINT line 
;   TAB(n) prints n=1..127 spaces, not jump to col n. Negative/Zero n ignored.
;   HEX$(expr) prints $hex, leading zero suppressed due to size constraints.
;
; Error codes (printed as "?N"):
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division or modulo by zero
;   ?3  out of memory
;   ?4  bad variable name in LET
;   ?5  RETURN without GOSUB
;   ?6  BREAK into running prog
;
; ---- ROM memory map ---------------------------------------------------------
;   $F800          Rom Start
;   $FFFC..$FFFF   Reset / IRQ vectors
;
; ---- program storage --------------------------------------------------------
;   Base $0180 to ceiling RAM_TOP ($0400 for 1 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; ---- version lineage --------------------------------------------------------
;   V1.15 (Sep 2026)  Free ROM before vectors: Bitbang 22bytes, Kowalski 63bytes
;                     Code Golf: PE_CMP leaves Y=1 as a free side effect
;                     RUNSP removed, GO_DO and DO_RETURN unwind with PLA/PLA.
;                     BUMP_LP now fetches *LP before advancing
;                     T0->CURLN merged into one shared tail via a BIT-trick
;                     MAIN's blank-line CR check removed as STMT's handles it
;                     DPEEK(addr)/`DPOKE addr, val` added: 16-bit PEEK/POKE.
;   V1.14 (Aug 2026)  Free ROM before vectors: Bitbang 10bytes, Kowalski 51bytes
;                     Removed Uppercase checks to reduce assembly size.
;                     Line-handling golf pass on DELINE/EDITLN/INSLINE.
;                     Code golf AND/OR/XOR, DO_NOT, and MTCHKW/GOTOL.
;   V1.13 (Aug 2026)  49 bytes free before vectors. Added $-prefixed hex
;                     literals (e.g. $BEEF), unified into PNUM as a single
;                     PNUM/PHEX radix-parameterized routine. MATCH_DISPATCH:
;                     MD_NOPAREN/MD_FAIL push/RTS folded into one shared
;                     block. Added NOT(x)/AND(a,b)/OR(a,b)/XOR(a,b), the
;                     2-arg forms using EAT_PAREN's to eat closing paren.
;   V1.12 (Aug 2026)  49 bytes free before vectors. Code-golf pass:
;                     EXPR1 quotient/remainder copy (E1_MOD) now shares one
;                     copy block indexed by X (2=T1 quotient, 4=T2 remainder),
;                     GOTOL's GT_OK now reuses existing ADD2_LP helper to advance
;                     LP past line header, then copies LP->IP.
;                     Deleted PRTSTR, DP_STR usedfor banner, refactored DO_ERROR.
;   V1.11 (Aug 2026)  11 bytes free before vectors
;                     BUG FIX: EXPR1 stashed operator in OP, but is recursive, 
;                     so parenthesized sub-expression with another */,/,%
;                     clobbered it (e.g. "2*(10/5)" ran as division).
;                     Operator now held on the hw stack across the call,
;                     popped into T3 (mirrors EXPR_ADD's existing pattern).
;                     EXPR's relational-mask stash moved OP->T3 too.
;   V1.10 (Aug 2026)  Zero page optimised to $80 bytes: 8->4 GOSUB levels, T3, OP
;                     IBUF_MAX 41->36 (42->37 bytes). No logic changes.
;   V1.9 (Aug 2026)   10 bytes free. Refactor Getch/Putch, Added HEX$(val) to PRINT.
;   V1.8 (Jul 2026)   21 bytes free. Updated all subroutine headers.
;   V1.7 (Jul 2026)   22 bytes free. Fixed Kowalski-incompatible syntax in UNI_TAB 
;                     `<(label-1), >(label-1)` rewritten as `.DW label-1` instead.
;                     Refactored GETLINE to Y counter, updated DELAY for ZP not Y.  
;   V1.6 (Jul 2026)   Fixed GETLINE buffer-overflow: GETCH echoed every character
;                     unconditionally before GETLINE could check for buffer-full.
;   V1.5 (Jul 2026)   Merged ST_TAB (statements) and EXPR2's linear 
;                     PEEK/USR/RND/FREE/ABS chain into a keyword+jump table 
;                     walked by a single MATCH_DISPATCH loop.
;   V1.4 (Jul 2026)   Added showcase and Syntax edits for Kowalski Simulator.
;   V1.3 (Jul 2026)   10 bytes free before vectors.  Multiple helpers to 
;                     refactor for size. Added optional LIST start,end and ABS.
;                     FREE converted to function to save space.
;   V1.2 (Jul 2026)   29 bytes free before vectors. Ported GOSUB/RETURN, RND 
;                     from uBASIC6502 1.9. Refactor PNUM/DELINE/INSLINE/EDITLN
;                     for size/correctness. GOTOL updates CURLN bugfix.Refactor
;                     DO_NEW. Remove partial ':' multi-statement support. 
;   V1.1 (Jun 2026)   Refactored for size, added FREE and TAB.
;   v1.0 (Jun 2026)   Initial Port from uBASIC6502 1.4
;
; ---- assembler mode ---------------------------------------------------------
         .opt proc6502

; ---- Hardware I/O (John Bell Engineering PN 80-153 -- 6522 VIA) -------------
VIA_DDRA = $1C03             ; 6522 Port A Data Direction Register
VIA_ORA  = $1C0F             ; 6522 Port A Output/Input Register (no handshake)
VIA_TX   = $01               ; PA0 = TX output bit mask
VIA_RX   = $02               ; PA1 = RX input  bit mask

; ---- Kowalski Emulated IO ---------------------------------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)

; ---- Constants -------------------------------------------------------------
	 .IF KOWALSKI
RAM_TOP  = $800 	     ; Showcase a smidge under 2kbytes
	 .ELSE
RAM_TOP  = $0400             ; Bell board has 1k SRAM (1 KB: 2x 2114)
	.ENDIF	 

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
ERR_RET  = '5'                 ; RETURN without GOSUB
ERR_IRQ  = '6'                 ; BREAK into running Prog

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
T4:         .RS 2              ; 16-bit: General scratch, DO_POKE, DELAY, free for others
IP:         .RS 2              ; 16-bit: interpreter pointer
CURLN:      .RS 2              ; 16-bit: currently-executing line number
PE:         .RS 2              ; 16-bit: program end (one past last byte)
LP:         .RS 2              ; 16-bit: line pointer / multi-purpose scratch
RND_SEED:   .RS 2              ; 16-bit: Galois LFSR state for RND 
RUN:        .RS 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
GOSUB_SP:   .RS 1              ; 8-bit:  GOSUB/RETURN stack pointer (holds ZP address directly)
GOSUB_LO:   .RS 16             ; base of the 4-level GOSUB return-frame stack (16 bytes)
VARS:       .RS 52             ; 52-byte variable store (A-Z, 2 bytes each)
IBUF:       .RS IBUF_MAX+1     ; Input line buffer 
ZPEND:		; audit

; ---- Zero-page lifetime notes -----------------------------------------
; T3 and T4 each serve two unrelated purposes at different times; safe only
; because this is a single-threaded interpreter with no reentrancy between
; the two uses of either byte. If that ever changes (e.g. an IRQ-driven
; path that touches these), re-check these pairings.
;   T0   : primary scratch / expression result -- live during nearly any
;          statement or expression evaluation; the most heavily reused byte
;   T1   : secondary scratch -- EXPR's left-operand stash, EXPR1's MUL/DIV/
;          MOD working value, MTCHKW's raw keyword-char stash
;   T2   : tertiary scratch -- PUTSTR/PRNL's string pointer; historically
;          also a STMT jump target (no longer true after the RTS-trick
;          dispatch rewrite -- MATCH_DISPATCH doesn't touch T2 at all now)
;   T3   : (a) PNUM's x10-multiply scratch, live only during decimal
;          parsing/printing; (b) bitbang GETCH/PUTCH's RXCHAR/TXCHAR shift
;          register, live only during serial I/O; (c) EXPR's relational
;          mask / EXPR1's MUL-DIV-MOD operator stash (v1.11), live only
;          after the operator's own recursive right-operand evaluation
;          has fully returned -- the operator itself is held on the
;          hardware stack, not T3, during that recursive call, which is
;          what fixes v1.10's "2*(10/5)" nested-parens bug (a fixed ZP
;          byte there got clobbered by the inner EXPR1 re-entry). Never
;          concurrent with (a)/(b): no PNUM or serial I/O call happens
;          between EXPR/EXPR1 popping the operator and its last use.
;   T4   : (a) DO_POKE/GET_TWO_ARGS' first-argument holder, live only
;          within a single POKE/LIST-range statement's own execution;
;          (b) DELAY_BIT/DELAY_HALF's countdown counter, live only during
;          a single bit-time delay. Never concurrent: DO_POKE's body
;          doesn't call PUTCH between setting T4 and reading it back.
;   LP   : line-store scan pointer -- shared by EDITLN, GOTOL, DO_LIST,
;          LSKIP, DELINE, PE_CMP, INSLINE; each call fully consumes LP
;          before any nested call that might also use it
; -------------------------------------------------------------------------
; Defined here so no forward reference
GOSUB_FULL = GOSUB_LO+3    ; lowest X for which a full 4-byte push still fits 
GOSUB_TOP  = GOSUB_LO+15   ; initial/empty GOSUB_SP value (topmost stack byte)

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
;   Lines  10-130: PRINT, CHR$, arithmetic, comparisons
;   Lines 140-240: GOSUB/RETURN (incl. nested)
;   Lines 250-430: GOTO loop, nested GOTO loop
;   Lines 440-500: TAB, FREE, POKE/PEEK
;   Lines 510-600: RND
;   Lines 610-860: Mandelbrot set renderer
;
;   v1.9:  Added RND section 
;   v1.8:  Added GOSUB/RETURN, TAB, FREE, and POKE/PEEK sections
;   v1.1:  Mandelbrot column scan adjusted from -128..16 to -120..4
; =============================================================================

         .DB $0A,$00,"REM uBASIC SHOWCASE",CR        ; 10 REM uBASIC - SHOWCASE
         .DB $14,$00,"PRINT ",$22,"-- uBASIC SHOWCASE --",$22,CR ; 20 PRINT "-- uBASIC SHOWCASE --"
         .DB $1E,$00,"PRINT ",$22,"--- PRINT / CHR$ ---",$22,CR ; 30 PRINT "--- PRINT / CHR$ ---"
         .DB $28,$00,"PRINT CHR$(65)",$3B,"CHR$(66)",$3B,"CHR$(67)",CR ; 40 PRINT CHR$(65);CHR$(66);CHR$(67)
         .DB $32,$00,"PRINT ",$22,"--- ARITHMETIC ---",$22,CR ; 50 PRINT "--- ARITHMETIC ---"
         .DB $3C,$00,"PRINT ",$22,"3+4=",$22,$3B,"3+4",$3B,$22,"  10-3=",$22,$3B,"10-3",$3B,$22,"  6*7=",$22,$3B,"6*7",CR ; 60 PRINT "3+4=";3+4;"  10-3=";10-3;"  6*7=";6*7
         .DB $46,$00,"PRINT ",$22,"20/4=",$22,$3B,"20/4",$3B,$22,"  17%5=",$22,$3B,"17%5",CR ; 70 PRINT "20/4=";20/4;"  17%5=";17%5
         .DB $50,$00,"PRINT ",$22,"--- COMPARISONS ---",$22,CR ; 80 PRINT "--- COMPARISONS ---"
         .DB $5A,$00,"IF 5>3 THEN PRINT ",$22,"5>3 ok",$22,CR ; 90 IF 5>3 THEN PRINT "5>3 ok"
         .DB $64,$00,"IF 3<5 THEN PRINT ",$22,"3<5 ok",$22,CR ; 100 IF 3<5 THEN PRINT "3<5 ok"
         .DB $6E,$00,"IF 3>=3 THEN PRINT ",$22,"3>=3 ok",$22,CR ; 110 IF 3>=3 THEN PRINT "3>=3 ok"
         .DB $78,$00,"IF 4<>3 THEN PRINT ",$22,"4<>3 ok",$22,CR ; 120 IF 4<>3 THEN PRINT "4<>3 ok"
         .DB $82,$00,"IF 3=3 THEN PRINT ",$22,"3=3 ok",$22,CR ; 130 IF 3=3 THEN PRINT "3=3 ok"
         .DB $8C,$00,"PRINT ",$22,"--- GOSUB/RETURN ---",$22,CR ; 140 PRINT "--- GOSUB/RETURN ---"
         .DB $96,$00,"GOSUB 200",CR                         ; 150 GOSUB 200
         .DB $A0,$00,"PRINT ",$22,"back from depth 1, X=",$22,$3B,"X",CR ; 160 PRINT "back from depth 1, X=";X
         .DB $AA,$00,"GOSUB 220",CR                         ; 170 GOSUB 220
         .DB $B4,$00,"PRINT ",$22,"back from depth 2, X=",$22,$3B,"X",CR ; 180 PRINT "back from depth 2, X=";X
         .DB $BE,$00,"GOTO 250",CR                          ; 190 GOTO 250
         .DB $C8,$00,"X=1",CR                               ; 200 X=1
         .DB $D2,$00,"RETURN",CR                            ; 210 RETURN
         .DB $DC,$00,"GOSUB 200",CR                         ; 220 GOSUB 200
         .DB $E6,$00,"X=X+1",CR                             ; 230 X=X+1
         .DB $F0,$00,"RETURN",CR                            ; 240 RETURN
         .DB $FA,$00,"PRINT ",$22,"--- LOOP via GOTO ---",$22,CR ; 250 PRINT "--- LOOP via GOTO ---"
         .DB $04,$01,"I=1",CR                               ; 260 I=1
         .DB $0E,$01,"IF I>5 THEN GOTO 310",CR              ; 270 IF I>5 THEN GOTO 310
         .DB $18,$01,"PRINT I",$3B,CR                       ; 280 PRINT I;
         .DB $22,$01,"I=I+1",CR                             ; 290 I=I+1
         .DB $2C,$01,"GOTO 270",CR                          ; 300 GOTO 270
         .DB $36,$01,"PRINT ",$22,$22,CR                    ; 310 PRINT ""
         .DB $40,$01,"PRINT ",$22,"--- NESTED LOOP ---",$22,CR ; 320 PRINT "--- NESTED LOOP ---"
         .DB $4A,$01,"I=1",CR                               ; 330 I=1
         .DB $54,$01,"IF I>3 THEN GOTO 430",CR              ; 340 IF I>3 THEN GOTO 430
         .DB $5E,$01,"J=1",CR                               ; 350 J=1
         .DB $68,$01,"IF J>3 THEN GOTO 400",CR              ; 360 IF J>3 THEN GOTO 400
         .DB $72,$01,"PRINT J",$3B,CR                       ; 370 PRINT J;
         .DB $7C,$01,"J=J+1",CR                             ; 380 J=J+1
         .DB $86,$01,"GOTO 360",CR                          ; 390 GOTO 360
         .DB $90,$01,"PRINT ",$22,$22,CR                    ; 400 PRINT ""
         .DB $9A,$01,"I=I+1",CR                             ; 410 I=I+1
         .DB $A4,$01,"GOTO 340",CR                          ; 420 GOTO 340
         .DB $AE,$01,"REM nested loop done",CR              ; 430 REM nested loop done
         .DB $B8,$01,"PRINT ",$22,"--- TAB / FREE ---",$22,CR ; 440 PRINT "--- TAB / FREE ---"
         .DB $C2,$01,"PRINT ",$22,"col1",$22,$3B,"TAB(3)",$3B,$22,"col2",$22,$3B,"TAB(3)",$3B,$22,"col3",$22,CR ; 450 PRINT "col1";TAB(3);"col2";TAB(3);"col3"
         .DB $CC,$01,"PRINT ",$22,"bytes free:",$22,$3B,"FREE",CR      ; 460 PRINT "bytes free:"; FREE
         .DB $E0,$01,"PRINT ",$22,"--- POKE / PEEK ---",$22,CR ; 480 PRINT "--- POKE / PEEK ---"
         .DB $EA,$01,"POKE 255,170",CR                       ; 490 POKE 255,170
         .DB $F4,$01,"PRINT ",$22,"poked 170, read back ",$22,$3B,"HEX$(PEEK(255))",CR ; 500 PRINT "poked 170, read back ";HEX$(PEEK(255))
         .DB $FE,$01,"PRINT ",$22,"--- RND ---",$22,CR      ; 510 PRINT "--- RND ---"
         .DB $08,$02,"PRINT RND",$3B,$22," ",$22,$3B,"RND",$3B,$22," ",$22,$3B,"RND",$3B,$22," ",$22,$3B,"RND",$3B,$22," ",$22,$3B,"RND",CR ; 520 PRINT RND;" ";RND;" ";RND;" ";RND;" ";RND
         .DB $12,$02,"I=1",CR                               ; 530 I=1
         .DB $1C,$02,"IF I>5 THEN GOTO 600",CR              ; 540 IF I>5 THEN GOTO 600
         .DB $26,$02,"R=RND",CR                             ; 550 R=RND
         .DB $30,$02,"R=R%10",CR                            ; 560 R=R%10
         .DB $3A,$02,"PRINT ",$22,"d",$22,$3B,"R",$3B,$22," ",$22,$3B,CR ; 570 PRINT "d";R;" ";
         .DB $44,$02,"I=I+1",CR                             ; 580 I=I+1
         .DB $4E,$02,"GOTO 540",CR                          ; 590 GOTO 540
         .DB $58,$02,"PRINT ",$22,$22,CR                    ; 600 PRINT ""
         .DB $62,$02,"PRINT ",$22,"--- MANDELBROT ---",$22,CR ; 610 PRINT "--- MANDELBROT ---"
         .DB $6C,$02,"I=-64",CR                             ; 620 I=-64
         .DB $76,$02,"IF I>56 THEN GOTO 860",CR             ; 630 IF I>56 THEN GOTO 860
         .DB $80,$02,"D=I",CR                               ; 640 D=I
         .DB $8A,$02,"C=-120",CR                            ; 650 C=-120
         .DB $94,$02,"IF C>4 THEN GOTO 830",CR              ; 660 IF C>4 THEN GOTO 830
         .DB $9E,$02,"A=C",CR                               ; 670 A=C
         .DB $A8,$02,"B=D",CR                               ; 680 B=D
         .DB $B2,$02,"E=0",CR                               ; 690 E=0
         .DB $BC,$02,"N=1",CR                               ; 700 N=1
         .DB $C6,$02,"IF N>16 THEN GOTO 790",CR             ; 710 IF N>16 THEN GOTO 790
         .DB $D0,$02,"IF E>0 THEN GOTO 770",CR              ; 720 IF E>0 THEN GOTO 770
         .DB $DA,$02,"T=A*A/64-B*B/64+C",CR                 ; 730 T=A*A/64-B*B/64+C
         .DB $E4,$02,"B=2*A*B/64+D",CR                      ; 740 B=2*A*B/64+D
         .DB $EE,$02,"A=T",CR                               ; 750 A=T
         .DB $F8,$02,"IF A*A/64+B*B/64>256 THEN IF E=0 THEN E=N",CR ; 760 IF A*A/64+B*B/64>256 THEN IF E=0 THEN E=N
         .DB $02,$03,"N=N+1",CR                             ; 770 N=N+1
         .DB $0C,$03,"IF N<=16 THEN GOTO 710",CR            ; 780 IF N<=16 THEN GOTO 710
         .DB $16,$03,"IF E>0 THEN PRINT CHR$(E+32)",$3B,CR  ; 790 IF E>0 THEN PRINT CHR$(E+32);
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
; ROM START  ($F800)
         .ORG $F800
; =============================================================================
; STRING TABLE  

; ---- human-readable strings -------------------------------------------------
; Last byte of each string has bit 7 set; PUTSTR masks it before printing.
        .IF KOWALSKI
STR_BANNER: .DB "uBASIC6502 v1.15"  ; startup banner
        .ELSE
STR_BANNER: .DB "JB uBASIC v1.15"  ; startup banner
        .ENDIF
        .DB 0   ; String terminator

; =============================================================================
; UNI_TAB -- unified keyword+dispatch table (4 bytes/entry: 2 raw ASCII
;   keyword chars, (handler-1)_lo, (handler-1)_hi). Two sections, each
;   terminated by a 3-byte $FF sentinel ($FF, (resume-1)_lo, (resume-1)_hi):
;     statement section, offset 0        -- sentinel resumes at DO_LET
;                                            (implicit "X=..." assignment)
;     function section, offset FUNC_TAB_OFF -- sentinel resumes at E2_LIT
;                                            (numeric literal / variable atom)
;   Addresses are stored as (target-1), not target: MATCH_DISPATCH pushes
;   them hi/lo and RTS's.
;   Bit 7 of a keyword's 2nd stored char: set = 1-arg function (its "(expr)"
;   is eaten by MATCH_DISPATCH's EAT_PAREN before the handler runs), clear =
;   statement or 0-arg function. All 2-char prefixes within a section are
;   unique. See MATCH_DISPATCH/MTCHKW for the search+dispatch mechanics.
; =============================================================================
UNI_TAB:
; -- statement section (offset 0) --
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
KW_REM:   .DB "RE"
          .DW DO_REM_CHK-1
KW_END:   .DB "EN"
          .DW DO_END-1
KW_LET:   .DB "LE"
          .DW DO_LET-1
KW_POKE:  .DB "PO"
          .DW DO_POKE-1
KW_DPOKE:  .DB "DP"
          .DW DO_DPOKE-1
          .DB $FF               ; sentinel: no-match -> DO_LET
          .DW DO_LET-1

FUNC_TAB: ; -- function section --
KW_PEEK:  .DB "P",$C5           ; "PE" bit7 set on 'E' -- 1-arg
          .DW DO_PEEK-1
KW_DPEEK: .DB "D",$D0           ; "DP" bit7 set on 'P' -- 1-arg
          .DW DO_DPEEK-1
KW_USR:   .DB "U",$D3           ; "US" bit7 set on 'S' -- 1-arg
          .DW DO_USR-1
KW_ABS:   .DB "A",$C2           ; "AB" bit7 set on 'B' -- 1-arg
          .DW DO_ABS-1
KW_RND:   .DB "RN"              ; 0-arg
          .DW DO_RND-1
KW_FREE:  .DB "FR"              ; 0-arg
          .DW DO_FREE-1
KW_NOT:   .DB "N",$CF           ; "NO" bit7 set on 'O' -- 1-arg
          .DW DO_NOT-1
KW_AND:   .DB "A",$CE           ; "AN" bit7 set on 'N' -- pseudo-1-arg: EAT_PAREN
          .DW DO_AND-1           ; eats '(' + first expr + blindly eats the comma
KW_OR:    .DB "O",$D2           ; "OR" bit7 set on 'R' -- same pseudo-1-arg trick
          .DW DO_OR-1
KW_XOR:   .DB "X",$CF           ; "XO" bit7 set on 'O' -- same pseudo-1-arg trick
          .DW DO_XOR-1
          .DB $FF               ; sentinel: no-match -> E2_LIT
          .DW E2_LIT-1

; ---- Special one-off keywords: NOT part of the dispatch walk above; matched
; directly via a standalone JSR MTCHKW with X = <label>-UNI_TAB (must stay
; within 256 bytes of UNI_TAB -- true here by a wide margin).
KW_THEN:  .DB "TH"
KW_CHRS:  .DB "CH"
KW_TAB:   .DB "TA"
KW_HEX:   .DB "HE"

FUNC_TAB_OFF = FUNC_TAB-UNI_TAB

; =============================================================================
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or Kowalski JMP trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
;
;   Sets up 6522 VIA Port A (PA0=TX output, idles high; PA1-PA7=inputs),
;   clears all zero-page RAM, sets the stack, enables IRQs, initialises PE
;   to PROG (empty program store), prints the banner, then falls into MAIN.
; =============================================================================
INIT:
         LDX #HWSTACK
         TXS                  ; set stack to top of page 1
         CLD                  ; ensure binary (not decimal) mode

         CLI                  ; enable maskable IRQs (Break pushbutton on IRQ pin)
         JSR DO_NEW           ; setup PE and PROG; also (re-)seeds RND_SEED

        .IF KOWALSKI
         ; --- Setup showcase  
         LDA #<SHOWCASE_END   ; point PE at end of pre-loaded showcase program
         STA PE               ; Replace with `JSR DO_NEW` for clean program (ROM)
         LDA #>SHOWCASE_END
         STA PE+1
        .ENDIF

         ; --- 6522 VIA setup: PA0 = TX output, PA1-PA7 = inputs ---
         LDA #VIA_TX          ; DDRA: bit 0 = output, bits 1-7 = input
         STA VIA_DDRA
         LDA #VIA_TX          ; TX line idles HIGH (mark = logic 1)
         STA VIA_ORA

         LDA #<STR_BANNER   ; point PE at end of pre-loaded showcase program
         STA IP               ; Replace with `JSR DO_NEW` for clean program (ROM)
         LDA #>STR_BANNER
         STA IP+1
         JSR DP_STR

         ; delete next 3 lines if really tight on ROM
         JSR DO_FREE          ; Free bytes      
         JSR PRT16            ; print  
         JSR PRNL
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
         JSR DO_END
         JSR GETLINE_M        ; print "> "; read line; set IP = IBUF
         JSR WPEEK            ; skip spaces; peek first non-space char into A
                               ; blank line (CR) falls through to the digit
                               ; check below, fails it, and reaches STMT via
                               ; MAIN_DIR -- STMT's own leading WPEEK/BCC
                               ; guard already no-ops on CR, so a dedicated
                               ; check here would be pure redundancy
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
         JSR WPEEK       ; (3) uppercase input required -- see KNOWN LIMITATIONS
         SEC             ; (1)
         SBC #'A'        ; (2) map 'A'-'Z' to 0-25
         CMP #26         ; (2) sets Carry if out of bounds!
         BCS PV_FAIL     ; (2) 
         ASL             ; (1) double the index for VARS lookup
         JMP BUMP_IP     ; (3) increments IP, leaves Carry clear (C=0)
PV_FAIL:
DO_IN_DN: RTS            ; (1) Carry is naturally 1 here from CMP!

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;
;   In:  -- (entered via IRQ; CPU has pushed PChi, PClo, P)
;   Out: if RUN != 0: unwinds stack, prints BREAK+linenum, jumps to MAIN
;        if RUN == 0: silently RTIs
;   Clobbers: A X  (stack deliberately abandoned when running)
;
;   The John Bell Engineering PN 80-153 6522 VIA IRQ output is NOT connected 
;   to the CPU. So we can wire a Break pushbutton to the IRQ to stop the program. 
;   When idle at the BASIC prompt: RTI silently discards the interrupt.
;   When a program is running: restores SP to RUNSP (unwinding all call
;   frames), then falls into the same DO_ERROR path as any other error
;   (A=ERR_IRQ='6'), which prints "?6@<linenum>" and jumps to MAIN.
; =============================================================================
IRQ_HANDLER:
         LDA RUN              ; is a program running?
         BEQ IRQ_idle         ; no: ignore interrupt
         LDA #ERR_IRQ
         JMP DO_ERROR         ; print "?6@<linenum>\r\n" then jump to MAIN
IRQ_idle:
        RTI

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
         LDA IP+1
         PHA                  ; [S: var_offset, IP_hi]
         LDA IP
         PHA                  ; [S: var_offset, IP_hi, IP_lo]
         JSR GETLINE_I        ; print "? "; read user input; IP = IBUF
         JSR EXPR             ; evaluate expression -> T0
         PLA
         STA IP               ; restore IP
         PLA
         STA IP+1
         JMP STORE_VAR         ; tail call: pop var_offset, store T0, RTS

; =============================================================================
; GETLINE  --  read one line from the terminal into IBUF; set IP = IBUF
;
;   Three entry points sharing one body:
;     GETLINE_M  prints "> " (immediate-mode prompt)
;     GETLINE_I  prints "? " (INPUT statement prompt)
;     GETLINE    no prompt
;
;   In:  --
;   Out: IBUF filled with input, CR-terminated; IP = IBUF
;   Clobbers: A X Y IP T3 T4  (X/T3/T4 via GETCH/PUTCH on the bitbang
;             build; Y is GETLINE's own buffer index)
;
;   Supports backspace (BS) to delete the last character.
;   At IBUF_MAX, further characters are rejected with a BELL (not stored,
;   not echoed, not advanced); backspace still deletes normally from there.
;   After CR is received, outputs CR+LF via PRNL before returning.
; =============================================================================
GETLINE_M:
         LDA #'>'            ; Prompt for multi-line / direct mode
         JSR PUTCH
         BNE GETLINE
GETLINE_I:
         JSR PRTQUEST        ; Prompt for INPUT statement
GETLINE:
         JSR PRTSPACE
         ; Initialize IP pointer to point to IBUF
         LDY #0
         STY IP+1            ; >IBUF is strictly 0 (IBUF is on ZP)
         LDA #<IBUF
         STA IP

GL_BS:   DEY                 ; Backspace: decrement buffer index
         BPL GL_ENTRY        ; Valid index (>= 0), loop back for next char
         INY                 ; Y wrapped from 0 to $FF: clamp back to 0

GL_ENTRY:
         JSR GETCH           ; Read raw key (char in A; Y preserved)
         CMP #CR
         BEQ GL_DONE         ; Line finished
         CMP #BS
         BEQ GL_BSECHO       ; Backspace key pressed
         CPY #IBUF_MAX
         BCS GL_FULL         ; Buffer full: sound bell
         STA IBUF,Y          ; Store char in line buffer (STA abs,Y)
         JSR PUTCH           ; Echo char (clobbers A; Y preserved)
         INY                 ; Advance buffer index
         BPL GL_ENTRY        ; Always taken (Y < 128)

GL_FULL: LDA #BELL           ; Ring bell on buffer overflow
         JSR PUTCH
         BNE GL_ENTRY        ; Always taken (PUTCH leaves Z=0)

GL_BSECHO:
         JSR PUTCH           ; Echo backspace character
         BNE GL_BS           ; Always taken (PUTCH leaves Z=0); decrement index

GL_DONE: STA IBUF,Y          ; Store CR terminator
         JSR PUTCH           ; Echo CR
         JMP PRNL            ; Tail-call print LF / newline and RTS

; =============================================================================
; DELINE  --  remove the line at LP from the program store; adjust PE
;
;   In:  LP -> start of line to delete (the line-number lo byte)
;        PE -> one past the last program byte
;   Out: line removed; PE = new end of program; LP PRESERVED (uses its own
;        T1 destination pointer instead of walking LP itself, so EDITLN's
;        replace path no longer needs to save/restore LP around this call)
;   Clobbers: A Y T0 T1 PE
; =============================================================================
DELINE:
         LDY #2
DL_LL:   LDA (LP),Y           ; scan body + CR
         INY
         CMP #CR
         BNE DL_LL            ; Y now = length of line
         TYA
         CLC
         ADC LP
         STA T0               ; T0.lo = LP.lo + length
         LDA LP+1
         STA T1+1              ; T1.hi = LP.hi (grab it before A is reused)
         ADC #0
         STA T0+1              ; T0.hi = LP.hi + carry (carry survives the
                                ; STA/LDA above -- neither touches it)
         LDA LP
         STA T1                ; T1.lo = LP.lo
         LDY #0
DL_CP:   LDA PE               ; check if we reached PE
         CMP T0
         BNE DL_DO
         LDA PE+1
         CMP T0+1
         BEQ DL_UPD           ; T0 == PE: nothing more to copy
DL_DO:   LDA (T0),Y           ; forward copy: (T0) -> (T1)
         STA (T1),Y
         INC T0               ; advance source
         BNE DL_NX
         INC T0+1
DL_NX:   INC T1               ; advance destination
         BNE DL_CP
         INC T1+1
         BNE DL_CP            ; unconditional (high byte won't wrap to 0)
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
; =============================================================================
EDITLN:
         JSR PNUM             ; parse line number -> T0; IP advances past digits
         JSR T0_TO_CURLN       ; CURLN = T0 (shared tail -- see STORE_VAR)
         JSR PROG2LP
EL_FL:   JSR PE_CMP            ; is LP == PE? (reached end of store); Y=1 after
         BEQ EL_INS            ; yes: insert at end
         LDX #CURLN
         JSR CMP_PLP_X         ; compare *(LP) against CURLN, hi byte first
         BCC EL_SKIP           ; stored line < target: keep scanning
         BEQ EL_FND            ; exact match: delete existing then (re)insert
         BNE EL_INS            ; stored line > target: insert before here (always taken)

EL_SKIP: JSR LSKIP             ; advance LP to next line (shared w/ GOTOL)
         BEQ EL_FL              ; LSKIP's only exit is via CMP #CR -- Z=1 guaranteed

EL_FND:  JSR DELINE            ; delete existing line at LP -- LP preserved
         ; falls through into EL_INS to write the replacement

EL_INS:  JSR WPEEK             ; skip spaces + peek (no consume) first body char
         CMP #CR
         BEQ EL_DN             ; CR only: delete-only (no body to insert)
         ; fall through into INSLINE to insert the body

; =============================================================================
; INSLINE  --  insert one line at LP; body text comes from IP (in IBUF)
;
;   In:  LP -> insertion point in program store
;        IP -> first byte of body text in IBUF (after the line number)
;        CURLN = 16-bit line number to store in the 2-byte header
;        PE -> one past the last current program byte
;   Out: new line written; PE advanced by line size
;   Clobbers: A X Y T0 T1 IP LP PE  (X is new here -- see INSLINE below;
;             confirmed harmless, MAIN reloads X unconditionally right
;             after its own JSR EDITLN, before anything could read it stale)
; =============================================================================
INSLINE:
         LDY #0
IN_CNT:  LDA (IP),Y            ; find body length
         INY
         CMP #CR
         BNE IN_CNT
         INY                   ; +2 for the 2-byte line number header
         INY
         TYA                   ; Y = total line size
         CLC
         ADC PE                ; calculate new PE = PE + total size
         STA T1
         LDA PE+1
         ADC #0
         STA T1+1
         CMP #>RAM_TOP         ; would we cross RAM_TOP?
         BCC IN_OK
         LDA #ERR_OM
         JMP DO_ERROR

IN_OK:   LDX #1                ; T0 = old PE, PE = T1 (new value), one X-indexed
IN_SW:   LDA PE,X               ; loop over both pointers' hi/lo bytes instead
         STA T0,X                ; of two independent LDA/STA*4 blocks -- each
         LDA T1,X                  ; iteration only touches its own indexed byte
         STA PE,X                   ; (PE+1/T0+1/T1+1 then PE/T0/T1), so there's
         DEX                         ; no aliasing between the hi and lo passes
         BPL IN_SW
         LDY #0
         JSR T0_CMP_LP         ; if old PE == LP, nothing to shift upward
         BEQ IN_HDR
IN_BK:   LDA T0                ; pre-decrement source (T0)
         BNE IN_D0
         DEC T0+1
IN_D0:   DEC T0
         LDA T1                ; pre-decrement destination (T1)
         BNE IN_D1
         DEC T1+1
IN_D1:   DEC T1
         LDA (T0),Y            ; backward copy loop
         STA (T1),Y
         JSR T0_CMP_LP         ; stop exactly when T0 == LP
         BNE IN_BK
         ; Y is guaranteed 0 here (from the LDY #0 above; T0_CMP_LP doesn't
         ; touch Y). Write hi byte first via INY, then lo byte via DEY, so Y
         ; lands back on 0 for the body-copy loop below with no reset needed.
IN_HDR:  INY
         LDA CURLN+1           ; write line number hi
         STA (LP),Y
         DEY
         LDA CURLN             ; write line number lo (Y is 0 here)
         STA (LP),Y
         JSR ADD2_LP           ; advance LP by 2 for the payload
IN_CP:   LDA (IP),Y            ; copy payload from IBUF
         STA (LP),Y
         CMP #CR
         BEQ IN_DN
         INY
         BNE IN_CP             ; always taken for bounded line lengths (<256)
DP_RET:
IN_DN:   RTS

; --- DO_NOT -- bitwise complement, 1-arg (T0 already holds the argument via
;     MATCH_DISPATCH's EAT_PAREN, same protocol as DO_ABS/DO_PEEK above).
;     NOT(x) = -(x+1). Increment first (standard INC-wrap-INC pattern,
DO_NOT:
        INC T0
        BNE DN_SK
        INC T0+1
DN_SK:  JMP NEG16

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
         BCS DP_TAB
         JSR E2_PAR           ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         LDA T0
         JSR PUTCH
         BNE DP_AFT            ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional

DP_TAB:  LDX #KW_TAB-UNI_TAB    ; x destroyed so reload 
         JSR MTCHKW           ; matched "TAB"?
         BCS DP_HEX
         JSR E2_PAR           ; Yes it is, Swallow `(`, get value, and swallow closing `)`
	 LDY T0               ; get number of Spaces 
         BMI DP_AFT           ; Ignore negative
DP_TLOOP:	 
    	 BEQ DP_AFT           ; If TAB(0) or loop is zero, skip printing spaces entirely
         JSR PRTSPACE 
         DEY
         BPL DP_TLOOP         ; always taken

DP_HEX:
         LDX #KW_HEX-UNI_TAB
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_NORM
         JSR E2_PAR           ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         JSR PRT_HEX
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

DP_NL:   
PRNL:    LDA #CR
         JSR PUTCH
         LDA #LF
         JMP PUTCH
         
; =============================================================================
; DO_POKE  --  POKE addr, value  :  write one byte to memory
;
;   Syntax: POKE <expr>, <expr>
;   In:  IP -> address expression
;   Out: byte written; IP advanced past statement
;   Clobbers: A X Y T0 T1 T2 T4 IP  (via GET_TWO_ARGS, which parses both
;             expressions -- see its own header)
; =============================================================================
DO_POKE:
         JSR GET_TWO_ARGS      ; T4 = address, T0 = value
         LDA T0                ; value byte, ignore High byte
         LDY #0
         STA (T4),Y            ; write value to address
; PUTSTR (end-of-string path) both want a plain RTS here.
PS_DN:   RTS

; =============================================================================
; DO_REM_CHK  --  REM <comment>  or  RETURN
;
;   In:  IP -> comment text (REM), or nothing (RETURN); LP -> keyword's
;        pre-match start, same (LP),Y=2 peek as DO_GO
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: REM: no-op.  RETURN: pops the frame pushed by the matching GOSUB
;        and resumes execution there.
;   Clobbers: A X (RETURN also: Y IP CURLN SP)
;
;   3rd char 'T' selects RETURN ("RE" + T, uppercase required -- see KNOWN
;   LIMITATIONS); anything else -- including the full word "REM" -- falls
;   through as a no-op.
; =============================================================================
DO_REM_CHK:
         LDY #2
         LDA (LP),Y
         CMP #'T'
         BNE PS_DN            ; not RETURN: REM is a no-op

         ; fall through into DO_RETURN:
         LDX GOSUB_SP
         CPX #GOSUB_TOP       ; stack empty (nothing was ever pushed)?
         BEQ DO_ERR_GS           ; Branch on empty straight to error exit

         LDY #0
POP_LP:  INX
         LDA 0,X
         STA IP,Y             ; Y=0,1,2,3 -> IP, IP+1, CURLN, CURLN+1
         INY
         CPY #4
         BNE POP_LP

         STX GOSUB_SP

         PLA                  ; discard the one JSR-STMT return address that's
         PLA                  ; always on the stack at this point (see DO_GO)
         JMP SK_LP            ; advance to the next line

; --- Pooled Error Handlers ---
DO_ERR_OM:  LDA #ERR_OM          ; Out of memory
         .byte $2C            ; [OPT] The BIT trick: Assembles as BIT $A9xx
DO_ERR_UL:  LDA #ERR_UL          ; (Assembled as A9 <ERR_UL>).
         .byte $2C            ;  The BIT trick: Assembles as BIT $A9xx
DO_ERR_GS:  LDA #ERR_RET         ; RETURN without GOSUB
         JMP DO_ERROR

; =============================================================================
; DO_GO  --  GOTO <linenum>  or  GOSUB <linenum>
;
;   In:  IP -> line number digits; LP -> keyword's pre-match start (MTCHKW's
;        contract), so (LP),Y with Y=2 peeks the keyword's 3rd raw character
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: GOTO:  IP = body of target line; stack unwound to RUNSP; RUNGO
;        GOSUB: return frame pushed, then as GOTO
;   Clobbers: A X Y T0 IP SP CURLN  (CURLN via GOTOL on a successful lookup)
;
;   3rd char 'S' selects GOSUB (uppercase required -- see KNOWN LIMITATIONS);
;   anything else -- including the full word "GOTO" -- falls through as
;   plain GOTO.
; =============================================================================
DO_GO:
         LDY #2
         LDA (LP),Y
         CMP #'S'             ; Sets the Z flag if it's 'S' (GOSUB), clears if not (GOTO)

         PHP                  ; [OPT] Save the Zero flag state to the hardware stack
         JSR EXPR             ; Parse target line number -> T0 (LP no longer needed)
         PLP                  ; [OPT] Restore the Zero flag state

         BNE GO_DO            ; [OPT] If Z flag is clear (not 'S'), skip GOSUB setup

         ; --- GOSUB Frame Setup Loop ---
         LDX GOSUB_SP
         CPX #GOSUB_FULL      ; room for a full 4-byte frame?
         BCC DO_ERR_OM        ; Branch on Carry Clear (X < GOSUB_FULL)

         LDY #3               ; Start at index 3 (pointing to CURLN+1)
PUSH_LP: LDA IP,Y             ; Reads CURLN+1, CURLN, IP+1, IP in that order
         STA 0,X              ; Push to zero-page stack
         DEX                  ; Decrement stack pointer
         DEY                  ; Decrement source index
         BPL PUSH_LP          ; Loop until Y goes negative ($FF)

         STX GOSUB_SP         ; Save updated stack pointer
         ; falls through to GO_DO

GO_DO:   JSR GOTOL            ; find line: C=0 found, C=1 not found
         BCS DO_ERR_UL        ; Branch on Carry Set to shared error exit

         PLA                  ; discard the one JSR-STMT return address --
         PLA                  ; STMT is always reached via exactly one JSR,
                               ; whether from RUNGO or MAIN_DIR (see DO_GO
                               ; header) -- so this always lands exactly back
                               ; at that caller's own stack depth
         JMP RUNGO            ; jump into run loop

; =============================================================================
; DO_LIST  --  LIST [n,m]  :  print program lines, optional range
;
;   In:  IP -> optional "n,m" range digits, or CR/end-of-statement for
;        "list everything"
;   Out: matching lines printed to terminal; IP advanced past the statement
;   Clobbers: A X Y T0 T1 T2 T4 IP LP  (T4/T0/T1/T2 via GET_TWO_ARGS when a
;             range is given; X also via PROG2LP)
;
;   Peeks each line's header via LP without consuming (matches GOTOL's
;   convention) so the skip-path can reuse the shared LSKIP routine; only
;   advances LP past the header when a line is actually going to be printed.
; =============================================================================
DO_LIST:
         LDA #0                 ; T1 is default low bound of zero
         STA T1
         STA T1+1
         STA T4                 ; default high bound is $7f00 in T4
         LDA #$7F
         STA T4+1
         JSR WPEEK
         CMP #CR+1              ; check for CR
         BCC LS_SCAN            ; wide range 
         JSR GET_TWO_ARGS      ; T4 = n (lo-bound), T0 = m (hi-bound)
         LDA T4                ; T1 = lo-bound (read T4 before it's reused below)
         STA T1
         LDA T4+1
         STA T1+1
         LDA T0                ; T4 now is hi-bound
         STA T4
         LDA T0+1
         STA T4+1
LS_SCAN: JSR PROG2LP
LS_LN:   JSR PE_CMP            ; Y=1 on return (side effect)
         BEQ LS_DONE
         LDA (LP),Y            ; peek line number hi (Y=1 already)
         STA T0+1
         DEY
         LDA (LP),Y            ; peek line number lo
         STA T0
         LDA T4                ; stop if current > hi-bound
         CMP T0
         LDA T4+1
         SBC T0+1
         BCC LS_DONE
         LDA T0                ; skip if current < lo-bound
         CMP T1
         LDA T0+1
         SBC T1+1
         BCC LS_SKIP
         JSR PRT16             ; in range: print it
         JSR PRTSPACE
         JSR ADD2_LP            ; advance LP past the 2-byte header for the body walk
LS_BODY: JSR BUMP_LP            ; A = char at LP, pre-advance (see BUMP_LP)
         CMP #CR
         BEQ LS_EOL
         JSR PUTCH
         BNE LS_BODY             ; PUTCH always leaves Z=0 (see DP_STR): unconditional

LS_EOL:  JSR PRNL
         BNE LS_LN               ; PRNL tail-calls PUTCH -- same Z=0 guarantee

LS_SKIP: JSR LSKIP              ; LP still at header start -- matches LSKIP's contract
         BEQ LS_LN               ; LSKIP's only exit is via CMP #CR -- Z=1 guaranteed

; =============================================================================
; ADD2_LP  --  LP += 2 (shared by INSLINE and DO_LIST, skip a 2-byte header)
;
;   In:  LP
;   Out: LP advanced by 2
;   Clobbers: LP  (the documented Out: change; no registers touched)
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: LDY #0
         LDA (LP),Y            ; A = *LP before advancing (like GETCI) --
         INC LP                ; LSKIP and DO_LIST's LS_BODY both rely on
         BNE BUMP_RTS          ; this fetch instead of doing their own
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
;   Out: Z=1 if LP == PE, Z=0 otherwise; Y=1 (side effect -- EDITLN, GOTOL,
;        and DO_LIST all need Y=1 right after this returns, either directly
;        or via CMP_PLP_X below, so it's set here for free)
;   Clobbers: A Y
; =============================================================================
PE_CMP:  LDY #1
         LDA LP
         CMP PE
         BNE PC_NE
         LDA LP+1
         CMP PE+1
PC_NE:   RTS

; =============================================================================
; CMP_PLP_X  --  compare *(LP) against the 16-bit ZP pair at address X
;
;   In:  X = zero-page address of the pair to compare against (e.g. #T0 or
;        #CURLN, used via 0,X/1,X indexed addressing); Y=1 (PE_CMP leaves
;        it that way -- see above)
;   Out: Z=1 if equal; C set/clear per unsigned 16-bit compare, hi byte first
;   Clobbers: A Y
; =============================================================================
CMP_PLP_X:
         LDA (LP),Y            ; Y=1: hi byte of *(LP)
         CMP 1,X
         BNE CPX_DN
         DEY                   ; Y=0
         LDA (LP),Y            ; lo byte of *(LP)
         CMP 0,X
CPX_DN:  RTS

; =============================================================================
; LSKIP  --  advance LP past the current line (shared by EDITLN, GOTOL)
;
;   In:  LP -> start of a line's 2-byte header
;   Out: LP -> start of the next line (past this line's CR terminator)
;   Clobbers: A Y LP
; =============================================================================
LSKIP:   JSR ADD2_LP    ; Skip the 2-byte line number header
LSK_LP:  JSR BUMP_LP    ; Advance LP; A = char that was there (pre-advance)
         CMP #CR        ; was it a CR?
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
; DO_RUN  --  RUN  :  execute program starting from the first line
;
;   In:  PE = current program end
;   Out: program executes; returns to MAIN on END/error/STOP
;   Clobbers: A X Y T0 T1 T2 IP SP RUN CURLN
;
;   RUNLP: top of the per-line execution loop.
;   RUNGO: mid-loop entry used by GOTO (after IP is already set to body).
; =============================================================================
DO_RUN:
         LDX #0
         JSR PROG2X
         LDA #$FF
         STA RUN              ; set run flag ($FF = running)
RUNLP:   LDA IP               ; test IP >= PE (16-bit unsigned)
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

         LDA #$E1              ; nonzero LFSR seed ($ACE1 -- an all-zero seed
         STA RND_SEED          ; is a fixed point for a Galois LFSR and would
         LDA #$AC              ; make RND return 0 forever; re-seed here so
         STA RND_SEED+1        ; every NEW (not just boot) leaves RND usable

         LDX #4
         JSR PROG2X            ; PE = PROG

         LDA #GOSUB_TOP
         STA GOSUB_SP          ; empty call stack (immediate-mode GOSUB unwind)

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
; MTCHKW  --  match a 2-char keyword prefix at IP against UNI_TAB entry X
;             (case-sensitive -- uppercase input is required, see KNOWN
;             LIMITATIONS), then consumes any further trailing letters/'$'.
;
;   In:  X = byte offset of the keyword entry within UNI_TAB (its first two
;        bytes are the raw keyword chars -- see KW_PEEK/KW_ABS/etc; the
;        special one-off keywords KW_THEN/CHRS/TAB are matched the same way,
;        X = <label>-UNI_TAB)
;   Out: match:    C=0, IP advanced past the keyword, N = bit7 of the
;                  entry's 2nd stored char (the 1-arg flag -- see
;                  KW_PEEK/KW_USR/KW_ABS) -- MATCH_DISPATCH tests BPL/BMI.
;                  X unchanged.
;        no match: C=1, IP restored to entry value, X unchanged, N/Z
;                  undefined -- check carry first, always.
;   Clobbers: A Y T1  (T2 is NOT clobbered -- caller may hold a jump target)
;
;   IP is saved in LP on entry and restored on failure. Shares its fail exit
;   (MK_FAIL/MK_SEC) and success exit (GT_R) with GOTOL -- do not rename.
; =============================================================================
MTCHKW:
         LDA IP
         STA LP               ; save IP in LP for restore on failure
         LDA IP+1
         STA LP+1

         ; compare first keyword character (direct against UNI_TAB,X)
         JSR WPEEK
         CMP UNI_TAB,X
         BNE MK_FAIL
         JSR GETCI

         ; compare second keyword character (bit7 may carry the 1-arg flag)
         LDA UNI_TAB+1,X
         STA T1               ; stash raw byte -- becomes the N-flag return below
         AND #$7F
         STA T1+1
         LDA (IP),Y
         CMP T1+1
         BNE MK_FAIL
         JSR GETCI

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
MK_RTS:  LDA T1               ; N = bit7 of raw 2nd keyword char (1-arg flag)
         CLC                  ; N flag survives CLC untouched (inline saves 2 bytes)
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
GT_SC:   JSR PE_CMP           ; test LP == PE (end of store); Y=1 after
         BEQ MK_FAIL          ; *CHANGED from MK_SEC* (see note below)
         LDX #T0
         JSR CMP_PLP_X        ; compare *(LP) against T0, hi byte first
         BEQ GT_OK
GT_NX:   JSR LSKIP            ; advance LP to next line
         BEQ GT_SC            ; LSKIP's only exit is via CMP #CR -- Z=1 guaranteed

GT_OK:   JSR T0_TO_CURLN       ; CURLN = T0 (T0 already == the matched line number)
         JSR ADD2_LP          ; LP += 2, past the 2-byte header
         CLC                  ; C=0: found
COPY_LP_IP:
         LDA LP               ; IP = LP (Carry flag passes through these unchanged)
         STA IP
         LDA LP+1
         STA IP+1
         RTS                  ; Exit with C=0 (from GT_OK) or C=1 (from MK_FAIL)

; =============================================================================
; GET_TWO_ARGS  --  shared helper: parse "expr,expr"
;
;   In:  IP -> first expression text
;   Out: T4 = first arg value, T0 = second arg value, IP advanced past both
;   Clobbers: A X Y T0 T1 T2 T4 IP  (same as EXPR/EAT_EXPR, which do the
;             actual parsing)
; =============================================================================
GET_TWO_ARGS:
         JSR EXPR              ; first arg -> T0
         LDA T0
         STA T4
         LDA T0+1
         STA T4+1
        ; drop through
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
; EXPR  --  evaluate expression including relational operators (bitmask design)
;
;   In:  IP -> expression text
;   Out: T0 = signed 16-bit result; true=$FFFF, false=$0000
;        IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 T3 IP
;
;   Operator bitmask built in X: LT=1  EQ=2  GT=4
;   Signed comparison uses the N XOR V trick (BVC / EOR #$80 / BMI) so no
;   65C02 opcodes are needed and the NMOS 6502 target is fully respected.
; =============================================================================
EXPR:
         JSR EXPR_ADD         ; evaluate left operand -> T0

         ; Save left on hardware stack
         LDA T0
         PHA
         LDA T0+1
         PHA

         ; Scan relational operator chars, building bitmask in X
         LDX #0               ; mask = 0 (no relop seen yet)
RL_LOOP: JSR WPEEK            ; A = next char
         SEC
         SBC #'<'             ; Map <, =, > to 0, 1, 2
         CMP #3               ; Bounds check (if < 0 or >= 3, Carry will be set!)
         BCS RL_DONE          ; Not a relational operator -> exit loop
         TAY                  ; Y = 0, 1, or 2
         TXA                  ; Pull accumulated mask so far
         ;ORA REL_MASK,Y       ; Apply new bit
         .DB $19, <REL_MASK, >REL_MASK  ; kludge
         TAX
         JSR GETCI            ; Consume operator (always returns A=$3C, $3D, or $3E)
         BNE RL_LOOP          ; BNE always branches (A is never zero)

RL_DONE: CPX #0               ; any relational operator found?
         BEQ RL_NONE          ; no: return left operand as-is

         ; Push mask, evaluate right operand, restore everything
         TXA                  ; mask -> A
         PHA                  ; push mask onto stack
         JSR EXPR_ADD         ; right operand -> T0
         PLA                  ; pop mask
         STA T3               ; stash mask in T3 (idle here, no calls before use)
         PLA                  ; left hi (pushed second, pops first)
         STA T1+1
         PLA                  ; left lo
         STA T1               ; T1 = left operand, T0 = right operand

         ; --- Classify T1 vs T0 as LT(1) / EQ(2) / GT(4) into A ---

         ; Check equality first (cheaper than subtract)
         LDA T1
         CMP T0
         BNE RL_NOT_EQ
         LDA T1+1
         CMP T0+1
         BNE RL_NOT_EQ
         LDA #2               ; EQ
         BNE RL_TEST          ; always taken (A=2 != 0)

RL_NOT_EQ:
         ; 16-bit signed subtract T1 - T0; use N XOR V to detect less-than
         LDA T1
         SEC
         SBC T0
         LDA T1+1
         SBC T0+1             ; N and V now reflect signed T1 - T0
         ; N XOR V = 1 means T1 < T0 (signed).
         ; Trick: if V set, flip bit 7 of result so BMI always means "less-than".
         BVC RL_NO_FLIP
         EOR #$80             ; flip N when V set
RL_NO_FLIP:
         BMI RL_IS_LT
         LDA #4               ; GT
         BNE RL_TEST          ; always taken
RL_IS_LT:
         LDA #1               ; LT

RL_TEST: AND T3               ; result bit AND operator mask
         BEQ REL_F            ; zero: A already 0, skip straight to REL_F
         LDA #$FF             ; non-zero: true
REL_F:   STA T0
         STA T0+1
         RTS

RL_NONE: ; No relop found: discard the stacked copy of left (T0 already correct)
         PLA                  ; discard saved T0+1
         PLA                  ; discard saved T0
         RTS
REL_MASK: .DB 1, 2, 4         ; Mask tab

; =============================================================================
; EXPR_ADD  --  additive level: + and -
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP
;
;   v1.1 BUG FIX: EA_DO now saves operator via TAX before loading T0 bytes.
;   v1.0 used LDX T0+1/TXA/PHA then LDX T0/TXA/PHA then PHA -- but after
;   "LDX T0 / TXA", A = T0-lo, so the final PHA pushed T0-lo a second time
;   and the operator character was never saved.  This caused wrong results
;   for any subtraction expression (e.g. 10-3 returned garbage).
; =============================================================================
EXPR_ADD:
         JSR EXPR1            ; evaluate first term -> T0
EA_LP:   JSR WPEEK
         CMP #'+'
         BEQ EA_DO
         CMP #'-'
         BNE EA_RTS           ; not + or -: done
EA_DO:   TAX                  ; v1.1 FIX: save operator in X BEFORE clobbering A
         LDA T0+1
         PHA                  ; push T0 hi
         LDA T0
         PHA                  ; push T0 lo
         TXA
         PHA                  ; push operator (recovered from X)
         JSR GETCI            ; consume operator
         JSR EXPR1            ; evaluate next term -> T0
         PLA                  ; pull operator
         CMP #'-'
         BNE EA_SUM
         JSR NEG16            ; subtraction: negate the right operand
EA_SUM:  CLC
         PLA                  ; pull old T0 lo
         ADC T0
         STA T0
         PLA                  ; pull old T0 hi
         ADC T0+1
         STA T0+1
         JMP EA_LP

; =============================================================================
; EXPR1  --  multiplicative level: * / %  (merged MUL/DIV/MOD kernel)
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced
;   Clobbers: A X Y T0 T1 T2 T3 IP
;
;   The operator ('*', '/', or '%') is held on the hardware stack across
;   the recursive right-operand evaluation (JSR EXPR2), then popped into
;   T3, so a single sign-correction preamble and postamble serves all
;   three operations.  '/' and '%' both use the DIV kernel; they differ
;   only in which of quotient (T1) or remainder (T2) is copied to T0 as
;   the result.
;
;   v1.11 FIX: operator used to be stashed directly in a fixed ZP byte
;   (OP) before the recursive call, which a parenthesized sub-expression
;   containing another */,/,% would silently clobber (e.g. "2*(10/5)"
;   ran as division). Now preserved on the hardware stack instead, which
;   is recursion-safe, and the OP byte has been removed entirely.
; =============================================================================
EXPR1:
         JSR EXPR2
E1_LP:   JSR WPEEK
         CMP #'*'
         BEQ E1_MD
         CMP #'/'
         BEQ E1_MD
         CMP #'%'
         BEQ E1_MD
; Shared by EXPR_ADD and EXPR1.
EA_RTS:  RTS

; --- DIV kernel ---------------------------------------------------------------
;   In:  T1 = dividend (positive), T0 = divisor (positive), Y = 16, T2 = 0
;   Out: T1 = quotient, T2 = remainder  (caller selects which to return in T0)
; -----------------------------------------------------------------------------
E1_DO_DIV:
E1_DB:   ASL T1               ; shift dividend left into T2 (shift-subtract method)
         ROL T1+1
         ROL T2
         ROL T2+1
         LDA T2
         SEC
         SBC T0
         TAX
         LDA T2+1
         SBC T0+1
         BCC E1_DS            ; remainder < divisor: quotient bit = 0
         STX T2
         STA T2+1
         INC T1               ; quotient bit = 1
E1_DS:   DEY
         BNE E1_DB
         LDA T3               ; MOD ('%'): use remainder in T2; else quotient T1
         CMP #'%'
         BEQ E1_MOD
         LDX #2               ; quotient offset: T1 is T0+2
         .DB $2C              ; BIT abs -- swallows the LDX #4 below as its
                               ; operand (skips it without a branch)
E1_MOD:  LDX #4               ; remainder offset: T2 is T0+4
E1_COPY: LDA T0,X             ; copy quotient (X=2) or remainder (X=4) to T0
         STA T0
         LDA T0+1,X
         STA T0+1
         JMP E1_SIGN

; --- MUL/DIV dispatch (operator fetch, sign determination, kernel select) ----
;   v1.11 FIX: operator is pushed on the hardware stack (not stashed in a
;   fixed ZP byte) across the JSR EXPR2 below, because EXPR2 can recurse
;   back into EXPR1 for a parenthesized sub-expression containing another
;   */,/,% -- a fixed-byte stash would get clobbered by that inner call
;   (e.g. "2*(10/5)" silently ran as division). Popped into T3 once the
;   recursive call is done and it's safe to hold a scratch value again.
E1_MD:   PHA                  ; save operator on hw stack (survives recursion)
         JSR GETCI            ; consume operator
         LDA T0               ; push left operand (will become T1)
         PHA
         LDA T0+1
         PHA
         JSR EXPR2            ; right operand -> T0
         PLA
         STA T1+1
         PLA
         STA T1
         PLA
         STA T3               ; pop operator into scratch (T3 idle here); A still holds it
         CMP #'*'             ; zero-div check for '/' and '%' (not '*')
         BEQ E1_NOCHK
         LDA T0               ; division/mod: check for zero divisor
         ORA T0+1
         BEQ E1_OVFL
E1_NOCHK:
         LDA T1+1
         EOR T0+1
         PHA                  ; push result sign (XOR of hi-bytes)
         LDA T1+1             ; make T1 positive
         BPL E1_P1
         JSR NEG_T1
E1_P1:   LDA T0+1             ; make T0 positive
         BPL E1_P2
         JSR NEG16
E1_P2:   LDA #0
         STA T2
         STA T2+1
         LDY #16
         LDA T3
         CMP #'*'             ; dispatch: '*' -> MUL; '/' or '%' -> DIV
         BNE E1_DO_DIV
         ; --- MUL kernel: T2 = T1 * T0 (shift-and-add) ----------------------
E1_MB:   LSR T1+1
         ROR T1
         BCC E1_MS
         LDA T2
         CLC
         ADC T0
         STA T2
         LDA T2+1
         ADC T0+1
         STA T2+1
E1_MS:   ASL T0
         ROL T0+1
         DEY
         BNE E1_MB
         LDX #4               ; product is in T2 (T0+4) -- reuse E1_COPY's
         JMP E1_COPY           ; T0,X copy-and-JMP-E1_SIGN tail

; --- sign postamble: apply XOR sign to T0 ------------------------------------
E1_SIGN: PLA                  ; pull result sign
         BPL E1_POS           ; positive: done
         JSR NEG16            ; negative: negate T0
E1_POS:  JMP E1_LP            ; loop: check for another * or /

E1_OVFL: LDA #ERR_OV          ; division or modulo by zero
         ; fall through into DO_ERROR

; =============================================================================
; DO_ERROR  --  print error message and return to immediate mode
;
;   In:  A = ERR_xx code (0-4)
;   Out: never returns to caller; jumps to MAIN
;   Clobbers: everything
;
;   Prints:  CR+LF  "?N"  ["@<linenum>"]  CR+LF  then jumps to MAIN.
;   The "@<linenum>" annotation is only printed when RUN != 0.
;   IRQ_HANDLER (BREAK) also lands here: JMP DO_ERROR with A=ERR_IRQ.
;   RUN is still nonzero at that point, so BREAK prints "?6@<linenum>" --
;   same generic path as any other error, no separate wording.
; =============================================================================
DO_ERROR:
         PHA                  ; save error code
         JSR PRNL             ; CR+LF before error message
         JSR PRTQUEST
         PLA
         JSR PUTCH            ; print "?N"
         LDA RUN
         BEQ DO_ERR_NL        ; not running: omit "@<line>" annotation
         LDA #'@'
         JSR PUTCH           ; print "@"
         LDA CURLN
         STA T0
         LDA CURLN+1
         STA T0+1
         JSR PRT16            ; print line number
DO_ERR_NL:
         JSR PRNL             ; CR+LF after error message
         JMP MAIN
         
; --- DO_PEEK/DO_DPEEK/DO_USR/DO_RND/DO_FREE/DO_ABS -- UNI_TAB function-
;     section handlers. Paren-eating for the 1-arg ones (PEEK/DPEEK/USR/ABS)
;     is done by MATCH_DISPATCH's EAT_PAREN before entry -- T0 already holds
;     the parsed argument on entry, and the handler does NOT re-consume it.
;     DO_RND falls through into RND_SHUFFLE (also JSR'd directly by GETCH);
;     DO_FREE is also JSR'd directly by INIT.
DO_PEEK: LDY #0                  ; T0 = *T0 (byte at address in T0)
         LDA (T0),Y
         STA T0
         STY T0+1                ; clear high byte
         RTS

; =============================================================================
; DO_DPEEK  --  DPEEK(addr)  :  read a 16-bit value from memory
;
;   In:  T0 = address (parsed by MATCH_DISPATCH's EAT_PAREN, same 1-arg
;        convention as DO_PEEK above -- T0 already holds the argument)
;   Out: T0 = 16-bit value at [addr] (lo byte), [addr+1] (hi byte)
;   Clobbers: A X Y
;
;   NMOS has no index-free (zp) mode, so unlike a 65C02 version this can't
;   read the lo byte with a bare LDA (T0) -- do the hi byte first into X
;   while Y=1, then DEY for the lo byte, matching GETCI/BUMP_LP's existing
;   "hi read, then lo" convention elsewhere in this file.
; =============================================================================
DO_DPEEK: LDY #1
         LDA (T0),Y              ; hi byte
         TAX
         DEY
         LDA (T0),Y              ; lo byte
         STA T0
         STX T0+1
         RTS

DO_USR:  JMP (T0)                ; jump to address in T0; fingers crossed
                                  ; caller returns with retval in T0

DO_RND:  LDA RND_SEED            ; LDA/STA don't touch Carry -- safe before BCC
         STA T0
         LDA RND_SEED+1          ; LDA/STA don't touch Carry -- safe before BCC
         AND #$7F                ; force positive (clear bit 15) for T0
         STA T0+1
        ; drop through
; =============================================================================
;   16-bit Galois LFSR in RND_SEED, tap $B4 (x^16+x^14+x^13+x^11+1),
;   Clobbers A, Shuffles on every call

RND_SHUFFLE:
         LSR RND_SEED+1       ; shift hi byte right, MSB = 0
         ROR RND_SEED         ; shift lo byte right, MSB = old hi bit 0
         LDA RND_SEED+1       ; Carry from the LSR above is still intact
         BCC E2_RND_SK        ; no bit fell out: skip the feedback tap
         EOR #$B4             ; apply feedback tap
         STA RND_SEED+1       ; update the seed in memory
E2_RND_SK:
         RTS                   ; end of RND

DO_FREE: SEC                  ; T0 = RAM_TOP - PE (free program-store bytes)
         LDA #<RAM_TOP
         SBC PE
         STA T0
         LDA #>RAM_TOP
         SBC PE+1
         STA T0+1
         RTS                    ; end of FREE

DO_ABS:  LDA T0+1               ; check high byte
         BMI NEG16              ; It is Negative so negate
         RTS                    ; otherwise return

; =============================================================================
; BITOP2_PREFIX / DO_AND / DO_OR / DO_XOR  --  2-arg bitwise functions
;
;   AND(a,b), OR(a,b), XOR(a,b). Reuses MATCH_DISPATCH's existing 1-arg
;   EAT_PAREN to eat clsoing ')'.  BITOP2_PREFIX then
;   pushes that first arg (and an op selector) on the stack across the
;   second parse, then a single shared loop combines both bytes.
;
;   In:  T0 = first arg (via EAT_PAREN); IP -> second expr, then ')'
;   Out: T0 = combined result; IP advanced past ')'
;   Clobbers: A X Y T0 IP
;
;   DO_AND/DO_OR/DO_XOR chain into BITOP2_PREFIX via three BIT-trick skips
;
;   BITOP_LP then processes hi byte (offset 1) then lo byte (offset 0) of
;   both operands, selecting AND/OR/XOR per Y via the same three-way
;   BIT-trick chain used for entry. Byte offset is in X (not Y) specifically
;   because T0,X has a real 2-byte zero-page,X encoding for AND/ORA/EOR/STA
; =============================================================================
DO_AND:  LDY #0               ; op 0 = AND
         .DB $2C              ; BIT abs: swallows DO_OR's LDY #1 (2 bytes)
DO_OR:   LDY #1               ; op 1 = OR
         .DB $2C              ; BIT abs: swallows DO_XOR's LDY #2 (2 bytes)
DO_XOR:  LDY #2               ; op 2 = XOR
         ; falls into BITOP2_PREFIX

BITOP2_PREFIX:
         LDA T0
         PHA                   ; push 1st arg lo
         LDA T0+1
         PHA                    ; push 1st arg hi
         TYA
         PHA                     ; push op selector
         JSR EXPR                 ; second arg -> T0
         JSR WEAT                  ; eat the REAL closing ')'
         PLA
         TAY                       ; restore op selector -> Y
         LDX #1                    ; X = byte offset: 1 (hi) then 0 (lo)
BITOP_LP:
         PLA                       ; pull 1st arg byte (hi first, then lo)
         CPY #1
         BCC BO_A                  ; Y=0 -> AND
         BEQ BO_O                   ; Y=1 -> OR
         EOR T0,X                    ; Y=2 -> XOR (2-byte zp,X, verified)
         .DB $2C                     ; BIT abs: swallows BO_A's AND T0,X
BO_A:    AND T0,X
         .DB $2C                     ; BIT abs: swallows BO_O's ORA T0,X
BO_O:    ORA T0,X
         STA T0,X
         DEX
         BPL BITOP_LP
         RTS

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
        ; drop through
; =============================================================================
; NEG_T1 / NEG16  --  two's-complement negate
;
;   NEG_T1:  negate T1 ($08/$09) -- enter here from EXPR1 sign correction
;   NEG16:   negate T0 ($06/$07) -- enter here from all other callers
;
;   In:  T0 or T1 = value to negate (selected by entry point)
;   Out: value negated in-place
;   Clobbers: A X
; =============================================================================
NEG16:   LDX #0
         .DB $2C              ; BIT abs: skips next 2 bytes (the LDX #0)
NEG_T1:  LDX #2
         LDA #0
         SEC
         SBC T0,X
         STA T0,X
         LDA #0
         SBC T0+1,X
         STA T0+1,X
         RTS

; =============================================================================
; Back to Expression 2 parsing - try number, hex literal, or var
E2_LIT: 
         LDY #0
         LDA (IP),Y           ; peek next char without consuming
         CMP #'$'
         BNE E2_DEC            ; not hex prefix
         JSR GETCI             ; consume '$'
         JMP PHEX               ; unified with PNUM (radix in T1)

E2_DEC:  CMP #'0'
         BCC E2_VAR
         CMP #'9'+1
         BCS E2_VAR
         ; drop through

; =============================================================================
; PNUM / PHEX  --  parse decimal or hex integer from ASCII at IP into T0
;
;   In:  IP -> ASCII digits. Leading spaces are NOT skipped here -- both
;        callers already guarantee IP is past them: EDITLN's caller (MAIN)
;        does JSR WPEEK before calling EDITLN, and E2_LIT's caller (EXPR2)
;        does JSR WPEEK before dispatching here. Verified by tracing both
;        call chains, not assumed.
;   Out: T0 = parsed value; IP advanced past the last digit
;   Clobbers: A X Y T0 T1 T2 T3  (T1 now holds the radix: 10 or 16 -- fine,
;        EDITLN/INSLINE's own headers already list T1 as clobbered, and
;        nothing in the EXPR recursion relies on T1 surviving a nested call)
;   Stops at the first digit invalid for the radix, without consuming it.
;   PHEX is reached via JMP from E2_LIT (after '$' already consumed) --
;   its own RTS returns to E2_LIT's caller (tail-call chain).
;   NOTE: hex digits accumulate via the same radix-iteration add loop as
;   decimal (up to 16 iterations per digit) rather than a 4-shift multiply
;   -- smaller code, but a hex literal re-parsed inside a tight loop pays
;   ~4x the cycles per digit vs a shift-based implementation would.
; =============================================================================
PNUM:
         LDA #10
         .DB $2C               ; BIT abs -- swallows PHEX's LDA #16 as its
                                ; operand (skips it without a branch)
PHEX:    LDA #16
         STA T1                ; save radix (10 or 16)
         LDY #0                ; Y stays 0 for the whole routine
         STY T0                ; clear result lo
         STY T0+1              ; clear result hi
PN_LP:   LDA (IP),Y            ; peek without consuming
         SEC
         SBC #'0'              ; '0'-'9'->0-9, ':'-'@'->10-16 (gap), 'A'-'F'->17-22
         CMP #10
         BCC PN_OK              ; 0-9: value already correct
         CMP #17
         BCC PN_DN               ; 10-16: gap chars, not a digit -- done
         CMP #23
         BCS PN_DN                ; >=23 (incl. wrapped chars before '0'): done
         SBC #6                    ; Carry is clear here (fell through the
                                    ; CMP #23 above): 'A'-'F' (17-22)-7 = 10-15
PN_OK:   CMP T1                     ; reject digits >= radix (e.g. A-F when
         BCS PN_DN                   ; parsing decimal)
         STA T2                     ; seed running sum lo with digit
         STY T3                     ; seed running sum hi with 0
         LDX T1                     ; T2:T3 = digit + radix*T0
         ; Carry is clear here (from CMP T1/BCS above not being taken)
PN_ML:   LDA T2
         ADC T0
         STA T2
         LDA T3
         ADC T0+1
         STA T3
         DEX
         BNE PN_ML

         LDA T2
         STA T0
         LDA T3
         STA T0+1

         JSR GETCI              ; consume digit char, advances IP 16-bit
         BNE PN_LP               ; guaranteed to branch since A != 0

E2_BAD:  JMP REL_F

E2_VAR:  JSR PARSE_VAR               ; variable name (single letter A-Z)?
	 BCS E2_BAD
         TAX
         LDA VARS,X
         STA T0
         LDA VARS+1,X
         STA T0+1
PN_DN:
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
E2_NOTPAR:
         CMP #'-'
         BNE E2_NOTNEG
         JMP E2_NEG            ; out of short-branch range from here
E2_NOTNEG:
         CMP #'+'
         BEQ E2_POS

        ; function matching (CHR$ excluded -- PRINT-only, see DP_CHR) via
        ; the shared UNI_TAB/MATCH_DISPATCH walk. Match: handler runs and
        ; RTS's straight through to EXPR2's caller (tail call). No match:
        ; falls through to E2_LIT below (FUNC_TAB's sentinel resume target).
         LDX #FUNC_TAB_OFF
         JMP MATCH_DISPATCH

E2_POS:  JSR GETCI            ; consume unary '+', then fall through
EXPR2:
         JSR WPEEK
         CMP #'('
         BNE E2_NOTPAR
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
        ; drop through
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
;   Falls through directly into MATCH_DISPATCH at the statement section
;   (offset 0) of UNI_TAB; a match runs the handler and RTS's to STMT's
;   caller, no match falls through to DO_LET (implicit "X=...") via the
;   sentinel. Nothing may be inserted between here and MATCH_DISPATCH.
; =============================================================================
STMT:
         JSR WPEEK
         CMP #' '             ; anything below space (CR, NUL) means empty line
         BCC GETCI_SK         ; return via nearest preceding RTS
         LDX #0                ; statement section offset, falls through
        ; drop through
; =============================================================================
; MATCH_DISPATCH -- shared keyword search across UNI_TAB (STMT falls
;   through at offset 0, EXPR2 enters at offset FUNC_TAB_OFF). Each section
;   ends with a 3-byte $FF sentinel whose next 2 bytes ARE the no-match
;   resume address (read directly, no loop-back -- see UNI_TAB header).
;
;   In:  X = section offset (0 = statements, FUNC_TAB_OFF = functions)
;   Out: matched handler executed (tail call, RTS's to MATCH_DISPATCH's
;        caller); IP advanced
;   Clobbers: A, X, Y, T1, T2
; =============================================================================
MATCH_DISPATCH:
MD_LP:   LDA UNI_TAB,X
         BMI MD_FAIL           ; $FF sentinel: no match in this section
         JSR MTCHKW            ; X = entry offset, passed straight through
         BCS MD_NX
         BPL MD_NOPAREN        ; bit7 clear: statement/0-arg, skip paren-eat
         TXA                   ; save table offset -- EAT_PAREN clobbers X
         PHA
         JSR EAT_PAREN
         PLA
         TAX
MD_NOPAREN:                    ; table stores (handler-1) -- see UNI_TAB header
         INX                   ; shift X by 1 so +1/+2 below read what +2/+3
                                ; would -- folds this into MD_FAIL's push/RTS
         ; falls through into MD_FAIL
MD_FAIL:                       ; sentinel stores (resume-1), same trick
         LDA UNI_TAB+2,X
         PHA
         LDA UNI_TAB+1,X
         PHA
DL_DN:   RTS                   ; shared bare RTS -- see DO_LET/NEG16 header note
MD_NX:   INX                   ; not in anyone's fallthrough -- only reached
         INX                   ; via the explicit "BCS MD_NX" above
         INX
         INX
         BNE MD_LP             ; always taken (table well under 256 bytes)

; =============================================================================
; EAT_PAREN  --  consume a delimiter+expr (EAT_EXPR), then a closing ')'
;
;   In:  IP -> '(' (possible leading spaces; see EAT_EXPR)
;   Out: T0 = parsed argument; IP advanced past the closing ')'
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Used by MATCH_DISPATCH to eat a 1-arg function's "(expr)" once, centrally,
;   before jumping to the handler
; =============================================================================
EAT_PAREN: JSR EAT_EXPR
        JMP WEAT        

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
; =============================================================================
; STORE_VAR / T0_TO_CURLN  --  shared tail: store T0 into a VARS-relative slot
;
;   STORE_VAR pops its offset off the hardware stack (pushed by PARSE_VAR's
;   caller) -- DO_LET falls through into it directly, so its PLA/TAX must
;   come first. The BIT-trick then skips T0_TO_CURLN's own LDX (2 bytes,
;   same width as PLA/TAX) so the fallthrough doesn't reload X. T0_TO_CURLN,
;   called directly (from EDITLN/GOTOL), sets X to CURLN's own offset from
;   VARS instead (wraps mod 256, since CURLN sits before VARS in zero page --
;   same 0,X/1,X indexed trick as CMP_PLP_X above).
;
;   In:  T0 = value to store; STORE_VAR entry: hardware stack top = var_offset
;   Out: VARS[X] = T0 (X = popped var_offset, or CURLN-VARS); RTS
;   Clobbers: A X
; =============================================================================
STORE_VAR:
         PLA
         TAX
         .DB $2C               ; BIT abs: swallows T0_TO_CURLN's LDX below
T0_TO_CURLN:
         LDX #CURLN-VARS       ; wraps mod 256 to CURLN's real ZP address
T0_TO_X:
         LDA T0
         STA VARS,X
         LDA T0+1
         STA VARS+1,X
         RTS
DL_POP:  PLA
         LDA #ERR_UK
         JMP DO_ERROR

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
WPEEK:   LDY #0
         LDA (IP),Y
         CMP #' '
         BNE RTS_1            ; non-space: return
         JSR GETCI            ; consume space and loop
         BNE WSKIP            ; always taken (' ' = $20, nonzero)
RTS_1:   RTS

; =============================================================================
; DO_DPOKE ? DPOKE addr, value: write a 16-bit value to memory (lo,hi) -- sister
;   of E2_dpeek/DPEEK(addr).
;   Clobbers: A Y T0 T1
; =============================================================================
DO_DPOKE:
        JSR GET_TWO_ARGS      ; T4 = addr, T0 = value
        LDY #0
        LDA T0
        STA (T4),Y             ; lo byte at addr
        INY
        LDA T0+1
        STA (T4),Y            ; hi byte at addr+1
        RTS

; =============================================================================
; PRT_HEX / PRT16 - Unified Variable-Width Printer
; In: T0 (16-bit value). T1 is used as scratch for the Base.
;   Clobbers: A Y T0 T1
; =============================================================================
PRT16:
         LDA T0+1           ; Check sign of T0
         BPL PRT16_POS      ; If positive, skip negation
         LDA #'-'           ; Print '-'
         JSR PUTCH
         JSR NEG16          ; Absolute value of T0
PRT16_POS:
         LDA #10            ; A = 10 (Dec Base)
         BNE PRT_MERGE      ; Unconditional jump over Hex (10 is not 0!)
PRT_HEX:
         LDA #'$'           ; Print '$' prefix
         JSR PUTCH
         LDA #16            ; A = 16 (Hex Base)
PRT_MERGE:
         STA T1             ; Store Radix (10 or 16)
PRT_LOOP_INIT:
         LDY #16            ; Setup 16-bit division
         LDA #0             ; Clear remainder
PRT_DIV_LOOP:
         ASL T0
         ROL T0+1
         ROL                ; ROL A (accumulates remainder)
         CMP T1             ; Compare against Radix in T1
         BCC PRT_SKIP
         SBC T1
         INC T0
PRT_SKIP:
         DEY
         BNE PRT_DIV_LOOP
         PHA                ; Push remainder (0-9 or 0-15)
         LDA T0
         ORA T0+1
         BEQ PRT_PRNT       ; If quotient is 0, we are done recursing
         JSR PRT_LOOP_INIT  ; Recurse for next MSB digit (T1 is preserved!)
PRT_PRNT:
         PLA                ; Pop remainder
PRT_HEXN:
         ORA #$30           ; Convert 0-15 to ASCII
         CMP #$3A
         BCC PRT_HEXN_OK
         ADC #$06           ; Adjust for A-F
PRT_HEXN_OK:
         ; fall through into PUTCH
        .DB $2C ; consume next 2 bytes
; =============================================================================
; Kowalski and JB have different IO
PRTQUEST:
        LDA #'?'        
        .DB $2C ; consume next 2 bytes
PRTSPACE:
        LDA #' '
        ; drop through
        
        .IF KOWALSKI
; =============================================================================
; PUTCH  --  write one character to the Kowalski terminal
;
;   In:  A = character to output
;   Out: --
;   Clobbers: X  (via TAX, done deliberately to refresh flags from A since
;             STA doesn't touch them -- see DP_STR/DP_CHR's "always taken"
;             branches, which rely on this). A and flags-from-A preserved.
; =============================================================================
PUTCH:   STA IO_OUT
         TAX    ; ensure zero flag not set
         RTS

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
GETCH:   JSR RND_SHUFFLE
         LDA IO_IN
         BEQ GETCH          ; spin until a char is available
         RTS

	.ELSE
; =============================================================================
; PUTCH  --  Transmit character in A via 6522 VIA PA0 (1200 baud @ 1 MHz)
;   Out: character sent; T3 destroyed
;   Clobbers: A, X, T3, T4
; =============================================================================
PUTCH:
         STA T3              ; 2 bytes - Save character
         LDX #10             ; 2 bytes - Send 10 bits total (Start + 8 Data + Stop)
         CLC                 ; 1 byte  - Seed Carry with 0 for the Start bit
PC_LOOP:
         LDA #$00            ; 2 bytes 
         ROL                 ; 1 byte  - A = Carry (0 or 1)
         STA VIA_ORA         ; 3 bytes - Drive bit on PA0
         JSR DELAY_BIT       ; 3 bytes - Delay ~818 cy 
         SEC                 ; 1 byte  - Seed Stop bits (1s fill in from the top)
         ROR T3              ; 2 bytes - Data bit -> Carry, 1 -> MSB
         DEX                 ; 1 byte
         BNE PC_LOOP         ; 2 bytes
         RTS                 ; 1 byte

; =============================================================================
; DELAY_BIT / DELAY_HALF  --  timing delays for 1200 baud @ 1 MHz
;   Out: T4 = 0, Z=1
;   Clobbers: A, T4
; =============================================================================
DELAY_BIT:
         LDA #100            ; 2 bytes - Full bit delay count (~818 cycles)
         .DB $2C             ; 1 byte  - BIT abs trick (swallows 'LDA #50')
DELAY_HALF:
         LDA #50             ; 2 bytes - Half bit delay count (~416 cycles)
         STA T4              ; 2 bytes
DL_LOOP: DEC T4              ; 2 bytes - 5 cycles
         BNE DL_LOOP         ; 2 bytes - 3 cycles (8 cycles per loop iteration)
         RTS                 ; 1 byte

; =============================================================================
; GETCH  --  receive one character via 6522 VIA PA1 (1200 baud @ 1 MHz)
;   Out: A = received character
;   Clobbers: A, X, T3, T4 (Preserves Y)
; =============================================================================
GETCH:   
GC_WAIT: JSR RND_SHUFFLE     ; 3 bytes - Harvest keystroke timing entropy
         LDA VIA_ORA         ; 3 bytes
         AND #VIA_RX         ; 2 bytes - Test PA1 (RX line)
         BNE GC_WAIT         ; 2 bytes - Non-zero = mark (idle high): wait
         
         JSR DELAY_HALF      ; 3 bytes - Advance to mid-point of Start bit       
         ; --- Read 9 bits: Start bit + 8 Data bits ---
         LDX #9              ; 2 bytes
GC_LOOP: LDA VIA_ORA         ; 3 bytes - Sample Port A
         LSR                 ; 1 byte  - PA0 -> Carry
         LSR                 ; 1 byte  - PA1 (RX bit) -> Carry
         ROR T3              ; 2 bytes - Shift RX into MSB of T3
         JSR DELAY_BIT       ; 3 bytes - Delay 1 bit time to next bit center
         DEX                 ; 1 byte
         BNE GC_LOOP         ; 2 bytes      
         LDA T3              ; 2 bytes - Return received character in A
         RTS                 ; 1 byte  - (Start bit safely discarded into Carry!)

	.ENDIF

ROMEND: ; for auditing

; =============================================================================
; Reset / IRQ / NMI vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT         ; $FFFC: reset vector
         .DW IRQ_HANDLER      ; $FFFE: IRQ vector   (Break pushbutton)
