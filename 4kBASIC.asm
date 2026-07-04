; =============================================================================
; 4K Integer BASIC v15.3 for the 65C02
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; A fully-featured, self-contained integer BASIC interpreter in 4 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; NEW to clear and enter your own program).
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
;   INPUT [prompt;] var [, var ...]    read from keyboard
;   LET var = expr     explicit assignment (LET keyword optional)
;   POKE addr, val     write byte to memory
;   READ var [, var ...]   read next value from DATA sequence
;   DATA val [, val ...]   literal values in program (consumed by READ)
;   RESTORE            reset DATA pointer to start of program
;   REM ...            comment to end of line
;   RUN                execute program from first line
;   LIST               list stored program
;   NEW                clear program
;   END                stop execution
;   RETURN             return from GOSUB
;   FREE               print bytes of program RAM remaining
;   GOTO expr          branch to line (expr may be variable or expression)
;   GOSUB expr         call subroutine at line (expr may be variable or expression)
;
;   Multi-statement:   ':' separates statements on one line.
;   Don't have FOR/NEXT, FOR/FOR or GOSUB/RETURN on same line
;
;   Expressions  (left-to-right within tier):
;   Tier 1 (lowest): AND  OR  XOR       (bitwise / logical)
;   Tier 2:          =  <>  <  >  <=  >=  (comparisons: return -1=true, 0=false)
;   Tier 3:          +  -
;   Tier 4:          *  /  %  MOD       (% and MOD are identical: integer remainder)
;   Tier 5 (atoms):  literal  variable  (expr)  -expr  +expr  NOT expr
;                    ABS(n)              absolute value
;                    SIN(deg)            sine   * 1000  (0-360 degrees, CORDIC)
;                    COS(deg)            cosine * 1000  (0-360 degrees, CORDIC)
;                    TAB(n)              print n spaces (PRINT only; expr argument)
;                    CHR$(n)             character with ASCII code n  (PRINT only)
;                    ASC("c")            ASCII code of first char of string
;                    PEEK(addr)          read byte from memory address
;                    USR(addr)           call machine-code subroutine, A=lo T0
;                    RND                 pseudo-random 1..32767 (no argument)
; Numbers:     signed 16-bit integers  -32768 .. 32767
; Variables:   A .. Z  (26 x 2-byte, zero-page)
; Line range:  1 .. 32767
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
; RECENT CHANGE HISTORY
;
; v15.3 (Jul 2026) - 24 bytes free
;   - FIXED: Cold-start Zero Page clear loop condition changed from BPL to BNE.
;   - FIXED: Single-line colon-chained FOR/NEXT execution via new SKIP_STMT logic.
;   - FIXED: Trailing colon evaluation bug in PRINT statement output.
;   - NOTE: Multi-FOR headers sharing a single line remains a documented limitation.
;
; v15.2 (Jul 2026) - 67 bytes free (ROM unaffected)
;   - Rewrote pre-loaded RAM showcase to an 805-byte self-checking test suite.
;   - Added SIN/COS wave-plot demo routines.
;
; v15.1 (Jul 2026) - 67 bytes free
;   - REMOVED: INKEY statement to reclaim ~16 bytes of ROM space.
;   - Added NEG_X subroutine entry point for centralized ZP 16-bit negation.
;   - Added SHIFT_R16_T0 routine for consolidated bit-shifts.
;   - Optimized DO_PRINT argument extraction and PNUM tail-calls.
;
; v15.0 (Jul 2026) - 0 bytes free (ROM Maxed out)
;   - ADDED: 16-bit fixed-point CORDIC engine for SIN(deg) and COS(deg).
;   - ADDED: TAB(n) print control via simple space-loop generator.
;   - REMOVED: CLS, HELP, AT, ON...GOTO/GOSUB, HEX$, and SGN to fit CORDIC engine.
;   - FIXED: Quadrant-negation calculation faults within core trigonometric paths.
;   - FIXED: Missing argument boundaries causing spurious "0" prints after TAB.
;   - Factored out shared PARSE_VAR token evaluator (saved ~28 bytes).
;   - Rewrote relational loops using sequential $3C-$3E ASCII offset arrays.
;
; v14.0 - v14.2 (Size Optimizations)
;   - Factored out 16-bit loop-decrement operations into centralized T2DEC helper.
;   - Redesigned relational engine using unified bitmasks and 65C02 N XOR V logic.
;   - Grouped statement tokens into a contiguous block ($80-$95) to drop CMP/BEQ chains.
;
; v13.0 (Size Optimizations)
;   - Switched strings and KW_TABLE to high-bit last-character termination.
;   - Dropped keyword length bytes, refactoring TRYKW to scan for high-bit flags.
;
; v12.0 - v12.4 (IRQ & Stability Pass)
;   - ADDED: Maskable IRQ support on $E007 supporting runtime BREAK recovery.
;   - FIXED: SGN(pos) sign-extension bug and restored missing uppercase PRT_HEX.
;   - Inlined PEEKC reads and deployed 65C02 zero-page indirect addressing.
;
; v11.3 - v11.4
;   - FIXED: Target line tracking during GOTO/GOSUB to prevent nested loop corruption.
; =============================================================================
;
; Zero-page layout:
;   $00-$01  IP      interpreter pointer  (token stream or program store)
;   $02-$03  PE      program end pointer
;   $04-$05  LP      scratch / line / keyword pointer
;   $06-$07  T0      expression result / scratch 0
;   $08-$09  T1      scratch 1
;   $0A-$0B  T2      scratch 2
;   $0C-$0D  CURLN   current executing line number
;   $0E      GRET    GOSUB nesting depth  (0-8)
;   $0F      RUN     non-zero while program is running
;   $10-$2F  IBUF    raw input buffer  (32 bytes)
;   $30-$4F  TBUF    tokenised buffer  (32 bytes)
;   $50-$8B  VARS    A-Z variables  (2 bytes each = 52 bytes)
;   $8C-$9B  GORET   GOSUB return-address stack  (8 x 2 bytes)
;   $9C      TKTOK   keyword scan index  (TRYKW scratch)
;   $9D      FSTK    FOR loop nesting depth  (0-4)
;   $9E-$B9  FOR_STK FOR stack frames  (4 x 7 bytes)
;   $BA      RUNSP    saved SP for GOTO/NEXT/GOSUB stack unwind
;   $BB      OP       saved MUL/DIV/MOD operator  ('*', '/' or '%')
;   $BC-$BD  DATA_PTR READ pointer into program store:
;              0    = reset/RESTORE'd ? rescan from PROG on next READ
;              PE   = exhausted, no more DATA values
;              else = position inside current DATA body (past TOK_DATA byte)
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
TOK_CLS     = $8F            ; CLS  (was $9C)
TOK_HELP    = $90            ; HELP  (was $9D)
; TOK_ON ($91) removed v15.0 -- slot is now a KW_TABLE placeholder
TOK_DATA    = $92            ; DATA val, val, ...  (was $A1)
TOK_READ    = $93            ; READ var  (was $A2)
TOK_RESTORE = $94            ; RESTORE  (was $A3)
TOK_ELSE    = $95            ; ELSE  (was $A4)
; ---- expression-atom tokens: $96..$A8 (never in STMT_JT) -------------------
TOK_PEEK    = $96            ; PEEK(addr)  (was $8F)
TOK_STEP    = $97            ; STEP  (was $90)
TOK_TO      = $98            ; TO  (was $91)
TOK_CHRS    = $99            ; CHR$(n)  (was $92)
TOK_ASC     = $9A            ; ASC("c")  (was $93)
TOK_ABS     = $9B            ; ABS(n)  (was $94)
TOK_USR     = $9C            ; USR(addr)  (was $95)
TOK_AND     = $9D            ; AND  (was $96)
TOK_OR      = $9E            ; OR   (was $97)
TOK_NOT     = $9F            ; NOT expr  (was $98)
TOK_XOR     = $A0            ; XOR  (was $99)
TOK_LET     = $A1            ; LET  (was $9A)
TOK_THEN    = $A2            ; THEN  (was $9B)
TOK_TAB     = $A3            ; TAB(n)  (replaces AT; same token slot)
; TOK_INKEY ($A4) removed v15.1
TOK_SIN     = $A8            ; SIN(deg) -> deg*1000 (0-360)  (was $A9)
TOK_COS     = $A9            ; COS(deg) -> deg*1000 (0-360)  (was $AA)
; TOK_SGN ($A5) removed v15.0
TOK_MOD     = $A6            ; MOD      -- unchanged
TOK_RND     = $A7            ; RND      -- unchanged
; TOK_HEXS ($A8) removed v15.0 -- slot reused by TOK_SIN
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
CURLN    = $02               ; 16-bit: current executing line number
LP       = $04               ; 16-bit: list/edit/scratch pointer
T0       = $06               ; 16-bit: expression result / scratch 0
T1       = $08               ; 16-bit: scratch 1
T2       = $0A               ; 16-bit: scratch 2
PE       = $0C               ; 16-bit: program end
GRET     = $0E               ;  8-bit: GOSUB nesting depth
RUN      = $0F               ;  8-bit: 0 = idle, $FF = running
IBUF     = $10               ; 32 bytes: raw input buffer  ($10-$2F)
TBUF     = $30               ; 32 bytes: tokenised buffer  ($30-$4F)
VARS     = $50               ; 52 bytes: A-Z variables     ($50-$8B)
GORET    = $8C               ; 16 bytes: GOSUB return stack ($8C-$9B)
TKTOK    = $9C               ;  8-bit: TRYKW keyword index
FSTK     = $9D               ;  8-bit: FOR nesting depth
FOR_STK  = $9E               ; 28 bytes: FOR frames        ($9E-$B9)
FOR_FRSZ = 7                 ; bytes per FOR frame
RUNSP    = $BA               ;  8-bit: saved SP for stack unwind
OP       = $BB               ;  8-bit: MUL/DIV operator ('*' or '/')
DATA_PTR = $BC               ; 16-bit: pointer to next DATA value to READ ($BC-$BD)
RND_SEED = $BE               ; 16-bit: LFSR seed for RND  ($BE-$BF); init to $ACE1

; CORDIC scratch (zeroed by INIT_z with rest of ZP):
CX       = $C0               ; 16-bit: CORDIC X accumulator
CY       = $C2               ; 16-bit: CORDIC Y accumulator
CZ       = $C4               ; 16-bit: CORDIC Z angle accumulator
CX_SAV   = $C6               ; 16-bit: saved CX per iteration
CIDX     = $C8               ;  8-bit: CORDIC iteration counter
ATEMP    = $C9               ;  8-bit: angle quadrant temp

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
        .DB $0A, $00, $89, " 4K BASIC v15", $2E, "1 SHOWCASE", $0D  ; 10  REM banner
        .DB $14, $00, $80, $22, $3D, $3D, " 4K BASIC v15", $2E, "1 ", $3D, $3D, $22, $0D  ; 20  PRINT "== 4K BASIC v15.1 =="
        .DB $1E, $00, $80, $22, "CHR", $22, $3B, $99, $28, $FF, $24, $00, $29, $3B, $22, $28, "65", $29, $3D, $22, $3B, $99, $28, $FF, $41, $00, $29, $3B, $22, "  ASC", $3D, $22, $3B, $9A, $28, $22, "A", $22, $29, $0D  ; 30  PRINT "CHR";CHR$(36);"(65)=";CHR$(65);"  ASC=";ASC("A")
        .DB $28, $00, $80, $22, "17 MOD 5", $3D, $22, $3B, $FF, $11, $00, $A6, $FF, $05, $00, $3B, $22, "  ABS neg7", $3D, $22, $3B, $9B, $28, $FF, $F9, $FF, $29, $0D  ; 40  PRINT "17 MOD 5=";17 MOD 5;"  ABS neg7=";ABS(-7)
        .DB $32, $00, $80, $22, "NOT 0", $3D, $22, $3B, $9F, $FF, $00, $00, $3B, $22, "  6 AND 3", $3D, $22, $3B, $FF, $06, $00, $9D, $FF, $03, $00, $0D  ; 50  PRINT "NOT 0=";NOT 0;"  6 AND 3=";6 AND 3
        .DB $3C, $00, $80, $22, "5 OR 2", $3D, $22, $3B, $FF, $05, $00, $9E, $FF, $02, $00, $3B, $22, "  7 XOR 3", $3D, $22, $3B, $FF, $07, $00, $A0, $FF, $03, $00, $0D  ; 60  PRINT "5 OR 2=";5 OR 2;"  7 XOR 3=";7 XOR 3
        .DB $46, $00, $80, $22, "RND MOD 10", $3D, $22, $3B, $A7, $A6, $FF, $0A, $00, $0D  ; 70  PRINT "RND MOD 10=";RND MOD 10
        .DB $50, $00, $8E, $FF, $00, $02, $2C, $FF, $2A, $00, $3A, $80, $22, "POKE 512 42  PEEK", $3D, $22, $3B, $96, $28, $FF, $00, $02, $29, $0D  ; 80  POKE 512,42 : PRINT "POKE 512 42  PEEK=";PEEK(512)
        .DB $5A, $00, $93, "A", $2C, "B", $2C, "C", $3A, $80, $22, "DATA  ", $22, $3B, "A", $3B, $22, "  ", $22, $3B, "B", $3B, $22, "  ", $22, $3B, "C", $0D  ; 90  READ A,B,C : PRINT "DATA  ";A;"  ";B;"  ";C
        .DB $64, $00, $94, $3A, $93, "A", $3A, $80, $22, "RESTORE A", $3D, $22, $3B, "A", $0D  ; 100 RESTORE : READ A : PRINT "RESTORE A=";A
        .DB $6E, $00, $92, " 111", $2C, "222", $2C, "333", $0D  ; 110 DATA 111,222,333
        .DB $78, $00, $8B, "I", $3D, $FF, $01, $00, $98, $FF, $05, $00, $0D  ; 120 FOR I=1 TO 5
        .DB $82, $00, $80, "I", $3B, $0D  ; 130 PRINT I;
        .DB $8C, $00, $8C, "I", $0D  ; 140 NEXT I
        .DB $96, $00, $80, $0D  ; 150 PRINT  (blank line)
        .DB $A0, $00, $8B, "I", $3D, $FF, $0A, $00, $98, $FF, $01, $00, $97, $2D, $FF, $03, $00, $0D  ; 160 FOR I=10 TO 1 STEP -3
        .DB $AA, $00, $80, "I", $3B, $0D  ; 170 PRINT I;
        .DB $B4, $00, $8C, "I", $0D  ; 180 NEXT I
        .DB $BE, $00, $80, $0D  ; 190 PRINT  (blank line)
        .DB $C8, $00, $81, $FF, $03, $00, $3E, $FF, $01, $00, $A2, $80, $22, "IF true", $22, $0D  ; 200 IF 3>1 THEN PRINT "IF true"
        .DB $D2, $00, $81, $FF, $01, $00, $3E, $FF, $03, $00, $A2, $80, $22, "WRONG", $22, $95, $80, $22, "ELSE ok", $22, $0D  ; 210 IF 1>3 THEN PRINT "WRONG" ELSE PRINT "ELSE ok"
        .DB $DC, $00, $83, $FF, $F4, $01, $0D  ; 220 GOSUB 500
        .DB $E6, $00, $89, " sine wave  TAB", $28, "20", $2B, "SIN", $28, "X", $29, $2F, "50", $29, $0D  ; 230 REM sine wave
        .DB $F0, $00, $8B, "X", $3D, $FF, $00, $00, $98, $FF, $67, $01, $97, $FF, $0F, $00, $0D  ; 240 FOR X=0 TO 359 STEP 15
        .DB $FA, $00, $80, $A3, $28, $FF, $14, $00, $2B, $A8, $28, "X", $29, $2F, $FF, $32, $00, $29, $3B, $22, $2A, $22, $0D  ; 250 PRINT TAB(20+SIN(X)/50);"*"
        .DB $04, $01, $8C, "X", $0D  ; 260 NEXT X
        .DB $0E, $01, $82, $FF, $58, $02, $0D  ; 270 GOTO 600
        .DB $18, $01, $8A, $0D  ; 280 END  (not reached)
        .DB $F4, $01, $80, $22, "GOSUB ok", $22, $3A, $84, $0D  ; 500 PRINT "GOSUB ok" : RETURN
        .DB $58, $02, $8B, "I", $3D, $2D, $FF, $40, $00, $98, $FF, $38, $00, $97, $FF, $06, $00, $0D  ; 600 FOR I=-64 TO 56 STEP 6
        .DB $62, $02, "D", $3D, "I", $0D  ; 610 D=I
        .DB $6C, $02, $8B, "C", $3D, $2D, $FF, $80, $00, $98, $FF, $10, $00, $97, $FF, $04, $00, $0D  ; 620 FOR C=-128 TO 16 STEP 4
        .DB $76, $02, "A", $3D, "C", $3A, "B", $3D, "D", $3A, "E", $3D, $FF, $00, $00, $0D  ; 630 A=C:B=D:E=0
        .DB $80, $02, $8B, "N", $3D, $FF, $01, $00, $98, $FF, $10, $00, $0D  ; 640 FOR N=1 TO 16
        .DB $8A, $02, $81, "E", $3E, $FF, $00, $00, $A2, $82, $FF, $A8, $02, $0D  ; 650 IF E>0 THEN GOTO 680
        .DB $94, $02, "T", $3D, "A", $2A, "A", $2F, $FF, $40, $00, $2D, "B", $2A, "B", $2F, $FF, $40, $00, $2B, "C", $0D  ; 660 T=A*A/64-B*B/64+C
        .DB $9E, $02, "B", $3D, $FF, $02, $00, $2A, "A", $2A, "B", $2F, $FF, $40, $00, $2B, "D", $3A, "A", $3D, "T", $0D  ; 670 B=2*A*B/64+D:A=T
        .DB $A8, $02, $81, "E", $3D, $FF, $00, $00, $A2, $81, "A", $2A, "A", $2F, $FF, $40, $00, $2B, "B", $2A, "B", $2F, $FF, $40, $00, $3E, $FF, $00, $01, $A2, "E", $3D, "N", $0D  ; 680 IF E=0 THEN IF A*A/64+B*B/64>256 THEN E=N
        .DB $B2, $02, $8C, "N", $0D  ; 690 NEXT N
        .DB $BC, $02, $81, "E", $3E, $FF, $00, $00, $A2, $80, $99, $28, "E", $2B, $FF, $20, $00, $29, $3B, $95, $80, $99, $28, $FF, $20, $00, $29, $3B, $0D  ; 700 IF E>0 THEN PRINT CHR$(E+32); ELSE PRINT CHR$(32);
        .DB $C6, $02, $8C, "C", $0D  ; 710 NEXT C
        .DB $D0, $02, $80, $22, $22, $0D  ; 720 PRINT "" (newline)
        .DB $DA, $02, $8C, "I", $0D  ; 730 NEXT I
        .DB $E4, $02, $8A, $0D  ; 740 END

SHOWCASE_END:               ; assembles to $0200+805 = $0525

; =============================================================================
        .ORG $F000
; STRING TABLE (all strings on same page)
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/kw addresses
STR_BANNER: .DB "4K BASIC v15.3"        ; drop through (trimmed ".0" -- saves 2 bytes)
STR_CRLF:   .DB $0D,$8A             ; CR, LF|$80 = $8A
STR_BYTES:  .DB " BYTES FREE",$0D,$8A  ; last LF has high-bit
STR_ERROR:  .DB " ER",$D2           ; 'R'|$80 = $D2
STR_IN:     .DB " IN ",$A0          ; last space|$80 = $A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB  ; 'K'|$80 = $CB
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
        CLI                  ; enable maskable IRQs (for $E007 Break key)
INIT_z: STZ 0,x              ; 65C02 STZ zp,x  (no LDA #0 needed)
        DEX
        BNE INIT_z            ; BUG FIX v15.3: was BPL, which only ever
                              ; clears $FF (DEX from $FF sets N=1 immediately,
                              ; so BPL never loops). BNE correctly clears
                              ; $FF down to $01 (255 bytes). $00 is left
                              ; unswept but is safe: IP ($00-$01) is set
                              ; explicitly before every use, never read
                              ; before being written.
        ; DATA_PTR ($BC-$BD) is zeroed by INIT_z above ? sentinel 0 = rescan from PROG
        LDA #$E1             ; seed RND LFSR to $ACE1 (must be non-zero)
        STA RND_SEED
        LDA #$AC
        STA RND_SEED+1
        ; --- Showcase setup - replace with `JSR DO_NEW` for actual ROM
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
        LDA #'>'             ; prompt
        JSR PUTCH
        LDA #' '
        JSR PUTCH
        JSR GETLINE          ; fills IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        LDA #>TBUF
        STA IP+1
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
; GETLINE ? read one raw-text line into IBUF, then tokenise it into TBUF
;   In:  None.
;   Out: IBUF  CR-terminated raw text
;        TBUF  tokenised equivalent  (via fall-through to TOKENIZE)
;        IP    clobbered (used by TOKENIZE)
;   Clobbers: A X Y T0 T1
; =============================================================================
GETLINE:
        LDX #0
GL_lp:  JSR GETCH
        CMP #$0D
        BEQ GL_done
        CMP #$08             ; backspace
        BNE GL_store
        CPX #0
        BEQ GL_lp
        DEX
        BRA GL_lp
GL_store:
        CPX #31              ; 31 + CR = 32 byte limit
        BCS GL_lp            ; buffer full: ignore char (no echo)
        JSR PUTCH            ; echo
        STA IBUF,x
        INX
        BRA GL_lp
GL_done:
        LDA #$0D
        STA IBUF,x           ; CR-terminate
        JSR PRNL             ; echo CR+LF, then fall through to TOKENIZE
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
        LDA #>IBUF
        STA T0+1
        LDA #<TBUF
        STA T1
        LDA #>TBUF
        STA T1+1
TK_TOP: LDA (T0)             ; 65C02 zp-indirect
        CMP #$0D
        BEQ TK_EOL
        TAX                  ; CMP #0 replacement: TAX sets Z for free (X dead here)
        BEQ TK_EOL
        CMP #' '             ; skip spaces
        BNE TK_NS
        JSR TKADV
        BRA TK_TOP
TK_NS:  CMP #'"'             ; string literal: pass through verbatim
        BNE TK_NSTR
        JSR TKEMIT           ; emit opening '"'
TK_SC:  JSR TKADV
        LDA (T0)             ; 65C02 zp-indirect
        JSR TKEMIT
        CMP #'"'
        BNE TK_SC_cont
        JSR TKADV            ; advance past closing '"'
        BRA TK_TOP
TK_SC_cont:
        CMP #$0D
        BNE TK_SC
        BRA TK_EOL           ; unterminated string: treat as EOL
TK_NSTR:
        CMP #'0'             ; decimal digit?
        BCC TK_NNUM
        CMP #'9'+1
        BCS TK_NNUM
        JSR TKPNUM           ; parse number into CURLN
        LDA #TOK_NUM
        JSR TKEMIT
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1
        JSR TKEMIT
        BRA TK_TOP
TK_NNUM:
        JSR UC
        CMP #'A'             ; possible keyword or variable?
        BCC TK_OTHER
        CMP #'Z'+1
        BCS TK_OTHER
        JSR TRYKW            ; try keyword match  (C=0 matched, C=1 not)
        BCC TK_TOP           ; keyword emitted: continue
TK_OTHER:                    ; punctuation / unrecognised: emit as-is
        LDA (T0)             ; 65C02 zp-indirect: re-read variable letter
        JSR UC
        JSR TKEMIT
        JSR TKADV
        BRA TK_TOP
TK_EOL: LDA #$0D             ; write $0D $00 end-of-line sentinel
        LDY #0
        STA (T1),y
        INY
        LDA #0
        STA (T1),y
        RTS

; =============================================================================
; TKADV ? advance source pointer T0 by one byte
;   In:  T0   source pointer
;   Out: T0   incremented
;   Clobbers: Flags only (A unchanged).
; =============================================================================
TKADV:  INC T0
        BNE TKADV_ok
        INC T0+1
TKADV_ok:
        RTS

; =============================================================================
; TKEMIT ? write A to token output at T1, advance T1
;   In:  A    byte to write;  T1  destination pointer
;   Out: T1   incremented
;   Clobbers: Y
; =============================================================================
TKEMIT: STA (T1)             ; 65C02 zp-indirect: no Y needed  ($92 opcode)
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
        LDA (T0)             ; 65C02 zp-indirect
        SEC
        SBC #'0'
        BCC TKPN_dn          ; < '0': done
        CMP #10
        BCS TKPN_dn          ; > '9': done
        PHA                  ; save digit
        JSR TKADV
        ; CURLN = CURLN * 10  using  (CURLN<<3) + (CURLN<<1)
        ASL CURLN            ; x2
        ROL CURLN+1
        LDA CURLN            ; save x2 in X,Y
        TAX
        LDA CURLN+1
        TAY
        ASL CURLN            ; x4
        ROL CURLN+1
        ASL CURLN            ; x8
        ROL CURLN+1
        TXA                  ; x8 + x2 = x10
        CLC
        ADC CURLN
        STA CURLN
        TYA
        ADC CURLN+1
        STA CURLN+1
        PLA                  ; add digit
        CLC
        ADC CURLN
        STA CURLN
        BCC TKPN_lp
        INC CURLN+1
        BRA TKPN_lp
; =============================================================================
; TRYKW ? try to match a keyword at the current source position (T0)
;   In:  T0    points at first character of candidate (already UC'd by caller)
;   Out: C=0   matched: token byte emitted via TKEMIT, T0 advanced past keyword
;        C=1   no match: T0 unchanged, nothing emitted
;        TKTOK keyword scan index (scratch; caller must not rely on value)
;   Clobbers: A Y T2 LP OP
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
        LDA T0               ; save source pos for possible backtrack
        STA CURLN
        LDA T0+1
        STA CURLN+1
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
        JSR TKADV            ; advance T0 (source ptr); clobbers flags but not X or Y
        INY                  ; next table char index
        BNE TRY_cmp          ; always (no keyword >= 256 chars)
TRY_matched_adv:
        JSR TKADV            ; advance source past the final matched char
        ; ---- full match ----
        LDA TKTOK
        PHA
        CMP #TOK_DATA        ; DATA: emit token FIRST, then raw body verbatim
        BNE TRY_chk_rem
        PLA
        JSR TKEMIT           ; emit TOK_DATA before the raw value list
TRY_raw:                     ; copy raw bytes until $0D (shared by DATA body loop)
        LDA (T0)
        CMP #$0D
        BEQ TRY_raw_done
        JSR TKEMIT
        JSR TKADV
        BRA TRY_raw
TRY_chk_rem:
        CMP #TOK_REM         ; REM: absorb rest of line verbatim, token emitted after
        BNE TRY_emt
TRY_rem:
        LDA (T0)
        CMP #$0D
        BEQ TRY_emt
        JSR TKEMIT
        JSR TKADV
        BRA TRY_rem
TRY_emt:
        PLA
        JSR TKEMIT
TRY_raw_done:
        CLC
        RTS
TRY_miss:                    ; this keyword doesn't match: restore T0, try next
        LDA CURLN
        STA T0
        LDA CURLN+1
        STA T0+1
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
        LDY #0
KW_nx_lp:
        LDA (T2),y           ; read char from entry
        BPL KW_nx_norm       ; bit 7 clear: not last char, advance and loop
        INY                  ; Y now = count of chars in this entry
        TYA
        CLC
        ADC T2
        STA T2
        BCC KW_next_ok
        INC T2+1
KW_next_ok:
        RTS
KW_nx_norm:
        INY
        BNE KW_nx_lp         ; always (no keyword is 256 chars)
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
        LDA T0
        STA CURLN
        LDA T0+1
        STA CURLN+1
        LDA #<PROG
        STA LP
        LDA #>PROG
        STA LP+1
EL_fl:  LDA LP               ; scan for insertion/replacement point
        CMP PE
        BNE EL_go
        LDA LP+1
        CMP PE+1
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
EL_len: LDA (LP),y
        INY
        CMP #$0D
        BNE EL_len
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
        JSR INSLINE          ; insert the new line
EL_done:
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
; =============================================================================
; T2DEC ? decrement 16-bit counter T2; return Z=1 when result reaches zero
;   In:  T2 = 16-bit counter
;   Out: T2 decremented; Z=1 if T2==0, Z=0 otherwise
;   Clobbers: A
;   Shared by DELINE and INSLINE to avoid duplicating the 14-byte
;   decrement-and-zero-test sequence in each copy loop.
; =============================================================================
T2DEC:  LDA T2
        BNE T2D_lo
        DEC T2+1
T2D_lo: DEC T2
        LDA T2
        ORA T2+1
        RTS                  ; Z=1 if zero, Z=0 if not
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
DL_ll:  LDA (LP),y           ; scan body for terminating $0D
        INY
        CMP #$0D
        BNE DL_ll
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
        LDY #0
DL_cp:  LDA (T0),y           ; shift bytes down
        STA (LP),y
        INY
        BNE DL_nhi
        INC T0+1
        INC LP+1
DL_nhi: JSR T2DEC            ; decrement T2; Z=1 when zero
        BNE DL_cp
DL_upd: LDA PE               ; update PE
        SEC
        SBC T1
        STA PE
        BCS DL_ok
        DEC PE+1
DL_ok:  RTS
; =============================================================================
; INSLINE ? insert (or replace) a tokenised line in the program store
;   In:  IP   source: <body> $0D  (no $FF prefix ? PNUM already consumed it)
;        LP   insertion point (bytes LP..PE shifted up to make room)
;        PE   current program end
;        CURLN line number for the 2-byte header
;   Out: new line written at LP with 2-byte header prepended
;        PE   advanced by inserted byte count
;   Clobbers: A Y T0 T1 T2
; =============================================================================
INSLINE:
        LDA IP
        STA T0
        LDA IP+1
        STA T0+1
        LDY #0
IN_cnt: LDA (T0),y           ; count body bytes up to and including $0D
        CMP #$0D
        BEQ IN_ce
        INY
        BRA IN_cnt
IN_ce:  INY                  ; include the $0D itself
        TYA
        CLC
        ADC #2               ; + 2-byte header
        PHA                  ; total byte count on stack
        ; OOM check: PE + total > RAM_TOP ?
        CLC
        ADC PE
        STA T2
        LDA PE+1
        ADC #0
        STA T2+1
        LDA T2
        CMP #<RAM_TOP        ; lo byte compare
        LDA T2+1
        SBC #>RAM_TOP        ; hi byte with borrow
        BCC IN_ok            ; new PE < RAM_TOP: fits
        PLA
        LDA #ERR_OM
        JMP DO_ERROR
IN_ok:  ; shift [LP..PE) up by total to make room
        LDA PE
        SEC
        SBC LP
        STA T0               ; T0 = bytes to shift
        LDA PE+1
        SBC LP+1
        STA T0+1
        LDA T0
        ORA T0+1
        BEQ IN_shift         ; nothing to shift
        LDA PE               ; T0 = PE - 1  (top of source range)
        SEC
        SBC #1
        STA T0
        LDA PE+1
        SBC #0
        STA T0+1
        TSX
        LDA $0101,x          ; peek total from stack (without popping)
        CLC
        ADC T0               ; T1 = T0 + total  (top of destination range)
        STA T1
        LDA T0+1
        ADC #0
        STA T1+1
        LDA PE               ; T2 = bytes to shift (PE - LP)
        SEC
        SBC LP
        STA T2
        LDA PE+1
        SBC LP+1
        STA T2+1
IN_bk:  LDY #0               ; copy backwards: high addresses first
        LDA (T0),y
        STA (T1),y
        LDA T0               ; decrement T0
        BNE IN_bk_d0
        DEC T0+1
IN_bk_d0:
        DEC T0
        LDA T1               ; decrement T1
        BNE IN_bk_d1
        DEC T1+1
IN_bk_d1:
        DEC T1
        JSR T2DEC            ; decrement T2; Z=1 when zero
        BNE IN_bk
IN_shift:
        PLA                  ; recover total byte count
        CLC
        ADC PE               ; update PE
        STA PE
        BCC IN_hdr
        INC PE+1
IN_hdr: LDY #0               ; write 2-byte line-number header at LP
        LDA CURLN
        STA (LP),y
        INY
        LDA CURLN+1
        STA (LP),y
        LDA LP               ; T0 = LP + 2  (body destination)
        CLC
        ADC #2
        STA T0
        LDA LP+1
        ADC #0
        STA T0+1
        LDY #0
IN_cp:  LDA (IP),y           ; copy body from IP to T0
        STA (T0),y
        CMP #$0D
        BEQ IN_done
        INY
        BRA IN_cp
IN_done:
        RTS

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
DP_top: JSR WPEEK
        CMP #$0D
        BEQ DP_nl_near       ; bare PRINT (EOL): just print newline
        CMP #0
        BEQ DP_nl_near       ; bare PRINT (sentinel): just print newline
        CMP #'"'             ; string literal in PRINT
        BNE DP_expr
        JSR GETCI            ; consume opening '"'
DP_str: JSR GETCI
        CMP #'"'
        BEQ DP_aft
        CMP #$0D
        BEQ DP_nl_near
        JSR PUTCH
        BRA DP_str
DP_nl_near: JMP PRNL         ; trampoline: forward jump to PRNL (out of BEQ range)
DP_expr:
        JSR WPEEK
        CMP #TOK_TAB         ; TAB(n): print n spaces to advance cursor column
        BNE DP_chk_chrs
        JSR GETCI            ; consume TAB token
        JSR E2_ARG1          ; consume '(n)' -> T0
        ; Print T0 spaces; T0 hi byte ignored (col counts > 255 wrap, harmless)
        LDX T0                ; loop count; sets Z for free (no CMP needed)
        BEQ DP_tab_skip      ; zero: nothing to print
DP_tab_lp:
        LDA #' '
        JSR PUTCH
        DEX
        BNE DP_tab_lp
DP_tab_skip:
        JMP DP_aft           ; check for ';' separator like every other item
DP_chk_chrs:
        CMP #TOK_CHRS        ; CHR$(n): emit char directly without conversion
        BNE DP_norm
        JSR GETCI            ; consume TOK_CHRS
        JSR E2_ARG1          ; consume '(n)' -> T0
        LDA T0
        JSR PUTCH
        BRA DP_aft
DP_norm:
        JSR EXPR
        JSR PRT16
DP_aft: JSR WPEEK
        CMP #';'             ; semicolon suppresses newline, continues list
        BEQ DP_semi
        BNE DP_nl            ; not semicolon: print newline and return
DP_semi:        JSR GETCI
        JSR WPEEK
        CMP #$0D             ; trailing semicolon at EOL: suppress newline
        BEQ DP_semi_dn
        TAX                  ; CMP #0 replacement: TAX sets Z for free (X dead here)
        BEQ DP_semi_dn
        CMP #TOK_ELSE        ; semicolon before ELSE: stop printing (IF handles ELSE)
        BEQ DP_semi_dn
        CMP #':'             ; semicolon before ':' (colon-chained stmt): stop
        BEQ DP_semi_dn
        JMP DP_top           ; more items: loop (too far for BRA)
DP_semi_dn:
        RTS                  ; suppress newline: return without printing CR+LF
DP_nl:  JMP PRNL             ; print CR+LF and return  (tail call)
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
        BNE DO_IF_true       ; condition true: execute THEN branch
        BRA DO_IF_f          ; condition false: hunt for ELSE
        ; -- condition true: execute THEN branch ------------------------------
DO_IF_true:
        JSR WPEEK
        CMP #TOK_THEN        ; optional THEN keyword
        BNE DO_IF_t_stmt
        JSR GETCI
DO_IF_t_stmt:
        JMP STMT             ; tail call ? RUNLP's SKIPEOL handles any ELSE remainder
DO_IF_done:
        RTS
        ; -- condition false: scan for ELSE -----------------------------------
DO_IF_f:
        JSR WPEEK
        CMP #$0D             ; EOL with no ELSE: done
        BEQ DO_IF_done
        TAX                  ; CMP #0 replacement: TAX sets Z for free (X dead here)
        BEQ DO_IF_done
        CMP #TOK_ELSE
        BNE DO_IF_f_skip
        JSR GETCI            ; consume TOK_ELSE
        JSR WPEEK
        CMP #TOK_THEN        ; optional THEN after ELSE (forgiving)
        BNE DO_IF_f_stmt
        JSR GETCI
DO_IF_f_stmt:
        JMP STMT             ; tail call ? RUNLP's SKIPEOL handles remainder
DO_IF_f_skip:
        JSR GETCI            ; consume token
        CMP #TOK_NUM         ; inline number? consume 2 more bytes
        BNE DO_IF_f
        JSR GETCI
        JSR GETCI
        BRA DO_IF_f
; =============================================================================
; DO_GOTO ? GOTO lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOTO:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        JSR GOTOL
        BCS DO_gosub_ul      ; seek failed: share DO_GOSUB's error stub
        LDA T0               ; update CURLN to target line (GOTOL leaves T0=line#)
        STA CURLN
        LDA T0+1
        STA CURLN+1
        BRA RUN_LINE         ; seek succeeded: unwind stack and run
; =============================================================================
; DO_GOSUB ? GOSUB lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOSUB:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        LDA GRET
        CMP #8               ; max 8 levels of nesting
        BCC DO_gosub_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_gosub_ok:
        ASL
        TAX
        LDA IP               ; push return address (IP after the GOSUB)
        STA GORET,x
        LDA IP+1
        STA GORET+1,x
        INC GRET
        JSR GOTOL
        BCS DO_gosub_ul
        LDA T0               ; update CURLN to target line (GOTOL leaves T0=line#)
        STA CURLN
        LDA T0+1
        STA CURLN+1
RUN_LINE:
        LDX RUNSP
        TXS
        JMP RUNGO
DO_gosub_ul:
        JMP DO_ERR_UL        ; ? shared error stub
; =============================================================================
; DO_RETURN ? RETURN
;   Clobbers: A X
; =============================================================================
DO_RETURN:
        LDA GRET
        BNE DO_return_ok
        JMP DO_ERR_NR        ; ? shared error stub
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
        LDA #'?'
        JSR PUTCH
        LDA #' '
        JSR PUTCH
        LDA IP               ; save IP across GETLINE
        STA T2
        LDA IP+1
        STA T2+1
        JSR GETLINE          ; reads into IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        LDA #>TBUF
        STA IP+1
        JSR EXPR             ; evaluate expression from TBUF
        LDA T2               ; restore IP
        STA IP
        LDA T2+1
        STA IP+1
        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
DO_input_dn:
        RTS
; =============================================================================
; DO_REM ? REM (comment): body already absorbed into token stream by TOKENIZE
;   Clobbers: None.
; =============================================================================
DO_REM: RTS
; =============================================================================
; DO_RUN ? RUN: start program from first line
;   Clobbers: A X
; =============================================================================
DO_RUN:
        LDA #<PROG
        STA IP
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
        LDA IP               ; check IP == PE  (end of program)
        CMP PE
        BNE RUNLP_go
        LDA IP+1
        CMP PE+1
        BEQ RUNEND
RUNLP_go:                    ; read 2-byte line number header, advance IP by 2
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INCIP
RUNLP_hi:
        LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INCIP
RUNGO:  JSR STMT
        LDA RUN
        BEQ RUNEND
        JSR SKIPEOL
        BRA RUNLP

; =============================================================================
; DO_NEW ? clear program store and variables
;   Clobbers: A X
; =============================================================================
DO_NEW:
        LDA #<PROG
        STA PE
        LDA #>PROG
        STA PE+1
        STZ DATA_PTR
        STZ DATA_PTR+1
        STZ GRET
        STZ FSTK
        LDX #$3B             ; clear VARS $50-$8B  (52 bytes = $3B+1)
DO_new_z:
        STZ VARS,x           ; 65C02 STZ zp,x
        DEX
        BPL DO_new_z
        ; drop through
; DO_END and RUNEND both just clear RUN and return.
; Two labels on one instruction: DO_END is the handler entry, RUNEND is the
; shared landing target used by DO_RUN and NEXT_END.
DO_END:
RUNEND: STZ RUN
        RTS
; =============================================================================
; DO_LIST ? list all program lines, de-tokenising on the fly
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_LIST:
        LDA #<PROG
        STA LP
        LDA #>PROG
        STA LP+1
LS_ln:  LDA LP               ; end of program?
        CMP PE
        BNE LS_go
        LDA LP+1
        CMP PE+1
        BNE LS_go
        RTS                  ; ? DONE: nearest RTS used as LS_DONE return point
LS_go:
        LDA (LP)             ; 65C02: lo byte of line number
        STA T0
        LDY #1
        LDA (LP),y           ; hi byte
        STA T0+1
        JSR PRT16            ; print line number
        LDA #' '
        JSR PUTCH
        LDA LP               ; advance LP past 2-byte header
        CLC
        ADC #2
        STA LP
        BCC LS_body
        INC LP+1
LS_body:
        LDA (LP)             ; 65C02 zp-indirect
        CMP #$0D
        BEQ LS_eol
        CMP #TOK_NUM
        BEQ LS_num
        CMP #TOK_PRINT
        BCC LS_lit           ; < TOK_PRINT: literal char
        ; keyword token: walk KW_TABLE to find printable name
        SEC
        SBC #TOK_PRINT
        TAX                  ; X = keyword index (0-based)
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
LS_skp: CPX #0
        BEQ LS_prk
        JSR KW_NEXT
        DEX
        BRA LS_skp
LS_prk: LDY #0               ; Y=0: print chars from start of entry until high-bit char
LS_pkl: LDA (T2),y
        BPL LS_pkl_norm      ; bit 7 clear: normal char
        AND #$7F             ; strip high-bit before printing last char
        JSR PUTCH
        BRA LS_pkd
LS_pkl_norm:
        JSR PUTCH
        INY
        BRA LS_pkl
LS_pkd: JSR LS_adv
        LDA #' '
        JSR PUTCH
        BRA LS_body
LS_lit: JSR PUTCH            ; literal character: print and advance
        JSR LS_adv
        BRA LS_body
LS_eol: JSR LS_adv
        JSR PRNL             ; CR+LF
        BRA LS_ln
LS_num: JSR LS_adv           ; skip $FF token
        LDA (LP)             ; 65C02: lo byte
        STA T0
        JSR LS_adv
        LDA (LP)             ; hi byte (Y=0 unchanged from LS_adv)
        STA T0+1
        JSR LS_adv
        JSR PRT16
        LDA #' '
        JSR PUTCH
        BRA LS_body
; =============================================================================
; LS_ADV ? advance list pointer LP by one byte
;   In:  LP   pointer into program store
;   Out: LP   incremented
;   Clobbers: None.
; =============================================================================
LS_adv: INC LP
        BNE LS_adv_ok
        INC LP+1
LS_adv_ok:
        RTS

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
        JMP PUTSTR           ; print " BYTES FREE\r\n" and return  (tail call)
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
PRNL:   LDA #<STR_CRLF
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
; LS_DONE and PS_DN are adjacent because DO_LIST (end-of-program path) and
; PUTSTR (end-of-string path) both want a plain RTS here.
PS_DN:   RTS

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
        LDA #>FOR_STK
        STA LP+1
        RTS

; =============================================================================
; DO_FOR ? FOR var = start TO limit [STEP step]
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_FOR:
        JSR WPEEK_UC
        CMP #'A'
        BCC DO_for_sn
        CMP #'Z'+1
        BCC DO_for_ok
DO_for_sn:
        LDA #ERR_SN
        JMP DO_ERROR
DO_for_ok:
        JSR GETCI            ; consume variable letter
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var_slot
        JSR EAT_EXPR         ; evaluate start value -> T0
        PLA
        TAX
        PHA                  ; save var_slot again (needed after EAT_EXPR)
        LDA T0
        STA VARS,x           ; store start value in variable
        LDA T0+1
        STA VARS+1,x
        JSR EAT_EXPR         ; consume '=' then evaluate '=', then TO, then limit
        LDA T0               ; push limit onto hardware stack
        PHA
        LDA T0+1
        PHA
        JSR WPEEK
        CMP #TOK_STEP
        BNE DO_for_nostep
        JSR GETCI            ; consume STEP token
        JSR EXPR             ; evaluate step -> T0
        LDA T0
        STA T2
        LDA T0+1
        STA T2+1
        BRA DO_for_havestep
DO_for_nostep:
        LDA #1               ; default step = 1
        STA T2
        STZ T2+1
DO_for_havestep:
        LDA T2               ; step of zero is illegal
        ORA T2+1
        BNE DO_for_szok
        PLA
        PLA
        PLA                  ; clean limit hi, limit lo, var_slot from stack
        LDA #ERR_ST
        JMP DO_ERROR
DO_for_szok:
        LDA FSTK
        CMP #4               ; max 4 nested FOR loops
        BCC DO_for_push
        PLA
        PLA
        PLA
        JMP DO_ERR_NR        ; ? shared error stub
DO_for_push:
        LDA T2               ; save step before FSTK_BASE clobbers T2
        PHA
        LDA T2+1
        PHA
        LDA FSTK
        JSR FSTK_BASE        ; LP = FOR_STK + FSTK*7  (clobbers T2)
        PLA
        STA T2+1             ; restore step hi
        PLA
        STA T2               ; restore step lo
        PLA
        STA T0+1             ; limit hi  (popped in push order: hi first)
        PLA
        STA T0               ; limit lo
        PLA                  ; var_slot
        LDY #0
        STA (LP),y           ; [0] var_slot
        INY
        LDA T0
        STA (LP),y           ; [1] limit_lo
        INY
        LDA T0+1
        STA (LP),y           ; [2] limit_hi
        INY
        LDA T2
        STA (LP),y           ; [3] step_lo
        INY
        LDA T2+1
        STA (LP),y           ; [4] step_hi
        INY
        LDA CURLN
        STA (LP),y           ; [5] loop_line_lo
        INY
        LDA CURLN+1
        STA (LP),y           ; [6] loop_line_hi
        INC FSTK
        RTS

; =============================================================================
; DO_NEXT ? NEXT [var]
;   Clobbers: A X Y T0 T1 T2 LP
; =============================================================================
DO_NEXT:
        JSR WPEEK_UC         ; consume optional variable name (ignored)
        CMP #'A'
        BCC DO_next_novar
        CMP #'Z'+1
        BCS DO_next_novar
        JSR GETCI
DO_next_novar:
        LDA FSTK
        BNE DO_next_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_next_ok:
        LDA FSTK
        SEC
        SBC #1
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
        ; load limit into T0
        LDY #1
        LDA (LP),y           ; [1] limit_lo
        STA T0
        INY
        LDA (LP),y           ; [2] limit_hi
        STA T0+1
        ; signed compare ? direction depends on step sign
        LDY #4
        LDA (LP),y           ; [4] step_hi
        BMI DN_neg_step
DN_pos_step:                 ; positive step: loop while var <= limit
        LDA VARS,x
        SEC
        SBC T0
        LDA VARS+1,x
        SBC T0+1
        BMI DN_loop          ; var < limit: keep looping
        LDA VARS,x           ; var == limit: loop one more time
        CMP T0
        BNE DN_done
        LDA VARS+1,x
        CMP T0+1
        BEQ DN_loop
        BRA DN_done
DN_neg_step:                 ; negative step: loop while var >= limit
        LDA T0
        SEC
        SBC VARS,x
        LDA T0+1
        SBC VARS+1,x
        BMI DN_loop          ; limit < var: keep looping
        LDA T0
        CMP VARS,x
        BNE DN_done
        LDA T0+1
        CMP VARS+1,x
        BEQ DN_loop
        BRA DN_done
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
        JSR INCIP            ; consume the $0D
        LDA IP
        CMP PE
        BNE DN_runbody
        LDA IP+1
        CMP PE+1
        BEQ DN_end           ; IP == PE: program ended inside loop
DN_runbody:                  ; read 2-byte line-number header, advance IP
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INCIP
DN_rh:  LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INCIP
DN_rb2: JMP RUN_LINE         ; restore S and jump to target
DN_samel:                    ; colon-chained: resume right after ':' on same line
        JSR INCIP            ; consume the ':'
        LDA T0                ; T0 still holds loop_line (GOTOL doesn't clobber it)
        STA CURLN
        LDA T0+1
        STA CURLN+1
        JMP RUNGO             ; re-enter statement dispatch mid-line (no header)
DN_done:
        DEC FSTK
        RTS
DN_ul:
        JMP DO_ERR_UL        ; ? shared error stub
; DN_end and RUNEND share the same body (clear RUN and return).
; Two adjacent labels: DN_end is the NEXT-loop EOF landing, RUNEND is
; already defined earlier; we can't duplicate ? use RUNEND directly.
DN_end: DEC FSTK
        STZ RUN
        RTS
; =============================================================================
; DO_POKE ? POKE addr, value
;   Clobbers: A Y T0 T1
; =============================================================================
DO_POKE:
        JSR EXPR             ; addr -> T0
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EAT_EXPR         ; consume ',' then value -> T0
        PLA
        STA T1+1             ; T1 = address
        PLA
        STA T1
        LDA T0
        LDY #0
        STA (T1),y           ; POKE the value  (STA (zp),y with Y=0)
        RTS

; =============================================================================
; DATA TABLES  (no page constraint ? placed here after main code)
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
; ---- expression-atom tokens $96..$A8 (in KW_TABLE for tokeniser only) ------
        .DB "PEE",$CB         ; $96 TOK_PEEK    ('K'|$80=$CB)  was $8F
        .DB "STE",$D0         ; $97 TOK_STEP    ('P'|$80=$D0)  was $90
        .DB "T",$CF           ; $98 TOK_TO      ('O'|$80=$CF)  was $91
        .DB "CHR",$A4         ; $99 TOK_CHRS    ('$'|$80=$A4)  was $92
        .DB "AS",$C3          ; $9A TOK_ASC     ('C'|$80=$C3)  was $93
        .DB "AB",$D3          ; $9B TOK_ABS     ('S'|$80=$D3)  was $94
        .DB "US",$D2          ; $9C TOK_USR     ('R'|$80=$D2)  was $95
        .DB "AN",$C4          ; $9D TOK_AND     ('D'|$80=$C4)  was $96
        .DB "O",$D2           ; $9E TOK_OR      ('R'|$80=$D2)  was $97
        .DB "NO",$D4          ; $9F TOK_NOT     ('T'|$80=$D4)  was $98
        .DB "XO",$D2          ; $A0 TOK_XOR     ('R'|$80=$D2)  was $99
        .DB "LE",$D4          ; $A1 TOK_LET     ('T'|$80=$D4)  was $9A
        .DB "THE",$CE         ; $A2 TOK_THEN    ('N'|$80=$CE)  was $9B
        .DB "TA",$C2          ; $A3 TOK_TAB     ('B'|$80=$C2)
        .DB $80               ; $A4 placeholder (INKEY removed v15.1)
        .DB $80               ; $A5 placeholder (SGN removed, expr atom not statement -- no STMT_JT impact)
        .DB "MO",$C4          ; $A6 TOK_MOD     ('D'|$80=$C4)
        .DB "RN",$C4          ; $A7 TOK_RND     ('D'|$80=$C4)
        .DB "SI",$CE          ; $A8 TOK_SIN     ('N'|$80=$CE)  (was $A9)
        .DB "CO",$D3          ; $A9 TOK_COS     ('S'|$80=$D3)  (was $AA)
        .DB 0                 ; end-of-table sentinel

; CORDIC atan table: atan(2^-i) in units where 16384 = 90 degrees
; Value[i] = round(16384 * atan(2^-i) / 90).  12 entries x 2 bytes = 24 bytes.
ATAN_TBL:
        .DW 8192, 4836, 2555, 1297, 651, 326, 163, 81, 41, 20, 10, 5

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
;   The tokeniser copies the raw value list verbatim after TOK_DATA.
;   At runtime we just return; RUNLP's own SKIPEOL call advances past the body.
;   READ/RESTORE consume the raw bytes via DATA_PTR.  (Same pattern as DO_REM.)
;   Clobbers: None.
; =============================================================================
; =============================================================================
; DO_RESTORE ? RESTORE: reset DATA pointer (0 = rescan from PROG on next READ)
;   Clobbers: A
; =============================================================================
DO_RESTORE:
        STZ DATA_PTR         ; 65C02 STZ zp
        STZ DATA_PTR+1
RD_done:
DO_DATA:
        RTS
; =============================================================================
; DO_ELSE_SK -- bare ELSE at statement level: skip rest of line
;   Reached via STMT_JT when ELSE appears as a bare statement (i.e. the false
;   branch of IF already consumed the THEN body and RUNLP calls STMT again,
;   which sees ELSE first).  We simply discard everything to end-of-line.
;   In:  IP   points at token following ELSE
;   Out: IP   advanced past $0D
;   Clobbers: A
; =============================================================================
DO_ELSE_SK:
        JMP SKIPEOL          ; tail call -- advances IP past $0D and returns
; =============================================================================
; DO_READ ? READ var [, var ...]
;   Reads the next value(s) from DATA lines into variable(s).
;   DATA line format in program store:
;     [lineno_lo][lineno_hi][TOK_DATA][raw ASCII: digits, commas, spaces][$0D]
;   DATA_PTR invariant:
;     0    reset/restored ? rescan from PROG on next READ
;     PE   exhausted ? no more DATA values exist
;     else points at current parse position INSIDE a DATA body (past TOK_DATA),
;          i.e. at a digit, comma, space, or $0D (body exhausted)
;   In:  IP        first token of READ statement (variable letter)
;        DATA_PTR  current position (see invariant)
;   Out: IP        advanced past consumed variable(s) and commas
;        DATA_PTR  advanced past consumed value(s)
;   Clobbers: A X Y T0 T1
; =============================================================================
DO_READ:
RD_var: JSR WPEEK_UC         ; peek at next IP token (uppercased)
        CMP #'A'
        BCC RD_sn
        CMP #'Z'+1
        BCS RD_sn
        JSR GETCI            ; consume variable letter
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var slot
        JSR RD_next_val      ; T0 = next data value; C=1 if out-of-data
        BCS RD_od
        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
        JSR WPEEK            ; check for ', var' continuation
        CMP #','
        BNE RD_done
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
;   Clobbers: A Y T1
; =============================================================================
RD_next_val:
        ; -- if DATA_PTR==0 (reset): start scanning from PROG ----------------
        LDA DATA_PTR
        ORA DATA_PTR+1
        BNE RD_chk_pe
        LDA #<PROG
        STA DATA_PTR
        LDA #>PROG
        STA DATA_PTR+1
        BRA RD_find          ; DATA_PTR now at first line header; find DATA
        ; -- if DATA_PTR==PE: out of data -------------------------------------
RD_chk_pe:
        LDA DATA_PTR
        CMP PE
        BNE RD_body
        LDA DATA_PTR+1
        CMP PE+1
        BEQ RD_ood
        ; -- DATA_PTR is inside a DATA body: skip separators ------------------
RD_body:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        CMP #','
        BEQ RD_sep_adv
        CMP #' '
        BEQ RD_sep_adv
        CMP #$0D
        BNE RD_parse         ; digit or '-': parse it
        ; $0D: this DATA body is exhausted ? advance past it and find next DATA
        JSR RD_adv_ptr       ; skip $0D
        ; fall through to RD_find (DATA_PTR now at next line header)
        ; -- scan from line header for next DATA line --------------------------
RD_find:
        LDA DATA_PTR
        CMP PE
        BNE RD_f_go
        LDA DATA_PTR+1
        CMP PE+1
        BEQ RD_ood           ; hit PE: no more DATA
RD_f_go:
        JSR RD_adv_ptr       ; skip lineno_lo
        JSR RD_adv_ptr       ; skip lineno_hi
        LDA (DATA_PTR)       ; first body token  (65C02 zp-indirect, no Y needed)
        CMP #TOK_DATA
        BEQ RD_found_data
        ; not DATA: scan forward to $0D then try next line
RD_skip_ln:
        LDA (DATA_PTR)       ; 65C02 zp-indirect
        CMP #$0D
        BEQ RD_skip_eol
        JSR RD_adv_ptr
        BRA RD_skip_ln
RD_skip_eol:
        JSR RD_adv_ptr       ; skip $0D ? at next line header
        BRA RD_find
RD_found_data:
        JSR RD_adv_ptr       ; skip TOK_DATA byte ? now inside body
        BRA RD_body          ; enter body (may be space/comma at start)
RD_sep_adv:
        JSR RD_adv_ptr
        BRA RD_body
        ; -- parse number at DATA_PTR -----------------------------------------
RD_parse:
        CMP #'-'
        BNE RD_pos
        JSR RD_adv_ptr       ; consume '-'
        JSR RD_uint
        LDA T0               ; negate
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
        INC T0
        BNE RD_neg_ok
        INC T0+1
RD_neg_ok:
        CLC
        RTS
RD_pos: JSR RD_uint
        CLC
        RTS
RD_ood: SEC
        RTS
; -- RD_ADV_PTR ? advance DATA_PTR by 1 ---------------------------------------
RD_adv_ptr:
        INC DATA_PTR
        BNE RD_ap_ok
        INC DATA_PTR+1
RD_ap_ok:
        RTS
; -- RD_UINT ? parse unsigned decimal at DATA_PTR into T0 ---------------------
;   Advances DATA_PTR past all consumed digit characters.
;   Clobbers: A Y T0 T1
RD_uint:
        STZ T0
        STZ T0+1
RD_u_lp:
        LDA (DATA_PTR)       ; 65C02 zp-indirect, no Y needed
        CMP #'0'
        BCC RD_u_done
        CMP #'9'+1
        BCS RD_u_done
        SEC
        SBC #'0'             ; digit 0-9
        PHA                  ; save digit
        ; T0 = T0*10:  save T0 in T1, shift T0 left 3 (?8), add T1*2
        LDA T0               ; copy T0 ? T1
        STA T1
        LDA T0+1
        STA T1+1
        ASL T0               ; T0 = T0*2
        ROL T0+1
        ASL T0               ; T0 = T0*4
        ROL T0+1
        ASL T0               ; T0 = T0*8
        ROL T0+1
        ASL T1               ; T1 = orig*2
        ROL T1+1
        LDA T0               ; T0 = T0*8 + T1*2 = orig*10
        CLC
        ADC T1
        STA T0
        LDA T0+1
        ADC T1+1
        STA T0+1
        PLA                  ; restore digit
        CLC
        ADC T0
        STA T0
        BCC RD_u_nc
        INC T0+1
RD_u_nc:
        JSR RD_adv_ptr
        BRA RD_u_lp
RD_u_done:
        RTS
; Two adjacent labels: DO_ERR_NR branches forward into DO_ERROR via BRA;
; DO_ERR_UL falls straight through into DO_ERROR.
; =============================================================================
DO_ERR_NR:
        LDA #ERR_NR
        BRA DO_err_entry     ; branch into DO_ERROR body  (skips TAX below)
DO_ERR_UL:
        LDA #ERR_UL
        ; *** FALL THROUGH to DO_ERROR ***
; =============================================================================
; DO_ERROR ? print error message and return to MAIN
;   In:  A    error code (ERR_xx constant = index into ERR_TABLE)
;   Out: Character emitted to terminal device. (jumps to MAIN; does not return to caller)
;   Clobbers: A X T0
; =============================================================================
DO_ERROR:
DO_err_entry:
        PHA              ; save error code (survives PRNL which uses A)
        JSR PRNL         ; print CR+LF
        PLA
        TAX              ; X = error code ? ERR_TABLE index
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
        LDA CURLN
        STA T0
        LDA CURLN+1
        STA T0+1
        JSR PRT16            ; line number
DO_err_noline:
        JSR PRNL
        CLI                  ; re-enable IRQs (harmless from error path; needed from IRQ path)
        JMP MAIN
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
; GOTOL ? search program store for a line number; point IP at its body
;   In:  T0   target line number (16-bit)
;   Out: C=0  found: IP points at first token after the 2-byte header
;        C=1  not found (caller should raise ERR_UL)
;   Clobbers: A Y IP
; =============================================================================
GOTOL:
        LDA #<PROG
        STA IP
        LDA #>PROG
        STA IP+1
GT_sc:  LDA IP
        CMP PE
        BNE GT_go
        LDA IP+1
        CMP PE+1
        BEQ GT_err           ; reached end without finding it
GT_go:  LDA (IP)             ; line-number lo  (65C02 zp-indirect, no Y needed)
        CMP T0
        BNE GT_nx
        LDY #1
        LDA (IP),y           ; line-number hi
        CMP T0+1
        BEQ GT_ok
GT_nx:  LDY #2               ; skip to body, scan for $0D
GT_sk:  LDA (IP),y
        INY
        CMP #$0D
        BNE GT_sk
        TYA
        CLC
        ADC IP
        STA IP
        BCC GT_sc
        INC IP+1
        BRA GT_sc
GT_ok:  LDA IP               ; advance IP past 2-byte header
        CLC
        ADC #2
        STA IP
        BCC GT_r
        INC IP+1
GT_r:   CLC
        RTS                  ; C=0: found
GT_err: SEC
        RTS                  ; C=1: not found
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
EB_rel:
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
        STX T2                ; stash running mask (T2 free here; assembler lacks ORA abs,x/y)
        LDA REL_MASK,y       ; new bit
        ORA T2               ; combine with running mask
        TAX
        JSR GETCI            ; consume operator (A = '<'/'='/'>' afterward, never 0)
        BNE RL_LOOP          ; always taken

RL_DONE:
        ; Push mask; evaluate right operand; restore left into T1
        TXA                  ; mask -> A
        PHA                  ; stack: mask | left-hi | left-lo | ...
        JSR EXPR_ADD         ; right operand -> T0
        PLA                  ; pop mask -> A
        STA T2               ; stash mask in T2-lo (T2 is free at this point)
        PLA                  ; left hi
        STA T1+1
        PLA                  ; left lo
        STA T1               ; T1=left, T0=right, T2=mask

        ; --- Classify T1 vs T0: produce result bit LT(1)/EQ(2)/GT(4) in A ---

        ; Equality check first (cheaper: two CMPs, no subtract)
        LDA T1
        CMP T0
        BNE RL_NOT_EQ
        LDA T1+1
        CMP T0+1
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
        AND T2               ; result bit AND operator mask
        BEQ REL_F            ; no overlap -> false
REL_T:  LDA #$FF
        .DB $2C              ; BIT abs: swallows next 2 bytes (the LDA #0 opcode+operand)
REL_F:  LDA #0               ; reached directly when false; skipped-over when true falls through
        STA T0               ; both paths converge here
        STA T0+1
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
EB_and: JSR GETCI            ; AND: bitwise and
        JSR REL_SETUP
        LDA T1
        AND T0
        STA T0
        LDA T1+1
        AND T0+1
        STA T0+1
        BRA EB_bool
EB_or:  JSR GETCI            ; OR: bitwise or
        JSR REL_SETUP
        LDA T1
        ORA T0
        STA T0
        LDA T1+1
        ORA T0+1
        STA T0+1
        BRA EB_bool
EB_xor: JSR GETCI            ; XOR: bitwise exclusive-or
        JSR REL_SETUP
        LDA T1
        EOR T0
        STA T0
        LDA T1+1
        EOR T0+1
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
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EXPR_ADD
        PLA
        STA T1+1
        PLA
        STA T1
        RTS
REL_MASK: .DB 1, 2, 4        ; bit for <,=,> respectively (indexed by RL_LOOP)
; =============================================================================
; EXPR_ADD ? Tier 2: addition, subtraction  (also relational dispatch above)
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
EA_sum: CLC
        LDA T1
        ADC T0
        STA T0
        LDA T1+1
        ADC T0+1
        STA T0+1
        BRA EA_lp
EA_rts: RTS
; =============================================================================
; EXPR1 ? Tier 3: multiply / divide  (merged sign-handling kernel)
; =============================================================================
EXPR1:
        JSR EXPR2
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
        JSR EXPR2            ; right operand -> T0
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
E1_p2:  STZ T2               ; clear accumulator
        STZ T2+1
        LDY #16              ; 16-bit iteration count
        LDA OP
        CMP #'*'
        BEQ E1_mul_mb        ; '*' -> multiply
        BRA E1_div_kern      ; '/' or '%' -> divide (remainder also computed)
        ; ---- MUL kernel: T2 = |T1| * |T0|  (shift-and-add) ----
E1_mul_mb:
        LSR T1+1
        ROR T1
        BCC E1_mul_ms
        CLC
        LDA T2
        ADC T0
        STA T2
        LDA T2+1
        ADC T0+1
        STA T2+1
E1_mul_ms:
        ASL T0
        ROL T0+1
        DEY
        BNE E1_mul_mb
        LDA T2               ; result -> T0
        STA T0
        LDA T2+1
        STA T0+1
        BRA E1_sign
        ; ---- DIV kernel: T1 = |T1| / |T0|, remainder in T2  ----
E1_div_kern:
E1_div_db:
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
        BCC E1_div_ds
        STX T2
        STA T2+1
        INC T1
E1_div_ds:
        DEY
        BNE E1_div_db
        LDA OP               ; MOD: result is remainder (T2), not quotient (T1)
        CMP #'%'
        BEQ E1_mod_result
        LDA T1               ; quotient -> T0
        STA T0
        LDA T1+1
        STA T0+1
        BRA E1_sign
E1_mod_result:
        LDA T2               ; remainder -> T0
        STA T0
        LDA T2+1
        STA T0+1
        ; *** FALL THROUGH to E1_SIGN ***
        ; ---- shared sign postamble ----
E1_sign:
        PLA                  ; pull saved sign byte
        BPL E1_pos
        JSR NEG16            ; result should be negative
E1_pos: JMP E1_lp            ; tail jump to loop  (saves 1 RTS)
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
        ; Advance LFSR: shift right 1; if bit fell out, XOR with $B400
        LDA RND_SEED
        LSR RND_SEED+1       ; shift hi byte right, MSB = 0
        ROR RND_SEED         ; shift lo byte right, MSB = old hi bit 0
        BCC E2_rnd_done      ; no feedback needed
        LDA RND_SEED+1
        EOR #$B4             ; apply feedback taps (x^16+x^14+x^13+x^11+1)
        STA RND_SEED+1
        ; lo byte tap is $00 so no EOR needed
E2_rnd_done:
        LDA RND_SEED
        STA T0
        LDA RND_SEED+1
        AND #$7F             ; force positive (clear bit 15) ? 1..32767
        STA T0+1
        RTS
; E2_inkey removed v15.1 (INKEY removed to save space)
; =============================================================================
; E2_USR ? USR(addr): call machine-code subroutine at addr
;   On entry: A = T0 lo byte (low byte of last expression, for parameter passing)
;   Out: T0  (caller sets this before RETURN if returning a value)
;   Clobbers: A X Y (and anything the called routine touches)
; =============================================================================
E2_usr: JSR GETCI            ; consume USR token
        JSR E2_ARG1          ; consume '(expr)' into T0
        JMP (T0)            ; tail call

; =============================================================================
; E2_SGN ? SGN(n): sign of n  ?  -1 (negative), 0 (zero), 1 (positive)
; E2_sgn removed (v15.0, space for CORDIC)
; =============================================================================
EXPR2:
        JSR WPEEK
        CMP #'('
        BEQ E2_par
        CMP #'-'
        BEQ E2_neg
        CMP #'+'
        BEQ E2_pos
        CMP #TOK_NOT
        BEQ E2_not
        CMP #TOK_NUM
        BEQ E2_num
; --- function tokens: check in reverse handler-placement order so closest handler = last checked ---
        CMP #TOK_RND
        BEQ E2_rnd
        CMP #TOK_USR
        BEQ E2_usr
        CMP #TOK_ABS
        BEQ E2_abs
; --- remaining tokens: handlers too far for BEQ, use BNE/JMP ---
        CMP #TOK_PEEK
        BNE EXPR2_t1
        JMP E2_peek
EXPR2_t1:
        CMP #TOK_CHRS
        BNE EXPR2_t2
        JMP E2_chrs
EXPR2_t2:
        CMP #TOK_ASC
        BNE EXPR2_t3
        JMP E2_asc
EXPR2_t3:
        CMP #TOK_SIN
        BNE EXPR2_t4
        JMP E2_sin
EXPR2_t4:
        CMP #TOK_COS
        BNE EXPR2_tvar_jmp
        JMP E2_cos
EXPR2_tvar_jmp:
        JMP EXPR2_tvar       ; not a function token: try as variable
; --- atom handlers (placed here so preamble BEQs above are in range) ---
E2_par: JSR GETCI            ; ( expr )
        JSR EXPR
        JMP WEAT             ; consume ')' and return  (tail call)
E2_neg: JSR GETCI            ; unary minus
        JSR EXPR2
        JMP NEG16            ; tail call
E2_pos: JSR GETCI            ; unary plus: no-op
        BRA EXPR2            ; tail call
E2_not: JSR GETCI            ; NOT: bitwise complement
        JSR EXPR2
        LDA T0
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
        RTS
E2_num: JMP PNUM             ; $FF lo hi inline number  (tail call)
E2_bad: STZ T0               ; unrecognised atom: return 0
        STZ T0+1
E2_abs_pos:
        RTS
; =============================================================================
; E2_ABS ? ABS(n): absolute value of n  ?  n if n=0, else -n
;   Clobbers: A T0
; =============================================================================
E2_abs: JSR GETCI            ; ABS(n)
        JSR E2_ARG1
        LDA T0+1
        BPL E2_abs_pos
        JMP NEG16            ; tail call: negate if negative

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
        RTS
; =============================================================================
; ASR16 -- arithmetic right shift T0 by X positions (X=0..11)
;   In : T0 signed 16-bit; X = count
;   Out: T0 shifted, sign-extended
;   Clobbers: A X
; =============================================================================
ASR16:
        CPX #0
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
        LDA CZ+1
        BMI CK_NEG
        ; d=+1
        LDA CY
        STA T0
        LDA CY+1
        STA T0+1
        LDX CIDX
        JSR ASR16
        LDA CX
        SEC
        SBC T0
        STA CX
        LDA CX+1
        SBC T0+1
        STA CX+1
        LDA CX_SAV
        STA T0
        LDA CX_SAV+1
        STA T0+1
        LDX CIDX
        JSR ASR16
        LDA CY
        CLC
        ADC T0
        STA CY
        LDA CY+1
        ADC T0+1
        STA CY+1
        LDX CIDX
        TXA
        ASL
        TAX
        LDA CZ
        SEC
        SBC ATAN_TBL,x
        STA CZ
        LDA CZ+1
        SBC ATAN_TBL+1,x
        STA CZ+1
        BRA CK_NX
CK_NEG: ; d=-1
        LDA CY
        STA T0
        LDA CY+1
        STA T0+1
        LDX CIDX
        JSR ASR16
        LDA CX
        CLC
        ADC T0
        STA CX
        LDA CX+1
        ADC T0+1
        STA CX+1
        LDA CX_SAV
        STA T0
        LDA CX_SAV+1
        STA T0+1
        LDX CIDX
        JSR ASR16
        LDA CY
        SEC
        SBC T0
        STA CY
        LDA CY+1
        SBC T0+1
        STA CY+1
        LDX CIDX
        TXA
        ASL
        TAX
        LDA CZ
        CLC
        ADC ATAN_TBL,x
        STA CZ
        LDA CZ+1
        ADC ATAN_TBL+1,x
        STA CZ+1
CK_NX:  LDX CIDX
        INX
        CPX #12
        BEQ CK_DN
        JMP CK_IT
CK_DN:  RTS
; =============================================================================
; E2_sin / E2_cos  --  SIN(deg)*1000 / COS(deg)*1000
;   In : token already peeked; A = token
;   Out: T0 = result (signed 16-bit, -1000..+1000)
;   Uses ATEMP as SIN=0/COS=1 selector; T1 as quadrant negation flags.
;   Quadrant folding (all-8-bit compares, no CMP #imm > 255):
;     Q1  0-90:    fold = angle;       flags=0 (no negs)
;     Q2  91-180:  fold = 180-angle;   flags=1 (negate CX)
;     Q3a 181-255: fold = angle-180;   flags=3 (negate CX+CY)
;     Q3b 256-270: fold = 76+lo;       flags=3
;     Q4  271-360: fold = 104-lo;      flags=2 (negate CY)
;   angles > 360 (T0+1 >= 2) return 0.
;   Clobbers: A X T0 T1 T2 CX CY CZ CX_SAV CIDX ATEMP
; =============================================================================
E2_cos:
        JSR GETCI
        LDA #1
        STA ATEMP           ; 1 = want COS
        BRA SC_GO
E2_sin:
        JSR GETCI
        STZ ATEMP           ; 0 = want SIN
SC_GO:
        JSR E2_ARG1         ; angle -> T0, consumes (...)
        ; Range check: T0+1 must be 0 or 1
        LDA T0+1
        BEQ SC_LO           ; hi=0: angle 0-255
        CMP #2
        BCC SC_IN           ; hi=1: angle 256-360, valid
SC_RET0:                    ; hi>=2: out of range -> return 0
        STZ T0
        STZ T0+1
        RTS
SC_IN:
        ; hi=1: angle 256-360
        LDA T0              ; lo byte (0-104 valid, 271-360 = hi:lo = 1:15..1:104)
        CMP #15             ; split Q3b/Q4: 271-256=15
        BCS SC_Q4
        ; Q3b: 256-270: fold = 76+lo
        CLC
        ADC #76
        STA T0
        STZ T0+1
        LDA #3
        BRA SC_FLAGS
SC_Q4:  ; Q4: 271-360: fold = 104-lo
        LDA #104
        SEC
        SBC T0
        STA T0
        STZ T0+1
        LDA #2
        BRA SC_FLAGS
SC_LO:  ; hi=0: angle 0-255
        LDA T0
        CMP #91
        BCC SC_Q1           ; 0-90: Q1
        CMP #181
        BCC SC_Q2           ; 91-180: Q2
        ; Q3a: 181-255: fold = angle-180
        SEC
        SBC #180
        STA T0
        LDA #3
        BRA SC_FLAGS
SC_Q2:  ; 91-180: fold = 180-angle
        LDA #180
        SEC
        SBC T0
        STA T0
        LDA #1
        BRA SC_FLAGS
SC_Q1:  LDA #0              ; no negations
SC_FLAGS:
        STA T1              ; save quadrant flags
        ; Multiply T0 (0-90) * 182 -> CZ  (182=0b10110110)
        LDA #182
        STA T2              ; use T2 as multiplier shift reg (T1 flags already saved)
        STZ CZ
        STZ CZ+1
        LDX #8
SC_ML:  LSR T2              ; bit -> C
        BCC SC_MN
        LDA CZ
        CLC
        ADC T0
        STA CZ
        LDA CZ+1
        ADC T0+1
        STA CZ+1
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
        ; NOTE: cannot reuse NEG16/NEG_T1 here -- NEG16 hardcodes LDX #0
        ; internally (it is a fixed T0-only entry point, with NEG_T1 as a
        ; second fixed entry point via the .BYTE $2C skip trick into the
        ; same body at a different hardcoded offset). Passing a custom X
        ; offset into NEG16 does not work: NEG16's own LDX #0 discards it.
        ; Inline negation used instead for CX/CY (confirmed correct by sim).
        LDA T1
        LSR                 ; bit0 -> C: negate CX?
        BCC SC_NCX
        LDX #CX-T0
        JSR NEG_X
SC_NCX: LDA T1               ; reload (A clobbered if NEG_X ran)
        LSR
        LSR                 ; bit1 -> C: negate CY?
        BCC SC_NCY
        LDX #CY-T0
        JSR NEG_X
SC_NCY:
        ; Select result: ATEMP=0->SIN(CY), ATEMP=1->COS(CX)
        LDA ATEMP
        BEQ SC_SIN
        LDA CX              ; COS
        STA T0
        LDA CX+1
        STA T0+1
        BRA SC_SCALE
SC_SIN: LDA CY
        STA T0
        LDA CY+1
        STA T0+1
SC_SCALE:
        ; Scale T0 from CORDIC units (0..9949) to *1000 via (|T0|>>4)*103>>6
        ; All 16-bit: max intermediate = 621*103 = 63963 < 65535.
        LDA T0+1
        BPL SC_SPOS
        LDX #0
        JSR NEG16           ; negate T0 (X=0 offset)
        LDA #1
        STA ATEMP           ; negative flag
        BRA SC_SDO
SC_SPOS:
        STZ ATEMP
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
        CLC
        LDA T2
        ADC T0
        STA T2
        LDA T2+1
        ADC T0+1
        STA T2+1
SC_SMN: ASL T0
        ROL T0+1
        DEX
        BNE SC_SML
        ; >>6: T0 = T2>>6
        LDA T2
        STA T0
        LDA T2+1
        STA T0+1
        LDX #6
        JSR SHIFT_R16_T0
        ; Apply sign
        LDA ATEMP
        BEQ SC_DONE
        LDX #0
        JSR NEG16           ; negate T0 (X=0 offset)
SC_DONE:
        RTS
; =============================================================================
; EXPR2_tvar ? variable or unrecognised atom (BRA from dispatch above)
; =============================================================================
EXPR2_tvar:
        JSR PARSE_VAR        ; harmless redundant WPEEK_UC re-peek (IP unmoved so far)
        BCC ET_ok            ; C=0: matched
        JMP E2_bad           ; C=1: no match (E2_bad too far for BCS)
ET_ok:  TAX
        LDA VARS,x
        STA T0
        LDA VARS+1,x
        STA T0+1
        RTS
; =============================================================================
; E2_PEEK ? PEEK(addr): read one byte from memory address  ?  0..255
;   Clobbers: A T0
; =============================================================================
E2_peek:
        JSR GETCI            ; PEEK(addr)
        JSR E2_ARG1
        LDA (T0)             ; 65C02 zp-indirect: read memory at addr
        STA T0
        STZ T0+1
        RTS
; =============================================================================
; E2_CHRS ? CHR$(n): numeric ASCII code to character value for PRINT
;   Returns n unchanged in T0; PRINT emits it directly via PUTCH.
;   Clobbers: A T0
; =============================================================================
E2_chrs:
        JSR GETCI            ; CHR$(n): result is just n (char value)
        JSR E2_ARG1
        RTS

; =============================================================================
; E2_ARG1 ? shared parser helper for single-argument functions
;   In:  IP points at '('
;   Out: T0 = argument value; IP advanced past closing ')'
; =============================================================================
E2_ARG1:
        JSR EAT_EXPR         ; consume '(' then evaluate argument
        JMP WEAT             ; consume ')' and return (tail call)
; =============================================================================
; E2_ASC ? ASC("str") or ASC(n): ASCII code of first character
;   String form: ASC("X") ? ASCII value of X.
;   Numeric form: ASC(n) ? n unchanged (identity, for symmetry with CHR$).
;   Clobbers: A T0
; =============================================================================
E2_asc: JSR GETCI            ; ASC("str") or ASC(n)
        JSR WEAT             ; consume '('
        JSR WPEEK
        CMP #'"'
        BNE E2_asc_num
        JSR GETCI            ; consume '"'
        JSR GETCI            ; first char -> A
        STA T0
        STZ T0+1
E2_asc_sk:
        LDA (IP)             ; peek: closing '"' or CR ?
        CMP #'"'
        BEQ E2_asc_dn
        CMP #$0D
        BEQ E2_asc_dn
        JSR GETCI
        BRA E2_asc_sk
E2_asc_dn:
        JSR GETCI            ; consume closing '"' or CR
        JMP WEAT             ; consume ')' and return  (tail call)
E2_asc_num:
        JSR EXPR
        JMP WEAT             ; consume ')' and return  (tail call)
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
        PLA
        TAX
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
        RTS

DO_let_pop:
        PLA
        LDA #ERR_UK
        JMP DO_ERROR
DO_let_dn:
        RTS

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

; PUTCH ? character output  (PRNL drops through here for the LF)
;   In:  A    character to send
;   Out: Character emitted to terminal device.
;   Clobbers: None.
PUTCH:  STA IO_PUTCH
        RTS
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
NEG_T1:
        LDX #2               ; X=2: address offset to T1 from T0
        .BYTE $2C            ; BIT abs  ? consumes next 2 bytes as operand
NEG16:
        LDX #0               ; X=0: address offset to T0
NEG_X:                       ; entry with X pre-loaded by caller
        LDA #0
        SEC
        SBC T0,x
        STA T0,x
        LDA #0
        SBC T0+1,x
        STA T0+1,x
        RTS
; =============================================================================
; PEEKC ? read byte at IP without advancing IP
;   In:  IP   token stream pointer
;   Out: A    byte at (IP)
;   Clobbers: None.
; -----------------------------------------------------------------------------
; GETCI ? read byte at IP and advance IP by one
;   In:  IP   token stream pointer
;   Out: A    byte that was at (IP);  IP  incremented
;   Clobbers: None.
; -----------------------------------------------------------------------------
; UC ? convert A to uppercase if it is a lowercase ASCII letter
;   In:  A    any byte
;   Out: A    uppercased (a-z ? A-Z); all other bytes unchanged
;   Clobbers: None.  (flags are affected)
; =============================================================================
; (PEEKC inlined as LDA (IP) at all call sites)
GETCI:  LDA (IP)             ; 65C02 zp-indirect: fetch byte at IP, then advance
    ; drop through
; INCIP ? increment IP (16-bit pointer) by 1
;   In:  IP points at current token byte.
;   Out: IP advanced by one byte.
;   Clobbers: Flags.
INCIP:  INC IP
        BNE INCIP_ok
        INC IP+1
INCIP_ok:
        RTS
; =============================================================================
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
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        ASL                  ; x2: byte offset into VARS
        CLC
        RTS
PV_fail:
        SEC
        RTS
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
; =============================================================================
; WEAT ? skip whitespace, consume (eat) the next byte
;   In:  IP   token stream pointer
;   Out: A    the consumed byte;  IP  advanced one past the first non-space
;   Clobbers: None.
; -----------------------------------------------------------------------------
; EAT_EXPR ? skip whitespace, consume one byte, then evaluate an expression
;   Convenience wrapper: WEAT then EXPR.
;   In:  IP   points at optional whitespace then expression
;   Out: T0   expression result;  IP  advanced past expression
;   Clobbers: A X Y T1 T2
; -----------------------------------------------------------------------------
; WPEEK_UC ? skip whitespace, peek next byte, uppercase it
;   In:  IP   token stream pointer
;   Out: A    first non-space byte, uppercased;  IP  unchanged
;   Clobbers: None.
; -----------------------------------------------------------------------------
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
        JSR INCIP
        BRA SKIP_STMT
SKST_colon:
        CLC
        RTS
SKST_eol:
        SEC
        RTS
; =============================================================================
; SKIPEOL ? advance IP past the $0D end-of-line marker
;   In:  IP   anywhere in the current token stream line
;   Out: IP   points at first byte of the next line
;   Clobbers: A
; =============================================================================
WEAT:   JSR WPEEK
        BRA GETCI            ; consume the non-space byte and return  (tail call)
EAT_EXPR:
        JSR WEAT
        JMP EXPR             ; tail call
SKIPEOL:
        JSR GETCI
        CMP #$0D
        BEQ SKIPEOL_d
        BRA SKIPEOL
; =============================================================================
; I/O stubs ? Kowalski simulator virtual terminal
; =============================================================================
; GETCH ? blocking character input
;   In:  None.
;   Out: A    character received
;   Clobbers: None.
GETCH:  LDA IO_GETCH         ; poll Kowalski virtual port
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
ROMEND = *                   ; first byte after executable ROM code 

; =============================================================================
; Vector page notes:
        .ORG $FFFC
        .DW INIT             ; RESET vector
        .DW IRQ_HANDLER          ; IRQ vector
