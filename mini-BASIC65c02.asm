; =============================================================================
; miniBASIC 65C02 v2.1
;
; 4KB Float BASIC (MBF4) for the 65C02.
;
; Statements accepted
;   END  FOR..TO..STEP  FREE  GOSUB  GOTO  IF..THEN  INPUT  LET  LIST  NEW
;   NEXT  POKE  PRINT (incl. TAB(n))  REM  RETURN  RUN
; Expressions:
;   + - * / %   = < > <= >= <>   unary -
;   ABS(n)   ACOS(n)   ASIN(n)   ATN(n)   CHR$(n)   COS(x)   DEG(rad)
;   PEEK(addr)   RND   SIN(x)   SQR(n)   USR(addr)
;   A-Z variables
;
; Numbers      : MBF4 float, ~6-7 significant decimal digits (see format below)
; String print : "literals", `;`, and CHR$() only; no string variables
;
; Trig is RADIANS-native throughout (SIN/COS/ATN/ASIN/ACOS all take/return
; radians). DEG(rad) converts a radian value to degrees for display -- it's
; the only place degrees exist in the language now. (Earlier versions had
; SIN/COS take degrees, matching the original CORDIC implementation this
; replaced; that convention is gone as of v2.0 -- this is a hobby project
; for obsolete hardware with no installed base to break, so there was no
; reason to keep two separate deg<->rad conversion mechanisms (SIN's entry
; conversion, ATN's exit conversion, plus a whole separate 90.0 constant
; duplicating the existing pi/2) when one, reused everywhere, does the job
; for less ROM. See v2.0 changelog for the exact byte accounting.)
;
; Number literals require a leading digit before the decimal point --
; "0.5" works, ".5" does not (parses as 0). This has been true since v1.5;
; not something introduced by any later change.
;
; ASIN/ACOS raise a ?2 (overflow) error at exactly x=+-1 (the x/sqrt(1-x^2)
; identity they're built on divides by zero there) instead of returning
; +-pi/2 -- same class of edge behavior as TAN at pi/2 would have.
;
; Input buffer : GETLINE's IBUF is 32 bytes. A typed or INPUT'd line longer
;   than that is *silently truncated* -- no error is raised, and the
;   remainder is discarded character-by-character up to the terminating CR.
;
; FOR/NEXT : loop variable, TO limit, and STEP are all real floats.
;   "FOR X = 1 TO 10 STEP 0.5" and non-integer TO bounds (e.g. "TO 10.5")
;   are both fully supported. Max nesting depth is 4.
;
; Toolchain: asm65c02 v1.14+ required (raises a hard error on an undefined
;   symbol in an instruction operand; earlier versions silently assembled
;   it as address $0000 with no diagnostic -- see the v1.9 changelog for
;   the real bug this caused and how it was found).
;
; =============================================================================
; CHANGE HISTORY
;
; v2.1 (Jul 2026) — Small verified ROM wins; one proposal tried and reverted
;   - ROM: 18 -> 41 bytes free.
;   - DO_LET: JSR STORE_VAR/RTS -> JMP STORE_VAR (tail call). 1 byte.
;   - FLT_CONST_PTR: removed CTAB_HI (all 7 constants -- C_ATANCOEF through
;     C_32768 -- happen to already live within a single ROM page, $FE, so
;     the high byte doesn't need per-entry storage; hardcoded #$FE instead
;     and dropped the table). 8 bytes. NOTE: this silently breaks if the
;     constant table ever grows past $FEFF -- check with --dump-all before
;     adding more entries; see the comment at FLT_CONST_PTR.
;   - PEEK/USR extracted from EXPR2's hand-written chain into their own
;     FLT_PEEK/FLT_USR handlers, wired through FN_TAB like ABS/SQR/etc.
;     14 bytes. (Verified USR_CALL/USR_RET already produce a proper FLT_A
;     via FLT_FROM_INT before doing this -- no behavior change.)
;   - TRIED AND REVERTED: consolidating STMT (ST_TAB) and FN_DISPATCH
;     (FN_TAB) onto one shared indirect-addressed TAB_SEARCH walker.
;     Initial estimate said ~6 bytes saved; implementing it correctly
;     required preserving T2 across EAT_PAREN (which clobbers T0-T2 --
;     missed in the original estimate), and that preservation cost more
;     than the consolidation saved. Measured net: 6 bytes *worse*, not
;     better, once correct. Reverted back to the separate STMT/FN_DISPATCH
;     versions rather than keep a net-negative "cleanup". RND and TAB were
;     evaluated for the same FN_TAB treatment and intentionally NOT
;     changed: RND takes no parens and FN_DISPATCH's EAT_PAREN is
;     unconditional (would break bare "RND"); TAB's print-then-continue
;     behavior needs a normal JSR/RTS relationship with DO_PRINT's own
;     per-item loop, which FN_DISPATCH's tail-call convention (built for
;     "caller doesn't want control back") would break.
;   - Regression: full suite re-run (statements via ST_TAB, functions via
;     FN_TAB including PEEK, full Mandelbrot+sine showcase) -- all pass,
;     byte-identical to v2.0 where applicable.
;
; v2.0 (Jul 2026) — Radians-native trig; full FN_TAB wiring; new toolchain
;   - CHANGED (breaking): SIN/COS switched from degrees to radians, to
;     match ATN/ASIN/ACOS (which were always going to be radians-native --
;     see the v1.9 byte-savings report this followed up on). The three
;     conversion mechanisms this removed: FLT_SIN's deg->rad entry
;     conversion (DEGRAD constant + 8 bytes of call-site code), FLT_ATAN's
;     rad->deg exit conversion (RADDEG constant + the RAD_TO_DEG routine's
;     2 call sites), and a standalone NINETY (90.0) constant used by
;     FLT_ATAN/FLT_ACOS/FLT_COS for quarter-turn math, now replaced by
;     reusing the PI_2 constant FLT_SIN's own range reduction already
;     needed. RAD_TO_DEG itself was kept (still useful) and wired up as
;     the new DEG(rad) keyword instead of being deleted.
;   - ADDED: DEG(rad) -- converts radians to degrees, via RAD_TO_DEG.
;   - ADDED: ATN(x), ASIN(x), ACOS(x) wired as real keywords (2-char
;     prefixes AT/AS/AC, no collisions). Previously existed only as
;     internal JSR-only subroutines (see v1.9).
;   - REFACTORED: EXPR2's function dispatch. ABS/SQR/SIN/COS/ATN/ASIN/
;     ACOS/DEG (all "EAT_PAREN, call FLT_A-in/FLT_A-out handler" shape)
;     now go through one shared table+loop (FN_TAB/FN_DISPATCH, modeled on
;     the existing ST_TAB/STMT statement dispatcher) instead of one
;     hand-written linear-chain stanza per keyword. CHR$/PEEK/USR/RND keep
;     their own hand-written stanzas -- each has a genuinely different
;     post-match shape (int-arg memory read, machine-code call, no
;     parens at all) that doesn't fit the uniform pattern, and unifying
;     4 one-off shapes doesn't pay for itself the way unifying 8 identical
;     ones does. DO_TRIG's old flag-passing indirection is gone entirely
;     (FN_TAB points SIN/COS straight at FLT_SIN/FLT_COS now).
;   - Found and fixed a real bug during this refactor: FN_DISPATCH is
;     entered via JSR, but on a keyword match it tail-jumps into the
;     handler via JMP (T2) rather than returning via RTS -- this left its
;     own JSR-pushed return address stranded on the stack, so the
;     handler's own RTS would return into that stale frame (inside
;     FN_DISPATCH's caller) instead of all the way back to EXPR2's true
;     caller. Fixed by discarding the stranded return address (PLA/PLA)
;     immediately before the tail-jump.
;   - Toolchain: rebuilt against a new asm65c02 (v1.14) that raises a hard
;     assembly error on an undefined symbol in an instruction operand,
;     instead of silently assembling it as $0000 (the exact bug class
;     that caused v1.7's RND crash, found and fixed in v1.9 before this
;     tool fix existed). sim65c02 embeds asm65c02.c directly and was
;     rebuilt alongside it.
;   - Showcase updated: sine-wave demo now steps I in radians (0 to ~2pi
;     by 0.2) instead of degrees (0 to 360 by 15); the SIN/COS identity
;     check uses SIN(0.5)/COS(0.5) instead of SIN(30)/COS(30). (Both
;     showcase edits originally used the shorthand ".2"/".5" form, which
;     silently parses as 0 in this BASIC -- caught by the sine wave
;     rendering as a flat vertical line instead of a curve; fixed to use
;     "0.2"/"0.5".)
;   - Regression: full suite re-run (relational ops, float FOR/NEXT,
;     DO_ERROR/IRQ_HANDLER, RND byte-identical to v1.5, SQR/ABS, SIN/COS
;     across quadrants in radians, ATN with range reduction verified
;     against DEG() round-tripping to the old degree-based test values,
;     ASIN/ACOS, full Mandelbrot+sine showcase) -- all pass.
;
; v1.9 (Jul 2026) — SQR() wired up; critical RND crash fixed
;   - FIXED (critical, introduced in v1.7): RND() would crash (or return
;     values outside [0,1)) after a few calls. Root cause: the v1.7 CORDIC
;     removal deleted a shared constant-loader block (FLT_10000_B/
;     FLT_360_B/FLT_32768_B, one shared RTS tail) because FLT_360_B/
;     FLT_10000_B were CORDIC-only -- but FLT_32768_B (needed by RND, used
;     nowhere near CORDIC) went with them by mistake. The reference to the
;     now-undefined FLT_32768_B didn't raise an assembly error; asm65c02
;     silently resolves undefined symbols to $0000, so "JSR FLT_32768_B"
;     assembled as "JSR $0000" -- a jump into T0's live zero-page scratch
;     data, executed as code. This is a real toolchain gap (undefined
;     symbols should be a hard error) worth fixing in asm65c02 itself at
;     some point, separate from this fix. Restored FLT_32768_B as a new
;     entry in the FLT_LDCONST/FLT_LDCONST_B table (cheaper than reviving
;     the old shared-tail routine, and consistent with how the other v1.7
;     constants are handled). Root-caused by isolating the exact failing
;     value (10293/32768) via a standalone test harness, then confirming
;     via the .LST that the JSR encoded to 20 00 00.
;   - ADDED: SQR( wired up as a real keyword (2-char prefix "SQ", no
;     collisions). ATN/ASIN/ACOS remain internal-only -- ROM is down to 9
;     bytes free after this fix, not enough room left for their dispatch
;     stanzas (~13-15 bytes each).
;   - Regression: full suite re-run (relational ops, float FOR/NEXT,
;     SIN/COS, SQR(), 40x RND() stress test now byte-identical to v1.5's
;     output, full Mandelbrot+sine showcase) -- all pass, all unchanged
;     from before this fix except RND no longer crashes.
;
; v1.8 (Jul 2026) — Tail-call/fallthrough byte savings
;   - ROM: 1 byte free (v1.7) -> 32 bytes free. No new features.
;   - No logic changes. Every `JMP TARGET` that was the last instruction of
;     a routine, where TARGET's code could instead be relocated to sit
;     immediately after it in ROM, was converted to a physical fallthrough
;     (JMP removed, TARGET's block moved to directly follow). Sites:
;     FLT_ABS (after E2NU's EAT_PAREN), FLT_ZERO (after FAZE), FLT_SUB/
;     FLT_NEGATE_B (after FLT_MOD), FLT_MUL (after RAD_TO_DEG), NORM_PACK
;     (after FMPK), FLT_DIV (after DIV_BY_TEN), FLT_NEGATE (after PARSE_NUM's
;     sign-apply, with FLT_NEGATE's own FND and the caller's FPSND merged
;     into one shared RTS), FLT_ATAN (after FLT_ASIN), FLT_SIN (after
;     FLT_COS, with FLT_COS/FLT_SIN swapped in file order to make the
;     fallthrough possible).
;   - Every fallthrough site was individually verified: the label formerly
;     reached via JMP is confirmed to be the very next non-comment line
;     after the JMP was removed, for all 9 sites. Full regression suite
;     re-run and confirmed byte-identical to v1.7 (relational operators,
;     float FOR/NEXT, DO_ERROR/IRQ_HANDLER line reporting, RND_SEED reseed
;     via PEEK, SIN/COS across all quadrants incl. >360 deg, SQRT/ATAN/
;     ASIN/ACOS via internal test harness, full Mandelbrot+sine showcase).
;
; v1.7 (Jul 2026) — Float-native SIN/COS + SQRT/ATAN/ASIN/ACOS
;   - REMOVED: the fixed-point CORDIC engine (CORDIC_KERN + old DO_TRIG
;     glue, 323 ROM bytes; CX/CY/CZ/TMPX/TMPY/MASKXZ/MASKY, 12 ZP bytes --
;     none of it used anywhere else). SIN/COS keyword dispatch (E2NSIN/
;     E2NCOS) is unchanged; only DO_TRIG's body was swapped.
;   - ADDED: FLT_SIN/FLT_COS, MBF4-native throughout (degrees in, matching
;     the old convention exactly): deg->rad, abs+mod-2pi range reduction
;     (reusing the existing FLT_MOD), fold to [0,pi] then [0,pi/2], then
;     the polynomial sin(x)~=x*(1-x^2*(0.16605-0.00761*x^2)) (~0.000164 max
;     abs error on [0,pi/2], better than CORDIC's ~0.05%).
;   - ADDED: FLT_SQRT (Newton-Raphson, 5 iterations, exponent-halving
;     initial guess; zero and negative-input guarded), FLT_ATAN (Pade
;     approximant core + range reduction for |x|>1 via
;     atan(x)=sign(x)*90-atan(1/x)), FLT_ASIN/FLT_ACOS (via the standard
;     asin(x)=atan(x/sqrt(1-x^2)), acos(x)=90-asin(x) identities). All are
;     internal subroutines only -- see OPEN ITEMS above.
;   - Extended the constant-table infrastructure (FLT_LDCONST/
;     FLT_LDCONST_B + one shared ROM table) built for FLT_ATAN to also
;     supply FLT_SIN's constants (pi/2, its two polynomial coefficients,
;     the degrees<->radians factors) -- avoids one-off loaders per constant.
;   - Net ROM effect of the whole swap: freed CORDIC (323B), spent it on
;     SQRT (76B) + constant infra/RAD_TO_DEG/ATAN_CORE (105B) + SIN/COS
;     (~220B) + public ATAN (80B) + ASIN/ACOS (~50B) combined. Also
;     extracted two small pre-existing duplicated code sequences (found via
;     asmdup.py) to close the final ~20-byte gap: the relational-operator
;     tail (</=/> parsing) and the DO_ERROR/IRQ_HANDLER shared "print IN
;     <line>, blank line, resume at MAIN" tail (now PRINT_IN_CURLN_MAIN).
;
; v1.6 (Jul 2026) — Floating-Point FOR/NEXT
;   - ROM usage: 3897 (v1.5) -> 3909 bytes (195 free after all additions).
;   - CHANGED: FOR/NEXT TO limit and STEP are now full 4-byte floats instead
;     of 16-bit-int-truncated staging values, so fractional STEP (e.g.
;     "STEP 0.5") and non-integer TO bounds are both supported and no
;     longer silently truncated.
;   - FOR_STK frame grew from 7 to 11 bytes/frame (var_slot + 4-byte limit +
;     4-byte step + loop_line) to hold the full floats; FSTK_BASE's index
;     multiplier changed from x7 to x11. This is RAM-only cost (frame stack
;     lives at $200, not ZP, since v1.5); ZP staging (FVAR/FLIM/FSTEP) grew
;     from 5 to 9 bytes, still well within free ZP.
;   - DO_NEXT's exit test now calls FLT_CMP directly on the post-add loop
;     variable vs. the float limit (var's sign vs. step's sign decides which
;     comparison outcome means "keep looping"), replacing the old int16
;     diff + sign-XOR trick.
;
; v1.5 (Jul 2026) — CORDIC Refactor, Duplicate Elimination & Feature Expansion
;   - ROM usage: 3879 (v1.4) -> 3897 bytes (193 free after all additions).
;   - ADDED: ABS(n), TAB(n), and float-normalized RND (16-bit Galois LFSR with
;     boot, NEW, and keyboard-wait jitter seeding).
;   - CHANGED: Relocated FOR/NEXT stack states (FVAR/FLIM/FSTEP/FOR_STK/FSTK)
;     from Zero Page to RAM, freeing 35 ZP bytes at a minor cost of 12 ROM bytes.
;   - CORDIC REFACTOR:
;     * Optimized CORDIC_KERN by stashing MASKXZ in X; reordered updates.
;     * Replaced 16-bit shift-multiply in DO_TRIG with 8-bit hardware multiply.
;     * Redesigned quadrant folding to use repeated subtraction and Gray-code
;       sign flags, replacing 4 range-check branches.
;     * Unified sin/cos indexed selections and merged constant store tails.
;   - DUPLICATE ELIMINATION (asmdup.py):
;     * Created VARIDX subroutine to handle variable offset calculations;
;       fixed case-insensitivity bug in DO_FOR.
;     * Created EAT_PAREN subroutine to unify expression parsing and delimiter
;       consumption across CHR$, USR, PEEK, SIN, and COS.
;     * Consolidated PUSH_FLT_A and POP_FLT_A into a unified routine via a
;       BIT-trick entry point; corrected STA instruction to use zero-page,X.
;   - CLEANUP: Removed the statement-separator caveat and the HELP keyword.
;
; v1.4 — FOR/NEXT, Floating-Point Sizing & Core Bug Fixes
;   - ROM usage: 3831 (v1.2) -> 3879 bytes (211 free).
;   - ADDED: FOR/NEXT loop control with a 4-level nested stack on Zero Page.
;     Uses FLT_ADD for loop variable updates.
;   - FLOAT SIZE OPTIMIZATION:
;     * Unified FLT_FROM_INT and FLT_FROM_INT_B into one indexed routine.
;     * Refactored NORM_PACK, FLT_ADD, FLT_MUL, and FLT_DIV (looped workspace
;       copies, TSB hidden-bit restoration, and combined STZ+BCS bounds checking).
;     * Replaced 8 inline float push/pop sequences with PUSH_FLT_A/POP_FLT_A
;       trampoline subroutines to preserve caller return addresses.
;   - FIXED: FLT_PRINT off-by-one bug that truncated single-digit fractional
;     floats (e.g., "1.5" printing as "1") via corrected CPY check.
;   - FIXED: FLT_PARSE digit accumulation bug where FLT_MUL clobbered the X
;     register; digit state is now stored in T0.
;   - uBASIC PORTS & CONSOLIDATIONS:
;     * Unified program pointer setups into PROG2X and comparison checks into PE_CMP_X.
;     * Shared LP increments via ADD2_LP/BUMP_LP and line-skips via LSKIP.
;     * Replaced INSLINE with a simpler backward-shift-copy algorithm.
;     * Consolidated variable writing across engine routines into STORE_VAR.
;   - 65C02 ADVANCEMENTS:
;     * Converted eligible static (zp),Y operations to (zp) no-index indirect mode.
;     * Replaced target PLA;TAX pairs with PLX in DO_LET and DO_INPUT.
;     * Optimized FLT_PRINT via INC A flag wrapping, stack-based digit caching
;       (PHA/PHX), and fractional loop reuse.
;
; v1.3 — GOSUB/RETURN & Keyword Engine Optimization
;   - ADDED: GOSUB and RETURN control flow with an 8-level Zero Page stack.
;     Uses a 3rd-character lookahead to multiplex GOTO/GOSUB and REM/RETURN.
;   - CHANGED: Replaced full-string keyword lookup with a space-saving 2-character
;     prefix matching scheme, enabling lenient matching (e.g., PRX for PRINT).
;
; v1.2 — Zero Page Contiguity & Documentation Pass
;   - CHANGED: Reorganized Zero Page into a fully contiguous $00-$B9 block.
;   - ADDED: Standardized headers (In/Out/Clobbers) across all subroutines.
;   - ADDED: Completely rewritten showcase program testing CORDIC sine and Mandelbrot.
;
; v1.1 — Memory Copy & Stack Protection Fixes
;   - FIXED: DELINE pointer corruption on edits/deletions with >=256 bytes
;     of trailing program text.
;   - FIXED: Immediate-mode GOTO crash by checking RUNSP state before
;     collapsing the runtime stack.
;   - CLEANUP: Removed dead float routines, reclaimed FLT_C ZP space, rerolled
;     utility routines into loops, and saved 68 bytes overall.
;
; MBF4: Byte0=biased_exp($00=zero), Byte1=sign|mant[22:16], Byte2-3=mant[15:0]
;       value=(-1)^sign * 2^(exp-$80) * 0.1mmm...
;       1.0=[$81,$00,$00,$00]  -1.0=[$81,$80,$00,$00]  10.0=[$84,$20,$00,$00]
;
; TRUE=-1.0  FALSE=0.0

         .opt proc65c02

; IO comms and constants
IO_OUT   = $E001            ; UART output: write character to terminal
IO_IN    = $E004            ; UART input: read character (0 = no char ready)
RAM_TOP  = $1000            ; first address above usable SRAM (4 KB)
IBUF_MAX = 31
CR       = $0D
LF       = $0A
BS       = $08

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
FP_LASTNZ: .RS 1             ; 8-bit:  FLT_PRINT index of last non-zero digit
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
; POKE, FREE, END) and every function (CHR$, PEEK, SIN, COS), plus a
; sine-wave plot and a floating-point Mandelbrot finale -- the pixel-plane
; scan itself is driven by fractional FOR/NEXT bounds (e.g.
; "FOR Y=-1 TO 0.95 STEP 0.0833"), with X/Y as the loop variables directly.
; `:` not supported#

PROG:
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
         .DB $F0,$00,"PRINT SIN(0.5)*SIN(0.5)+COS(0.5)*COS(0.5)",$0D
; line 250
         .DB $FA,$00,"PRINT ",$22,"=== sine wave ===",$22,$0D
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
         .DB $5E,$01,"I=I+0.2",$0D
; line 360
         .DB $68,$01,"IF I<=6.4 THEN GOTO 270",$0D
; line 370
         .DB $72,$01,"PRINT ",$22,"=== Mandelbrot finale ===",$22,$0D
; line 380
         .DB $7C,$01,"FOR Y=-1 TO 0.95 STEP 0.0833",$0D
; line 390
         .DB $86,$01,"FOR X=-2 TO 0.48 STEP 0.0417",$0D
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
         .DB $44,$02,"NEXT X",$0D
; line 600
         .DB $58,$02,"PRINT",$0D
; line 610
         .DB $62,$02,"NEXT Y",$0D
; line 650
         .DB $8A,$02,"END",$0D
SHOWCASE_END: ; audit

; ---- STRING/KEYWORD TABLE (page $F0) ----------------------------------------

         .ORG $F000
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
KW_ABS:    .DB "AB"
KW_RND:    .DB "RN"
KW_TAB:    .DB "TA"
KW_SQR:    .DB "SQ"
KW_ATN:    .DB "AT"
KW_ASIN:   .DB "AS"
KW_ACOS:   .DB "AC"
KW_DEG:    .DB "DE"

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
         JSR RESEED_RND         ; INIZ zeroed RND_SEED too, and 0 is a fixed
                                ; point for a Galois LFSR (stays 0 forever) --
                                ; reseed it with a non-zero value
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
         JMP PRINT_IN_CURLN_MAIN
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
         JMP PRINT_IN_CURLN_MAIN

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

; EAT_PAREN -- consume a delimiter+expr (EAT_EXPR), then consume one more
;   delimiter (the closing ')'). Shared by CHR$/PEEK/USR/SIN/COS parsing.
;   Clobbers: same as EAT_EXPR, plus WEAT's (none extra)
EAT_PAREN: JSR EAT_EXPR
           JMP WEAT

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
         BCS DPTB
         JSR EAT_PAREN
         JSR FLT_TO_INT
         LDA T0
         JSR PUTCH
         BRA DPA
DPTB:    LDA #<KW_TAB
         JSR MTCHKW
         BCS DPNC
         JSR EAT_PAREN
         JSR FLT_TO_INT
         LDA T0
         BEQ DPA               ; TAB(0) or negative: nothing to print
         TAX
DPTL:    LDA #' '
         JSR PUTCH
         DEX
         BNE DPTL
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
RESEED_RND:
         LDA #$AC
         STA RND_SEED           ; reseed RND too (0 is a fixed point for a
         LDA #$E1                 ; Galois LFSR, never reached again once
         STA RND_SEED+1              ; seeded non-zero, but NEW resets to a
         RTS                            ; known sequence, same as uBASIC)

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
         BCS E2NFN
         JMP EAT_PAREN
E2NFN:   JSR FN_DISPATCH        ; ABS/SQR/SIN/COS/ATN/ASIN/ACOS/PEEK/USR (FN_TAB)
         BCS E2NRND2            ; no match: try RND next. (A match tail-jumps
                                 ; into the handler and never returns here.)
E2NRND2: LDA #<KW_RND
         JSR MTCHKW
         BCS E2ND
         JSR RND_SHUFFLE
         LDA RND_SEED
         STA T0
         LDA RND_SEED+1
         AND #$7F              ; force positive (0-32767 range)
         STA T0+1
         JSR FLT_FROM_INT
         LDX #IDX_32768
         JSR FLT_LDCONST_B
         JMP FLT_DIV           ; RND() = LFSR value / 32768, so 0 <= x < 1
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
DLD:     RTS

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
         RTS

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
; =============================================================================
DO_FOR:
         JSR WPEEK_UC
         CMP #'A'
         BCC DFBADJ
         CMP #'Z'+1
         BCS DFBADJ
         JSR VARIDX            ; var_index*4 = byte offset into VARS
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
         LDX #3                 ; stage limit float FLT_A -> FLIM (4 bytes)
DFLCP:   LDA FLT_A,X
         STA FLIM,X
         DEX
         BPL DFLCP
         LDA #<KW_STEP
         JSR MTCHKW
         BCS DFNOSTEP
         JSR EXPR              ; evaluate step -> FLT_A
         BRA DFSCP
DFNOSTEP:
         LDA #1                ; default step = 1.0
         STA T0
         STZ T0+1
         JSR FLT_FROM_INT      ; FLT_A = 1.0
DFSCP:   LDX #3                 ; stage step float FLT_A -> FSTEP (4 bytes)
DFSCPL:  LDA FLT_A,X
         STA FSTEP,X
         DEX
         BPL DFSCPL
         LDA FSTEP              ; step of zero is illegal (exponent byte
         BNE DFSZOK              ;  0 == float value 0, per FLT_* convention)
         LDA #ERR_ST
         JMP DO_ERROR
DFSZOK:  LDA FSTK
         CMP #4                ; max 4 nested FOR loops
         BCC DFPUSH
         LDA #ERR_FOR
         JMP DO_ERROR
DFPUSH:  JSR FSTK_BASE          ; LP = FOR_STK + FSTK*11 (A already = FSTK)
         LDY #8                 ; copy FVAR,FLIM(4),FSTEP(4) (they're
DFCP:    LDA FVAR,Y              ; contiguous in ZP) into the frame in one pass
         STA (LP),Y
         DEY
         BPL DFCP
         LDY #9
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
;   Clobbers: A, X, Y, T0, T1, T2, LP, FLT_A, FLT_B, FLT_SA, FLT_SB, FLT_ER, FLT_DB
;
;   Both bound and step are now full floats. After VAR += STEP, FLT_CMP
;   compares VAR to LIMIT (-1/0/+1). Which outcomes mean "keep looping"
;   depends on STEP's sign, stashed on the hardware stack before FLT_ADD/
;   FLT_CMP get a chance to clobber FLT_B: for a positive STEP, loop unless
;   VAR>LIMIT; for a negative STEP, loop unless VAR<LIMIT. Landing exactly
;   on LIMIT (CMP==0) always loops once more (inclusive bound), same as
;   the old integer version.
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
         LDY #8                 ; copy step float, frame[5..8] -> FLT_B[0..3]
         LDX #3
DNCPB:   LDA (LP),Y
         STA FLT_B,X
         DEY
         DEX
         BPL DNCPB
         LDY #6                 ; frame[6] = step's sign|mant_hi byte;
         LDA (LP),Y              ; stash its sign bit now, before FLT_ADD/
         AND #$80                ; FLT_CMP get a chance to clobber FLT_B
         PHA
         JSR FLT_ADD            ; FLT_A = var + step
         LDA (LP)               ; var_slot again
         TAX
         JSR STORE_VAR           ; store updated loop variable back to VARS
         LDY #4                 ; copy limit float, frame[1..4] -> FLT_B[0..3]
         LDX #3
DNCPL:   LDA (LP),Y
         STA FLT_B,X
         DEY
         DEX
         BPL DNCPL
         JSR FLT_CMP             ; A = -1/0/+1 (var vs limit); FLT_A preserved
         STA T2                  ; stash compare result
         PLA                     ; recover step's sign bit
         BMI DN_negstep
         LDA T2                  ; positive step: loop unless var>limit
         CMP #1
         BEQ DN_done
         BRA DN_loop
DN_negstep:
         LDA T2                  ; negative step: loop unless var<limit
         CMP #$FF
         BEQ DN_done
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
DN_done: DEC FSTK                ; limit crossed: pop the frame, fall through
         RTS

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
         .DB <KW_DEG, <RAD_TO_DEG,>RAD_TO_DEG
         .DB <KW_PEEK,<FLT_PEEK,>FLT_PEEK
         .DB <KW_USR, <FLT_USR, >FLT_USR
         .DB $FF

; FLT_PEEK -- FLT_A = float(PEEK(FLT_A)).  In: FLT_A=address.  Clobbers: A,X,Y,T0.
FLT_PEEK:
         JSR FLT_TO_INT
         LDA (T0)
         STA T0
         STZ T0+1
         JMP FLT_FROM_INT

; FLT_USR -- call machine code at FLT_A (as an address); FLT_A = its
;   result (via USR_CALL/USR_RET).  Clobbers: A,X,Y,T0,T2 + whatever the
;   called routine clobbers.
FLT_USR:
         JSR FLT_TO_INT
         LDA T0
         STA T2
         LDA T0+1
         STA T2+1
         JMP USR_CALL

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
         PHX                    ; save table offset -- EAT_PAREN clobbers X
         JSR EAT_PAREN
         PLX
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
; PUSH_FLT_A / POP_FLT_A -- save/restore the 4-byte float FLT_A on the
; hardware stack, straddling arbitrary caller code (relational ops parking
; the left operand across a recursive EXPR_ADD call, FLT_PRINT parking the
; original value across its digit-scaling loop, etc).
;
; Merged into one routine: PUSH_FLT_A's entry stub sets X=3 then a BIT-
; trick (.DB $2C) swallows POP_FLT_A's own "LDX #-4" (2 bytes) so it falls
; straight into the shared return-address trampoline with X untouched.
; TXA re-tests X's sign to pick the push or pop path -- this can't be
; skipped even though LDX already set N/Z on entry, because the PLA pair
; just above it clobbers those flags first.
;
; Must be entered via JSR, not tail-called: each pops its own return
; address out of the way first, does the real push/pop, then pushes the
; address back before RTS. A plain JSR/RTS wrapper around PHA x4/PLA x4
; would break -- the parked frame must survive underneath the JSR's own
; return address across arbitrary intervening code, so its own RTS would
; otherwise consume the last 2 bytes of parked float data as a return
; address (confirmed by an earlier crash before this trampoline was added).
;
; The X=-4-counting-up-to-0 POP loop needs zero-page,X addressing to wrap
; correctly (STA FLT_A+4,X with X=$FC computes ($34+$FC) mod 256 = $30 =
; FLT_A, verified against the assembler's actual output) -- Y doesn't work
; here since STA has no zero-page,Y mode, only absolute,Y, which does a
; full 16-bit add instead of wrapping and would corrupt the stack page.
;
;   PUSH_FLT_A  In: FLT_A  Out: FLT_A pushed beneath caller's return addr
;               Clobbers: A, X, PFA_RL/PFA_RH
;   POP_FLT_A   In: -- (matching PUSH_FLT_A frame beneath the return addr)
;               Out: FLT_A restored  Clobbers: A, X, PFA_RL/PFA_RH
PUSH_FLT_A:
         LDX #3
         .DB $2C               ; BIT-trick: swallows POP_FLT_A's "LDX #-4"
POP_FLT_A:
         LDX #<-4
         PLA
         STA PFA_RL
         PLA
         STA PFA_RH
         TXA
         BMI POPL
PSHL:    LDA FLT_A,X
         PHA
         DEX
         BPL PSHL
PRET:    LDA PFA_RH
         PHA
         LDA PFA_RL
         PHA
         RTS
POPL:    PLA
         STA FLT_A+4,X
         INX
         BNE POPL
         BRA PRET              ; unconditional: X==0 here (BNE just fell through)

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
FAZE:    ; drop through

; FLT_ZERO -- FLT_A = 0.0.  Clobbers: A, X.
FLT_ZERO:
         LDX #3
FZL:     STZ FLT_A,X
         DEX
         BPL FZL
         RTS

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
         ;JMP FLT_SUB
         ; drop through

; =============================================================================
; FLT_SUB  --  FLT_A = FLT_A - FLT_B (negates FLT_B and falls into FLT_ADD)
;
;   In/Out/Clobbers: as FLT_ADD; also permanently negates FLT_B's sign
; =============================================================================
FLT_SUB: JSR FLT_NEGATE_B
         JSR FLT_ADD
;         JMP FLT_NEGATE_B
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
         JMP FLT_ZERO           ; S < 0: no complex support, clamp to 0.0
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
         TYA
         PHA                    ; protect the iteration counter across FLT_DIV
         JSR FLT_DIV            ; FLT_A = S / x_n  (FLT_DIV clobbers FLT_B)
         LDX #3                 ; restore x_n into FLT_B from T_X
NRRB:    LDA T_X,X
         STA FLT_B,X
         DEX
         BPL NRRB
         JSR FLT_ADD            ; FLT_A = (S/x_n) + x_n
         DEC FLT_A              ; /2 via exponent decrement (result is normalised)
         PLA
         TAY
         DEY
         BNE NR_LOOP
         RTS

; RAD_TO_DEG -- FLT_A = FLT_A * 57.29578 (radians -> degrees). Also wired
;   directly as the DEG(x) BASIC keyword (FN_TAB) since all the other trig
;   functions are radian-native now -- this is the only place degrees
;   still exist in the language, for a programmer who wants to display an
;   angle in degrees.
;   Clobbers: as FLT_MUL, plus X (const index)
RAD_TO_DEG:
         LDX #IDX_RADDEG
         JSR FLT_LDCONST_B
         ; drop through

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
         ;JMP FLT_DIV
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
;         JMP FLT_NEGATE
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
; FLT_CONST table  --  ROM-resident 4-byte MBF4 constants for ATAN/ASIN/ACOS,
;   loaded via FLT_LDCONST (-> FLT_A) / FLT_LDCONST_B (-> FLT_B). Values
;   computed to nearest MBF4 representation (round-to-nearest mantissa).
; =============================================================================
IDX_ATANCOEF = 0
IDX_ONE      = 1
IDX_RADDEG   = 2
IDX_PI_2     = 3
IDX_C1_SIN   = 4
IDX_C2_SIN   = 5
IDX_32768    = 6

CTAB_LO: .DB <C_ATANCOEF,<C_ONE,<C_RADDEG,<C_PI_2,<C_C1_SIN,<C_C2_SIN,<C_32768
C_ATANCOEF: .DB $7F,$0F,$CC,$E2  ; 0.28086 (FLT_ATAN_CORE Pade coefficient)
C_ONE:      .DB $81,$00,$00,$00  ; 1.0
C_RADDEG:   .DB $86,$65,$2E,$E1  ; 57.29578 (180/pi, radians -> degrees; DEG())
C_PI_2:     .DB $81,$49,$0F,$DB  ; 1.5707963 (pi/2, radians)
C_C1_SIN:   .DB $7E,$2A,$09,$03  ; 0.16605 (FLT_SIN polynomial coefficient)
C_C2_SIN:   .DB $79,$79,$5D,$4F  ; 0.00761 (FLT_SIN polynomial coefficient)
C_32768:    .DB $90,$00,$00,$00  ; 32768.0 (RND's LFSR->float divisor)

; FLT_CONST_PTR -- point T0 at constant X's 4 ROM bytes. All constants
;   (C_ATANCOEF..C_32768 above) are required to stay within page $FE --
;   confirmed at $FE4B-$FE66 as of this writing. If the table ever grows
;   past $FEFF, this hardcoded high byte silently breaks (same bug class
;   as the v1.9 FLT_32768_B incident) -- check with --dump-all before
;   adding more constants here.
;   Clobbers: A, T0.
FLT_CONST_PTR:
         LDA CTAB_LO,X
         STA T0
         LDA #$FE
         STA T0+1
         RTS

; FLT_LDCONST  -- In: X=const index (IDX_*).  Out: FLT_A = constant[X].
;   Clobbers: A, X, Y, T0
FLT_LDCONST:
         JSR FLT_CONST_PTR
         LDY #3
FLCA:    LDA (T0),Y
         STA FLT_A,Y
         DEY
         BPL FLCA
         RTS

; FLT_LDCONST_B -- In: X=const index (IDX_*).  Out: FLT_B = constant[X].
;   Clobbers: A, X, Y, T0
FLT_LDCONST_B:
         JSR FLT_CONST_PTR
         LDY #3
FLCB:    LDA (T0),Y
         STA FLT_B,Y
         DEY
         BPL FLCB
         RTS

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
;   Clobbers: as FLT_SQRT/FLT_ATAN combined
; =============================================================================
FLT_ASIN:
         JSR PUSH_FLT_A         ; stack: [x]
         JSR FLT_A_TO_B         ; FLT_B = x
         JSR FLT_MUL            ; FLT_A = x^2
         JSR FLT_A_TO_B         ; FLT_B = x^2
         LDX #IDX_ONE
         JSR FLT_LDCONST        ; FLT_A = 1.0
         JSR FLT_SUB            ; FLT_A = 1.0 - x^2
         JSR FLT_SQRT           ; FLT_A = sqrt(1-x^2)
         JSR FLT_A_TO_B         ; FLT_B = sqrt(1-x^2)
         JSR POP_FLT_A          ; FLT_A = x
         JSR FLT_DIV            ; FLT_A = x / sqrt(1-x^2)
;         JMP FLT_ATAN           ; tail: atan(...), radians
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
         JMP FLT_ATAN_CORE     ; tail: FLT_A = atan_core_rad(x); RTS

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
; polynomial implementation (MBF4 throughout; replaces the old fixed-point
; CORDIC engine, freeing 323 ROM bytes / 12 ZP bytes it used exclusively).
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
;         JMP FLT_SIN            ; sin(pi/2-x) = cos(x)
        ; drop through
; =============================================================================
; FLT_SIN  --  FLT_A = sin(FLT_A), RADIANS (any magnitude/sign)
;
;   In:  FLT_A = angle, radians
;   Out: FLT_A = sin(angle), accurate to ~0.0002 (better than the old
;        CORDIC's documented ~0.05%, back when this was degrees/fixed-point)
;   Clobbers: A, X, Y, T0, T1, T_S, T_X, FLT_B, FLT_SA, FLT_SB, FLT_ER,
;             FLT_DE, FLT_DB, FLT_MA, FLT_MB, FLT_MC, FLT_DVH, FLT_DVM, FLT_DVL
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

         LDX #IDX_PI_2
         JSR FLT_LDCONST_B     ; FLT_B = pi/2
         INC FLT_B             ; FLT_B = pi     (exponent-INC = *2, since
         INC FLT_B             ; FLT_B = 2*pi    NORM_PACK always leaves
                                ;                 constants normalised)
         JSR FLT_MOD           ; FLT_A = |x| mod 2*pi (already non-negative
                                ;  in, so no C-style-negative-remainder fixup
                                ;  needed out)

         LDX #IDX_PI_2         ; fold [0,2pi) -> [0,pi]: if (x mod 2pi) > pi,
         JSR FLT_LDCONST_B     ;  use (x mod 2pi) - pi and flip the sign
         INC FLT_B             ;  we'll apply at the end (sin(x)=-sin(x-pi))
         JSR FLT_SUB            ; FLT_A = (x mod 2pi) - pi
         LDA FLT_A+1
         BPL FS_GT_PI
         LDX #IDX_PI_2          ; <= pi: undo the subtraction (add pi back)
         JSR FLT_LDCONST_B
         INC FLT_B
         JSR FLT_ADD
         BRA FS_FOLD2
FS_GT_PI: PLA
         EOR #$80
         PHA                    ; flip the stashed sign

FS_FOLD2:                       ; fold [0,pi] -> [0,pi/2]: sin(x)=sin(pi-x)
         LDX #3
FS1SV:   LDA FLT_A,X
         STA T_X,X              ; T_X = x (save explicitly; FLT_SUB's FLT_B
         DEX                     ; side effects aren't guaranteed byte-exact
         BPL FS1SV                ; beyond the documented "restored" primitives)
         LDX #IDX_PI_2
         JSR FLT_LDCONST_B          ; FLT_B = pi/2
         JSR FLT_SUB                  ; FLT_A = x - pi/2
         LDA FLT_A+1
         BMI FS_LE_PI2                 ; x < pi/2: keep x as-is
         JSR FLT_A_TO_B                 ; x >= pi/2: new_x = pi/2 - (x-pi/2)
         LDX #IDX_PI_2                    ;          = pi - x
         JSR FLT_LDCONST
         JSR FLT_SUB
         BRA FS_POLY
FS_LE_PI2: LDX #3
FS1RS:   LDA T_X,X
         STA FLT_A,X
         DEX
         BPL FS1RS

FS_POLY:                        ; sin(x) ~= x*(1 - x^2*(C1 - C2*x^2))
         LDX #3
FS2SV:   LDA FLT_A,X
         STA T_S,X              ; T_S = x (post-fold, in [0,pi/2])
         DEX
         BPL FS2SV
         JSR FLT_A_TO_B
         JSR FLT_MUL            ; FLT_A = x^2
         LDX #3
FS3SV:   LDA FLT_A,X
         STA T_X,X              ; T_X = x^2
         DEX
         BPL FS3SV
         LDX #IDX_C2_SIN
         JSR FLT_LDCONST_B      ; FLT_B = 0.00761
         JSR FLT_MUL            ; FLT_A = 0.00761 * x^2
         JSR FLT_A_TO_B
         LDX #IDX_C1_SIN
         JSR FLT_LDCONST        ; FLT_A = 0.16605
         JSR FLT_SUB            ; FLT_A = 0.16605 - 0.00761*x^2
         LDX #3
FS3RS:   LDA T_X,X
         STA FLT_B,X            ; FLT_B = x^2 (restored)
         DEX
         BPL FS3RS
         JSR FLT_MUL            ; FLT_A = x^2 * (0.16605 - 0.00761*x^2)
         JSR FLT_A_TO_B
         LDX #IDX_ONE
         JSR FLT_LDCONST        ; FLT_A = 1.0
         JSR FLT_SUB            ; FLT_A = 1.0 - x^2*(...)
         LDX #3
FS2RS:   LDA T_S,X
         STA FLT_B,X            ; FLT_B = x (restored)
         DEX
         BPL FS2RS
         JSR FLT_MUL            ; FLT_A = x * (1.0 - x^2*(...)) = sin(x)

         PLA                    ; retrieve final sign
         EOR FLT_A+1
         STA FLT_A+1
         RTS

ROMEND: ; audit

        ; vectors
         .ORG $FFFC
         .DW INIT
         .DW IRQ_HANDLER
