; =============================================================================
; JB-uBASIC6502 v1.3  --  2 KB Tiny BASIC (NMOS 6502) for John Bell 80-153 SBC
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; Note: Due to bitbang serial IO, this is not compatible with Kowalski simulator.
;   Instead use the JB-Sim65c02 simulator.
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
;   $0000-$008B  zero-page (IP/CURLN/PE/LP/T0-T2/RUN/OP/IBUF/T3
;                GCHRX/VARS/RUNSP/T3/GOSUB_SP/GOSUB stack)
;   $0100-$017F  Hardware stack (page 1, mandatory)
;   $0180-$03FF  BASIC program store (RAM_TOP=$0400)
;
; Statements accepted (full or 2-letter prefix):
;   END  GOSUB  GOTO  IF..THEN  INPUT  LET  POKE  PRINT  REM  RETURN    
;   LIST [n,m]  NEW  RUN
;
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   FREE   PEEK(addr)   USR(addr)   A-Z variables
;
; Numbers      : signed 16-bit  (-32768 .. 32767)
; String print : "literals", `;`, TAB(n) and CHR$(char); no string variables
;
; Note: `:` multi-statement not supported. Inpout buffer is 31 chars long.  
;
; Error codes (printed as "?N"):
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division or modulo by zero
;   ?3  out of memory
;   ?4  bad variable name in LET
;   ?5  RETURN without GOSUB
;
; ---- ROM memory map ---------------------------------------------------------
;   $F800          Rom Start
;   $FFFC..$FFFF   reset / IRQ vectors
;
; ---- program storage --------------------------------------------------------
;   Base $0180 to ceiling RAM_TOP ($0400 for 1 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; ---- version lineage --------------------------------------------------------
; 6502 base:
;   V1.3 (Jul 2026)   10 bytes free before vectors.  Multiple helpers to 
;                     refactor for size.  Added optional LIST start,end.
;                     FREE converted to function to save space.
;   V1.2 (Jul 2026)   29 bytes free before vectors. Ported GOSUB/RETURN, RND 
;                     from uBASIC6502 1.9. Refactor PNUM/DELINE/INSLINE/EDITLN
;                     for size/correctness. GOTOL updates CURLN bugfix.Refactor
;                     DO_NEW. Clean-up partial ':' multi-statement support. 
;   V1.1 (Jun 2026)   Refactored for size, added FREE and TAB.
;   v1.0 (Jun 2026)   Initial Port from uBASIC6502 1.4
;
; ---- assembler mode ---------------------------------------------------------
         .opt proc6502

; ---- hardware I/O (John Bell Engineering PN 80-153 -- 6522 VIA) -------------
VIA_DDRA = $1C03             ; 6522 Port A Data Direction Register
VIA_ORA  = $1C0F             ; 6522 Port A Output/Input Register (no handshake)
VIA_TX   = $01               ; PA0 = TX output bit mask
VIA_RX   = $02               ; PA1 = RX input  bit mask

; ---- Constants -------------------------------------------------------------
RAM_TOP  = $0400             ; first address above usable SRAM (1 KB: 2x 2114)
HWSTACK  = $7f               ; Give more space to PROG
PROG     = $0180             ; = $101 + HWSTACK; hardcoded due to assembler barf 
IBUF_MAX = 31                ; highest valid index into IBUF
CR       = $0D               ; ASCII carriage return
LF       = $0A               ; ASCII line feed
BS       = $08               ; ASCII backspace
GOSUB_FULL = (GOSUB_LO+3)    ; lowest X for which a full 4-byte push still fits 
GOSUB_TOP  = (GOSUB_LO+31)   ; initial/empty GOSUB_SP value (topmost stack byte)

; ---- error codes -------------------------------------------------------------
ERR_SN   = 0                 ; syntax / bad expression
ERR_UL   = 1                 ; undefined line number
ERR_OV   = 2                 ; division or modulo by zero
ERR_OM   = 3                 ; out of memory
ERR_UK   = 4                 ; bad variable name in LET
ERR_RET  = 5                 ; RETURN without GOSUB

; ---- zero-page symbols -------------------------------------------------------
        .ORG 0
; Note IP and CURLN must be sequential for GOSUB/RETURN stack push
T0:         .RES 2              ; 16-bit: primary scratch word / expression result
T1:         .RES 2              ; 16-bit: secondary scratch word
T2:         .RES 2              ; 16-bit: tertiary scratch word / STMT jump target
T3:         .RES 2              ; 16-bit: PNUM x10-multiply scratch, RXCHAR/TXCHAR
T4:         .RES 2              ; 16-bit: Used in DO_POKE, free for others
IP:         .RES 2              ; 16-bit: interpreter pointer
CURLN:      .RES 2              ; 16-bit: currently-executing line number
PE:         .RES 2              ; 16-bit: program end (one past last byte)
LP:         .RES 2              ; 16-bit: line pointer / multi-purpose scratch
RND_SEED:   .RES 2              ; 16-bit: Galois LFSR state for RND (lo=$8A, hi=$8B)
RUN:        .RES 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
OP:         .RES 1              ; 8-bit:  saved operator for MUL/DIV/MOD ('*'/'/'/'%')
GCHRX:      .RES 1              ; 8-bit:  GETLINE: buffer index X saved across JSR GETCH
RUNSP:      .RES 1              ; 8-bit:  stack-pointer snapshot for GOTO/BREAK unwind
GOSUB_SP:   .RES 1              ; 8-bit:  GOSUB/RETURN stack pointer (holds a ZP address directly)
GOSUB_LO:   .RES 32             ; base of the 8-level GOSUB return-frame stack (32 bytes)
VARS:       .RES 52             ; 52-byte variable store (A-Z, 2 bytes each)
IBUF:       .RES (IBUF_MAX+1)   ; 32-byte input line buffer - coudl be bigger
ZPEND:		; audit

; =============================================================================
; ROM START  ($F800)
         .ORG $F800

; =============================================================================
; STRING / KEYWORD TABLE  (page $F8)
;
; All strings and 2-byte keyword entries are kept on STR_PAGE ($F8).
; PUTSTR uses STR_PAGE as the fixed hi-byte, and MTCHKW sets T1+1 to STR_PAGE
; when reading keyword bytes by (T1),Y.
;
; TERMINATION: the last byte of every string has bit 7 set (value |= $80).
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/keyword addresses

; ---- bit-7 terminated character constants - few needed as 2 word KW match ---
; Naming: T_<char>  where <char> is the ASCII letter or symbol.
T_LF  = 138              ; $0A + $80  (LF  -- final byte of STR_CRLF)
T_SP  = 160              ; $20 + $80  (' ' -- final byte of STR_IN)
T_E   = 197              ; $45 + $80  ('E' -- NE, RE, LE, PE)
T_K   = 203              ; $4B + $80  ('K' -- BREAK, PEEK)

; ---- human-readable strings -------------------------------------------------
; Last byte of each string has bit 7 set; PUTSTR masks it before printing.
STR_BANNER: .DB "JB uBASIC v1.3"  ; startup banner, rolls into free
STR_CRLF:   .DB CR, T_LF       ; CR + LF
STR_IN:     .DB " IN", T_SP    ; " IN " (error annotation: " IN <linenum>")
STR_BREAK:  .DB CR, LF, "BREA", T_K  ; "\r\nBREAK"

; ---- keyword strings --------------------------------------------------------
; Two uppercase ASCII bytes per keyword (no bit-7 terminator).
; MTCHKW compares a 16-bit prefix and then skips trailing letters in input.
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
KW_RND:     .DB 'R','N'
KW_FREE:    .DB 'F','R'

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

         ; --- 6522 VIA setup: PA0 = TX output, PA1-PA7 = inputs ---
         LDA #VIA_TX          ; DDRA: bit 0 = output, bits 1-7 = input
         STA VIA_DDRA
         LDA #VIA_TX          ; TX line idles HIGH (mark = logic 1)
         STA VIA_ORA

         CLI                  ; enable maskable IRQs (Break pushbutton on IRQ pin)
         JSR DO_NEW           ; setup PE and PROG; also (re-)seeds RND_SEED

        ;  STR_BANNER
         LDA #<STR_BANNER
         JSR PUTSTR           ; print banner + CR+LF
         ; fall through into MAIN

; =============================================================================
; MAIN  --  immediate-mode prompt / dispatch loop
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
; Check for proper variable access
PARSE_VAR:
         JSR WPEEK_UC         ; Skips spaces, peeks char, converts to uppercase
         CMP #'A'
         BCC PV_FAIL
         CMP #'Z'+1
         BCS PV_FAIL
         JSR GETCI            ; Consume the variable char
         AND #$DF             ; uppercase inline (char already known alphabetic)
         SEC
         SBC #'A'
         ASL                  ; Convert to VARS offset; C=0 guaranteed (max input 25)
         RTS
PV_FAIL: SEC
IRQ_idle:
         RTS

; =============================================================================
; IRQ_HANDLER  --  maskable interrupt handler ($FFFE vector)
;
;   In:  -- (entered via IRQ; CPU has pushed PChi, PClo, P)
;   Out: if RUN != 0: unwinds stack, prints BREAK+linenum, jumps to MAIN
;        if RUN == 0: silently RTIs
;   Clobbers: A X  (stack deliberately abandoned when running)
;
;   On the John Bell Engineering PN 80-153, the Break pushbutton is wired
;   to the IRQ pin.  The 6522 VIA IRQ output is NOT connected to the CPU.
;   When idle at the BASIC prompt: RTI silently discards the interrupt.
;   When a program is running: restores SP to RUNSP (unwinding all call
;   frames), prints BREAK IN <linenum>, then returns to MAIN.
; =============================================================================
IRQ_HANDLER:
         LDA RUN              ; is a program running?
         BEQ IRQ_idle         ; no: ignore interrupt
         LDX RUNSP            ; yes: restore SP to pre-run snapshot
         TXS                  ; (unwinds all JSR frames accumulated during RUN)
         LDA #<STR_BREAK
         JSR PUTSTR           ; print "\r\nBREAK"
         JMP DO_break_in      ; print " IN <linenum>\r\n" then jump to MAIN

; =============================================================================
; DO_INPUT  --  INPUT <var>
;
;   In:  IP -> variable name in source
;   Out: named variable updated; IP restored to position after variable name
;   Clobbers: A X Y T0 T1 T2 IP GCHRX
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
DO_IN_DN:
         RTS

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
;   Clobbers: A X Y IP GCHRX TEMP
;
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
; Can jump in here with no prompt
         LDX #0
GL_LP:   STX GCHRX            ; save buffer index X across GETCH (ZP, keeps A free)
         JSR GETCH            ; read one char (GETCH echoes it; clobbers X)
         LDX GCHRX            ; restore buffer index X; A = received char intact
         CMP #CR
         BEQ GL_DONE
         CMP #BS
         BNE GL_STORE
         DEX
         BPL GL_LP            ; X was > 0: decrement succeeded, loop
         INX                  ; X was 0: DEX wrapped to $FF (N set) -- restore it
         BEQ GL_LP            ; X is 0 again: unconditional loop back
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

         ; [OPT] GETCI does the identical 16-bit IP increment and returns the
         ; raw digit char ($30-$39) in A, which is always nonzero.
         JSR GETCI             ; consume digit, advances IP 16-bit
         BNE PN_LP              ; guaranteed to branch since A != 0

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
         JSR PROG2LP
EL_FL:   JSR PE_CMP            ; is LP == PE? (reached end of store)
         BEQ EL_INS            ; yes: insert at end
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
	 BNE EL_INS		; always taken
	
EL_SKIP: JSR LSKIP             ; advance LP to next line (shared w/ GOTOL)
         JMP EL_FL
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
; INSLINE: ; not actually called anywhere
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
IN_HDR:  LDA CURLN             ; write line number lo
         STA (LP),Y            ; Y is 0 here
         INY
         LDA CURLN+1           ; write line number hi
         STA (LP),Y
         JSR ADD2_LP           ; advance LP by 2 for the payload
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
         BNE DP_STR            ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional
DP_CHR: LDA #<KW_CHRS
         JSR MTCHKW           ; matched "CHR$"?
         BCS DP_TAB
         JSR E2_COMMON        ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         LDA T0
         JSR PUTCH
         BNE DP_AFT            ; PUTCH always leaves A=VIA_TX=1 (Z=0): unconditional
DP_TAB:  LDA #<KW_TAB
         JSR MTCHKW           ; matched "TAB"?
         BCS DP_NORM
         JSR E2_COMMON        ; Yes it is, Swallow `(`, get value, and swallow closing `)`
	 LDA T0
    	 BEQ DP_AFT           ; If TAB(0), skip printing spaces entirely
         STA GCHRX            ; counter in ZP: PUTCH clobbers X, can't loop on X
DP_TLOOP:	 
         LDA #' '              ; reload each iteration: PUTCH clobbers A too
         JSR PUTCH 
         DEC GCHRX
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
; PRNL / PUTSTR   --  print a bit-7-terminated string
;
;   Three entry points sharing one body:
;     PRNL      -- prints STR_CRLF (CR+LF); no argument needed
;     DP_NL     -- alias for PRNL used by DO_PRINT fall-through
;     PUTSTR    -- In: A = lo-byte of string address (hi-byte = STR_PAGE)
;     PUTSTRZP  -- In: T2 = lo-byte of string address (hi-byte set here)
;
;   Out: characters written to terminal
;   Clobbers: A Y T2
;
;   All strings must reside on STR_PAGE.  A single lo-byte pointer suffices
;   because the hi-byte is always STR_PAGE.
;
;   Termination: bit 7 of the last character is set.  BMI detects it, AND #$7F
;   strips it, PUTCH prints it, then the routine returns.
;
;   Co-located labels:
;     PS_DN (end of PUTSTR) is a plain RTS.
;     DO_PRINT falls into DP_NL / PRNL rather than using JSR+RTS.
; =============================================================================
PRNL:
DP_NL:   LDA #<STR_CRLF       ; load CR+LF string address, then fall into PUTSTR
PUTSTR:  STA T2               ; store lo-byte; hi-byte set below
         LDA #STR_PAGE
         STA T2+1             ; hi-byte is always STR_PAGE
         LDY #0
PS_LP:   LDA (T2),Y           ; fetch next character
         BMI PS_LAST          ; bit 7 set: this is the last character
         JSR PUTCH            ; print character
         INC T2               ; advance string pointer (lo-byte only; page never wraps)
         BNE PS_LP            ; always taken: string table constrained to one page
PS_LAST: AND #$7F             ; strip bit 7 from last character
         JMP PUTCH            ; Tail call print last character

; =============================================================================
; DO_POKE  --  POKE addr, value  :  write one byte to memory
;
;   Syntax: POKE <expr>, <expr>
;   In:  IP -> address expression
;   Out: byte written; IP advanced past statement
;   Clobbers: A, T3
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
;   3rd char 'T' (case-insensitive) selects RETURN ("RE" + T); anything
;   else -- including the full word "REM" -- falls through as a no-op.
; =============================================================================
DO_REM_CHK:
         LDY #2
         LDA (LP),Y
         AND #$DF             ; uppercase
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

         LDX RUNSP
         TXS                  ; unwind hardware stack to pre-statement state
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
;   Clobbers: A X Y T0 IP SP
;
;   3rd char 'S' (case-insensitive) selects GOSUB; anything else -- including
;   the full word "GOTO" -- falls through as plain GOTO.
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

; =============================================================================
; GET_TWO_ARGS  --  shared helper: parse "expr,expr"; 
; first -> T4, second -> T0
; =============================================================================
GET_TWO_ARGS:
         JSR EXPR              ; first arg -> T0
         LDA T0
         STA T4
         LDA T0+1
         STA T4+1
         JSR EAT_EXPR          ; skip spaces, eat ',', second arg -> T0
         RTS

; =============================================================================
; DO_LIST  --  LIST [n,m]  :  print program lines, optional range
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
LS_LN:   JSR PE_CMP
         BEQ LS_DONE
         LDY #0
         LDA (LP),Y            ; peek line number lo (LP not yet advanced)
         STA T0
         LDY #1
         LDA (LP),Y            ; peek line number hi
         STA T0+1
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
         LDY #0                ; PRT16's contract doesn't guarantee Y on exit
         LDA #' '
         JSR PUTCH
         JSR ADD2_LP            ; advance LP past the 2-byte header for the body walk
LS_BODY: LDY #0
         LDA (LP),Y
         JSR BUMP_LP
         CMP #CR
         BEQ LS_EOL
         JSR PUTCH
         JMP LS_BODY
LS_EOL:  JSR PRNL
         JMP LS_LN
LS_SKIP: JSR LSKIP              ; LP still at header start -- matches LSKIP's contract
         JMP LS_LN
LS_DONE: RTS
BUMP_LP: INC LP
         BNE BUMP_RTS
         INC LP+1
BUMP_RTS:RTS

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
LSKIP:   LDY #2
LSK_LP:  LDA (LP),Y
         INY
         CMP #CR
         BNE LSK_LP
         TYA
         CLC
         ADC LP
         STA LP
         BCC LSK_RTS
         INC LP+1
LSK_RTS: RTS

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
; ADD2_LP  --  LP += 2 (shared by INSLINE and DO_LIST, skip a 2-byte header)
;
;   In:  LP
;   Out: LP advanced by 2
;   Clobbers: A
; =============================================================================
ADD2_LP: LDA LP
         CLC
         ADC #2
         STA LP
         BCC A2L_RTS
         INC LP+1
A2L_RTS: RTS

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
         JSR PROG2X
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
         LDX #$ff
         LDA #0
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
         SEC
         SBC #'A'              ; shift 'A'-'Z' down to 0-25; remainder kept in A
         CMP #26
         BCS MK_OK             ; not a letter: exit, A still holds the remainder
         JSR GETCI
         BNE MK_SKIP           ; always taken (token chars are nonzero)
MK_OK:   CMP #$E3              ; remainder == '$'-'A' (mod 256)? reuses A, no re-peek
         BNE GT_R              ; not '$': clear carry, return success
         JSR GETCI             ; it IS '$': consume it
         BNE GT_R              ; A = '$' ($24), always nonzero -- return success

MK_FAIL: LDA LP               ; restore IP to saved position
         STA IP
         LDA LP+1
         STA IP+1
MK_SEC:         
         SEC                  ; C=1: no match
         RTS

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
         BEQ MK_SEC            ; not found
GT_GO:   LDY #0
         LDA (LP),Y           ; read line-number lo
         CMP T0               ; compare line-number lo
         BNE GT_NX
         LDY #1
         LDA (LP),Y
         CMP T0+1             ; compare line-number hi
         BEQ GT_OK
GT_NX:   JSR LSKIP             ; advance LP to next line (shared w/ EDITLN)
         JMP GT_SC
GT_OK:   LDA T0               ; T0 already == the matched line number
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDA LP                ; IP = LP + 2 (advance past 2-byte header)
         CLC
         ADC #2
         STA IP
         LDA LP+1
         ADC #0
         STA IP+1
GT_R:    CLC
         RTS

; =============================================================================
; EAT_EXPR  --  skip spaces, consume one char (e.g. '('), evaluate expression
;
;   In:  IP -> char to consume (leading spaces skipped first)
;   Out: T0 = expression result; IP advanced past expression
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Consumes one char (e.g. opening '('), then falls through into EXPR.
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
;   Clobbers: A X Y T0 T1 T2 OP IP
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
         LDA #$FF             ; must be true
	     .DB $2C              ; Executes "BIT $00A9" (swallows LDA #0)
REL_F:   LDA #0
         STA T0
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
;   Clobbers: A X Y T0 T1 T2 OP IP
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
;   E2_NEG: entry for unary '-' -- consumes '-(via E2_POS) then negates result.
;
;   Note: E2_BAD returns T0=0 for unrecognised atoms (no error raised). -- consumes the '+' then falls into EXPR2.
;   E2_NEG: entry for unary '-' -- evaluates atom then negates it.
; =============================================================================
E2_COMMON:
         JSR EAT_EXPR         ; consume '(' and evaluate argument -> T0
         JMP WEAT             ; tail call: consume ')' and return

E2_POS:  JSR GETCI            ; consume unary '+', then fall through

EXPR2:
         JSR WPEEK
         CMP #'('
         BNE E2_NOTPAR
         JMP E2_PAR
E2_NOTPAR:
         CMP #'-'
         BEQ E2_NEG
         CMP #'+'
         BEQ E2_POS

        ; start function matching - we dont match CHR$ as handled by PRINT
         LDA #<KW_PEEK
         JSR MTCHKW           ; matched "PEEK"?
         BCS E2_NOT_PEEK
         JSR E2_COMMON        ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         LDY #0
         LDA (T0),Y           ; read byte at address
         STA T0               ; Store it
         STY T0+1             ; Clear high byte
         RTS

E2_NOT_PEEK:
         LDA #<KW_USR
         JSR MTCHKW           ; matched "USR"?
         BCS E2_NOT_USR
         JSR E2_COMMON        ; Yes it is, Swallow `(`, get value, and swallow closing `)`
         JMP (T0)             ; And jump, fingers crossed we return with retval in T0

E2_NOT_USR:
         LDA #<KW_RND
         JSR MTCHKW           ; matched "RND"?
         BCS E2_NOT_RND       ; nope
         ; Drop through
; =============================================================================
;   16-bit Galois LFSR in RND_SEED, tap $B4 (x^16+x^14+x^13+x^11+1),
;   Shuffles on every call, better on a timer but we dont have one 
         LSR RND_SEED+1       ; shift hi byte right, MSB = 0
         ROR RND_SEED         ; shift lo byte right, MSB = old hi bit 0

         LDA RND_SEED         ; LDA/STA don't touch Carry -- safe before BCC
         STA T0

         LDA RND_SEED+1       ; Carry from the LSR above is still intact
         BCC E2_RND_SK        ; no bit fell out: skip the feedback tap

         EOR #$B4             ; apply feedback tap
         STA RND_SEED+1       ; update the seed in memory
E2_RND_SK:
         AND #$7F             ; force positive (clear bit 15) for T0
         STA T0+1
         RTS

E2_NOT_RND:
         LDA #<KW_FREE
         JSR MTCHKW           ; matched "FREE"?
         BCS E2_NOT_FREE      ; nope
         SEC                  ; T0 = RAM_TOP - PE (free program-store bytes)
         LDA #<RAM_TOP
         SBC PE
         STA T0
         LDA #>RAM_TOP
         SBC PE+1
         STA T0+1
         RTS

E2_NOT_FREE:
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
;   Clobbers: A Y IP
; =============================================================================
GETCI:   LDY #0
         LDA (IP),Y
         INC IP               ; 16-bit increment
         BNE GETCI_SK
         INC IP+1
; DO_IF_F and GETCI_SK are adjacent because DO_IF (condition-false path)
; and GETCI both want a plain RTS and this is the nearest one.
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
         ORA T0+1
         BEQ DO_IF_F          ; false: return
         LDA #<KW_THEN
         JSR MTCHKW           ; consume optional THEN keyword
         ; fall through into STMT to execute the consequent

; =============================================================================
; STMT  --  execute one statement from IP
;
;   In:  IP -> statement text (spaces will be skipped)
;   Out: statement executed; IP advanced
;   Clobbers: A X Y T0 T1 T2 IP
;
;   Walks ST_TAB: tries MTCHKW for each 3-byte entry (kw_lo, hdlr_lo, hdlr_hi).
;   On match, loads handler into T2 and dispatches via JMP(T2).
;   The $FF sentinel terminates the table; no match falls through to DO_LET.
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
         LDA ST_TAB+2,X        ; matched: push handler-1 hi, then lo, RTS to dispatch
         PHA
         LDA ST_TAB+1,X
         PHA
         RTS                   ; ST_TAB stores (handler-1); RTS pulls+1 -> handler

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
;   DL_DN: nearest following RTS -- shared with NEG16/NEG_T1 (below) and
;   the DO_LET error-bail path (DL_POP -> DO_ERROR).
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
         ; falls through into STORE_VAR (JMP would be free but fallthrough is 0 bytes)
; =============================================================================
; STORE_VAR  --  shared tail: pop var_offset pushed by caller, store T0 there
;
;   In:  T0 = value to store; hardware stack top = var_offset (from PARSE_VAR)
;   Out: VARS[var_offset] = T0; RTS to caller's caller
;   Clobbers: A X
; =============================================================================
STORE_VAR:
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
;   BIT abs opcode ($2C) to consume the LDX #0 as a 2-byte operand,
;   skipping into the shared body with X=2 intact.
;
;   DL_DN is the nearest RTS and is shared by DO_LET and NEG16.
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
;
;   Tail-calls UC (JMP UC); UC's RTS returns to UCIP's caller.
; =============================================================================
UCIP:    LDY #0
         LDA (IP),Y
         JMP UC

; =============================================================================
; WSKIP / WPEEK  --  skip spaces; return first non-space in A
;
;   In:  IP -> text (may start with spaces)
;   Out: A = first non-space char; IP advanced past any leading spaces
;        (char is NOT consumed -- IP still points to it)
;   Clobbers: A
;
;   Three labels for the same entry point (names document caller intent):
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
; PUTCH  --  transmit one character via 6522 VIA PA0 (bitbang, 1200 baud)
;
;   In:  A = character to transmit
;   Out: TX line left in mark (idle high) state
;   Clobbers: A X Y TEMP
;
;   Protocol: 8N1 (start bit / 8 data bits LSB-first / stop bit).
;   Baud rate: ~1200 baud at 1 MHz (DELAY_BIT = 160 iterations x ~5 cy = 800+
;   overhead ~= 833 cy per bit).  Adjust BAUD_FULL / BAUD_HALF for other rates.
;
;   The entire Port A byte is written each time; PA1-PA7 are inputs so the
;   written value is masked by DDRA and only PA0 is driven.
; =============================================================================
PUTCH:
         STA T3             ; save character to shift out

         ; --- Start bit: TX = 0 ---
         LDA #$00
         STA VIA_ORA
         JSR DELAY_BIT

         ; --- 8 data bits, LSB first ---
         LDX #8
PC_LOOP: LSR T3             ; bit 0 -> carry
         LDA #$00
         ADC #$00             ; A = 0 + carry = 0 or 1 (the bit to send)
         STA VIA_ORA
         JSR DELAY_BIT
         DEX
         BNE PC_LOOP

         ; --- Stop bit: TX = 1 ---
         ; Note: stop-bit delay omitted; caller overhead provides >1 bit period
         LDA #VIA_TX
         STA VIA_ORA
         RTS

; =============================================================================
; DELAY_BIT / DELAY_HALF  --  serial timing delays for 1200 baud @ 1 MHz
;
;   In:  -- (entry point selects delay count)
;   Out: Y = 0 on return
;   Clobbers: Y
;
;   Inner loop: DEY (2 cy) + BNE (3 cy taken, 2 cy exit) = ~5 cy/iter.
;   JSR overhead ~12 cy included in totals above.
;   Timing is approximate; adjust BAUD_FULL / BAUD_HALF for exact match.
; =============================================================================
DELAY_BIT:
         JSR DELAY_HALF       ; full bit period (~833 cy at 1 MHz)
DELAY_HALF:
         LDY #80              ; half bit period (~417 cy at 1 MHz)
DL_LOOP: DEY
         BNE DL_LOOP
         RTS

; =============================================================================
; GETCH  --  receive one character via 6522 VIA PA1 (bitbang, 1200 baud)
;            then echo it via PUTCH
;   In:  --
;   Out: A = received character
;   Clobbers: A X Y TEMP  (caller must save X if needed; see GETLINE/GCHRX)
;
;   The received byte is assembled in TEMP[$30] via 8x ROR from the MSB.
;   It is saved on the hardware stack (PHA) before JSR PUTCH (which clobbers
;   TEMP), then restored via PLA.  Caller's X is NOT preserved -- callers
;   that need X intact (e.g. GETLINE) must save it themselves (see GCHRX).
; =============================================================================
GETCH:
         ; --- Wait for start bit: PA1 goes LOW ---
         ; Caller is responsible for preserving X if needed (GETCH clobbers X).
GC_WAIT: LDA VIA_ORA
         AND #VIA_RX          ; isolate PA1
         BNE GC_WAIT          ; non-zero = mark (idle high): keep waiting

         ; --- Delay to centre of start bit, then one full bit to bit 0 ---
         JSR DELAY_HALF       ; 0.5 bit: reach mid-point of start bit
         JSR DELAY_BIT        ; 1.0 bit: advance to centre of data bit 0

         ; --- Sample 8 data bits LSB first into T3 ---
         LDX #8
GC_LOOP: LDA VIA_ORA         ; read port
         LSR                  ; PA0 -> carry (TX bit discarded)
         LSR                  ; PA1 -> carry (RX data bit)
         ROR T3+1           ; carry -> MSB of TEMP; shift right
         JSR DELAY_BIT        ; advance to centre of next bit
         DEX
         BNE GC_LOOP
         ; After 8 RORs: T3 holds the received byte (LSB-first serial,
         ; ROR accumulates from MSB down -> correct byte in T3).

         ; --- Echo, then restore caller's X and return char in A ---
         LDA T3+1
         JSR PUTCH            ; echo
         LDA T3+1
         RTS

; =============================================================================
; STMT DISPATCH TABLE
;
; Each 3-byte entry:  <kw_lo_byte, <handler_lo, >handler_hi
; STMT walks the table calling MTCHKW on each keyword.
; $FF sentinel causes STMT to fall through to DO_LET (implicit assignment).
; =============================================================================
; NOTE: handler addresses stored as (handler-1) for the RTS-dispatch trick in STMT.
ST_TAB:
         .DB <KW_PRINT, <(DO_PRINT-1), >(DO_PRINT-1)
         .DB <KW_IF,    <(DO_IF-1),    >(DO_IF-1)
         .DB <KW_GOTO,  <(DO_GO-1),    >(DO_GO-1)
         .DB <KW_LIST,  <(DO_LIST-1),  >(DO_LIST-1)
         .DB <KW_RUN,   <(DO_RUN-1),   >(DO_RUN-1)
         .DB <KW_NEW,   <(DO_NEW-1),   >(DO_NEW-1)
         .DB <KW_INPUT, <(DO_INPUT-1), >(DO_INPUT-1)
         .DB <KW_REM,   <(DO_REM_CHK-1), >(DO_REM_CHK-1)
         .DB <KW_END,   <(DO_END-1),   >(DO_END-1)
         .DB <KW_LET,   <(DO_LET-1),   >(DO_LET-1)
         .DB <KW_POKE,  <(DO_POKE-1),  >(DO_POKE-1)
         .DB $FF  ; sentinel: fall through to implicit assign


ROMEND: ; for auditing

; =============================================================================
; Reset / IRQ / NMI vectors
; =============================================================================
         .ORG $FFFC
         .DW INIT         ; $FFFC: reset vector
         .DW IRQ_HANDLER      ; $FFFE: IRQ vector   (Break pushbutton)
