; =============================================================================
; 4K Integer BASIC v15.18 for the 65C02
;
; Copyright (c) 2026 Vincent Crabtree, licensed under the MIT License, see LICENSE
;
; A fully-featured, self-contained integer Tiny BASIC interpreter in 4 KB of ROM.
; Pre-loaded showcase program + Mandelbrot renderer (type RUN to execute,
; LIST to view, NEW to clear and enter your own program).
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
;   INPUT var          read from keyboard
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
;                    HEX$(n)             n as 4-digit hex, MSB first  (PRINT only)
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
; v15.18 (Aug 2026) - 508 bytes free
;   RESTORED: HEX$(n) as a PRINT-only item, mirroring CHR$/TAB's existing
;   PRINT-only scoping (v15.17 note): "HEX$(n)" only recognized inside a
;   PRINT item list, not as a general EXPR2 atom -- consistent with the
;   v15.0 removal note ("REMOVED ... HEX$ ... to fit CORDIC engine") and
;   the v12.4 note about a "PRT_HEX" routine, both suggesting this existed
;   before and is being restored rather than newly invented.
;   New token TOK_HEXS = $AA (next free slot after TOK_COS); appended to
;   KW_TABLE (order-independent here since HEX$ is dispatched directly by
;   DO_PRINT via CMP, like TAB/CHR$, not through the FUNC_JT contiguous-
;   range trick, so it did not need to slot inside the Group A run).
;   DO_PRINT: new DP_chk_hexs check between the existing CHR$ and default-
;   expression checks; reuses E2_chrs (already the generic "consume token,
;   eat (expr) -> T0" helper shared by ABS/PEEK/USR) to parse HEX$(n).
;
; v15.17 (Aug 2026) - 521 bytes free
;   EXPR2 function dispatch: CMP/BEQ chain -> FUNC_JT indexed jump table
;   Renumbered TOK_ABS/PEEK/USR/SIN/COS (Group A, uniform 1-arg) and
;   TOK_RND (Group B, 0-arg) to be contiguous at $A5-$A9/$A4, so EXPR2 can
;   range-test + index into a table instead of a per-token CMP chain.
;   Centralized the "consume token, eat '(' expr ')'" step (previously
;   each handler's own JSR E2_chrs) into the dispatcher itself, once.
;   TRYKW/DO_LIST are purely KW_TABLE-position-derived, so the reorder
;   needed no changes there -- confirmed by inspection and by regression.
;   E2_usr: added explicit LDA T0 to restore its documented "A = T0 lo
;   byte" entry invariant, since it's no longer an incidental side effect
;   of who calls E2_chrs.
;
;   CHR$ scoped to PRINT-only (removed from EXPR2's general dispatch);
;   DO_PRINT's own TOK_CHRS check is unchanged. "X=CHR$(65)" no longer
;   parses; "PRINT CHR$(65)" still does. -4 bytes.
;
;   RUN corrupts the stored bytes of program line 1 as
;   a side effect of execution -- reproduces on the pristine v15.16 build
;   too, so unrelated to this change; LIST *after* RUN shows a garbled
;   first line, LIST run first is unaffected.
;
; v15.16 (Aug 2026) - 453 bytes free
;   E2_SIN/E2_COS REVIEW (completing the pass 4 review)
;   The CORDIC_KERN restructuring in v15.15 came from a larger suggested
;   refactor that also covered the whole E2_sin/E2_cos angle-fold/negate/
;   scale pipeline -- only CORDIC_KERN itself was reviewed and applied
;   last time; the rest was an oversight, not a rejection. Reviewed and
;   applied the remaining four pieces this pass, each checked for
;   equivalence before implementing:
;
;   1) Angle-fold restructured from four explicit quadrant branches
;      (SC_IN/SC_Q4/SC_LO/SC_Q2/SC_Q1, splitting on the hi-byte boundary
;      at 255/256) to a two-step geometric fold (fold >180 via a 16-bit
;      subtract, flags=3; then fold >90 via the ~A+1+180=180-A trick,
;      flags^=1). Traced all four quadrants by hand against the old
;      branch logic, including the 255/256 hi-byte transition specifically
;      since that's where a 16-bit-vs-8-bit subtraction bug would show up
;      -- folded angles and quadrant flags match old logic exactly in
;      every case. +18 bytes.
;   2) Quadrant negation: LSR T1 (memory-direct) instead of LDA T1/LSR
;      into A -- removes the "reload T1, A may have been clobbered by
;      NEG_X" step entirely since each check now reads T1 fresh from
;      zero page rather than a stale register copy. +3 bytes.
;   3) Result select (SIN vs COS): both now go through TO_T0 with a
;      dynamiclly-chosen X offset (default CY, override to CX for COS)
;      instead of TO_T0 for COS but a separate 4-instruction manual copy
;      for SIN. +8 bytes.
;   4) Sign handling: ATEMP now stores T0+1's raw byte directly (bit 7 is
;      the sign) instead of building an explicit 0/1 flag via a branch.
;      This is NOT cosmetic -- it requires the later "apply sign" check
;      to change from BEQ (tests for exact zero) to BIT/BPL (tests bit 7
;      only), or it would be a live bug; both sides updated together.
;      Kept the existing fall-through into NEG16 (no JSR/JMP needed) --
;      the suggested refactor's "JMP NEG16" would have cost 3 bytes for
;      something the file already gets for free via code adjacency.
;      +6 bytes.
;
; v15.15 (Aug 2026) - SIZE PASS 4 + REM BUG FIX
;   Continued the general size-optimization pass on the hand-optimized
;   v15.14 base, then fixed a real correctness bug found along the way.
;
;   CMP_T0_LP: the two INSLINE compares (T0 vs LP) reverted to inline in
;   the earlier CMP16 pass (both live inside a loop that holds Y at a
;   constant 0 for its own (T0),y/(T1),y addressing, which CMP16's
;   (ZP0),y trick would clobber) turned out to be safely extractable
;   anyway -- a FIXED-operand compare (no X/Y parameterization, doesn't
;   touch Y at all) has none of that hazard. +3 bytes.
;
;   CORDIC_KERN restructured (reviewed a suggested refactor for
;   correctness before implementing): instead of two separate branches
;   (d=+1 doing SUB, d=-1 doing ADD) each duplicating the CY>>i and
;   CX_SAV>>i shift setup, conditionally NEG16 the shifted value first
;   and always ADDT0_TO -- "negate then add" unifies what were two
;   separate operations into one, and each shift now naturally happens
;   only once (no duplication to hoist out). This made SHIFT_CY,
;   SHIFT_CXSAV, and SUBT0_FROM (added in the previous two passes)
;   entirely unused -- removed all three. Verified equivalence by hand
;   for all three CZ-sign branches before implementing. +40 bytes.
;
;   RD_uint (DATA value parsing): AND #$0F instead of SEC/SBC #'0' for
;   ASCII-digit-to-value (saves 1 byte), TAY/TYA instead of PHA/PLA to
;   stash the digit (same byte cost, free speed win), and restructured
;   the *10 multiply to reuse the already-doubled T0 for T1 instead of
;   computing T1 from scratch. +5 bytes.
;
;   RD_next_val (DATA/READ line scanning) restructured to share the
;   "$0D exhaustion: advance past it, go to RD_find" logic between
;   RD_body's and RD_skip_ln's $0D cases (previously two near-identical
;   copies), and dropped a redundant STZ DATA_PTR (the preceding ORA
;   already proved it's 0). Traced both scan loops by hand to confirm
;   RD_skip_ln's TOK_NUM handling still never tests a number's lo/hi
;   payload byte against $0D -- once the $FF marker is detected all 3
;   bytes are unconditionally skipped without re-inspection, so checking
;   $0D before TOK_NUM in the loop is safe. Used the existing DATAPTRADD2
;   helper (one JSR, advances by 2) instead of duplicating two separate
;   advance-by-1 calls. +5 bytes.
;
;   REM BUG (found while reviewing the above, not a hunted-for target):
;   TOKENIZE's REM handling pushed TOK_REM, then copied the comment text
;   via a dedicated loop, and only popped+emitted TOK_REM AFTER the text
;   -- the token landed AFTER the comment in the tokenized stream instead
;   of before it. LIST showed "25 REM INSERTED" as "25 INSERTEDREM", and
;   RUNning a line with a REM crashed with "UK ERR" (STMT read the first
;   raw text byte as an unrecognized statement token). Root-caused by
;   tracing TRY_matched_adv's PHA/PLA pairing against DATA's already-
;   correct token-first handling. Fixed by mirroring DATA's pattern
;   exactly: emit TOK_REM first, then reuse the existing TRY_raw copy-
;   until-$0D loop (same one DATA already uses) instead of a separate,
;   buggy TRY_rem loop -- which also let the redundant loop be deleted.
;   +8 bytes (fix and size win together). Verified: the exact edittest.txt
;   repro (insert "25 REM INSERTED" into an existing program) now LISTs
;   correctly and RUNs without error; also tested empty REM, REM as the
;   final line, and REM mixed with other statements.
;
; v15.14 (Aug 2026) - HAND-OPTIMIZED BASE ADOPTED
;   Swapped to a hand-optimized upload as the new base (archived the prior
;   copy as archive/4kBASIC_v15.13_pre_handopt.asm). Substantial rework:
;   KW_TABLE/STMT_JT/DO_ERROR relocated, several routines renamed (e.g.
;   TKADV -> INC_T0), expression-atom tokens renumbered $96-$A9, removed
;   commands (CLS/HELP/ON/INKEY/SGN) replaced with STMT_JT placeholder
;   entries. Too extensive to line-diff meaningfully, so verified by full
;   regression instead of audit: all 12 scripts (general coverage,
;   relational operators x2, deep trig/div/mod/goto/gosub/for-next,
;   isolated FOR/NEXT, line-editing, negative-DATA, SKIPEOL colon-chains
;   x2, tokenized-number edge values, full CORDIC quadrant sweep) produce
;   correct results. Specifically re-verified the v15.12 DELINE page-
;   boundary fix survived the rework (both the page-crossing replace and
;   page-crossing delete repros) -- it did, still correct. Fresh baselines
;   captured against this build for future regression comparisons (prior
;   baselines are stale: token renumbering changes cycle counts and some
;   detokenized LIST spacing, though not program semantics).
;   Net: 321 bytes free (up from 216 on the pre-handopt build).
;
; v15.13 (Aug 2026) - HANDOFF REVIEW cont'd: TOKSKIP_LP/TOKSKIP_IP dedup
;   Factored out the two shared helpers the handoff had designed (sizes
;   estimated, not yet deployed) but never actually wired in: EL_len,
;   DL_ll (both scan (LP),Y), and IN_cnt, GT_sk (both scan (IP),Y) were
;   four byte-for-byte identical 15-byte TOK_NUM-aware $0D scan loops --
;   confirmed identical by reading all four before touching any of them.
;   Extracted TOKSKIP_LP and TOKSKIP_IP (each: loop body + RTS, ~16 bytes),
;   call sites become `LDY #n / JSR TOKSKIP_xx` (the LDY stays -- that's
;   caller-specific starting offset, not part of the shared scan). Per the
;   handoff's own note: IN_cp (copy loop, not a pure scan) and RD_skip_ln
;   (uses the separate DATA_PTR, not LP/IP) are correctly NOT part of this
;   -- left as their own tuned implementations, unchanged.
;
; v15.12 (Aug 2026) - HANDOFF REVIEW: tokenized-EOL-scan bug inventory
;   DELINE's LP-preservation issue (handoff flagged as suspected-but-
;   unconfirmed, comparison-only against mini-BASIC's pattern): CONFIRMED
;   live and triggered. DELINE's shift-copy loop increments LP+1 on every
;   256-byte page-boundary crossing as the destination pointer advances,
;   and never restores it -- so replacing/deleting an existing line (the
;   only path that calls DELINE) whose shift crosses a page boundary
;   leaves LP pointing past the true insertion point. INSLINE (called
;   right after DELINE on the replace-line path) trusts LP as-is, so the
;   new line content gets spliced into whatever line LP now points at
;   instead of the intended position. Reproduced with a 59-line program:
;   replacing line 1 spliced "1 PRINT 999" into the middle of line 38.
;   Fixed exactly as the handoff prescribed: PHA/PHA the LP bytes before
;   the shift loop (only on the branch that actually shifts anything --
;   the nothing-to-shift fast path never touches LP, so it's left alone),
;   PLA/PLA restore after. +12 bytes (handoff estimated ~8; the difference
;   is the branch-around for the fast path). Reproduced the exact failure
;   first, confirmed the fix resolves it (line 1 correctly at the front,
;   line 38 no longer corrupted), then confirmed a plain page-crossing
;   delete (no replace) and an ordinary small non-crossing replace both
;   still work, then ran the full regression suite.
;
; v15.11 (Aug 2026) - SIZE OPTIMIZATION PASS 3/N (code golf, size not speed)
;   Tier 3: the 16-bit equality-compare duplicates (asmdup found 10, not
;   the 3-7 originally estimated). Implemented per explicit direction to
;   avoid inline-parameters-after-JSR: added ZP0, a permanent $0000 zp
;   pointer (placed in the existing .RS chain, so it's zeroed for free by
;   INIT's cold-boot DO_NEW clear -- no dedicated init cost), which lets
;   CMP (ZP0),y address a destination directly via Y the way zp,X already
;   lets X address a source directly -- STA/CMP don't support zp,Y, so
;   this is the equivalent trick using the $D1 CMP (zp),y opcode.
;     CMP16 (X = zp addr of A, Y = zp addr of B, returns Z iff A==B,
;     same early-exit-on-low-byte-mismatch semantics as the inline code
;     it replaces) -- 8x converted, net +12 bytes (see bug note below for
;     why not 10x).
;
;   BUG FOUND AND FIXED before this reached the file permanently:
;   INSLINE's byte-shift-on-insert loop (IN_bk, around line ~950) uses
;   (T0),y / (T1),y indirect addressing with Y held at a constant 0 for
;   the whole loop -- it advances by decrementing T0/T1 themselves, not
;   by incrementing Y. CMP16 clobbers Y as part of the (ZP0),y trick and
;   never restores it. Converting IN_bk's two compares (the loop-entry
;   check and the loop-continuation check) to CMP16 left Y non-zero
;   after the first JSR, so every subsequent byte of the shift copied
;   from/to the wrong offset -- silently corrupting the program store
;   on the second and later line insertions (first-line insert has
;   nothing to shift, so it looked fine until tested further). Caught by
;   the regression suite (FOR/NEXT threw "UK ERR", LIST showed garbled
;   lines), root-caused via the LIST-after-entry test, fixed by leaving
;   those two sites as inline compares -- both use plain LDA/CMP/BNE
;   with no zp,Y trick, so Y is never touched. All other 8 CMP16 sites
;   audited individually for the same hazard: every one either uses the
;   Y-less 65C02 (zp) indirect mode afterward or explicitly reloads Y
;   before using it, so none share this problem.
;   General takeaway for future passes: CMP16/any (ZP0),y-based helper
;   is only safe to call where the surrounding code doesn't have a live
;   Y across the call -- check for (zp),y addressing in the enclosing
;   loop before converting a compare inside it, not just immediately
;   after the converted block.
;   Also caught: RD_parse (negative DATA literal parsing) inlined a
;   16-bit negate-in-place on T0 that's byte-for-byte what NEG16 already
;   does. Replaced with JSR NEG16 (NEG16's default entry is X=0, i.e.
;   T0, so no setup needed). +10 bytes.
;
; v15.10 (Aug 2026) - SIZE OPTIMIZATION PASS 2/N (code golf, size not speed)
;   Base for this pass was a WIP upload that had already independently
;   applied pass-1-equivalent peephole fixes, reworked the zero page to
;   use .RS allocation, refactored GETLINE (shared prompt, max-length
;   enforcement), AND cleanly fixed the REL_F/REL_T false-positive STZ
;   issue flagged in pass 1 -- REL_T now does DEC T0/DEC T0+1 onto a
;   value both paths unconditionally STZ first, instead of the old
;   BIT-skip trick that made REL_F's STA a two-different-A-values join
;   point. That fix is cleaner than anything pass 1 would have done, so
;   it's adopted as-is.
;
;   Ran asmdup.py again against this base and extracted five shared
;   16-bit helper bodies (added after NEG_X, same calling convention:
;   caller pre-loads X with (target_zp - T0); zero-page,X wraps mod 256
;   so it reaches any zero-page location regardless of distance from T0):
;     TO_T0        - copy a 16-bit zp value into T0                 (11x)
;     T0_TO_CURLN  - copy T0 into CURLN (fixed src/dst, no X needed)  (4x)
;     STORE_VAR    - store T0 into VARS[x]                           (4x)
;     ADDT0_TO     - add T0 into a 16-bit zp accumulator              (3x)
;     GETVARC      - GETCI+UC+SEC+SBC #'A' shared prefix              (3x)
;   One STORE_VAR call site (DO_let_var) was a tail call -- used
;   JMP STORE_VAR instead of JSR+RTS for one more byte.
;   Net: 173 bytes free (was 108 on the WIP base's own build; that base's
;   own header note of "77 bytes free" predates its final GETLINE pass).
;
;   Left for a later pass (deliberately not touched here):
;     - ~8 remaining 16-bit copies with arbitrary (non-T0/non-CURLN)
;       src/dst pairs, the CMP16 equality-compare idiom (LP/PE, T0/LP,
;       IP/PE), and SETPTR16 (immediate 16-bit load into a zp pointer,
;       13x) -- all need genuine two-arbitrary-operand parameter passing
;       (inline-parameter-after-JSR technique), higher complexity/risk
;       than anything in this pass.
;     - EXPR2's token-dispatch CMP/BEQ chain -> jump table (mirroring
;       STMT's existing JMP (STMT_JT,X)) -- explicitly deferred pending
;       an architecture discussion, not an implementation question.
;
; v15.9 (Aug 2026) - 77 bytes free
;  Refactor Zero page to use .RS instead of hard coded addresses. 
;  Refactor GETLINE to limit input to Max chars with common Prompt.
;  SIZE OPTIMIZATION PASS 1/N (code golf, size not speed)
;       11x  LDA #0 + STA <addr>   -> STZ <addr>      (2 bytes each)
;        7x  JMP <in-BRA-range>    -> BRA             (1 byte each)
;        4x  PLA + TAX             -> PLX             (1 byte each)
;        1x  TXA + PHA             -> PHX             (1 byte)
;
; v15.8 (Aug 2026) - BUG FIX (line-terminator scanning)
;   - TOKENIZE bug stores numbers as a 3-byte token, TOK_NUM
;     ($FF) followed by a little-endian lo/hi pair, and terminates each line
;     with $0D. Several scan/copy loops located line/statement boundaries by
;     naively comparing every raw byte to $0D (or ':'), without recognising
;     that they might be inside a number token's lo/hi payload. Any number
;     literal with a lo or hi byte equal to 13 ($0D) -- e.g. 13, 269, 525,
;     3328-3583, etc. -- was misread as an end-of-line (or, for SKIP_STMT,
;     also end-of-statement) marker, corrupting program-store scanning.
;     Reproduced with a single line ("5 A=13" alone corrupted the store).
;     Fixed by giving each affected loop the same token-aware shape already
;     used correctly by DO_LIST's LS_body/LS_skip_body and by DO_IF_f's
;     ELSE-scan: on seeing TOK_NUM, unconditionally skip the following 2 (or,
;     where the loop advances via a subroutine call per byte, 3 including the
;     marker) bytes without testing them against the terminator. Fixed sites:
;       EDITLN   (EL_len)         - scan to next stored line during insert/replace
;       DELINE   (DL_ll)          - scan body to find deleted line's byte count
;       INSLINE  (IN_cnt, IN_cp)  - body-length scan and payload copy loop
;       READ/DATA(RD_skip_ln)     - scan non-DATA lines while hunting for DATA
;       GOTOL    (GT_sk)          - scan to next stored line while searching
;       SKIP_STMT                 - scan to ':' or $0D (used by DO_NEXT to find
;                                   a colon-chained statement after FOR)
;       SKIPEOL                   - scan to $0D (used every RUNLP iteration and
;                                   by DO_ELSE_SK; the most frequently hit site)
;
; v15.7 (Jul 2026) - 110 bytes free 
;   - OPTIMISED: DO_FOR variable-letter validation. Consumes the letter via
;     GETCI first, then validates with SEC/SBC #'A'/CMP #26 (one-sided
;     range check) instead of the previous WPEEK_UC/CMP 'A'/CMP 'Z'+1
;   - OPTIMISED: DO_FOR step storage deferred to one shared store point
;     (DO_for_havestep) instead of duplicating LDA/STA pairs in both the
;     STEP and no-STEP branches; the no-STEP branch now just loads the
;     default (1,0) into A/X and falls through to the same store the STEP
;     branch uses.
;   - OPTIMISED: DO_FOR and DO_NEXT each had a redundant LDA FSTK
;     immediately after a CMP/BNE that had just loaded the identical value
;   - OPTIMISED: DO_NEXT's optional variable-name consumption uses
;     SEC/SBC #'A'/CMP #26 (matching DO_FOR's pattern above) instead of
;     two absolute bounds checks.
;   - OPTIMISED (largest single change): DO_NEXT's comparison logic
;     replaced. Previously: load limit into T0, branch on step sign, then
;     two near-mirrored branches (positive-step / negative-step) each with
;     their own equality special-case (~67 bytes). Now: a single unified
;     signed compare -- diff = var - limit; if diff==0 the limit is met
;     exactly (inclusive: always loop once more); otherwise XOR diff's
;     sign with the step's sign -- differing signs means the limit has not
;     yet been reached (keep looping), matching signs means it has been
;     crossed (stop). 
;
; v15.6 
;   - NEW: LIST n,m -- optional line-number range (bare LIST unchanged).
;     Lines below n are walked via a new, minimal, token-aware skip loop
;     (LS_skip_body/LS_skip_hdr) that recognises $FF (2-byte literal
;     marker) and $0D (end of line) only -- no KW_TABLE walk needed, since
;     every keyword is one byte in the stored stream regardless of its
;     printed length.
;   - NEW: GET_TWO_ARGS -- shared <expr>,<expr> parser for DO_LIST, DO_POKE
;   - Range checks store the hi-bound in CY (free CORDIC scratch, unused
;     outside SIN/COS) rather than T2: T2 is clobbered mid-scan by the
;     existing KW_TABLE walk in the print path, which would otherwise
;     corrupt the hi-bound after the first keyword-containing line printed.
;
; v15.5 
;   - Ported INSLINE from uBASIC6502b: the shift-up loop no longer counts
;     bytes into a scratch register and calls a shared decrement helper
;     per byte copied. Instead the moving source/dest pointers are compared
;     directly against LP each iteration, stopping exactly when the shift
;     is done. Removes T2 usage from INSLINE entirely and drops the total-
;     byte-count hardware-stack juggling (TSX/peek) the old version needed
;     to keep the OOM-checked total alive across the shift.
;   - Deleted T2DEC (shared 16-bit decrement-and-test helper). INSLINE no
;     longer calls it; DELINE's own single call site was inlined directly
;   - OOM check simplified to a hi-byte-only compare (new_PE_hi vs
;     >RAM_TOP), exactly correct rather than approximate because
;     RAM_TOP=$1000 is page-aligned; flagged in the routine header for any
;     future RAM_TOP change.
;
; v15.4 
;   - Reordered zero page: FVAR/FLIM/FSTEP inserted immediately before CURLN,
;     forming a contiguous 7-byte run [FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1,
;     CURLN,CURLN+1] matching the FOR_STK frame layout exactly. DO_FOR now
;     stages var_slot/limit/step directly into this block (no hardware-stack
;     juggling) and pushes the frame with one indexed copy loop instead of
;     7 unrolled LDA/STA/INY sequences. DO_NEXT unchanged (its per-field
;     logic -- VARS indexing, signed step add, limit compare -- does not
;     benefit from a blind copy loop the way a push does).
;   - Merged DO_GOTO and DO_GOSUB's duplicated GOTOL/error/CURLN-update tail
;     into one shared block (DO_go_common), entered directly by GOTO or
;     after the return-frame push by GOSUB.
;   - Replaced the ZP-bounce workaround for the relational-mask combine
;     (STX/LDA/ORA/TAX) with direct opcode injection (.DB $19 / .DW REL_MASK
;     = ORA REL_MASK,Y) since the assembler lacks the abs,Y mnemonic form for
;     ORA. Verified correct with an isolated test before applying.
;
; v15.3 
;   - FIXED: Cold-start Zero Page clear loop condition changed from BPL to BNE.
;   - FIXED: Single-line colon-chained FOR/NEXT execution via new SKIP_STMT logic.
;   - FIXED: Trailing colon evaluation bug in PRINT statement output.
;   - NOTE: Multi-FOR headers sharing a single line remains a documented limitation.
;
; v15.2 (Jul 2026) - 67 bytes free
;   - Rewrote pre-loaded RAM showcase to self-checking test suite.
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
IBUF_MAX = 31
BELL     = 7
BS       = 8
CR       = $0D

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
TOK_CLS     = $8F            ; CLS  
TOK_HELP    = $90            ; HELP  
; TOK_ON ($91) removed v15.0 -- slot is now a KW_TABLE placeholder
TOK_DATA    = $92            ; DATA val, val, ...  
TOK_READ    = $93            ; READ var
TOK_RESTORE = $94            ; RESTORE 
TOK_ELSE    = $95            ; ELSE  
; ---- expression-atom tokens: $96..$A8 (never in STMT_JT) -------------------
; ---- v15.17: renumbered so table-dispatched function tokens (Group A:
;      ABS/PEEK/USR/SIN/COS, uniform 1-arg; Group B: RND, 0-arg) are
;      contiguous at the top ($A4-$A9). Everything else here stays
;      individually checked (infix ops AND/OR/XOR/MOD, statement-context
;      keywords STEP/TO/LET/THEN, or PRINT-only CHR$/ASC/TAB) -- unaffected
;      by the FUNC_JT dispatch change. TRYKW/DO_LIST derive token<->text
;      purely from KW_TABLE position, so this reorder needs no other fix.
TOK_STEP    = $96            ; STEP 
TOK_TO      = $97            ; TO  
TOK_CHRS    = $98            ; CHR$(n)  (PRINT-only, v15.17)
TOK_ASC     = $99            ; ASC("c") 
TOK_AND     = $9A            ; AND  
TOK_OR      = $9B            ; OR   
TOK_NOT     = $9C            ; NOT expr 
TOK_XOR     = $9D            ; XOR  
TOK_LET     = $9E            ; LET  
TOK_THEN    = $9F            ; THEN 
TOK_TAB     = $A0            ; TAB(n)  (replaces AT; same token slot)
TOK_MOD     = $A1            ; MOD     
; TOK_INKEY ($A2) removed v15.1
; TOK_SGN ($A3) removed v15.0
; ---- Group B (0-arg, no parens) -- FUNC_JT dispatch starts here (FUNC_LO) --
TOK_RND     = $A4            ; RND     
; ---- Group A (uniform 1-arg, paren-wrapped) -- FUNC_JT indices 0..4 --------
TOK_ABS     = $A5            ; ABS(n)  
TOK_PEEK    = $A6            ; PEEK(addr)  
TOK_USR     = $A7            ; USR(addr)  
TOK_SIN     = $A8            ; SIN(deg) -> deg*1000 (0-360)
TOK_COS     = $A9            ; COS(deg) -> deg*1000 (0-360)
TOK_HEXS    = $AA            ; HEX$(n)  4-digit hex, PRINT-only (v15.18)
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
; FVAR,FLIM,FSTEP,CURLN are contiguous
; on purpose: DO_FOR copies this 7-byte block into
; a FOR_STK frame with one indexed loop instead of
; unrolled stores (CURLN already holds the correct
; loop_line value, so no separate copy is needed).
FVAR     = $02               ;  8-bit: FOR staging: var_slot (VARS offset)
FLIM:    .RS 2               ; 16-bit: FOR staging: limit
FSTEP:   .RS 2               ; 16-bit: FOR staging: step
CURLN:   .RS 2               ; 16-bit: current executing line number
; --- 
LP:      .RS 2               ; 16-bit: list/edit/scratch pointer
T0:      .RS 2               ; 16-bit: expression result / scratch 0
T1:      .RS 2               ; 16-bit: scratch 1
T2:      .RS 2               ; 16-bit: scratch 2
PE:      .RS 2               ; 16-bit: program end
GRET:    .RS 1               ;  8-bit: GOSUB nesting depth
RUN:     .RS 1               ;  8-bit: 0 = idle, $FF = running
GORET:   .RS 2               ; 16 bytes: GOSUB return stack 
TKTOK:   .RS 1               ;  8-bit: TRYKW keyword index
FSTK:    .RS 1               ;  8-bit: FOR nesting depth
FOR_STK: .RS 28              ; 28 bytes: FOR frames        
FOR_FRSZ = 7                 ; bytes per FOR frame
RUNSP:   .RS 1               ;  8-bit: saved SP for stack unwind
OP:      .RS 1               ;  8-bit: MUL/DIV operator ('*' or '/')
DATA_PTR: .RS 2              ; 16-bit: pointer to next DATA value to READ 
RND_SEED: .RS 2              ; 16-bit: LFSR seed for RND, init to $ACE1

; CORDIC scratch (zeroed by INIT_z with rest of ZP):
CX:      .RS 2               ; 16-bit: CORDIC X accumulator
CY:      .RS 2               ; 16-bit: CORDIC Y accumulator
CZ:      .RS 2               ; 16-bit: CORDIC Z angle accumulator
CX_SAV:  .RS 2               ; 16-bit: saved CX per iteration
CIDX:    .RS 1               ;  8-bit: CORDIC iteration counter
ATEMP:   .RS 1               ;  8-bit: angle quadrant temp

; Buffers/BASIC VARS
TBUF:    .RS 32               ; 32 bytes: tokenised buffer  
VARS:    .RS 52               ; 52 bytes: A-Z variables     
IBUF:    .RS 32               ; 32 bytes: raw input buffer  

; ZP0 - permanent $0000 pointer for (zp),Y indirect-indexed addressing.
; Zeroed once by INIT's cold-boot DO_NEW clear (X=$FF entry covers all of
; zero page $01-$FF) and never written again, so (ZP0),Y always resolves
; to address Y itself -- lets CMP16/etc. use Y as a direct dest zp address
; the way zp,X already lets X be a direct src zp address (STA doesn't
; support zp,Y, so this is the equivalent trick for the write/compare side).
ZP0:     .RS 2

ZPEND    = *                    ; audit

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
        .DB $0A, $00, $89, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $31, $20, $53, $48, $4F, $57, $43, $41, $53, $45, $0D  ; 10 REM  4K BASIC SHOWCASE
        .DB $14, $00, $80, $22, $3D, $3D, $20, $34, $4B, $20, $42, $41, $53, $49, $43, $20, $76, $31, $35, $2E, $31, $20, $3D, $3D, $22, $0D  ; 20 PRINT "== 4K BASIC v15.8 =="
        .DB $1E, $00, $80, $22, $43, $48, $52, $22, $3B, $98, $28, $FF, $24, $00, $29, $3B, $22, $28, $36, $35, $29, $3D, $22, $3B, $98, $28, $FF, $41, $00, $29, $3B, $22, $20, $20, $41, $53, $43, $3D, $22, $3B, $99, $28, $22, $41, $22, $29, $0D  ; 30 PRINT "CHR";CHR$ (36 );"(65)=";CHR$ (65 );"  ASC=";ASC ("A")
        .DB $28, $00, $80, $22, $31, $37, $20, $4D, $4F, $44, $20, $35, $3D, $22, $3B, $FF, $11, $00, $A1, $FF, $05, $00, $3B, $22, $20, $20, $41, $42, $53, $20, $6E, $65, $67, $37, $3D, $22, $3B, $A5, $28, $2D, $FF, $07, $00, $29, $0D  ; 40 PRINT "17 MOD 5=";17 MOD 5 ;"  ABS neg7=";ABS (-7 )
        .DB $32, $00, $80, $22, $4E, $4F, $54, $20, $30, $3D, $22, $3B, $9C, $FF, $00, $00, $3B, $22, $20, $20, $36, $20, $41, $4E, $44, $20, $33, $3D, $22, $3B, $FF, $06, $00, $9A, $FF, $03, $00, $0D  ; 50 PRINT "NOT 0=";NOT 0 ;"  6 AND 3=";6 AND 3 
        .DB $3C, $00, $80, $22, $35, $20, $4F, $52, $20, $32, $3D, $22, $3B, $FF, $05, $00, $9B, $FF, $02, $00, $3B, $22, $20, $20, $37, $20, $58, $4F, $52, $20, $33, $3D, $22, $3B, $FF, $07, $00, $9D, $FF, $03, $00, $0D  ; 60 PRINT "5 OR 2=";5 OR 2 ;"  7 XOR 3=";7 XOR 3 
        .DB $46, $00, $80, $22, $52, $4E, $44, $20, $4D, $4F, $44, $20, $31, $30, $3D, $22, $3B, $A4, $A1, $FF, $0A, $00, $0D  ; 70 PRINT "RND MOD 10=";RND MOD 10 
        .DB $50, $00, $8E, $FF, $00, $08, $2C, $FF, $2A, $00, $3A, $80, $22, $50, $4F, $4B, $45, $20, $32, $30, $34, $38, $20, $34, $32, $20, $20, $50, $45, $45, $4B, $3D, $22, $3B, $A6, $28, $FF, $00, $08, $29, $0D  ; 80 POKE 2048,42:PRINT "POKE 2048 42  PEEK=";PEEK(2048)
        .DB $5A, $00, $93, $41, $2C, $42, $2C, $43, $3A, $80, $22, $44, $41, $54, $41, $20, $20, $22, $3B, $41, $3B, $22, $20, $20, $22, $3B, $42, $3B, $22, $20, $20, $22, $3B, $43, $0D  ; 90 READ A,B,C:PRINT "DATA  ";A;"  ";B;"  ";C
        .DB $64, $00, $94, $3A, $93, $41, $3A, $80, $22, $52, $45, $53, $54, $4F, $52, $45, $20, $41, $3D, $22, $3B, $41, $0D  ; 100 RESTORE :READ A:PRINT "RESTORE A=";A
        .DB $6E, $00, $92, $20, $31, $31, $31, $2C, $32, $32, $32, $2C, $33, $33, $33, $0D  ; 110 DATA  111,222,333
        .DB $78, $00, $8B, $49, $3D, $FF, $01, $00, $97, $FF, $05, $00, $0D  ; 120 FOR I=1 TO 5 
        .DB $82, $00, $80, $49, $3B, $0D  ; 130 PRINT I;
        .DB $8C, $00, $8C, $49, $0D  ; 140 NEXT I
        .DB $96, $00, $80, $0D  ; 150 PRINT 
        .DB $A0, $00, $8B, $49, $3D, $FF, $0A, $00, $97, $FF, $01, $00, $96, $2D, $FF, $03, $00, $0D  ; 160 FOR I=10 TO 1 STEP -3 
        .DB $AA, $00, $80, $49, $3B, $0D  ; 170 PRINT I;
        .DB $B4, $00, $8C, $49, $0D  ; 180 NEXT I
        .DB $BE, $00, $80, $0D  ; 190 PRINT 
        .DB $C8, $00, $81, $FF, $03, $00, $3E, $FF, $01, $00, $9F, $80, $22, $49, $46, $20, $74, $72, $75, $65, $22, $0D  ; 200 IF 3 >1 THEN PRINT "IF true"
        .DB $D2, $00, $81, $FF, $01, $00, $3E, $FF, $03, $00, $9F, $80, $22, $57, $52, $4F, $4E, $47, $22, $95, $80, $22, $45, $4C, $53, $45, $20, $6F, $6B, $22, $0D  ; 210 IF 1 >3 THEN PRINT "WRONG"ELSE PRINT "ELSE ok"
        .DB $DC, $00, $83, $FF, $F4, $01, $0D  ; 220 GOSUB 500 
        .DB $E6, $00, $89, $20, $73, $69, $6E, $65, $20, $77, $61, $76, $65, $20, $20, $54, $41, $42, $28, $32, $30, $2B, $53, $49, $4E, $28, $58, $29, $2F, $35, $30, $29, $0D  ; 230 REM  sine wave  TAB(20+SIN(X)/50)
        .DB $F0, $00, $8B, $58, $3D, $FF, $00, $00, $97, $FF, $67, $01, $96, $FF, $0F, $00, $0D  ; 240 FOR X=0 TO 359 STEP 15 
        .DB $FA, $00, $80, $A0, $28, $FF, $14, $00, $2B, $A8, $28, $58, $29, $2F, $FF, $32, $00, $29, $3B, $22, $2A, $22, $0D  ; 250 PRINT TAB (20 +SIN (X)/50 );"*"
        .DB $04, $01, $8C, $58, $0D  ; 260 NEXT X
        .DB $0E, $01, $82, $FF, $58, $02, $0D  ; 270 GOTO 600 
        .DB $18, $01, $8A, $0D  ; 280 END 
        .DB $F4, $01, $80, $22, $47, $4F, $53, $55, $42, $20, $6F, $6B, $22, $3A, $84, $0D  ; 500 PRINT "GOSUB ok":RETURN 
        .DB $58, $02, $8B, $49, $3D, $2D, $FF, $40, $00, $97, $FF, $38, $00, $96, $FF, $06, $00, $0D  ; 600 FOR I=-64 TO 56 STEP 6 
        .DB $62, $02, $44, $3D, $49, $0D  ; 610 D=I
        .DB $6C, $02, $8B, $43, $3D, $2D, $FF, $80, $00, $97, $FF, $10, $00, $96, $FF, $04, $00, $0D  ; 620 FOR C=-128 TO 16 STEP 4 
        .DB $76, $02, $41, $3D, $43, $3A, $42, $3D, $44, $3A, $45, $3D, $FF, $00, $00, $0D  ; 630 A=C:B=D:E=0 
        .DB $80, $02, $8B, $4E, $3D, $FF, $01, $00, $97, $FF, $10, $00, $0D  ; 640 FOR N=1 TO 16 
        .DB $8A, $02, $81, $45, $3E, $FF, $00, $00, $9F, $82, $FF, $A8, $02, $0D  ; 650 IF E>0 THEN GOTO 680 
        .DB $94, $02, $54, $3D, $41, $2A, $41, $2F, $FF, $40, $00, $2D, $42, $2A, $42, $2F, $FF, $40, $00, $2B, $43, $0D  ; 660 T=A*A/64 -B*B/64 +C
        .DB $9E, $02, $42, $3D, $FF, $02, $00, $2A, $41, $2A, $42, $2F, $FF, $40, $00, $2B, $44, $3A, $41, $3D, $54, $0D  ; 670 B=2 *A*B/64 +D:A=T
        .DB $A8, $02, $81, $45, $3D, $FF, $00, $00, $9F, $81, $41, $2A, $41, $2F, $FF, $40, $00, $2B, $42, $2A, $42, $2F, $FF, $40, $00, $3E, $FF, $00, $01, $9F, $45, $3D, $4E, $0D  ; 680 IF E=0 THEN IF A*A/64 +B*B/64 >256 THEN E=N
        .DB $B2, $02, $8C, $4E, $0D  ; 690 NEXT N
        .DB $BC, $02, $81, $45, $3E, $FF, $00, $00, $9F, $80, $98, $28, $45, $2B, $FF, $20, $00, $29, $3B, $95, $80, $98, $28, $FF, $20, $00, $29, $3B, $0D  ; 700 IF E>0 THEN PRINT CHR$ (E+32 );ELSE PRINT CHR$ (32 );
        .DB $C6, $02, $8C, $43, $0D  ; 710 NEXT C
        .DB $D0, $02, $80, $22, $22, $0D  ; 720 PRINT ""
        .DB $DA, $02, $8C, $49, $0D  ; 730 NEXT I
        .DB $E4, $02, $8A, $0D  ; 740 END 
SHOWCASE_END = *               ; v15.18: assembles to $0200+807 = $0527 (line 80 POKE/PEEK address moved 512->2048, see trace.log)

; =============================================================================
        .ORG $F000      ; 4kbyte 
; STRING TABLE (all strings on same page)
; =============================================================================
STR_PAGE  = >STR_BANNER      ; hi-byte shared by all string/kw addresses
STR_BANNER: .DB "4K BASIC v15.18"       ; same length as v15.15
STR_CRLF:   .DB $0D,$8A             ; CR, LF|$80 = $8A
STR_BYTES:  .DB " BYTES FREE",$0D,$8A  ; last LF has high-bit
STR_ERROR:  .DB " ER",$D2           ; 'R'|$80 = $D2
STR_IN:     .DB " IN ",$A0          ; last space|$80 = $A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB  ; 'K'|$80 = $CB

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
; ---- expression-atom tokens $96..$A9 (in KW_TABLE for tokeniser only) ------
; v15.17: reordered so Group A (ABS,PEEK,USR,SIN,COS) + Group B (RND) are
; contiguous at $A4-$A9 for FUNC_JT indexed dispatch. Non-grouped tokens
; (individually checked, unaffected) fill $96-$A1; 2 placeholders at $A2-$A3.
        .DB "STE",$D0         ; $96 TOK_STEP    ('P'|$80=$D0)
        .DB "T",$CF           ; $97 TOK_TO      ('O'|$80=$CF)
        .DB "CHR",$A4         ; $98 TOK_CHRS    ('$'|$80=$A4)  PRINT-only
        .DB "AS",$C3          ; $99 TOK_ASC     ('C'|$80=$C3)
        .DB "AN",$C4          ; $9A TOK_AND     ('D'|$80=$C4)
        .DB "O",$D2           ; $9B TOK_OR      ('R'|$80=$D2)
        .DB "NO",$D4          ; $9C TOK_NOT     ('T'|$80=$D4)
        .DB "XO",$D2          ; $9D TOK_XOR     ('R'|$80=$D2)
        .DB "LE",$D4          ; $9E TOK_LET     ('T'|$80=$D4)
        .DB "THE",$CE         ; $9F TOK_THEN    ('N'|$80=$CE)
        .DB "TA",$C2          ; $A0 TOK_TAB     ('B'|$80=$C2)
        .DB "MO",$C4          ; $A1 TOK_MOD     ('D'|$80=$C4)
        .DB $80               ; $A2 placeholder (INKEY removed v15.1)
        .DB $80               ; $A3 placeholder (SGN removed, expr atom not statement -- no STMT_JT impact)
        .DB "RN",$C4          ; $A4 TOK_RND     ('D'|$80=$C4)  Group B: 0-arg, FUNC_LO
        .DB "AB",$D3          ; $A5 TOK_ABS     ('S'|$80=$D3)  Group A: FUNC_JT[0]
        .DB "PEE",$CB         ; $A6 TOK_PEEK    ('K'|$80=$CB)  Group A: FUNC_JT[1]
        .DB "US",$D2          ; $A7 TOK_USR     ('R'|$80=$D2)  Group A: FUNC_JT[2]
        .DB "SI",$CE          ; $A8 TOK_SIN     ('N'|$80=$CE)  Group A: FUNC_JT[3]
        .DB "CO",$D3          ; $A9 TOK_COS     ('S'|$80=$D3)  Group A: FUNC_JT[4]
        .DB "HEX",$A4         ; $AA TOK_HEXS    ('$'|$80=$A4)  PRINT-only, not in FUNC_JT
        .DB 0                 ; end-of-table sentinel

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
        CLI                  ; enable maskable IRQs (for IRQ Break key)

        ; Clear zero page
        JSR DO_NEW

        ; --- Showcase setup - Delete for actual ROM
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
        JSR GETLINE_M          ; fills IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
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
; Two adjacent labels: DO_ERR_NR branches forward into DO_ERROR via BRA;
; DO_ERR_UL falls straight through into DO_ERROR.
; =============================================================================
DO_ERR_NR:
        LDA #ERR_NR
        .DB $2C
DO_ERR_UL:
        LDA #ERR_UL
        ; drop through
; =============================================================================
; DO_ERROR ? print error message and return to MAIN
;   In:  A    error code (ERR_xx constant = index into ERR_TABLE)
;   Out: Character emitted to terminal device. (jumps to MAIN; does not return to caller)
;   Clobbers: A X T0
; =============================================================================
DO_ERROR:
        PHA              ; save error code (survives PRNL which uses A)
        JSR PRNL         ; print CR+LF
        PLX              ; X = error code ? ERR_TABLE index
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
        LDX #(CURLN-T0)
        JSR TO_T0
        JSR PRT16            ; line number
DO_err_noline:
        JSR PRNL
        CLI                  ; re-enable IRQs (harmless from error path; needed from IRQ path)
        BRA MAIN

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
         JSR PRTSP
GETLINE: LDX #0
GLL:     JSR GETCH             ; raw read, no echo (see header note)
         CMP #CR
         BEQ GLD
         CMP #BS
         BNE GLS
         JSR PUTCH             ; echo the backspace byte
         TXA                   ; was CPX #0 -- saves 1 byte; A clobbered but GETCH overwrites it
         BEQ GLL
         DEX
         BRA GLL
GLS:     CPX #IBUF_MAX
         BCS GLFULL
         STA IBUF,X
         JSR PUTCH             ; echo the stored character (A unaffected by the STA above)
         INX
         BRA GLL
GLFULL:  LDA #BELL              ; buffer full: discard the char (X
         JSR PUTCH               ; doesn't move), beep instead of echoing it
         BRA GLL                 ; -- the character itself is never printed
GLD:     STA IBUF,X
         JSR PUTCH              ; echo the raw CR (mirrors the old GETCH echo)
         JSR PRNL
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
        STZ T0+1
        LDA #<TBUF
        STA T1
        STZ T1+1

TK_TOP: LDA (T0)             ; 65C02 zp-indirect
        BEQ TK_EOL           ; Null sentinel ($00) -> EOL
        CMP #$0D
        BEQ TK_EOL           ; CR ($0D) -> EOL
        CMP #' '             ; Skip spaces
        BEQ INC_TOP

        CMP #'"'             ; String literal?
        BNE TK_NSTR
        JSR TKEMIT           ; Emit opening '"'
TK_SC:  JSR INC_T0
        LDA (T0)
        BEQ TK_EOL           ; Unterminated string ($00) -> EOL
        JSR TKEMIT
        CMP #'"'
        BEQ INC_TOP          ; Closing '"' -> advance T0 & resume loop
        CMP #$0D
        BNE TK_SC            ; Keep copying string bytes
        BRA TK_EOL           ; Unterminated string ($0D) -> EOL

TK_NSTR:
        CMP #'0'             ; Decimal digit?
        BCC TK_NNUM
        CMP #'9'+1
        BCS TK_NNUM
        JSR TKPNUM           ; Parse number into CURLN (advances T0)
        LDA #TOK_NUM
        JSR TKEMIT
        LDA CURLN
        JSR TKEMIT
        LDA CURLN+1
        JSR TKEMIT
        BRA TK_TOP

TK_NNUM:
        JSR UC
        CMP #'A'             ; Keyword or variable letter?
        BCC TK_OTHER
        CMP #'Z'+1
        BCS TK_OTHER
        JSR TRYKW            ; Try keyword match (C=0 matched, C=1 not)
        BCC TK_TOP           ; Keyword matched & emitted: continue

TK_OTHER:
        LDA (T0)             ; Re-read char for variable/punctuation
        JSR UC
        JSR TKEMIT
INC_TOP:
        JSR INC_T0           ; Shared helper: advance T0 and loop
        BRA TK_TOP

TK_EOL: LDA #$0D             ; Write $0D $00 end-of-line sentinel
        JSR TKEMIT
        LDA #0
        BRA TKEMIT           ; Tail call: emits $00 and RTS

; =============================================================================
; INC_T0 ? advance source pointer T0 by one byte
;   Out: T0   incremented
;   Clobbers: Flags only (A unchanged).
; =============================================================================
INC_T0: INC T0
        BNE INC_T0_ok
        INC T0+1
INC_T0_ok:
        RTS

; =============================================================================
; INC_DATA_PTR ? advance DATA_PTR by 1 ---------------------------------------
;   Clobbers: Flags only (A unchanged).
; =============================================================================
DATAPTRADD2:
        JSR INC_DATA_PTR
INC_DATA_PTR:
        INC DATA_PTR
        BNE RD_ap_ok
        INC DATA_PTR+1
RD_ap_ok:
        RTS

; =============================================================================
; GETCI ? read byte at IP and advance IP by one
;   In:  IP   token stream pointer
;   Out: A    byte that was at (IP);  IP  incremented
;   Clobbers: None.
; =============================================================================
IPADD2: JSR INC_IP
        .DB $2C                 ; Swallow LDA (IP)
GETCI:  LDA (IP)             ; 65C02 zp-indirect: fetch byte at IP, then advance
    ; drop through
; =============================================================================
; INC_IP ? increment IP (16-bit pointer) by 1
;   In:  IP points at current token byte.
;   Out: IP advanced by one byte.
;   Clobbers: Flags.
; =============================================================================
INC_IP: INC IP
        BNE INC_IP_ok
        INC IP+1
INC_IP_ok:
        RTS

; =============================================================================
; INC_LP ? advance list pointer LP by one byte
;   In:  LP   pointer into program store
;   Out: LP   incremented
;   Clobbers: None.
; =============================================================================
LPADD2: JSR INC_LP
INC_LP: INC LP
        BNE INC_LP_ok
        INC LP+1
INC_LP_ok:
        RTS

; =============================================================================
; TKEMIT ? write A to token output at T1, advance T1
;   In:  A    byte to write;  T1  destination pointer
;   Out: T1   incremented
;   Clobbers: Y
; =============================================================================
TKEMIT: STA (T1)             ; 65C02 zp-indirect: no Y needed  ($92 opcode)
INC_T1:
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
        LDA (T0)             ; Get ASCII character
        EOR #'0'             ; MAGIC: Maps '0'-'9' to $00-$09. Everything else goes to >= $0A!
        CMP #10              
        BCS TKPN_dn          ; If >= 10, it wasn't a digit. We are done!
        
        PHA                  ; Save the exact binary digit (0-9)
        JSR INC_T0           ; Advance pointer
        
        ; CURLN = CURLN * 10 (via x*2 + x*8)
        ASL CURLN
        ROL CURLN+1          ; CURLN = x*2
        LDA CURLN
        TAX
        LDA CURLN+1
        TAY                  ; X,Y = x*2
        
        ASL CURLN
        ROL CURLN+1
        ASL CURLN
        ROL CURLN+1          ; CURLN = x*8
        
        TXA
        CLC
        ADC CURLN
        STA CURLN
        TYA
        ADC CURLN+1
        STA CURLN+1          ; CURLN = x*2 + x*8 = x*10
        
        PLA                  ; A = digit
        ; CLC                ; 
        ADC CURLN
        STA CURLN
        BCC TKPN_lp
        INC CURLN+1
        BRA TKPN_lp

TKPN_dn: 
        RTS

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
        JSR T0_TO_CURLN      ; save source pos for possible backtrack
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
        JSR INC_T0            ; advance T0 (source ptr); clobbers flags but not X or Y
        INY                  ; next table char index
        BNE TRY_cmp          ; always (no keyword >= 256 chars)
TRY_matched_adv:
        JSR INC_T0            ; advance source past the final matched char
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
        JSR INC_T0
        BRA TRY_raw
TRY_chk_rem:
        CMP #TOK_REM         ; REM: emit token FIRST, then absorb rest of line verbatim
        BNE TRY_emt
        PLA
        JSR TKEMIT           ; emit TOK_REM before the raw comment text
        BRA TRY_raw          ; shared raw-copy-until-$0D loop (same as DATA body)
TRY_emt:
        PLA
        JSR TKEMIT
TRY_raw_done:
        CLC
        RTS
TRY_miss:                    ; this keyword doesn't match: restore T0, try next
        LDX #(CURLN-T0)
        JSR TO_T0
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
        LDY #$FF             ; Start at -1
KW_nx_lp:
        INY                  ; On first pass, Y rolls over to 0
        LDA (T2),Y           ; Sets the N flag
        BPL KW_nx_lp         ; N is untouched Branch back if high-bit is 0
        TYA                  ; A = index of the last character
        SEC                  ; Set carry = 1 (acts as a +1 for the addition)
        ADC T2               ; A = T2 + Y + 1 
        STA T2
        BCC KW_next_ok       ; If we didn't overflow 255, skip the high-byte inc
        INC T2+1
KW_next_ok:
EL_done:
        RTS

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
        JSR T0_TO_CURLN
        STZ LP
        LDA #>PROG
        STA LP+1
EL_fl:  LDX #LP               ; scan for insertion/replacement point
        LDY #PE
        JSR CMP16
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
        JSR TOKSKIP_LP
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
        ; drop through
; =============================================================================
; INSLINE ? insert (or replace) a tokenised line in the program store
;   In:  IP   source: <body> $0D  (no $FF prefix ? PNUM already consumed it)
;        LP   insertion point (bytes LP..PE shifted up to make room)
;        PE   current program end
;        CURLN line number for the 2-byte header
;   Out: new line written at LP with 2-byte header prepended
;        PE   advanced by inserted byte count
;   Clobbers: A Y T0 T1
;   Ported from uBASIC6502b (v15.5): the NMOS original counted the shift
;   distance into a scratch register and called a shared decrement-and-test
;   helper (T2DEC) once per byte copied. Replaced with a direct pointer
;   comparison (does the moving pointer equal LP yet?) each iteration,
;   which needs no scratch counter at all and removes T2DEC's last
;   remaining caller after DELINE's own copy of the same pattern was
;   inlined (see DELINE) -- T2DEC itself is deleted. OOM check compares
;   only the new PE's high byte against RAM_TOP's high byte, which is
;   exactly correct (not approximate) because RAM_TOP=$1000 is page-aligned.
; =============================================================================
INSLINE:
        LDY #0
        JSR TOKSKIP_IP
        INY                  ; +2 for the 2-byte line-number header
        INY
        TYA                  ; A = total line size
        CLC
        ADC PE                ; new PE = PE + total size
        STA T1
        LDA PE+1
        ADC #0
        STA T1+1
        CMP #>RAM_TOP        ; would this cross RAM_TOP? (hi-byte only:
        BCC IN_ok            ;  exact since RAM_TOP is page-aligned)
        LDA #ERR_OM
        JMP DO_ERROR
IN_ok:  LDA PE                ; T0 = old PE
        STA T0
        LDA PE+1
        STA T0+1
        LDA T1                ; commit new PE now (OOM check already passed)
        STA PE
        LDA T1+1
        STA PE+1
        LDY #0
        JSR CMP_T0_LP        ; if old PE == LP, nothing to shift upward
        BEQ IN_hdr
IN_bk:  LDA T0                ; pre-decrement source (T0)
        BNE IN_d0
        DEC T0+1
IN_d0:  DEC T0
        LDA T1                ; pre-decrement destination (T1)
        BNE IN_d1
        DEC T1+1
IN_d1:  DEC T1
        LDA (T0),y            ; backward copy loop
        STA (T1),y
        JSR CMP_T0_LP        ; stop exactly when T0 == LP
        BNE IN_bk
IN_hdr: LDA CURLN             ; write 2-byte line-number header at LP
        STA (LP),y            ; Y is 0 here
        INY
        LDA CURLN+1
        STA (LP),y
        ; advance LP by 2 for the payload destination
        JSR LPADD2
IN_l2:  LDY #0
IN_cp:  LDA (IP),y            ; copy payload from IP
        STA (LP),y
        CMP #TOK_NUM           ; inline number: copy its 2-byte lo/hi payload
        BNE IN_cp_chk          ;  unconditionally -- must not test them for $0D
        INY
        LDA (IP),y
        STA (LP),y
        INY
        LDA (IP),y
        STA (LP),y
        INY
        BRA IN_cp
IN_cp_chk:
        CMP #$0D
        BEQ IN_done
        INY
        BRA IN_cp             ; always taken for bounded line lengths (<256)

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
        JSR TOKSKIP_LP
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
        LDA LP               ; save LP: the shift loop's own page-boundary
        PHA                  ;  INC LP+1 must not leak to the caller -- INSLINE
        LDA LP+1             ;  (called right after DELINE, on the replace-line
        PHA                  ;  path) needs LP to still be the insertion point.
        LDY #0
DL_cp:  LDA (T0),y           ; shift bytes down
        STA (LP),y
        INY
        BNE DL_nhi
        INC T0+1
        INC LP+1
DL_nhi: LDA T2               ; decrement T2 (inlined; T2DEC removed, single caller)
        BNE DL_declo
        DEC T2+1
DL_declo:
        DEC T2
        LDA T2
        ORA T2+1
        BNE DL_cp
        PLA                  ; restore LP
        STA LP+1
        PLA
        STA LP
DL_upd: LDA PE               ; update PE
        SEC
        SBC T1
        STA PE
        BCS DL_ok
        DEC PE+1
IN_done:
DL_ok:  RTS

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
DP_top: JSR WPEEK            ; Peek next token -> A
        TAX                  ; CMP #0 replacement (sets Z flag if A=0)
        BEQ DP_nl            ; bare PRINT (sentinel): just print newline
        CMP #CR
        BEQ DP_nl            ; bare PRINT (EOL): just print newline
        CMP #'"'             ; string literal?
        BNE DP_expr    
        JSR GETCI            ; consume opening '"'

DP_str: JSR GETCI
        CMP #'"'
        BEQ DP_aft
        CMP #CR
        BEQ DP_nl
        JSR PUTCH
        BRA DP_str

DP_expr:
        CMP #TOK_TAB         ; TAB(n)?
        BNE DP_chk_chrs
        
        JSR E2_chrs          ; Consumes TAB token and get (n) into T0
        LDX T0               ; Loop count
        BEQ DP_aft           
DP_tab_lp:
        JSR PRTSP            
        DEX
        BNE DP_tab_lp
        BRA DP_aft

DP_chk_chrs:
        CMP #TOK_CHRS        ; CHR$(n)?
        BNE DP_chk_hexs
        
        JSR E2_chrs          ; Consumes CHR$ token get (n) -> T0 
        LDA T0
        JSR PUTCH
        BRA DP_aft

DP_chk_hexs:
        CMP #TOK_HEXS        ; HEX$(n)?
        BNE DP_norm

        JSR E2_chrs          ; Consumes HEX$ token, get (n) -> T0
        JSR PRT_HEX          ; print T0 as 4-digit hex, MSB first
        BRA DP_aft

DP_norm:
        JSR EXPR             
        JSR PRT16
        ; Falls through to DP_aft

DP_aft: JSR WPEEK
        CMP #';'
        BEQ DP_semi
DP_nl:  JMP PRNL             ; Tail call: Print newline and return (No trampoline needed!)

DP_semi:
        JSR GETCI            ; consume ';'
        JSR WPEEK
        CMP #CR             
        BEQ DP_semi_dn       ; trailing semicolon at EOL
        CMP #':'             
        BEQ DP_semi_dn       ; semicolon before ':'
        CMP #TOK_ELSE        
        BEQ DP_semi_dn       ; semicolon before ELSE      
        TAX                  ; Is A == 0 (sentinel)? Sets Z flag.
        BNE DP_top           ; If NOT zero, keep printing! If zero, falls through to RTS.
DP_semi_dn:
DO_IF_done:
        RTS
        
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
        BNE DO_IF_exec       ; MAGIC: If condition is true, skip the ELSE hunt entirely!

        ; -- condition false: scan for ELSE -----------------------------------
DO_IF_f:
        JSR WPEEK
        CMP #CR              ; EOL with no ELSE: done
        BEQ DO_IF_done
        TAX                  ; Brilliant 1-byte CMP #0 replacement (retained from your code!)
        BEQ DO_IF_done
        
        CMP #TOK_ELSE
        BEQ DO_IF_else       ; Found the ELSE! Jump to consume it
        
        JSR GETCI            ; Consume ignored token
        CMP #TOK_NUM         ; Inline number?
        BNE DO_IF_f          
        JSR IPADD2           ; Consume the 2-byte payload for TOK_NUM
        BRA DO_IF_f

        ; -- condition true / ELSE block found --------------------------------
DO_IF_else:
        JSR GETCI            ; Consume TOK_ELSE and fall through to exec!

DO_IF_exec:                  ; SHARED execution block for both True and ELSE
        JSR WPEEK
        CMP #TOK_THEN        ; Optional THEN keyword (forgiving for both IF and ELSE)
        BNE DO_IF_stmt
        JSR GETCI            ; Consume TOK_THEN
DO_IF_stmt:
        JMP STMT             ; Tail call -> RUNLP's SKIPEOL handles any remainder

; =============================================================================
; DO_GOTO ? GOTO lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOTO:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        BRA DO_go_common     ; GOTO has no frame to push -- skip straight to the tail

; =============================================================================
; DO_GOSUB ? GOSUB lineno
;   Clobbers: A X T0
; =============================================================================
DO_GOSUB:
        JSR EXPR             ; evaluate target (literal or expression) -> T0
        LDA GRET
        CMP #8               ; max 8 levels of nesting
        BCC DO_gosub_ok
GOSRET_ERR:
        JMP DO_ERR_NR        ; ? shared error stub
DO_gosub_ok:
        ASL
        TAX
        LDA IP               ; push return address (IP after the GOSUB)
        STA GORET,x
        LDA IP+1
        STA GORET+1,x
        INC GRET
        ; fall through into the shared GOTO/GOSUB tail
DO_go_common:                ; shared by DO_GOTO and DO_GOSUB
        JSR GOTOL
        BCS DO_gosub_ul
        JSR T0_TO_CURLN      ; update CURLN to target line (GOTOL leaves T0=line#)
RUN_LINE:
        LDX RUNSP
        TXS
        BRA RUNGO
DO_gosub_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; =============================================================================
; DO_RETURN ? RETURN
;   Clobbers: A X
; =============================================================================
DO_RETURN:
        LDA GRET
        BEQ GOSRET_ERR
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
        LDA IP               ; save IP across GETLINE
        STA T2
        LDA IP+1
        STA T2+1
        JSR GETLINE_I          ; reads into IBUF, tokenises into TBUF
        LDA #<TBUF
        STA IP
        STZ IP+1
        JSR EXPR             ; evaluate expression from TBUF
        LDA T2               ; restore IP
        STA IP
        LDA T2+1
        STA IP+1
        PLX
        JSR STORE_VAR
DO_input_dn:    ; drop through

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
        STZ IP
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
        LDX #IP               ; check IP == PE  (end of program)
        LDY #PE
        JSR CMP16
        BEQ RUNEND
RUNLP_go:                    ; read 2-byte line number header, advance IP by 2
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INC_IP
RUNLP_hi:
        LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INC_IP
RUNGO:  JSR STMT
        LDA RUN
        BEQ RUNEND
        JSR SKIPEOL
        BRA RUNLP

; =============================================================================
; DO_NEW ? clear ZP and reste Program store
;   Clobbers: A X
; =============================================================================
DO_NEW:
        ; clear zero page
        LDX #0
INIT_z: STZ 0,x              ; 65C02 STZ zp,x  (no LDA #0 needed)
        DEX
        BNE INIT_z           
        ; DATA_PTR ($BC-$BD) is zeroed by INIT_z above ? sentinel 0 = rescan from PROG  
        ; reset program store
        STZ PE  ; since page aligned
        LDA #>PROG
        STA PE+1

        ; Seed RND
        LDA #$E1             ; seed RND LFSR to $ACE1 (must be non-zero)
        STA RND_SEED
        LDA #$AC
        STA RND_SEED+1
        ; drop through - alreayd cleared but harmless and saves a RET

; Two labels on one instruction: DO_END is the handler entry, RUNEND is the
; shared landing target used by DO_RUN and NEXT_END.
DO_END:
RUNEND: STZ RUN
LS_done:
        RTS

; =============================================================================
; DO_LIST ? LIST [n,m] : list program lines, optional line-number range,
; de-tokenising on the fly
;   Syntax:  LIST         -- all lines
;            LIST n,m     -- lines n..m inclusive (n,m may be expressions)
;   In:  IP -> first char after "LIST"; PE = program end
;   Out: matching lines printed; IP advanced
;   Clobbers: A X Y T0 T1 T2 LP
;   T1 = lo-bound, T2 = hi-bound; defaulted to the full range (0..$7FFF) for
;   a bare LIST, or set via GET_TWO_ARGS.
;   Lines below the lo-bound are walked (to correctly locate the next line)
;   via a separate, minimal token-aware skip loop (LS_skip_body) that never
;   calls PUTCH/PRT16/PRNL, so the shared print primitives need no
;   suppression flag. Lines are stored in ascending order, so a current
;   line number above the hi-bound stops the whole scan immediately.
; =============================================================================
DO_LIST:
        STZ T1                ; default lo-bound = 0
        STZ T1+1
        LDA #$FF
        STA CY                ; default hi-bound = $7FFF
        LDA #$7F
        STA CY+1
        JSR WPEEK
        CMP #$0E
        BCC LS_scan           ; bare LIST? defaults stand
        
        JSR GET_TWO_ARGS      ; args present: T1 = n (lo), T0 = m
        LDA T0
        STA CY                ; move m into hi-bound (CY)
        LDA T0+1
        STA CY+1
LS_scan:
        STZ LP
        LDA #>PROG
        STA LP+1

LS_ln:  LDX #LP               ; end of program?
        LDY #PE
        JSR CMP16
        BEQ LS_done           ; MAGIC: Inverted branch! (saves 3 bytes)

        LDA (LP)              ; read lo byte of line number
        STA T0
        LDY #1
        LDA (LP),y            ; read hi byte
        STA T0+1

        ; -- Bound Checks --
        LDA CY                ; current > hi-bound? (CY - T0 borrows)
        CMP T0
        LDA CY+1
        SBC T0+1
        BCC LS_done           ; yes: passed hi-bound, STOP execution entirely
        
        LDA T0                ; current < lo-bound? (T0 - T1 borrows)
        CMP T1
        LDA T0+1
        SBC T1+1
        BCC LS_skip_hdr       ; yes: below lo-bound, silently skip this line!
        
        ; -- Print Valid Line --
        JSR PRT16             ; print line number
        JSR PRTSP
        JSR LPADD2            ; advance LP past 2-byte header

LS_body:
        LDA (LP)
        CMP #CR
        BEQ LS_eol
        CMP #TOK_NUM
        BEQ LS_num
        CMP #TOK_PRINT
        BCC LS_lit            ; < TOK_PRINT: literal char

        ; -- Keyword Lookup --
        SEC
        SBC #TOK_PRINT
        TAX                   ; X = keyword index (0-based)
        LDA #<KW_TABLE
        STA T2
        LDA #>KW_TABLE
        STA T2+1
        TXA                   
        BEQ LS_prk            ; If X was 0, jump right to printing
LS_skp_lp:
        JSR KW_NEXT           
        DEX                   
        BNE LS_skp_lp         ; MAGIC: DEX sets Z, no CPX needed! (saves 4 bytes)

LS_prk: LDY #0
LS_pkl: LDA (T2),Y
        PHA                   ; Save original char with bit 7 intact
        AND #$7F              ; Strip high-bit for printing
        JSR PUTCH
        PLA                   ; Restore original char
        BMI LS_pkd            ; MAGIC: If bit 7 was set, we are done! (saves 3 bytes)
        INY
        BRA LS_pkl

LS_pkd: JSR INC_LP
        JSR PRTSP
        BRA LS_body

LS_lit: JSR PUTCH
        JSR INC_LP
        BRA LS_body

LS_num: JSR INC_LP
        LDA (LP)
        STA T0
        JSR INC_LP
        LDA (LP)
        STA T0+1
        JSR INC_LP
        JSR PRT16
        JSR PRTSP
        BRA LS_body

; -- below-lo-bound path: advance LP past header, then skip body silently --
LS_skip_hdr:
        JSR LPADD2
LS_skip_body:
        LDA (LP)
        CMP #CR
        BEQ LS_skip_eol
        CMP #TOK_NUM
        BNE LS_skip_adv
        JSR LPADD2            ; skip the $FF marker, skip lo byte
LS_skip_adv:
        JSR INC_LP            ; skip this byte (or the literal's hi byte)
        BRA LS_skip_body

LS_eol: JSR PRNL              ; MAGIC: Fall-through EOL handler (saves 1 byte)
LS_skip_eol:
        JSR INC_LP
        JMP LS_ln             ; Loop back to next line

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
        ;BRA PUTSTR           ; print " BYTES FREE\r\n" and return  (tail call)
        .DB $2C               ; eat next 2 bytes
        ; drop through
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
PRNL:    LDA #<STR_CRLF
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
        STZ LP+1
PS_DN:   RTS

; =============================================================================
; DO_FOR ? FOR var = start TO limit [STEP step]
;   In:  IP -> variable letter
;   Out: loop frame pushed onto FOR_STK; VARS[var] = start
;   Clobbers: A X Y T0 T2 LP
;   Stages var_slot/limit/step into FVAR/FLIM/FSTEP, which sit immediately
;   before CURLN in zero page (see equates) forming one contiguous 7-byte
;   run [FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1,CURLN,CURLN+1] matching the FOR_STK
;   frame layout exactly. CURLN already holds the correct loop_line value
;   (set once per line before STMT runs), so no separate copy is needed for
;   it. The final push is one indexed loop instead of 7 unrolled stores.
;   Variable letter is consumed before validation (not peeked): safe because
;   DO_ERROR never returns to its caller (ends in JMP MAIN), so IP's exact
;   position after an aborted statement is never examined.
; =============================================================================
DO_FOR:
        JSR GETVARC          ; consume variable letter directly, A = char-'A'
        CMP #26               ; 0-25 = valid letter
        BCC DO_for_ok
        LDA #ERR_SN
        JMP DO_ERROR
DO_for_ok:
        ASL                  ; byte offset into VARS
        STA FVAR             ; stage var_slot directly (no stack juggling)
        JSR EAT_EXPR         ; evaluate start value -> T0
        LDX FVAR
        JSR STORE_VAR         ; store start value in variable
        JSR EAT_EXPR         ; consume '=' then evaluate '=', then TO, then limit
        LDA T0
        STA FLIM             ; stage limit directly
        LDA T0+1
        STA FLIM+1
        JSR WPEEK
        CMP #TOK_STEP
        BNE DO_for_nostep
        JSR GETCI            ; consume STEP token
        JSR EXPR             ; evaluate step -> T0
        LDA T0
        LDX T0+1
        BRA DO_for_havestep
DO_for_nostep:
        LDA #1               ; default step = 1
        LDX #0
DO_for_havestep:
        STA FSTEP            ; stage step (shared store for both paths)
        STX FSTEP+1
        ORA FSTEP+1          ; step of zero is illegal
        BNE DO_for_szok
        LDA #ERR_ST
        JMP DO_ERROR
DO_for_szok:
        LDA FSTK
        CMP #4               ; max 4 nested FOR loops
        BCC DO_for_push
        JMP DO_ERR_NR        ; ? shared error stub
DO_for_push:
        JSR FSTK_BASE        ; LP = FOR_STK + FSTK*7 (A already holds FSTK)
        LDY #6
DO_for_cp:
        LDA FVAR,y           ; copy FVAR,FLIM,FLIM+1,FSTEP,FSTEP+1,CURLN,CURLN+1
        STA (LP),y           ; into the frame in one pass (offsets match exactly)
        DEY
        BPL DO_for_cp
        INC FSTK
        RTS

; =============================================================================
; DO_NEXT ? NEXT [var]
;   In:  IP -> optional variable name (consumed but not checked against the
;        FOR variable; NEXT always closes the innermost active loop)
;   Out: loop variable advanced; branches back into the loop body or falls
;        through to the statement after NEXT once the limit is crossed
;   Clobbers: A X Y T0 T2 LP
;   Comparison is a single unified signed test: diff = var - limit. If
;   diff==0 the limit is met exactly (inclusive: always loop once more).
;   Otherwise XOR diff's sign with the step's sign -- differing signs means
;   the limit has not yet been reached (keep looping); matching signs means
;   it has been crossed (stop). Replaces separate mirrored branches for
;   positive- and negative-step loops with one shared path.
; =============================================================================
DO_NEXT:
        JSR WPEEK_UC         ; consume optional variable name (ignored)
        SEC
        SBC #'A'
        CMP #26               ; 0-25 = valid letter
        BCS DO_next_novar
        JSR GETCI
DO_next_novar:
        LDA FSTK
        BNE DO_next_ok
        JMP DO_ERR_NR        ; ? shared error stub
DO_next_ok:
        DEC                 ; 65C02: top frame index = FSTK - 1 (A already
                              ;  holds FSTK from the check above)
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
        ; unified signed compare: diff = var - limit
        LDY #1
        LDA VARS,x
        SEC
        SBC (LP),y           ; [1] limit_lo
        STA T0
        INY
        LDA VARS+1,x
        SBC (LP),y           ; [2] limit_hi
        TAX                  ; X = diff hi byte
        ORA T0               ; Z reflects 16-bit "diff == 0"
        BEQ DN_loop          ; var == limit: always loop once more
        TXA                  ; restore diff hi byte (restores N flag)
        LDY #4
        EOR (LP),y           ; XOR with [4] step_hi
        BMI DN_loop          ; differing signs: limit not yet crossed
        DEC FSTK             ; matching signs: limit crossed, done
        RTS
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
        JSR INC_IP            ; consume the $0D
        LDX #IP
        LDY #PE
        JSR CMP16
        BEQ DN_end           ; IP == PE: program ended inside loop
DN_runbody:                  ; read 2-byte line-number header, advance IP
        LDA (IP)             ; 65C02 zp-indirect: lo byte
        STA CURLN
        JSR INC_IP
DN_rh:  LDA (IP)             ; hi byte
        STA CURLN+1
        JSR INC_IP
DN_rb2: JMP RUN_LINE         ; restore S and jump to target
DN_samel:                    ; colon-chained: resume right after ':' on same line
        JSR INC_IP            ; consume the ':'
        JSR T0_TO_CURLN      ; T0 still holds loop_line (GOTOL doesn't clobber it)
        JMP RUNGO             ; re-enter statement dispatch mid-line (no header)
DN_ul:
        JMP DO_ERR_UL        ; ? shared error stub

; DN_end must stay separate from RUNEND: RUNEND only clears RUN, it does
; NOT decrement FSTK. A program ending on the last line of a bare FOR/NEXT
; needs FSTK decremented here; branching to RUNEND directly would leave
; the FOR-nesting counter permanently wrong for the rest of execution.
DN_end: DEC FSTK
        STZ RUN
        RTS

; =============================================================================
; GET_TWO_ARGS ? parse two comma-separated expressions; shared by DO_POKE
; and DO_LIST
;   Syntax: <expr> , <expr>
;   In:  IP -> first expression
;   Out: T1 = first argument (16-bit); T0 = second argument (16-bit)
;   Clobbers: A T0 T1
;   The first result is carried across the second EXPR call via the
;   hardware stack rather than left in T1 directly, because EXPR's own
;   binary-operator evaluation (relational/add-sub/mul-div tiers) uses T1
;   as scratch for its left operand.
; =============================================================================
GET_TWO_ARGS:
        JSR EXPR              ; first arg -> T0
        LDA T0+1
        PHA                   ; save hi byte
        LDA T0
        PHA                   ; save lo byte
        JSR EAT_EXPR          ; consume ',' then evaluate second arg -> T0
        PLA
        STA T1                ; pull first arg lo
        PLA
        STA T1+1              ; pull first arg hi
        RTS

; =============================================================================
; DO_POKE ? POKE addr, value
;   Clobbers: A Y T0 T1
; =============================================================================
DO_POKE:
        JSR GET_TWO_ARGS      ; T1 = addr, T0 = value
        LDA T0
        STA (T1)            ; POKE the value
        RTS

; =============================================================================
; DO_RESTORE ? RESTORE: reset DATA pointer (0 = rescan from PROG on next READ)
;   READ/RESTORE consume the raw bytes via DATA_PTR.  (Same pattern as DO_REM.)
;   Clobbers: None.
; =============================================================================
;   Clobbers: A
; =============================================================================
DO_RESTORE:
        STZ DATA_PTR         ; 65C02 STZ zp
        STZ DATA_PTR+1
RD_done:
DO_DATA:
        RTS

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
        JSR GETVARC          ; consume variable letter, A = char-'A'
        ASL                  ; byte offset into VARS
        PHA                  ; save var slot
        JSR RD_next_val      ; T0 = next data value; C=1 if out-of-data
        BCS RD_od
        PLX
        JSR STORE_VAR
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
        LDA #>PROG
        STA DATA_PTR+1        ; DATA_PTR lo already 0 (ORA above proved it)
        BRA RD_find          ; DATA_PTR now at first line header; find DATA

        ; -- $0D exhaustion (shared by RD_body and RD_skip_ln below): advance
        ;    past it, then find the next DATA line ---------------------------
RD_exh: JSR INC_DATA_PTR       ; skip $0D
        ; fall through to RD_find (DATA_PTR now at next line header)
        ; -- scan from line header for next DATA line --------------------------
RD_find:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
        BEQ RD_ood           ; hit PE: no more DATA
        JSR DATAPTRADD2       ; skip lineno_lo and hi
        LDA (DATA_PTR)       ; first body token  (65C02 zp-indirect, no Y needed)
        CMP #TOK_DATA
        BEQ RD_found_data
        ; not DATA: scan forward to $0D then try next line
RD_skip_ln:
        LDA (DATA_PTR)       ; 65C02 zp-indirect
        CMP #CR
        BEQ RD_exh           ; share exhaustion advancement
        CMP #TOK_NUM          ; inline number: unconditionally skip its 3-byte
        BNE RD_ADV            ;  marker+lo+hi -- must not test lo/hi for $0D
        JSR DATAPTRADD2       ; skip lo/hi payload
RD_ADV:
        JSR INC_DATA_PTR
        BRA RD_skip_ln

        ; -- if DATA_PTR==PE: out of data -------------------------------------
RD_chk_pe:
        LDX #DATA_PTR
        LDY #PE
        JSR CMP16
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
        BRA RD_exh            ; $0D: exhausted -> shared advance+find

GT_err:
RD_ood: SEC
        RTS

RD_sep_adv:
RD_found_data:
        JSR INC_DATA_PTR       ; skip TOK_DATA byte ? now inside body
        BRA RD_body          ; enter body (may be space/comma at start)

        ; -- parse number at DATA_PTR -----------------------------------------
RD_parse:
        CMP #'-'             ; Was it a minus sign? (Sets Z flag if true)
        PHP                  ; Push the processor flags to the stack
        BNE RD_pos           ; If not a minus, skip advancing the pointer      
        JSR INC_DATA_PTR     ; Consume '-'
RD_pos: JSR RD_uint          ; Both paths share the integer parse        
        PLP                  ; Pull the flags back from the stack
        BNE RD_done          ; If Z flag is 0 (wasn't a minus), skip negation        
        JSR NEG16            ; Negate T0 in place
RD_done:
        CLC                  ; Clear carry (required by both paths)
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
        AND #$0F              ; ASCII digit -> value (valid for '0'-'9')
        TAY                   ; save digit in Y
        ; T0 = T0*10:  T1 = T0*2 (reuse the doubled T0), T0 = T1*4, T0 += T1
        ASL T0
        ROL T0+1              ; T0 = orig*2
        LDA T0
        STA T1
        LDA T0+1
        STA T1+1              ; T1 = orig*2
        ASL T0
        ROL T0+1              ; T0 = orig*4
        ASL T0
        ROL T0+1              ; T0 = orig*8
        CLC
        LDA T0
        ADC T1
        STA T0
        LDA T0+1
        ADC T1+1
        STA T0+1              ; T0 = orig*8 + orig*2 = orig*10
        TYA                   ; restore digit
        CLC
        ADC T0
        STA T0
        BCC RD_u_nc
        INC T0+1
RD_u_nc:
        JSR INC_DATA_PTR
        BRA RD_u_lp
RD_u_done:
        RTS

; =============================================================================
; GOTOL ? search program store for a line number; point IP at its body
;   In:  T0   target line number (16-bit)
;   Out: C=0  found: IP points at first token after the 2-byte header
;        C=1  not found (caller should raise ERR_UL)
;   Clobbers: A Y IP
; =============================================================================
GOTOL:
        STZ IP
        LDA #>PROG
        STA IP+1
GT_sc:  LDX #IP
        LDY #PE
        JSR CMP16
        BEQ GT_err           ; reached end without finding it
GT_go:  LDA (IP)             ; line-number lo  (65C02 zp-indirect, no Y needed)
        CMP T0
        BNE GT_nx
        LDY #1
        LDA (IP),y           ; line-number hi
        CMP T0+1
        BEQ GT_ok
GT_nx:  LDY #2               ; skip to body, scan for $0D
        JSR TOKSKIP_IP
        TYA
        CLC
        ADC IP
        STA IP
        BCC GT_sc
        INC IP+1
        BRA GT_sc
GT_ok:   ; advance IP past 2-byte header
        JSR IPADD2
GT_r:   CLC
        RTS                  ; C=0: found

; =============================================================================
; EAT_EXPR ? skip whitespace, consume one byte, then evaluate an expression
;   Convenience wrapper: WEAT then EXPR.
;   In:  IP   points at optional whitespace then expression
;   Out: T0   expression result;  IP  advanced past expression
;   Clobbers: A X Y T1 T2
; =============================================================================
EAT_EXPR:
        JSR WEAT
        ; drop through
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
REL_MASK: .DB 1, 2, 4        ; bit for <,=,> respectively (indexed by RL_LOOP)
EB_rel:
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
        TXA                  ; running mask so far
        .DB $19               ; ORA REL_MASK,y  (opcode $19; assembler lacks the mnemonic form)
        .DW REL_MASK
        TAX
        JSR GETCI            ; consume operator (A = '<'/'='/'>' afterward, never 0)
        BNE RL_LOOP          ; always taken

RL_DONE:
        ; Push mask; evaluate right operand; restore left into T1
        PHX                  ; mask -> stack: mask | left-hi | left-lo | ...
        JSR EXPR_ADD         ; right operand -> T0
        PLA                  ; pop mask -> A
        STA T2               ; stash mask in T2-lo (T2 is free at this point)
        PLA                  ; left hi
        STA T1+1
        PLA                  ; left lo
        STA T1               ; T1=left, T0=right, T2=mask

        ; --- Classify T1 vs T0: produce result bit LT(1)/EQ(2)/GT(4) in A ---

        ; Equality check first (cheaper: two CMPs, no subtract)
        LDX #T1
        LDY #T0
        JSR CMP16
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
	STZ T0               ; Default False 
	STZ T0+1	     ; 
        AND T2               ; Result bit AND operator mask
        BEQ REL_F            ; No overlap -> false
REL_T:  DEC T0	             ; Set True (-1)
        DEC T0+1	     ; Set True
REL_F:  
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

; AND: bitwise and
EB_and: JSR REL_SETUP
        LDA T1
        AND T0
        STA T0
        LDA T1+1
        AND T0+1
;        STA T0+1
;        BRA EB_bool
        BRA EB_EPILOG

; OR: bitwise or
EB_or:  JSR REL_SETUP
        LDA T1
        ORA T0
        STA T0
        LDA T1+1
        ORA T0+1
;        STA T0+1
;        BRA EB_bool
        BRA EB_EPILOG

; XOR: bitwise exclusive-or
EB_xor: JSR REL_SETUP
        LDA T1
        EOR T0
        STA T0
        LDA T1+1
        EOR T0+1
EB_EPILOG:
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
        JSR GETCI       ; consume token
        LDA T0
        PHA
        LDA T0+1
        PHA
        JSR EXPR_ADD
        PLA
        STA T1+1
        PLA
        STA T1
EA_rts: RTS

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
EA_sum: 
        LDX #(T1-T0)    ; 2
        JSR ADDT0_TO    ; 3
        JSR TO_T0       ; 3 = 8
        BRA EA_lp

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

E1_mod_result:
        LDX #(T2-T0)          ; remainder -> T0
        JSR TO_T0
        ; *** FALL THROUGH to E1_SIGN ***
        ; ---- shared sign postamble ----
E1_sign:
        PLA                  ; pull saved sign byte
        BPL E1_pos
        JSR NEG16            ; result should be negative
E1_pos: BRA E1_lp            ; tail jump to loop  (saves 1 RTS)

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
        LDX #(T1-T0)          ; quotient -> T0
        JSR TO_T0
        BRA E1_sign

        ; ---- MUL kernel: T2 = |T1| * |T0|  (shift-and-add) ----
E1_mul_mb:
        LSR T1+1
        ROR T1
        BCC E1_mul_ms
        LDX #(T2-T0)
        JSR ADDT0_TO
E1_mul_ms:
        ASL T0
        ROL T0+1
        DEY
        BNE E1_mul_mb
        LDX #(T2-T0)          ; result -> T0
        JSR TO_T0
        BRA E1_sign

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
        LDA RND_SEED
        STA T0
        LDA RND_SEED+1
        AND #$7F             ; force positive (clear bit 15) ? 1..32767
        STA T0+1
        ; drop through
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
; E2_USR ? USR(addr): call machine-code subroutine at addr
;   In:  T0 = addr (consumed centrally by EXPR2_t1 dispatcher)
;   On entry: A = T0 lo byte (low byte of last expression, for parameter passing)
;   Out: T0  (caller sets this before RETURN if returning a value)
;   Clobbers: A X Y (and anything the called routine touches)
; =============================================================================
E2_usr: LDA T0                ; restore documented "A = T0 lo byte" entry invariant
        JMP (T0)            ; tail call

; =============================================================================
; E2_SGN ? SGN(n): sign of n  ?  -1 (negative), 0 (zero), 1 (positive)
; E2_sgn removed (v15.0, space for CORDIC)
; =============================================================================
E2_pos: JSR GETCI            ; unary plus: no-op
        ; drop through
; =============================================================================
; E2_GRP -- generic parenthesized sub-expression: (expr)
;   Distinct from E2_chrs/E2_ARG1: those expect a function TOKEN first,
;   consumed by GETCI, then a '(' consumed by WEAT. Here the '(' itself is
;   what GETCI consumes, so there is no separate opening delimiter left to
;   eat -- go straight to EXPR, then eat the closing ')' (same JMP WEAT
;   tail-call idiom as E2_asc_exit).
;   Was previously routed through E2_chrs, which double-consumed and ate
;   the first byte of the inner expression instead of a delimiter (bug).
;   Clobbers: A T0 (+ whatever EXPR clobbers)
; =============================================================================
E2_grp: JSR GETCI            ; consume '('
        JSR EXPR             ; evaluate inner expression
        BRA WEAT              ; consume ')' and return (tail call)

EXPR2:
        JSR WPEEK
        CMP #'('
        BEQ E2_grp 
        CMP #'-'
        BEQ E2_neg
        CMP #'+'
        BEQ E2_pos
        CMP #TOK_NOT
        BEQ E2_not
        CMP #TOK_NUM
        BEQ PNUM
        CMP #TOK_ASC
        BNE EXPR2_t1
        JMP E2_asc

; =============================================================================
; EXPR2_t1 -- Group A/B function tokens: table-dispatched (v15.17)
;   TOK_RND..TOK_COS ($A4-$A9) are contiguous by design (see TOK_* block).
;   RND (Group B: 0-arg, no parens) sits at FUNC_LO; ABS/PEEK/USR/SIN/COS
;   (Group A: uniform 1-arg, paren-wrapped) sit immediately above it and
;   are indexed into FUNC_JT. Replaces the old per-token CMP/BEQ chain.
;   Anything below FUNC_LO here is not a function token -> try as variable.
; =============================================================================
EXPR2_t1:
        CMP #TOK_RND          ; FUNC_LO
        BCS EXPR2_t1a         ; in range (>= FUNC_LO): continue below
        JMP EXPR2_tvar        ; below range: not a function token, try as variable
EXPR2_t1a:
        BEQ E2_rnd            ; == FUNC_LO: RND (0-arg, no parens)
        ; else: TOK_ABS..TOK_COS -- consume token + eat '(' expr ')' into T0
        ; centrally (was done per-handler via each's own JSR E2_chrs), then
        ; index into FUNC_JT (word index = (token - TOK_ABS) * 2).
        SEC
        SBC #TOK_ABS
        ASL
        PHA                   ; stash word-index across the recursive JSR E2_chrs below
        JSR E2_chrs            ; consume token, eat '(' expr ')' -> T0
        PLX
        .DB $7C                ; JMP (FUNC_JT,X)  -- 65C02 absolute indexed indirect
        .DW FUNC_JT

FUNC_JT:
        .DW E2_abs, E2_peek, E2_usr, E2_sin, E2_cos   ; TOK_ABS..TOK_COS ($A5-$A9)

; =============================================================================
; E2_PEEK ? PEEK(addr): read one byte from memory address  ?  0..255
;   In:  T0 = address (consumed centrally by EXPR2_t1 dispatcher)
;   Clobbers: A T0
; =============================================================================
E2_peek:
        LDA (T0)             ; 65C02 zp-indirect: read memory at addr
        STA T0
        STZ T0+1
        RTS

; =============================================================================
; E2_CHRS ? CHR$(n): numeric ASCII code to character value for PRINT
;   Returns n unchanged in T0; PRINT emits it directly via PUTCH.
;   PRINT-scoped only (v15.17): called directly by DO_PRINT's own TOK_CHRS
;   check, and reused as the shared "consume token, eat (expr)" helper by
;   E2_abs/E2_peek/E2_usr. No longer reachable as a general EXPR2 atom --
;   CHR$() outside a PRINT item is not recognized (smaller binary; TAB has
;   the same PRINT-only scope already).
;   Clobbers: A T0
; =============================================================================
E2_chrs:
        JSR GETCI            ; CHR$(n): result is just n (char value)
        ; drop through
; =============================================================================
; E2_ARG1 ? shared parser helper for single-argument functions
;   In:  IP points at '('
;   Out: T0 = argument value; IP advanced past closing ')'
; =============================================================================
E2_ARG1:
        JSR EAT_EXPR         ; consume '(' then evaluate argument
        ; drop through
; =============================================================================
; WEAT ? skip whitespace, consume (eat) the next byte
;   In:  IP   token stream pointer
;   Out: A    the consumed byte;  IP  advanced one past the first non-space
;   Clobbers: None.
; =============================================================================
WEAT:   JSR WPEEK
        JMP GETCI            ; consume the non-space byte and return  (tail call)

; --- atom handlers (placed here so preamble BEQs above are in range) ---

; NOT: bitwise complement.  No parens (like unary -/+): consume token,
; then recurse straight into EXPR2 for the operand -- do NOT route through
; E2_chrs/E2_ARG1, which assumes a following '(' and would eat one byte
; of the operand instead (this was a real bug: "NOT 0;X" truncated the
; rest of the statement because E2_ARG1's WEAT ate the operand's leading
; byte). Mirrors E2_neg's shape exactly.
E2_not: JSR GETCI    ; consume NOT token
        JSR EXPR2    ; evaluate operand directly (no paren expected)
        LDA T0
        EOR #$FF
        STA T0
        LDA T0+1
        EOR #$FF
        STA T0+1
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

E2_neg: JSR GETCI            ; unary minus
        JSR EXPR2
        BRA N16TRAMP         ; NEG16 tail call trampoline

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
E2_abs_pos:
        RTS

; =============================================================================
; E2_ABS ? ABS(n): absolute value of n  ?  n if n=0, else -n
;   In:  T0 = n (consumed centrally by EXPR2_t1 dispatcher)
;   Clobbers: A T0
; =============================================================================
E2_abs: LDA T0+1
        BPL E2_abs_pos
N16TRAMP:
        JMP NEG16            ; tail call: negate if negative

; =============================================================================
; ASR16 -- arithmetic right shift T0 by X positions (X=0..11)
;   In : T0 signed 16-bit; X = count
;   Out: T0 shifted, sign-extended
;   Clobbers: A X
; =============================================================================
ASR16:
        TXA ; CPX #0    ; save 1 byte
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
; E2_sin / E2_cos  --  SIN(deg)*1000 / COS(deg)*1000
;   In : T0 = angle in degrees (consumed centrally by EXPR2_t1 dispatcher)
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
        LDA #1
        STA ATEMP           ; 1 = want COS
        .DB $2C             ; skip next 2 bytes
E2_sin:
        STZ ATEMP           ; 0 = want SIN
SC_GO:
        ; Range check: T0+1 must be 0 or 1
        LDA T0+1
        CMP #2
        BCC SC_VALID         ; hi=0 or 1: angle 0-360, valid
SC_RET0:                    ; hi>=2: out of range -> return 0
        STZ T0
        STZ T0+1
CK_DN:  RTS

SC_VALID:
        LDY #0               ; quadrant flags start at 0
        TAX                  ; save hi byte for the >180 check
        ; 1) fold angle > 180? (angle -= 180, flags = 3: negate both CX and CY)
        BNE SC_180           ; hi!=0: angle >= 256, definitely > 180
        LDA T0
        CMP #181
        BCC SC_90            ; hi=0 and angle < 181: no fold needed here
SC_180: LDA T0
        SEC
        SBC #180
        STA T0
        LDA T0+1
        SBC #0
        STA T0+1             ; 16-bit subtract handles the hi=1 borrow correctly
        LDY #3
        ; 2) fold angle > 90? (angle = 180-angle, flags ^= 1: flip CX negation)
SC_90:  LDA T0
        CMP #91
        BCC SC_FLAGS         ; < 91: quadrant resolved
        EOR #$FF
        SEC
        ADC #180             ; ~A+1+180 == 180-A  (T0+1 guaranteed 0 here)
        STA T0
        TYA
        EOR #1
        TAY
SC_FLAGS:
        STY T1               ; save quadrant flags
        ; Multiply T0 (0-90) * 182 -> CZ  (182=0b10110110)
        LDA #182
        STA T2              ; use T2 as multiplier shift reg (T1 flags already saved)
        STZ CZ
        STZ CZ+1
        LDX #8
SC_ML:  LSR T2              ; bit -> C
        BCC SC_MN
        LDX #(CZ-T0)
        JSR ADDT0_TO
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
        ; Apply quadrant negations from T1 (in-place shifts avoid reloading A)
        LSR T1               ; bit0 -> C: negate CX?
        BCC SC_NCX
        LDX #CX-T0
        JSR NEG_X
SC_NCX: LSR T1               ; bit1 -> C: negate CY?
        BCC SC_NCY
        LDX #CY-T0
        JSR NEG_X
SC_NCY:
        ; Result select: ATEMP=0->SIN(CY), ATEMP=1->COS(CX)
        LDX #(CY-T0)          ; default: SIN
        LDA ATEMP
        BEQ SC_SEL
        LDX #(CX-T0)          ; switch to COS
SC_SEL: JSR TO_T0
SC_SCALE:
        ; Absolute value (store sign implicitly: bit 7 of ATEMP)
        LDA T0+1
        STA ATEMP
        BPL SC_SDO
        JSR NEG16           ; make positive for scaling
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
        LDX #(T2-T0)
        JSR ADDT0_TO
SC_SMN: ASL T0
        ROL T0+1
        DEX
        BNE SC_SML
        ; >>6: T0 = T2>>6
        LDX #(T2-T0)
        JSR TO_T0
        LDX #6
        JSR SHIFT_R16_T0
        ; Apply sign
        BIT ATEMP
        BPL SC_DONE
        ; drop through

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
NEG16:
        LDX #0               ; X=0: address offset to T0
        .DB $2C            ; BIT abs  ? consumes next 2 bytes as operand
NEG_T1:
        LDX #2               ; X=2: address offset to T1 from T0
NEG_X:                       ; entry with X pre-loaded by caller
        LDA #0
        SEC
        SBC T0,x
        STA T0,x
        LDA #0
        SBC T0+1,x
        STA T0+1,x
SC_DONE:
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

        ; 1) CX = CX -/+ (CY >> i)
        LDX #(CY-T0)
        JSR TO_T0
        LDX CIDX
        JSR ASR16
        LDA CZ+1
        BMI CK_P1            ; CZ<0: want ADD, skip negate
        JSR NEG16            ; CZ>=0: want SUB, negate T0 then add
CK_P1:  LDX #(CX-T0)
        JSR ADDT0_TO

        ; 2) CY = CY +/- (CX_SAV >> i)
        LDX #(CX_SAV-T0)
        JSR TO_T0
        LDX CIDX
        JSR ASR16
        LDA CZ+1
        BPL CK_P2            ; CZ>=0: want ADD, skip negate
        JSR NEG16            ; CZ<0: want SUB, negate T0 then add
CK_P2:  LDX #(CY-T0)
        JSR ADDT0_TO

        ; 3) CZ = CZ -/+ ATAN_TBL[i]
        LDX CIDX
        TXA
        ASL
        TAX
        LDA ATAN_TBL,x
        STA T0
        LDA ATAN_TBL+1,x
        STA T0+1
        LDA CZ+1
        BMI CK_P3            ; CZ<0: want ADD, skip negate
        JSR NEG16            ; CZ>=0: want SUB, negate T0 then add
CK_P3:  LDX #(CZ-T0)
        JSR ADDT0_TO

        LDX CIDX
        INX
        CPX #12
        BNE CK_IT
        RTS

; =============================================================================
; TO_T0 / T0_TO_CURLN / STORE_VAR / ADDT0_TO / GETVARC
;   Size-optimization pass 2: shared bodies for the 16-bit copy/add/store/
;   var-index idioms asmdup.py found repeated across the file. Same NEG_X
;   convention as above (caller pre-loads X with (source_zp - T0); zero-
;   page,X wraps mod 256 so this reaches any zero-page location regardless
;   of how far it sits from T0).
; =============================================================================

; TO_T0 ? copy a 16-bit zero-page value into T0
;   In:  X = (src_zp - T0), pre-loaded by caller
;   Out: T0 = src (16-bit)
;   Clobbers: A
TO_T0:
        LDA T0,x
        STA T0
        LDA T0+1,x
        STA T0+1
        RTS

; T0_TO_CURLN ? copy T0 into CURLN  (fixed src/dst, no X needed)
;   In:  T0
;   Out: CURLN = T0 (16-bit)
;   Clobbers: A
T0_TO_CURLN:
        LDA T0
        STA CURLN
        LDA T0+1
        STA CURLN+1
        RTS

; ADDT0_TO ? add T0 into a 16-bit zero-page accumulator
;   In:  X = (dst_zp - T0), pre-loaded by caller; T0 = addend
;   Out: dst += T0 (16-bit, wraps)
;   Clobbers: A
ADDT0_TO:
        CLC
        LDA T0,x
        ADC T0
        STA T0,x
        LDA T0+1,x
        ADC T0+1
        STA T0+1,x
        RTS

; GETVARC ? read next char, uppercase, subtract 'A'
;   In:  IP (via GETCI)
;   Out: A = char - 'A'  (0-25 if a valid letter; caller checks range/carry)
;        flags set by the SBC (same as inline SEC/SBC #'A' would leave)
;   Clobbers: A
GETVARC:
        JSR GETCI
        JSR UC
        SEC
        SBC #'A'
        RTS

; CMP16 ? compare two 16-bit zero-page values for equality
;   In:  X = zp addr of A, Y = zp addr of B (both pre-loaded by caller)
;   Out: Z flag set iff A==B (16-bit); same early-exit-on-low-byte-mismatch
;        semantics as the inline LDA/CMP/BNE/LDA/CMP it replaces, so the
;        caller's existing BEQ/BNE after the JSR works unchanged.
;   Clobbers: A
;   Uses ZP0 (permanent $0000 zp pointer) so Y can address B directly via
;   (ZP0),Y -- STA/CMP don't support zp,Y, this is the equivalent trick.
CMP16:
        LDA $00,x
        CMP (ZP0),y
        BNE CMP16_ne
        INY
        LDA $01,x
        CMP (ZP0),y
CMP16_ne:
        RTS

; CMP_T0_LP ? compare 16-bit T0 vs LP for equality, Z set iff equal
;   Same early-exit-on-low-byte-mismatch semantics as the inline code it
;   replaces, so the caller's BEQ/BNE after the JSR works unchanged.
;   Fixed operands (not X/Y-parameterized like CMP16) and does NOT touch
;   Y -- needed because both call sites live inside INSLINE's backward
;   copy loop, which holds Y at a constant 0 for its own (T0),y/(T1),y
;   addressing; CMP16's (ZP0),y trick would clobber that.
;   Clobbers: A
CMP_T0_LP:
        LDA T0
        CMP LP
        BNE CMP_T0_LP_ne
        LDA T0+1
        CMP LP+1
CMP_T0_LP_ne:
        RTS

; =============================================================================
; EXPR2_tvar ? variable or unrecognised atom (BRA from dispatch above)
; =============================================================================
EXPR2_tvar:
        JSR PARSE_VAR        ; harmless redundant WPEEK_UC re-peek (IP unmoved so far)
        BCC ET_ok            ; C=0: matched
;        JMP E2_bad           ; C=1: no match (E2_bad too far for BCS)
E2_bad: STZ T0               ; unrecognised atom: return 0
        STZ T0+1
        RTS   

ET_ok:  TAX
        LDA VARS,x
        STA T0
        LDA VARS+1,x
        STA T0+1
        RTS

; =============================================================================
; E2_ASC ? ASC("str") or ASC(n): ASCII code of first character
;   String form: ASC("X") ? ASCII value of X.
;   Numeric form: ASC(n) ? n unchanged (identity, for symmetry with CHR$).
;   Clobbers: A T0
; =============================================================================
E2_asc: JSR GETCI            ; ASC("str") or ASC(n)      get token
        JSR WEAT             ; consume '('
        JSR WPEEK            ; peek next char
        CMP #'"'             ; is it a string?
        BEQ E2_asc_str       ; yes -> jump to string handler

        JSR EXPR             ; no -> evaluate as numeric expression
        BRA E2_asc_exit      ; (65C02) skip over string handler

E2_asc_str:
        JSR GETCI            ; consume opening '"'
        JSR GETCI            ; first char -> A
        STA T0               ; save ASCII value to low byte
        STZ T0+1             ; (65C02) zero high byte

E2_asc_sk:
        JSR GETCI            ; consume next char
        CMP #'"'             
        BEQ E2_asc_exit      ; if '"', we are done
        CMP #$0D             
        BNE E2_asc_sk        ; if not CR, keep looping
                             ; if CR, naturally fall through!
E2_asc_exit:
        JMP WEAT             ; consume ')' and return (tail call)

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
        PLX
        ; drop through
; STORE_VAR ? store T0 into VARS[x]
;   In:  T0, X = var slot*2 (pre-loaded by caller, e.g. via PLX or LDX FVAR)
;   Out: VARS[x] = T0 (16-bit)
;   Clobbers: A
STORE_VAR:
        LDA T0
        STA VARS,x
        LDA T0+1
        STA VARS+1,x
DO_let_dn:
        RTS

DO_let_pop:
        PLA
        LDA #ERR_UK
        JMP DO_ERROR

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
        .DB $2C                 ; consume Space
        ; drop through
; =============================================================================
; PRTSP ? Print Space
;   Out: Space  emitted to terminal device.
;   Clobbers: A
PRTSP: 
        LDA #' '
        ; drop through
; =============================================================================
; PUTCH ? character output  
;   In:  A    character to send
;   Out: Character emitted to terminal device.
;   Clobbers: None.
; =============================================================================
PUTCH:  STA IO_PUTCH
        RTS

; =============================================================================
; PRT_HEX ? print T0 as 4 upper-case hex digits, MSB first (leading zeros)
;   In:  T0   16-bit value
;   Out: 4 hex characters emitted to terminal
;   Clobbers: A T0
;   PRT_HEXB/PRT_HEXN are shared, byte/nibble-level tail-call helpers:
;   PRT_HEX  -> JSR PRT_HEXB (hi byte) -> falls into PRT_HEXB (lo byte)
;   PRT_HEXB -> JSR PRT_HEXN (hi nibble) -> falls into PRT_HEXN (lo nibble)
;   PRT_HEXN ends with a JMP PUTCH tail call (no RTS needed).
; =============================================================================
PRT_HEX:
        LDA T0+1
        JSR PRT_HEXB
        LDA T0
        ; drop through: print lo byte
PRT_HEXB:
        PHA
        LSR
        LSR
        LSR
        LSR
        JSR PRT_HEXN
        PLA
        ; drop through: print lo nibble
PRT_HEXN:
        AND #$0F
        ORA #$30              ; '0'..'9' / ':'..'?' for 10-15
        CMP #$3A
        BCC PRT_HEXN_OK
        ADC #$06              ; carry set from CMP above -> 'A'..'F'
PRT_HEXN_OK:
        BRA PUTCH              ; tail call: emit digit and return

; =============================================================================
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
        CMP #TOK_NUM
        BNE SKST_adv          ; If not a number, skip ahead to the single increment
        JSR IPADD2            ; If it IS a number, skip the 2 extra bytes first
SKST_adv:
        JSR INC_IP            ; Shared increment (applies to all non-terminal tokens)
        BRA SKIP_STMT

; -----------------------------------------------------------------------------
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
        JSR GETVARC
        ASL                  ; x2: byte offset into VARS
SKST_colon:
        CLC
        RTS
SKST_eol:
PV_fail:
        SEC
        RTS

; =============================================================================
; WPEEK_UC ? skip whitespace, peek next byte, uppercase it
;   In:  IP   token stream pointer
;   Out: A    first non-space byte, uppercased;  IP  unchanged
;   Clobbers: None.
;
; UC ? convert A to uppercase if it is a lowercase ASCII letter
;   In:  A    any byte
;   Out: A    uppercased (a-z ? A-Z); all other bytes unchanged
;   Clobbers: None.  (flags are affected)
; =============================================================================
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
        
; -----------------------------------------------------------------------------
; TOKSKIP_LP/IP ? scan (LP),Y for $0D, skipping TOK_NUM payloads
;   In:  Y   starting offset (caller sets it, e.g. LDY #2 to skip a header)
;   Out: Y   offset just past the $0D
;   Clobbers: A
; =============================================================================
TOKSKIP_LP:
TSLP:   LDA (LP),y
        INY
        CMP #TOK_NUM
        BNE TSLP_chk
        INY
        INY
;        BRA TSLP ; not needed as A is a token
TSLP_chk:
        CMP #$0D
        BNE TSLP
        RTS

; TOKSKIP_IP ? identical, but via (IP),Y
;   In:  Y   starting offset (caller sets it)
;   Out: Y   offset just past the $0D
;   Clobbers: A
TOKSKIP_IP:
TSIP:   LDA (IP),y
        INY
        CMP #TOK_NUM
        BNE TSIP_chk
        INY
        INY
;        BRA TSIP ; not needed as A is a token
TSIP_chk:
        CMP #$0D
        BNE TSIP
        RTS

; =============================================================================
; DO_ELSE_SK -- bare ELSE at statement level: skip rest of line
;   Reached via STMT_JT when ELSE appears as a bare statement (i.e. the false
;   branch of IF already consumed the THEN body and RUNLP calls STMT again,
;   which sees ELSE first).  We simply discard everything to end-of-line.
;
; SKIPEOL ? advance IP past the $0D end-of-line marker
;   In:  IP   anywhere in the current token stream line
;   Out: IP   points at first byte of the next line
;   Clobbers: A
; =============================================================================
DO_ELSE_SK:
SKIPEOL:
        JSR SKIP_STMT         ; C=0 at ':', C=1 at $0D
        JSR INC_IP              ; advance past whichever terminator we stopped at
        BCC SKIPEOL            ; ':' -> more statements on this line: keep scanning
        RTS                     ; $0D -> IP now points past it

; =============================================================================
; I/O stubs ? Kowalski simulator virtual terminal
; =============================================================================
; GETCH ? blocking character input
;   In:  None.
;   Out: A    character received
;   Clobbers: None.
GETCH:  JSR RND_SHUFFLE
        LDA IO_GETCH         ; poll Kowalski virtual port
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

; =============================================================================
; DATA TABLES  (no page constraint ? placed here after main code)
; CORDIC atan table: atan(2^-i) in units where 16384 = 90 degrees
; Value[i] = round(16384 * atan(2^-i) / 90).  12 entries x 2 bytes = 24 bytes.
ATAN_TBL:
        .DW 8192, 4836, 2555, 1297, 651, 326, 163, 81, 41, 20, 10, 5

ROMEND = *                   ; first byte after executable ROM code 

; =============================================================================
; Vector page notes:
        .ORG $FFFC
        .DW INIT             ; RESET vector
        .DW IRQ_HANDLER          ; IRQ vector
