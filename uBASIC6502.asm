; =============================================================================
; uBASIC6502 v1.7 
;
; 16 bit signed Tiny BASIC interpreter for NMOS 6502 and 2kbyte 2716 EPROM.
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Statements accepted 
;   END  GOSUB GOTO  IF..THEN  INPUT  LET  PRINT  REM RETURN
;   FREE  LIST  NEW  RUN
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   PEEK(addr)   USR(addr)   A-Z variables
;
; Numbers      : signed 16-bit  (-32768 .. 32767)
; String print : "literals", `;`, TAB(n) and CHR$() only; no string variables
;
; Error codes (printed as "?N"):
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division or modulo by zero
;   ?3  out of memory
;   ?4  bad variable name in LET
;   ?5  RETURN without GOSUB
;
; ---- program storage --------------------------------------------------------
;   Base $0200; ceiling RAM_TOP ($1000 for 4 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; =============================================================================
; CHANGE HISTORY
;
; v1.7 (Jul 2026) 58 bytes free before vectors
;   - FIXED: GOSUB degraded to GOTO,due to EXPR overwritten
;   - FIXED: Replacing existing line inserted at end of the program instead of 
;     in place, fixed by save/restore LP. 
;   - FIXED: RETURN never restored IP/CURLN. 
;   - FIXED: GOTOL never updated CURLN on a jump, only IP. Fixed by copying T0
;
; v1.6 (Jul 2026) - 83 bytes before vectors
;   - ADDED: GOSUB/RETURN using GOTO/REM 3rd-char dispatch.
;   - Implemented an 8-level return stack in Zero Page ($67-$86).
;   - FIXED: `DO_POKE` value corruption caused by an early address restore.
;   - Rewrote `DELINE`/`INSLINE` to use direct pointer comparisons (saves space).
;   - Optimized `PNUM` for size by switching from shift-based to loop-based x10.
;   - Optimized `EXPR2` branching; removed obsolete `T2DEC` subroutine.
;
; v1.5 (Jul 2026)
;   - Reordered Zero Page to group all active symbols contiguously ($00-$64).
;   - FIXED: `DELINE` page-boundary corruption on program tails >= 256 bytes.
;   - FIXED: `DO_NEW` loop bounds overflow when clearing A-Z variables.
;
; v1.4 (Jun 2026)
;   - Refactored core loop for size; added `FREE` and `TAB(n)` keywords.
;
; v1.3 (Apr 2026)
;   - Factored out `T2DEC` helper subroutine from line-handling routines.
;
; v1.2 (Apr 2026)
;   - Redesigned `EXPR` relational evaluator using an operator bitmask loop.
;   - Implemented standard 6502 `N XOR V` signed 16-bit comparison logic.
;
; v1.1 (Mar 2026) - Bug fixes ported from mango_one repository:
;   - FIXED: `EXPR_ADD` operator-save register clobber in multi-term subtraction.
;   - FIXED: Infinite loop guard in `DO_LIST` for lines missing CR terminators.
;   - Adjusted default Mandelbrot showcase program coordinates for better centering.
;
;  v17.0 (Mar 2026)  comment cleanup/public release baseline.
;   - Initial 6502 port from v17.0 uBASIC65c02 Tiny BASIC source.
;
; =============================================================================

; ---- assembler mode ---------------------------------------------------------
         .opt proc6502

; ---- hardware I/O ports (Kowalski simulator UART) ----------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)
IO_IRQ   = $E007             ; write any value to fire a maskable hardware IRQ

; ---- RAM ceiling -------------------------------------------------------------
RAM_TOP  = $1000             ; first address above usable SRAM (4 KB)

; ---- zero-page symbols -------------------------------------------------------
; Note IP and CURLN must be sequential for GOSUB/RETURN stack push
IP       = $00               ; 16-bit: interpreter pointer
CURLN    = $02               ; 16-bit: currently-executing line number
PE       = $04               ; 16-bit: program end (one past last byte)
LP       = $06               ; 16-bit: line pointer / multi-purpose scratch
T0       = $08               ; 16-bit: primary scratch word / expression result
T1       = $0A               ; 16-bit: secondary scratch word
T2       = $0C               ; 16-bit: tertiary scratch word / STMT jump target
RUN      = $0E               ; 8-bit:  run flag ($00 = immediate, $FF = running)
OP       = $0F               ; 8-bit:  saved operator for MUL/DIV/MOD ('*'/'/'/'%')
IBUF     = $10               ; 32-byte input line buffer
VARS     = $30               ; A-Z variable store (2 bytes each), 52 bytes ($30-$63)
RUNSP    = $64               ; 8-bit:  stack-pointer snapshot for GOTO/BREAK unwind
T3       = $65               ; 8-bit:  PNUM x10-multiply scratch (digit-seeded hi byte)
GOSUB_SP = $66               ; 8-bit:  GOSUB/RETURN stack pointer (holds a ZP address directly)
GOSUB_LO = $67               ; base of the 8-level GOSUB return-frame stack (32 bytes, $67-$86)
GOSUB_TOP  = $86             ; initial/empty GOSUB_SP value (topmost stack byte, = GOSUB_LO+31)
GOSUB_FULL = $6A             ; lowest X for which a full 4-byte push still fits ($67-$6A)

; ---- error codes -------------------------------------------------------------
ERR_SN   = 0                 ; syntax / bad expression
ERR_UL   = 1                 ; undefined line number
ERR_OV   = 2                 ; division or modulo by zero
ERR_OM   = 3                 ; out of memory
ERR_UK   = 4                 ; bad variable name in LET
ERR_RET  = 5                 ; RETURN without GOSUB

; ---- Misc constants -------------------------------------------------
IBUF_MAX = 31                ; highest valid index into IBUF
VARS_MAX = $33               ; highest X index for variable clear loop ($30..$63)
CR       = $0D               ; ASCII carriage return
LF       = $0A               ; ASCII line feed
BS       = $08               ; ASCII backspace
HWSTACK  = $FF               ; Standard stack - lower on small ram targets?
PROG     = HWSTACK+$101      ; May be lower if we use a smaller Stack 

; =============================================================================
; Program Start - Kowalski trampoline, which executes from the first byte not 
; reset vector.  Real hardware reaches INIT via Reset vector $FFFC instead.
; Technically in Zero page but overwritten as soon as program starts
         .ORG 0 
         JMP INIT

; =============================================================================
; Pre-loaded showcase program  
;
;   Stored as raw ASCII.  Line format: <lineno_lo> <lineno_hi> <body> <CR>
;
;   Lines  10-260: feature demos (PRINT, CHR$, arithmetic, comparisons, loops)
;   Lines 270-480: Mandelbrot set renderer
;
;   v1.1: Mandelbrot column scan adjusted from -128..16 to -120..4 for a
;         better-centred render.
; =============================================================================
         .ORG PROG

         .DB $0A,$00,$52,$45,$4D,$20,$75,$42,$41,$53,$49,$43,$20,$76,$31,$33,$20,$2D,$20,$53,$48,$4F,$57,$43,$41,$53,$45,$0D  ; 10 REM uBASIC v13 - SHOWCASE
         .DB $14,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$20,$75,$42,$41,$53,$49,$43,$20,$76,$31,$33,$20,$53,$48,$4F,$57,$43,$41,$53,$45,$20,$2D,$2D,$22,$0D  ; 20 PRINT "-- uBASIC v13 SHOWCASE --"
         .DB $1E,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$50,$52,$49,$4E,$54,$20,$2F,$20,$43,$48,$52,$24,$20,$2D,$2D,$2D,$22,$0D  ; 30 PRINT "--- PRINT / CHR$ ---"
         .DB $28,$00,$50,$52,$49,$4E,$54,$20,$43,$48,$52,$24,$28,$36,$35,$29,$3B,$43,$48,$52,$24,$28,$36,$36,$29,$3B,$43,$48,$52,$24,$28,$36,$37,$29,$0D  ; 40 PRINT CHR$(65);CHR$(66);CHR$(67)
         .DB $32,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$41,$52,$49,$54,$48,$4D,$45,$54,$49,$43,$20,$2D,$2D,$2D,$22,$0D  ; 50 PRINT "--- ARITHMETIC ---"
         .DB $3C,$00,$50,$52,$49,$4E,$54,$20,$22,$33,$2B,$34,$3D,$22,$3B,$33,$2B,$34,$3B,$22,$20,$20,$31,$30,$2D,$33,$3D,$22,$3B,$31,$30,$2D,$33,$3B,$22,$20,$20,$36,$2A,$37,$3D,$22,$3B,$36,$2A,$37,$0D  ; 60 PRINT "3+4=";3+4;"  10-3=";10-3;"  6*7=";6*7
         .DB $46,$00,$50,$52,$49,$4E,$54,$20,$22,$32,$30,$2F,$34,$3D,$22,$3B,$32,$30,$2F,$34,$3B,$22,$20,$20,$31,$37,$25,$35,$3D,$22,$3B,$31,$37,$25,$35,$0D  ; 70 PRINT "20/4=";20/4;"  17%5=";17%5
         .DB $50,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$43,$4F,$4D,$50,$41,$52,$49,$53,$4F,$4E,$53,$20,$2D,$2D,$2D,$22,$0D  ; 80 PRINT "--- COMPARISONS ---"
         .DB $5A,$00,$49,$46,$20,$35,$3E,$33,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$22,$35,$3E,$33,$20,$6F,$6B,$22,$0D  ; 90 IF 5>3 THEN PRINT "5>3 ok"
         .DB $64,$00,$49,$46,$20,$33,$3C,$35,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$22,$33,$3C,$35,$20,$6F,$6B,$22,$0D  ; 100 IF 3<5 THEN PRINT "3<5 ok"
         .DB $6E,$00,$49,$46,$20,$33,$3E,$3D,$33,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$22,$33,$3E,$3D,$33,$20,$6F,$6B,$22,$0D  ; 110 IF 3>=3 THEN PRINT "3>=3 ok"
         .DB $78,$00,$49,$46,$20,$34,$3C,$3E,$33,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$22,$34,$3C,$3E,$33,$20,$6F,$6B,$22,$0D  ; 120 IF 4<>3 THEN PRINT "4<>3 ok"
         .DB $82,$00,$49,$46,$20,$33,$3D,$33,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$22,$33,$3D,$33,$20,$6F,$6B,$22,$0D  ; 130 IF 3=3 THEN PRINT "3=3 ok"
         .DB $8C,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$4C,$4F,$4F,$50,$20,$76,$69,$61,$20,$47,$4F,$54,$4F,$20,$2D,$2D,$2D,$22,$0D  ; 140 PRINT "--- LOOP via GOTO ---"
         .DB $96,$00,$49,$3D,$31,$0D  ; 150 I=1
         .DB $A0,$00,$49,$46,$20,$49,$3E,$35,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$31,$39,$30,$0D  ; 160 IF I>5 THEN GOTO 190
         .DB $AA,$00,$50,$52,$49,$4E,$54,$20,$49,$3B,$0D  ; 170 PRINT I;
         .DB $B4,$00,$49,$3D,$49,$2B,$31,$3A,$47,$4F,$54,$4F,$20,$31,$36,$30,$0D  ; 180 I=I+1:GOTO 160
         .DB $BE,$00,$50,$52,$49,$4E,$54,$20,$22,$22,$0D  ; 190 PRINT ""
         .DB $C8,$00,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$4E,$45,$53,$54,$45,$44,$20,$4C,$4F,$4F,$50,$20,$2D,$2D,$2D,$22,$0D  ; 200 PRINT "--- NESTED LOOP ---"
         .DB $D2,$00,$49,$3D,$31,$0D  ; 210 I=1
         .DB $DC,$00,$49,$46,$20,$49,$3E,$33,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$32,$37,$30,$0D  ; 220 IF I>3 THEN GOTO 270
         .DB $E6,$00,$4A,$3D,$31,$0D  ; 230 J=1
         .DB $F0,$00,$49,$46,$20,$4A,$3E,$33,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$32,$36,$30,$0D  ; 240 IF J>3 THEN GOTO 260
         .DB $FA,$00,$50,$52,$49,$4E,$54,$20,$4A,$3B,$0D  ; 250 PRINT J;
         .DB $FF,$00,$4A,$3D,$4A,$2B,$31,$3A,$47,$4F,$54,$4F,$20,$32,$34,$30,$0D  ; 255 J=J+1:GOTO 240
         .DB $04,$01,$50,$52,$49,$4E,$54,$20,$22,$22,$3A,$49,$3D,$49,$2B,$31,$3A,$47,$4F,$54,$4F,$20,$32,$32,$30,$0D  ; 260 PRINT "":I=I+1:GOTO 220
         .DB $0E,$01,$50,$52,$49,$4E,$54,$20,$22,$2D,$2D,$2D,$20,$4D,$41,$4E,$44,$45,$4C,$42,$52,$4F,$54,$20,$2D,$2D,$2D,$22,$0D  ; 270 PRINT "--- MANDELBROT ---"
         .DB $18,$01,$49,$3D,$2D,$36,$34,$0D  ; 280 I=-64
         .DB $22,$01,$49,$46,$20,$49,$3E,$35,$36,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$34,$38,$30,$0D  ; 290 IF I>56 THEN GOTO 480
         .DB $2C,$01,$44,$3D,$49,$0D  ; 300 D=I
; v1.1: line 310 C=-120 (was -128), line 320 C>4 (was C>16) — better-centred render
         .DB $36,$01,$43,$3D,$2D,$31,$32,$30,$0D  ; 310 C=-120
         .DB $40,$01,$49,$46,$20,$43,$3E,$34,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$34,$35,$30,$0D  ; 320 IF C>4 THEN GOTO 450
         .DB $4A,$01,$41,$3D,$43,$3A,$42,$3D,$44,$3A,$45,$3D,$30,$3A,$4E,$3D,$31,$0D  ; 330 A=C:B=D:E=0:N=1
         .DB $54,$01,$49,$46,$20,$4E,$3E,$31,$36,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$33,$39,$30,$0D  ; 340 IF N>16 THEN GOTO 390
         .DB $5E,$01,$49,$46,$20,$45,$3E,$30,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$33,$38,$30,$0D  ; 350 IF E>0 THEN GOTO 380
         .DB $68,$01,$54,$3D,$41,$2A,$41,$2F,$36,$34,$2D,$42,$2A,$42,$2F,$36,$34,$2B,$43,$0D  ; 360 T=A*A/64-B*B/64+C
         .DB $72,$01,$42,$3D,$32,$2A,$41,$2A,$42,$2F,$36,$34,$2B,$44,$3A,$41,$3D,$54,$0D  ; 370 B=2*A*B/64+D:A=T
         .DB $7C,$01,$49,$46,$20,$41,$2A,$41,$2F,$36,$34,$2B,$42,$2A,$42,$2F,$36,$34,$3E,$32,$35,$36,$20,$54,$48,$45,$4E,$20,$49,$46,$20,$45,$3D,$30,$20,$54,$48,$45,$4E,$20,$45,$3D,$4E,$0D  ; 380 IF A*A/64+B*B/64>256 THEN IF E=0 THEN E=N
         .DB $86,$01,$4E,$3D,$4E,$2B,$31,$3A,$49,$46,$20,$4E,$3C,$3D,$31,$36,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$33,$34,$30,$0D  ; 390 N=N+1:IF N<=16 THEN GOTO 340
         .DB $90,$01,$49,$46,$20,$45,$3E,$30,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$43,$48,$52,$24,$28,$45,$2B,$33,$32,$29,$3B,$0D  ; 400 IF E>0 THEN PRINT CHR$(E+32);
         .DB $9A,$01,$49,$46,$20,$45,$3D,$30,$20,$54,$48,$45,$4E,$20,$50,$52,$49,$4E,$54,$20,$43,$48,$52,$24,$28,$33,$32,$29,$3B,$0D  ; 410 IF E=0 THEN PRINT CHR$(32);
         .DB $A4,$01,$43,$3D,$43,$2B,$34,$0D  ; 420 C=C+4
         .DB $AE,$01,$47,$4F,$54,$4F,$20,$33,$32,$30,$0D  ; 430 GOTO 320
         .DB $C2,$01,$50,$52,$49,$4E,$54,$20,$22,$22,$0D  ; 450 PRINT ""
         .DB $CC,$01,$49,$3D,$49,$2B,$36,$0D  ; 460 I=I+6
         .DB $D6,$01,$47,$4F,$54,$4F,$20,$32,$39,$30,$0D  ; 470 GOTO 290
         .DB $E0,$01,$45,$4E,$44,$0D  ; 480 END
SHOWCASE_END:

; =============================================================================
; ROM START  ($F800)
; =============================================================================
         .ORG $F800

; =============================================================================
; STRING / KEYWORD TABLE  (page $F8 onwards)
; All strings and 2-byte keyword entries are kept on STR_PAGE ($F8).
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string and keyword addresses

; ---- bit-7 terminal-character constants -------------------------------------
; Naming: T_<char>  where <char> is the ASCII letter or symbol.
T_LF  = 138              ; $0A + $80  (LF  -- final byte of STR_CRLF)
T_SP  = 160              ; $20 + $80  (' ' -- final byte of STR_IN)
T_D   = 196              ; $44 + $80  ('D' -- END)
T_E   = 197              ; $45 + $80  ('E' -- NE, RE, LE, PE)
T_F   = 198              ; $46 + $80  ('F' -- IF)
T_H   = 200              ; $48 + $80  ('H' -- TH, CH)
T_I   = 201              ; $49 + $80  ('I' -- LI)
T_K   = 203              ; $4B + $80  ('K' -- BREAK, PEEK)
T_M   = 205              ; $4D + $80  ('M' -- REM)
T_N   = 206              ; $4E + $80  ('N' -- RUN, THEN)
T_O   = 207              ; $4F + $80  ('O' -- GO, PO)
T_P   = 208              ; $50 + $80
T_R   = 210              ; $52 + $80  ('R' -- USR)
T_S   = 211              ; $53 + $80  ('S' -- US)
T_T   = 212              ; $54 + $80
T_U   = 213              ; $55 + $80  ('U' -- RU)
T_W   = 215              ; $57 + $80  ('W' -- NEW)
T_DS  = 164              ; $24 + $80  ('$' -- CHR$)

; ---- human-readable strings -------------------------------------------------
; Last byte of each string has bit 7 set; PUTSTR masks it before printing.
; Bit 7 terminated, Kowalski assembler doesnt like "ch"|$80 inside a .DB 
STR_BANNER: .DB "uBASIC6502 v1.4 "; startup banner, rolls into free
STR_FREE:   .DB "Free "
STR_CRLF:   .DB CR, T_LF       ; CR + LF
STR_IN:     .DB " IN", T_SP    ; " IN " (error annotation: " IN <linenum>")
STR_BREAK:  .DB CR, LF, "BREA", T_K  ; "\r\nBREAK"

; ---- keyword strings --------------------------------------------------------
; Two uppercase ASCII bytes per keyword (no bit-7 terminator).
; MTCHKW compares a 16-bit prefix and then skips trailing letters in input.
KW_TABLE:
KW_PRINT:   .DB 'P','R'
KW_IF:      .DB 'I','F'
KW_GOTO:    .DB 'G','O'
KW_LIST:    .DB 'L','I'
KW_RUN:     .DB 'R','U'
KW_NEW:     .DB 'N','E'
KW_INPUT:   .DB 'I','N'
KW_REM:     .DB 'R','E'
KW_END:     .DB 'E','N'
KW_LET:     .DB 'L','E'
KW_THEN:    .DB 'T','H'
KW_CHRS:    .DB 'C','H'      
KW_POKE:    .DB 'P','O'
KW_PEEK:    .DB 'P','E'
KW_USR:     .DB 'U','S'
KW_TAB:     .DB 'T','A'	     
KW_FREE:    .DB 'F','R'

; =============================================================================
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or Kowalski JMP trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
; =============================================================================
INIT:
         LDX #HWSTACK
         TXS                  ; set page 1 stack
         CLD                  ; ensure binary (not decimal) mode
         CLI                  ; enable maskable IRQs (for Break key)
         LDA #0
INIT_Z:  STA 0,X              ; clear zero-page byte at X
         DEX
         BNE INIT_Z
         LDA #GOSUB_TOP
         STA GOSUB_SP          ; empty call stack and immediate-mode GOSUB
         ; --- 
         LDA #<SHOWCASE_END   ; point PE at end of pre-loaded showcase program
         STA PE               ; Replace with `JSR DO_NEW` for clean program (ROM)
         LDA #>SHOWCASE_END
         STA PE+1
         ; ---
         LDA #<STR_BANNER
         JSR PUTSTR           ; print banner + Free + CR+LF (STR_CRLF follows )
         JSR DO_FREE
         ; fall through into MAIN

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
;
;   In:  -- (falls through from INIT, or jumped to from DO_ERROR / DO_END)
;   Out: never returns
;   Clobbers: everything (infinite loop)
;
;   Reads one line from the terminal.  Lines that start with a digit are
;   routed to EDITLN (program store editor); else executed via STMT_LINE 
; =============================================================================
MAIN:
         LDX #HWSTACK
         TXS                  ; set stack to top of page 1
         LDA #0
         STA RUN              ; clear run flag (immediate mode)
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
         JSR STMT_LINE        ; execute as immediate statement
         JMP MAIN

; =============================================================================
; DO_FREE  --  FREE  :  print free program-store bytes
;
;   In:  PE = current program end pointer
;   Out: "<N>\r\n" printed to terminal
;   Clobbers: A T0
;
;   Computes RAM_TOP - PE (16-bit), prints the count via PRT16 then PRNL
; =============================================================================
DO_FREE:
         SEC
         LDA #<RAM_TOP
         SBC PE
         STA T0
         LDA #>RAM_TOP
         SBC PE+1
         STA T0+1
         JSR PRT16            ; print free count
         JMP PRNL             ; print CR+LF and return (tail call)

; =============================================================================
; Check for proper variable access
PARSE_VAR:
         JSR WPEEK_UC         ; Skips spaces, peeks char, converts to uppercase
         CMP #'A'
         BCC PV_FAIL
         CMP #'Z'+1
         BCS PV_FAIL
         JSR GETCI            ; Consume the variable char
         JSR UC               ; Uppercase it again (since GETCI fetched raw)
         SEC
         SBC #'A'
         ASL                  ; Convert to VARS offset
         CLC
         RTS
PV_FAIL: SEC
         RTS

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;
;   In:  -- (entered via hardware IRQ; CPU has pushed PChi, PClo, P)
;   Out: if RUN != 0: unwinds stack, prints BREAK+linenum, jumps to MAIN
;        if RUN == 0: silently ignored (RTI)
;   Clobbers: A X  (stack deliberately abandoned when running)
;   The program store is left intact; the user can LIST or RUN again.
;   When idle at the prompt: RTI silently discards the interrupt.
; =============================================================================
IRQ_HANDLER:
         LDA RUN              ; is a program running?
         BEQ IRQ_idle         ; no: ignore interrupt
         LDX RUNSP            ; yes: restore SP to pre-run snapshot
         TXS                  ; (unwinds all JSR frames accumulated during RUN)
         LDA #<STR_BREAK
         JSR PUTSTR           ; print "\r\nBREAK"
         JMP DO_break_in      ; print " IN <linenum>\r\n" then jump to MAIN
IRQ_idle:
         RTI                  ; idle: silently discard interrupt

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
         PLA
         TAX                  ; X = VARS offset
         LDA T0
         STA VARS,X           ; store result into variable
         LDA T0+1
         STA VARS+1,X
DO_IN_DN: RTS

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
;   Clobbers: A X IP
;   Supports backspace (BS) to delete the last character.
;   Overflow characters (beyond IBUF_MAX) are silently discarded.
;   After CR is received, outputs CR+LF via PRNL before returning.
; =============================================================================
GETLINE_M:
         LDA #'>'
         .DB $2C              ; BIT abs: fetches & discards next 2 bytes as operand
GETLINE_I:
         LDA #'?'
         JSR PUTCH
         LDA #' '
         JSR PUTCH
GETLINE:
         LDX #0
GL_LP:   JSR GETCH            ; read one char (GETCH also echoes it)
         CMP #CR
         BEQ GL_DONE
         CMP #BS
         BNE GL_STORE
         CPX #0
         BEQ GL_LP            ; backspace on empty buffer -- ignore
         DEX
         BPL GL_LP            ; always taken here (X never reaches bit7 in IBUF range)
GL_STORE:
         CPX #IBUF_MAX
         BCS GL_LP            ; buffer full -- ignore overflow
         STA IBUF,X
         INX
         BPL GL_LP            ; always taken here (IBUF index remains < $80)
GL_DONE: STA IBUF,X           ; store CR as in-band terminator
         JSR PRNL             ; output CR+LF
         LDA #<IBUF
         STA IP
         LDA #>IBUF
         STA IP+1
; PN_DN is the RTS for both GETLINE (falls off the end here) and PNUM (branches
; here when the first non-digit is seen).  They share because this is the
; nearest RTS to both call sites.
PN_DN:   RTS

; =============================================================================
; PNUM  --  parse unsigned decimal integer from ASCII at IP into T0
;
;   In:  IP -> ASCII digits (leading spaces skipped automatically)
;   Out: T0 = parsed value; IP advanced past the last digit
;   Clobbers: A X T0 T2 T3
;   Stops at the first non-digit without consuming it.
; =============================================================================
PNUM:
         JSR WSKIP             ; skip leading spaces
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
         ; [OPT] CMP #10 guaranteed Carry is CLEAR here! (No CLC needed)
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

         ; [OPT] Removed CLC and replaced BCC with a second BNE
         INC IP                ; consume digit
         BNE PN_LP             ; Loop if low byte didn't wrap
         INC IP+1              ; If it wrapped, increment high byte
         BNE PN_LP             ; Loop (assumes IP+1 won't wrap to $00)

; =============================================================================
; DELINE  --  remove the line at LP from the program store; adjust PE
;
;   In:  LP -> start of line to delete (the line-number lo byte)
;        PE -> one past the last program byte
;   Out: line removed; PE = new end of program; LP == PE (NOT the original
;        deletion point -- callers that still need that address, e.g.
;        EDITLN's replace path, must save it themselves before calling)
;   Clobbers: A Y T0 LP PE
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
         STA T0               ; T0 = LP + length (start of next line)
         LDA LP+1
         ADC #0
         STA T0+1
         LDY #0
DL_CP:   LDA PE               ; check if we reached PE
         CMP T0
         BNE DL_DO
         LDA PE+1
         CMP T0+1
         BEQ DL_UPD           ; T0 == PE: nothing more to copy
DL_DO:   LDA (T0),Y           ; forward copy: (T0) -> (LP)
         STA (LP),Y
         INC T0               ; advance source
         BNE DL_NX
         INC T0+1
DL_NX:   INC LP               ; advance destination
         BNE DL_CP
         INC LP+1
         BNE DL_CP            ; unconditional (high byte won't wrap to 0)
DL_UPD:  LDA LP               ; LP naturally points exactly to the new PE
         STA PE
         LDA LP+1
         STA PE+1
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
         LDA T0
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDA #<PROG
         STA LP
         LDA #>PROG
         STA LP+1
EL_FL:   LDA LP               ; is LP == PE? (reached end of store)
         CMP PE
         BNE EL_GO
         LDA LP+1
         CMP PE+1
         BEQ EL_INS           ; yes: insert at end
EL_GO:   LDY #1               ; compare stored line number hi-byte first
         LDA (LP),Y
         CMP CURLN+1
         BCC EL_SKIP           ; stored line < target: keep scanning
         BNE EL_INS            ; stored line > target: insert before here
         DEY                   ; hi equal: compare lo byte
         LDA (LP),Y
         CMP CURLN
         BCC EL_SKIP
         BEQ EL_FND            ; exact match: delete existing then (re)insert
         ; JMP EL_INS
	BNE EL_INS		; always taken
	
EL_SKIP: LDY #2                ; advance LP to next line: scan for CR
EL_LEN:  LDA (LP),Y
         INY
         CMP #CR
         BNE EL_LEN
         TYA
         CLC
         ADC LP
         STA LP
         BCC EL_FL
         INC LP+1
         BCS EL_FL            ; unconditional (if BCC fell through, C=1)
EL_FND:  LDA LP                ; save the deletion point -- DELINE returns
         STA T1                ; with LP == new PE (see DELINE's header), but
         LDA LP+1               ; INSLINE below needs the *original* LP to
         STA T1+1                ; write the replacement line back in place
         JSR DELINE            ; delete existing line at LP
         LDA T1
         STA LP                ; restore LP for INSLINE (PE is already correct)
         LDA T1+1
         STA LP+1
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
;   Clobbers: A X Y T0 T1 IP LP PE
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
IN_OK:   LDA PE                ; T0 = old PE
         STA T0
         LDA PE+1
         STA T0+1
         LDA T1                ; write new PE early (we know it's safe now)
         STA PE
         LDA T1+1
         STA PE+1
         LDY #0
         LDA T0                ; if old PE == LP, nothing to shift upward
         CMP LP
         BNE IN_BK
         LDA T0+1
         CMP LP+1
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
         LDA T0                ; stop exactly when T0 == LP
         CMP LP
         BNE IN_BK
         LDA T0+1
         CMP LP+1
         BNE IN_BK
IN_HDR:  LDA CURLN             ; write line number lo
         STA (LP),Y            ; Y is 0 here
         INY
         LDA CURLN+1           ; write line number hi
         STA (LP),Y
         LDA LP                ; advance LP by 2 for the payload
         CLC
         ADC #2
         STA LP
         BCC IN_L2
         INC LP+1
IN_L2:   LDY #0
IN_CP:   LDA (IP),Y            ; copy payload from IBUF
         STA (LP),Y
         CMP #CR
         BEQ IN_DN
         INY
         BNE IN_CP             ; always taken for bounded line lengths (<256)
; EL_DN, DP_RET and IN_DN are adjacent because EDITLN (delete-only path),
; DO_PRINT (semicolon suppress path), and INSLINE all want a plain RTS and
; this is the nearest one.
EL_DN:
DP_RET:
IN_DN:   RTS

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
         CMP #CR
         BEQ DP_NL
         TAX			; Check for NUL - Transfer sets EQ flag for free
         BEQ DP_NL
         CMP #'"'
         BNE DP_CHR
         JSR GETCI            ; consume opening '"'
DP_STR:  JSR GETCI            ; read string body char by char
         CMP #'"'
         BEQ DP_AFT           ; closing '"' -- go check for ';'
         CMP #CR
         BEQ DP_NL            ; unterminated string -- print CR/LF and stop
         JSR PUTCH
         JMP DP_STR
DP_CHR: LDA #<KW_CHRS
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_TAB
         JSR EAT_EXPR         ; consume '(' and evaluate argument
         JSR WEAT             ; consume ')'
         LDA T0
         JSR PUTCH
         JMP DP_AFT
DP_TAB:  LDA #<KW_TAB
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_NORM
         JSR EAT_EXPR         ; consume '(' and evaluate argument
         JSR WEAT             ; consume ')'
	     LDX T0
	     BEQ DP_AFT           ; If TAB(0), skip printing spaces entirely
         LDA #' '
DP_TLOOP:	 
         JSR PUTCH 
         DEX
         BNE DP_TLOOP       
         BEQ DP_AFT
DP_NORM: JSR EXPR             ; numeric expression
         JSR PRT16
DP_AFT:  JSR WPEEK
         CMP #';'
         BNE DP_NL
         JSR GETCI            ; consume ';'
         JSR WPEEK
         CMP #CR
         BEQ DP_RET           ; trailing ';': suppress CR/LF (DP_RET = IN_DN = RTS above)
         TAX			; check for NUL
         BEQ DP_RET
         BNE DP_TOP		; always taken

; =============================================================================
; PRNL / PUTSTR / PUTSTRZP  --  print a bit-7-terminated string
;
;   Three entry points sharing one body:
;     PRNL      -- prints STR_CRLF (CR+LF); no argument needed
;     DP_NL     -- alias for PRNL used by DO_PRINT fall-through
;     PUTSTR    -- In: A = lo-byte of string address (hi-byte = STR_PAGE)
;     PUTSTRZP  -- In: T2 = lo-byte of string address (hi-byte set here)
;
;   Out: characters written to terminal; T2 left pointing at last character
;   Clobbers: A Y T2
;
;   All strings must reside on STR_PAGE.  A single lo-byte pointer suffices
;   because the hi-byte is always STR_PAGE.
;
;   Termination: bit 7 of the last character is set.  BMI detects it, AND #$7F
;   strips it, PUTCH prints it, then the routine returns.
;
;   Co-located labels:
;     LS_DONE (end of DO_LIST) and PS_DN (end of PUTSTR) share one RTS.
;     DO_PRINT falls into DP_NL / PRNL rather than using JSR+RTS.
; =============================================================================
PRNL:
DP_NL:   LDA #<STR_CRLF       ; load CR+LF string address, then fall into PUTSTR
PUTSTR:  STA T2               ; store lo-byte; hi-byte set below
PUTSTRZP:
         LDA #STR_PAGE
         STA T2+1             ; hi-byte is always STR_PAGE
         LDY #0
PS_LP:   LDA (T2),Y           ; fetch next character
         BMI PS_LAST          ; bit 7 set: this is the last character
         JSR PUTCH            ; print character
         INC T2               ; advance string pointer (lo-byte only; page never wraps)
         BNE PS_LP            ; always taken: string table constrained to one page
PS_LAST: AND #$7F             ; strip bit 7 from last character
         JSR PUTCH            ; print last character
; LS_DONE and PS_DN are adjacent because DO_LIST (end-of-program path) and
; PUTSTR (end-of-string path) both want a plain RTS here.
LS_DONE:
PS_DN:   RTS

; =============================================================================
; DO_POKE  --  POKE addr, value  :  write one byte to memory
;
;   Syntax: POKE <expr>, <expr>
;   In:  IP -> address expression
;   Out: byte written; IP advanced past statement
;   Clobbers: A Y T0 T1 IP
; =============================================================================
DO_POKE:
         JSR EXPR              ; evaluate address -> T0
         LDA T0+1              ; push address hi byte  (T1 clobbered by MTCHKW
         PHA                   ;   in the second EXPR call, so use hardware stack)
         LDA T0                ; push address lo byte
         PHA
         JSR WEAT              ; skip spaces, consume ','
         JSR EXPR              ; evaluate value -> T0
         PLA
         STA T1                ; address lo
         PLA
         STA T1+1              ; address hi
         LDA T0                ; value, fetched after address is restored
         LDY #0
         STA (T1),Y            ; write value to address
         RTS
         
; =============================================================================
; DO_LIST  --  LIST  :  print all program lines in source form
;
;   In:  PE = current program end
;   Out: all lines printed as "<linenum> <body>"
;   Clobbers: A X Y T0 LP
; =============================================================================
DO_LIST:
         LDA #<PROG
         STA LP
         LDA #>PROG
         STA LP+1
LS_LN:   LDA LP               ; test LP == PE (end of program)
         CMP PE
         BNE LS_GO
         LDA LP+1
         CMP PE+1
         BEQ LS_DONE          ; end of program: branches to shared RTS above
LS_GO:   LDY #0
         LDA (LP),Y           ; read line number lo
         STA T0
         INY                  ; Y=1
         LDA (LP),Y           ; read line number hi
         STA T0+1
         JSR PRT16            ; print line number
         LDA #' '
         JSR PUTCH
         LDA LP               ; advance LP past 2-byte header
         CLC
         ADC #2
         STA LP
         BCC LS_BODY
         INC LP+1
LS_BODY: LDY #0
         LDA LP               ; v1.1: safety guard -- if LP reaches PE before CR,
         CMP PE               ; stop listing cleanly (guards against corrupted store)
         BNE LS_CHR
         LDA LP+1
         CMP PE+1
         BEQ LS_DONE          ; LP==PE: end cleanly rather than overrunning
LS_CHR:
         LDA (LP),Y
         CMP #CR
         BEQ LS_EOL
         JSR PUTCH
         INC LP
         BNE LS_BODY
         INC LP+1
         BNE LS_BODY          ; always taken here (listing walks RAM pages, never wraps to $00)
LS_EOL:  JSR PRNL              ; print CR+LF at end of each listed line
         INC LP               ; skip CR byte
         BNE LS_LN
         INC LP+1
         BNE LS_LN            ; always taken here

; =============================================================================
; DO_GO  --  GOTO <linenum>  or  GOSUB <linenum>
;
;   In:  IP -> line number digits; LP -> keyword's pre-match start (MTCHKW's
;        contract), so (LP),Y with Y=2 peeks the keyword's 3rd raw character
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: GOTO:  IP = body of target line; stack unwound to RUNSP; RUNGO
;        GOSUB: return frame pushed, then as GOTO
;   Clobbers: A X Y T0 IP SP
;
;   3rd char 'S' (case-insensitive) selects GOSUB; anything else -- including
;   the full word "GOTO" -- falls through as plain GOTO.
;
;   BUGFIX: the 3rd-char peek must happen BEFORE "JSR EXPR" below, not after.
;   EXPR2 unconditionally tries MTCHKW against "CHR$"/"PEEK"/"USR" for every
;   atom -- including a plain number -- and MTCHKW's first action is always
;   "LP = IP", regardless of whether the match succeeds. So by the time EXPR
;   returns, LP no longer points at "GOTO"/"GOSUB" at all; it points wherever
;   EXPR's own atom parsing last left it. Peeking (LP),Y afterward reads
;   garbage relative to the keyword, which is why GOSUB was silently
;   degrading to a plain GOTO (no frame pushed) -- confirmed via sim65c02:
;   "10 GOSUB 100" / "100 PRINT 1" / "110 RETURN" prints 1, then errors
;   "?5 IN 110" (RETURN without GOSUB) because no frame was ever pushed.
; =============================================================================
DO_GO:
         LDY #2
         LDA (LP),Y
         AND #$DF             ; uppercase, matching MTCHKW's case-insensitivity
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

         LDX RUNSP
         TXS                  ; restore SP to pre-statement state
         JMP RUNGO            ; jump into run loop

; --- Pooled Error Handlers ---
DO_ERR_OM:  LDA #ERR_OM          ; Out of memory
         .byte $2C            ; [OPT] The BIT trick: Assembles as BIT $A9xx
DO_ERR_UL:  LDA #ERR_UL          ; (Assembled as A9 <ERR_UL>). 
         .byte $2C            ;  The BIT trick: Assembles as BIT $A9xx
DO_ERR_GS:  LDA #ERR_RET         ; RETURN without GOSUB
         JMP DO_ERROR

; =============================================================================
; DO_REM_CHK  --  REM <comment>  or  RETURN
;
;   In:  IP -> comment text (REM), or nothing (RETURN); LP -> keyword's
;        pre-match start, same (LP),Y=2 peek as DO_GO
;        NOTE: IP and CURLN must be sequential in Zero Page.
;   Out: REM: no-op.  RETURN: pops the frame pushed by the matching GOSUB
;        and resumes execution there.
;   Clobbers: A X (RETURN also: Y IP CURLN SP, via STLN_CHK)
;
;   3rd char 'T' (case-insensitive) selects RETURN ("RE" + T); anything
;   else -- including the full word "REM" -- falls through as a no-op.
; =============================================================================
DO_REM_CHK:
         LDY #2
         LDA (LP),Y
         AND #$DF             ; uppercase
         CMP #'T'
         BNE ST_NOP           ; not RETURN: REM is a no-op
         ; fall through into DO_RETURN
 
DO_RETURN:
         LDX GOSUB_SP
         CPX #GOSUB_TOP       ; stack empty (nothing was ever pushed)?
         BEQ DO_ERR_GS           ; Branch on empty straight to error exit

         ; --- GOSUB Frame Pop (Loop) ---
         ; BUGFIX: STA has no zero-page,Y addressing mode -- STA IP+4,Y
         ; assembles as absolute,Y (99 04 00), so Y=$FC computed as
         ; $0004+252=$0100, not a zero-page wraparound to $0000. The pop
         ; wrote into the base of the hardware stack instead of IP/CURLN,
         ; which were then never restored -- confirmed via sim65c02 listing.
         ; Fixed by using small positive Y (0..3), matching PUSH_LP's own
         ; already-safe range, instead of the negative-offset trick.
         LDY #0
POP_LP:  INX
         LDA 0,X
         STA IP,Y             ; Y=0,1,2,3 -> IP, IP+1, CURLN, CURLN+1
         INY
         CPY #4
         BNE POP_LP
         
         STX GOSUB_SP

         LDX RUNSP
         TXS                  ; unwind hardware stack to pre-statement state
         JSR STLN_CHK         ; resume any remaining statements on this line
         JMP SK_LP            ; then advance to the next line

; =============================================================================
; DO_NEW  --  NEW  :  clear program store and all variables
;
;   Out: PE = PROG; VARS cleared
;   Clobbers: A X PE VARS
; =============================================================================
DO_NEW:
         LDA #<PROG
         STA PE
         LDA #>PROG
         STA PE+1
         LDX #VARS_MAX
         LDA #0
DO_NWZ:  STA VARS,X
         DEX
         BPL DO_NWZ
         ; drop through
; =============================================================================
; DO_END  --  END  :  halt program execution and return to immediate mode
;
;   In:  --
;   Out: RUN cleared; returns to STMT caller, which returns to RUNLP/MAIN
;   Clobbers: RUN
; =============================================================================
DO_END:
RUNEND:  LDA #0
         STA RUN
ST_NOP:  RTS

; =============================================================================
; DO_RUN  --  RUN  :  execute program starting from the first line
;
;   In:  PE = current program end
;   Out: program executes; returns to MAIN on END/error/STOP
;   Clobbers: everything
;
;   RUNLP: top of the per-line execution loop.  Saves SP so GOTO can unwind.
;   RUNGO: mid-loop entry used by GOTO (after IP is already set to body).
; =============================================================================
DO_RUN:
         LDA #<PROG
         STA IP
         LDA #>PROG
         STA IP+1
         LDA #$FF
         STA RUN              ; set run flag ($FF = running)
         LDA #GOSUB_TOP
         STA GOSUB_SP         ; fresh call stack for this run
RUNLP:   TSX
         STX RUNSP            ; snapshot SP for GOTO / error recovery
         LDA IP               ; test IP >= PE (16-bit unsigned)
         CMP PE
         LDA IP+1
         SBC PE+1
         BCS RUNEND           ; IP >= PE: end of program
         JSR GETCI            ; read line-number lo
         STA CURLN
         JSR GETCI            ; read line-number hi
         STA CURLN+1
RUNGO:   JSR STMT_LINE         ; execute statement(s) on this line (honouring ':')
         LDA RUN
         BEQ RUNEND           ; RUN cleared by END/error -- stop
SK_LP:   JSR GETCI            ; advance IP past CR (SKIPEOL inlined)
         CMP #CR
         BNE SK_LP
 	     BEQ RUNLP		; always taken

; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to body (past 2-byte header); CURLN = T0
;        C=1  not found -- IP = PE; CURLN unchanged
;   Clobbers: A Y IP CURLN
;
;   BUGFIX: previously left CURLN untouched, so after any GOTO/GOSUB jump
;   error messages reported the line that started the jump chain rather than
;   the current line (e.g. "?3 IN 10" instead of "?3 IN 90" for an error 9
;   GOSUBs deep). T0 already equals the line just matched, so no extra scan
;   is needed -- just copy it across at GT_OK.
; =============================================================================
GOTOL:
         LDA #<PROG
         STA IP
         LDA #>PROG
         STA IP+1
GT_SC:   LDA IP               ; test IP == PE (end of store)
         CMP PE
         BNE GT_GO
         LDA IP+1
         CMP PE+1
         BEQ GT_ERR           ; not found
GT_GO:   LDY #0
         LDA (IP),Y           ; read line-number lo
         CMP T0               ; compare line-number lo
         BNE GT_NX
         LDY #1
         LDA (IP),Y
         CMP T0+1             ; compare line-number hi
         BEQ GT_OK
GT_NX:   LDY #2               ; skip line: scan for CR from body start
GT_SK:   LDA (IP),Y
         INY
         CMP #CR
         BNE GT_SK
         TYA
         CLC
         ADC IP               ; IP += line length
         STA IP
         BCC GT_SC
         INC IP+1
         BNE GT_SC            ; always taken here (program store never wraps to page $00)
GT_OK:   LDA T0               ; T0 already == the matched line number
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDA IP
         CLC
         ADC #2               ; advance IP past 2-byte header
         STA IP
         BCC GT_R
         INC IP+1
GT_R:    CLC
         RTS
GT_ERR:  SEC
         RTS

; =============================================================================
; EAT_EXPR  --  skip spaces, consume one char (e.g. '('), evaluate expression
;
;   In:  IP -> char to consume (leading spaces skipped first)
;   Out: T0 = expression result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Falls through into EXPR after consuming the opening char.
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
;   Clobbers: A X Y T0 T1 OP IP
;
;   Operator bitmask built in X: LT=1  EQ=2  GT=4
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
         ; ORA REL_MASK,Y       ; Apply new bit
         .DB $19, <REL_MASK, >REL_MASK ; Kludge - need to add to ASM65c02.c
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
         STA OP               ; stash in OP (ZP $0F, idle during eval)
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

RL_TEST: AND OP               ; result bit AND operator mask
         BEQ REL_F            ; no overlap -> false
REL_T:   LDA #$FF
	 .DB $2C              ; Executes "BIT $00A9" (swallows LDA #0)
REL_F:   LDA #0
         STA T0
         STA T0+1
         RTS

RL_NONE: ; No relop found: discard the stacked copy of left (T0 already correct)
         PLA                  ; discard saved T0+1
         PLA                  ; discard saved T0
EXPR_RT: RTS
REL_MASK: .DB 1, 2, 4         ; Tuck this 3-byte table right before EXPR_ADD

; =============================================================================
; EXPR_ADD  --  additive level: + and -
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced
;   Clobbers: A X T0 T1 IP
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
;
;   In:  IP -> expression text
;   Out: T0 = result; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP OP
;
;   The operator ('*', '/', or '%') is saved in OP so a single sign-correction
;   preamble and postamble serves all three operations.  '/' and '%' both use
;   the DIV kernel; they differ only in which of quotient (T1) or remainder
;   (T2) is copied to T0 as the result.
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
; EA_RTS and E1_RET are the same physical RTS byte, shared by EXPR_ADD and EXPR1.
EA_RTS:
E1_RET:  RTS

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
         LDA OP               ; MOD ('%'): use remainder in T2; else quotient T1
         CMP #'%'
         BEQ E1_MOD
         LDA T1               ; copy quotient to T0
         STA T0
         LDA T1+1
         STA T0+1
         JMP E1_SIGN
E1_MOD:  LDA T2               ; '%': copy remainder (T2) to T0
         STA T0
         LDA T2+1
         STA T0+1
         JMP E1_SIGN

; --- MUL/DIV dispatch (operator fetch, sign determination, kernel select) ----
E1_MD:   STA OP               ; save operator ('*', '/', or '%')
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
         LDA OP
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
         LDA OP
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
         LDA T2               ; copy product to T0
         STA T0
         LDA T2+1
         STA T0+1
         ; fall through into E1_SIGN

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
;   Prints:  CR+LF  "?N"  [" IN <linenum>"]  CR+LF  then jumps to MAIN.
;   The " IN <linenum>" annotation is only printed when RUN != 0.
;   DO_break_in is a mid-function entry used by IRQ_HANDLER (BREAK interrupt).
; =============================================================================
DO_ERROR:
         PHA                  ; save error code
         JSR PRNL             ; CR+LF before error message
         LDA #'?'
         JSR PUTCH
         PLA
         CLC
         ADC #'0'
         JSR PUTCH            ; print "?N"
         LDA RUN
         BEQ DO_ERR_NL        ; not running: omit " IN <line>" annotation
DO_break_in:
         LDA #<STR_IN
         JSR PUTSTR           ; print " IN "
         LDA CURLN
         STA T0
         LDA CURLN+1
         STA T0+1
         JSR PRT16            ; print line number
DO_ERR_NL:
         JSR PRNL             ; CR+LF after error message
         JMP MAIN
         
; =============================================================================
; EXPR2  --  atom level: parentheses, unary +/-, CHR$, number literals, variables
;
;   In:  IP -> atom text
;   Out: T0 = atom value; IP advanced past atom
;   Clobbers: A X Y T0 T1 T2 IP
;
;   E2_POS: entry for unary '+' -- consumes the '+' then falls into EXPR2.
;   E2_NEG: entry for unary '-' -- evaluates atom then negates it.
; =============================================================================
E2_POS:  JSR GETCI            ; consume unary '+', then fall through

EXPR2:
         JSR WPEEK
         CMP #'('
         BEQ E2_PAR

E2_NOT_PAR:
         CMP #'-'
         BEQ E2_NEG
         CMP #'+'
         BEQ E2_POS
         LDA #<KW_CHRS
         JSR MTCHKW           ; matched "CHR$"?
         BCS E2_NOTCHRS
         JSR EAT_EXPR         ; consume '(' and evaluate argument -> T0
         JMP WEAT             ; tail call: consume ')' and return
E2_NOTCHRS:
         LDA #<KW_PEEK
         JSR MTCHKW           ; matched "PEEK"?
         BCS E2_NOT_PEEK
         JSR EAT_EXPR         ; consume '(' and evaluate address -> T0
         JSR WEAT             ; consume ')'
         LDY #0
         LDA (T0),Y           ; read byte at address
         STA T0
         LDA #0
         STA T0+1
         RTS

E2_NOT_PEEK:
         LDA #<KW_USR
         JSR MTCHKW           ; matched "USR"?
         BCS E2_NOT_USR
         JSR EAT_EXPR         ; consume '(' and evaluate address -> T0
         JSR WEAT             ; consume ')'
         ; drop through
; =============================================================================
; DO_USR --  machine-code call helper for USR(addr) atom
;   In:  T0 = address of user routine
;   Out: T0 = User return value
;   User code must RET and place any return value in T0 
; =============================================================================
         JMP (T0)             ; indirect tail call to user code

E2_NOT_USR:
         LDY #0
         LDA (IP),Y           ; peek next char without consuming
         CMP #'0'
         BCC E2_VAR
         CMP #'9'+1
         BCS E2_VAR
         JMP PNUM             ; tail call: parse decimal literal -> T0
	
E2_BAD:  JMP REL_F

E2_VAR:  JSR PARSE_VAR               ; variable name (single letter A-Z)?
	 BCS E2_BAD
         TAX
         LDA VARS,X
         STA T0
         LDA VARS+1,X
         STA T0+1
         RTS

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
         JMP NEG16            ; tail call: negate result

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
;   Falls through into GETCI after skipping spaces.
; =============================================================================
WEAT:    JSR WSKIP            ; skip spaces, then fall through

; =============================================================================
; GETCI  --  fetch char at IP and advance IP
;
;   In:  IP -> char to fetch
;   Out: A = char; IP incremented (16-bit)
;   Clobbers: A IP
; =============================================================================
GETCI:   LDY #0
         LDA (IP),Y
         INC IP               ; 16-bit increment
         BNE GETCI_SK
         INC IP+1
; DO_IF_F and GETCI_SK are adjacent because DO_IF (condition-false path)
; and GETCI both want a plain RTS and this is the nearest one.
DO_IF_F:
STLN_RTS:
GETCI_SK: RTS
         
; =============================================================================
; DO_IF  --  IF <expr> THEN <stmt>  (THEN keyword is optional)
;
;   In:  IP -> expression text
;   Out: if true, statement executed; if false, returns (STMT will SKIPEOL)
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Falls through into STMT to execute the consequent.
;   On false, branches to DO_IF_F (= GETCI_SK = nearest preceding RTS).
; =============================================================================
DO_IF:
         JSR EXPR             ; evaluate condition -> T0
         LDA T0
         ORA T0+1
         BEQ DO_IF_F          ; false: return
         LDA #<KW_THEN
         JSR MTCHKW           ; consume optional THEN keyword
         ; fall through into STMT to execute the consequent

; =============================================================================
; STMT_LINE  --  execute one or more statements separated by ':' on a line
;
;   In:  IP -> statement text
;   Out: all colon-separated statements on this line executed; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP
;
;   After each statement, peeks the next character.  If it is ':', consumes
;   it and loops to execute the next statement.  Otherwise returns.
;   MAIN and RUNGO call this instead of STMT directly.
; =============================================================================
STMT_LINE:
         JSR STMT              ; execute one statement
STLN_CHK:
         JSR WPEEK             ; peek next char (skips spaces)
         CMP #':'
         BNE STLN_RTS          ; not ':', done
         JSR GETCI             ; consume ':'
         BNE STMT_LINE         ; always taken here (':' = $3A, nonzero)

; =============================================================================
; STMT  --  execute one statement from IP
;
;   In:  IP -> statement text (spaces will be skipped)
;   Out: statement executed; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Walks ST_TAB trying MTCHKW for each keyword.  On match, loads handler
;   address into T2 and jumps indirect.  Falls through to DO_LET when the
;   $FF sentinel is reached (implicit variable assignment).
; =============================================================================
STMT:
         JSR WPEEK
         CMP #' '             ; anything below space (CR, NUL) means empty line
         BCC GETCI_SK         ; return via nearest preceding RTS
         LDX #0
ST_LP:   LDA ST_TAB,X         ; read keyword lo-byte from table
         BMI ST_LET            ; $FF sentinel: nothing matched
         JSR MTCHKW            ; try to match keyword at IP
         BCS ST_NX             ; no match: advance to next entry
         LDA ST_TAB+1,X       ; matched: load handler lo
         STA T2
         LDA ST_TAB+2,X       ; load handler hi
         STA T2+1
         JMP (T2)             ; dispatch to handler

ST_NX:   INX
         INX
         INX
         BNE ST_LP            ; always taken before $FF sentinel
ST_LET:  ; fall through into DO_LET

; =============================================================================
; DO_LET  --  LET <var> = <expr>  or implicit  <var> = <expr>
;
;   In:  IP -> variable name (with optional leading spaces)
;   Out: variable assigned; IP advanced
;   Clobbers: A X T0 IP
;
;   DL_DN: nearest following RTS -- shared with NEG16/NEG_T1 below.
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
         PLA
         TAX
         LDA T0
         STA VARS,X
         LDA T0+1
         STA VARS+1,X
         RTS
DL_POP:  PLA
         LDA #ERR_UK
         JMP DO_ERROR

; =============================================================================
; NEG_T1 / NEG16  --  two's-complement negate
;
;   NEG_T1:  negate T1 ($08/$09) -- enter here from EXPR1 sign correction
;   NEG16:   negate T0 ($06/$07) -- enter here from all other callers
;
;   In:  T0 or T1 = value to negate (selected by entry point)
;   Out: value negated in-place
;   Clobbers: A X
;
;   DL_DN is the nearest RTS and is shared by DO_LET and NEG16.
; =============================================================================
NEG_T1:  LDX #2
         .DB $2C              ; BIT abs: skips next 2 bytes (the LDX #0)
NEG16:   LDX #0
         LDA #0
NEGX:
         SEC
         SBC T0,X
         STA T0,X
         LDA #0
         SBC T0+1,X
         STA T0+1,X
; DL_DN: shared RTS for DO_LET (bad-variable bail) and NEG16 (fall-through)
DL_DN:   RTS

; =============================================================================
; WPEEK_UC  --  skip spaces at IP, peek first non-space char, convert to UC
;
;   In:  IP -> text (may have leading spaces)
;   Out: A = first non-space char, uppercased; IP unchanged (char not consumed)
;   Clobbers: A
; =============================================================================
WPEEK_UC:
         JSR WSKIP            ; skip spaces; A = first non-space char
         ; fall through into UC

; =============================================================================
; UC  --  convert A to uppercase
;
;   In:  A = any ASCII char
;   Out: A = uppercase if a-z, otherwise unchanged
;   Clobbers: A
; =============================================================================
UC:      CMP #'a'
         BCC RTS_1
         CMP #'{'             ; '{' = 'z' + 1
         BCS RTS_1
         AND #$DF             ; clear bit 5: a-z -> A-Z
RTS_1:   RTS

; =============================================================================
; UCIP  --  uppercase peek at current IP character (without consuming)
;
;   In:  IP -> current input character
;   Out: A = uppercased *(IP)
;   Clobbers: A Y
; =============================================================================
UCIP:    LDY #0
         LDA (IP),Y
         JMP UC

; =============================================================================
; WSKIP_NS / WSKIP / WPEEK  --  skip spaces; return first non-space in A
;
;   In:  IP -> text (may start with spaces)
;   Out: A = first non-space char; IP advanced past any leading spaces
;        (char is NOT consumed -- IP still points to it)
;   Clobbers: A
;
;   Three labels for the same entry point (names document caller intent):
;     WSKIP_NS  -- "no side-effects" alias used by MTCHKW
;     WSKIP     -- skip side-effect is desired
;     WPEEK     -- intent is to inspect without consuming
; =============================================================================
WSKIP_NS:
WSKIP:
WPEEK:   LDY #0
         LDA (IP),Y
         CMP #' '
         BNE RTS_1            ; non-space: return
         JSR GETCI            ; consume space and loop
         BNE WSKIP            ; always taken (' ' = $20, nonzero)

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

; =============================================================================
; PUTCH  --  write one character to the terminal (Kowalski UART)
;
;   In:  A = character to output
;   Out: --
;   Clobbers: --  (flags may change)
;
;   Note: Kowalski UART at IO_OUT ($E001) accepts a write immediately with no
;   busy-wait required.  For hardware with a status register, replace with a
;   poll-then-write loop (see mango_one repo for Apple I PIA variant).
; =============================================================================
PUTCH:   STA IO_OUT
         RTS

; =============================================================================
; GETCH  --  read one character from the terminal (blocking); echo it
;
;   In:  --
;   Out: A = character read
;   Clobbers: A
;
;   Spins on IO_IN ($E004) until non-zero, then echoes via PUTCH (tail call).
;   Note: for hardware with a separate status register, replace with a
;   poll-on-status variant (see mango_one repo for Apple I PIA variant).
; =============================================================================
GETCH:   LDA IO_IN
         BEQ GETCH            ; spin until a char is available
         BNE PUTCH            ; Always taken - echo it, then return (tail call)
                              
; =============================================================================
; STMT DISPATCH TABLE
; Each 3-byte entry:  <kw_lo_byte, <handler_lo, >handler_hi
; STMT walks the table calling MTCHKW on each keyword.
; $FF sentinel causes STMT to fall through to DO_LET (implicit assignment).
; =============================================================================
ST_TAB:
         .DB <KW_PRINT, <DO_PRINT, >DO_PRINT
         .DB <KW_IF,    <DO_IF,    >DO_IF
         .DB <KW_GOTO,  <DO_GO,    >DO_GO
         .DB <KW_LIST,  <DO_LIST,  >DO_LIST
         .DB <KW_RUN,   <DO_RUN,   >DO_RUN
         .DB <KW_NEW,   <DO_NEW,   >DO_NEW
         .DB <KW_INPUT, <DO_INPUT, >DO_INPUT
         .DB <KW_REM,   <DO_REM_CHK, >DO_REM_CHK
         .DB <KW_END,   <DO_END,   >DO_END
         .DB <KW_LET,   <DO_LET,   >DO_LET
         .DB <KW_POKE,  <DO_POKE,  >DO_POKE
         .DB <KW_FREE,  <DO_FREE,  >DO_FREE
         .DB $FF                             ; sentinel: fall through to implicit assign

; =============================================================================
; MTCHKW  --  case-insensitive keyword match at IP
;
;   In:  A = lo-byte of keyword string (hi-byte = STR_PAGE, always)
;   Out: C=0  matched -- IP advanced past the keyword
;        C=1  no match -- IP restored to entry value
;   Clobbers: A Y T1  (T2 is NOT clobbered -- caller may hold STMT jump addr)
;
;   IP is saved in LP on entry and restored on failure.
;   Leading spaces at IP are skipped before attempting the match.
;   Keyword entries are 2-byte uppercase prefixes; MTCHKW then skips any
;   remaining trailing alphabetic characters so full BASIC keywords work.
; =============================================================================
MTCHKW:
         STA T1               ; keyword address lo
         LDA #STR_PAGE
         STA T1+1             ; keyword address hi (always STR_PAGE)
         LDA IP
         STA LP               ; save IP in LP for restore on failure
         LDA IP+1
         STA LP+1
         ; compare first keyword character
         JSR WPEEK_UC
         LDY #0
         CMP (T1),Y
         BNE MK_FAIL
         JSR GETCI
         ; compare second keyword character
         JSR UCIP
         LDY #1
         CMP (T1),Y
         BNE MK_FAIL

         JSR GETCI
         ; matched prefix: skip remaining letters for full BASIC keywords
MK_SKIP: JSR UCIP
         CMP #'A'
         BCC MK_OK
         CMP #'Z'+1
         BCS MK_OK
         JSR GETCI
         BNE MK_SKIP           ; always taken (token chars are nonzero)
MK_OK:   LDY #0
         LDA (IP),Y
         CMP #'$'              ; allow full CHR$ spelling after 2-char CH prefix
         BNE MK_OK_RET
         JSR GETCI
MK_OK_RET:
         CLC                  ; C=0: match
         RTS
MK_FAIL_LAST:
MK_FAIL: LDA LP               ; restore IP to saved position
         STA IP
         LDA LP+1
         STA IP+1
         SEC                  ; C=1: no match
         RTS
ROMEND: ; for audit purposes

; =============================================================================
; Reset / IRQ vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT               ; $FFFC: reset vector
         .DW IRQ_HANDLER        ; $FFFE: IRQ vector
