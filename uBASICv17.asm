; =============================================================================
; uBASIC v17.0  --  2 KB Tiny BASIC for the 65C02
;
; A minimal self-contained Fixed Point Tiny BASIC interpreter in 2 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; NEW to clear and enter your own program).
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
; Credit to Oscar Toledo for his x86 BootBASIC inspiration.
;
; =============================================================================
;
; Statements   : PRINT  IF..THEN  GOTO  LIST  RUN  NEW  INPUT  REM  END  LET
;                POKE   FREE   HELP
; Expressions  : + - * / %   = < > <= >= <>   unary -
;                CHR$(n)   PEEK(addr)   USR(addr)   A-Z variables
; Numbers      : signed 16-bit  (-32768 .. 32767)
; String print : "literals" and CHR$() only; no string variables
;
; Error codes (printed as "?N"):
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division or modulo by zero
;   ?3  out of memory
;   ?4  bad variable name in LET
;
; ---- ROM memory map ---------------------------------------------------------
;   $F800          BRA INIT  (2-byte Kowalski trampoline; see note below)
;   $F802..$F859   string / keyword table  (all on page $F8)
;   $F85A..$FFE6   interpreter code  (2023 bytes)
;   $FFE7..$FFFB   free (21 bytes)
;   $FFFC..$FFFF   reset / IRQ vectors
;
; ---- zero-page layout -------------------------------------------------------
;   $00-$01  IP     interpreter pointer (into IBUF or program store)
;   $02-$03  PE     program end pointer (one past last program byte)
;   $04-$05  LP     line pointer / multi-purpose scratch pointer
;   $06-$07  T0     primary scratch word / expression result
;   $08-$09  T1     secondary scratch word
;   $0A-$0B  T2     tertiary scratch word / STMT indirect-jump target
;   $0C-$0D  CURLN  currently-executing line number
;   $0E      RUN    run flag: $00 = immediate mode, $FF = program running
;   $0F      OP     saved operator for MUL/DIV/MOD kernel ('*', '/', '%')
;   $10-$2F  IBUF   input line buffer (32 bytes)
;   $30-$4F  --     free RAM
;   $50-$8B  VARS   A-Z variable store (2 bytes each, 52 bytes total)
;   $8C      RUNSP  stack-pointer snapshot for GOTO / BREAK unwind
;
; ---- program storage --------------------------------------------------------
;   Base $0200; ceiling RAM_TOP ($1000 for 4 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; ---- Kowalski simulator note ------------------------------------------------
;   Kowalski v2.x executes from the first assembled byte rather than the
;   reset vector.  A two-byte BRA INIT trampoline at $F800 bridges over the
;   string table so both Kowalski and real hardware work identically.
;
; ---- ROM / no-showcase note -------------------------------------------------
;   To start with an empty program store (no pre-loaded showcase), change
;   the two lines in INIT that load SHOWCASE_END into PE to instead load PROG:
;     LDA #<SHOWCASE_END  ->  LDA #<PROG
;     LDA #>SHOWCASE_END  ->  LDA #>PROG
;
; ---- version history --------------------------------------------------------
; v17.0 (Mar 2026)  Comment cleanup for public release.  No code changes.
; v16.0 (Mar 2026)  Size optimisations; 15 bytes saved, 6->21 bytes free.
;   GL_DONE: JSR PUTCH/LDA #LF/JSR PUTCH (8 bytes) -> JSR PRNL (3 bytes).
;   MTCHKW: two near-identical 23-byte compare sequences merged into one
;   shared MK_CMP body.  MK_LP sets Y=0; MK_ISLAST sets Y=1; CPY #1 after
;   GETCI selects loop-back vs. exit.  Y is documented clobbered by MTCHKW.
; v15.0 (Mar 2026)  Bit-7 string termination; 10 bytes net saved.
;   All NUL ($00) string terminators replaced by setting bit 7 of each
;   string's final character.  Named T_x constants used because Kowalski
;   cannot evaluate "ch"|$80 as a .DB argument.  PUTSTR and MTCHKW strip
;   bit 7 before use.  KW_LIST_END ($00) sentinel kept as-is (not a string
;   terminator; consumed by DO_HELP as an end-of-table marker).
; v14.2 (Mar 2026)  IRQ/BREAK handler; INC A / DEC A (65C02 accumulator forms).
; v14.1 (Mar 2026)  Fix DO_HELP infinite loop.
; =============================================================================
;
; ---- assembler mode ---------------------------------------------------------
         .opt proc65c02

; ---- hardware I/O ports ------------------------------------------------------
IO_OUT   = $E001             ; UART output: write character to terminal
IO_IN    = $E004             ; UART input:  read character (0 = no char ready)
IO_IRQ   = $E007             ; write any value to fire a maskable hardware IRQ

; ---- RAM ceiling -------------------------------------------------------------
RAM_TOP  = $1000             ; first address above usable SRAM (4 KB)

; ---- zero-page symbols -------------------------------------------------------
IP       = $00               ; 16-bit: interpreter pointer
PE       = $02               ; 16-bit: program end (one past last byte)
LP       = $04               ; 16-bit: line pointer / multi-purpose scratch
T0       = $06               ; 16-bit: primary scratch word / expression result
T1       = $08               ; 16-bit: secondary scratch word
T2       = $0A               ; 16-bit: tertiary scratch word / STMT jump target
CURLN    = $0C               ; 16-bit: currently-executing line number
RUN      = $0E               ; 8-bit:  run flag ($00 = immediate, $FF = running)
OP       = $0F               ; 8-bit:  saved operator for MUL/DIV/MOD ('*'/'/'/'%')
IBUF     = $10               ; 32-byte input line buffer
VARS     = $50               ; 52-byte variable store (A-Z, 2 bytes each)
RUNSP    = $8C               ; 8-bit:  stack-pointer snapshot for GOTO/BREAK unwind

; ---- program store base ------------------------------------------------------
PROG     = $0200

; ---- error codes -------------------------------------------------------------
ERR_SN   = 0                 ; syntax / bad expression
ERR_UL   = 1                 ; undefined line number
ERR_OV   = 2                 ; division or modulo by zero
ERR_OM   = 3                 ; out of memory
ERR_UK   = 4                 ; bad variable name in LET

; ---- miscellaneous constants -------------------------------------------------
IBUF_MAX = 31                ; highest valid index into IBUF
VARS_MAX = $3B               ; highest X index for STZ VARS,X loop ($50..$8B)
CR       = $0D               ; ASCII carriage return
LF       = $0A               ; ASCII line feed
BS       = $08               ; ASCII backspace

; =============================================================================
; ROM START  ($F800)
; =============================================================================
         .ORG $F800

; Kowalski trampoline: Kowalski executes from the first assembled byte rather
; than the reset vector.  Real hardware reaches INIT via $FFFC instead.
         BRA INIT

; =============================================================================
; STRING / KEYWORD TABLE  (page $F8, $F802 onward)
;
; All strings and keywords must remain on the same page as STR_BANNER.
; PUTSTR and MTCHKW address them using STR_PAGE as the fixed hi-byte, so a
; single lo-byte pointer suffices and no page crossing can occur.
;
; TERMINATION: the last byte of every string has bit 7 set (value |= $80).
;   PUTSTR strips bit 7 with AND #$7F before printing the final character.
;   MTCHKW strips bit 7 before comparing the final keyword character.
;   All string content is 7-bit ASCII so bit 7 never occurs naturally --
;   the scheme is unambiguous.
;
; EXCEPTION: KW_LIST_END ($00) is an end-of-table sentinel used by DO_HELP.
;   It is NOT a string terminator and must remain $00.
;
; Named T_x constants are used for bit-7-set final characters because the
; Kowalski assembler cannot evaluate "ch"|$80 inside a .DB argument.  Each
; constant is simply the ASCII value plus 128 (addition equals OR here since
; all base characters are below $80).
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string and keyword addresses

; ---- bit-7 terminal-character constants -------------------------------------
; Naming: T_<char>  where <char> is the ASCII letter or symbol.
T_LF  = 138              ; $0A + $80  (LF  -- final byte of STR_CRLF)
T_SP  = 160              ; $20 + $80  (' ' -- final byte of STR_IN)
T_D   = 196              ; $44 + $80  ('D' -- END)
T_E   = 197              ; $45 + $80  ('E' -- POKE, FREE)
T_F   = 198              ; $46 + $80  ('F' -- IF)
T_K   = 203              ; $4B + $80  ('K' -- BREAK, PEEK)
T_M   = 205              ; $4D + $80  ('M' -- REM)
T_N   = 206              ; $4E + $80  ('N' -- RUN, THEN)
T_O   = 207              ; $4F + $80  ('O' -- GOTO)
T_P   = 208              ; $50 + $80  ('P' -- HELP)
T_R   = 210              ; $52 + $80  ('R' -- USR)
T_T   = 212              ; $54 + $80  ('T' -- PRINT, LIST, INPUT, LET)
T_W   = 215              ; $57 + $80  ('W' -- NEW)
T_DS  = 164              ; $24 + $80  ('$' -- CHR$)

; ---- human-readable strings -------------------------------------------------
; Last byte of each string has bit 7 set; PUTSTR masks it before printing.
STR_BANNER: .DB "uBASIC v15.0"  ; startup banner; falls into STR_CRLF for CR+LF
STR_CRLF:   .DB CR, T_LF       ; CR + LF
STR_IN:     .DB " IN", T_SP    ; " IN " (error annotation: " IN <linenum>")
STR_BREAK:  .DB CR, LF, "BREA", T_K  ; "\r\nBREAK"

; ---- keyword strings --------------------------------------------------------
; Last character of each keyword has bit 7 set (T_x constant).
; MTCHKW masks bit 7 before comparing against uppercased input.
KW_TAB:
KW_PRINT:   .DB "PRIN", T_T
KW_IF:      .DB "I", T_F
KW_GOTO:    .DB "GOT", T_O
KW_LIST:    .DB "LIS", T_T
KW_RUN:     .DB "RU", T_N
KW_NEW:     .DB "NE", T_W
KW_INPUT:   .DB "INPU", T_T
KW_REM:     .DB "RE", T_M
KW_END:     .DB "EN", T_D
KW_LET:     .DB "LE", T_T
KW_THEN:    .DB "THE", T_N
KW_CHRS:    .DB "CHR", T_DS   ; opening '(' consumed separately by EAT_EXPR
KW_POKE:    .DB "POK", T_E
KW_FREE:    .DB "FRE", T_E    ; also used as display string "FREE" by DO_FREE
KW_PEEK:    .DB "PEE", T_K
KW_USR:     .DB "US", T_R
KW_HELP:    .DB "HEL", T_P
KW_LIST_END:.DB 0             ; $00 end-of-table sentinel for DO_HELP (not a string terminator)

; =============================================================================
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or Kowalski BRA trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
;
;   Clears all zero-page RAM, sets the stack, enables IRQs, points PE at the
;   end of the pre-loaded showcase program, prints the banner + free count,
;   then falls into MAIN.
; =============================================================================
INIT:
         LDX #$FF
         TXS                  ; set stack to top of page 1
         CLD                  ; ensure binary (not decimal) mode
         CLI                  ; enable maskable IRQs (for $E007 Break key)
INIT_Z:  STZ 0,X              ; clear zero-page byte at X (65C02: STZ zp,X)
         DEX
         BPL INIT_Z
         LDA #<SHOWCASE_END   ; point PE at end of pre-loaded showcase program
         STA PE               ; (change to PROG/PROG for no pre-loaded program)
         LDA #>SHOWCASE_END
         STA PE+1
         LDA #<STR_BANNER
         JSR PUTSTR           ; print banner + CR+LF (STR_CRLF follows immediately)
         JSR DO_FREE          ; print free byte count
         ; fall through into MAIN

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
;
;   In:  -- (falls through from INIT, or jumped to from DO_ERROR / DO_END)
;   Out: never returns
;   Clobbers: everything (infinite loop)
;
;   Reads one line from the terminal.  Lines that start with a digit are
;   routed to EDITLN (program store editor); all others are executed
;   immediately via STMT_LINE.
; =============================================================================
MAIN:
         STZ RUN              ; clear run flag (immediate mode)
         JSR GETLINE_M        ; print "> "; read line; set IP = IBUF
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
         JSR STMT_LINE        ; execute as immediate statement
         BRA MAIN

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
         BRA MAIN

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;
;   In:  -- (entered via hardware IRQ; CPU has pushed PChi, PClo, P)
;   Out: if RUN != 0: unwinds stack, prints BREAK+linenum, jumps to MAIN
;        if RUN == 0: silently ignored (RTI)
;   Clobbers: A X  (stack deliberately abandoned when running)
;
;   Triggered by writing any value to IO_IRQ ($E007) -- the "Break" key.
;   When a program is running: restores the stack to RUNSP (unwinding all
;   call frames), prints "\r\nBREAK IN <linenum>\r\n", then jumps to MAIN.
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
         BRA DO_break_in      ; print " IN <linenum>\r\n" then jump to MAIN
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
         JSR WPEEK_UC         ; skip spaces; peek var name uppercased
         CMP #'A'
         BCC DO_IN_DN         ; not a letter -- nothing to do
         CMP #'Z'+1
         BCS DO_IN_DN
         JSR GETCI            ; consume the variable letter
         JSR UC               ; ensure uppercase
         SEC
         SBC #'A'
         ASL                  ; -> VARS byte offset (0, 2, 4 ...)
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
; DO_IN_DN and ST_NOP are adjacent because DO_INPUT and the REM handler both
; want a plain RTS and this is the nearest one.
DO_IN_DN:
ST_NOP:  RTS

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
;
;   Supports backspace (BS) to delete the last character.
;   Overflow characters (beyond IBUF_MAX) are silently discarded.
;   After CR is received, outputs CR+LF via PRNL before returning.
;
;   Trick: GETLINE_M loads '>' then uses a .DB $2C (BIT abs opcode) as a
;   2-byte skip to fall past the LDA #'?' in GETLINE_I.
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
         BRA GL_LP
GL_STORE:
         CPX #IBUF_MAX
         BCS GL_LP            ; buffer full -- ignore overflow
         STA IBUF,X
         INX
         BRA GL_LP
GL_DONE: STA IBUF,X           ; store CR as in-band terminator
         JSR PRNL             ; output CR+LF (v16: replaces JSR PUTCH/LDA #LF/JSR PUTCH, -5 bytes)
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
;   Clobbers: A X T0 T2
;
;   Stops at the first non-digit without consuming it.
;   Algorithm: T0 = T0*10 + digit, using T0*8 + T0*2 to avoid a multiply.
;   Called by EDITLN, DO_GOTO, and EXPR2.
; =============================================================================
PNUM:
         JSR WSKIP            ; skip leading spaces
         STZ T0               ; clear result
         STZ T0+1
PN_LP:   LDA (IP)             ; 65C02 zp-indirect: peek without consuming
         SEC
         SBC #'0'             ; map '0'-'9' to 0-9
         BCC PN_DN            ; below '0' -- done  (branches to shared RTS above)
         CMP #10
         BCS PN_DN            ; above '9' -- done
         PHA                  ; save digit (0-9)
         INC IP               ; consume digit: 16-bit increment
         BNE PN_SK
         INC IP+1
PN_SK:   ASL T0               ; T0 = T0 * 2
         ROL T0+1
         LDA T0               ; save T0*2 lo for later addition
         STA T2
         LDX T0+1             ; save T0*2 hi in X (1 byte vs STX T2+1)
         ASL T0               ; T0 = T0 * 4
         ROL T0+1
         ASL T0               ; T0 = T0 * 8
         ROL T0+1
         PLA                  ; restore digit
         CLC
         ADC T0               ; digit + T0*8 lo
         ADC T2               ; + T0*2 lo
         STA T0
         TXA
         ADC T0+1             ; T0*2 hi + T0*8 hi + carry
         STA T0+1
         BRA PN_LP

; =============================================================================
; DELINE  --  remove the line at LP from the program store; adjust PE
;
;   In:  LP -> start of line to delete (the line-number lo byte)
;        PE -> one past the last program byte
;   Out: line removed; PE decremented by line length
;   Clobbers: A X Y T0 T1 T2 PE
;
;   Measures the line length by scanning for CR (starting at body offset 2),
;   then shifts all subsequent bytes forward to close the gap.
; =============================================================================
DELINE:
         LDY #2
DL_LL:   LDA (LP),Y           ; scan body + CR
         INY
         CMP #CR
         BNE DL_LL            ; Y now = bytes from LP to first byte AFTER CR
         STY T1               ; T1 = line length (header + body + CR)
         TYA
         CLC
         ADC LP
         STA T0               ; T0 = LP + length = first byte of next line
         LDA LP+1
         ADC #0
         STA T0+1
         LDA PE               ; T2 = PE - T0 = bytes to copy forward
         SEC
         SBC T0
         STA T2
         LDA PE+1
         SBC T0+1
         STA T2+1
         LDA T2
         ORA T2+1
         BEQ DL_UPD           ; nothing to shift -- just update PE
         LDY #0
DL_CP:   LDA (T0),Y           ; forward copy: (T0),Y -> (LP),Y
         STA (LP),Y
         INY
         BNE DL_NHI
         INC T0+1             ; Y wrapped -- advance both hi-bytes
         INC LP+1
DL_NHI:  LDA T2               ; decrement 16-bit counter T2
         BNE DL_DC
         DEC T2+1
DL_DC:   DEC T2
         LDA T2
         ORA T2+1
         BNE DL_CP
DL_UPD:  LDA PE               ; PE -= line length
         SEC
         SBC T1
         STA PE
         BCS DL_OK
         DEC PE+1
; EL_DN and DL_OK are adjacent because both EDITLN (delete-only path) and
; DELINE share this single RTS.
EL_DN:
DL_OK:   RTS

; =============================================================================
; EDITLN  --  insert, replace, or delete a numbered line in the program store
;
;   In:  IP -> line-number digits in IBUF (spaces already skipped by MAIN)
;   Out: program store updated; IP, LP, PE adjusted
;   Clobbers: A X Y T0 T1 T2 IP LP PE CURLN
;
;   Parses the line number, locates the insertion point by scanning the store
;   in line-number order, deletes any existing line with the same number, then
;   inserts the new body.  An empty body (CR only) means delete-only.
;
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
         BRA EL_INS
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
         BRA EL_FL
EL_FND:  JSR DELINE            ; delete existing line at LP
EL_INS:  JSR WSKIP             ; skip spaces between line number and body
         LDA (IP)              ; peek first body character
         CMP #CR
         BEQ EL_DN             ; CR only: delete-only (no body to insert)
         CMP #0
         BEQ EL_DN             ; NUL (empty): same
         ; fall through into INSLINE to insert the body

; =============================================================================
; INSLINE  --  insert one line at LP; body text comes from IP (in IBUF)
;
;   In:  LP -> insertion point in program store
;        IP -> first byte of body text in IBUF (after the line number)
;        CURLN = 16-bit line number to store in the 2-byte header
;        PE -> one past the last current program byte
;   Out: new line written; PE advanced by line size
;   Clobbers: A X Y T0 T1 T2 IP LP PE
;
;   Counts body + CR to get total line size, checks OOM, shifts existing
;   program store upward to make room, writes header then body.
; =============================================================================
INSLINE:
         LDY #0
IN_CNT:  LDA (IP),Y           ; count body bytes until CR
         CMP #CR
         BEQ IN_CE
         INY
         BRA IN_CNT
IN_CE:   INY                  ; include CR itself
         TYA
         CLC
         ADC #2               ; +2 for the line-number header
         TAX                  ; X = total line size (header + body + CR)
         PHX                  ; save line size on stack
         SEC                  ; OOM check: new PE = PE + line_size
         ADC PE
         STA T2
         LDA PE+1
         ADC #0
         STA T2+1
         LDA T2+1
         CMP #>RAM_TOP        ; would we cross RAM_TOP?
         BCC IN_OK
         PLX
         LDA #ERR_OM
         JMP DO_ERROR
IN_OK:   LDA PE               ; T2 = PE - LP (bytes of store above insertion point)
         SEC
         SBC LP
         STA T2
         LDA PE+1
         SBC LP+1
         STA T2+1
         LDA T2
         ORA T2+1
         BEQ IN_SHIFT         ; nothing above LP: skip the shift
         LDA PE               ; T0 = PE - 1  (top byte of existing store)
         SEC
         SBC #1
         STA T0
         LDA PE+1
         SBC #0
         STA T0+1
         TXA                  ; T1 = T0 + line_size (destination for top byte)
         CLC
         ADC T0
         STA T1
         LDA T0+1
         ADC #0
         STA T1+1
IN_BK:   LDY #0               ; copy one byte: (T0) -> (T1), working downward
         LDA (T0),Y
         STA (T1),Y
         LDA T0               ; decrement T0 (16-bit)
         BNE IN_D0
         DEC T0+1
IN_D0:   DEC T0
         LDA T1               ; decrement T1 (16-bit)
         BNE IN_D1
         DEC T1+1
IN_D1:   DEC T1
         LDA T2               ; decrement shift counter T2 (16-bit)
         BNE IN_D2
         DEC T2+1
IN_D2:   DEC T2
         LDA T2
         ORA T2+1
         BNE IN_BK
IN_SHIFT:
         PLX                  ; restore line size
         TXA
         CLC
         ADC PE               ; advance PE by line size
         STA PE
         BCC IN_HDR
         INC PE+1
IN_HDR:  LDY #0
         LDA CURLN
         STA (LP),Y           ; write line number lo
         INY
         LDA CURLN+1
         STA (LP),Y           ; write line number hi  (Y=1 here)
         LDA LP               ; T0 = LP + 2  (where body bytes go)
         CLC
         ADC #2
         STA T0
         LDA LP+1
         ADC #0
         STA T0+1
         DEY                  ; Y = 0  (was 1; DEY cheaper than LDY #0)
IN_CP:   LDA (IP),Y           ; copy body + CR from IBUF to store
         STA (T0),Y
         CMP #CR
         BEQ IN_DN
         INY
         BRA IN_CP
; DP_RET and IN_DN are adjacent because DO_PRINT (semicolon suppress path) and
; INSLINE both want a plain RTS and this is the nearest one.
DP_RET:
IN_DN:   RTS

; =============================================================================
; DO_FREE  --  FREE  :  print free program-store bytes
;
;   In:  PE = current program end pointer
;   Out: "<N> FREE\r\n" printed to terminal
;   Clobbers: A T0
;
;   Computes RAM_TOP - PE (16-bit), prints the count via PRT16, emits a
;   space, then prints "FREE\r\n" by calling PUTSTR(KW_FREE) followed by
;   PRNL.  KW_FREE doubles as the display string; no separate STR_FREE needed.
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
         LDA #' '
         JSR PUTCH            ; space before "FREE"
         LDA #<KW_FREE
         JSR PUTSTR           ; print "FREE" (reuses keyword string)
         BRA PRNL             ; print CR+LF and return (tail call)
         
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
         CMP #0
         BEQ DP_NL
         CMP #'"'
         BNE DP_EXPR
         JSR GETCI            ; consume opening '"'
DP_STR:  JSR GETCI            ; read string body char by char
         CMP #'"'
         BEQ DP_AFT           ; closing '"' -- go check for ';'
         CMP #CR
         BEQ DP_NL            ; unterminated string -- print CR/LF and stop
         JSR PUTCH
         BRA DP_STR
DP_EXPR: LDA #<KW_CHRS
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_NORM
         JSR EAT_EXPR         ; consume '(' and evaluate argument
         JSR WEAT             ; consume ')'
         LDA T0
         JSR PUTCH
         BRA DP_AFT
DP_NORM: JSR EXPR             ; numeric expression
         JSR PRT16
DP_AFT:  JSR WPEEK
         CMP #';'
         BNE DP_NL
         JSR GETCI            ; consume ';'
         JSR WPEEK
         CMP #CR
         BEQ DP_RET           ; trailing ';': suppress CR/LF (DP_RET = IN_DN = RTS above)
         CMP #0
         BEQ DP_RET
         BRA DP_TOP

; (DO_PRINT falls through into PRNL/PUTSTR at DP_NL when no items remain)
; =============================================================================
; DO_HELP  --  HELP  :  print all keywords separated by spaces
;
;   In:  --
;   Out: all keyword strings printed to terminal, then CR+LF
;   Clobbers: A Y T2
;
;   Walks the keyword table from KW_TAB to the $00 sentinel at KW_LIST_END.
;   T2 is used as the lo-byte pointer (STR_PAGE hi-byte supplied by PUTSTRZP).
;   PUTSTRZP returns with T2 pointing at the last (bit-7-set) byte of the
;   keyword just printed.  INC T2 steps past it to the first byte of the next
;   entry.  LDA (T2),Y (Y=0 on return) reads that byte; $00 means end of table.
; =============================================================================
DO_HELP:
         LDA #<KW_TAB         ; T2 = start of keyword table
         STA T2
DH_LP:   JSR PUTSTRZP         ; print keyword; T2 left at last (bit-7) byte
         INC T2               ; step past last char to first byte of next entry
         LDA (T2),Y           ; Y=0 on return from PUTSTRZP
         BEQ DH_DN            ; $00 = KW_LIST_END: done
         LDA #' '
         JSR PUTCH            ; space between keywords
         BRA DH_LP
DH_DN:                        ; fall through into PRNL for final CR+LF

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
;   strips it, PUTCH prints it, then the routine returns.  NUL ($00) is no
;   longer used as a string terminator.
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
         BRA PS_LP
PS_LAST: AND #$7F             ; strip bit 7 from last character
         JSR PUTCH            ; print last character
; LS_DONE and PS_DN are adjacent because DO_LIST (end-of-program path) and
; PUTSTR (end-of-string path) both want a plain RTS here.
LS_DONE:
PS_DN:   RTS

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
LS_GO:   LDA (LP)             ; read line number lo  (65C02 zp-indirect, no Y needed)
         STA T0
         LDY #1
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
LS_BODY: LDA (LP)             ; 65C02 zp-indirect: no Y needed here
         CMP #CR
         BEQ LS_EOL
         JSR PUTCH
         INC LP
         BNE LS_BODY
         INC LP+1
         BRA LS_BODY
LS_EOL:  JSR PRNL              ; print CR+LF at end of each listed line
         INC LP               ; skip CR byte
         BNE LS_LN
         INC LP+1
         BRA LS_LN

; =============================================================================
; DO_GOTO  --  GOTO <linenum>
;
;   In:  IP -> line number digits
;   Out: IP = body of target line; stack unwound to RUNSP; continues at RUNGO
;   Clobbers: A X T0 IP SP
; =============================================================================
DO_GOTO:
         JSR PNUM             ; parse target line number -> T0
         JSR GOTOL            ; find line: C=0 found (IP at body), C=1 not found
         BCC DG_OK
         LDA #ERR_UL
         JMP DO_ERROR
DG_OK:   LDX RUNSP
         TXS                  ; restore SP to pre-statement state (unwinds call stack)
         BRA RUNGO            ; jump into run loop at statement-execute point

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
         BRA RUNLP

; =============================================================================
; DO_END  --  END  :  halt program execution and return to immediate mode
;
;   In:  --
;   Out: RUN cleared; returns to STMT caller, which returns to RUNLP/MAIN
;   Clobbers: RUN
;
;   DO_END is the STMT dispatch handler.  RUNEND is the internal label reached
;   when the program runs off the end of the store, or when RUN is cleared by
;   another path.  Both converge here: STZ RUN then RTS.
; =============================================================================
DO_END:
RUNEND:  STZ RUN
         RTS

; =============================================================================
; DO_NEW  --  NEW  :  clear program store and all variables
;
;   In:  --
;   Out: PE = PROG; VARS cleared
;   Clobbers: A X PE VARS
; =============================================================================
DO_NEW:
         LDA #<PROG
         STA PE
         LDA #>PROG
         STA PE+1
         LDX #VARS_MAX
DO_NWZ:  STZ VARS,X           ; 65C02: STZ zp,X (2 bytes; no LDA #0 needed)
         DEX
         BPL DO_NWZ
         RTS

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
         LDA T0                ; value byte
         PLX                   ; pull address lo -> X  (65C02 PLX)
         STX T1
         PLX                   ; pull address hi -> X
         STX T1+1
         LDY #0
         STA (T1),Y            ; write value to address
         RTS

; =============================================================================
; GOTOL  --  find line by number in program store
;
;   In:  T0 = 16-bit target line number
;   Out: C=0  found -- IP points to body (past 2-byte header)
;        C=1  not found -- IP = PE
;   Clobbers: A Y IP
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
GT_GO:   LDA (IP)             ; read line-number lo  (65C02 zp-indirect, no Y needed)
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
         BRA GT_SC
GT_OK:   LDA IP
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
; EXPR  --  evaluate a full expression including relational operators
;
;   In:  IP -> expression text
;   Out: T0 = signed 16-bit result; true=$FFFF, false=$0000
;        IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Precedence (lowest to highest): relational < additive < multiplicative < unary/atom
;   Relational operators: = < > <= >= <>
;   Evaluates left operand via EXPR_ADD, then checks for one relational op.
; =============================================================================
EXPR:
         JSR EXPR_ADD
         JSR WPEEK
         CMP #'='
         BEQ EQ_OP
         CMP #'<'
         BEQ LT_OP
         CMP #'>'
         BEQ GT_OP            ; branch into GT_OP (and thence to EXPR_RT's RTS)
; EXPR_RT: nearest RTS -- EXPR falls here when no relational operator is found.
EXPR_RT: RTS

; --- REL_SETUP  --  shared preamble for all relational operators ---------------
;
;   In:  T0 = left operand (already evaluated)
;        IP -> start of right operand (operator char already consumed by caller)
;   Out: T0 = right operand; T1 = left operand (swapped for easy comparison)
;   Clobbers: A T0 T1
; -----------------------------------------------------------------------------
REL_SETUP:
         LDA T0               ; push left operand
         PHA
         LDA T0+1
         PHA
         JSR EXPR_ADD         ; evaluate right operand -> T0
         PLA
         STA T1+1             ; pop left operand into T1 (hi first -- stack order)
         PLA
         STA T1
         RTS

; --- EQ_OP  ( = ) ---
EQ_OP:   JSR GETCI            ; consume '='
         JSR REL_SETUP
         LDA T1
         CMP T0
         BNE EQ_F
         LDA T1+1
         CMP T0+1
         BEQ REL_T            ; equal: true
EQ_F:    BRA REL_F

; --- LT_OP  ( <  also entry for <=  <> ) ---
LT_OP:   JSR GETCI            ; consume '<'
         LDA (IP)             ; peek next char without consuming (65C02 zp-indirect)
         CMP #'>'
         BEQ NE_OP            ; '<>' sequence
         CMP #'='
         BEQ LE_OP            ; '<=' sequence
         JSR REL_SETUP        ; plain '<': T1 - T0; negative means T1 < T0
         LDA T1
         SEC
         SBC T0
         LDA T1+1
         SBC T0+1
         BMI REL_T
         BRA REL_F

; --- NE_OP  ( <> ) ---
NE_OP:   JSR GETCI            ; consume '>'
         JSR REL_SETUP
         LDA T1
         CMP T0
         BNE REL_T            ; any difference: true
         LDA T1+1
         CMP T0+1
         BNE REL_T
         BRA REL_F

; --- LE_OP  ( <= ) ---
LE_OP:   JSR GETCI            ; consume '='
         JSR REL_SETUP        ; T0 - T1; negative means T0 < T1, i.e. NOT <=
         LDA T0
         SEC
         SBC T1
         LDA T0+1
         SBC T1+1
         BMI REL_F

; --- REL_T / REL_F  --  common true / false returns ---------------------------
REL_T:   LDA #$FF
         STA T0
         STA T0+1
         RTS
REL_F:   STZ T0
         STZ T0+1
         RTS

; --- GT_OP  ( >  also entry for >= ) ---
GT_OP:   JSR GETCI            ; consume '>'
         LDA (IP)             ; peek next char without consuming (65C02 zp-indirect)
         CMP #'='
         BEQ GE_OP            ; '>=' sequence
         JSR REL_SETUP        ; plain '>': T0 - T1; negative means T0 < T1 => false
         LDA T0
         SEC
         SBC T1
         LDA T0+1
         SBC T1+1
         BMI REL_T
         BRA REL_F

; --- GE_OP  ( >= ) ---
GE_OP:   JSR GETCI            ; consume '='
         JSR REL_SETUP        ; T1 - T0; negative means T1 < T0, i.e. NOT >=
         LDA T1
         SEC
         SBC T0
         LDA T1+1
         SBC T0+1
         BMI REL_F
         BRA REL_T

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
         BNE EA_RTS           ; not + or -: done (EA_RTS = E1_RET = shared RTS below)
EA_DO:   LDX T0+1
         PHX                  ; push T0 hi
         LDX T0
         PHX                  ; push T0 lo
         PHA                  ; push operator
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
         BRA EA_LP

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
;
;   EA_RTS and E1_RET share the same physical RTS byte: EXPR_ADD's loop exit
;   (EA_RTS) and EXPR1's loop exit (E1_RET) both branch here when no matching
;   operator is found.
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

; --- DIV kernel (placed before MUL so the BEQ E1_DO_DIV in the dispatch fits) -
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
         BRA E1_SIGN          ; apply sign
E1_MOD:  LDA T2               ; '%': copy remainder (T2) to T0
         STA T0
         LDA T2+1
         STA T0+1
         BRA E1_SIGN          ; apply sign

; --- MUL/DIV dispatch (operator fetch, sign determination, kernel select) ----
E1_MD:   STA OP               ; save '*' or '/'
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
E1_POS:  JMP E1_LP            ; loop: check for another * or / (BRA out of range)

E1_OVFL: LDA #ERR_OV          ; division or modulo by zero
         ; fall through into DO_ERROR


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
         BNE E2_NOT_PAR       ; not '(': check other atoms
         BRA E2_PAR           ; parenthesised sub-expression (within BRA range)
E2_NOT_PAR:
         CMP #'-'
         BEQ E2_NEG
         CMP #'+'
         BEQ E2_POS
         LDA #<KW_CHRS
         JSR MTCHKW           ; matched "CHR$"?
         BCS E2_NOTCHRS
         JSR EAT_EXPR         ; consume '(' and evaluate argument -> T0
         BRA WEAT             ; tail call: consume ')' and return (within BRA range)
E2_NOTCHRS:
         LDA #<KW_PEEK
         JSR MTCHKW           ; matched "PEEK"?
         BCS E2_NOT_PEEK
         JSR EAT_EXPR         ; consume '(' and evaluate address -> T0
         JSR WEAT             ; consume ')'
         LDY #0
         LDA (T0),Y           ; read byte at address (T0 is ZP ptr $06/$07)
         STA T0
         STZ T0+1
         RTS
E2_NOT_PEEK:
         LDA #<KW_USR
         JSR MTCHKW           ; matched "USR"?
         BCS E2_NOT_USR
         JSR EAT_EXPR         ; consume '(' and evaluate address -> T0
         JSR WEAT             ; consume ')'
         LDA T0               ; copy address to T2
         STA T2
         LDA T0+1
         STA T2+1
         JMP USR_CALL         ; tail-call helper; it does JMP(T2), user RTS -> USR_RET
E2_NOT_USR:
         LDA (IP)             ; peek next char without consuming (65C02 zp-indirect)
         CMP #'0'
         BCC E2_VAR
         CMP #'9'+1
         BCS E2_VAR
         JMP PNUM             ; tail call: parse decimal literal -> T0

E2_BAD:  STZ T0               ; unrecognised atom: return 0 (no error)
         STZ T0+1
         RTS

E2_VAR:  JSR UC               ; variable name (single letter A-Z)?
         CMP #'A'
         BCC E2_BAD
         CMP #'Z'+1
         BCS E2_BAD
         JSR GETCI            ; consume the letter
         JSR UC
         SEC
         SBC #'A'
         ASL                  ; -> VARS byte offset (0, 2, 4 ...)
         TAX
         LDA VARS,X
         STA T0
         LDA VARS+1,X
         STA T0+1
         RTS

E2_NEG:  JSR E2_POS           ; consume '-', evaluate atom
         JMP NEG16            ; tail call: negate result (BRA out of range)

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
WEAT:    JSR WSKIP            ; skip spaces (result in A), then fall through

; =============================================================================
; GETCI  --  fetch char at IP and advance IP
;
;   In:  IP -> char to fetch
;   Out: A = char; IP incremented (16-bit)
;   Clobbers: A IP
; =============================================================================
GETCI:   LDA (IP)             ; 65C02 zp-indirect (2 bytes, no Y needed)
         INC IP               ; 16-bit increment
         BNE GETCI_SK
         INC IP+1
; DO_IF_F and GETCI_SK are adjacent because DO_IF (condition-false path)
; and GETCI both want a plain RTS and this is the nearest one.
DO_IF_F:
STLN_RTS: ; RTS
GETCI_SK: RTS

; =============================================================================
; DO_IF  --  IF <expr> THEN <stmt>  (THEN keyword is optional)
;
;   In:  IP -> expression text
;   Out: if true, statement executed; if false, returns (STMT will SKIPEOL)
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Falls through into STMT to execute the consequent (saves JSR+RTS pair).
;   On false, branches to DO_IF_F (= GETCI_SK = nearest preceding RTS).
; =============================================================================
DO_IF:
         JSR EXPR             ; evaluate condition -> T0
         LDA T0
         ORA T0+1
         BEQ DO_IF_F          ; false: return (STMT will skip rest of line via SK_LP)
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
;   DO_IF falls through into STMT (not STMT_LINE), so false-IF leaves IP at
;   the "THEN ..." text; STMT_LINE's WPEEK then sees a letter (not ':') and
;   returns safely -- the rest of the line is skipped by RUNGO's SK_LP loop.
; =============================================================================
STMT_LINE:
         JSR STMT              ; execute one statement
STLN_CHK:
         JSR WPEEK             ; peek next char (skips spaces)
         CMP #':'
         BNE STLN_RTS          ; not ':', done
         JSR GETCI             ; consume ':'
         BRA STMT_LINE         ; execute next statement
; STLN_RTS shares DO_IF_F = GETCI_SK, the nearest preceding RTS.

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
;
;   ST_NOP (RTS for REM and DO_INPUT) is at DO_IN_DN near the top of the file;
;   ST_LET falls through into DO_LET immediately below.
; =============================================================================
STMT:
         JSR WPEEK
         CMP #' '             ; anything below space (CR, NUL) means empty line
         BCC GETCI_SK         ; return via nearest preceding RTS (= DO_IF_F = GETCI_SK)
         LDX #0
ST_LP:   LDA ST_TAB,X         ; read keyword lo-byte from table
         BMI ST_LET            ; $FF sentinel: nothing matched
         JSR MTCHKW            ; try to match keyword at IP
         BCS ST_NX             ; no match: advance to next entry
         LDA ST_TAB+1,X       ; matched: load handler lo
         STA T2
         LDA ST_TAB+2,X       ; load handler hi
         STA T2+1
         JMP (T2)             ; dispatch to handler (T2 = $0A/$0B)

ST_NX:   INX
         INX
         INX
         BRA ST_LP
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
         JSR WPEEK_UC         ; skip spaces, peek var name, uppercase
         CMP #'A'
         BCC DL_DN            ; not a letter: bail (DL_DN = NEG16/DL_DN = RTS below)
         CMP #'Z'+1
         BCS DL_DN
         JSR GETCI            ; consume variable letter
         JSR UC
         SEC
         SBC #'A'
         ASL                  ; -> VARS byte offset
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
;   Trick: NEG_T1 loads X=2 (offset to T1 relative to T0), then uses a
;   BIT abs opcode ($2C) to consume the LDX #0 instruction as a 2-byte
;   operand, skipping into the shared body with X=2 intact.
;
;   DL_DN is the nearest RTS and is shared by DO_LET (bad-variable bailout)
;   and NEG16 (falls off the end here).
; =============================================================================
NEG_T1:  LDX #2
         .DB $2C              ; BIT abs: skips next 2 bytes (the LDX #0)
NEG16:   LDX #0
         LDA #0
         SEC
         SBC T0,X
         STA T0,X
         LDA #0
         SBC T0+1,X
         STA T0+1,X
; DL_DN is the nearest following RTS, shared by:
;   DO_LET  -- branches here on bad variable name (BCC / BCS bail)
;   NEG16   -- falls through here after negation
DL_DN:   RTS

; =============================================================================
; WPEEK_UC  --  skip spaces at IP, peek first non-space char, convert to UC
;
;   In:  IP -> text (may have leading spaces)
;   Out: A = first non-space char, uppercased; IP unchanged (char not consumed)
;   Clobbers: A
;
;   Falls through into UC after WSKIP returns.
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
;
;   RTS_1: shared return for UC, WPEEK/WSKIP (branch here when no action taken)
; =============================================================================
UC:      CMP #'a'
         BCC RTS_1            ; below 'a': not a lowercase letter
         CMP #'{'             ; '{' = 'z' + 1
         BCS RTS_1            ; above 'z': not a lowercase letter
         AND #$DF             ; clear bit 5: a-z -> A-Z
RTS_1:   RTS

; =============================================================================
; WSKIP_NS / WSKIP / WPEEK  --  skip spaces; return first non-space in A
;
;   In:  IP -> text (may start with spaces)
;   Out: A = first non-space char; IP advanced past any leading spaces
;        (char is NOT consumed -- IP still points to it)
;   Clobbers: A
;
;   Three labels for the same entry point:
;     WSKIP_NS  -- "no side-effects" alias used by MTCHKW
;     WSKIP     -- used when the skip side-effect is desired
;     WPEEK     -- used when the intent is to inspect without consuming
;   All are identical in behaviour; the names document caller intent.
; =============================================================================
WSKIP_NS:
WSKIP:
WPEEK:   LDA (IP)             ; 65C02 zp-indirect peek (no Y needed)
         CMP #' '
         BNE RTS_1            ; non-space: return (branches to shared RTS above)
         JSR GETCI            ; consume space and loop
         BRA WSKIP

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
         ORA #'0'             ; convert 0-9 to ASCII '0'-'9'
         ; fall through into PUTCH

; =============================================================================
; PUTCH  --  write one character to the terminal
;
;   In:  A = character to output
;   Out: --
;   Clobbers: --  (flags may change)
; =============================================================================
PUTCH:   STA IO_OUT
         RTS

; =============================================================================
; GETCH  --  read one character from the terminal (blocking); echo it
;
;   In:  --
;   Out: A = character read
;   Clobbers: A
; =============================================================================
GETCH:   LDA IO_IN
         BEQ GETCH            ; spin until a char is available
         BRA PUTCH            ; echo it, then return (tail call)

; =============================================================================
; USR_CALL / USR_RET  --  machine-code call helper for USR(addr) atom
;
;   In:  T2 = address of user routine (lo at $0A, hi at $0B)
;   Out: T0 = value in A when user routine executes RTS
;   Clobbers: A (user routine may clobber anything)
;
;   USR_CALL performs JMP(T2): an indirect jump to the user routine.  Because
;   EXPR2 called USR_CALL via JMP (tail call), the user routine's RTS returns
;   directly to EXPR2's caller.  A holds the user's return value; USR_RET
;   stores it into T0 and clears T0+1 so USR() behaves as a 16-bit zero-
;   extended expression atom.
;
;   Placement: USR_CALL must be after GETCH in source order.  If placed
;   between PRT16PRNT and PUTCH it would intercept PRT16's fall-through
;   (PRT16PRNT falls into PUTCH; inserting code there breaks PRT16).
; =============================================================================
USR_CALL:
         JMP (T2)              ; indirect jump to user code; RTS returns to EXPR2's caller
USR_RET: STA T0                ; save A as the 16-bit result lo-byte
         STZ T0+1              ; result is zero-extended (hi = 0)
         RTS

; =============================================================================
; STMT DISPATCH TABLE
;
; Each 3-byte entry:  <kw_lo_byte, <handler_lo, >handler_hi
; STMT walks the table calling MTCHKW on each keyword.
; $FF sentinel causes STMT to fall through to DO_LET (implicit assignment).
;
; Placed before STMT so the assembler resolves forward handler references as
; absolute addresses rather than zero-page on the first pass.
; =============================================================================
ST_TAB:
         .DB <KW_PRINT, <DO_PRINT, >DO_PRINT
         .DB <KW_IF,    <DO_IF,    >DO_IF
         .DB <KW_GOTO,  <DO_GOTO,  >DO_GOTO
         .DB <KW_LIST,  <DO_LIST,  >DO_LIST
         .DB <KW_RUN,   <DO_RUN,   >DO_RUN
         .DB <KW_NEW,   <DO_NEW,   >DO_NEW
         .DB <KW_INPUT, <DO_INPUT, >DO_INPUT
         .DB <KW_REM,   <ST_NOP,   >ST_NOP  ; REM: ST_NOP is the nearest following RTS
         .DB <KW_END,   <DO_END,   >DO_END
         .DB <KW_LET,   <DO_LET,   >DO_LET  ; explicit LET keyword (body = implicit path)
         .DB <KW_POKE,  <DO_POKE,  >DO_POKE
         .DB <KW_FREE,  <DO_FREE,  >DO_FREE
         .DB <KW_HELP,  <DO_HELP,  >DO_HELP
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
;
;   Termination (v15.0): keyword strings use bit-7 termination.  The loop
;   fetches the keyword byte, records whether it is the last char (bit 7),
;   masks it with AND #$7F, compares against the (uppercased) input char,
;   and on a match checks if this was the last keyword char to decide
;   whether the full keyword has been matched.
; =============================================================================
MTCHKW:
         STA T1               ; keyword address lo
         LDA #STR_PAGE
         STA T1+1             ; keyword address hi (always STR_PAGE)
         LDA IP
         STA LP               ; save IP in LP in case we need to restore
         LDA IP+1
         STA LP+1
         JSR WSKIP_NS         ; skip leading spaces in input (does not update LP)
         ; ---- main comparison loop ----
         ; On entry: T1 = ptr to current keyword char; IP = ptr to current input char
         ; v16: non-last and last-char paths now share MK_CMP body (-7 bytes).
         ;      Y=0 => non-last char (loop back); Y=1 => last char (exit on match).
         ;      Y is documented as clobbered by MTCHKW so all callers are safe.
MK_LP:   LDA (T1)             ; fetch keyword char; bit 7 set on last char of keyword
         BMI MK_ISLAST        ; last keyword char: strip bit 7 and set Y=1
         LDY #0               ; non-last char: Y=0
         BRA MK_CMP           ; join shared compare body
         ; ---- last keyword char: strip bit 7, mark as last, fall into shared body ----
MK_ISLAST:
         AND #$7F             ; strip bit 7 to get true ASCII value
         LDY #1               ; last char: Y=1
         ; ---- shared compare body: both paths join here ----
MK_CMP:  PHA                  ; save keyword char
         LDA (IP)             ; peek next input char (65C02 zp-indirect, no Y needed)
         JSR UC               ; uppercase it for case-insensitive comparison
         STA T1+1             ; temp-stash UC'd input (T1+1 normally = STR_PAGE)
         PLA                  ; restore keyword char
         CMP T1+1             ; compare keyword char vs uppercased input
         BNE MK_FAIL          ; mismatch -> restore IP and return C=1
         LDA #STR_PAGE        ; restore T1+1 to STR_PAGE
         STA T1+1
         JSR GETCI            ; consume matched input char (advances IP)
         CPY #1               ; was this the last keyword char?
         BEQ MK_OK            ; yes: full keyword matched, return C=0
         INC T1               ; no: advance keyword pointer to next char
         BRA MK_LP            ; loop for next char
MK_OK:   CLC                  ; C=0: match
         RTS
MK_FAIL_LAST:                 ; alias: same address as MK_FAIL (retained for clarity)
MK_FAIL: LDA LP               ; restore IP to saved position
         STA IP
         LDA LP+1
         STA IP+1
         SEC                  ; C=1: no match
         RTS

; Pre-loaded Mandelbrot program  ($0200)
;
;   Stored as raw ASCII.  Line format: <lineno_lo> <lineno_hi> <body> <CR>
;   Spaces between tokens are preserved exactly as typed.
; =============================================================================
         .ORG $0200

; Feature showcase program exercising major uBASIC v13 capabilities.
; Lines  10-260: feature demos (PRINT, CHR$, arithmetic, comparisons, GOTO loops)
; Lines 270-470: Mandelbrot set renderer (GOTO-based nested loops)
;
; Note: uBASIC stores programs as raw ASCII (no tokeniser).
;
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
         .DB $36,$01,$43,$3D,$2D,$31,$32,$38,$0D  ; 310 C=-128
         .DB $40,$01,$49,$46,$20,$43,$3E,$31,$36,$20,$54,$48,$45,$4E,$20,$47,$4F,$54,$4F,$20,$34,$35,$30,$0D  ; 320 IF C>16 THEN GOTO 450
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
SHOWCASE_END:               ; INIT sets PE to this address ($0623)

; =============================================================================
; Reset / IRQ vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT             ; $FFFC: reset vector
         .DW IRQ_HANDLER      ; $FFFE: IRQ vector