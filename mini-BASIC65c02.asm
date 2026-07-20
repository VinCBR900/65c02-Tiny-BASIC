; =============================================================================
; miniBASIC 65C02 v2.9
; Copyright (c) 2026 Vincent Crabtree, MIT License
;
; 4KB Float BASIC (MBF4) for the 65C02.
;
; Statements accepted
;   END  FOR..TO..STEP  FREE  GOSUB  GOTO  IF..THEN  INPUT  LET  LIST [n,m]
;   NEW  NEXT  POKE  PRINT [TAB(n)][;][CHR$(n)]  REM  RETURN  RUN
;
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   ABS(flt)   ACOS(flt)   ASIN(flt)   ATN(flt)   COS(rad)   FLOOR(flt)   
;   FREE   PEEK(addr)   PI   RND   SIN(rad)   SQR(flt)   TAN(rad)   USR(addr)
;   A-Z variables
;
; Numbers      : MBF4 float, ~6-7 significant decimal digits (see format below)
; String print : "literals", `;`, TAB(n) and CHR$() only; no string variables
;
; Trig is RADIANS-native throughout (SIN/COS/ATN/ASIN/ACOS all take/return
; radians). Use PI (e.g. "X*180/PI") to convert to degrees for display.
;
; FOR/NEXT : loop variable, TO limit, and STEP are all real floats.
;   "FOR X = 1 TO 10 STEP 0.5" and non-integer TO bounds (e.g. "TO 10.5")
;   are both fully supported. Max nesting depth is 4.
;
; GOSUB/GOTO accept expressions eg GOTO 100+10*B
;
; KNOWN LIMITATIONS
;
; Two Character keyword matching - To save ROM space, only 2 chars are 
;   matched, then rest of word consumed until a space or `(`.  So spaces
;   are needed eg `10 PRINT TAB(5);"HELLO"` works, `10 PR TA(5);"Hello"`
;   also works, but `10 PRINTTAB(5);"Hello"` prints '5Hello'
;
; Number literals require a leading digit before the decimal point --
;   "0.5" works, ".5" does not (parses as 0).
;
; TAN(x) raises a ?2 (overflow) error at odd multiples of pi/2 since TAN is
;   undefined there - our sin/cos identity divides by cos(x) which is 0.0.
;
; Measured Trig accuracy: ATN is well-behaved across whole domain, correctly
;   saturates toward +-pi/2 for large |x|) with error up to ~0.005 rad, worst around
;   |x|=0.5-1.5 (e.g. ATN(1)=0.780725 vs true 0.785398). TAN tracks the
;   true value under 0.03% relative error even 0.001 rad from a pi/2
;   asymptote (TAN(pi/2-0.001)=1000.31 vs true 1000.00).
;
; Input buffer is 32 bytes, truncated at IBUF_MAX (31) chars -- each keypress
;   past the limit sounds BELL ($07) but is still echoed. The excess chars
;   are still discarded (X stops advancing), just with an audible signal.
;
; TAB(n) and CHR$(n) are only valid on a PRINT line. Both accept expressions but
;   TAB prints n spaces, not jumps to column n. 
;
; FLOOR(flt) rounds towards zero eg floor(3.5) is 3, floor (-3.5) is -3, NOT -4.
; 
;  FLOAT FORMAT
; MBF4: Byte0=biased_exp($00=zero), Byte1=sign|mant[22:16], Byte2-3=mant[15:0]
;       value=(-1)^sign * 2^(exp-$80) * 0.1mmm...
;       1.0=[$81,$00,$00,$00]  -1.0=[$81,$80,$00,$00]  10.0=[$84,$20,$00,$00]
;
; TRUE=-1.0  FALSE=0.0


; =============================================================================
; CHANGE HISTORY
;
; v2.9 (2026-07) - ROM usage: 94 bytes free .
;   - Refactord FLT push/pop, A->B and B->A for size. Refactored FLT_MOD to use
;     Push/Pop FLT_B rather than manual memory move.
;
; v2.8 (2026-07) - ROM usage: 62 -> 68 bytes free (6 bytes saved).
;   - Refactored MTCHKW & FN_DISPATCH to check for Bit 7 signal for 0 or 1 ARG
;     Function, refactored RND/PI/FREE into FN_TAB to save a little space.
;     Added FLOOR(flt) function which rounds towrads zero.
;
; v2.7WIP (2026-07) - ROM usage: 76 -> 62 bytes free.
;   - Removed DEG, added PI and converted FREE to function form but
;     broke due to adding to FN_TAB which expects ARG, consuming CR terminator.
;
; v2.6 (2026-07)
;   - Fixed a spurious division-by-zero error in ASIN() and ACOS() when evaluating 1 or -1.
;   - Identified a known register-preservation bug in FLT_CMP and its corresponding docstring.
;   - Audited TAN() accuarcy and behavior at asymptotes, confirming division-by-zero is an
;     expected result for undefined inputs, confirms  fit for general use.
;   - Replaced DEG(rad) function with general PI constant function for space. 
;
; v2.5 (Jul 2026) — Duplicate Elimination, GETLINE Audits & Cleanups
;   - ROM usage: 17 -> 15 bytes free.
;   - ADDED: BELL ($07) audible feedback on GETLINE buffer overflow.
;   - OPTIMIZED: POP_FLT_B epilogue duplicated code replaced with BRA PRET.
;   - CLEANUP: Stale header notes removed; statement summary updated for DO_LIST.
;
; v2.4 (Jul 2026) — Code Golfing & Range Feature Additions
;   - ROM usage: 61 -> 17 bytes free.
;   - ADDED: DO_LIST range support (LIST n,m) using persistent 16-bit bounds.
;   - REFACTORED: DO_POKE inline body promoted to shared GET_TWO_ARGS routine.
;   - OPTIMIZED: FLT_LDCONST and FLT_LDCONST_B merged via BIT-trick.
;   - OPTIMIZED: Extracted LD_PI_FUNC helper to factor out duplicated sequences 
;     in FLT_SIN.
;   - OPTIMIZED: FLT_SIN RAM-buffer save/restore replaced with stack 
;     trampolines (PUSH_FLT_A, POP_FLT_B).
;
; v2.3 (Jul 2026) — 65C02 Opcode Pass & TAN Function
;   - ROM usage: 114 -> 61 bytes free.
;   - ADDED: TAN via FN_TAB, computed as sin(x)/cos(x).
;   - OPTIMIZED: replaced JMPs with 65c02 BRAs and fixed PHY/PLY in FLT_SQRT.
;   - FIXED: FLT_TAN float clobbering bug by stashing sin(x) in FLIM.
;   - FIXED: DPTB execution path for TAN(x) to support continued expressions.
;
; v2.2 (Jul 2026) — Float Math & Print Optimizations
;   - ROM usage: 41 -> 114 bytes free.
;   - OPTIMIZED: Extracted shared ADD_A_B/SUB_A_B/SHR_A loops for FLT_ADD/FLT_MUL.
;   - OPTIMIZED: FLT_MUL exponent calculation simplified via EOR $80.
;   - OPTIMIZED: DO_FOR error exits unified via BIT-trick daisy chain.
;   - OPTIMIZED: DO_NEXT limit-copy extracted to CPY_FRM_FLTB.
;   - OPTIMIZED: FLT_PRINT logic streamlined, renaming FP_LASTNZ to FP_LIMIT.
;   - FIXED: Branch-range bugs in shared zero-trampolines.
;
; v2.1 (Jul 2026) — Function Handlers & Table Cleanups
;   - ROM usage: 18 -> 41 bytes free.
;   - REFACTORED: PEEK and USR extracted into FLT_PEEK/FLT_USR handlers via FN_TAB.
;   - OPTIMIZED: DO_LET subroutine call converted to a tail call (JMP).
;   - OPTIMIZED: FLT_CONST_PTR CTAB_HI table removed; hardcoded high byte used.
;   - REVERTED: Attempted STMT and FN_DISPATCH consolidation (cost more than saved).
;
; v2.0 (Jul 2026) — Radians-Native Trig & Function Dispatch
;   - CHANGED: SIN/COS switched from degrees to radians.
;   - ADDED: DEG(rad) function to convert radians back to degrees.
;   - ADDED: ATN(x), ASIN(x), and ACOS(x) wired as recognized keywords.
;   - REFACTORED: EXPR2 function dispatch consolidated into shared FN_TAB/FN_DISPATCH.
;   - FIXED: Tail-jump return address stack leak in FN_DISPATCH.
;
; v1.9 (Jul 2026) — SQR() Function & Critical RND Fix
;   - ROM usage: 9 bytes free.
;   - ADDED: SQR() wired as a recognized keyword.
;   - FIXED (CRITICAL): RND() crash/out-of-bounds bug caused by a missing 
;     FLT_32768_B constant loader accidentally removed in v1.7.
;
; v1.8 (Jul 2026) — Tail-Call & Fallthrough Optimizations
;   - ROM usage: 1 -> 32 bytes free.
;   - OPTIMIZED: Converted trailing JMPs intodropthrough by reorg.
;
; v1.7 (Jul 2026) — Float-Native Trig & Math Functions
;   - REMOVED: Fixed-point CORDIC engine, freeing 323 ROM bytes.
;   - ADDED: Float-native FLT_SIN and FLT_COS (polynomial approximation).
;   - ADDED: Internal subroutines for FLT_SQRT (Newton-Raphson), FLT_ATAN, 
;     FLT_ASIN, and FLT_ACOS.
;   - OPTIMIZED: Extended FLT_LDCONST infrastructure to supply FLT_SIN constants.
;   - OPTIMIZED: Extracted duplicated code in relational operators and DO_ERROR tails.
;
; v1.6 (Jul 2026) — Floating-Point FOR/NEXT
;   - ROM usage: 3897 -> 3909 bytes (195 free).
;   - CHANGED: FOR/NEXT limits and STEP converted to full 4-byte floats, 
;     supporting fractional limits and steps.
;   - CHANGED: DO_NEXT exit test updated to use FLT_CMP directly.
;   - REFACTORED: FOR_STK frame expanded from 7 to 11 bytes per frame.
;
; v1.5 (Jul 2026) — CORDIC Refactor, Duplicate Elimination & Feature Expansion
;   - ROM usage: 3879 -> 3897 bytes (193 free).
;   - ADDED: ABS(n), TAB(n), and float-normalized RND (16-bit Galois LFSR).
;   - CHANGED: Relocated FOR/NEXT stack states from Zero Page to RAM.
;   - REFACTORED: CORDIC optimizations (MASKXZ stashing, hardware multiply).
;   - REFACTORED: Extracted VARIDX and EAT_PAREN subroutines.
;   - REFACTORED: Consolidated PUSH_FLT_A/POP_FLT_A into a unified routine.
;   - CLEANUP: Removed statement-separator caveat and HELP keyword.
;
; v1.4 — FOR/NEXT, Floating-Point Sizing & Core Bug Fixes
;   - ROM usage: 3831 -> 3879 bytes (211 free).
;   - ADDED: FOR/NEXT loop control with a 4-level nested stack on Zero Page.
;   - OPTIMIZED: Unified FLT_FROM_INT routines and added PUSH_FLT_A/POP_FLT_A.
;   - OPTIMIZED: Refactored float math (NORM_PACK, FLT_ADD, FLT_MUL, FLT_DIV).
;   - OPTIMIZED: 65C02 enhancements ((zp) indirect mode, PLX, FLT_PRINT loops).
;   - REFACTORED: Consolidated variable writes, pointer updates, and line shifts.
;   - FIXED: FLT_PRINT off-by-one fractional bug and digit accumulation bug.
;
; v1.3 — GOSUB/RETURN & Keyword Engine Optimization
;   - ADDED: GOSUB and RETURN control flow (8-level Zero Page stack).
;   - CHANGED: Keyword lookup replaced with space-saving 2-character prefix matching.
;
; v1.2 — Zero Page Contiguity & Documentation Pass
;   - ADDED: Standardized In/Out/Clobbers headers across all subroutines.
;   - CHANGED: Reorganized Zero Page into a fully contiguous $00-$B9 block.
;
; v1.1 — Memory Copy & Stack Protection Fixes
;   - OPTIMIZED: Removed dead float routines and rerolled utilities into loops 
;     (saved 68 bytes).
;   - FIXED: DELINE pointer corruption on edits/deletions with >=256 bytes 
;     of trailing text.
;   - FIXED: Immediate-mode GOTO crash by validating RUNSP state.

         .opt proc65c02

; IO comms and constants
IO_OUT   = $E001            ; UART output: write character to terminal
IO_IN    = $E004            ; UART input: read character (0 = no char ready)
RAM_TOP  = $1000            ; first address above usable SRAM (4 KB)
IBUF_MAX = 31
CR       = $0D
LF       = $0A
BS       = $08
BELL     = $07

; Error codes
ERR_SN   = 0
ERR_UL   = 1
ERR_OV   = 2
ERR_OM   = 3
ERR_UK   = 4
ERR_RET  = 5                 ; RETURN without GOSUB
ERR_ST   = 6                 ; illegal (zero) STEP
ERR_FOR  = 7                 ; too many nested FOR (max 4 deep)
ERR_NF   = 8                 ; NEXT without FOR

; ---- zero page  --------------------
; NOTE: IP and CURLN must stay sequential (IP,IP+1,CURLN,CURLN+1) -- the
; GOSUB/RETURN 4-byte frame push/pop loop in DO_GOTO/DO_REM_CHK depends on
; it, same as it does in uBASIC.
        .ORG 0
        ; We need a hack for Kowalski as it executes from zero
        JMP INIT
        NOP
;T0:       .RS 2              ; 16-bit: primary scratch word / expression result
;T1:       .RS 2              ; 16-bit: secondary scratch word / MTCHKW keyword ptr
T0        = 0                 ; Kludge to overwite Kowalski trampoline   
T1        = 2
T2:       .RS 2              ; 16-bit: tertiary scratch word / STMT jump target
IP:       .RS 2              ; 16-bit: interpreter/parse pointer
CURLN:    .RS 2              ; 16-bit: currently-executing line number
PE:       .RS 2              ; 16-bit: program end (one past last byte)
LP:       .RS 2              ; 16-bit: line pointer / MTCHKW's IP-backup scratch
RUN:      .RS 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
IBUF:     .RS 32             ; 32-byte input line buffer ($10-$2F)
FLT_A:    .RS 4              ; 4-byte float accumulator (exp,sign|mant_hi,mant,mant)
FLT_B:    .RS 4              ; 4-byte float operand B
FLT_SA:   .RS 1              ; 8-bit:  sign of FLT_A during add/sub/mul/div
FLT_SB:   .RS 1              ; 8-bit:  sign of FLT_B during add/sub/mul/div
FLT_ER:   .RS 1              ; 8-bit:  running exponent during add/mul/div
FLT_DE:   .RS 1              ; 8-bit:  decimal exponent scratch (FLT_PRINT/PARSE)
FLT_DB:   .RS 1              ; 8-bit:  extra mantissa bit scratch (align/round)
RUNSP:    .RS 1              ; 8-bit:  stack-pointer snapshot for GOTO/RUN unwind
VARS:     .RS 104            ; A-Z variable store (4 bytes each), 104 bytes
VARS_MAX = $67               ; 103; STZ VARS,X for X=103..0 clears VARS (104 bytes)
FP_LIMIT: .RS 1              ; 8-bit:  FLT_PRINT fraction-digit limit (index of last non-zero digit + 1; 0 = none)
FLT_MA:   .RS 1              ; 8-bit:  MUL multiplicand scratch (hi)
FLT_MB:   .RS 1              ; 8-bit:  MUL multiplicand scratch (mid)
FLT_MC:   .RS 1              ; 8-bit:  MUL multiplicand scratch (lo)
FLT_DVH:  .RS 1              ; 8-bit:  DIV divisor scratch (hi)
FLT_DVM:  .RS 1              ; 8-bit:  DIV divisor scratch (mid)
FLT_DVL:  .RS 1              ; 8-bit:  DIV divisor scratch (lo)
GOSUB_SP: .RS 1              ; 8-bit:  GOSUB/RETURN stack pointer (holds a ZP
                             ;  address directly, not an index -- see DO_GOTO)
GOSUB_LO: .RS 32             ; base of the 8-level GOSUB return-frame stack
                             ; (32 bytes: 8 frames x 4 bytes: IP,IP+1,CURLN,CURLN+1)
PFA_RL:   .RS 1              ; 8-bit: PUSH_FLT_A/POP_FLT_A return-addr trampoline lo
PFA_RH:   .RS 1              ; 8-bit: PUSH_FLT_A/POP_FLT_A return-addr trampoline hi
RND_SEED: .RS 2              ; 16-bit: Galois LFSR state for RND
FVAR:     .RS 1              ; 8-bit:  staged byte offset into VARS (var*4)
FLIM:     .RS 4              ; 4-byte: staged limit float (contiguous with
                             ;  FVAR/FSTEP for FSTK_PUSH's indexed copy loop)
FSTEP:    .RS 4              ; 4-byte: staged step float
FSTK:     .RS 1              ; 8-bit: count of active FOR loops (0-4)
T_S:      .RS 4              ; 4-byte: FLT_SQRT's original-S scratch (preserved
                             ;  across all Newton-Raphson iterations)
T_X:      .RS 4              ; 4-byte: FLT_SQRT's per-iteration guess scratch
LSLO:     .RS 2              ; 16-bit: DO_LIST range low bound (dedicated --
                             ;  T0-T2 all get clobbered by PRT16 inside the
                             ;  listing loop, so these can't live there)
LSHI:     .RS 2              ; 16-bit: DO_LIST range high bound

; More Constants here to avoid forward reference issues
GOSUB_TOP  = GOSUB_LO+31    ; empty-stack value for GOSUB_SP (topmost byte)
GOSUB_FULL = GOSUB_LO+3     ; lowest GOSUB_SP for which a full push still fits
ZPEND:  ; audit

        .ORG $200
; ---- FOR/NEXT (loop VARIABLE, LIMIT and STEP are all real floats; "FOR X =
; 1 TO 10 STEP 0.5" is fully supported. Max nesting depth is 4.)
FOR_STK:  .RS 44             ; 4 frames x 11 bytes: [var_slot,
                             ;  limit(4-byte float), step(4-byte float),
                             ;  loop_line_lo,loop_line_hi]

; ===========================================================================
; SHOWCASE (RAM, pre-loaded for simulator; starts at PROG, right after the
; FOR/NEXT RAM block )
; Line format: lo_lineno, hi_lineno, ASCII body, CR
; Exercises every statement (PRINT, LET, IF..THEN, GOTO, FOR..TO..STEP..NEXT,
; POKE, FREE, END) and every function (CHR$, PEEK, SIN, COS, TAN, ASIN,
; ACOS, ATN, SQR), plus VORTEX.BAS -- a trig-library stress test that
; renders a warped 3D spiral vortex, exercising SIN/COS/TAN/ASIN/ACOS/ATN/
; SQR all in one nested pixel-plane scan -- and a floating-point Mandelbrot
; finale, whose pixel-plane scan itself is driven by fractional FOR/NEXT
; bounds (e.g. "FOR Y=-1 TO 0.95 STEP 0.0833"), with X/Y as the loop
; variables directly.
; `:` not supported#

PROG:
; line 10
         .DB $0A,$00,"REM miniBASIC 65C02 Float BASIC - showcase",$0D
; line 20
         .DB $14,$00,"PRINT ",$22,"=== LET and Arithmetic ===",$22,$0D
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
         .DB $C8,$00,"PRINT ",$22,"Free Mem=",$22,"; FREE",$0D
; line 210
         .DB 210,$00,"PRINT ",$22,"=== PI constant ===",$22,$0D
; line 220
         .DB $DC,$00,"PRINT 355/113;",$22,"=355/113 PI=",$22,";PI;",$22," Delta=",$22,";355/113-PI",$0D
; line 230
         .DB $E6,$00,"PRINT ",$22,"=== SIN/COS identity ===",$22,$0D
; line 240
         .DB $F0,$00,"PRINT SIN(0.5)*SIN(0.5)+COS(0.5)*COS(0.5)",$0D
; line 250
         .DB $FA,$00,"REM ============================================",$0D
; line 260
         .DB $04,$01,"REM VORTEX.BAS V1.1 - TRIG LIBRARY STRESS TEST",$0D
; line 270
         .DB $0E,$01,"PRINT ",$22,"=== Render A Warped 3D Spiral Vortex to Test: ===",$22,$0D
; line 280
         .DB $18,$01,"PRINT ",$22,"SIN, COS, TAN, ASIN, ACOS, ATN, SQRT",$22,$0D
; line 290
         .DB $22,$01,"REM L TRACKS LAST COLUMN SINCE TAB() HERE PRINTS",$0D
; line 300
         .DB $2C,$01,"REM N SPACES, NOT AN ABSOLUTE COLUMN",$0D
; line 310
         .DB $36,$01,"REM ============================================",$0D
; line 320
         .DB $40,$01,"LET H=27",$0D
; line 330
         .DB $4A,$01,"LET V=13",$0D
; line 340
         .DB $54,$01,"FOR R=0 TO 26",$0D
; line 350
         .DB $5E,$01,"LET L=0",$0D
; line 360
         .DB $68,$01,"FOR C=0 TO 60",$0D
; line 370
         .DB $72,$01,"LET X=(C-30)/H",$0D
; line 380
         .DB $7C,$01,"LET Y=(R-13)/V",$0D
; line 390
         .DB $86,$01,"LET D=SQRT(X*X+Y*Y)",$0D
; line 400
         .DB $90,$01,"IF D>1.2 THEN GOTO 640",$0D
; line 410
         .DB $9A,$01,"IF X=0 THEN GOTO 440",$0D
; line 420
         .DB $A4,$01,"LET T=ATN(Y/X)",$0D
; line 430
         .DB $AE,$01,"GOTO 450",$0D
; line 440
         .DB $B8,$01,"LET T=1.5708",$0D
; line 450
         .DB $C2,$01,"REM --- TEST SIN/COS ---",$0D
; line 460
         .DB $CC,$01,"LET W=SIN(6*D-3*T)",$0D
; line 470
         .DB $D6,$01,"REM --- TEST TAN ---",$0D
; line 480
         .DB $E0,$01,"LET U=TAN(W*0.5)",$0D
; line 490
         .DB $EA,$01,"REM --- BOUND VALUE TO [-0.99, 0.99] ---",$0D
; line 500
         .DB $F4,$01,"LET P=COS(U)*0.99",$0D
; line 510
         .DB $FE,$01,"REM --- TEST ASIN/ACOS ---",$0D
; line 520
         .DB $08,$02,"LET A=ACOS(P)",$0D
; line 530
         .DB $12,$02,"LET B=ASIN(P)",$0D
; line 540
         .DB $1C,$02,"REM --- MATH SHADE VALUE ---",$0D
; line 550
         .DB $26,$02,"LET Z=ABS(A-B)/3.1416",$0D
; line 560
         .DB $30,$02,"REM --- MAP TO ASCII CHARS ---",$0D
; line 570
         .DB $3A,$02,"LET S=32",$0D
; line 580
         .DB $44,$02,"IF Z>0.15 THEN LET S=46",$0D
; line 590
         .DB $4E,$02,"IF Z>0.35 THEN LET S=43",$0D
; line 600
         .DB $58,$02,"IF Z>0.55 THEN LET S=79",$0D
; line 610
         .DB $62,$02,"IF Z>0.75 THEN LET S=64",$0D
; line 620
         .DB $6C,$02,"PRINT TAB(C-L);CHR$(S);",$0D
; line 630
         .DB $76,$02,"LET L=C+1",$0D
; line 640
         .DB $80,$02,"NEXT C",$0D
; line 650
         .DB $8A,$02,"PRINT",$0D
; line 660
         .DB $94,$02,"NEXT R",$0D
; line 680
         .DB $A8,$02,"PRINT ",$22,"=== Mandelbrot finale ===",$22,$0D
; line 690
         .DB $B2,$02,"FOR Y=-1 TO 0.95 STEP 0.0833",$0D
; line 700
         .DB $BC,$02,"FOR X=-2 TO 0.48 STEP 0.0417",$0D
; line 730
         .DB $DA,$02,"U=0",$0D
; line 740
         .DB $E4,$02,"V=0",$0D
; line 750
         .DB $EE,$02,"N=0",$0D
; line 760
         .DB $F8,$02,"P=U*U",$0D
; line 770
         .DB $02,$03,"Q=V*V",$0D
; line 780
         .DB $0C,$03,"IF P+Q>4 THEN GOTO 850",$0D
; line 790
         .DB $16,$03,"IF N>=15 THEN GOTO 850",$0D
; line 800
         .DB $20,$03,"W=P-Q+X",$0D
; line 810
         .DB $2A,$03,"V=2*U*V+Y",$0D
; line 820
         .DB $34,$03,"U=W",$0D
; line 830
         .DB $3E,$03,"N=N+1",$0D
; line 840
         .DB $48,$03,"GOTO 760",$0D
; line 850
         .DB $52,$03,"K=48+N",$0D
; line 860
         .DB $5C,$03,"IF N<15 THEN GOTO 880",$0D
; line 870
         .DB $66,$03,"K=64",$0D
; line 880
         .DB $70,$03,"PRINT CHR$(K);",$0D
; line 890
         .DB $7A,$03,"NEXT X",$0D
; line 910
         .DB $8E,$03,"PRINT",$0D
; line 920
         .DB $98,$03,"NEXT Y",$0D
; line 960
         .DB $C0,$03,"END",$0D
SHOWCASE_END: ; audit

; ---- STRING/KEYWORD TABLE (page $F0) ----------------------------------------

         .ORG $F000
STR_PAGE = >STR_BANNER
STR_BANNER: .DB "miniBASIC 65C02 v2.9"
STR_CRLF:   .DB $0D,$8A
STR_IN:     .DB " IN",$A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB

; Two uppercase ASCII bytes per keyword (no terminator, no length).
; MTCHKW compares this 2-byte prefix, then skips trailing letters at IP so
; the full BASIC keyword is consumed.
; GOTO/GOSUB, REM/RETURN, TAB/TAN each peek the 3rd  character to check. 
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
KW_FREE:   .DB "F",$D2         ; "FR" with bit7 set on 'R' -- flags FREE as a
                                ; 0-arg keyword for MTCHKW/FN_DISPATCH (real
                                ; ASCII letters never set bit7, so it's free)
KW_PEEK:   .DB "PE"
KW_USR:    .DB "US"
KW_SIN:    .DB "SI"
KW_COS:    .DB "CO"
KW_FOR:    .DB "FO"
KW_TO:     .DB "TO"
KW_STEP:   .DB "ST"
KW_ABS:    .DB "AB"
KW_RND:    .DB "R",$CE         ; "RN" with bit7 set on 'N' -- 0-arg flag
KW_TAB:    .DB "TA"             
KW_SQR:    .DB "SQ"
KW_ATN:    .DB "AT"
KW_ASIN:   .DB "AS"
KW_ACOS:   .DB "AC"
KW_PI:     .DB "P",$C9         ; "PI" with bit7 set on 'I' -- 0-arg flag
KW_FLOOR:  .DB "FL"

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
         JSR DO_NEW

; --- Setup showcase - Delete for actual ROM
         LDA #<SHOWCASE_END
         STA PE
         LDA #>SHOWCASE_END
         STA PE+1
; ---
         LDA #<STR_BANNER
         JSR PUTSTR

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
         BRA PRINT_IN_CURLN_MAIN
DE_NL:   JSR PRNL
         BRA MAIN

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
         ; drop through

; PRINT_IN_CURLN_MAIN -- print " IN <curln>", a blank line, then resume at
;   MAIN (does not return to caller). Shared tail for DO_ERROR/IRQ_HANDLER.
;   Clobbers: everything (never returns)
PRINT_IN_CURLN_MAIN:
         LDA #<STR_IN
         JSR PUTSTR
         LDA CURLN
         STA T0
         LDA CURLN+1
         STA T0+1
         JSR PRT16
         JSR PRNL
         BRA MAIN
IRQI:    RTI

; =============================================================================
; GETLINE_M / GETLINE_I / GETLINE  --  read one line of input into IBUF
;
;   In:  GETLINE_M prints "> " (main prompt); GETLINE_I prints "? " (INPUT
;        prompt); both then fall into GETLINE, which just reads.
;   Out: IBUF holds the typed line (CR-terminated, backspace-editable,
;        truncated past IBUF_MAX -- each keypress past the limit sounds
;        BELL); IP -> IBUF
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
         BCS GLFULL
         STA IBUF,X
         INX
         BRA GLL
GLFULL:  LDA #BELL              ; buffer full: still discard the char (X
         JSR PUTCH               ; doesn't move), but beep so the overflow
         BRA GLL                 ; isn't silent anymore
GLD:     STA IBUF,X
         JSR PRNL
         LDA #<IBUF
         STA IP
         LDA #>IBUF
         STA IP+1
PND:     RTS

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
         BRA ELD         ; no body: done
ELIS2:   ; drop through
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
;   two 16-bit increments for the cost of one JSR .
;   In: LP   Out: LP+2 (ADD2_LP) or LP+1 (BUMP_LP)   Clobbers: nothing
; =============================================================================
ADD2_LP: JSR BUMP_LP    ; do not split from BUMP_LP
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

; VARIDX -- consume a variable letter (already validated as A-Z by the
;   caller) and compute its VARS byte offset (index*4)
;   In: IP -> the letter (peeked+validated, not yet consumed)
;   Out: A = byte offset into VARS; IP advanced past the letter
;   Clobbers: A
VARIDX:  JSR GETCI
         JSR UC
         SEC
         SBC #'A'
         ASL
         ASL
         RTS

; RND_SHUFFLE -- advance the 16-bit Galois LFSR one step (tap $B4:
;   x^16+x^14+x^13+x^11+1). Called both from GETCH's keyboard-wait loop
;   (accumulating entropy from real timing jitter while idle) and from
;   RND() itself. Shuffles on every call; better with a hardware timer,
;   but this board doesn't have one.
;   Out: RND_SEED advanced  Clobbers: A
RND_SHUFFLE:
         LSR RND_SEED+1
         ROR RND_SEED
         BCC RS_SK
         LDA RND_SEED+1
         EOR #$B4
         STA RND_SEED+1
RS_SK:   RTS

; =============================================================================
; DO_FREE  --  FREE Memory function - returns free bytes
;   In:  PE = current program end
;   Clobbers: A, T0
; =============================================================================
DO_FREE: SEC
         LDA #<RAM_TOP
         SBC PE
         STA T0
         LDA #>RAM_TOP
         SBC PE+1
         STA T0+1
         JMP FLT_FROM_INT

; =============================================================================
; DO_PRINT  --  PRINT statement
;
;   In:  IP->print-list "string", expr, TAB(n) (n is spaces), CHR$(n), separated by ';'
;   Out: items printed; trailing ';' suppresses the final CRLF
;   Clobbers: A, X, Y, T0-T2, FLT_A, IP
; =============================================================================
DO_PRINT:
DPT:        JSR WPEEK
DPT_CHK:    CMP #CR+1           ; Dual-boundary check: Is A < 14 (NUL or CR)?
            BCC PRNL            ; If so, branch directly to external PRNL
            CMP #'"'
            BNE DPX
            
            JSR GETCI           ; Consume opening quote
DPS:        JSR GETCI
            CMP #'"'
            BEQ DPA
            CMP #CR
            BEQ PRNL            ; String broke early: hit the newline
            JSR PUTCH
            BRA DPS

DPX:        LDA #<KW_CHRS
            JSR MTCHKW
            BCC DO_CHRS
            LDA #<KW_TAB
            JSR MTCHKW
            BCS DPNC
            
            LDY #2              ; Disambiguate TAB from TAN
            LDA (LP),Y
            AND #$DF
            CMP #'N'
            BEQ REWIND_TAN
            
DO_TAB:     JSR EAT_PAREN
            JSR FLT_TO_INT
            LDX T0              ; Direct to X (sets Z flag)
            BEQ DPA             ; TAB(0) or negative: skip printing spaces
DPTL:       LDA #' '
DPTL_ENTRY: JSR PUTCH
            DEX
            BNE DPTL
            BRA DPA             ; Jump to trailing delimiter handler

DO_CHRS:    JSR EAT_PAREN
            JSR FLT_TO_INT
            LDX #1              ; Target loop count = 1
            LDA T0              ; Load targeted CHR$ value
            BRA DPTL_ENTRY      ; Re-use the space loop infrastructure

REWIND_TAN: LDA LP
            STA IP
            LDA LP+1
            STA IP+1            ; Restore input pointer to pre-match state
DPNC:       JSR EXPR
            JSR FLT_PRINT
            
DPA:        JSR WPEEK
            CMP #';'
            BNE PRNL            ; Missing trailing semicolon: newline and RTS
            JSR GETCI           ; Consume semicolon
            JSR WPEEK           ; Peek next token
            CMP #CR+1           ; Is next token NUL or CR (< 14)?
            BCS DPT_CHK         ; If >= 14, loop back to handle next token
            RTS                 ; If NUL or CR, suppress newline and exit

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
; DO_LIST -- LIST [n,m] : print program lines, optionally restricted to a
;   line-number range. With no arguments, lists the whole program (original
;   behavior, unchanged). 
;   In: IP -> optional "n,m" range   Clobbers: A, X, Y, T0, T1, FLT_A, IP, LP
DO_LIST: STZ LSLO
         STZ LSLO+1             ; default lo-bound = 0
         LDA #$FF
         STA LSHI
         STA LSHI+1             ; default hi-bound = $FFFF (no real limit)
         JSR WPEEK
         CMP #CR+1
         BCC LS_SCAN            ; bare CR: no args, full-range listing
         JSR GET_TWO_ARGS       ; T1 = lo-bound, T0 = hi-bound
         LDA T1
         STA LSLO
         LDA T1+1
         STA LSLO+1
         LDA T0
         STA LSHI
         LDA T0+1
         STA LSHI+1
LS_SCAN: LDX #6
         JSR PROG2X
LSL:     LDX #6
         JSR PE_CMP_X
         BEQ LSDN
LSGO:    LDA (LP)
         STA T0
         LDY #1
         LDA (LP),Y
         STA T0+1                ; T0 = this line's number
         LDA LSHI                ; stop entirely once current > hi-bound
         CMP T0                  ; (program is sorted ascending, so nothing
         LDA LSHI+1               ;  past this point can be in range either)
         SBC T0+1
         BCC LSDN
         LDA T0                  ; skip (don't print) if current < lo-bound
         CMP LSLO
         LDA T0+1
         SBC LSLO+1
         BCC LSSKIP
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
LSSKIP:  JSR LSKIP               ; LP still at header start -- LSKIP's own
         BRA LSL                 ; contract, matches GOTOL's convention too
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
; DO_POKE  --  POKE addr,value statement
;
;   In:  IP -> "<addr-expr>,<value-expr>"
;   Out: memory at addr written with (value AND $FF)
;   Clobbers: A, X, Y, T0, T1, FLT_A, IP
; =============================================================================
DO_POKE: JSR GET_TWO_ARGS      ; T1 = address, T0 = value
         LDA T0
         STA (T1)
         RTS

; =============================================================================
; GET_TWO_ARGS -- shared helper: parse "<expr>,<expr>", each converted to a
;   signed 16-bit integer via FLT_TO_INT (EXPR's real output is a float in
;   FLT_A -- every caller that wants an int follows it with FLT_TO_INT; see
;   DO_GOTO). Was DO_POKE's own inline body; DO_LIST's range feature reuses
;   it unchanged.
;
;   In:  IP -> "<expr>,<expr>"
;   Out: T1 = first arg, T0 = second arg (both signed 16-bit ints)
;   Clobbers: A, X, Y, T0, T1, FLT_A, IP
; =============================================================================
GET_TWO_ARGS:
         JSR EXPR
         JSR FLT_TO_INT
         LDA T0+1
         PHA
         LDA T0
         PHA
         JSR WEAT
         JSR EXPR
         JSR FLT_TO_INT
         PLA
         STA T1
         PLA
         STA T1+1
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
         JSR VARIDX
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
         JMP STORE_VAR

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
         BRA RLTAIL
RLNL:    CMP #'='
         BNE RLNE
         TXA
         ORA #2
         BRA RLTAIL
RLNE:    CMP #'>'
         BNE RLNR
         TXA
         ORA #4
RLTAIL:  TAX
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
EARS:        
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
         BRA E2PR        ; parenthesised expression
E2NP2:
         CMP #'-'
         BNE E2NNG
         BRA E2NG
E2NNG:   CMP #'+'
         BEQ E2PS
E2NFN:   JSR FN_DISPATCH        ; ABS/SQR/SIN/COS/ATN/ASIN/ACOS/TAN/PEEK/USR/
                                 ; RND/PI/FREE (all via FN_TAB now -- RND/PI/
                                 ; FREE's KW_ entries carry the 0-arg flag,
                                 ; see MTCHKW). Falls through to E2ND (numeric
                                 ; literal) only if NO entry matches at all.
E2ND:    LDA (IP)
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
         JSR VARIDX
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
         BRA WEAT

; =============================================================================
; EAT_PAREN -- consume a delimiter+expr (EAT_EXPR), then consume one more
;   delimiter (the closing ')'). Shared by CHR$/PEEK/USR/SIN/COS parsing.
;   Clobbers: same as EAT_EXPR, plus WEAT's (none extra)
EAT_PAREN: JSR EAT_EXPR
           ; drop through

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
         BNE PUTCH
         JSR RND_SHUFFLE
         BRA GETCH

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
         BMI DO_LET
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
;DIFDN:   RTS
;STLT:
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
         JSR VARIDX
         PHA
         JSR WPEEK
         CMP #'='
         BNE DLPOP
         JSR GETCI
         JSR EXPR
         PLX
         JMP STORE_VAR
DLPOP:   PLA
         LDA #ERR_UK
         JMP DO_ERROR

; =============================================================================
; FSTK_BASE  --  LP = FOR_STK + A*11
;   In:  A = frame index (0-3)
;   Out: LP = address of that frame within FOR_STK
;   Clobbers: A, T2
; =============================================================================
FSTK_BASE:
         STA T2
         ASL 
         ASL 
         CLC
         ADC T2                ; A = index*5
         ASL                    ; A = index*10
         CLC
         ADC T2                ; A = index*11
         CLC
         ADC #<FOR_STK
         STA LP
         LDA #>FOR_STK
         ADC #0
         STA LP+1
DIFDN:
DLD:     RTS

; =============================================================================
; DO_FOR  --  FOR var = start TO limit [STEP step]
;
;   In:  IP -> variable letter
;   Out: loop frame pushed onto FOR_STK; VARS[var] = float(start)
;   Clobbers: A, X, Y, T0, T2, LP, FLT_A, FLT_B, FLT_ER, FLT_SA
;
;   The loop VARIABLE, LIMIT, and STEP are all real floats now -- LIMIT
;   and STEP are staged whole (no int16 truncation), so "FOR X = 1 TO 10
;   STEP 0.5" and non-integer TO bounds ("FOR X = 1 TO 10.5") both work.
;
;   Error paths (bad var name, missing '=', missing TO, too many nested
;   FORs, STEP of zero) share one JMP DO_ERROR via a BIT-trick daisy chain
;   (same technique as ERR_UL_J elsewhere): each LDA #errcode falls into
;   a ".byte $2C" that turns the *next* "LDA #errcode" into a harmless
;   3-byte BIT-absolute, skipping straight past it to the shared JMP.
; =============================================================================
DO_FOR:
         JSR WPEEK_UC
         CMP #'A'
         BCC DFBAD
         CMP #'Z'+1
         BCS DFBAD
         JSR VARIDX             ; var_index*4 = byte offset into VARS
         STA FVAR
         JSR WPEEK
         CMP #'='
         BNE DFBAD
         JSR GETCI
         JSR EXPR               ; evaluate start -> FLT_A
         LDX FVAR
         JSR STORE_VAR
         LDA #<KW_TO
         JSR MTCHKW
         BCS DFBAD              ; TO is mandatory
         JSR EXPR               ; evaluate limit -> FLT_A
         LDX #3                 ; stage limit float FLT_A -> FLIM (4 bytes)
DFLCP:   LDA FLT_A,X
         STA FLIM,X
         DEX
         BPL DFLCP
         LDA #<KW_STEP
         JSR MTCHKW
         BCS DFNOSTEP
         JSR EXPR               ; evaluate step -> FLT_A
         BRA DFSCP
DFNOSTEP:
         LDA #1                 ; default step = 1.0
         STA T0
         STZ T0+1
         JSR FLT_FROM_INT       ; FLT_A = 1.0
DFSCP:   LDX #3                 ; stage step float FLT_A -> FSTEP (4 bytes)
DFSCPL:  LDA FLT_A,X
         STA FSTEP,X
         DEX
         BPL DFSCPL
         LDA FSTEP              ; step of zero is illegal (exponent byte = 0)
         BNE DFSZOK

ERR_ST_J:
         LDA #ERR_ST            ; BIT-trick daisy chain (see header note)
         .byte $2C              ; swallows the next LDA #ERR_FOR as a BIT abs
ERR_FOR_J:
         LDA #ERR_FOR
         .byte $2C              ; swallows the next LDA #ERR_SN as a BIT abs
DFBAD:
         LDA #ERR_SN
         JMP DO_ERROR           ; shared exit point for all DO_FOR errors

DFSZOK:  LDA FSTK
         CMP #4                 ; max 4 nested FOR loops
         BCS ERR_FOR_J
DFPUSH:  JSR FSTK_BASE          ; LP = FOR_STK + FSTK*11 (A already = FSTK)
         LDY #10                ; CURLN merged into the main copy loop below
         LDA CURLN+1
         STA (LP),Y             ; [10] loop_line_hi
         DEY
         LDA CURLN
         STA (LP),Y             ; [9]  loop_line_lo
         DEY
DFCP:    LDA FVAR,Y             ; [0..8] copy contiguous FVAR, FLIM, FSTEP
         STA (LP),Y
         DEY
         BPL DFCP
         INC FSTK
         RTS

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
         BEQ DO_NEXT
         ; fall through to DO_NEW ('W', i.e. "NEW")

; =============================================================================
; DO_NEW  --  NEW statement: erase the program and clear all variables
;
;   In:  --
;   Out: PE reset to PROG; VARS zeroed; GOSUB and FOR/NEXT stacks emptied
;   Clobbers: A, X
; =============================================================================
DO_NEW:  LDX #$FF       ; wipe zero page
INIZ:    STZ 0,X
         DEX
         BPL INIZ
        ; load vars
         LDX #4
         JSR PROG2X
         LDA #GOSUB_TOP
         STA GOSUB_SP          ; empty call stack (immediate-mode GOSUB unwind)
RESEED_RND:
         LDA #$AC
         STA RND_SEED           ; reseed RND too (0 is a fixed point for a
         LDA #$E1                 ; Galois LFSR, never reached again once
         STA RND_SEED+1              ; seeded non-zero, but NEW resets to a
         RTS                            ; known sequence, same as uBASIC)

; =============================================================================
; DO_NEXT  --  NEXT [var]
;
;   In:  IP -> optional variable name (consumed but not checked against the
;        FOR variable; NEXT always closes the innermost active loop)
;   Out: loop variable advanced; branches back to the line after the FOR
;        that opened this loop, or falls through to the statement after
;        NEXT once the limit is crossed
;   Clobbers: A, X, Y, T0, T1, T2, LP, FLT_A, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DB
;
;   Both bound and step are now full floats. After VAR += STEP, FLT_CMP
;   compares VAR to LIMIT (-1/0/+1). Which outcomes mean "keep looping"
;   depends on STEP's sign, stashed on the hardware stack before FLT_ADD/
;   FLT_CMP get a chance to clobber FLT_B: for a positive STEP, loop unless
;   VAR>LIMIT; for a negative STEP, loop unless VAR<LIMIT. Landing exactly
;   on LIMIT (CMP==0) always loops once more (inclusive bound), same as
;   the old integer version.
;
;   The stop/loop decision is done in X rather than via CMP #1 / CMP #$FF:
;   TAX the -1/0/+1 compare result, then DEX (positive step) or INX
;   (negative step) turns "stop" into X==0, testable with a single BNE/BEQ.
; =============================================================================
DO_NEXT:
         JSR WPEEK_UC           ; consume optional variable name (ignored)
         CMP #'A'
         BCC DNNOVAR
         CMP #'Z'+1
         BCS DNNOVAR
         JSR GETCI
DNNOVAR: LDA FSTK
         BNE DNOK
         LDA #ERR_NF
         JMP DO_ERROR
DNOK:    DEC                    ; top frame index = FSTK-1
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
         LDY #8                 ; copy step float, frame[5..8] -> FLT_B
         JSR CPY_FRM_FLTB
         LDY #6                 ; frame[6] = step's sign|mant_hi byte;
         LDA (LP),Y             ; stash its sign bit now, before FLT_ADD/
         AND #$80               ; FLT_CMP get a chance to clobber FLT_B
         PHA
         JSR FLT_ADD            ; FLT_A = var + step
         LDA (LP)               ; var_slot again
         TAX
         JSR STORE_VAR           ; store updated loop variable back to VARS
         LDY #4                 ; copy limit float, frame[1..4] -> FLT_B
         JSR CPY_FRM_FLTB
         JSR FLT_CMP             ; A = -1/0/+1 (var vs limit); FLT_A preserved
         TAX                     ; stash compare result in X
         PLA                     ; recover step's sign bit (00=pos, 80=neg)
         BMI DN_negstep
         DEX                     ; positive step: CMP==1 (var>limit) -> X=0
         BNE DN_loop             ; loop unless X==0
DN_done: DEC FSTK                ; limit crossed: pop the frame, fall through
         RTS
DN_negstep:
         INX                     ; negative step: CMP==-1 (var<limit) -> X=0
         BEQ DN_done             ; stop unless X!=0
DN_loop: LDY #9
         LDA (LP),Y             ; [9] loop_line_lo
         STA T0
         INY
         LDA (LP),Y             ; [10] loop_line_hi
         STA T0+1
         JSR GOTOL
         BCS DN_ul
         LDX RUNSP
         TXS                    ; unwind hardware stack (same as GOTO/RETURN)
         JMP SKL                ; skip past the FOR line itself, land on body
DN_ul:   JMP ERR_UL_J

; =============================================================================
; CPY_FRM_FLTB -- copy 4 bytes ending at (LP),Y down through (LP),Y-3 into
;                 FLT_B (used for both the step and limit copies in DO_NEXT)
;   In:  Y = offset of the last (highest) byte to copy from the frame
;   Out: FLT_B = the 4-byte float at (LP),Y-3..Y
;   Clobbers: A, X, Y
CPY_FRM_FLTB:
         LDX #3
CFFL:    LDA (LP),Y
         STA FLT_B,X
         DEY
         DEX
         BPL CFFL
         RTS

; =============================================================================
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
         .DB $FF

; FLT_ABS -- FLT_A = |FLT_A|.  Clobbers: A.
FLT_ABS: LDA FLT_A+1
         AND #$7F
         STA FLT_A+1
         RTS

; ---- FN_TAB: unary float-function dispatch table (3 bytes/entry, $FF-
; terminated). Each handler receives FLT_A=argument (already parsed by
; FN_DISPATCH's EAT_PAREN) and must return FLT_A=result, ending in RTS.
FN_TAB:
         .DB <KW_ABS, <FLT_ABS, >FLT_ABS
         .DB <KW_SQR, <FLT_SQRT,>FLT_SQRT
         .DB <KW_SIN, <FLT_SIN, >FLT_SIN
         .DB <KW_COS, <FLT_COS, >FLT_COS
         .DB <KW_ATN, <FLT_ATAN,>FLT_ATAN
         .DB <KW_ASIN,<FLT_ASIN,>FLT_ASIN
         .DB <KW_ACOS,<FLT_ACOS,>FLT_ACOS
         .DB <KW_TAB, <FLT_TAN, >FLT_TAN  
         .DB <KW_PEEK,<FLT_PEEK,>FLT_PEEK
         .DB <KW_USR, <FLT_USR, >FLT_USR
         .DB <KW_FLOOR, <FLT_FLOOR, >FLT_FLOOR
         .DB <KW_RND, <FLT_RND, >FLT_RND   ; 0-arg (KW_RND flags it)
         .DB <KW_PI,  <FLT_PI,  >FLT_PI    ; 0-arg (KW_PI flags it)
         .DB <KW_FREE,<DO_FREE, >DO_FREE   ; 0-arg (KW_FREE flags it)
         .DB $FF

; =============================================================================
; FLT_PEEK -- FLT_A = float(PEEK(FLT_A)).  In: FLT_A=address.  Clobbers: A,X,Y,T0.
FLT_PEEK:
         JSR FLT_TO_INT
         LDA (T0)
         STA T0
         STZ T0+1
         JMP FLT_FROM_INT

; =============================================================================
; FLT_USR -- call machine code at FLT_A (as an address); FLT_A = its
;   result (via USR_CALL).  
;   Out: FLT_A = float(A) zero-extended to 16 bits
;   Clobbers: A,X,Y,T0 + whatever the called routine clobbers.
FLT_USR:
         JSR FLT_TO_INT
         JSR USR_CALL   
         JMP FLT_FROM_INT
USR_CALL: JMP (T0)

; =============================================================================
; FN_DISPATCH  --  match one keyword against FN_TAB and, on a match, parse
;   its "(expr)" argument and tail-call the handler.
;
;   In:  IP -> candidate keyword text
;   Out: match:  handler invoked with FLT_A=argument; the handler's own RTS
;        returns past FN_DISPATCH's caller (tail call via JMP (T2)) --
;        FN_DISPATCH itself does not return to its caller on a match
;        no match: carry set, IP unchanged, RTS
;   Clobbers: A, X, Y, T1, T2 (+ the matched handler's own clobbers)
; =============================================================================
FN_DISPATCH:
         LDX #0
FNL:     LDA FN_TAB,X
         BMI FNLT
         JSR MTCHKW
         BCS FNNX
         BMI FN_NOPAREN         ; N flag (from MTCHKW): 0-arg keyword, e.g.
                                ; RND/PI/FREE -- skip the "(expr)" parse
         PHX                    ; save table offset -- EAT_PAREN clobbers X
         JSR EAT_PAREN
         PLX
FN_NOPAREN:
         LDA FN_TAB+1,X
         STA T2
         LDA FN_TAB+2,X
         STA T2+1
         PLA                    ; discard FN_DISPATCH's own return address --
         PLA                    ; it's about to tail-jump, not RTS, so this
                                 ; frame must not be left stranded on the
                                 ; stack (the handler's own RTS must land on
                                 ; EXPR2's true caller, not back in here)
         JMP (T2)
FNNX:    INX
         INX
         INX
         BRA FNL
FNLT:    SEC
         RTS

; =============================================================================
; MTCHKW  --  case-insensitive match of a 2-char keyword prefix at IP, then
;             consumes any further trailing letters (uBASIC's scheme)
;
;   In:  A = low byte of the 2-byte keyword prefix (on STR_PAGE)
;   Out: match:  carry clear, IP advanced past the matched keyword,
;                N flag = bit 7 of the keyword's 2nd stored byte (set by
;                the keyword definition itself -- see KW_RND/KW_PI/KW_FREE --
;                to flag a keyword that takes no parenthesized argument;
;                real ASCII letters never set this bit, so it's free).
;                FN_DISPATCH tests BMI/BPL right after a match to decide
;                whether to call EAT_PAREN.
;        no match: carry set, IP restored to its value on entry, N/Z
;                undefined (check carry first, always)
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
         LDY #1
         LDA (T1),Y            ; A = raw stored 2nd byte (may carry the 0-arg
                                ; flag in bit 7 -- see KW_RND/KW_PI/KW_FREE)
         STA T1+1               ; stash raw byte (STR_PAGE no longer needed;
                                 ; T1/T1+1 are already documented-clobbered,
                                 ; so no caller can be relying on them here)
         AND #$7F                ; mask the flag bit off for the real compare
         STA T1
         JSR PEEKUC               ; A = peeked char (real ASCII, bit7 always 0)
         CMP T1
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
MKRTS:   LDA T1+1              ; N flag = bit 7 of raw 2nd keyword byte (the
                                ; 0-arg flag) -- FN_DISPATCH tests BMI/BPL
         CLC
         RTS
MKFL:    LDA LP
         STA IP
         LDA LP+1
         STA IP+1
         SEC
         RTS

; =============================================================================
; FLOAT LIBRARY  --  MBF4 format, see header comment for the byte layout
; =============================================================================

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
        JSR PUSH_FLT_A
        JSR POP_FLT_B ; must be JSR as routine cleans up return address
        RTS

; FLT_RND -- FLT_A = pseudorandom float, 0 <= x < 1 (LFSR value / 32768)
;   Out: FLT_A = result.  Clobbers: as RND_SHUFFLE/FLT_FROM_INT/FLT_DIV
FLT_RND: JSR RND_SHUFFLE
         LDA RND_SEED
         STA T0
         LDA RND_SEED+1
         AND #$7F              ; force positive (0-32767 range)
         STA T0+1
         JSR FLT_FROM_INT
         LDX #IDX_32768
         JSR FLT_LDCONST_B
         JMP FLT_DIV           ; RND() = LFSR value / 32768, so 0 <= x < 1

; Returns PI in FLT A and FLT B for Radian/degree conversions
FLT_PI:
        JSR LD_PI_FUNC
        ; drop through
FLT_B_TO_A:
        JSR PUSH_FLT_B
        JSR POP_FLT_A ; must be JSR as routine cleans up return address
        RTS

; =============================================================================
; PUSH_FLT_A,B / POP_FLT_A,B -- save/restore a 4-byte float FLT_x on the
; hardware stack.
;
; Must be entered via JSR, not tail-called: each pops its own return
; address out of the way first, does the real push/pop, then pushes the
; address back before RTS.
;
; Entry Points: PUSH_FLT_A, PUSH_FLT_B, POP_FLT_A, POP_FLT_B
; Clobbers:     A, X, Y
; =============================================================================

PUSH_FLT_A: LDX #FLT_A + 3
            .DB $2C             ; BIT abs: swallows "LDX #FLT_B + 3"
PUSH_FLT_B: LDX #FLT_B + 3
            SEC                 ; C=1 indicates PUSH operation
            BRA DO_FLT

POP_FLT_A:  LDX #FLT_A
            .DB $2C             ; BIT abs: swallows "LDX #FLT_B"
POP_FLT_B:  LDX #FLT_B
            CLC                 ; C=0 indicates POP operation

DO_FLT:     PLA
            STA PFA_RL          ; Preserve return address LSB
            PLA
            STA PFA_RH          ; Preserve return address MSB
            LDY #4              ; Transfer 4 bytes for float
            BCS DO_PUSH

POPL:       PLA
            STA 0,X             ; Pop stack byte into ZP address X
            INX
            DEY
            BNE POPL
            BRA PRETA           ; Restore return address and RTS

DO_PUSH:
PSHL:       LDA 0,X             ; Read byte from ZP address X and push
            PHA
            DEX
            DEY
            BNE PSHL

PRETA:      LDA PFA_RH
            PHA
            LDA PFA_RL
            PHA
            RTS
      
; =============================================================================
; FLT_FLOOR -- round to zero i.e. 3.5 becomes 3, -3.5 becomes -3
;   Out: FLT_A = float(A) zero-extended to 16 bits
;   Clobbers: A,X,Y,T0 + whatever the called routine clobbers.
FLT_FLOOR:
         JSR FLT_TO_INT
        ; drop through
; =============================================================================
; FLT_FROM_INT / FLT_FROM_INT_B  --  convert a signed 16-bit integer to float
;
;   In:  T0 = signed 16-bit value
;   Out: FLT_A (FLT_FROM_INT) or FLT_B (FLT_FROM_INT_B) = float(T0)
;   Clobbers: A, X, T0, FLT_ER, FLT_SA
; =============================================================================
FLT_B_OFFSET = FLT_B - FLT_A ; page zero offset

FLT_FROM_INT:
         LDX #0
         .byte $2C             ; [OPT] BIT trick: assembles as BIT $A9xx,
FLT_FROM_INT_B:
         LDX #FLT_B_OFFSET
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

; =============================================================================
; SHARED UTILITY ROUTINES  --  used by both FLT_ADD and FLT_MUL
; =============================================================================
; ADD_A_B -- 24-bit addition: FLT_A = FLT_A + FLT_B
;   In:  FLT_A, FLT_B
;   Out: FLT_A = FLT_A + FLT_B; carry = carry out of bit 23 (mantissa overflow)
;   Clobbers: A, X
ADD_A_B: CLC
         LDX #2
ADDLP:   LDA FLT_A+1,X
         ADC FLT_B+1,X
         STA FLT_A+1,X
         DEX
         BPL ADDLP
         RTS

; SUB_A_B -- 24-bit subtraction: FLT_A = FLT_A - FLT_B
;   In:  FLT_A, FLT_B
;   Out: FLT_A = FLT_A - FLT_B; carry clear = borrow occurred
;   Clobbers: A, X
SUB_A_B: SEC
         LDX #2
SUBLP:   LDA FLT_A+1,X
         SBC FLT_B+1,X
         STA FLT_A+1,X
         DEX
         BPL SUBLP
         RTS

; SHR_A -- 32-bit right shift: carry -> FLT_A+1 -> FLT_A+2 -> FLT_A+3 -> FLT_DB
;   In:  FLT_A+1..+3, FLT_DB, carry (bit shifted in at the top)
;   Out: all four shifted right one bit
;   Clobbers: none (flags only)
SHR_A:   ROR FLT_A+1
         ROR FLT_A+2
         ROR FLT_A+3
         ROR FLT_DB
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
         LDX #3                 ; looped swap of FLT_A <-> FLT_B
FASWAP:  LDA FLT_A,X
         LDY FLT_B,X
         STA FLT_B,X
         STY FLT_A,X            ; STY zp,X saves 1 byte over TYA/STA
         DEX
         BPL FASWAP

FASG:    LDA FLT_A+1
         AND #$80
         STA FLT_SA
         LDA FLT_B+1
         AND #$80
         STA FLT_SB
         LDA #$80
         TSB FLT_A+1            ; restore hidden bits
         TSB FLT_B+1
         LDA FLT_A
         STA FLT_ER
         SEC
         SBC FLT_B
         CMP #25
         STZ FLT_DB
         BCS FANM               ; shift >= 25: B's mantissa is entirely gone
         TAX                    ; X = shift count
         BEQ FAOP
FABT:    LSR FLT_B+1             ; shift B right
         ROR FLT_B+2
         ROR FLT_B+3
         ROR FLT_DB
         DEX
         BNE FABT
FAOP:    LDA FLT_SA
         CMP FLT_SB
         BEQ FASM
         JSR SUB_A_B            ; 24-bit subtraction
         BCS FANM
         SEC                    ; borrow occurred: negate result
         LDA #0
         SBC FLT_DB
         STA FLT_DB
         LDX #2
NEGLP:   LDA #0                 ; 24-bit negation loop
         SBC FLT_A+1,X
         STA FLT_A+1,X
         DEX
         BPL NEGLP
         ORA FLT_A+2            ; check for zero
         ORA FLT_A+3
         BEQ FAZE
         LDA FLT_SA
         EOR #$80
         STA FLT_SA
         BRA FANM
FASM:    JSR ADD_A_B            ; 24-bit addition
         BCC FANM
         JSR SHR_A               ; handle carry overflow
         INC FLT_ER
         BEQ FAZE
FANM:    JMP NORM_PACK
FAZE:    ; drop through

; FLT_ZERO -- FLT_A = 0.0.  Clobbers: A, X.
FLT_ZERO:
        LDX #0 ; zp offset
        JMP F_ZERO      ; tail call

; FLT_MOD: FLT_A = FLT_A - FLT_B*trunc(FLT_A/FLT_B)
; =============================================================================
; FLT_MOD  --  FLT_A = FLT_A mod FLT_B  (truncating, C-style: result takes
;              the sign of the dividend)
;
;   In:  FLT_A = dividend, FLT_B = divisor
;   Out: FLT_A = FLT_A - FLT_B*trunc(FLT_A/FLT_B).  ?2 if FLT_B is 0.0
;   Clobbers: A, X, Y, FLT_A, FLT_B, and everything FLT_DIV/FLT_MUL/FLT_SUB do
; =============================================================================
FLT_MOD: 
        JSR PUSH_FLT_A        ; park FLT_A on hardware stack
        JSR PUSH_FLT_B        ; park FLT_B on hardware stack
        JSR FLT_DIV
        JSR FLT_FLOOR
        JSR POP_FLT_B
        JSR FLT_MUL
        JSR FLT_A_TO_B
        JSR POP_FLT_A         ; restore FLT_A
        ; drop through

; =============================================================================
; FLT_SUB  --  FLT_A = FLT_A - FLT_B (negates FLT_B and falls into FLT_ADD)
;
;   In/Out/Clobbers: as FLT_ADD; also permanently negates FLT_B's sign
; =============================================================================
FLT_SUB: JSR FLT_NEGATE_B
         JSR FLT_ADD
        ; drop through
; FLT_NEGATE / FLT_NEGATE_B -- flip the sign bit of FLT_A / FLT_B (no-op on
; zero, so -0.0 can't arise).  Clobbers: A.
FLT_NEGATE_B:
         LDA FLT_B
         BEQ FNBD
         LDA FLT_B+1
         EOR #$80
         STA FLT_B+1
FNBD:    RTS

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

; =============================================================================
; FLT_SQRT  --  FLT_A = sqrt(FLT_A), Newton-Raphson, 5 iterations
;
;   In:  FLT_A = S (operand)
;   Out: FLT_A = sqrt(S). Negative input is clamped to 0.0 (domain guard;
;        this library has no complex-number support).
;   Clobbers: A, X, Y, T_S, T_X, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE,
;             FLT_DB, FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
;
;   Initial guess is the classic "halve the biased exponent" trick: for
;   S = 1.m * 2^(E-128), sqrt(S) ~= 2^(E/2 - 64), i.e. new exponent
;   E' = E/2 + 64. 5 iterations of x_{n+1} = (x_n + S/x_n) / 2 (the "/2"
;   done cheaply via exponent decrement, valid since NORM_PACK always
;   leaves results normalised) is plenty for the 24-bit mantissa.
; =============================================================================
FLT_SQRT:
         LDA FLT_A
         BNE FSQ_NZ
         RTS                    ; S == 0: FLT_A already 0.0, nothing to do
FSQ_NZ:  LDA FLT_A+1
         BPL FSQ_OK
         BRA FLT_ZERO
FSQ_OK:  LDX #3                 ; T_S = S (preserved across all iterations)
FSQSV:   LDA FLT_A,X
         STA T_S,X
         DEX
         BPL FSQSV
         LDA FLT_A              ; initial guess: halve the biased exponent
         LSR                     ; (through the accumulator, not memory-direct --
         CLC                       ;  LSR on a zp operand never touches A/exponent
         ADC #64                    ;  math must happen in the accumulator)
         STA FLT_A
         LDY #5                 ; 5 Newton-Raphson iterations
NR_LOOP: LDX #3                 ; FLT_A currently holds x_n (the current guess)
NRSV:    LDA FLT_A,X            ; save x_n to both T_X (for later restore) and
         STA T_X,X               ; FLT_B (as FLT_DIV's divisor) in one pass
         STA FLT_B,X
         DEX
         BPL NRSV
         LDX #3                 ; FLT_A = S (dividend)
NRLD:    LDA T_S,X
         STA FLT_A,X
         DEX
         BPL NRLD
         PHY                    ; protect the iteration counter across FLT_DIV
         JSR FLT_DIV            ; FLT_A = S / x_n  (FLT_DIV clobbers FLT_B)
         LDX #3                 ; restore x_n into FLT_B from T_X
NRRB:    LDA T_X,X
         STA FLT_B,X
         DEX
         BPL NRRB
         JSR FLT_ADD            ; FLT_A = (S/x_n) + x_n
         DEC FLT_A              ; /2 via exponent decrement (result is normalised)
         PLY
         DEY
         BNE NR_LOOP
         RTS

; MUL_BY_TEN -- FLT_A = FLT_A * 10.  Clobbers: as FLT_MUL.
MUL_BY_TEN:
         JSR FLT_TEN_B
        ; drop through

; FLT_MUL: FLT_A = FLT_A * FLT_B  (24-iter shift-and-accumulate)
; =============================================================================
; FLT_MUL  --  FLT_A = FLT_A * FLT_B  (24-iteration shift-and-accumulate)
;
;   In:  FLT_A, FLT_B = operands
;   Out: FLT_A = product
;   Clobbers: A, X, Y, FLT_B, FLT_MA, FLT_MB, FLT_MC, FLT_SA, FLT_ER, FLT_DB
;
;   FLT_A (the multiplicand) is copied to FLT_MA/MB/MC and that copy is
;   shifted each iteration; FLT_B (the multiplier) is left untouched so the
;   shared ADD_A_B (FLT_A += FLT_B) can accumulate partial products directly.
;   SIGN_XOR stays a JSR here (not inlined) since FLT_DIV also calls it --
;   inlining would only grow this routine without shrinking FLT_DIV's copy.
; =============================================================================
FLT_MUL: LDA FLT_A
         BNE FMCKB
         RTS
FMCKB:   LDA FLT_B
         BNE FMNZ
         JMP FLT_ZERO
FMNZ:    LDA FLT_A              ; Er = A + B - 128 (XOR $80 == -128 mod 256)
         CLC
         ADC FLT_B
         EOR #$80
         STA FLT_ER
         JSR SIGN_XOR
         LDA #$80
         TSB FLT_A+1
         TSB FLT_B+1
         LDX #2                 ; copy A to MA..MC (multiplicand, gets shifted)
FM_CPY:  LDA FLT_A+1,X          ; and clear FLT_A+1..3 (accumulator)
         STA FLT_MA,X
         STZ FLT_A+1,X
         DEX
         BPL FM_CPY
         STZ FLT_DB
         LDY #24
FML:     LSR FLT_MA              ; shift multiplicand copy right
         ROR FLT_MB
         ROR FLT_MC
         BCC FMS
         JSR ADD_A_B            ; add fixed multiplier FLT_B into accumulator
FMS:     JSR SHR_A               ; shift accumulator right
         DEY
         BNE FML
         LDA FLT_A+1
         BMI FMPK
         ASL FLT_DB
         ROL FLT_A+3
         ROL FLT_A+2
         ROL FLT_A+1
         DEC FLT_ER
FMPK:    ; drop through

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

; DIV_BY_TEN -- FLT_A = FLT_A / 10.  Clobbers: as FLT_DIV.
DIV_BY_TEN:
         JSR FLT_TEN_B
        ; drop through

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
ERR_OV_J: LDA #ERR_OV
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

; =============================================================================
; FLT_PRINT  --  print FLT_A in decimal (up to 6 significant digits, trailing
;                zeros trimmed)
;
;   In:  FLT_A = value to print
;   Out: printed to the terminal, no trailing CRLF
;   Clobbers: A, X, Y, FLT_A, FLT_B, T0-T2, IBUF, FP_LIMIT
;
;   Algorithm: handle zero/sign, scale to [1,10), extract 6 digits, round,
;   strip trailing zeros, print with decimal point.  FLT_DE holds the
;   decimal exponent (saved in T2 during digit extraction, since FLT_DE
;   itself is clobbered by the FLT_TO_INT call used to grab each digit).
;
;   FP_LIMIT holds an EXCLUSIVE index limit (last-non-zero-digit index + 1,
;   or 0 if the whole fraction is zero) rather than the index itself -- that
;   lets both the "stop printing fraction digits" test and the "fraction is
;   entirely zero, skip the decimal point" case share one CPY/BCS test.
; =============================================================================
FLT_PRINT:
         LDA FLT_A
         BNE FPNZ
         LDA #'0'
         JMP PUTCH         ; tail-call for absolute zero

FPNZ:    LDA FLT_A+1
         BPL FPPS
         LDA #'-'
         JSR PUTCH
         JSR FLT_ABS

FPPS:    JSR PUSH_FLT_A    ; save original value
         STZ FLT_DE

FPDN:    JSR FLT_TEN_B
         JSR FLT_CMP
         INC              ; 65C02: accumulator increment (sets Z on $FF->$00)
         BEQ FPUP
         JSR DIV_BY_TEN
         INC FLT_DE
         BRA FPDN

FPUP:    LDA FLT_A
         CMP #$81          ; is FLT_A >= 1.0?
         BCS FPSC
         JSR MUL_BY_TEN
         DEC FLT_DE
         BRA FPUP

FPSC:    LDA FLT_DE
         STA T2
         LDX #0

FPDIG:   PHX               ; save digit index
         JSR FLT_TO_INT    ; T0 = int(FLT_A)
         LDA T0
         PHA               ; save digit value
         STZ T0+1
         JSR FLT_FROM_INT_B
         JSR FLT_SUB

         LDA FLT_A+1
         BPL FPCL          ; safe single-branch sign check: FLT_ZERO always
         JSR FLT_ZERO      ; clears FLT_A+1 too, so bit 7 clear also covers
                            ; the exact-zero case -- no separate BEQ needed
FPCL:    JSR MUL_BY_TEN
         PLA               ; restore digit
         PLX               ; restore index
         ORA #'0'
         STA IBUF,X
         INX
         CPX #7
         BNE FPDIG

FPRD:    LDA T2            ; restore exponent back to FLT_DE early
         STA FLT_DE
         LDA IBUF+6
         CMP #'5'
         BCC FPNRD
         LDX #5

FPRU:    INC IBUF,X
         LDA IBUF,X
         CMP #':'          ; did it roll past '9'?
         BCC FPNRD
         LDA #'0'
         STA IBUF,X
         DEX
         BPL FPRU
         LDA #'1'
         STA IBUF
         INC FLT_DE        ; increment exponent directly

FPNRD:   LDX #5
FPST:    LDA IBUF,X
         CMP #'0'
         BNE FPSTD
         DEX
         BPL FPST

FPSTD:   INX               ; X = index of last non-zero digit + 1
         STX FP_LIMIT      ; save as the exclusive fraction-digit limit

         LDA FLT_DE
         BMI FPLT1

         INC              ; A = integer digit count
         TAX               ; keep loop counter in X
         LDY #0

FPIT:    LDA #'0'          ; pad with zeroes if Y >= 6
         CPY #6
         BCS FPIT2
         LDA IBUF,Y
         INY
FPIT2:   JSR PUTCH
         DEX
         BNE FPIT

FPFR:    CPY #6
         BCS FPEND
         CPY FP_LIMIT      ; compare to the exclusive fraction limit
         BCS FPEND         ; Y >= FP_LIMIT: nothing left to print (also
                            ; catches "fraction is all zero", FP_LIMIT==0)
FPFRGO:  LDA #'.'
         JSR PUTCH

FPFRL:   LDA IBUF,Y
         JSR PUTCH
         INY
         CPY FP_LIMIT
         BCS FPEND
         CPY #6
         BCC FPFRL
         ; fall through straight to FPEND

FPEND:   JSR POP_FLT_A         ; restore FLT_A (kept as JSR+RTS, NOT a tail
         RTS                   ; call -- POP_FLT_A's trampoline requires its
                                ; own fresh return address from being JSR'd)

FPLT1:   LDA #'0'
         JSR PUTCH
         LDA #'.'
         JSR PUTCH
         LDA FLT_DE
         EOR #$FF          ; fast calculation of leading zeroes
         BEQ FPLZD
         TAX
FPLZ:    LDA #'0'
         JSR PUTCH
         DEX
         BNE FPLZ
FPLZD:   LDY #0
         BRA FPFRL            ; reuse FPFRL instead of a duplicate loop


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
        ; drop through
; FLT_NEGATE / FLT_NEGATE_B -- flip the sign bit of FLT_A / FLT_B (no-op on
; zero, so -0.0 can't arise).  Clobbers: A.
FLT_NEGATE:
         LDA FLT_A
         BEQ FND
         LDA FLT_A+1
         EOR #$80
         STA FLT_A+1
FND:     
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

; =============================================================================
; FLT_ATAN_CORE  --  FLT_A = atan(FLT_A), RADIANS, single-term Pade approx
;   x/(1+0.28086*x^2). Accurate to ~0.005 rad ONLY for |x| <= 1; the public
;   FLT_ATAN wrapper (below) range-reduces so this is never called outside
;   that domain.
;
;   In:  FLT_A = x  (|x| <= 1)
;   Out: FLT_A = atan(x) approximation, radians
;   Clobbers: A, X, Y, T0, T1, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DB, FLT_MA,
;             FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
; =============================================================================
FLT_ATAN_CORE:
         JSR PUSH_FLT_A        ; stack: [x]
         JSR FLT_A_TO_B        ; FLT_B = x
         JSR FLT_MUL           ; FLT_A = x^2
         LDX #IDX_ATANCOEF
         JSR FLT_LDCONST_B     ; FLT_B = 0.28086
         JSR FLT_MUL           ; FLT_A = 0.28086 * x^2
         LDX #IDX_ONE
         JSR FLT_LDCONST_B     ; FLT_B = 1.0
         JSR FLT_ADD           ; FLT_A = 1 + 0.28086*x^2   [denominator]
         JSR FLT_A_TO_B        ; FLT_B = denominator
         JSR POP_FLT_A         ; FLT_A = x
         JMP FLT_DIV           ; FLT_A = x / denominator

; =============================================================================
; FLT_ASIN  --  FLT_A = asin(FLT_A), RADIANS.  asin(x) = atan(x/sqrt(1-x^2))
;
;   Domain-checked (v2.6): |x| > 1 raises ?2 (genuinely undefined). At
;   exactly |x| = 1, 1-x^2 is exactly 0.0 in MBF4 (no rounding involved),
;   so sqrt(1-x^2) = 0.0 and the old code divided x/0.0 -- spurious ?2 on
;   a perfectly valid, finite input (asin(+-1) = +-pi/2 exactly). Fixed by
;   checking the sqrt result before dividing and returning +-pi/2 directly
;   when it's exactly zero, instead of dividing into it.
;   Domain check tests the SIGN of (1.0-x^2) directly rather than calling
;   FLT_CMP: FLT_CMP's own FLT_SUB call negates FLT_B in place and never
;   restores it (its docstring claims FLT_A/FLT_B are both preserved --
;   only FLT_A actually is), which silently corrupted x^2 for the sqrt
;   step below in an earlier draft of this fix. Testing (1.0-x^2)'s sign
;   directly avoids FLT_CMP altogether and reuses the same subtraction
;   FLT_SQRT needs anyway -- no double computation, no borrowed routine
;   with a stale doc comment to trust.
;   Clobbers: as FLT_SQRT/FLT_ATAN combined, plus the hardware stack (one
;   extra transient byte via PHA/PLA in the |x|==1 branch only)
; =============================================================================
FLT_ASIN:
         JSR PUSH_FLT_A         ; stack: [x] (need signed x back for the
                                ;  final divide/return; POP_FLT_A restores
                                ;  it further down)
         JSR FLT_A_TO_B         ; FLT_B = x
         JSR FLT_MUL            ; FLT_A = x^2
         JSR FLT_A_TO_B         ; FLT_B = x^2
         LDX #IDX_ONE
         JSR FLT_LDCONST        ; FLT_A = 1.0
         JSR FLT_SUB            ; FLT_A = 1.0 - x^2 (negative iff |x| > 1)
         LDA FLT_A+1
         BPL ASIN_INDOMAIN      ; sign bit clear: 1.0-x^2 >= 0, in domain
         JSR POP_FLT_A          ; balance PUSH_FLT_A's frame before erroring
         JMP ERR_OV_J           ; 1.0-x^2 < 0: |x| > 1, genuinely undefined
ASIN_INDOMAIN:
         JSR FLT_SQRT            ; FLT_A = sqrt(1-x^2); exactly 0 at |x|==1
         JSR FLT_A_TO_B         ; FLT_B = sqrt(1-x^2)
         JSR POP_FLT_A          ; FLT_A = x (original, signed, popped)
         LDA FLT_B              ; is sqrt(1-x^2) exactly 0.0? (exponent byte)
         BNE ASIN_NORMAL        ; nonzero: normal path, divide then atan
         LDA FLT_A+1            ; zero: |x|==1 exactly -- asin(x)=sign(x)*pi/2
         AND #$80
         PHA                    ; stash x's sign (cheaper than T2 here: only
                                 ;  needed across one JSR, not the whole
                                 ;  routine, so PHA/PLA beats STA/LDA zp)
         LDX #IDX_PI_2
         JSR FLT_LDCONST        ; FLT_A = pi/2
         PLA
         BEQ ASIN_RTS           ; x >= 0: +pi/2 is correct
         LDA FLT_A+1
         ORA #$80
         STA FLT_A+1            ; x < 0: -pi/2
ASIN_RTS: RTS
ASIN_NORMAL:
         JSR FLT_DIV            ; FLT_A = x / sqrt(1-x^2)
        ; drop through
; =============================================================================
; FLT_ATAN  --  FLT_A = atan(FLT_A), RADIANS, valid for any x
;
;   In:  FLT_A = x
;   Out: FLT_A = atan(x), radians
;   Clobbers: A, X, Y, T0, T1, T2, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE,
;             FLT_DB, FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
;
;   FLT_ATAN_CORE's Pade approximation is only valid for |x| <= 1. For
;   |x| > 1, range-reduce via atan(x) = sign(x)*pi/2 - atan(1/x) (radians;
;   1/x has magnitude < 1 and the same sign as x, so atan(1/x) is computed
;   by the core directly -- verified: for x=-2, atan(-2)=-1.1071 rad, and
;   -pi/2 - atan(-0.5) = -1.5708 - (-0.4636) = -1.1072, matches).
; =============================================================================
FLT_ATAN:
         LDA FLT_A+1
         AND #$80
         STA T2                ; T2 = original sign bit of x (0 or $80)
         LDA FLT_A+1
         AND #$7F
         STA FLT_A+1           ; FLT_A = |x|
         LDX #IDX_ONE
         JSR FLT_LDCONST_B     ; FLT_B = 1.0
         JSR FLT_CMP           ; A = -1/0/+1 : |x| vs 1.0 (FLT_A preserved=|x|)
         CMP #1
         BEQ FA_BIG            ; |x| > 1: range-reduce

         LDA FLT_A+1           ; |x| <= 1: restore sign, run core directly
         ORA T2
         STA FLT_A+1           ; FLT_A = x (signed)
        ;  JMP FLT_ATAN_CORE     ; tail: FLT_A = atan_core_rad(x); RTS
        JMP FLT_ATAN_CORE     ; tail: FLT_A = atan_core_rad(x); RTS
                                ; (was BRA -- FLT_ASIN's growth pushed this
                                ;  out of branch range; JMP always fits)
FA_BIG:  LDA FLT_A+1           ; FLT_A currently = |x| (preserved by FLT_CMP)
         ORA T2
         STA FLT_A+1           ; FLT_A = x (signed)
         JSR FLT_A_TO_B        ; FLT_B = x
         LDX #IDX_ONE
         JSR FLT_LDCONST       ; FLT_A = 1.0
         JSR FLT_DIV           ; FLT_A = 1/x (same sign as x, |1/x| < 1)
         JSR FLT_ATAN_CORE     ; FLT_A = atan_core_rad(1/x)
         JSR FLT_A_TO_B        ; FLT_B = atan_core_rad(1/x)
         LDX #IDX_PI_2
         JSR FLT_LDCONST       ; FLT_A = pi/2
         LDA T2
         BEQ FA_SUB            ; positive x: keep +pi/2
         LDA FLT_A+1
         ORA #$80
         STA FLT_A+1           ; negative x: -pi/2
FA_SUB:  JMP FLT_SUB            ; FLT_A = (+-pi/2) - atan_core_rad(1/x)

; =============================================================================
; FLT_ACOS  --  FLT_A = acos(FLT_A), RADIANS.  acos(x) = pi/2 - asin(x)
;   Clobbers: as FLT_ASIN
; =============================================================================
FLT_ACOS:
         JSR FLT_ASIN           ; FLT_A = asin(x), radians
         JSR FLT_A_TO_B         ; FLT_B = asin(x)
         LDX #IDX_PI_2
         JSR FLT_LDCONST        ; FLT_A = pi/2
         JMP FLT_SUB            ; FLT_A = pi/2 - asin(x)

; ===========================================================================
; SIN(x)/COS(x), x in RADIANS (float, any range/sign) -- float-native
; polynomial implementation,
;
; Pipeline: FLT_A (radians) --abs+mod 2pi--> [0,2pi)
;           --fold--> [0,pi] --fold--> [0,pi/2] --polynomial--> sin
;           --reapply sign-->  FLT_A
; ===========================================================================

; =============================================================================
; FLT_COS  --  FLT_A = cos(FLT_A), RADIANS.  cos(x) = sin(pi/2-x)
;   Clobbers: as FLT_SIN
; =============================================================================
FLT_COS:
         JSR FLT_A_TO_B         ; FLT_B = x
         LDX #IDX_PI_2
         JSR FLT_LDCONST        ; FLT_A = pi/2
         JSR FLT_SUB            ; FLT_A = pi/2 - x
        ; drop through
; =============================================================================
; FLT_SIN  --  FLT_A = sin(FLT_A), RADIANS (any magnitude/sign)
;
;   In:  FLT_A = angle, radians
;   Out: FLT_A = sin(angle), accurate to ~0.0002
;   Clobbers: A, X, Y, T0, T1, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE, FLT_DB,
;             FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL, PFA_RL/PFA_RH
;
;   sin(x) ~= x*(1 - x^2*(0.16605 - 0.00761*x^2)), valid for x in [0,pi/2]
;   (max abs error ~0.000164 there). Range reduction folds any input into
;   that domain first via the standard abs -> mod 2pi -> fold-to-[0,pi]
;   (via sin(x)=sin(pi-x)... actually via 2pi-periodicity + the pi-x
;   identity) -> fold-to-[0,pi/2] (via sin(x)=sin(pi-x)) chain.
; =============================================================================
FLT_SIN:
         LDA FLT_A+1
         AND #$80
         PHA                   ; stash original sign
         LDA FLT_A+1
         AND #$7F
         STA FLT_A+1           ; FLT_A = |x| (radians)

         JSR LD_PI_FUNC        ; FLT_B = pi
         INC FLT_B              ; FLT_B = 2*pi (NORM_PACK always leaves
                                 ;               constants normalised)
         JSR FLT_MOD           ; FLT_A = |x| mod 2*pi (already non-negative
                                ;  in, so no C-style-negative-remainder fixup
                                ;  needed out)

         JSR LD_PI_FUNC         ; fold [0,2pi) -> [0,pi]: if (x mod 2pi) > pi,
                                 ;  use (x mod 2pi) - pi and flip the sign
                                 ;  we'll apply at the end (sin(x)=-sin(x-pi))
         JSR FLT_SUB            ; FLT_A = (x mod 2pi) - pi
         LDA FLT_A+1
         BPL FS_GT_PI
         JSR LD_PI_FUNC          ; <= pi: undo the subtraction (add pi back)
         JSR FLT_ADD
         BRA FS_FOLD2
FS_GT_PI: PLA
         EOR #$80
         PHA                    ; flip the stashed sign

FS_FOLD2:                       ; fold [0,pi] -> [0,pi/2]: sin(x)=sin(pi-x)
         JSR PUSH_FLT_A         ; park x (was: explicit 4-byte save to T_X --
                                 ; FLT_SUB's FLT_B side effects aren't
                                 ; guaranteed byte-exact beyond the documented
                                 ; "restored" primitives, so x itself is
                                 ; parked, not recomputed)
         LDX #IDX_PI_2
         JSR FLT_LDCONST_B          ; FLT_B = pi/2
         JSR FLT_SUB                  ; FLT_A = x - pi/2
         LDA FLT_A+1
         BMI FS_LE_PI2                 ; x < pi/2: discard this, restore x
         JSR FLT_A_TO_B                 ; x >= pi/2: new_x = pi/2 - (x-pi/2)
         JSR POP_FLT_A                    ; discard parked x -- FLT_A is
                                           ; about to be overwritten below,
                                           ; but the pop must still happen to
                                           ; keep PUSH_FLT_A's frame balanced
         LDX #IDX_PI_2                    ;          = pi - x
         JSR FLT_LDCONST
         JSR FLT_SUB
         BRA FS_POLY
FS_LE_PI2:
         JSR POP_FLT_A          ; x < pi/2: restore original x

FS_POLY:                        ; sin(x) ~= x*(1 - x^2*(C1 - C2*x^2))
         JSR PUSH_FLT_A         ; stack: [x]      (was: T_S = x)
         JSR FLT_A_TO_B
         JSR FLT_MUL            ; FLT_A = x^2
         JSR PUSH_FLT_A         ; stack: [x, x^2] (was: T_X = x^2)
         LDX #IDX_C2_SIN
         JSR FLT_LDCONST_B      ; FLT_B = 0.00761
         JSR FLT_MUL            ; FLT_A = 0.00761 * x^2
         JSR FLT_A_TO_B
         LDX #IDX_C1_SIN
         JSR FLT_LDCONST        ; FLT_A = 0.16605
         JSR FLT_SUB            ; FLT_A = 0.16605 - 0.00761*x^2
         JSR POP_FLT_B          ; FLT_B = x^2 (popped). stack: [x]
         JSR FLT_MUL            ; FLT_A = x^2 * (0.16605 - 0.00761*x^2)
         JSR FLT_A_TO_B
         LDX #IDX_ONE
         JSR FLT_LDCONST        ; FLT_A = 1.0
         JSR FLT_SUB            ; FLT_A = 1.0 - x^2*(...)
         JSR POP_FLT_B          ; FLT_B = x (popped). stack: empty
         JSR FLT_MUL            ; FLT_A = x * (1.0 - x^2*(...)) = sin(x)

         PLA                    ; retrieve final sign
         EOR FLT_A+1
         STA FLT_A+1
         RTS

; =============================================================================
; FLT_TAN  --  FLT_A = tan(FLT_A), RADIANS.  tan(x) = sin(x)/cos(x)
;
;   In:  FLT_A = angle, radians
;   Out: FLT_A = tan(angle).  ?2 (division by zero) if cos(x) rounds to
;        exactly 0.0 (x an exact multiple of pi/2) -- FLT_DIV raises that
;        directly and does not return here, same as any other /0.
;   Clobbers: as FLT_SIN/FLT_COS, plus FLT_DIV's own (FLT_B, FLT_DVH/M/L),
;             plus FLIM (see below)
;
; =============================================================================
FLT_TAN: JSR PUSH_FLT_A          ; park x across the FLT_SIN call
         JSR FLT_SIN             ; FLT_A = sin(x)
         LDX #3
TNSV:    LDA FLT_A,X
         STA FLIM,X              ; FLIM = sin(x) (borrowed scratch, see above)
         DEX
         BPL TNSV
         JSR POP_FLT_A           ; FLT_A = x (restored)
         JSR FLT_COS             ; FLT_A = cos(x)
         JSR FLT_A_TO_B          ; FLT_B = cos(x) (divisor; last FLT_B write
                                  ; before FLT_DIV, so this one sticks)
         LDX #3
TNRS:    LDA FLIM,X
         STA FLT_A,X             ; FLT_A = sin(x) (restored from FLIM)
         DEX
         BPL TNRS
         JMP FLT_DIV             ; FLT_A = sin(x)/cos(x) = tan(x); tail call

; =============================================================================
; FLT_CONST table  --  ROM-resident 4-byte MBF4 constants for ATAN/ASIN/ACOS,
;   loaded via FLT_LDCONST (-> FLT_A) / FLT_LDCONST_B (-> FLT_B). Values
;   computed to nearest MBF4 representation (round-to-nearest mantissa).
; =============================================================================

; FLT_CONST_PTR -- point T0 at constant X's 4 ROM bytes. All constants
;   (C_ATANCOEF..C_32768 above) must to stay within One page ($FFxx
;   as of writing). If the table overlaps a page boundary this silently
;   breaks. Check LST file when adding more constants.
;   Clobbers: A, T0.
FLT_CONST_PTR:
         LDA CTAB_LO,X
         STA T0
         LDA #>CTAB_LO
         STA T0+1
         RTS

; FLT_LDCONST / FLT_LDCONST_B -- In: X=const index (IDX_*).
;   FLT_LDCONST:   Out: FLT_A = constant[X]
;   FLT_LDCONST_B: Out: FLT_B = constant[X]
;
;   Clobbers: A, X, Y, T0, T1
FLT_LDCONST:
         LDA #<FLT_A
         .DB $2C               ; BIT-trick: swallows FLT_LDCONST_B's "LDA #<FLT_B"
FLT_LDCONST_B:
         LDA #<FLT_B
         STA T1
         STZ T1+1
         JSR FLT_CONST_PTR     ; T0 = source ptr (X = const index, untouched here)
         LDY #3
FLCLP:   LDA (T0),Y
         STA (T1),Y
         DEY
         BPL FLCLP
         RTS

; LD_PI_FUNC -- FLT_B = pi. 
;   Out: FLT_B = pi.  Clobbers: A, X, Y, T0, T1
LD_PI_FUNC:
         LDX #IDX_PI_2
         JSR FLT_LDCONST_B     ; FLT_B = pi/2
         INC FLT_B             ; FLT_B = pi (exponent-INC = *2)
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
; indices
IDX_ATANCOEF = 0
IDX_ONE      = 1
IDX_PI_2     = 2
IDX_C1_SIN   = 3
IDX_C2_SIN   = 4
IDX_32768    = 5
IDX_TEN      = 6

CTAB_LO: .DB <C_ATANCOEF,<C_ONE,<C_PI_2,<C_C1_SIN,<C_C2_SIN,<C_32768
C_ATANCOEF: .DB $7F,$0F,$CC,$E2  ; 0.28086 (FLT_ATAN_CORE Pade coefficient)
C_ONE:      .DB $81,$00,$00,$00  ; 1.0
C_PI_2:     .DB $81,$49,$0F,$DB  ; 1.5707963 (pi/2, radians)
C_C1_SIN:   .DB $7E,$2A,$09,$03  ; 0.16605 (FLT_SIN polynomial coefficient)
C_C2_SIN:   .DB $79,$79,$5D,$4F  ; 0.00761 (FLT_SIN polynomial coefficient)
C_32768:    .DB $90,$00,$00,$00  ; 32768.0 (RND's LFSR->float divisor)

ROMEND: ; audit

        ; vectors
         .ORG $FFFC
         .DW INIT
         .DW IRQ_HANDLER
