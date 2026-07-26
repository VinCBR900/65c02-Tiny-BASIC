; =============================================================================
; miniBASIC 65C02 v3.4
; Copyright (c) 2026 Vincent Crabtree, MIT License
;
; 4KB Float BASIC (MBF4) for the 65C02.
;
; Statements accepted
;   END  FOR..TO..STEP  FREE  GOSUB  GOTO  IF..THEN  INPUT  LET  LIST [n,m]
;   NEW  NEXT  POKE  PRINT [TAB(n)][;][CHR$(n)]  REM  RETURN  RUN
;
; Expressions:
;   + - * / % ^   = < > <= >= <>   unary -
;   ABS(flt)  ACOS(flt)  ASIN(flt)  ATN(flt)  COS(rad)  EXP(flt)  FLOOR(flt)   
;   FREE  LN(flt)  PEEK(addr)  PI  RND  SIN(rad)  TAN(rad)  SQR(flt)  USR(addr)
;   26 single letter variables, A-Z 
;
; Numbers      : MBF4 float, ~6-7 significant decimal digits (see format below)
; String print : "literals", `;`, TAB(n) and CHR$() only; no string variables
;
; Trig is RADIANS-native throughout (SIN/COS/TAN/ATN/ASIN/ACOS all take/return
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
; Number literal Format: Require a leading digit before the decimal point -
;   "0.5" works, ".5" does not (parses as 0).
;   Scientific notation is NOT supported - the "E..." suffix is silently 
;   ignored, so "1E10" parses as plain "1". Type magnitudes in full.
;
; ASIN(x)/ACOS(x) for |x| >= 1 saturate to the boundary (+/-PI/2 for ASIN,
;   0/PI for ACOS) rather than erroring -- this includes the mathematically
;   exact |x|==1 case and the out-of-domain |x|>1 case.
;
; SQRT(negative) clamps to 0.0 (no complex-number support).
;
; LN(x) for x<=0 raises a "?2" domain error .
;
; EXP(x) for |x| too large to fit the internal exponent scratch byte
;   (roughly |x| > 88, i.e. beyond this float format's representable range
;   in either direction) raises a "?2" error.
;
; X^Y is computed as EXP(Y*LN(X)):
;   - X must be positive; X<=0 raises LN's "?2" domain error, negative base 
;     not supported e.g. (-2)^2.
;   - Binds tighter than * / % (proper BODMAS/PEMDAS) and is right-
;     associative, so "2*3^2"=18 and "2^3^2"=512, matching convention.
;   - Inherits EXP's overflow/underflow "?2" error for extreme results.
;
; SIN/COS accurate to ~0.0002 rad on their core polynomial domain (see
;   FLT_SIN/FLT_COS headers). Range reduction (mod 2*PI) itself breaks down
;   for |x| gtr-or-eq ~205,887 (32767 * 2*PI) -- FLT_MOD's FLOOR step
;   saturates its 16-bit intermediate there, producing garbage well outside
;   [-1,1] beyond that magnitude.
;
; Input buffer is 41 bytes, truncated at IBUF_MAX - each keypress past the 
;   limit sounds BELL ($07) but is still echoed. The excess chars
;   are still discarded (X stops advancing), just with an audible signal.
;
; TAB(n) and CHR$(n) are only valid on a PRINT line. Both accept expressions but
;   TAB prints n spaces, not jumps to column n. TAB(n) for n<=0 prints nothing
;   TAB(n) for n>255 wraps mod 256.
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
; v3.4 (2026-07) - 10 bytes free
;   - RESTORED: X^Y power operator, this time with correct BODMAS/PEMDAS
;     precedence - binds tighter than * / %, right-associative 
;   - DEDUPED: E1_RHS -- shared "park left, consume operator, parse right
;     via EXPR1P, GET_RIGHT to combine" glue, previously duplicated between
;     EXPR1's E1MD (*/ %) and EXPR1P's own recursive ^ case (found via
;     asmdup.py). +5 bytes. Must be entered via JSR+RTS, never a tail-call
;     JMP into GET_RIGHT -- GET_RIGHT/PUSH_FLT_A/POP_FLT_A rely on stealing
;     a genuine JSR return address for their park/restore trick; a JMP
;     doesn't provide one, and an earlier attempt at this exact extraction
;     used JMP and silently corrupted FLT_MUL's first real call, confirmed
;     via full regression before landing the corrected version.
;
; v3.3 (2026-07) - 42 bytes free
;   - ADDED: "Hypnotic Eye" showcase section (lines 262-289) -- a logarithmic
;     ripple stress-testing SQRT/SIN/EXP/LN together, including a deliberate
;     LN(0)-avoidance guard (D<0.05 check) at the ripple's exact center.
;     RAM-resident showcase text only; no ROM code changed, no byte-budget
;     impact.
;   - Refactor for size:
;       - NEG16 -- shared 16-bit negate, previously duplicated in FLT_TO_INT
;       - CALC_INT_LN2 -- shared "float(staged int)*ln(2)" step
;
; v3.2 (2026-07) - 21 bytes free
;   - Restored TAN function, modified DO_PRINT for TAB vs TAN.
;   - Deleted POW `^` due to incorrect Operater precidence no space to fix
;     at the time, and limited range that could catch you out.
;   - Cleaned up Page Zero for stale entries - 16 zp bytes free for expansion. 
;
; v3.1 (2026-07) - 34 bytes free
;   - Refactored MATCH_DISPATCH/MTCHKW for a merged UNI_TAB/FUNC_TAB
;     keyword+jump table (4 bytes/entry, keyword chars inline).
;
; v3.0 (2026-07) - 0 bytes free
;   - FIXED: ASIN/ACOS(+/-1) no longer crash with a "?2" divide-by-zero --
;     the x/sqrt(1-x^2) identity's 0/0 boundary case now returns +/-PI/2
;     directly. |x|>1 now also saturates to the same boundary
;   - FIXED: FLT_SQRT negative input clamps to 0.0 corrected
;   - FIXED: TAB(n) for negative n now correctly prints nothing 
;   - ADDED: domain guard on LN(x<=0) -- raises "?2" instead of returning a
;     large nonsense value.
;   - ADDED: range guard on EXP(x) -- raises "?2" for |x| beyond what the
;     8-bit EXP_K scratch byte can hold, instead of silently wrapping.
;   - ADDED: X^Y power operator via EXP(Y*LN(X)), same precedence as * / % to
;     fit ROM, Base must be >=0 (No negative or zero base). No space to fix. 

; v2.15 (2026-07) - 34 bytes free
;   - Removed TAN() to reclaim ROM space; users can implement it via SIN()/COS().
;   - Restored FLT_SQRT using exp(0.5*ln x) identity with zero and unit guards.
;   - Restored FLT_ASIN/ACOS atan(x/sqrt(1-x^2)) for inputs where |x| < 1.
;
; v2.14WIP (2026-07)
;   - Extracted the GET_RIGHT tail-pair helper to optimize common register-restoration sequences.
;   - Upgraded ATAN to a degree-3 polynomial using shared Horner evaluation, significantly improving accuracy and reducing code size.
;
; v2.13WIP (2026-07)
;   - Extracted HORNER_ODD, a shared odd-polynomial evaluator, to eliminate duplicated evaluation glue.
;   - Split HORNER_EVAL to allow table pointers to survive squaring operations.
;   - Converted SIN to use Horner method
;
; v2.12WIP (2026-07)
;   - Extracted LD1_ADD_B to share float addition logic between FLT_LN and FLT_ATAN_CORE.
;
; v2.11WIP (2026-07)
;   - Fixed a critical FLT_MUL bug caused by incorrect fall-through placement during earlier refactoring.
;   - Fixed an off-by-one indexing error in CTAB_LO that corrupted exponential evaluations.
;   - Refactored HORNER_EVAL to accept table pointers in A/X for improved efficiency.
;
; v2.10WIP (2026-07)
;   - Added HORNER_EVAL for generic table-driven polynomial evaluations.
;   - Added FLT_LN and FLT_EXP keywords using polynomial and exponent-mantissa reductions.
;   - Temporarily stubbed FLT_SQRT, FLT_ASIN, and FLT_ACOS to manage ROM headroom.
;   - Extracted shared mantissa shifting and keyword disambiguation routines.
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
;   - Audited TAN() accuracy and behavior at asymptotes, confirming division-by-zero is an
;     expected result for undefined inputs, confirms  fit for general use.
;   - Replaced DEG(rad) function with general PI constant function for space. 
;
; v2.5 (Jul 2026) — Duplicate Elimination, GETLINE Audits & Cleanups
;   - ADDED: BELL ($07) audible feedback on GETLINE buffer overflow.
;   - OPTIMIZED: POP_FLT_B epilogue duplicated code replaced with BRA PRET.
;   - CLEANUP: Stale header notes removed; statement summary updated for DO_LIST.
;
; v2.4 (Jul 2026) — Code Golfing & Range Feature Additions
;   - ADDED: DO_LIST range support (LIST n,m) using persistent 16-bit bounds.
;   - REFACTORED: DO_POKE inline body promoted to shared GET_TWO_ARGS routine.
;   - OPTIMIZED: FLT_LDCONST and FLT_LDCONST_B merged via BIT-trick.
;   - OPTIMIZED: Extracted LD_PI_B helper to factor out duplicated sequences 
;     in FLT_SIN.
;   - OPTIMIZED: FLT_SIN RAM-buffer save/restore replaced with stack 
;     trampolines (PUSH_FLT_A, POP_FLT_B).
;
; v2.3 (Jul 2026) — 65C02 Opcode Pass & TAN Function
;   - ADDED: TAN via FN_TAB, computed as sin(x)/cos(x).
;   - OPTIMIZED: replaced JMPs with 65c02 BRAs and fixed PHY/PLY in FLT_SQRT.
;   - FIXED: FLT_TAN float clobbering bug by stashing sin(x) in FLIM.
;   - FIXED: DPTB execution path for TAN(x) to support continued expressions.
;
; v2.2 (Jul 2026) — Float Math & Print Optimizations
;   - OPTIMIZED: Extracted shared ADD_A_B/SUB_A_B/SHR_A loops for FLT_ADD/FLT_MUL.
;   - OPTIMIZED: FLT_MUL exponent calculation simplified via EOR $80.
;   - OPTIMIZED: DO_FOR error exits unified via BIT-trick daisy chain.
;   - OPTIMIZED: DO_NEXT limit-copy extracted to CPY_FRM_FLTB.
;   - OPTIMIZED: FLT_PRINT logic streamlined, renaming FP_LASTNZ to FP_LIMIT.
;   - FIXED: Branch-range bugs in shared zero-trampolines.
;
; v2.1 (Jul 2026) — Function Handlers & Table Cleanups
;   - REFACTORED: PEEK and USR extracted into FLT_PEEK/FLT_USR handlers via FN_TAB.
;   - OPTIMIZED: DO_LET subroutine call converted to a tail call (JMP).
;   - OPTIMIZED: FLT_CONST_PTR CTAB_HI table removed; hardcoded high byte used.
;
; v2.0 (Jul 2026) — Radians-Native Trig & Function Dispatch
;   - CHANGED: SIN/COS switched from degrees to radians.
;   - ADDED: DEG(rad) function to convert radians back to degrees.
;   - ADDED: ATN(x), ASIN(x), and ACOS(x) wired as recognized keywords.
;   - REFACTORED: EXPR2 function dispatch consolidated into shared FN_TAB/FN_DISPATCH.
;   - FIXED: Tail-jump return address stack leak in FN_DISPATCH.
;
; v1.9 (Jul 2026) — SQR() Function & Critical RND Fix
;   - ADDED: SQR() wired as a recognized keyword.
;   - FIXED (CRITICAL): RND() crash/out-of-bounds bug caused by a missing 
;     FLT_32768_B constant loader accidentally removed in v1.7.
;
; v1.8 (Jul 2026) — Tail-Call & Fallthrough Optimizations
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
IBUF_MAX = 40               ; Max number of char input buffer
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
; GOSUB/RETURN 4-byte frame push/pop loop in DO_GOTO/DO_REM_CHK requires it

        .ORG 0
        ; We need a hack for Kowalski as it executes from zero
        JMP INIT
        NOP
;T0:       .RS 2              ; 16-bit: primary scratch word / expression result
;T1:       .RS 2              ; 16-bit: secondary scratch word / MTCHKW byte scratch
T0        = 0                 ; Kludge to overwite Kowalski trampoline   
T1        = 2
T2:       .RS 2              ; 16-bit: tertiary scratch word / STMT jump target
IP:       .RS 2              ; 16-bit: interpreter/parse pointer
CURLN:    .RS 2              ; 16-bit: currently-executing line number
PE:       .RS 2              ; 16-bit: program end (one past last byte)
LP:       .RS 2              ; 16-bit: line pointer / MTCHKW's IP-backup scratch
RUN:      .RS 1              ; 8-bit:  run flag ($00 = immediate, $FF = running)
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
LSLO:     .RS 2              ; 16-bit: DO_LIST range low bound (dedicated --
                             ;  T0-T2 all get clobbered by PRT16 inside the
                             ;  listing loop, so these can't live there)
LSHI:     .RS 2              ; 16-bit: DO_LIST range high bound
PTR:      .RS 2              ; 16-bit: coefficient-table pointer for HORNER_EVAL
HORNER_N: .RS 1              ; 8-bit: HORNER_EVAL's loop counter (kept off X --
                             ;  FLT_MUL/FLT_ADD both clobber X)
LN_M:     .RS 4              ; 4-byte: FLT_LN's mantissa scratch (dedicated,
                             ;  not shared with HORNER_EVAL -- that collision
                             ;  is exactly the bug FP_TMP caused earlier)
EXP_K:    .RS 1              ; 8-bit: FLT_EXP's integer k (assumes |k| fits
                             ;  in a signed byte -- true for any BASIC-
                             ;  reachable float; no floor-adjust needed since
                             ;  FLT_EXP uses plain truncation, so k never
                             ;  needs 16-bit arithmetic)
IBUF:     .RS 41             ; Line input line buffer ()
 
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
         .DB $F1,$00,"PRINT ",$22,"=== LN/EXP Identity ===",$22,$0D
         .DB $F2,$00,"PRINT ",$22,"EXP(LN(2))=",$22,";EXP(LN(2));",$22," LN(EXP(2))=",$22,";LN(EXP(2))",$0D
         .DB $F3,$00,"PRINT ",$22,"=== Power Math (X^Y) ===",$22,$0D
         .DB $F4,$00,"PRINT ",$22,"2^8 = EXP(8*LN(2)) = ",$22,";EXP(8*LN(2))",$0D
         .DB $09,$01,"PRINT ",$22,"=== HYPNOTIC EYE - LN/EXP/TRIG STRESS TEST ===",$22,$0D
         .DB $0A,$01,"FOR R=0 TO 26",$0D
         .DB $0B,$01,"LET Y=(R-13)/10",$0D
         .DB $0C,$01,"LET L=0",$0D
         .DB $0D,$01,"FOR C=0 TO 60",$0D
         .DB $0E,$01,"LET X=(C-30)/20",$0D
         .DB $0F,$01,"LET D=SQRT(X*X+Y*Y)",$0D
         .DB $10,$01,"REM -- Catch center to avoid LN(0) crash --",$0D
         .DB $11,$01,"IF D<0.05 THEN GOTO 284",$0D
         .DB $12,$01,"REM -- The Math: Sine wave dampened by EXP and LN --",$0D
         .DB $13,$01,"LET W=SIN(10*D) * EXP(-0.5 * (LN(D)*LN(D)))",$0D
         .DB $14,$01,"REM -- Map to positive space --",$0D
         .DB $15,$01,"LET Z=(W+1)/2",$0D
         .DB $16,$01,"LET S=32",$0D
         .DB $17,$01,"IF Z>0.30 THEN LET S=46",$0D
         .DB $18,$01,"IF Z>0.45 THEN LET S=45",$0D
         .DB $19,$01,"IF Z>0.60 THEN LET S=43",$0D
         .DB $1A,$01,"IF Z>0.75 THEN LET S=42",$0D
         .DB $1B,$01,"IF Z>0.90 THEN LET S=64",$0D
         .DB $1C,$01,"IF D<0.05 THEN LET S=32",$0D
         .DB $1D,$01,"PRINT TAB(C-L);CHR$(S);",$0D
         .DB $1E,$01,"LET L=C+1",$0D
         .DB $1F,$01,"NEXT C",$0D
         .DB $20,$01,"PRINT",$0D
         .DB $21,$01,"NEXT R",$0D
         .DB $36,$01,"PRINT ",$22,"=== Render A Warped 3D Spiral Vortex to Test: ===",$22,$0D
         .DB $40,$01,"PRINT ",$22,"SIN, COS, TAN, ASIN, ACOS, ATN, SQRT",$22,$0D
         .DB $4A,$01,"REM L TRACKS LAST COLUMN SINCE TAB(n) HERE PRINTS n spaces",$0D
         .DB $68,$01,"LET H=27",$0D
         .DB $72,$01,"LET V=13",$0D
         .DB $7C,$01,"FOR R=0 TO 26",$0D
         .DB $86,$01,"LET L=0",$0D
         .DB $90,$01,"FOR C=0 TO 60",$0D
         .DB $9A,$01,"LET X=(C-30)/H",$0D
         .DB $A4,$01,"LET Y=(R-13)/V",$0D
         .DB $AE,$01,"LET D=SQRT(X*X+Y*Y)",$0D
         .DB $B8,$01,"IF D>1.2 THEN GOTO 680",$0D
         .DB $C2,$01,"IF X=0 THEN GOTO 480",$0D
         .DB $CC,$01,"LET T=ATN(Y/X)",$0D
         .DB $D6,$01,"GOTO 490",$0D
         .DB $E0,$01,"LET T=PI/2",$0D
         .DB $EA,$01,"REM --- TEST SIN/COS ---",$0D
         .DB $F4,$01,"LET W=SIN(6*D-3*T)",$0D
         .DB $FE,$01,"REM --- TAN ---",$0D
         .DB $08,$02,"LET U=TAN(W*0.5)",$0D
;         .DB $0D,$02,"LET U=SIN(W*0.5)/COS(W*0.5)",$0D
         .DB $1C,$02,"LET P=COS(U)",$0D
         .DB $26,$02,"REM --- TEST ASIN/ACOS ---",$0D
         .DB $30,$02,"LET A=ACOS(P)",$0D
         .DB $3A,$02,"LET B=ASIN(P)",$0D
         .DB $44,$02,"REM --- MATH SHADE VALUE ---",$0D
         .DB $4E,$02,"LET Z=ABS(A-B)/PI",$0D
         .DB $58,$02,"REM --- MAP TO ASCII CHARS ---",$0D
         .DB $62,$02,"LET S=32",$0D
         .DB $6C,$02,"IF Z>0.15 THEN LET S=46",$0D
         .DB $76,$02,"IF Z>0.35 THEN LET S=43",$0D
         .DB $80,$02,"IF Z>0.55 THEN LET S=79",$0D
         .DB $8A,$02,"IF Z>0.75 THEN LET S=64",$0D
         .DB $94,$02,"PRINT TAB(C-L);CHR$(S);",$0D
         .DB $9E,$02,"LET L=C+1",$0D
         .DB $A8,$02,"NEXT C",$0D
         .DB $B2,$02,"PRINT",$0D
         .DB $BC,$02,"NEXT R",$0D
         .DB $D0,$02,"PRINT ",$22,"=== Mandelbrot finale ===",$22,$0D
         .DB $DA,$02,"FOR Y=-1 TO 0.95 STEP 0.0833",$0D
         .DB $E4,$02,"FOR X=-2 TO 0.48 STEP 0.0417",$0D
         .DB $02,$03,"U=0",$0D
         .DB $0C,$03,"V=0",$0D
         .DB $16,$03,"N=0",$0D
         .DB $20,$03,"P=U*U",$0D
         .DB $2A,$03,"Q=V*V",$0D
         .DB $34,$03,"IF P+Q>4 THEN GOTO 890",$0D
         .DB $3E,$03,"IF N>=15 THEN GOTO 890",$0D
         .DB $48,$03,"W=P-Q+X",$0D
         .DB $52,$03,"V=2*U*V+Y",$0D
         .DB $5C,$03,"U=W",$0D
         .DB $66,$03,"N=N+1",$0D
         .DB $70,$03,"GOTO 800",$0D
         .DB $7A,$03,"K=48+N",$0D
         .DB $84,$03,"IF N<15 THEN GOTO 920",$0D
         .DB $8E,$03,"K=64",$0D
         .DB $98,$03,"PRINT CHR$(K);",$0D
         .DB $A2,$03,"NEXT X",$0D
         .DB $B6,$03,"PRINT",$0D
         .DB $C0,$03,"NEXT Y",$0D
         .DB $E8,$03,"END",$0D
SHOWCASE_END: ; audit

; ---- STRING/KEYWORD TABLE (page $F0) ----------------------------------------

         .ORG $F000
STR_PAGE = >STR_BANNER
STR_BANNER: .DB "miniBASIC 65C02 v3.4"
STR_CRLF:   .DB $0D,$8A
STR_IN:     .DB " IN",$A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB

; =============================================================================
; ---- UNI_TAB: unified keyword dispatch table (4 bytes/entry)
;   Two sections, each terminated by a $FF sentinel entry whose handler field
;   IS the no-match resume target (DO_LET for statements, E2ND for functions).
;   STMT searches section 0 (offset 0), E2NFN searches section 1 (offset 39).
;   Bit 7 of keyword's 2nd stored byte: set = 1-arg func (EAT_PAREN),
;   clear = statement/0-arg func (no EAT_PAREN).  All 2-char prefixes unique.
UNI_TAB:
; -- Statement section (offset 0) --
KW_PRINT: .DB "PR", <DO_PRINT, >DO_PRINT
KW_IF:    .DB "IF", <DO_IF,   >DO_IF
KW_GO:    .DB "GO", <DO_GOTO, >DO_GOTO
KW_LIST:  .DB "LI", <DO_LIST, >DO_LIST
KW_RUN:   .DB "RU", <DO_RUN,  >DO_RUN
KW_NEW:   .DB "NE", <DO_NEW_CHK,>DO_NEW_CHK
KW_FOR:   .DB "FO", <DO_FOR,  >DO_FOR
KW_INPUT: .DB "IN", <DO_INPUT,>DO_INPUT
KW_REM:   .DB "RE", <DO_REM_CHK,>DO_REM_CHK
KW_END:   .DB "EN", <DO_END,  >DO_END
KW_LET:   .DB "LE", <DO_LET,  >DO_LET
LW_POKE:  .DB "PO", <DO_POKE, >DO_POKE
          .DB $FF, <DO_LET, >DO_LET     ; sentinel: no-match → DO_LET

FUNC_TAB: ; -- function section --
KW_ABS:    .DB "A",$C2, <FLT_ABS, >FLT_ABS         ; "AB" with bit7 set on 'B' -- 1-arg flag
KW_SQR:    .DB "S",$D1, <FLT_SQRT,>FLT_SQRT        ; "SQ" with bit7 set on 'Q' -- 1-arg flag
KW_SIN:    .DB "S",$C9, <FLT_SIN, >FLT_SIN         ; "SI" with bit7 set on 'I' -- 1-arg flag
KW_COS:    .DB "C",$CF, <FLT_COS, >FLT_COS         ; "CO" with bit7 set on 'O' -- 1-arg flag
KW_TAN:    .DB "T",$C1, <FLT_TAN, >FLT_TAN         ; "TA" with bit7 set on 'A' -- 1-arg flag
KW_ATN:    .DB "A",$D4, <FLT_ATAN,>FLT_ATAN        ; "AT" with bit7 set on 'T' -- 1-arg flag
KW_ASIN:   .DB "A",$D3, <FLT_ASIN,>FLT_ASIN        ; "AS" with bit7 set on 'S' -- 1-arg flag
KW_ACOS:   .DB "A",$C3, <FLT_ACOS,>FLT_ACOS        ; "AC" with bit7 set on 'C' -- 1-arg flag
KW_PEEK:   .DB "P",$C5, <FLT_PEEK,>FLT_PEEK        ; "PE" with bit7 set on 'E' -- 1-arg flag
KW_USR:    .DB "U",$D3, <FLT_USR, >FLT_USR         ; "US" with bit7 set on 'S' -- 1-arg flag
KW_FLOOR:  .DB "F",$CC, <FLT_FLOOR,>FLT_FLOOR     ; "FL" with bit7 set on 'L' -- 1-arg flag
KW_EXP:    .DB "E",$D8, <FLT_EXP, >FLT_EXP         ; "EX" with bit7 set on 'X' -- 1-arg flag
KW_LN:     .DB "L",$CE, <FLT_LN,  >FLT_LN          ; "LN" with bit7 set on 'N' -- 1-arg flag
KW_PI:     .DB "PI",    <FLT_PI,  >FLT_PI          ; "PI" (0-arg, bit7 clear)
KW_FREE:   .DB "FR",    <DO_FREE, >DO_FREE         ; "FREE" (0-arg, bit7 clear)
KW_RND:    .DB "RN",    <FLT_RND, >FLT_RND         ; RND (0-arg, bit7 clear)
         .DB $FF, <E2ND, >E2ND             ; sentinel: no-match → E2ND

; Special Keywords - wierd functions or supporting words
; Two uppercase ASCII bytes per keyword (no terminator, no length).
KW_THEN:   .DB "TH"
KW_CHRS:   .DB "CH"
KW_TO:     .DB "TO"
KW_STEP:   .DB "ST"
KW_TAB:    .DB "TA"            ; TAB not TAN            

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
         TXA                   ; was CPX #0 -- saves 1 byte; A clobbered but GETCH overwrites it
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
         STZ IP+1
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
         BEQ ELD
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
;   ADD2_LP calls BUMP_LP once, then falls
;   straight through into BUMP_LP's own body for a second increment
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

; CPY_V2A -- copy 4 bytes from VARS,X into FLT_A (shared by E2VR, DONEXT)
;   In: X = byte offset into VARS   Out: FLT_A = VARS[X..X+3], X advanced by 4
;   Clobbers: A, Y
CPY_V2A: LDY #0
CVA_LP:  LDA VARS,X
         STA FLT_A,Y
         INX
         INY
         CPY #4
         BNE CVA_LP
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

DPX:        LDX #KW_CHRS-UNI_TAB ; check for CHR$
            JSR MTCHKW
            BCS CHK_TAB
DO_CHRS:    JSR EAT_PAREN
            JSR FLT_TO_INT
            LDX #1              ; Target loop count = 1
            LDA T0              ; Load targeted CHR$ value
            BRA DPTL_ENTRY      ; Re-use the space loop infrastructure
CHK_TAB:
            LDY #2
            LDA (IP),Y
            AND #$DF            ; uppercase-normalize
            CMP #'B'
            BEQ TAB_OK          ; 3rd char is 'B' -> real TAB
            SEC
            SBC #'A'
            CMP #26
            BCC DPNC            ; a letter, not 'B' (e.g. "TAN") -> not TAB
TAB_OK:
            LDX #KW_TAB-UNI_TAB
            JSR MTCHKW
            BCS DPNC            ; not TAB so jump          
DO_TAB:     JSR EAT_PAREN       ; get number of spaces
            JSR FLT_TO_INT
            LDA T0+1
            BMI DPA             ; TAB(negative): skip printing spaces
            LDX T0              ; Direct to X (sets Z flag)
            BEQ DPA             ; TAB(0): skip printing spaces
DPTL:       LDA #' '
DPTL_ENTRY: JSR PUTCH
            DEX
            BNE DPTL
            BRA DPA             ; Jump to trailing delimiter handler

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
; CHK3RD -- A = 3rd char of the current line (upper-cased), for disambiguating
;   keyword collisions eg GOTO/GOSUB, REM/RETURN, NEW/NEXT
;   In: LY (Y=2 expected by convention, but LDY is done inside here so
;       callers don't need to set it themselves)
;   Clobbers: A, Y
; =============================================================================
CHK3RD:
            LDY #2
            LDA (LP),Y
            AND #$DF
            RTS

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
; =============================================================================
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
         JSR CHK3RD
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
         JSR CHK3RD
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
         JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
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
; -1 floating point into FLT_A         
F_MINUSONE:         
         LDA #$81          ; TRUE = -1.0 = [$81,$80,$00,$00]
         STA FLT_A
         ;LDA #$80
         DEC
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
         JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
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
EXPR1:   JSR EXPR1P
E1L:     JSR WPEEK
         CMP #'*'
         BEQ E1MD
         CMP #'/'
         BEQ E1MD
         CMP #'%'
         BEQ E1MD
E1R:     RTS
E1MD:    PHA                  ; save operator
         JSR E1_RHS            ; FLT_B = right (via EXPR1P), FLT_A restored
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
FUNC_TAB_OFF = FUNC_TAB-UNI_TAB
E2PS:    JSR GETCI
EXPR2:   JSR WPEEK
         CMP #'('
         BEQ E2PR
E2NP2:
         CMP #'-'
         BEQ E2NG
E2NNG:   CMP #'+'
         BEQ E2PS
E2NFN:   LDX #FUNC_TAB_OFF             ; offset to function section of UNI_TAB - needs Define
         JMP MATCH_DISPATCH   ; enter MATCH_DISPATCH loop at function section

E2ND:    LDA (IP)               ; resume here if no match
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
         JMP CPY_V2A          ; tail-call shared copy VARS,X → FLT_A (4 bytes)
E2NG:    JSR E2PS
         JMP FLT_NEGATE
E2PR:    JSR GETCI
         JSR EXPR
         BRA WEAT

; =============================================================================
; EAT_PAREN -- consume a delimiter+expr (EAT_EXPR), then another ')'
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
EAT_PAREN: JSR EAT_EXPR
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
DIFDN:   RTS

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
; STMT  --  match one keyword against UNI_TAB and dispatch to its handler;
;           no match at all falls through to DO_LET (implicit "X=...")
;
;   In:  IP -> statement text
;   Out: statement executed; IP advanced
;   Clobbers: as the dispatched handler
; =============================================================================
DO_IF:   JSR EXPR
         LDA FLT_A
         BEQ DIFDN
         LDX #KW_THEN-UNI_TAB
         JSR MTCHKW
         ; falls through into STMT to run exactly one consequent statement

STMT:    JSR WPEEK
         CMP #' '
         BCC DIFDN
         LDX #0                 ; statement offset
         ; falls through into MATCH_DISPATCH (LDX #0)

; =============================================================================
; MATCH_DISPATCH --  shared keyword search across UNI_TAB (two sections:
;   statements at offset 0, functions at offset FUNC_TAB_OFF).  Each section ends with
;   a $FF sentinel entry whose handler field IS the no-match resume target.
;   Bit 7 of the keyword's 2nd stored byte selects behavior:
;     set   = 1-arg function: call EAT_PAREN before loading handler addr
;     clear = statement or 0-arg function: skip EAT_PAREN
;   On match: handler address stored in T2, JMP (T2) tail call.
;   On no-match ($FF sentinel): JMP (UNI_TAB+1,X) tail call — reads the
;   no-match target directly from the table, preserving T2 (needed by
;   relational operators which store their mask in T2 across EXPR_ADD calls).
;   All exits are tail calls: zero extra stack depth.
;   Clobbers: A, X, T2 (on match only)
; =============================================================================
MATCH_DISPATCH:
MDL:     LDA UNI_TAB,X
         BMI MD_FAIL          ; $FF sentinel: jump via table (preserves T2)
         JSR MTCHKW            ; X = entry offset, passed straight through
         BCS MDNX
         BPL MD_NOPAREN        ; bit7 clear: statement/0-arg, skip EAT_PAREN
         PHX                   ; save table offset -- EAT_PAREN clobbers X
         JSR EAT_PAREN
         PLX
MD_NOPAREN:
         LDA UNI_TAB+2,X
         STA T2
         LDA UNI_TAB+3,X
         STA T2+1
         JMP (T2)             ; tail-call handler
MDNX:    INX
         INX
         INX
         INX
         BRA MDL
MD_FAIL: JMP (UNI_TAB+1,X)    ; 65C02 indexed indirect: no-match target from table

; =============================================================================
; DO_LET  --  LET <var>=<expr>, or implicit <var>=<expr> (UNI_TAB fallthrough)
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
         LDX #KW_TO-UNI_TAB
         JSR MTCHKW
         BCS DFBAD              ; TO is mandatory
         JSR EXPR               ; evaluate limit -> FLT_A
         LDX #3                 ; stage limit float FLT_A -> FLIM (4 bytes)
DFLCP:   LDA FLT_A,X
         STA FLIM,X
         DEX
         BPL DFLCP
         LDX #KW_STEP-UNI_TAB
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
         JSR CHK3RD
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
;   on LIMIT (CMP==0) always loops once more (inclusive bound) 
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
         JSR CPY_V2A           ; copy VARS,X → FLT_A (4 bytes)
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
; MTCHKW  --  case-insensitive match of a 2-char keyword prefix at IP, then
;             consumes any further trailing letters (uBASIC's scheme)
;
;   In:  X = byte offset of the keyword entry within UNI_TAB (its first two
;        bytes are the raw keyword chars -- see KW_ABS/KW_SIN/etc; special
;        one-off keywords not in the dispatch table, e.g. KW_TO/KW_STEP,
;        are called the same way via X = <label>-UNI_TAB)
;   Out: match:  carry clear, IP advanced past the matched keyword,
;                N flag = bit 7 of the keyword's 2nd stored byte (set by
;                the keyword definition itself -- see KW_ABS/KW_SIN/etc --
;                1-arg flag) -- MATCH_DISPATCH tests BPL; X unchanged
;        no match: carry set, IP restored to its value on entry, X
;                unchanged, N/Z undefined (check carry first, always)
;   Clobbers: A, Y, T1
;
;   After the 2-char prefix matches, any run of trailing letters at IP is
;   swallowed (so "PR" matches the full word "PRINT", but also anything
;   else starting "PR" -- lenient by design, see v1.3 changelog). A
;   trailing '$' right after the letters (as in CHR$) is swallowed too:
;   the letter-skip loop computes (char-'A'), and '$'-'A' mod 256 = $E3
;   is checked for specially once a non-letter ends the loop.
; =============================================================================
MTCHKW:  LDA IP
         STA LP
         LDA IP+1
         STA LP+1
         JSR WPEEK_UC
         CMP UNI_TAB,X         ; absolute,X -- entry's 1st char, direct in table
         BNE MKFL
         JSR GETCI
         LDA UNI_TAB+1,X        ; A = raw stored 2nd byte (may carry the 0-arg
                                 ; flag in bit 7 -- see KW_RND/KW_PI/KW_FREE)
         STA T1                  ; stash raw byte for the N-flag return below
         AND #$7F                ; mask the flag bit off for the real compare
         STA T1+1
         JSR PEEKUC               ; A = peeked char (real ASCII, bit7 always 0)
         CMP T1+1
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
MKRTS:   LDA T1                ; N flag = bit 7 of raw 2nd keyword byte (the
         CLC
         RTS
MKFL:    LDA LP
         STA IP
         LDA LP+1
         STA IP+1
         SEC
         RTS

; =============================================================================
; FLT_RND -- FLT_A = pseudorandom float, 0 <= x < 1 (LFSR value / 32768)
;   Out: FLT_A = result.  Clobbers: as RND_SHUFFLE/FLT_FROM_INT/FLT_DIV
; =============================================================================
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

; =============================================================================
; FLOAT LIBRARY  --  MBF4 format, see header comment for the byte layout
; =============================================================================
; FLT_ABS -- FLT_A = |FLT_A|.  Clobbers: A.
FLT_ABS: LDA FLT_A+1
         AND #$7F
         STA FLT_A+1
         RTS

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

; =============================================================================
; CALC_SIGN_EXP -- shared FLT_MUL/FLT_DIV tail: A in = staged FLT_ER value.
;   Stores FLT_ER, XORs the result sign, sets both operands' sign bits
;   positive (magnitude-only from here on), and leaves X=2 for the caller's
;   own copy loop. Found via asmdup.py. Clobbers: A, X, FLT_ER, FLT_SA.
; =============================================================================
CALC_SIGN_EXP:
         STA FLT_ER
         JSR SIGN_XOR
         LDA #$80
         TSB FLT_A+1
         TSB FLT_B+1
         LDX #2
         RTS
         
; =============================================================================
; LD1_ADD_B -- FLT_A = FLT_A + 1.0, FLT_B = result.
;   Shared by FLT_LN and FLT_ATAN_CORE 
;   Clobbers: A, X, + FLT_ADD's own (FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE,
;             FLT_DB), + FLT_A_TO_B's own (via its internal push/pop)
; =============================================================================
LD1_ADD_B:
         LDX #IDX_ONE
         JSR FLT_LDCONST_B     ; FLT_B = 1.0
         JSR FLT_ADD           ; FLT_A = FLT_A + 1.0
;         JMP FLT_A_TO_B        ; FLT_B = result
        ; drop through
; FLT_A_TO_B / FLT_B_TO_A -- copy the 4-byte float FLT_A<->FLT_B.
; Clobbers: A, X.
FLT_A_TO_B:
        JSR PUSH_FLT_A
        JSR POP_FLT_B ; must be JSR as routine cleans up return address
        RTS

; Returns PI in FLT A and FLT B for Radian/degree conversions
FLT_PI:
        JSR LD_PI_B
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

; GET_RIGHT -- shared "move current FLT_A to FLT_B and restore parked FLT_A"
GET_RIGHT:
            JSR FLT_A_TO_B

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

; Zero floating point defined by offset X, x= 0 is FLT_A         
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

         JSR NEG16

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

NEG16:
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
; SHL_MANTISSA -- shift FLT_DB:FLT_A+3:FLT_A+2:FLT_A+1 left by 1 bit.
;   Shared by FLT_MUL, NORM_PACK, and FLT_DIV (found via asmdup.py --
;   identical 4-instruction sequence in all three). Clobbers: A.
; =============================================================================
SHL_MANTISSA:
         ASL FLT_DB
         ROL FLT_A+3
         ROL FLT_A+2
         ROL FLT_A+1
E1PR:    RTS

; =============================================================================
; CALC_INT_LN2 -- FLT_A = float(T0)*ln(2), where T0 is an already-staged
;   16-bit signed int (FLT_FROM_INT's input). Shared by FLT_LN (E*ln2) and
;   FLT_EXP (k*ln2) -- found via asmdup.py. Clobbers: as FLT_FROM_INT,
;   FLT_MUL combined.
; =============================================================================
CALC_INT_LN2:
        JSR FLT_FROM_INT
        LDX #IDX_LN2
        JSR FLT_LDCONST_B
        JMP FLT_MUL            ; tail call

; =============================================================================
; E1_RHS -- shared by EXPR1's E1MD and EXPR1P's own recursive ^ case: park
;   the left operand, consume the operator char, parse the right operand
;   (through EXPR1P, so ^ chains bind correctly), then GET_RIGHT to combine.
;   Must use JSR+RTS here, not a tail-call JMP into GET_RIGHT -- GET_RIGHT
;   relies on stealing a genuine JSR return address for its park/restore
;   trick, and a tail-call doesn't provide one (confirmed the hard way).
;   Found via asmdup.py. Clobbers: as PUSH_FLT_A/GETCI/EXPR1P/GET_RIGHT.
; =============================================================================
E1_RHS:  JSR PUSH_FLT_A
         JSR GETCI
         JSR EXPR1P
         JSR GET_RIGHT
         RTS

; =============================================================================
; EXPR1P -- power level: right-associative x^y, binds tighter than * / %
;   (BODMAS/PEMDAS-correct, unlike the earlier same-precedence attempt).
;   Recursive on the right operand so "2^3^2" = "2^(3^2)" = 512, matching
;   convention -- and cheaper than a left-associative loop besides, since
;   the recursive tail-call skips needing its own BRA back-edge.
; =============================================================================
EXPR1P:  JSR EXPR2
         JSR WPEEK
         CMP #'^'
         BNE E1PR
         JSR E1_RHS            ; FLT_B = right (via EXPR1P), FLT_A restored
;         JMP FLT_POW              ; tail call
        ; drop through
; =============================================================================
; FLT_POW -- FLT_A = FLT_A ^ FLT_B  (base^exponent), via EXP(exponent*LN(base))
;   Domain: base > 0 (inherits FLT_LN's ?2 domain error for base<=0; negative
;   or non-positive bases -- e.g. (-2)^2 -- are NOT specially supported).
;   Clobbers: as FLT_LN, FLT_MUL, FLT_EXP combined.
; =============================================================================
FLT_POW: JSR PUSH_FLT_B       ; stash exponent (FLT_LN clobbers FLT_B)
         JSR FLT_LN            ; FLT_A = ln(base)
         JSR POP_FLT_B          ; FLT_B = exponent (restored)
         JSR FLT_MUL             ; FLT_A = exponent * ln(base)
         JMP FLT_EXP              ; FLT_A = exp(...) = base^exponent; tail call

; =============================================================================
; FLT_LN -- FLT_A = ln(FLT_A), x > 0 required (?2 domain error otherwise --
;   FLT_SQRT still separately clamps negative input to 0.0, its own
;   established legacy behavior, rather than erroring)
;   Clobbers: A, X, Y, T0, T1, FLT_B, LN_M, + HORNER_EVAL's clobbers
; =============================================================================
FLT_LN:
        LDA FLT_A
        BEQ LN_ERR             ; x==0 -> domain error
        LDX FLT_A+1             ; A still holds FLT_A (exponent) below
        BPL LN_CONT             ; x>0 -> continue
LN_ERR: JMP ERR_OV_J            ; ?2 domain error (shared with FLT_DIV)
LN_CONT:
        SEC
        SBC #128
        PHA                    ; stash signed exponent E (1 byte) -- NOT T1,
                                ;  which FLT_DIV clobbers internally below

        LDA #128
        STA FLT_A              ; FLT_A = m, mantissa in [0.5,1.0)

        LDX #3
LN_SAVEM: LDA FLT_A,X
        STA LN_M,X              ; stash m (dedicated scratch, not FP_TMP)
        DEX
        BPL LN_SAVEM
        LDX #IDX_ONE
        JSR FLT_LDCONST_B       ; FLT_B = 1.0
        JSR FLT_SUB              ; FLT_A = m - 1  (FLT_B now permanently -1.0)
        JSR PUSH_FLT_A            ; stash (m-1) -- paired with POP_FLT_A below
        LDX #3
LN_RESTM: LDA LN_M,X
        STA FLT_A,X               ; FLT_A = m (restored)
        DEX
        BPL LN_RESTM
        JSR LD1_ADD_B              ; FLT_A = m + 1, FLT_B = m + 1
        JSR POP_FLT_A                   ; FLT_A = (m-1) -- balances the
                                         ;  PUSH_FLT_A above
        JSR FLT_DIV                      ; FLT_A = z = (m-1)/(m+1)

        LDA #<LN_POLY_TBL                       ; FLT_A = z*Q(z^2) = ln(m), via
        LDX #>LN_POLY_TBL                       ;  the shared HORNER_ODD evaluator
        JSR HORNER_ODD                          ;  (squares z, evals Q(z^2),
                                                 ;  multiplies back by z)

        PLA                     ; retrieve E -- must happen NOW, while the
                                 ;  stack's top is still E: every push above
                                 ;  is already balanced by this point, and
                                 ;  ln(m) hasn't been parked yet (parking it
                                 ;  first would put PLA on the wrong bytes)
        STA T0
        AND #$80
        BEQ LN_EPOS
        LDA #$FF
LN_EPOS: STA T0+1

        JSR PUSH_FLT_A            ; NOW park ln(m)
        JSR CALC_INT_LN2            ; FLT_A = float(E)*ln(2)
        JSR POP_FLT_B                     ; FLT_B = ln(m) -- balances the
                                           ;  PUSH_FLT_A just above
        ;JMP FLT_ADD                         ; FLT_A = E*ln2 + ln(m); tail call
        ;drop through
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
PFE:     ;JMP FLT_ZERO
FAZE:    ; drop through
        ; drop through
; FLT_ZERO -- FLT_A = 0.0.  Clobbers: A, X.
FLT_ZERO:
        LDX #0 ; zp offset
        JMP F_ZERO      ; tail call

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
        JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
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

; =============================================================================
; FLT_CMP  --  compare FLT_A to FLT_B (both preserved)
; FLT_CMP: A=$FF(A<B) $00(A=B) $01(A>B). FLT_A preserved; uses T1.
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

HE_DONE: JSR POP_FLT_B         ; drain the final parked Z (discarded) --
                                ; balances the initial PUSH_FLT_B for any N,
                                ; including N=0
FCLT:    LDA #$FF
         RTS

; =============================================================================
; HORNER_EVAL -- generic table-driven Horner polynomial evaluator.
;
;   In:  PTR   -> ROM table: [1-byte degree N][4-byte C_N]...[4-byte C_0]
;        FLT_B = evaluation point Z (already prepared by the caller -- could
;                be x, x^2, a reduced r/m, whatever; this routine doesn't
;                care what it represents, only that it's the value every
;                Horner step multiplies in)
;   Out: FLT_A = P(Z), PTR left just past the table (pointing at whatever
;                follows it in ROM)
;
;   The first coefficient loaded (the top, C_N) is explicitly copied from
;   FLT_B into FLT_A via FLT_B_TO_A to seed the running sum -- HE_LOAD_COEFF
;   only ever writes FLT_B, same as the file's other coefficient-loader
;   idioms, so this seed step is required, not implicit.
;
;   Table address is passed in A(lo)/X(hi) rather than requiring the caller
;   to set PTR itself -- saves 4 bytes per call site (the STA PTR/STX PTR+1
;   moves here, written once, instead of duplicated at every caller).
;
;   Clobbers: A, X, Y, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE, FLT_DB,
;             FLT_MA, FLT_MB, FLT_MC, PFA_RL, PFA_RH, HORNER_N, PTR
; =============================================================================
HORNER_EVAL:
        STA PTR
        STX PTR+1
        ; fall through into HE_BODY. HE_BODY is also entered directly by
        ; HORNER_ODD (below), which sets PTR itself -- A/X can't survive
        ; the squaring step there, so the ptr-store is split out of the body.
HE_BODY:
        JSR PUSH_FLT_B         ; stack: [Z]
        LDY #0
        LDA (PTR),Y            ; degree N
        STA HORNER_N
        INC PTR
        BNE HE_L1
        INC PTR+1
HE_L1:  JSR HE_LOAD_COEF       ; FLT_B = C_N (top coeff); PTR += 4
        JSR FLT_B_TO_A         ; FLT_A = C_N  (seed the Horner sum)

HE_LOOP: LDA HORNER_N
        BEQ HE_DONE
        JSR POP_FLT_B          ; FLT_B = Z (retrieve)
        JSR PUSH_FLT_B         ; re-park immediately -- FLT_MUL is about
                                ; to clobber FLT_B
        JSR FLT_MUL            ; FLT_A = sum * Z
        JSR HE_LOAD_COEF       ; FLT_B = next coeff; PTR += 4
        JSR FLT_ADD            ; FLT_A = sum*Z + coeff
        DEC HORNER_N
        BRA HE_LOOP

HE_LOAD_COEF: LDY #3
HE_LC_LOOP:   LDA (PTR),Y
              STA FLT_B,Y
              DEY
              BPL HE_LC_LOOP
              LDA PTR
              CLC
              ADC #4
              STA PTR
              BCC HE_LC_RTS
              INC PTR+1
HE_LC_RTS:    RTS

; =============================================================================
; HORNER_ODD -- shared odd-polynomial evaluator: FLT_A = z * P(z^2).
;
;   Folds the previously-duplicated "square, eval P(z^2), multiply back by z"
;   glue that FLT_SIN (sin(x)=x*P(x^2)) and FLT_LN (ln(m)=z*Q(z^2)) each
;   spelled out inline. FLT_EXP keeps using plain HORNER_EVAL (even poly).
;
;   In:  A/X = coefficient table (same [degree][coeffs...] layout as
;             HORNER_EVAL), FLT_A = z
;   Out: FLT_A = z * P(z^2); PTR left just past the table
;   Clobbers: A, X, Y, FLT_B, PTR, HORNER_N, PFA_RL/H, + FLT_MUL/FLT_ADD's
;             own documented clobbers
; =============================================================================
HORNER_ODD:
        STA PTR                 ; save table ptr NOW: A/X die in FLT_MUL below
        STX PTR+1
        JSR PUSH_FLT_A         ; park z
        JSR FLT_A_TO_B         ; FLT_B = z
        JSR FLT_MUL            ; FLT_A = z^2
        JSR FLT_A_TO_B         ; FLT_B = z^2  (HORNER_EVAL's eval point)
        JSR HE_BODY            ; FLT_A = P(z^2)   (PTR already set)
        JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
        BRA FLT_MUL            ; FLT_A = z * P(z^2)   (tail call)

; =============================================================================
; FLT_SQRT  --  FLT_A = sqrt(FLT_A) using exp(0.5*ln x) identity with zero and unit guards.
;   In:  FLT_A = S (operand)
;   Out: FLT_A = sqrt(S). Negative input is clamped to 0.0 (domain guard;
;        this library has no complex-number support -- this guard is now
;        real as of v3.0, see Known Limitations at the top of the file).
;   TO-DO: accuracy not formally audited (unlike FLT_ATAN_CORE, which has a
;     documented ~1.9e-4 rad bound). One data point: SQRT(4) observed as
;     2.00001, i.e. ~5e-5 relative error -- likely fine, not verified further.
;   Clobbers: A, X, Y, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE,
;             FLT_DB, FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
; =============================================================================
FLT_SQRT: LDA FLT_A
         BEQ SQRTZ2          ; x==0 -> sqrt(0)=0 (skip the undefined ln(0))
         LDA FLT_A+1
         BPL FSQ_POS         ; x>0 -> normal path
         STZ FLT_A           ; x<0 -> clamp to 0.0 (comment above was aspirational)
SQRTZ2: 
         RTS
FSQ_POS: JSR FLT_LN
         LDA FLT_A
         BEQ SQRTZ           ; ln(x)==0 (x==1) -> exp(0)=1, skip DEC
         DEC FLT_A           ; *0.5  (halve the exponent)
SQRTZ:   ; JMP FLT_EXP         ; tail: exp(0.5*ln x)
        ; drop through
; =============================================================================
; FLT_EXP -- FLT_A = e^FLT_A
;   k = trunc(x*log2(e)); r = x - k*ln(2), so r falls in the SYMMETRIC range
;   (-ln2,+ln2) -- deliberately not floor-adjusted to [0,1)-style
;   Clobbers: A, X, Y, T0, FLT_B, EXP_K, + HORNER_EVAL's clobbers
; =============================================================================
FLT_EXP:
        JSR PUSH_FLT_A          ; stack: [x] -- need x again for r=x-k*ln2
        LDX #IDX_LOG2E
        JSR FLT_LDCONST_B        ; FLT_B = log2(e)
        JSR FLT_MUL                ; FLT_A = y = x*log2(e)
        JSR FLT_TO_INT               ; T0 = trunc(y) = k (16-bit, saturated)
        LDA T0
        BMI EK_NEGCHK
        LDA T0+1
        BEQ EK_FITS         ; positive k, fits a signed byte
        BRA EK_OOR
EK_NEGCHK:
        LDA T0+1
        CMP #$FF
        BEQ EK_FITS         ; negative k, fits a signed byte
EK_OOR: JSR POP_FLT_A       ; k doesn't fit -- balance entry's PUSH_FLT_A
        JMP ERR_OV_J        ; |x| too large for EXP -> ?2 (shared w/ FLT_DIV)
EK_FITS:
        LDA T0
        STA EXP_K                     ; stash k's low byte (dedicated 1-byte
                                       ;  scratch -- simpler and safer than
                                       ;  interleaving a raw PHA inside the
                                       ;  x park/restore pair above)
        JSR CALC_INT_LN2                ; FLT_A = float(k)*ln(2)
        JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
                                                 ;  balances the PUSH_FLT_A
                                                 ;  at entry
        JSR FLT_SUB                               ; FLT_A = r = x - k*ln(2)

        JSR FLT_A_TO_B                              ; FLT_B = r (HORNER_EVAL's
                                                     ;  eval point)
        LDA #<EXP_POLY_TBL
        LDX #>EXP_POLY_TBL
        JSR HORNER_EVAL                               ; FLT_A = P(r) ~= exp(r)

        LDA EXP_K
        CLC
        ADC FLT_A
        STA FLT_A                                       ; FLT_A = exp(r)*2^k
        RTS

; MUL_BY_TEN -- FLT_A = FLT_A * 10.  Clobbers: as FLT_MUL.
MUL_BY_TEN:
         JSR FLT_TEN_B
        ; drop through

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
         JSR CALC_SIGN_EXP
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
         JSR SHL_MANTISSA
         DEC FLT_ER
FMPK:    ; drop through into NORM_PACK

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
NPBT:    JSR SHL_MANTISSA
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
         JSR CALC_SIGN_EXP
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
FDL:     JSR SHL_MANTISSA
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
         JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
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
; FLT_ASIN  --  FLT_A = asin(FLT_A), RADIANS.  asin(x) = atan(x/sqrt(1-x^2))
;
;   |x|==1 and |x|>1 both handled as of v3.0 (see Known Limitations at the
;   top of the file for the saturate-to-+/-PI/2 behavior and why). Accuracy
;   is inherited from FLT_SQRT and FLT_ATAN_CORE.
;   Clobbers: as FLT_SQRT/FLT_ATAN combined, plus the hardware stack (one
;   extra transient byte via PHA/PLA in the |x|==1 branch only)
; =============================================================================
FLT_ASIN: JSR FLT_A_TO_B       ; FLT_B = x
         JSR PUSH_FLT_A       ; park x (numerator) across the squaring
         JSR FLT_MUL          ; FLT_A = x*x = x^2  (FLT_A=x, FLT_B=x)
         JSR FLT_A_TO_B       ; FLT_B = x^2
         LDX #IDX_ONE         ; FLT_A = 1.0 ...
         JSR FLT_LDCONST
         JSR FLT_SUB          ; FLT_A = 1 - x^2
         JSR FLT_SQRT         ; FLT_A = sqrt(1 - x^2)  (denominator)
         LDA FLT_A
         BNE FA_NORM          ; denom != 0 -> normal path
         JSR GET_RIGHT        ; |x|==1: FLT_A = x (restored), FLT_B = 0
         LDX #IDX_PI_2
         JSR FLT_LDCONST_B    ; FLT_B = +pi/2
         LDA FLT_A+1
         BPL FA_SGN
         SMB7 FLT_B+1            ; x<0 -> -pi/2
FA_SGN:  JMP FLT_B_TO_A       ; FLT_A = asin(+-1) = (+-)pi/2; RTS
FA_NORM: JSR GET_RIGHT        ; FLT_B = denominator, FLT_A = x (restored)
         JSR FLT_DIV          ; FLT_A = x / sqrt(1 - x^2)
        ; drop through
; =============================================================================
; FLT_ATAN  --  FLT_A = atan(FLT_A), RADIANS, valid for any x
;
;   In:  FLT_A = x
;   Out: FLT_A = atan(x), radians
;   Clobbers: A, X, Y, T0, T1, T2, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DE,
;             FLT_DB, FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
;
;   Range reduction verified for large |x| (v3.0 -- tested up to ~1E10-scale
;   literals; converges correctly to +/-PI/2). Accuracy is FLT_ATAN_CORE's,
;   documented on that routine below (~1.9e-4 rad on its core domain).
; =============================================================================
FLT_ATAN:
         LDA FLT_A+1
         AND #$80
         STA T2                ; T2 = original sign bit of x (0 or $80)
         RMB7 FLT_A+1            ; FLT_A = |x|
         LDX #IDX_ONE
         JSR FLT_LDCONST_B     ; FLT_B = 1.0
         JSR FLT_CMP           ; A = -1/0/+1 : |x| vs 1.0 (FLT_A preserved=|x|)
         CMP #1
         BEQ FA_BIG            ; |x| > 1: range-reduce

         LDA FLT_A+1           ; |x| <= 1: restore sign, run core directly
         ORA T2
         STA FLT_A+1           ; FLT_A = x (signed)
        ; drop through
; =============================================================================
; FLT_ATAN_CORE  --  FLT_A = atan(FLT_A), RADIANS, degree-3 odd polynomial
;   atan(x) = x*P(x^2) evaluated via the shared HORNER_ODD. Remez/minimax fit
;   on the core domain |x| <= 1, accurate to ~1.9e-4 rad (vs ~4.7e-3 for the
;   old single-coefficient Pade x/(1+0.28086*x^2) this replaces). The public
;   FLT_ATAN wrapper (below) range-reduces so this is never called outside
;   |x| <= 1. Sign is free: x*P(x^2) inherits the sign of x because x^2 >= 0.
;
;   In:  FLT_A = x  (|x| <= 1, signed)
;   Out: FLT_A = atan(x) approximation, radians (signed)
;   Clobbers: A, X, Y, FLT_B, PTR, HORNER_N, PFA_RL, PFA_RH, + FLT_MUL/FLT_ADD
;             clobbers (FLT_MA/MB/MC etc.). Note: no longer touches the FLT_DIV
;             working registers (FLT_DVH/DVM/DVL) -- the division is gone.
; =============================================================================
FLT_ATAN_CORE:
         LDA #<ATN_POLY_TBL    ; A/X -> degree-3 atan coefficient table
         LDX #>ATN_POLY_TBL
         JMP HORNER_ODD        ; FLT_A = x * P(x^2) = atan(x)

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
         SMB7 FLT_A+1            ; negative x: -pi/2
FA_SUB:  JMP FLT_SUB            ; FLT_A = (+-pi/2) - atan_core_rad(1/x)

; =============================================================================
; FLT_ACOS  --  FLT_A = acos(FLT_A), RADIANS.  acos(x) = pi/2 - asin(x)
;   Clobbers: as FLT_ASIN
; =============================================================================
; FLT_ACOS -- acos(x) = pi/2 - asin(x).  
FLT_ACOS: JSR FLT_ASIN
          JSR FLT_A_TO_B       ; FLT_B = asin(x)
          LDX #IDX_PI_2
          JSR FLT_LDCONST      ; FLT_A = pi/2
          JMP FLT_SUB          ; tail: pi/2 - asin(x)

; =============================================================================
; FLT_TAN -- FLT_A = tan(FLT_A), RADIANS.  tan(x) = sin(x)/cos(x)
;   Asymptotes (x = pi/2 + n*pi) hit FLT_DIV's zero-divisor trap -> "?2",
;   same as any other undefined-result case in this library.
;   Clobbers: as FLT_SIN/FLT_COS/FLT_DIV combined, plus the hardware stack
;   (one float parked across FLT_SIN, one across FLT_COS).
; =============================================================================
FLT_TAN: JSR PUSH_FLT_A       ; park x
         JSR FLT_SIN            ; FLT_A = sin(x)
         JSR GET_RIGHT            ; FLT_B = sin(x), FLT_A = x (restored)
         JSR PUSH_FLT_B             ; park sin(x)
         JSR FLT_COS                  ; FLT_A = cos(x) (uses restored x)
         JSR GET_RIGHT                  ; FLT_B = cos(x), FLT_A = sin(x) (restored)
         JMP FLT_DIV                      ; FLT_A = sin(x)/cos(x); tail-call

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
;   Out: FLT_A = sin(angle), accurate to ~0.0002
;   sin(x) ~= x*(1 - x^2*(0.16605 - 0.00761*x^2)), valid for x in [0,pi/2].
;   Range reduction (abs -> mod 2pi -> fold [0,pi] -> fold [0,pi/2]) is
;   unchanged from the original hand-written version.
; =============================================================================
FLT_SIN:
         LDA FLT_A+1
         AND #$80
         PHA                   ; stash original sign
         RMB7 FLT_A+1            ; FLT_A = |x| (radians)

         JSR LD_PI_B        ; FLT_B = pi
         INC FLT_B              ; FLT_B = 2*pi (NORM_PACK always leaves
                                 ;               constants normalised)
         JSR FLT_MOD           ; FLT_A = |x| mod 2*pi

         JSR LD_PI_B         ; fold [0,2pi) -> [0,pi]
         JSR FLT_SUB            ; FLT_A = (x mod 2pi) - pi
         LDA FLT_A+1
         BPL FS_GT_PI
         JSR LD_PI_B          ; <= pi: undo the subtraction (add pi back)
         JSR FLT_ADD
         BRA FS_FOLD2
FS_GT_PI: PLA
         EOR #$80
         PHA                    ; flip the stashed sign

FS_FOLD2:                       ; fold [0,pi] -> [0,pi/2]: sin(x)=sin(pi-x)
         JSR PUSH_FLT_A         ; park x
         LDX #IDX_PI_2
         JSR FLT_LDCONST_B          ; FLT_B = pi/2
         JSR FLT_SUB                  ; FLT_A = x - pi/2
         LDA FLT_A+1
         BMI FS_LE_PI2                 ; x < pi/2: discard this, restore x
         JSR GET_RIGHT          ; FLT_B = FLT_A (right), restore parked FLT_A
                                           ; happen to keep the frame balanced
         LDX #IDX_PI_2                    ;          = pi - x
         JSR FLT_LDCONST
         JSR FLT_SUB
         BRA FS_POLY
FS_LE_PI2:
         JSR POP_FLT_A          ; x < pi/2: restore original x

FS_POLY:                        ; sin(x) ~= x*P(x^2) via the shared
                                 ; HORNER_ODD evaluator (squares z, evals
                                 ; P(z^2), multiplies back by z).
         LDA #<SIN_POLY_TBL
         LDX #>SIN_POLY_TBL
         JSR HORNER_ODD         ; FLT_A = x * P(x^2) = sin(x)

         PLA                    ; retrieve final sign
         EOR FLT_A+1
         STA FLT_A+1
         RTS


; =============================================================================
; FLT_CONST_PTR -- point T0 at constant X's 4 ROM bytes. All constants
;   (C_ATANCOEF..C_32768 above) must to stay within One page ($FFxx
;   as of writing). If the table overlaps a page boundary this silently
;   breaks. Check LST file when adding more constants.
;   Clobbers: A, T0.
; =============================================================================
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

; LD_PI_B -- FLT_B = pi. 
;   Out: FLT_B = pi.  Clobbers: A, X, Y, T0, T1
LD_PI_B:
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

; =============================================================================
; FLT_CONST table  --  ROM-resident 4-byte MBF4 constants for ATAN/ASIN/ACOS,
;   loaded via FLT_LDCONST (-> FLT_A) / FLT_LDCONST_B (-> FLT_B). Values
;   computed to nearest MBF4 representation (round-to-nearest mantissa).
; =============================================================================
; indices
IDX_ONE      = 0
IDX_PI_2     = 1
IDX_32768    = 2
IDX_LOG2E    = 3
IDX_LN2      = 4

; ATN_POLY_TBL -- degree-3 odd-poly atan(x)=x*P(x^2), Remez on [0,1]:
;   atan ~= x*(1 - 0.326217246*x^2 + 0.156670754*x^4 - 0.045055345*x^6)
;   coeffs stored highest-power first (HORNER_EVAL order): C3,C2,C1,C0
ATN_POLY_TBL:
         .DB 3
         .DB $7C,$B8,$8B,$F4   ; C3 = -0.045055345
         .DB $7E,$20,$6E,$4C   ; C2 =  0.156670749
         .DB $7F,$A7,$05,$F2   ; C1 = -0.326217234
         .DB $80,$7F,$F3,$94   ; C0 =  0.999810457

LN_POLY_TBL:  .DB 3
              .DB $7F,$2F,$29,$5C   ; C3 =  0.34211242
              .DB $7F,$4A,$A5,$C5   ; C2 =  0.39579598
              .DB $80,$2A,$B1,$9C   ; C1 =  0.66677263
              .DB $81,$7F,$FF,$FB   ; C0 =  1.99999941

EXP_POLY_TBL: .DB 5
              .DB $7A,$0B,$13,$F2   ; C5 =  0.00848864
              .DB $7C,$2E,$6E,$2A   ; C4 =  0.04258553
              .DB $7E,$2A,$A1,$BF   ; C3 =  0.16663264
              .DB $7F,$7F,$EC,$A5   ; C2 =  0.49985232
              .DB $81,$00,$00,$0F   ; C1 =  1.00000182
              .DB $81,$00,$00,$1C   ; C0 =  1.00000339

; Do not split SIN_POLY_TBL from C_ONE 
SIN_POLY_TBL: .DB 2
              .DB $79,$79,$5D,$4F   ; C2 =  0.00761  (=C_C2_SIN, unchanged)
              .DB $7E,$AA,$09,$03   ; C1 = -0.16605  (=-C_C1_SIN, sign flipped
                                    ;  for Horner form -- see header comment)
C_ONE:      .DB $81,$00,$00,$00  ; C0 =  1.0 also used by SIN_POLY_TBL
C_PI_2:     .DB $81,$49,$0F,$DB  ; 1.5707963 (pi/2, radians)
C_32768:    .DB $90,$00,$00,$00  ; 32768.0 (RND's LFSR->float divisor)
C_LOG2E:    .DB $81,$38,$AA,$3B  ; 1.4426950 (log2 e; FLT_EXP reduction)
C_LN2:      .DB $80,$31,$72,$18  ; 0.6931472 (ln 2; FLT_EXP/FLT_LN reduction)

CTAB_LO: .DB <C_ONE,<C_PI_2,<C_32768,<C_LOG2E,<C_LN2

ROMEND: ; audit

        ; vectors
         .ORG $FFFC
         .DW INIT
         .DW IRQ_HANDLER
