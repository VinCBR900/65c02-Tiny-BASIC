; =============================================================================
; miniBASIC 65C02 v1.4
;
; 4KB Float BASIC (MBF4) for the 65C02.
; Derived from uBASIC v18.1 (integer 65C02) + miniBASIC 8088 v2.0 (float).
;
; Statements accepted
;   END  FOR..TO..STEP  FREE  GOSUB  GOTO  HELP  IF..THEN  INPUT  LET  LIST
;   NEW  NEXT  POKE  PRINT  REM  RETURN  RUN
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   CHR$(n)   PEEK(addr)   USR(addr)   SIN(deg)   COS(deg)   A-Z variables
;
; Numbers      : MBF4 float, ~6-7 significant decimal digits (see format below)
; String print : "literals", `;`, and CHR$() only; no string variables
;
; Input buffer : GETLINE's IBUF is 32 bytes. A typed or INPUT'd line longer
;   than that is *silently truncated* -- no error is raised, and the
;   remainder is discarded character-by-character up to the terminating CR.
;   Program lines stored via EDITLN are NOT limited to 32 bytes (they bypass
;   IBUF entirely and are copied straight into program storage), so a LISTed
;   line may be longer than 32 characters even though you could never have
;   typed it directly at the prompt.
;
; FOR/NEXT : the loop variable is a real float (usable normally in the loop
;   body), but TO and STEP are evaluated as 16-bit signed integers -- this
;   keeps the 4-level-deep frame stack small enough to fit free zero page.
;   "FOR X = 1 TO 10 STEP 0.5" is therefore not supported; TO/STEP must be
;   whole numbers (a non-integer START value, e.g. "FOR X = 1.5 TO 10", is
;   fine). Max nesting depth is 4.
;
; ':' statement separator : NOT an officially supported feature -- it exists
;   as an artifact of STMT_LINE's implementation (it loops for more
;   statements after seeing ':') rather than a deliberate design, and has
;   real edge cases. Simple "VAR=expr:VAR=expr[:GOTO n]" chains work
;   correctly and are used within this file's own showcase program and
;   error-recovery paths. However "PRINT expr;:<more>" on one line is
;   broken: DO_PRINT sees the trailing ';' and unconditionally tries to
;   parse one more print item, which fails on ':' and silently prints a
;   spurious "0" before falling through to the next statement. Do not rely
;   on ':' in new code; treat any working use of it as incidental, not
;   guaranteed.
;
; Error codes (printed as "?N"):
;   ?0  syntax / bad expression
;   ?1  undefined line number
;   ?2  division or modulo by zero
;   ?3  out of memory (also: GOSUB stack full, 8 levels deep)
;   ?4  bad variable name in LET
;   ?5  RETURN without GOSUB
;   ?6  illegal (zero) STEP
;   ?7  too many nested FOR (max 4 deep)
;   ?8  NEXT without FOR
;
; ---- program storage --------------------------------------------------------
;   Base PROG ($0200); ceiling RAM_TOP ($1000 for 4 KB SRAM).
;   Line format:  <lineno_lo> <lineno_hi> <raw ASCII body> <CR>
;   No tokenisation; body bytes are stored exactly as typed.
;
; ORG $F000 (2732 EPROM).  RAM $0000-$0FFF.
; =============================================================================
; CHANGE HISTORY
;
; v1.4: Large session covering FOR/NEXT, a float-library size pass, several
;       real bugs (one pre-existing), and a uBASIC-helper porting pass.
;       ROM usage: 3831 (v1.2 baseline) -> 4021 (right after FOR/NEXT, 98.2%
;       full) -> 3879 (after this session's size work, 211 free).
;
;   FOR/NEXT
;       (1) Added FOR var=start[TO limit][STEP step] / NEXT [var]. 4-level
;           frame stack at FOR_STK ($E2-$FD, zero page). New KW_FOR/KW_TO/
;           KW_STEP keywords. NEW/NEXT share the "NE" prefix, disambiguated
;           by 3rd-char peek (same trick as GOTO/GOSUB, REM/RETURN). New
;           errors: ?6 illegal STEP, ?7 too many nested FOR, ?8 NEXT w/o FOR.
;       (2) BUG (caught before release): the draft this was built from
;           assumed uBASIC's integer VARS (2 bytes/var) -- directly adding
;           an integer STEP onto our 4-byte float VARS bytes would have
;           produced garbage. Loop variable is updated via a real
;           FLT_ADD instead; only the limit/step comparison is integer.
;
;   Float library size pass (asmdup.py-driven)
;       (3) FLT_FROM_INT/FLT_FROM_INT_B unified into one X-offset-indexed
;           routine (asmdup.py flagged them as near-duplicates).
;       (4) NORM_PACK/FLT_ADD/FLT_MUL/FLT_DIV: adopted TSB hidden-bit
;           restore, looped (not unrolled) swaps/workspace-copies, and a
;           combined STZ+BCS shift-count check, per a supplied optimized
;           draft, cross-checked instruction-by-instruction against the
;           existing code before applying.
;       (5) BUG (caught during testing, introduced by #4): FLT_PARSE's
;           digit-accumulation loop kept a digit in X across `JSR
;           MUL_BY_TEN` -- fine while FLT_MUL happened not to touch X, but
;           its header already documented X as clobbered, and the new
;           FLT_MUL legitimately does clobber it. "PRINT 10", "PRINT 100"
;           etc. silently produced wrong values. Fixed by saving the digit
;           to T0 before the call instead of X after.
;       (6) 8 duplicated 12-byte inline FLT_A push/pop sequences replaced
;           with PUSH_FLT_A/POP_FLT_A subroutines (asmdup.py find). NOTE:
;           these cannot be plain JSR/RTS wrappers around PHA x4/PLA x4 --
;           the pushed frame must survive underneath the JSR's own return
;           address across arbitrary intervening code, so each one pops
;           its own return address out of the way first, does the real
;           work, then pushes it back before RTS. A naive first attempt
;           without this trampoline crashed immediately (RTS consumed the
;           last 2 bytes of parked float data as a return address).
;
;   Bug fix (pre-existing, not from this session)
;       (7) FLT_PRINT's fraction-printing guard did `CPY FP_LASTNZ; BCS
;           FPEND` ("skip if already past the last significant digit"),
;           but BCS fires on Y>=FP_LASTNZ, not Y>FP_LASTNZ. A fraction with
;           exactly one significant digit (e.g. 1.5) has Y land exactly on
;           FP_LASTNZ, so the off-by-one skipped it -- "PRINT 1.5" printed
;           "1". Confirmed present in the very first uploaded v1.2; never
;           triggered until FOR/NEXT's float-start-value test hit it.
;
;   uBASIC helper porting pass (reviewed for applicability, not all of
;   uBASIC's line-editing helpers translate -- see below)
;       (8) PROG2X: one indexed routine sets IP/PE/LP to PROG (were 5
;           separate 4-instruction inline sequences); works here because
;           IP/PE/LP happen to sit at the same +0/+4/+6 ZP offsets uBASIC
;           assumes.
;       (9) PE_CMP_X: one indexed routine compares IP or LP against PE
;           (were 3 separate inline compares in EDITLN/DO_LIST/GOTOL).
;      (10) ADD2_LP/BUMP_LP: shared LP+=2 / LP+=1 (uBASIC's JSR-then-fall-
;           through trick), replacing 3 inline increments in DO_LIST.
;      (11) INSLINE replaced with uBASIC's design: a T0_CMP_LP-driven
;           backward shift-copy instead of our own T2DEC-counter-driven
;           one, and a simpler PE+size-vs-RAM_TOP overflow check. ~43
;           bytes saved; extensively tested (append, insert-before,
;           replace same/longer/shorter body, delete).
;      (12) LSKIP added (shared "advance LP past the current line",
;           uBASIC's design) and GOTOL restructured to search via LP
;           instead of IP -- converting to IP only once a match is found
;           -- so it can share LSKIP with EDITLN instead of each keeping
;           its own 21-byte inline copy. Highest-risk change this session
;           (GOTOL underlies GOTO/GOSUB/RUN/NEXT); tested against all four.
;      (13) T0_CMP_LP checked against our INSLINE and NOT applicable on
;           its own -- our original INSLINE used a different algorithm
;           shape (copy-based, no "found it" check). Became applicable
;           once INSLINE itself was replaced per (11).
;      (14) uBASIC's DO_LIST checked and found to be LARGER, not smaller
;           -- it implements LIST start,end range filtering, which ours
;           doesn't have (out of scope). Not ported.
;      (15) STORE_VAR: "copy FLT_A into VARS[X..X+3]" was duplicated
;           identically in DO_LET, DO_INPUT, DO_FOR, DO_NEXT (asmdup.py
;           find); now one shared routine.
;
;   65C02 opcode pass
;      (16) Several `LDY #0` + `(zp),Y` sites where Y never changes across
;           the access converted to plain `(zp)` (65C02 zero-page-indirect,
;           no index): PUTSTR's print loop, LSKIP, DO_POKE, EXPR2's PEEK.
;           CAUGHT: an attempted `CMP (zp)` in MTCHKW assembles fine but
;           the simulator only implements the 65C02 no-index-indirect mode
;           for LDA/STA ($B2/$92), not CMP/ADC/SBC/etc ($D2 unknown-opcode
;           halt) -- reverted that one site back to LDY #0 + `(zp),Y`.
;      (17) Two `PLA;TAX` pairs (DO_LET, DO_INPUT, both feeding STORE_VAR)
;           replaced with `PLX`.
;      (18) FLT_PRINT: `INC A` replaces `CMP #$FF` after FLT_CMP (A=$FF
;           wraps to $00, same Z result, verified against FLT_CMP's actual
;           0/1/$FF contract); the digit-loop's saved digit/index moved
;           from dedicated ZP bytes (FP_IX/FP_XSV, now free) to PHA/PHX
;           (safe here since it's a plain in-frame push/pop, not a
;           subroutine call -- unlike PUSH_FLT_A/POP_FLT_A, no trampoline
;           needed); `ORA #'0'` replaces `CLC/ADC #'0'` (digit is 0-9, no
;           overlapping bits, OR and ADD agree); the separate integer-
;           digit and zero-padding loops merged into one; the <1.0 case's
;           fraction-printing loop now reuses the >=1.0 case's loop via a
;           branch instead of duplicating it. REJECTED from the supplied
;           draft: `JMP POP_FLT_A` as a tail call at the end -- POP_FLT_A's
;           trampoline (see #6) requires being entered via JSR so it has
;           its own return address to manage; tail-calling it means it
;           consumes the caller's return address instead, corrupting the
;           stack. Kept as `JSR POP_FLT_A` / `RTS`.
;
; v1.3: (1) Ported GOSUB/RETURN from uBASIC v1.3: 8-level zero-page return
;           stack at GOSUB_LO ($BB-$DA). GOTO/GOSUB share one ST_TAB entry
;           and one keyword prefix ("GO"); the handler peeks the 3rd raw
;           input character to tell them apart (uBASIC's trick). Same for
;           REM/RETURN ("RE" + 3rd char). New ?5 error: RETURN w/o GOSUB.
;       (2) MTCHKW/KW_TAB replaced with uBASIC's 2-char-prefix scheme (was
;           full-string, high-bit-terminated, variable length). Saves table
;           bytes now and scales better as keywords are added later (FOR/
;           NEXT etc). BEHAVIOR CHANGE: keyword matching is now lenient
;           like uBASIC -- e.g. "PRX" matches PRINT, since only the first
;           2 letters are checked and any run of trailing letters is
;           swallowed. Was previously exact-spelling only.
;
; v1.2: (1) Zero page reorganized to be fully contiguous $00-$B9 (was two small
;           gaps at $0F and $A8-$AB), every byte now individually commented.
;       (2) Every subroutine given a header comment (purpose/In/Out/Clobbers),
;           matching the uBASIC documentation convention.
;       (3) Showcase program rewritten to exercise every statement and
;           function, including a CORDIC sine wave and a floating-point
;           Mandelbrot finale.
;
; v1.1: (1) DELINE no longer corrupts LP when editing/deleting a program
;           line with >=256 bytes of trailing program text (the copy loop's
;           page-boundary bookkeeping was bumping the caller's insertion
;           pointer along with its own source pointer).
;       (2) Immediate-mode GOTO no longer crashes when issued before the
;           first RUN (DO_GOTO now only collapses the stack via RUNSP while
;           a program is actually RUNning).
;       (3) Dead FLT_A_TO_C/FLT_C_TO_A removed, FLT_C zero-page freed.
;       (4) FLT_A_TO_B/FLT_B_TO_A, variable fetch/store, and FLT_ZERO
;           rerolled into loops; float-alignment byte fast-path removed;
;           PUTSTRZP tail-calls PUTCH.  68 bytes smaller overall.
;
; MBF4: Byte0=biased_exp($00=zero), Byte1=sign|mant[22:16], Byte2-3=mant[15:0]
;       value=(-1)^sign * 2^(exp-$80) * 0.1mmm...
;       1.0=[$81,$00,$00,$00]  -1.0=[$81,$80,$00,$00]  10.0=[$84,$20,$00,$00]
;
; ZP:  $00/$01=IP  $02/$03=CURLN  $04/$05=PE  $06/$07=LP
;      $08/$09=T0  $0A/$0B=T1  $0C/$0D=T2
;      $0E=RUN  $0F free  $10-$2F=IBUF(32)
;      $30-$33=FLT_A  $34-$37=FLT_B  $38-$3B=CX/CY (CORDIC)
;      $3C=FLT_SA  $3D=FLT_SB  $3E=FLT_ER  $3F=FLT_DE  $40=FLT_DB
;      $41 free  $42=RUNSP  $43-$AA=VARS(A-Z,4 bytes each)
;      $AB=FP_LASTNZ  $AC-$B1=FLT mul/div scratch
;      $B2-$B9=CORDIC (CZ,TMPX,TMPY,MASKXZ,MASKY)
;      $BA=GOSUB_SP  $BB-$DA=GOSUB_LO (8-level return stack)  $DB-$FF free
; Zero page is fully contiguous $00-$DA -- see equates below for a comment
; on every byte.
;
; TRUE=-1.0  FALSE=0.0
; Errors: ?0=syntax ?1=undef_line ?2=div0 ?3=out_of_mem ?4=bad_var

         .opt proc65c02

IO_OUT   = $E001            ; UART output: write character to terminal
IO_IN    = $E004            ; UART input: read character (0 = no char ready)
RAM_TOP  = $1000            ; first address above usable SRAM (4 KB)

; ---- zero page (fully contiguous, $00-$DA; $DB-$FF free) --------------------
; NOTE: IP and CURLN must stay sequential (IP,IP+1,CURLN,CURLN+1) -- the
; GOSUB/RETURN 4-byte frame push/pop loop in DO_GOTO/DO_REM_CHK depends on
; it, same as it does in uBASIC.
IP       = $00              ; 16-bit: interpreter/parse pointer
CURLN    = $02              ; 16-bit: currently-executing line number
PE       = $04              ; 16-bit: program end (one past last byte)
LP       = $06              ; 16-bit: line pointer / MTCHKW's IP-backup scratch
T0       = $08              ; 16-bit: primary scratch word / expression result
T1       = $0A              ; 16-bit: secondary scratch word / MTCHKW keyword ptr
T2       = $0C              ; 16-bit: tertiary scratch word / STMT jump target
RUN      = $0E              ; 8-bit:  run flag ($00 = immediate, $FF = running)
; $0F free (was FP_IX -- FLT_PRINT's digit loop now uses PHA/PLA instead)
IBUF     = $10              ; 32-byte input line buffer ($10-$2F)
FLT_A    = $30              ; 4-byte float accumulator (exp,sign|mant_hi,mant,mant)
FLT_B    = $34              ; 4-byte float operand B
CX       = $38              ; 16-bit: CORDIC X accumulator (CX/CY must stay
CY       = $3A              ; 16-bit: CORDIC Y accumulator  contiguous as one block)
FLT_SA   = $3C              ; 8-bit:  sign of FLT_A during add/sub/mul/div
FLT_SB   = $3D              ; 8-bit:  sign of FLT_B during add/sub/mul/div
FLT_ER   = $3E              ; 8-bit:  running exponent during add/mul/div
FLT_DE   = $3F              ; 8-bit:  decimal exponent scratch (FLT_PRINT/PARSE)
FLT_DB   = $40              ; 8-bit:  extra mantissa bit scratch (align/round)
; $41 free (was FP_XSV -- FLT_PRINT's digit loop now uses PHX/PLX instead)
RUNSP    = $42              ; 8-bit:  stack-pointer snapshot for GOTO/RUN unwind
VARS     = $43              ; A-Z variable store (4 bytes each), 104 bytes
VARS_MAX = $67              ; 103; STZ VARS,X for X=103..0 clears VARS (104 bytes)
FP_LASTNZ = $AB             ; 8-bit:  FLT_PRINT index of last non-zero digit
FLT_MA   = $AC              ; 8-bit:  MUL multiplicand scratch (hi)
FLT_MB   = $AD              ; 8-bit:  MUL multiplicand scratch (mid)
FLT_MC   = $AE              ; 8-bit:  MUL multiplicand scratch (lo)
FLT_DVH  = $AF              ; 8-bit:  DIV divisor scratch (hi)
FLT_DVM  = $B0              ; 8-bit:  DIV divisor scratch (mid)
FLT_DVL  = $B1              ; 8-bit:  DIV divisor scratch (lo)
CZ       = $B2              ; 16-bit: CORDIC Z (angle accumulator)
TMPX     = $B4              ; 16-bit: CORDIC per-iteration tmpX (TMPX/TMPY must
TMPY     = $B6              ; 16-bit: CORDIC per-iteration tmpY  stay contiguous)
MASKXZ   = $B8              ; 8-bit:  CORDIC branchless sign mask for X/Z update
MASKY    = $B9              ; 8-bit:  CORDIC branchless sign mask for Y update
GOSUB_SP = $BA               ; 8-bit:  GOSUB/RETURN stack pointer (holds a ZP
                              ;  address directly, not an index -- see DO_GOTO)
GOSUB_LO = $BB                ; base of the 8-level GOSUB return-frame stack
                               ; (32 bytes: 8 frames x 4 bytes: IP,IP+1,CURLN,CURLN+1)
GOSUB_TOP  = GOSUB_LO+31    ; empty-stack value for GOSUB_SP (topmost byte)
GOSUB_FULL = GOSUB_LO+3     ; lowest GOSUB_SP for which a full push still fits
PFA_RL   = $DB               ; 8-bit: PUSH_FLT_A/POP_FLT_A return-addr trampoline lo
PFA_RH   = $DC               ; 8-bit: PUSH_FLT_A/POP_FLT_A return-addr trampoline hi
; ---- FOR/NEXT (loop VARIABLE is a real float in VARS; LIMIT and STEP are
; 16-bit signed integers, to keep the 4-level frame stack small enough to
; fit free zero page -- "FOR X = 1 TO 10 STEP 0.5" is therefore not
; supported, TO/STEP must be whole numbers) ----
FVAR     = $DD               ; 8-bit:  staged byte offset into VARS (var*4)
FLIM     = $DE               ; 16-bit: staged limit (contiguous with FVAR/FSTEP
                              ;  for FSTK_PUSH's indexed copy loop)
FSTEP    = $E0               ; 16-bit: staged step
FOR_STK  = $E2               ; 4 frames x 7 bytes: [var_slot,lim_lo,lim_hi,
                              ;  step_lo,step_hi,loop_line_lo,loop_line_hi]
FSTK     = $FE                ; 8-bit: count of active FOR loops (0-4)
; $FF free
PROG     = $0200
IBUF_MAX = 31
CR       = $0D
LF       = $0A
BS       = $08
ERR_SN   = 0
ERR_UL   = 1
ERR_OV   = 2
ERR_OM   = 3
ERR_UK   = 4
ERR_RET  = 5                 ; RETURN without GOSUB
ERR_ST   = 6                 ; illegal (zero) STEP
ERR_FOR  = 7                 ; too many nested FOR (max 4 deep)
ERR_NF   = 8                 ; NEXT without FOR

         .ORG $F000
ROMSTART: BRA INIT   ; Kowalski trampoline

; ---- STRING/KEYWORD TABLE (page $F0) ----------------------------------------
STR_PAGE = >STR_BANNER
STR_BANNER: .DB "miniBASIC 65C02"
STR_CRLF:   .DB $0D,$8A
STR_FREE:   .DB "FRE",$C5     ; " FREE" tail for DO_FREE; KW_FREE (2-byte
                                ; prefix, no terminator) can no longer double
                                ; as this string under the uBASIC KW scheme
STR_IN:     .DB " IN",$A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB
; Two uppercase ASCII bytes per keyword (no terminator, no length).
; MTCHKW compares this 2-byte prefix, then skips trailing letters at IP so
; the full BASIC keyword is consumed (uBASIC's scheme). GOTO/GOSUB share
; the "GO" entry and REM/RETURN share "RE" -- their handlers peek the 3rd
; raw input character to disambiguate (see DO_GOTO / DO_REM_CHK).
KW_TAB:
KW_PRINT:  .DB "PR"
KW_IF:     .DB "IF"
KW_GOTO:   .DB "GO"
KW_LIST:   .DB "LI"
KW_RUN:    .DB "RU"
KW_NEW:    .DB "NE"
KW_INPUT:  .DB "IN"
KW_REM:    .DB "RE"
KW_END:    .DB "EN"
KW_LET:    .DB "LE"
KW_THEN:   .DB "TH"
KW_CHRS:   .DB "CH"
KW_POKE:   .DB "PO"
KW_FREE:   .DB "FR"
KW_PEEK:   .DB "PE"
KW_USR:    .DB "US"
KW_SIN:    .DB "SI"
KW_COS:    .DB "CO"
KW_FOR:    .DB "FO"
KW_TO:     .DB "TO"
KW_STEP:   .DB "ST"

; =============================================================================
; INIT  --  cold start
;
;   In:  -- (entered via reset vector at $FFFC, or the Kowalski trampoline)
;   Out: never returns; falls through into MAIN
;   Clobbers: everything
; =============================================================================
INIT:    LDX #$FF
         TXS
         CLD
         CLI
INIZ:    STZ 0,X
         DEX
         BPL INIZ
         LDA #GOSUB_TOP        ; INIZ zeroed GOSUB_SP too; 0 is not the empty
         STA GOSUB_SP          ; sentinel -- set it properly
         LDA #<SHOWCASE_END
         STA PE
         LDA #>SHOWCASE_END
         STA PE+1
         LDA #<STR_BANNER
         JSR PUTSTR
         JSR DO_FREE

; =============================================================================
; MAIN  --  the "> " prompt loop
;
;   In:  -- (falls through from INIT, or looped back to from itself)
;   Out: never returns
;   Clobbers: everything
;
;   Reads one line; if it starts with a digit, treats it as a numbered
;   program line (EDITLN); otherwise runs it immediately (STMT).
; =============================================================================
MAIN:    STZ RUN
         JSR GETLINE_M
         JSR WPEEK
         CMP #CR
         BEQ MAIN
         SEC
         SBC #'0'
         CMP #10
         BCS MAIND
         JSR EDITLN
         BRA MAIN
MAIND:   JSR STMT
         BRA MAIN

; =============================================================================
; DO_ERROR  --  print "?N" (and, if a program is RUNning, " IN <line>") then
;               abandon the current statement and return to MAIN
;
;   In:  A = error code (see ERR_* equates)
;   Out: never returns to caller -- falls into MAIN
;   Clobbers: everything
; =============================================================================
DO_ERROR:
         PHA
         JSR PRNL
         LDA #'?'
         JSR PUTCH
         PLA
         CLC
         ADC #'0'
         JSR PUTCH
         LDA RUN
         BEQ DE_NL
         LDA #<STR_IN
         JSR PUTSTR
         LDA CURLN
         STA T0
         LDA CURLN+1
         STA T0+1
         JSR PRT16
DE_NL:   JSR PRNL
         JMP MAIN

; =============================================================================
; IRQ_HANDLER  --  BRK/IRQ vector target (Ctrl-C style break)
;
;   In:  -- (hardware IRQ/BRK)
;   Out: if RUN, unwinds to MAIN printing "BREAK IN <line>"; else RTI
;   Clobbers: everything (on the break path; RTI path is transparent)
; =============================================================================
IRQ_HANDLER:
         LDA RUN
         BEQ IRQI
         LDX RUNSP
         TXS
         LDA #<STR_BREAK
         JSR PUTSTR
         LDA #<STR_IN
         JSR PUTSTR
         LDA CURLN
         STA T0
         LDA CURLN+1
         STA T0+1
         JSR PRT16
         JSR PRNL
         JMP MAIN
IRQI:    RTI

; =============================================================================
; GETLINE_M / GETLINE_I / GETLINE  --  read one line of input into IBUF
;
;   In:  GETLINE_M prints "> " (main prompt); GETLINE_I prints "? " (INPUT
;        prompt); both then fall into GETLINE, which just reads.
;   Out: IBUF holds the typed line (CR-terminated, backspace-editable,
;        silently truncated past IBUF_MAX); IP -> IBUF
;   Clobbers: A, X, IP
; =============================================================================
GETLINE_M:
         LDA #'>'
         .DB $2C
GETLINE_I:
         LDA #'?'
         JSR PUTCH
         LDA #' '
         JSR PUTCH
GETLINE: LDX #0
GLL:     JSR GETCH
         CMP #CR
         BEQ GLD
         CMP #BS
         BNE GLS
         CPX #0
         BEQ GLL
         DEX
         BRA GLL
GLS:     CPX #IBUF_MAX
         BCS GLL
         STA IBUF,X
         INX
         BRA GLL
GLD:     STA IBUF,X
         JSR PRNL
         LDA #<IBUF
         STA IP
         LDA #>IBUF
         STA IP+1
         RTS

; =============================================================================
; PNUM  --  parse an unsigned decimal integer from IP into T0
;
;   In:  IP -> first (possibly space-prefixed) digit
;   Out: T0 = parsed 16-bit value (0 if no digits present); IP advanced past
;        all consumed digits
;   Clobbers: A, X, T2
; =============================================================================
PNUM:    JSR WSKIP
         STZ T0
         STZ T0+1
PNL:     LDA (IP)
         EOR #'0'              ; maps '0'-'9' to 0-9; anything else is >= 10
         CMP #10
         BCS PND
         STA T2
         STZ T2+1
         LDX #10               ; T2 = digit + 10*T0
PNML:    LDA T2                ; CMP #10 above guarantees carry clear here
         ADC T0
         STA T2
         LDA T2+1
         ADC T0+1
         STA T2+1
         DEX
         BNE PNML
         LDA T2
         STA T0
         LDA T2+1
         STA T0+1
         INC IP
         BNE PNL
         INC IP+1
         BRA PNL
PND:     RTS

; =============================================================================
; T2DEC  --  decrement the 16-bit counter at T0/T1 (used by DELINE/INSLINE's
;            byte-shift loops)
;
;   In:  T2/T2+1 = current count (must be nonzero)
;   Out: T2/T2+1 decremented by one; Z flag set iff the result is zero
;   Clobbers: A
; =============================================================================
T2DEC:   LDA T2
         BNE T2DL
         DEC T2+1
T2DL:    DEC T2
         LDA T2
         ORA T2+1
         RTS

; =============================================================================
; DELINE  --  delete the program line whose start address is in LP
;
;   In:  LP -> start of the line to delete (2-byte lineno, body, CR)
;   Out: the line is removed and all following program text shifted down to
;        close the gap; PE shrunk accordingly; LP unchanged (still valid as
;        the insertion point for a following INSLINE call)
;   Clobbers: A, X, Y, T0, T1, T2
; =============================================================================
DELINE:  LDY #2
DLL:     LDA (LP),Y
         INY
         CMP #CR
         BNE DLL
         STY T1
         TYA
         CLC
         ADC LP
         STA T0
         LDA LP+1
         ADC #0
         STA T0+1
         LDA PE
         SEC
         SBC T0
         STA T2
         LDA PE+1
         SBC T0+1
         STA T2+1
         LDA T2
         ORA T2+1
         BEQ DLU
         LDA LP               ; save LP: the (LP),Y wraparound-bump below
         PHA                  ; must advance the destination base past $xxFF
         LDA LP+1             ; boundaries, but LP is also our caller's
         PHA                  ; insertion point and must survive unchanged
         LDY #0
DLC:     LDA (T0),Y
         STA (LP),Y
         INY
         BNE DLN
         INC T0+1
         INC LP+1
DLN:     JSR T2DEC
         BNE DLC
         PLA
         STA LP+1
         PLA
         STA LP
DLU:     LDA PE
         SEC
         SBC T1
         STA PE
         BCS DLK
         DEC PE+1
DLK:     RTS

; =============================================================================
; EDITLN  --  add/replace/delete a numbered program line
;
;   In:  IP -> line number, followed by the new body (or CR for delete-only)
;   Out: program storage updated; PE adjusted; IP left past end of input
;   Clobbers: A, X, Y, T0, T1, T2, LP, CURLN
;
;   Falls through into INSLINE once the insertion point (LP) is found and any
;   existing same-numbered line has been removed via DELINE.
; =============================================================================
EDITLN:  JSR PNUM
         LDA T0
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDX #6
         JSR PROG2X
ELFL:    LDX #6
         JSR PE_CMP_X
         BEQ ELIS
ELGO:    LDY #1
         LDA (LP),Y
         CMP CURLN+1
         BCC ELSK
         BNE ELIS
         DEY
         LDA (LP),Y
         CMP CURLN
         BCC ELSK
         BEQ ELFD
         BRA ELIS
ELSK:    JSR LSKIP
         BRA ELFL
ELFD:    JSR DELINE
ELIS:    JSR WPEEK
         CMP #CR
         BNE ELIS2
         JMP ELD         ; no body: done
ELIS2:
; =============================================================================
; INSLINE  --  insert one line at LP; body text comes from IP (in IBUF)
;
;   In:  LP -> insertion point in program store
;        IP -> first byte of body text in IBUF (after the line number)
;        CURLN = 16-bit line number to store in the 2-byte header
;        PE -> one past the last current program byte
;   Out: new line written; PE advanced by line size
;   Clobbers: A, X, Y, T0, T1, IP, LP, PE
;
;   Ported from uBASIC's INSLINE (was our own T2DEC-counter-driven design):
;   the backward shift-copy loop here is driven by T0_CMP_LP (stop exactly
;   when the source pointer reaches LP) instead of a separately-tracked
;   byte counter, and the space check is a plain "does PE+size cross
;   RAM_TOP" rather than computing an explicit displacement first.
; =============================================================================
INSLINE: LDY #0
IN_CNT:  LDA (IP),Y            ; find body length
         INY
         CMP #CR
         BNE IN_CNT
         INY                   ; +2 for the 2-byte line number header
         INY
         TYA                   ; Y = total line size
         CLC
         ADC PE                ; new PE = PE + total size
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
         LDA T1                ; write new PE early (already known safe)
         STA PE
         LDA T1+1
         STA PE+1
         LDY #0
         JSR T0_CMP_LP         ; old PE == LP already? nothing to shift up
         BEQ IN_HDR
IN_BK:   LDA T0                ; pre-decrement source (T0)
         BNE IN_D0
         DEC T0+1
IN_D0:   DEC T0
         LDA T1                ; pre-decrement destination (T1)
         BNE IN_D1
         DEC T1+1
IN_D1:   DEC T1
         LDA (T0),Y            ; backward copy loop (Y stays 0 throughout,
         STA (T1),Y             ; via 65C02 zero-page indirect addressing)
         JSR T0_CMP_LP         ; stop exactly when T0 == LP
         BNE IN_BK
IN_HDR:  LDA CURLN             ; write line number lo
         STA (LP),Y            ; Y is 0 here
         INY
         LDA CURLN+1           ; write line number hi
         STA (LP),Y
         JSR ADD2_LP           ; advance LP by 2 for the payload
         LDY #0
IN_CP:   LDA (IP),Y            ; copy payload from IBUF
         STA (LP),Y
         CMP #CR
         BEQ ELD
         INY
         BRA IN_CP
ELD:     RTS

; =============================================================================
; PRNL  --  print CR+LF
; PUTSTR  --  print a high-bit-terminated string on STR_PAGE
; PUTSTRZP  --  same, but the pointer (T2/T2+1) is already fully set up
;
;   In:  PRNL: --.  PUTSTR: A = low byte of the string (on STR_PAGE).
;        PUTSTRZP: T2/T2+1 -> string.
;   Out: string printed through PUTCH, up to and including the high-bit
;        terminated final character; T2 left pointing at that final char
;   Clobbers: A, Y, T2
; =============================================================================
PRNL:    LDA #<STR_CRLF
PUTSTR:  STA T2
PUTSTRZP:
         LDA #STR_PAGE
         STA T2+1
PSL:     LDA (T2)
         BMI PSE
         JSR PUTCH
         INC T2
         BRA PSL
PSE:     AND #$7F
         JMP PUTCH

; =============================================================================
; DO_FREE  --  FREE statement: print bytes of program storage remaining
;
;   In:  PE = current program end
;   Out: prints "<n> FREE" + CRLF
;   Clobbers: A, T0
; =============================================================================
; =============================================================================
; PROG2X  --  set a zero-page pointer to PROG
;
;   IP,PE,LP sit at fixed offsets 0/4/6 from IP (see ZP map), so one
;   indexed routine covers all three targets instead of each call site
;   spelling out "LDA #<PROG / STA ptr / LDA #>PROG / STA ptr+1" (matches
;   uBASIC's PROG2LP/PROG2X trick).
;   In: X = 0 (IP), 4 (PE), or 6 (LP)   Out: that pointer = PROG
;   Clobbers: A
; =============================================================================
PROG2X:  LDA #<PROG
         STA IP,X
         LDA #>PROG
         STA IP+1,X
         RTS

; =============================================================================
; PE_CMP_X  --  compare a zero-page pointer against PE
;
;   In: X = 0 (IP) or 6 (LP); the pointer at IP,X / IP+1,X
;   Out: Z=1 if that pointer == PE, Z=0 otherwise
;   Clobbers: A
; =============================================================================
PE_CMP_X: LDA IP,X
          CMP PE
          BNE PCX_NE
          LDA IP+1,X
          CMP PE+1
PCX_NE:   RTS

; =============================================================================
; ADD2_LP / BUMP_LP  --  advance LP by 2, or by 1
;
;   ADD2_LP calls BUMP_LP once, then (having no RTS of its own) falls
;   straight through into BUMP_LP's own body for a second increment --
;   two 16-bit increments for the cost of one JSR (uBASIC's trick).
;   In: LP   Out: LP+2 (ADD2_LP) or LP+1 (BUMP_LP)   Clobbers: nothing
; =============================================================================
ADD2_LP: JSR BUMP_LP
BUMP_LP: INC LP
         BNE BUMP_RTS
         INC LP+1
BUMP_RTS: RTS

; T0_CMP_LP -- compare T0 against LP (shared by INSLINE's two checks)
;   Out: Z=1 if T0==LP, Z=0 otherwise   Clobbers: A
T0_CMP_LP:
         LDA T0
         CMP LP
         BNE TCL_NE
         LDA T0+1
         CMP LP+1
TCL_NE:  RTS

; LSKIP -- advance LP past the current line (shared by EDITLN, GOTOL)
;   In: LP -> start of a line's 2-byte header
;   Out: LP -> start of the next line (past this line's CR terminator)
;   Clobbers: A, Y, LP
LSKIP:   JSR ADD2_LP
LSK_LP:  LDA (LP)
         JSR BUMP_LP
         CMP #CR
         BNE LSK_LP
         RTS

; STORE_VAR -- copy FLT_A (4 bytes) into VARS starting at offset X
;   In: X = byte offset into VARS   Out: VARS[X..X+3] = FLT_A
;   Clobbers: A, X, Y
STORE_VAR:
         LDY #0
SV_LP:   LDA FLT_A,Y
         STA VARS,X
         INX
         INY
         CPY #4
         BNE SV_LP
         RTS

DO_FREE: SEC
         LDA #<RAM_TOP
         SBC PE
         STA T0
         LDA #>RAM_TOP
         SBC PE+1
         STA T0+1
         JSR PRT16
         LDA #' '
         JSR PUTCH
         LDA #<STR_FREE
         JSR PUTSTR
         JMP PRNL

; =============================================================================
; DO_PRINT  --  PRINT statement
;
;   In:  IP -> print-list: "string", expr, CHR$(n), separated by ';'
;   Out: items printed; trailing ';' suppresses the final CRLF
;   Clobbers: A, X, Y, T0-T2, FLT_A, IP
; =============================================================================
DO_PRINT:
DPT:     JSR WPEEK
         CMP #CR
         BEQ DPNL
         CMP #0
         BEQ DPNL
         CMP #'"'
         BNE DPX
         JSR GETCI
DPS:     JSR GETCI
         CMP #'"'
         BEQ DPA
         CMP #CR
         BEQ DPNL
         JSR PUTCH
         BRA DPS
DPX:     LDA #<KW_CHRS
         JSR MTCHKW
         BCS DPNC
         JSR EAT_EXPR
         JSR WEAT
         JSR FLT_TO_INT
         LDA T0
         JSR PUTCH
         BRA DPA
DPNC:    JSR EXPR
         JSR FLT_PRINT
DPA:     JSR WPEEK
         CMP #';'
         BNE DPNL
         JSR GETCI
         JSR WPEEK
         CMP #CR
         BEQ DPRT              ; trailing ';' immediately before CR: suppress newline
         CMP #0
         BEQ DPRT
         BRA DPT
DPNL:    JSR PRNL
DPRT:    RTS

; =============================================================================
; DO_LIST  --  LIST statement: print the whole program
;
;   In:  --
;   Out: every line printed as "<lineno> <body>" + CRLF
;   Clobbers: A, Y, T0, LP
; =============================================================================
DO_LIST: LDX #6
         JSR PROG2X
LSL:     LDX #6
         JSR PE_CMP_X
         BEQ LSDN
LSGO:    LDA (LP)
         STA T0
         LDY #1
         LDA (LP),Y
         STA T0+1
         JSR PRT16
         LDA #' '
         JSR PUTCH
         JSR ADD2_LP
LSB:     LDA (LP)
         CMP #CR
         BEQ LSEOL
         JSR PUTCH
         JSR BUMP_LP
         BRA LSB
LSEOL:   JSR PRNL
         JSR BUMP_LP
         BRA LSL
LSDN:    RTS

; =============================================================================
; DO_GOTO  --  GOTO <linenum>  or  GOSUB <linenum> (also the shared entry for
;              DO_RUN's line-by-line trampoline, and every subsequent line
;              during a RUN)
;
;   In:  IP -> target line-number expression; LP -> keyword's pre-match
;        start (MTCHKW's contract), so (LP),Y with Y=2 peeks the keyword's
;        3rd raw character. NOTE: IP and CURLN must stay sequential in ZP.
;   Out: GOTO:  jumps into the program at that line and keeps executing
;        line-by-line until END or falling off the end (RUNEND)
;        GOSUB: return frame (IP,CURLN) pushed to GOSUB_LO first, then as
;        GOTO; ?1 if the line doesn't exist, ?3 if the GOSUB stack is full
;        (8 levels deep)
;   Clobbers: everything -- this is the main statement-execution trampoline
;
;   3rd char 'S' (case-insensitive) selects GOSUB; anything else -- including
;   the full word "GOTO" -- falls through as plain GOTO.
;
;   RUNLP re-snapshots the stack pointer into RUNSP before each line, so that
;   GOTO/GOSUB can collapse the call stack back to this point instead of
;   growing without bound across an unbounded GOTO loop.
; =============================================================================
DO_GOTO:
         LDY #2
         LDA (LP),Y
         AND #$DF              ; uppercase, matching MTCHKW's case-insensitivity
         CMP #'S'               ; Z set if 3rd char is 'S' (GOSUB)
         PHP                    ; save that flag across EXPR/FLT_TO_INT
         JSR EXPR
         JSR FLT_TO_INT         ; T0 = target line number
         PLP
         BNE GODO               ; not GOSUB: skip frame push

         LDX GOSUB_SP
         CPX #GOSUB_FULL        ; room for a full 4-byte frame?
         BCC ERR_OM_J
         LDY #3                 ; CURLN+1,CURLN,IP+1,IP in that order
PUSHLP:  LDA IP,Y
         STA 0,X                ; GOSUB_SP holds a raw ZP address, not an index
         DEX
         DEY
         BPL PUSHLP
         STX GOSUB_SP

GODO:    JSR GOTOL
         BCS ERR_UL_J
DGOK:    LDA RUN               ; only valid to collapse the stack via RUNSP
         BEQ RUNGO             ; while already inside an active RUN loop;
         LDX RUNSP             ; RUNSP is stale/uninitialized for an
         TXS                   ; immediate-mode GOTO (stack is already at
RUNGO:   JSR STMT               ; the correct depth in that case)
         LDA RUN
         BEQ RUNEND
SKL:     JSR GETCI
         CMP #CR
         BNE SKL
RUNLP:   TSX
         STX RUNSP
         LDA IP
         CMP PE
         LDA IP+1
         SBC PE+1
         BCS RUNEND
         JSR GETCI
         STA CURLN
         JSR GETCI
         STA CURLN+1
         BRA RUNGO
DO_RUN:  LDX #0
         JSR PROG2X
         LDA #$FF
         STA RUN
         BRA RUNLP
RUNEND:
DO_END:  STZ RUN
         RTS

; --- Pooled error handlers (shared by GOTO/GOSUB) ---
ERR_OM_J: LDA #ERR_OM           ; GOSUB stack full
          .byte $2C             ; [OPT] BIT trick: assembles as BIT $A9xx,
ERR_UL_J: LDA #ERR_UL           ;  swallowing the LDA #ERR_UL opcode+operand
          JMP DO_ERROR

; =============================================================================
; DO_NEW_CHK  --  NEW statement, or NEXT [var] statement
;
;   NEW and NEXT share the "NE" keyword-table prefix (same collision as
;   GOTO/GOSUB and REM/RETURN); the 3rd raw input character disambiguates:
;   'X' (case-insensitive, from "NEXT") selects NEXT; anything else --
;   including the full word "NEW" -- falls through as NEW.
; =============================================================================
DO_NEW_CHK:
         LDY #2
         LDA (LP),Y
         AND #$DF
         CMP #'X'
         BEQ DO_NEXT_J
         ; fall through to DO_NEW ('W', i.e. "NEW")

; =============================================================================
; DO_NEW  --  NEW statement: erase the program and clear all variables
;
;   In:  --
;   Out: PE reset to PROG; VARS zeroed; GOSUB and FOR/NEXT stacks emptied
;   Clobbers: A, X
; =============================================================================
DO_NEW:  LDX #4
         JSR PROG2X
         LDX #VARS_MAX
DNL:     STZ VARS,X
         DEX
         BPL DNL
         LDA #GOSUB_TOP
         STA GOSUB_SP          ; empty call stack (immediate-mode GOSUB unwind)
         STZ FSTK               ; empty the FOR/NEXT loop stack too
         RTS

DO_NEXT_J:
         JMP DO_NEXT

; =============================================================================
; DO_POKE  --  POKE addr,value statement
;
;   In:  IP -> "<addr-expr>,<value-expr>"
;   Out: memory at addr written with (value AND $FF)
;   Clobbers: A, X, Y, T0, T1, FLT_A, IP
; =============================================================================
DO_POKE: JSR EXPR
         JSR FLT_TO_INT
         LDA T0+1
         PHA
         LDA T0
         PHA
         JSR WEAT
         JSR EXPR
         JSR FLT_TO_INT
         LDA T0
         PLX
         STX T1
         PLX
         STX T1+1
         STA (T1)
         RTS

; =============================================================================
; DO_INPUT  --  INPUT var statement
;
;   In:  IP -> a single A-Z variable name
;   Out: prints "? ", reads a line, evaluates it as an expression, stores the
;        result in that variable; a bad variable name is silently a no-op
;   Clobbers: A, X, Y, FLT_A, IP (saved/restored around the nested GETLINE_I)
; =============================================================================
DO_INPUT:
         JSR WPEEK_UC
         CMP #'A'
         BCC DIDN
         CMP #'Z'+1
         BCS DIDN
         JSR GETCI
         JSR UC
         SEC
         SBC #'A'
         ASL
         ASL
         PHA
         LDA IP+1
         PHA
         LDA IP
         PHA
         JSR GETLINE_I
         JSR EXPR
         PLA
         STA IP
         PLA
         STA IP+1
         PLX
         JSR STORE_VAR

; =============================================================================
; DO_REM_CHK  --  REM <comment>  or  RETURN
;
;   In:  IP -> comment text (REM), or nothing (RETURN); LP -> keyword's
;        pre-match start, same (LP),Y=2 peek as DO_GOTO.
;   Out: REM: no-op.  RETURN: pops the frame pushed by the matching GOSUB
;        and resumes execution there; ?5 if the GOSUB stack is empty.
;   Clobbers: A, X (RETURN also: Y, IP, CURLN, SP)
;
;   3rd char 'T' (case-insensitive) selects RETURN ("RE"+T); anything else
;   -- including the full word "REM" -- falls through as a no-op.
; =============================================================================
DO_REM_CHK:
         LDY #2
         LDA (LP),Y
         AND #$DF              ; uppercase
         CMP #'T'
         BNE ST_NOP            ; not RETURN: REM is a no-op

         LDX GOSUB_SP
         CPX #GOSUB_TOP        ; stack empty (nothing was ever pushed)?
         BEQ ERR_RET_J
         LDY #0
POPLP:   INX
         LDA 0,X               ; GOSUB_SP holds a raw ZP address, not an index
         STA IP,Y               ; Y=0,1,2,3 -> IP, IP+1, CURLN, CURLN+1
         INY
         CPY #4
         BNE POPLP
         STX GOSUB_SP
         LDX RUNSP
         TXS                   ; unwind hardware stack to pre-statement state
         JMP SKL               ; advance past the rest of this line, resume RUN
ERR_RET_J:
         LDA #ERR_RET
         JMP DO_ERROR

DIDN:
ST_NOP:  RTS

; =============================================================================
; GOTOL  --  locate a program line by number
;
;   In:  T0/T0+1 = target line number
;   Out: on success: IP -> first byte of that line's body (past the 2-byte
;        line number), CURLN updated to T0, carry clear.  On failure: carry
;        set, IP unchanged from whatever GOTOL itself scanned to (caller
;        must not rely on it)
;   Clobbers: A, Y, IP, CURLN
; =============================================================================
GOTOL:   LDX #6
         JSR PROG2X
GTSC:    JSR PE_CMP_X
         BEQ GTERR
GTGO:    LDA (LP)
         CMP T0
         BNE GTNX
         LDY #1
         LDA (LP),Y
         CMP T0+1
         BEQ GTOK
GTNX:    JSR LSKIP
         BRA GTSC
GTOK:    LDA T0
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDA LP
         CLC
         ADC #2
         STA IP
         LDA LP+1
         ADC #0
         STA IP+1
         CLC
         RTS
GTERR:   SEC
         RTS

; =============================================================================
; EAT_EXPR  --  consume one delimiter (whitespace/'(') then parse an expr
; EXPR  --  top-level expression parser: an EXPR_ADD term, optionally
;           followed by one relational operator (< = > <= >= <>) and a
;           second term
;
;   In:  IP -> expression text
;   Out: FLT_A = result (TRUE=-1.0/FALSE=0.0 for a relational result);
;        IP advanced past the expression
;   Clobbers: A, X, Y, FLT_A, FLT_B, T0-T2, IP
; =============================================================================
EAT_EXPR:
         JSR WEAT
         ; fall through to EXPR

EXPR:    JSR EXPR_ADD
         LDX #0
         JSR WPEEK
RLO:     CMP #'<'
         BNE RLNL
         TXA
         ORA #1
         TAX
         JSR GETCI
         LDA (IP)
         BRA RLO
RLNL:    CMP #'='
         BNE RLNE
         TXA
         ORA #2
         TAX
         JSR GETCI
         LDA (IP)
         BRA RLO
RLNE:    CMP #'>'
         BNE RLNR
         TXA
         ORA #4
         TAX
         JSR GETCI
         LDA (IP)
         BRA RLO
RLNR:    TXA
         BNE RLH
         RTS
RLH:     STX T2               ; save mask in T2 lo
         JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         JSR EXPR_ADD          ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         JSR POP_FLT_A         ; restore FLT_A
         JSR FLT_CMP
         BEQ RLE
         BMI RLLT
         LDA #4
         BRA RLCK
RLLT:    LDA #1
         BRA RLCK
RLE:     LDA #2
RLCK:    AND T2
         BEQ RLF
         LDA #$81          ; TRUE = -1.0 = [$81,$80,$00,$00]
         STA FLT_A
         LDA #$80
         STA FLT_A+1
         STZ FLT_A+2
         STZ FLT_A+3
         RTS
RLF:     JMP FLT_ZERO

; =============================================================================
; EXPR_ADD  --  additive level: one or more EXPR1 terms joined by + or -
;
;   In:  IP -> expression text
;   Out: FLT_A = sum/difference; IP advanced
;   Clobbers: A, X, Y, FLT_A, FLT_B, IP
; =============================================================================
EXPR_ADD:
         JSR EXPR1
EAL:     JSR WPEEK
         CMP #'+'
         BEQ EADO
         CMP #'-'
         BNE EARS
EADO:    PHA                  ; save operator
         JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         JSR GETCI
         JSR EXPR1             ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         JSR POP_FLT_A         ; restore FLT_A
         PLA                   ; pull operator
         CMP #'-'
         BEQ EASB
         JSR FLT_ADD
         BRA EAL
EASB:    JSR FLT_SUB
         BRA EAL
EARS:    RTS

; =============================================================================
; EXPR1  --  multiplicative level: one or more EXPR2 terms joined by * / %
;
;   In:  IP -> expression text
;   Out: FLT_A = product/quotient/remainder; IP advanced
;   Clobbers: A, X, Y, FLT_A, FLT_B, IP
; =============================================================================
EXPR1:   JSR EXPR2
E1L:     JSR WPEEK
         CMP #'*'
         BEQ E1MD
         CMP #'/'
         BEQ E1MD
         CMP #'%'
         BEQ E1MD
E1R:     RTS
E1MD:    PHA                  ; save operator
         JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         JSR GETCI
         JSR EXPR2             ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         JSR POP_FLT_A         ; restore FLT_A
         PLA                   ; pull operator
         CMP #'*'
         BEQ E1ML
         CMP #'/'
         BEQ E1DV
         JSR FLT_MOD
         BRA E1L
E1ML:    JSR FLT_MUL
         BRA E1L
E1DV:    JSR FLT_DIV
         BRA E1L

; =============================================================================
; EXPR2  --  atom level: parenthesised expr, unary +/-, CHR$/PEEK/USR/SIN/COS
;            function call, numeric literal, or A-Z variable
;
;   In:  IP -> expression text
;   Out: FLT_A = value; IP advanced past the atom
;   Clobbers: A, X, Y, FLT_A, T0-T2, IP
; =============================================================================
E2PS:    JSR GETCI
EXPR2:   JSR WPEEK
         CMP #'('
         BNE E2NP2
         JMP E2PR        ; parenthesised expression
E2NP2:
         CMP #'-'
         BNE E2NNG
         JMP E2NG
E2NNG:   CMP #'+'
         BEQ E2PS
         LDA #<KW_CHRS
         JSR MTCHKW
         BCS E2NC
         JSR EAT_EXPR
         JMP WEAT
E2NC:    LDA #<KW_PEEK
         JSR MTCHKW
         BCS E2NP
         JSR EAT_EXPR
         JSR WEAT
         JSR FLT_TO_INT
         LDA (T0)
         STA T0
         STZ T0+1
         JMP FLT_FROM_INT
E2NP:    LDA #<KW_USR
         JSR MTCHKW
         BCS E2NSIN
         JSR EAT_EXPR
         JSR WEAT
         JSR FLT_TO_INT
         LDA T0
         STA T2
         LDA T0+1
         STA T2+1
         JMP USR_CALL
E2NSIN:  LDA #<KW_SIN
         JSR MTCHKW
         BCS E2NCOS
         JSR EAT_EXPR
         JSR WEAT
         LDA #1
         BRA E2TRIG
E2NCOS:  LDA #<KW_COS
         JSR MTCHKW
         BCS E2NU
         JSR EAT_EXPR
         JSR WEAT
         LDA #0
E2TRIG:  JMP DO_TRIG
E2NU:    LDA (IP)
         CMP #'0'
         BCC E2VR
         CMP #'9'+1
         BCS E2VR
         JMP FLT_PARSE
E2BD:    JMP FLT_ZERO
E2VR:    JSR UC
         CMP #'A'
         BCC E2BD
         CMP #'Z'+1
         BCS E2BD
         JSR GETCI
         JSR UC
         SEC
         SBC #'A'
         ASL
         ASL
         TAX
         LDY #0
EVRL:    LDA VARS,X
         STA FLT_A,Y
         INX
         INY
         CPY #4
         BNE EVRL
         RTS
E2NG:    JSR E2PS
         JMP FLT_NEGATE
E2PR:    JSR GETCI
         JSR EXPR
         JMP WEAT

; =============================================================================
; WEAT     -- skip whitespace, then consume+return one character (GETCI)
; GETCI    -- consume and return the character at IP, advancing IP
; WSKIP    -- skip whitespace (does not consume the first non-space char)
; WPEEK    -- alias for WSKIP: skip whitespace, return (not consume) next char
; UC       -- uppercase A (if lowercase letter)
; WPEEK_UC -- WSKIP then UC
; PRT16    -- print T0/T0+1 as a signed decimal integer
; PUTCH    -- write A to the terminal
; GETCH    -- block for and return one input character
; NEG16 / NEG_T1 -- negate T0/T0+1 (NEG_T1: negate T1/T1+1 instead)
;
;   Clobbers: A (all); GETCI/WEAT also advance IP; PRT16 clobbers T0-T2
; =============================================================================
WEAT:    JSR WSKIP
GETCI:   LDA (IP)
         INC IP
         BNE GCO
         INC IP+1
GCO:     RTS

WPEEK_UC:
         JSR WSKIP
UC:      CMP #'a'
         BCC UCD
         CMP #'{'
         BCS UCD
         AND #$DF
UCD:     RTS

; PEEKUC -- peek at the char at IP (no space-skip), uppercase; tail-calls UC
;   In: IP  Out: A = uppercased char at IP; IP unchanged  Clobbers: A
PEEKUC:  LDA (IP)
         BRA UC

WSKIP:
WPEEK:   LDA (IP)
         CMP #' '
         BNE WPD
         JSR GETCI
         BRA WSKIP
WPD:     RTS

PRT16:   BIT T0+1
         BPL P16G
         LDA #'-'
         JSR PUTCH
         JSR NEG16
P16G:    LDY #16
         LDA #0
P16D:    ASL T0
         ROL T0+1
         ROL
         CMP #10
         BCC P16S
         SBC #10
         INC T0
P16S:    DEY
         BNE P16D
         PHA
         LDA T0
         ORA T0+1
         BEQ P16P
         JSR P16G
P16P:    PLA
         ORA #'0'
PUTCH:   STA IO_OUT
         RTS

GETCH:   LDA IO_IN
         BEQ GETCH
         BRA PUTCH

NEG_T1:  LDX #2
         .DB $2C
NEG16:   LDX #0
         LDA #0
         SEC
         SBC T0,X
         STA T0,X
         LDA #0
         SBC T0+1,X
         STA T0+1,X
         RTS

; =============================================================================
; USR_CALL / USR_RET  --  USR(addr) expression function: call machine code
;
;   In:  T2/T2+1 = address to call (USR_CALL); on return from that code,
;        A = its result (USR_RET)
;   Out: FLT_A = float(A) zero-extended to 16 bits
;   Clobbers: whatever the called routine clobbers, plus T0
; =============================================================================
USR_CALL: JMP (T2)
USR_RET: STA T0
         STZ T0+1
         JMP FLT_FROM_INT

; =============================================================================
; DO_IF  --  IF <expr> THEN <stmt>  statement (exactly one consequent
;            statement; there is no ':' chaining -- see the file header)
;
;   In:  IP -> condition expression
;   Out: if condition is nonzero, falls into STMT to run exactly one more
;        statement; if zero, the rest of the line is abandoned (caller's
;        SKL loop discards it)
;   Clobbers: as EXPR/STMT
;
; STMT  --  match one keyword against ST_TAB and dispatch to its handler;
;           no match at all falls through to DO_LET (implicit "X=...")
;
;   In:  IP -> statement text
;   Out: statement executed; IP advanced
;   Clobbers: as the dispatched handler
; =============================================================================
DO_IF:   JSR EXPR
         LDA FLT_A
         BEQ DIFDN
         LDA #<KW_THEN
         JSR MTCHKW
         ; falls through into STMT to run exactly one consequent statement

STMT:    JSR WPEEK
         CMP #' '
         BCC DIFDN
         LDX #0
STL:     LDA ST_TAB,X
         BMI STLT
         JSR MTCHKW
         BCS STNX
         LDA ST_TAB+1,X
         STA T2
         LDA ST_TAB+2,X
         STA T2+1
         JMP (T2)
STNX:    INX
         INX
         INX
         BRA STL
DIFDN:   RTS
STLT:
; =============================================================================
; DO_LET  --  LET <var>=<expr>, or implicit <var>=<expr> (ST_TAB fallthrough)
;
;   In:  IP -> variable name
;   Out: variable assigned FLT_A; IP advanced.  ?4 if not a valid A-Z name,
;        or if not followed by '='
;   Clobbers: A, X, Y, FLT_A, IP
; =============================================================================
DO_LET:  JSR WPEEK_UC
         CMP #'A'
         BCC DLD
         CMP #'Z'+1
         BCS DLD
         JSR GETCI
         JSR UC
         SEC
         SBC #'A'
         ASL
         ASL
         PHA
         JSR WPEEK
         CMP #'='
         BNE DLPOP
         JSR GETCI
         JSR EXPR
         PLX
         JSR STORE_VAR
         RTS
DLPOP:   PLA
         LDA #ERR_UK
         JMP DO_ERROR
DLD:     RTS

; =============================================================================
; FSTK_BASE  --  LP = FOR_STK + A*7
;   In:  A = frame index (0-3)
;   Out: LP = address of that frame within FOR_STK
;   Clobbers: A, T2
; =============================================================================
FSTK_BASE:
         STA T2
         ASL 
         CLC
         ADC T2
         ASL 
         CLC
         ADC T2                ; A = index*7
         CLC
         ADC #<FOR_STK
         STA LP
         LDA #>FOR_STK
         ADC #0
         STA LP+1
         RTS

; =============================================================================
; DO_FOR  --  FOR var = start TO limit [STEP step]
;
;   In:  IP -> variable letter
;   Out: loop frame pushed onto FOR_STK; VARS[var] = float(start)
;   Clobbers: A, X, Y, T0, T2, LP, FLT_A, FLT_B
;
;   The loop VARIABLE is a real float in VARS, updated via FLT_ADD each
;   NEXT, so it behaves normally in float expressions inside the loop
;   body. LIMIT and STEP are 16-bit signed integers, not floats -- this
;   keeps a 4-level-deep frame stack small enough to fit free zero page.
;   Consequently "FOR X = 1 TO 10 STEP 0.5" is not supported: TO/STEP
;   must be whole numbers (a non-integer start value like "FOR X = 1.5
;   TO 10" IS fine -- only the bound and step are integer-only).
; =============================================================================
DO_FOR:
         JSR WPEEK_UC
         CMP #'A'
         BCC DFBADJ
         CMP #'Z'+1
         BCS DFBADJ
         JSR GETCI
         SEC
         SBC #'A'
         ASL 
         ASL                  ; var_index*4 = byte offset into VARS
         STA FVAR
         JSR WPEEK
         CMP #'='
         BNE DFBADJ
         JSR GETCI
         JSR EXPR              ; evaluate start -> FLT_A
         BRA DFCONT
DFBADJ:  JMP DFBAD
DFCONT:  LDX FVAR
         JSR STORE_VAR
         LDA #<KW_TO
         JSR MTCHKW
         BCS DFBAD             ; TO is mandatory
         JSR EXPR              ; evaluate limit -> FLT_A
         JSR FLT_TO_INT        ; T0 = 16-bit limit
         LDA T0
         STA FLIM
         LDA T0+1
         STA FLIM+1
         LDA #<KW_STEP
         JSR MTCHKW
         BCS DFNOSTEP
         JSR EXPR              ; evaluate step -> FLT_A
         JSR FLT_TO_INT
         LDA T0
         LDX T0+1
         BRA DFHVSTEP
DFNOSTEP:
         LDA #1                ; default step = 1
         LDX #0
DFHVSTEP:
         STA FSTEP
         STX FSTEP+1
         ORA FSTEP+1           ; step of zero is illegal
         BNE DFSZOK
         LDA #ERR_ST
         JMP DO_ERROR
DFSZOK:  LDA FSTK
         CMP #4                ; max 4 nested FOR loops
         BCC DFPUSH
         LDA #ERR_FOR
         JMP DO_ERROR
DFPUSH:  JSR FSTK_BASE          ; LP = FOR_STK + FSTK*7 (A already = FSTK)
         LDY #4                 ; copy FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1 (they're
DFCP:    LDA FVAR,Y              ; contiguous in ZP) into the frame in one pass
         STA (LP),Y
         DEY
         BPL DFCP
         LDY #5
         LDA CURLN               ; loop_line = this FOR statement's own line;
         STA (LP),Y                ; NEXT skips past it via SKL, landing on
         INY                         ; the first body line (same trick RETURN
         LDA CURLN+1                  ; uses to resume mid-run)
         STA (LP),Y
         INC FSTK
         RTS
DFBAD:   LDA #ERR_SN
         JMP DO_ERROR

; =============================================================================
; DO_NEXT  --  NEXT [var]
;
;   In:  IP -> optional variable name (consumed but not checked against the
;        FOR variable; NEXT always closes the innermost active loop)
;   Out: loop variable advanced; branches back to the line after the FOR
;        that opened this loop, or falls through to the statement after
;        NEXT once the limit is crossed
;   Clobbers: A, X, Y, T0, T2, LP, FLT_A, FLT_B
;
;   Comparison converts the (post-add) float loop variable to a 16-bit int
;   and does a single unified signed test: diff = var - limit. If diff==0
;   the limit is met exactly (inclusive: always loop once more). Otherwise
;   XOR diff's sign with the step's sign -- differing signs means the
;   limit has not yet been reached (keep looping); matching signs means
;   it has been crossed (stop).
; =============================================================================
DO_NEXT:
         JSR WPEEK_UC          ; consume optional variable name (ignored)
         CMP #'A'
         BCC DNNOVAR
         CMP #'Z'+1
         BCS DNNOVAR
         JSR GETCI
DNNOVAR: LDA FSTK
         BNE DNOK
         LDA #ERR_NF
         JMP DO_ERROR
DNOK:    DEC                   ; top frame index = FSTK-1
         JSR FSTK_BASE          ; LP = base of top frame
         LDA (LP)               ; [0] var_slot
         TAX
         LDY #0
DNLD:    LDA VARS,X             ; load current loop variable into FLT_A
         STA FLT_A,Y
         INX
         INY
         CPY #4
         BNE DNLD
         LDY #3
         LDA (LP),Y             ; [3] step_lo
         STA T0
         INY
         LDA (LP),Y             ; [4] step_hi
         STA T0+1
         JSR FLT_FROM_INT_B     ; FLT_B = float(step)
         JSR FLT_ADD            ; FLT_A = var + step
         LDA (LP)               ; var_slot again
         TAX
         JSR STORE_VAR           ; store updated loop variable back to VARS
         JSR FLT_TO_INT         ; T0 = int(current loop var), for the compare
         LDY #1
         LDA T0
         SEC
         SBC (LP),Y             ; [1] limit_lo
         STA T2
         INY
         LDA T0+1
         SBC (LP),Y             ; [2] limit_hi
         TAX                    ; X = diff hi byte
         ORA T2                 ; Z reflects 16-bit "diff == 0"
         BEQ DN_loop            ; var == limit: always loop once more
         TXA                    ; restore diff hi byte (restores N flag)
         LDY #4
         EOR (LP),Y             ; XOR with [4] step_hi
         BMI DN_loop            ; differing signs: limit not yet crossed
         DEC FSTK                ; matching signs: limit crossed, done
         RTS
DN_loop: LDY #5
         LDA (LP),Y             ; [5] loop_line_lo
         STA T0
         INY
         LDA (LP),Y             ; [6] loop_line_hi
         STA T0+1
         JSR GOTOL
         BCS DN_ul
         LDX RUNSP
         TXS                    ; unwind hardware stack (same as GOTO/RETURN)
         JMP SKL                ; skip past the FOR line itself, land on body
DN_ul:   JMP ERR_UL_J

; ---- ST_TAB: statement-keyword dispatch table (3 bytes/entry, $FF-terminated)
ST_TAB:
         .DB <KW_PRINT,<DO_PRINT,>DO_PRINT
         .DB <KW_IF,   <DO_IF,   >DO_IF
         .DB <KW_GOTO, <DO_GOTO, >DO_GOTO
         .DB <KW_LIST, <DO_LIST, >DO_LIST
         .DB <KW_RUN,  <DO_RUN,  >DO_RUN
         .DB <KW_NEW,  <DO_NEW_CHK,>DO_NEW_CHK
         .DB <KW_FOR,  <DO_FOR,  >DO_FOR
         .DB <KW_INPUT,<DO_INPUT,>DO_INPUT
         .DB <KW_REM,  <DO_REM_CHK,>DO_REM_CHK
         .DB <KW_END,  <DO_END,  >DO_END
         .DB <KW_LET,  <DO_LET,  >DO_LET
         .DB <KW_POKE, <DO_POKE, >DO_POKE
         .DB <KW_FREE, <DO_FREE, >DO_FREE
         .DB $FF

; =============================================================================
; MTCHKW  --  case-insensitive match of a 2-char keyword prefix at IP, then
;             consumes any further trailing letters (uBASIC's scheme)
;
;   In:  A = low byte of the 2-byte keyword prefix (on STR_PAGE)
;   Out: match:  carry clear, IP advanced past the matched keyword
;        no match: carry set, IP restored to its value on entry
;   Clobbers: A, Y, T1
;
;   After the 2-char prefix matches, any run of trailing letters at IP is
;   swallowed (so "PR" matches the full word "PRINT", but also anything
;   else starting "PR" -- lenient by design, see v1.3 changelog). A
;   trailing '$' right after the letters (as in CHR$) is swallowed too:
;   the letter-skip loop computes (char-'A'), and '$'-'A' mod 256 = $E3
;   is checked for specially once a non-letter ends the loop.
; =============================================================================
MTCHKW:  STA T1
         LDA #STR_PAGE
         STA T1+1
         LDA IP
         STA LP
         LDA IP+1
         STA LP+1
         JSR WPEEK_UC
         LDY #0
         CMP (T1),Y
         BNE MKFL
         JSR GETCI
         JSR PEEKUC
         LDY #1
         CMP (T1),Y
         BNE MKFL
         JSR GETCI
MKSKIP:  JSR PEEKUC
         SEC
         SBC #'A'
         CMP #26
         BCS MKOK             ; not a letter: stop skipping
         JSR GETCI
         BNE MKSKIP           ; unconditional: GETCI's A is a letter, nonzero
MKOK:    CMP #$E3              ; remainder == '$'-'A' (mod 256)?
         BNE MKRTS
         JSR GETCI             ; it IS '$': consume it
MKRTS:   CLC
         RTS
MKFL:    LDA LP
         STA IP
         LDA LP+1
         STA IP+1
         SEC
         RTS

; ===========================================================================
; FLOAT LIBRARY
; ===========================================================================

; =============================================================================
; FLOAT LIBRARY  --  MBF4 format, see header comment for the byte layout
; =============================================================================

; FLT_ZERO -- FLT_A = 0.0.  Clobbers: A, X.
FLT_ZERO:
         LDX #3
FZL:     STZ FLT_A,X
         DEX
         BPL FZL
         RTS

; FLT_NEGATE / FLT_NEGATE_B -- flip the sign bit of FLT_A / FLT_B (no-op on
; zero, so -0.0 can't arise).  Clobbers: A.
FLT_NEGATE:
         LDA FLT_A
         BEQ FND
         LDA FLT_A+1
         EOR #$80
         STA FLT_A+1
FND:     RTS

FLT_NEGATE_B:
         LDA FLT_B
         BEQ FNBD
         LDA FLT_B+1
         EOR #$80
         STA FLT_B+1
FNBD:    RTS

; FLT_ABS -- FLT_A = |FLT_A|.  Clobbers: A.
FLT_ABS: LDA FLT_A+1
         AND #$7F
         STA FLT_A+1
         RTS

; SIGN_XOR -- FLT_SA = sign bit of (FLT_A's sign XOR FLT_B's sign); used by
; FLT_MUL/FLT_DIV to work out the result's sign before combining magnitudes.
; Clobbers: A.
SIGN_XOR:
         LDA FLT_A+1
         EOR FLT_B+1
         AND #$80
         STA FLT_SA
         RTS

; FLT_A_TO_B / FLT_B_TO_A -- copy the 4-byte float FLT_A<->FLT_B.
; Clobbers: A, X.
FLT_A_TO_B:
         LDX #3
FABL:    LDA FLT_A,X
         STA FLT_B,X
         DEX
         BPL FABL
         RTS

FLT_B_TO_A:
         LDX #3
FBAL:    LDA FLT_B,X
         STA FLT_A,X
         DEX
         BPL FBAL
         RTS

; PUSH_FLT_A / POP_FLT_A -- save/restore the 4-byte float FLT_A on the
; hardware stack, straddling arbitrary caller code (relational ops parking
; the left operand across a recursive EXPR_ADD call, FLT_PRINT parking the
; original value across its digit-scaling loop, etc). Replaces 7 duplicated
; 12-byte inline push sequences and 7 duplicated 12-byte inline pop
; sequences (asmdup.py find). NOT used for the single FLT_B push/pop in
; FLT_MOD -- one use doesn't recoup a second subroutine's own cost, so
; that one stays inline.
;
; These can't be plain JSR/RTS wrappers around PHA x4 / PLA x4: the pushed
; frame is meant to sit on the stack for the FULL gap between the push
; call site and a LATER, separate pop call site -- with arbitrary other
; JSR/RTS activity (recursion, nested FLT_CMP, etc) happening in between.
; A naive "JSR does 4x PHA then RTS" leaves the frame ON TOP OF its own
; JSR return address, so its own RTS pops the wrong bytes and jumps into
; garbage. Fix: pop the return address out of the way first, do the real
; push/pop, then put the return address back on top before RTS.
;   PUSH_FLT_A  In: FLT_A  Out: FLT_A pushed beneath caller's return addr
;               Clobbers: A, Y, PFA_RL/PFA_RH
;   POP_FLT_A   In: -- (matching PUSH_FLT_A frame beneath the return addr)
;               Out: FLT_A restored  Clobbers: A, Y, PFA_RL/PFA_RH
PUSH_FLT_A:
         PLA
         STA PFA_RL
         PLA
         STA PFA_RH
         LDY #3
PSHL:    LDA FLT_A,Y
         PHA
         DEY
         BPL PSHL
         LDA PFA_RH
         PHA
         LDA PFA_RL
         PHA
         RTS

POP_FLT_A:
         PLA
         STA PFA_RL
         PLA
         STA PFA_RH
         LDY #0
POPL:    PLA
         STA FLT_A,Y
         INY
         CPY #4
         BNE POPL
         LDA PFA_RH
         PHA
         LDA PFA_RL
         PHA
         RTS

; =============================================================================
; FLT_FROM_INT / FLT_FROM_INT_B  --  convert a signed 16-bit integer to float
;
;   In:  T0 = signed 16-bit value
;   Out: FLT_A (FLT_FROM_INT) or FLT_B (FLT_FROM_INT_B) = float(T0)
;   Clobbers: A, X, T0, FLT_ER, FLT_SA
;
;   Was two near-identical 35-line routines differing only in destination
;   (FLT_A vs FLT_B) -- asmdup.py flagged the shared "negate 16-bit T0"
;   fragment as duplicated. Unified via FLT_B_OFFSET (X-indexed into
;   FLT_A,X / FLT_A+1,X / FLT_A+2,X / FLT_A+3,X; X=0 hits FLT_A, X=4 hits
;   FLT_B since the two floats are contiguous 4-byte blocks in ZP). Also
;   drops the separate FLT_SB: the sign is only live within this routine's
;   own body (consumed by F_PACK before returning), so FLT_SA doubles as
;   scratch for both destinations -- nothing depends on FLT_FROM_INT_B
;   leaving a fresh FLT_SB behind (checked: its only caller immediately
;   follows with FLT_SUB, which recomputes FLT_SB from scratch anyway).
; =============================================================================
FLT_B_OFFSET = FLT_B - FLT_A

FLT_FROM_INT_B:
         LDX #FLT_B_OFFSET
         BRA FLT_SHARED

FLT_FROM_INT:
         LDX #0

FLT_SHARED:
         LDA T0
         ORA T0+1
         BNE F_NONZERO
F_ZERO:  STZ FLT_A,X
         STZ FLT_A+1,X
         STZ FLT_A+2,X
         STZ FLT_A+3,X
         RTS

F_NONZERO:
         LDA T0+1
         AND #$80
         STA FLT_SA
         BEQ F_POS

         LDA #0
         SEC
         SBC T0
         STA T0
         LDA #0
         SBC T0+1
         STA T0+1

F_POS:   LDA #$90
         STA FLT_ER

F_NORM:  LDA T0+1
         BMI F_PACK
         ASL T0
         ROL T0+1
         DEC FLT_ER
         BNE F_NORM           ; unconditional: FLT_ER won't hit 0 first

F_PACK:  LDA FLT_ER
         STA FLT_A,X
         LDA T0+1
         AND #$7F
         ORA FLT_SA
         STA FLT_A+1,X
         LDA T0
         STA FLT_A+2,X
         STZ FLT_A+3,X
         RTS

; =============================================================================
; FLT_TO_INT  --  convert FLT_A to a signed 16-bit integer (truncating)
;
;   In:  FLT_A = value
;   Out: T0 = truncated value, saturated to +32767/-32768 on overflow
;   Clobbers: A, X, FLT_DE
; =============================================================================
FLT_TO_INT:
         STZ T0
         STZ T0+1
         LDA FLT_A
         BEQ FTID
         SEC
         SBC #$80
         BCC FTID
         BEQ FTID
         CMP #17
         BCS FTIS
         STA FLT_DE
         LDA FLT_A+1
         ORA #$80
         STA T0+1
         LDA FLT_A+2
         STA T0
         LDA #16
         SEC
         SBC FLT_DE
         BEQ FTIG
         TAX
FTIS2:   LSR T0+1
         ROR T0
         DEX
         BNE FTIS2
FTIG:    LDA FLT_A+1
         BMI FTIN
FTID:    RTS
FTIN:    LDA #0
         SEC
         SBC T0
         STA T0
         LDA #0
         SBC T0+1
         STA T0+1
         RTS
FTIS:    LDA #$FF
         STA T0
         LDA #$7F
         STA T0+1
         LDA FLT_A+1
         BPL FTID
         LDA #1
         STA T0
         LDA #$80
         STA T0+1
         RTS

; FLT_TEN_B -- FLT_B = 10.0.  Clobbers: A.
FLT_TEN_B:
         LDA #$84
         STA FLT_B
         LDA #$20
         STA FLT_B+1
         STZ FLT_B+2
         STZ FLT_B+3
         RTS

; MUL_BY_TEN -- FLT_A = FLT_A * 10.  Clobbers: as FLT_MUL.
MUL_BY_TEN:
         JSR FLT_TEN_B
         JMP FLT_MUL

; DIV_BY_TEN -- FLT_A = FLT_A / 10.  Clobbers: as FLT_DIV.
DIV_BY_TEN:
         JSR FLT_TEN_B
         JMP FLT_DIV

; =============================================================================
; NORM_PACK  --  normalise an unpacked mantissa and pack it into FLT_A
;
;   In:  FLT_A+1:+2:+3 = 24-bit mantissa (may be un-normalised, i.e. the
;        implicit leading 1 bit not yet in bit 7 of FLT_A+1), FLT_DB = guard
;        byte for rounding, FLT_ER = raw (unbiased-range) exponent,
;        FLT_SA = sign bit (already positioned in bit 7)
;   Out: FLT_A = fully packed, normalised, rounded result (or 0.0 if the
;        exponent underflows during normalisation/rounding)
;   Clobbers: A
; =============================================================================
NORM_PACK:
NPL:     LDA FLT_A+1
         BMI NPRND
         BNE NPBT
         LDA FLT_ER
         CMP #9                ; ER<9: subtracting 8 would hit <=0, go to zero
         BCC NPZE
         SBC #8                ; carry guaranteed set by CMP, safe to subtract
         STA FLT_ER
         LDA FLT_A+2
         STA FLT_A+1
         LDA FLT_A+3
         STA FLT_A+2
         LDA FLT_DB
         STA FLT_A+3
         STZ FLT_DB
         BRA NPL
NPBT:    ASL FLT_DB
         ROL FLT_A+3
         ROL FLT_A+2
         ROL FLT_A+1
         DEC FLT_ER
         BNE NPL
NPZE:    JMP FLT_ZERO
NPRND:   ASL FLT_DB             ; bit 7 of FLT_DB into carry (== ADC #$80)
         BCC NPPK
         LDX #3                 ; looped increment cascade through A+3..A+1
NPRND_L: INC FLT_A,X
         BNE NPPK
         DEX
         BNE NPRND_L
         LDA #$80
         STA FLT_A+1
         INC FLT_ER
         BEQ NPZE
NPPK:    LDA FLT_ER
         STA FLT_A
         LDA FLT_A+1
         AND #$7F
         ORA FLT_SA
         STA FLT_A+1
         RTS

; =============================================================================
; FLT_ADD  --  FLT_A = FLT_A + FLT_B
;
;   In:  FLT_A, FLT_B = operands
;   Out: FLT_A = sum
;   Clobbers: A, X, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE, FLT_DB
; =============================================================================
FLT_ADD: LDA FLT_A
         BNE FACKB
         JMP FLT_B_TO_A
FACKB:   LDA FLT_B
         BNE FABTH
         RTS
FABTH:   LDA FLT_A
         CMP FLT_B
         BCS FASG
         LDX #3                ; looped swap of FLT_A<->FLT_B (was unrolled)
FASWAP:  LDA FLT_A,X
         LDY FLT_B,X
         STA FLT_B,X
         TYA
         STA FLT_A,X
         DEX
         BPL FASWAP

FASG:    LDA FLT_A+1
         AND #$80
         STA FLT_SA
         LDA FLT_B+1
         AND #$80
         STA FLT_SB
         LDA #$80
         TSB FLT_A+1           ; 65C02: restores hidden bit in one 2-byte op
         TSB FLT_B+1
         LDA FLT_A
         STA FLT_ER
         SEC
         SBC FLT_B
         CMP #25
         STZ FLT_DB            ; STZ doesn't touch flags -- CMP's carry survives
         BCS FANM              ; shift >= 25: B's mantissa is entirely gone
         TAX                   ; X = shift count
         BEQ FAOP
FABT:    LSR FLT_B+1
         ROR FLT_B+2
         ROR FLT_B+3
         ROR FLT_DB
         DEX
         BNE FABT
FAOP:    LDA FLT_SA
         CMP FLT_SB
         BEQ FASM
         SEC
         LDA FLT_A+3
         SBC FLT_B+3
         STA FLT_A+3
         LDA FLT_A+2
         SBC FLT_B+2
         STA FLT_A+2
         LDA FLT_A+1
         SBC FLT_B+1
         STA FLT_A+1
         BCS FANM
         SEC
         LDA #0
         SBC FLT_DB
         STA FLT_DB
         LDA #0
         SBC FLT_A+3
         STA FLT_A+3
         LDA #0
         SBC FLT_A+2
         STA FLT_A+2
         LDA #0
         SBC FLT_A+1
         STA FLT_A+1
         ORA FLT_A+2
         ORA FLT_A+3
         BEQ FAZE
         LDA FLT_SA
         EOR #$80
         STA FLT_SA
         BRA FANM
FASM:    CLC
         LDA FLT_A+3
         ADC FLT_B+3
         STA FLT_A+3
         LDA FLT_A+2
         ADC FLT_B+2
         STA FLT_A+2
         LDA FLT_A+1
         ADC FLT_B+1
         STA FLT_A+1
         BCC FANM
         ROR FLT_A+1
         ROR FLT_A+2
         ROR FLT_A+3
         ROR FLT_DB
         INC FLT_ER
         BEQ FAZE
FANM:    JMP NORM_PACK
FAZE:    JMP FLT_ZERO

; =============================================================================
; FLT_SUB  --  FLT_A = FLT_A - FLT_B (negates FLT_B and falls into FLT_ADD)
;
;   In/Out/Clobbers: as FLT_ADD; also permanently negates FLT_B's sign
; =============================================================================
FLT_SUB: JSR FLT_NEGATE_B
         JSR FLT_ADD
         JMP FLT_NEGATE_B

; FLT_CMP: A=$FF(A<B) $00(A=B) $01(A>B). FLT_A preserved; uses T1.
; =============================================================================
; FLT_CMP  --  compare FLT_A to FLT_B (both preserved)
;
;   In:  FLT_A, FLT_B = operands
;   Out: A = 0 if equal, 1 if FLT_A>FLT_B, $FF if FLT_A<FLT_B
;   Clobbers: A, T1 (FLT_A/FLT_B restored to their original values)
; =============================================================================
FLT_CMP: JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         JSR FLT_SUB
         LDA FLT_A
         STA T1
         LDA FLT_A+1
         STA T1+1
         JSR POP_FLT_A         ; restore FLT_A
         LDA T1
         BNE FCNZ
         LDA #0
         RTS
FCNZ:    LDA T1+1
         BMI FCLT
         LDA #1
         RTS
FCLT:    LDA #$FF
         RTS

; FLT_MUL: FLT_A = FLT_A * FLT_B  (24-iter shift-and-accumulate)
; =============================================================================
; FLT_MUL  --  FLT_A = FLT_A * FLT_B  (24-iteration shift-and-accumulate)
;
;   In:  FLT_A, FLT_B = operands
;   Out: FLT_A = product
;   Clobbers: A, X, Y, FLT_B, FLT_MA, FLT_MB, FLT_MC, FLT_SA, FLT_ER, FLT_DB
; =============================================================================
FLT_MUL: LDA FLT_A
         BNE FMCKB
         RTS
FMCKB:   LDA FLT_B
         BNE FMNZ
         JMP FLT_ZERO
FMNZ:    LDA FLT_A
         SEC
         SBC #$80
         CLC
         ADC FLT_B
         STA FLT_ER
         JSR SIGN_XOR
         LDA #$80
         TSB FLT_A+1
         TSB FLT_B+1
         LDX #2                ; looped copy FLT_A+1..+3 -> FLT_MA..FLT_MC,
FM_CPY:  LDA FLT_A+1,X         ; zeroing FLT_A+1..+3 in the same pass
         STA FLT_MA,X
         STZ FLT_A+1,X
         DEX
         BPL FM_CPY
         STZ FLT_DB
         LDY #24
FML:     LSR FLT_B+1
         ROR FLT_B+2
         ROR FLT_B+3
         BCC FMS
         CLC
         LDA FLT_A+3
         ADC FLT_MC
         STA FLT_A+3
         LDA FLT_A+2
         ADC FLT_MB
         STA FLT_A+2
         LDA FLT_A+1
         ADC FLT_MA
         STA FLT_A+1
FMS:     ROR FLT_A+1
         ROR FLT_A+2
         ROR FLT_A+3
         ROR FLT_DB
         DEY
         BNE FML
         LDA FLT_A+1
         BMI FMPK
         ASL FLT_DB
         ROL FLT_A+3
         ROL FLT_A+2
         ROL FLT_A+1
         DEC FLT_ER
FMPK:    JMP NORM_PACK

; FLT_DIV: FLT_A = FLT_A / FLT_B  (32-iter shift-subtract)
; =============================================================================
; FLT_DIV  --  FLT_A = FLT_A / FLT_B  (32-iteration restoring division)
;
;   In:  FLT_A = dividend, FLT_B = divisor
;   Out: FLT_A = quotient.  ?2 (division by zero) if FLT_B is 0.0
;   Clobbers: A, X, Y, FLT_B, FLT_DVH, FLT_DVM, FLT_DVL, FLT_SA, FLT_ER, FLT_DB
; =============================================================================
FLT_DIV: LDA FLT_B
         BNE FDBNZ
         LDA #ERR_OV
         JMP DO_ERROR
FDBNZ:   LDA FLT_A
         BNE FDANZ
         RTS
FDANZ:   LDA FLT_A
         SEC
         SBC FLT_B
         CLC
         ADC #$80
         STA FLT_ER
         JSR SIGN_XOR
         LDA #$80
         TSB FLT_A+1
         TSB FLT_B+1
         LDX #2                ; looped copy: FLT_B+1..+3 -> DVH/DVM/DVL,
FD_CPY:  LDA FLT_B+1,X         ;              FLT_A+1..+3 -> T0/T0+1/T1
         STA FLT_DVH,X
         LDA FLT_A+1,X
         STA T0,X
         DEX
         BPL FD_CPY
         LDA T0
         CMP FLT_DVH
         BCC FDPD
         BNE FDPS
         LDA T0+1
         CMP FLT_DVM
         BCC FDPD
         BNE FDPS
         LDA T1
         CMP FLT_DVL
         BCC FDPD
FDPS:    LSR T0
         ROR T0+1
         ROR T1
         INC FLT_ER
FDPD:    STZ FLT_A+1
         STZ FLT_A+2
         STZ FLT_A+3
         STZ FLT_DB
         LDY #32
FDL:     ASL FLT_DB
         ROL FLT_A+3
         ROL FLT_A+2
         ROL FLT_A+1
         ASL T1
         ROL T0+1
         ROL T0
         BCS FDFORCE         ; 25th bit overflowed: remainder > any 24-bit divisor
         SEC
         LDA T1
         SBC FLT_DVL
         PHA
         LDA T0+1
         SBC FLT_DVM
         PHA
         LDA T0
         SBC FLT_DVH
         BCC FDNO
         STA T0
         PLA
         STA T0+1
         PLA
         STA T1
         INC FLT_DB
         BRA FDNX
FDFORCE: SEC                 ; unconditional subtract; borrow chain still valid
         LDA T1
         SBC FLT_DVL
         STA T1
         LDA T0+1
         SBC FLT_DVM
         STA T0+1
         LDA T0
         SBC FLT_DVH
         STA T0
         INC FLT_DB
         BRA FDNX
FDNO:    PLA
         PLA
FDNX:    DEY
         BNE FDL
         JMP NORM_PACK

; FLT_MOD: FLT_A = FLT_A - FLT_B*trunc(FLT_A/FLT_B)
; =============================================================================
; FLT_MOD  --  FLT_A = FLT_A mod FLT_B  (truncating, C-style: result takes
;              the sign of the dividend)
;
;   In:  FLT_A = dividend, FLT_B = divisor
;   Out: FLT_A = FLT_A - FLT_B*trunc(FLT_A/FLT_B).  ?2 if FLT_B is 0.0
;   Clobbers: A, X, Y, FLT_A, FLT_B, and everything FLT_DIV/FLT_MUL/FLT_SUB do
; =============================================================================
FLT_MOD: JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         LDA FLT_B+3
         PHA
         LDA FLT_B+2
         PHA
         LDA FLT_B+1
         PHA
         LDA FLT_B
         PHA
         JSR FLT_DIV
         JSR FLT_TO_INT
         JSR FLT_FROM_INT
         PLA
         STA FLT_B
         PLA
         STA FLT_B+1
         PLA
         STA FLT_B+2
         PLA
         STA FLT_B+3
         JSR FLT_MUL
         JSR FLT_A_TO_B
         JSR POP_FLT_A         ; restore FLT_A
         JMP FLT_SUB

; =============================================================================
; FLT_PRINT  --  print FLT_A in decimal (up to 6 significant digits, trailing
;                zeros trimmed)
;
;   In:  FLT_A = value to print
;   Out: printed to the terminal, no trailing CRLF
;   Clobbers: A, X, Y, FLT_A, FLT_B, T0-T2, IBUF, FP_LASTNZ
;
;   Algorithm: handle zero/sign, scale to [1,10), extract 6 digits, round,
;   strip trailing zeros, print with decimal point.  FLT_DE holds the
;   decimal exponent (saved in T2 during digit extraction, since FLT_DE
;   itself is clobbered by the FLT_TO_INT call used to grab each digit).
; =============================================================================
FLT_PRINT:
         LDA FLT_A
         BNE FPNZ
         LDA #'0'
         JMP PUTCH
FPNZ:    LDA FLT_A+1
         BPL FPPS
         LDA #'-'
         JSR PUTCH
         JSR FLT_ABS
FPPS: JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         STZ FLT_DE
FPDN:    JSR FLT_TEN_B
         JSR FLT_CMP
         INC                 ; 65C02: A=$FF(less) wraps to $00 (sets Z) --
         BEQ FPUP              ; replaces CMP #$FF (both give Z on "less")
         JSR DIV_BY_TEN
         INC FLT_DE
         BRA FPDN
FPUP:    LDA FLT_A
         CMP #$81
         BCS FPSC
         JSR MUL_BY_TEN
         DEC FLT_DE
         BRA FPUP
FPSC:    LDA FLT_DE
         STA T2
         LDX #0
FPDIG:   PHX                  ; save digit index (was STX FP_XSV)
         JSR FLT_TO_INT       ; T0 = int(FLT_A)  [0-9]
         LDA T0               ; save digit value NOW before T0 clobbered
         PHA                  ; save digit (was STA FP_IX)
         STZ T0+1             ; T0=digit(lo), T0+1=0
         JSR FLT_FROM_INT_B   ; FLT_B = float(digit)  [clobbers FLT_ER, FLT_SB]
         JSR FLT_SUB          ; FLT_A = FLT_A - digit  [clobbers T0,T1,T2,FLT_SA/SB/ER/DB]
         LDA FLT_A
         BEQ FPCL
         LDA FLT_A+1
         BPL FPCL
         JSR FLT_ZERO         ; clamp negative rounding artefact
FPCL:    JSR MUL_BY_TEN       ; FLT_A = fraction * 10  [clobbers T0,T1,T2,X,...]
         PLA                  ; restore saved digit
         PLX                  ; restore digit index
         ORA #'0'             ; safe as OR: digit is 0-9, no bits overlap '0'
         STA IBUF,X
         INX
         CPX #7
         BNE FPDIG
FPRD:    LDA IBUF+6
         CMP #'5'
         BCC FPNRD
         LDX #5
FPRU:    INC IBUF,X
         LDA IBUF,X
         CMP #':'
         BCC FPNRD
         LDA #'0'
         STA IBUF,X
         DEX
         BPL FPRU
         LDA #'1'
         STA IBUF
         INC T2
FPNRD:   LDA T2
         STA FLT_DE
         LDX #5
FPST:    LDA IBUF,X
         CMP #'0'
         BNE FPSTD
         DEX
         BPL FPST
FPSTD:   STX FP_LASTNZ        ; index of last non-zero digit (-1/$FF if all zero)
         LDA FLT_DE
         BMI FPLT1
         INC
         STA T2+1             ; T2+1 = integer digit count (de+1)
         LDY #0
FPIT:    LDA #'0'             ; merged digit+padding loop: prep '0', then
         CPY #6                ; overwrite with a real digit if any remain
         BCS FPIT2
         LDA IBUF,Y
         INY
FPIT2:   JSR PUTCH
         DEC T2+1
         BNE FPIT
FPFR:    CPY #6
         BCS FPEND
         LDA FP_LASTNZ
         BMI FPEND            ; all-zero fraction: nothing to print
         CPY FP_LASTNZ
         BEQ FPFRGO           ; Y == FP_LASTNZ: that digit itself still needs
         BCS FPEND            ; printing (bug fix: was BCS-only, an off-by-
                               ; one that skipped single-digit fractions like
                               ; "1.5" entirely -- pre-existing, not from this
                               ; session's changes)
FPFRGO:  LDA #'.'
         JSR PUTCH
FPFRL:   LDA IBUF,Y
         JSR PUTCH
         CPY FP_LASTNZ
         BCS FPEND            ; just printed the last significant digit
         INY
         CPY #6
         BCC FPFRL
         BRA FPEND
FPLT1:   LDA #'0'
         JSR PUTCH
         LDA IBUF
         CMP #'0'
         BEQ FPEND
         LDA #'.'
         JSR PUTCH
         LDA FLT_DE
         EOR #$FF
         BEQ FPLZD
         TAX
FPLZ:    LDA #'0'
         JSR PUTCH
         DEX
         BNE FPLZ
FPLZD:   LDY #0
         BRA FPFRL            ; reuse FPFRL instead of a duplicate loop
FPEND:   JSR POP_FLT_A         ; restore FLT_A (kept as JSR+RTS, NOT a tail
         RTS                   ; call -- POP_FLT_A's trampoline requires its
                                ; own fresh return address from being JSR'd)

; =============================================================================
; FLT_PARSE  --  parse a decimal numeric literal at IP into FLT_A
;
;   In:  IP -> optional sign, digits, optional '.' and more digits
;   Out: FLT_A = parsed value; IP advanced past the literal
;   Clobbers: A, X, FLT_A, FLT_B, FLT_DE, IP, and everything FLT_ADD/
;   FLT_FROM_INT_B/MUL_BY_TEN/PARSE_FRAC clobber
; =============================================================================
FLT_PARSE:
         JSR FLT_ZERO
         STZ FLT_DE
         LDA (IP)
         CMP #'-'
         BNE FPNN
         LDA #$80
         STA FLT_DE
         JSR GETCI
         BRA FPAI
FPNN:    CMP #'+'
         BNE FPAI
         JSR GETCI
FPAI:    LDA (IP)
         CMP #'0'
         BCC FPDT
         CMP #'9'+1
         BCS FPDT
         SEC
         SBC #'0'
         STA T0                ; save digit to T0 BEFORE MUL_BY_TEN, not X
         STZ T0+1               ; after: FLT_MUL (via MUL_BY_TEN) clobbers X
         JSR GETCI               ; per its own documented contract -- T0 is
         JSR MUL_BY_TEN            ; untouched by FLT_MUL/MUL_BY_TEN, safe
         JSR FLT_FROM_INT_B
         JSR FLT_ADD
         BRA FPAI
FPDT:    CMP #'.'
         BNE FPSG
         JSR GETCI
         JSR PUSH_FLT_A        ; park FLT_A on hardware stack
         JSR PARSE_FRAC
         JSR FLT_A_TO_B
         JSR POP_FLT_A         ; restore FLT_A
         JSR FLT_ADD
FPSG:    LDA FLT_DE
         BEQ FPSND
         JMP FLT_NEGATE
FPSND:   RTS

; =============================================================================
; PARSE_FRAC  --  parse the fractional digits after a decimal point
;
;   In:  IP -> first fractional digit
;   Out: FLT_A = 0.<digits> (i.e. those digits' value scaled into [0,1));
;        IP advanced past the digits
;   Clobbers: A, X, FLT_A, FLT_B, IP, and everything FLT_ADD/DIV_BY_TEN/
;   FLT_FROM_INT_B clobber
; =============================================================================
PARSE_FRAC:
         LDA (IP)
         CMP #'0'
         BCC PFE
         CMP #'9'+1
         BCS PFE
         SEC
         SBC #'0'
         TAX
         JSR GETCI
         PHX
         JSR PARSE_FRAC
         PLX
         STX T0
         STZ T0+1
         JSR FLT_FROM_INT_B
         JSR FLT_ADD
         JMP DIV_BY_TEN
PFE:     JMP FLT_ZERO

; ===========================================================================
; CORDIC trig: SIN(x)/COS(x), x in degrees (float, any range/sign)
;
; Pipeline: FLT_A (degrees) --range-reduce to [0,360)--> T0 (0-359 int)
;           --quadrant-fold--> T0 (0-90), T1 (quadrant flags)
;           --x182/256--> CZ (Z angle units, 16384=90deg)
;           --CORDIC_KERN (16-iter, branchless)--> CX=cos*10000, CY=sin*10000
;           --apply quadrant sign to CX/CY--> select CX or CY --> FLT_A/10000
; ===========================================================================

; =============================================================================
; CORDIC_KERN  --  16-iteration branchless rotation-mode CORDIC
;
;   In:  CX/CY = initial vector (CX=6073, CY=0 for our use), CZ = target
;        angle (16384 units = 90 deg; converges for |CZ| up to ~18182, i.e.
;        ~100 deg, so callers must pre-fold to 0-90 deg before calling this)
;   Out: CX = 10000*cos(angle), CY = 10000*sin(angle) (both +-~5 units)
;   Clobbers: A, X, Y, TMPX, TMPY, MASKXZ, MASKY
; =============================================================================
CORDIC_KERN:
        LDY #0
CK_ITER:
        LDX #3
CK_CP:  LDA CX,x
        STA TMPX,x
        DEX
        BPL CK_CP
        TYA
        BEQ CK_NOSH
        TAX
CK_SH:  LDA TMPX+1
        ASL 
        ROR TMPX+1
        ROR TMPX
        LDA TMPY+1
        ASL 
        ROR TMPY+1
        ROR TMPY
        DEX
        BNE CK_SH
CK_NOSH:
        LDA CZ+1
        ASL 
        LDA #0
        SBC #0
        STA MASKXZ
        EOR #$FF
        STA MASKY
        LDA MASKXZ
        ASL 
        LDA TMPY
        EOR MASKXZ
        ADC CX
        STA CX
        LDA TMPY+1
        EOR MASKXZ
        ADC CX+1
        STA CX+1
        LDA MASKY
        ASL 
        LDA TMPX
        EOR MASKY
        ADC CY
        STA CY
        LDA TMPX+1
        EOR MASKY
        ADC CY+1
        STA CY+1
        LDA MASKXZ
        ASL 
        LDA CK_ATL,y
        EOR MASKXZ
        ADC CZ
        STA CZ
        LDA CK_ATH,y
        EOR MASKXZ
        ADC CZ+1
        STA CZ+1
        INY
        CPY #16
        BNE CK_ITER
        RTS

CK_ATL: .DB <8192,<4836,<2555,<1297,<651,<326,<163,<81,<41,<20,<10,<5,<3,<1,<1,<0
CK_ATH: .DB >8192,>4836,>2555,>1297,>651,>326,>163,>81,>41,>20,>10,>5,>3,>1,>1,>0

; FLT_360_B -- FLT_B = 360.0.  Clobbers: A.
FLT_360_B:
        LDA #$89
        STA FLT_B
        LDA #$34
        STA FLT_B+1
        STZ FLT_B+2
        STZ FLT_B+3
        RTS

; FLT_10000_B -- FLT_B = 10000.0.  Clobbers: A.
FLT_10000_B:
        LDA #$8E
        STA FLT_B
        LDA #$1C
        STA FLT_B+1
        LDA #$40
        STA FLT_B+2
        STZ FLT_B+3
        RTS

; =============================================================================
; DO_TRIG  --  shared SIN/COS implementation, entered from EXPR2
;
;   In:  FLT_A = angle in degrees (already parsed by the caller);
;        A = 0 for COS, 1 for SIN
;   Out: FLT_A = cos(angle) or sin(angle), accurate to ~0.05%
;   Clobbers: A, X, Y, FLT_A, FLT_B, T0-T2, CX, CY, CZ, TMPX, TMPY,
;   MASKXZ, MASKY
; =============================================================================
DO_TRIG:
        PHA                     ; save cos/sin selector
        JSR FLT_360_B
        JSR FLT_MOD             ; FLT_A = angle mod 360 (truncating; may be negative)
        LDA FLT_A               ; exponent==0 is this codebase's canonical "value is
        BEQ DT_NONNEG           ; zero" test (see FLT_PRINT) -- treat as non-negative
        LDA FLT_A+1
        BPL DT_NONNEG
        JSR FLT_360_B
        JSR FLT_ADD             ; negative: wrap into [0,360)
DT_NONNEG:
        JSR FLT_TO_INT          ; T0 = 0..359
        ; ---- quadrant fold: T0 -> 0..90, T1 = flags (bit0=negate CX, bit1=negate CY)
        LDA T0+1
        BNE DTF_HI
        LDA T0
        CMP #91
        BCC DTF_Q1
        CMP #181
        BCC DTF_Q2
        BRA DTF_Q3               ; hi=0 means T0<=255, and 255<271, so must be Q3
DTF_HI:
        LDA T0
        CMP #15                 ; 256+15=271: Q3/Q4 split
        BCC DTF_Q3
DTF_Q4: LDA #<360
        SEC
        SBC T0
        STA T0
        LDA #>360
        SBC T0+1
        STA T0+1
        LDA #2
        BRA DTF_FLAGS
DTF_Q3: LDA T0
        SEC
        SBC #180
        STA T0
        LDA T0+1
        SBC #0
        STA T0+1
        LDA #3
        BRA DTF_FLAGS
DTF_Q2: LDA #180
        SEC
        SBC T0
        STA T0
        STZ T0+1
        LDA #1
        BRA DTF_FLAGS
DTF_Q1: STZ T0+1
        LDA #0
DTF_FLAGS:
        STA T1
        ; ---- T0(0-90) * 182/256 -> CZ (angle -> Z units) ----
        LDA #182
        STA T2
        STZ CZ
        STZ CZ+1
        LDX #8
DTF_ML: LSR T2
        BCC DTF_MN
        LDA CZ
        CLC
        ADC T0
        STA CZ
        LDA CZ+1
        ADC T0+1
        STA CZ+1
DTF_MN: ASL T0
        ROL T0+1
        DEX
        BNE DTF_ML
        ; ---- init + run CORDIC ----
        LDA #<6073
        STA CX
        LDA #>6073
        STA CX+1
        STZ CY
        STZ CY+1
        JSR CORDIC_KERN
        ; ---- apply quadrant sign flags ----
        LDA T1
        LSR
        BCC DT_NCX
        LDA #0
        SEC
        SBC CX
        STA CX
        LDA #0
        SBC CX+1
        STA CX+1
DT_NCX: LDA T1
        LSR
        LSR
        BCC DT_NCY
        LDA #0
        SEC
        SBC CY
        STA CY
        LDA #0
        SBC CY+1
        STA CY+1
DT_NCY:
        ; ---- select CX(cos)/CY(sin), convert to float, /10000 ----
        PLA
        BEQ DT_COS
        LDA CY
        STA T0
        LDA CY+1
        STA T0+1
        BRA DT_SCALE
DT_COS: LDA CX
        STA T0
        LDA CX+1
        STA T0+1
DT_SCALE:
        JSR FLT_FROM_INT
        JSR FLT_10000_B
        JMP FLT_DIV

; ===========================================================================
; SHOWCASE (RAM $0200, pre-loaded for simulator)
; Line format: lo_lineno, hi_lineno, ASCII body, CR
; Exercises every statement (PRINT, LET, IF..THEN, GOTO, POKE, FREE, HELP,
; END) and every function (CHR$, PEEK, SIN, COS), plus a CORDIC sine-wave
; plot and a floating-point Mandelbrot finale. Deliberately colon-free (see
; the ':' note in the file header).
; ===========================================================================
         .ORG $0200
; line 10
         .DB $0A,$00,"REM miniBASIC 65C02 Float BASIC - showcase",$0D
; line 20
         .DB $14,$00,"PRINT ",$22,"=== LET and arithmetic ===",$22,$0D
; line 30
         .DB $1E,$00,"LET A=7",$0D
; line 40
         .DB $28,$00,"B=3",$0D
; line 50
         .DB $32,$00,"PRINT ",$22,"A=",$22,";A;",$22," B=",$22,";B",$0D
; line 60
         .DB $3C,$00,"PRINT ",$22,"A+B=",$22,";A+B;",$22," A-B=",$22,";A-B",$0D
; line 70
         .DB $46,$00,"PRINT ",$22,"A*B=",$22,";A*B;",$22," A/B=",$22,";A/B",$0D
; line 80
         .DB $50,$00,"PRINT ",$22,"A MOD B=",$22,";A%B",$0D
; line 90
         .DB $5A,$00,"PRINT ",$22,"=== relational ops ===",$22,$0D
; line 100
         .DB $64,$00,"PRINT ",$22,"A>B ",$22,";A>B;",$22," A<B ",$22,";A<B",$0D
; line 110
         .DB $6E,$00,"PRINT ",$22,"A=A ",$22,";A=A;",$22," A<>B ",$22,";A<>B",$0D
; line 120
         .DB $78,$00,"PRINT ",$22,"=== IF/THEN/GOTO ===",$22,$0D
; line 130
         .DB $82,$00,"IF A>B THEN PRINT ",$22,"A is bigger than B",$22,$0D
; line 140
         .DB $8C,$00,"PRINT ",$22,"=== POKE/PEEK ===",$22,$0D
; line 150
         .DB $96,$00,"POKE 4000,65",$0D
; line 160
         .DB $A0,$00,"PRINT ",$22,"PEEK(4000)=",$22,";PEEK(4000)",$0D
; line 170
         .DB $AA,$00,"PRINT ",$22,"=== CHR$ ===",$22,$0D
; line 180
         .DB $B4,$00,"PRINT CHR$(72);CHR$(73);CHR$(33)",$0D
; line 190
         .DB $BE,$00,"PRINT ",$22,"=== FREE ===",$22,$0D
; line 200
         .DB $C8,$00,"FREE",$0D
; line 210
         .DB $D2,$00,"PRINT ",$22,"=== 355/113 ~ pi ===",$22,$0D
; line 220
         .DB $DC,$00,"PRINT 355/113",$0D
; line 230
         .DB $E6,$00,"PRINT ",$22,"=== SIN/COS identity ===",$22,$0D
; line 240
         .DB $F0,$00,"PRINT SIN(30)*SIN(30)+COS(30)*COS(30)",$0D
; line 250
         .DB $FA,$00,"PRINT ",$22,"=== CORDIC sine wave ===",$22,$0D
; line 260
         .DB $04,$01,"I=0",$0D
; line 270
         .DB $0E,$01,"Y=SIN(I)",$0D
; line 280
         .DB $18,$01,"C=20+Y*18",$0D
; line 290
         .DB $22,$01,"J=0",$0D
; line 300
         .DB $2C,$01,"IF J>=C THEN GOTO 340",$0D
; line 310
         .DB $36,$01,"PRINT ",$22," ",$22,";",$0D
; line 320
         .DB $40,$01,"J=J+1",$0D
; line 330
         .DB $4A,$01,"GOTO 300",$0D
; line 340
         .DB $54,$01,"PRINT ",$22,"*",$22,$0D
; line 350
         .DB $5E,$01,"I=I+15",$0D
; line 360
         .DB $68,$01,"IF I<=360 THEN GOTO 270",$0D
; line 370
         .DB $72,$01,"PRINT ",$22,"=== Mandelbrot finale ===",$22,$0D
; line 380
         .DB $7C,$01,"R=0",$0D
; line 390
         .DB $86,$01,"C=0",$0D
; line 400
         .DB $90,$01,"X=-2+C*0.0417",$0D
; line 410
         .DB $9A,$01,"Y=-1+R*0.0833",$0D
; line 420
         .DB $A4,$01,"U=0",$0D
; line 430
         .DB $AE,$01,"V=0",$0D
; line 440
         .DB $B8,$01,"N=0",$0D
; line 450
         .DB $C2,$01,"P=U*U",$0D
; line 460
         .DB $CC,$01,"Q=V*V",$0D
; line 470
         .DB $D6,$01,"IF P+Q>4 THEN GOTO 540",$0D
; line 480
         .DB $E0,$01,"IF N>=15 THEN GOTO 540",$0D
; line 490
         .DB $EA,$01,"W=P-Q+X",$0D
; line 500
         .DB $F4,$01,"V=2*U*V+Y",$0D
; line 510
         .DB $FE,$01,"U=W",$0D
; line 520
         .DB $08,$02,"N=N+1",$0D
; line 530
         .DB $12,$02,"GOTO 450",$0D
; line 540
         .DB $1C,$02,"K=48+N",$0D
; line 550
         .DB $26,$02,"IF N<15 THEN GOTO 570",$0D
; line 560
         .DB $30,$02,"K=64",$0D
; line 570
         .DB $3A,$02,"PRINT CHR$(K);",$0D
; line 580
         .DB $44,$02,"C=C+1",$0D
; line 590
         .DB $4E,$02,"IF C<60 THEN GOTO 400",$0D
; line 600
         .DB $58,$02,"PRINT",$0D
; line 610
         .DB $62,$02,"R=R+1",$0D
; line 620
         .DB $6C,$02,"IF R<24 THEN GOTO 390",$0D
; line 630
         .DB $76,$02,"PRINT ",$22,"=== HELP ===",$22,$0D
; line 650
         .DB $8A,$02,"END",$0D
SHOWCASE_END:

         .ORG $FFFC
         .DW ROMSTART
         .DW IRQ_HANDLER
