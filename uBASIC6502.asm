; uBASIC2650.asm  —  Tiny BASIC for Signetics 2650
; Version: v1.11 - BUG-SCA-12: *SWSTK→SWSTK in DO_RUN; BUG-SCA-13: inline labels split
;
; Initial Target: PIPBUG 1 monitor (1kB ROM $0000-$03FF, 64B RAM $0400-$043F)
;   Code base $0440.  Variables pinned at $1500 (ORG).  Program store $15B8+.
;   I/O via PIPBUG ROM entry points (BSTA,UN):
;     COUT $02B4  — output char in R0
;     CHIN $0286  — blocking input, char returned in R0
;     CRLF $008A  — emit CR+LF (R0 not significant on entry or exit)
;
; Assembler: asm2650.c v1.6   Simulator: sim2650.c v1.9
; Build:
;   gcc -Wall -O2 -o asm2650 asm2650.c
;   gcc -Wall -O2 -o sim2650 sim2650.c
;   ./asm2650 uBASIC2650.asm uBASIC2650.hex
;   ./sim2650 --pipbug uBASIC2650.hex
;   ./sim2650 --pipbug -t uBASIC2650.hex             # CPU trace
;   ./sim2650 --pipbug -b 0xADDR uBASIC2650.hex      # breakpoint
;   ./sim2650 --pipbug -m 0xADDR LEN uBASIC2650.hex  # mem dump at halt
;
; NOTE: Winarcadia assembler expects LABELS: to be on a dedicated line
;
; CC SEMANTICS (2650 ALU — SUB sets opposite of most CPUs):
;   ADD: no-carry->GT  carry+zero->EQ  carry+nonzero->LT
;   SUB: no-borrow+nonzero->GT  no-borrow+zero->EQ  borrow->LT
;   Carry skip:  BCTA,GT lbl  (GT = C=0 = no carry)
;   Borrow skip: BCFA,LT lbl  (NOT LT = no borrow, covers GT+EQ)
;
; HI/LO OPERATOR CONVENTION (WinArcadia / asm2650.py standard):
;   <ADDR = HIGH byte (bits 15:8)   e.g. <$1584 = $15
;   >ADDR = LOW  byte (bits  7:0)   e.g. >$1584 = $84
;
; DO_ERROR convention: LODI,R0 <code>; BCTA,UN DO_ERROR
;   Saves RUNFLG, clears run state, then BCTA,UN REPL (flushes hardware RAS).
;
; RAS DEPTH BUDGET (8-level hardware stack, shared by BSTA and BSTR):
;   PIPBUG COUT: uses BSTR DLAY inside = caller+2. CRLF: BSTR COUT→BSTR DLAY = caller+3.
;   PIPBUG CHIN: uses BSTR DLAY/DLY inside = caller+2.
;   Our deepest path: STMT_EXEC(1)→PARSE_EXPR(2)→APPLY_OP(3)→MUL16(4)→INC_EXP(5)
;                  or STMT_EXEC(1)→PRINT_S16(2)→COUT(3)→[BSTR DLAY inside COUT](4)
;   Verified max depth = 5. Limit = 8. Margin = 3. DO_IF adds 2 more → max 7. Safe.
;
; SCRATCH REGISTER ALLOCATION:
;   SC0:SC1   — general scratch; clobbered by STMT_EXEC (do NOT use for inter-
;               statement state — see BUG-BASIC-13)
;   SWSTK[0:1] ($152E:$152F) — DO_RUN next-line-pointer save across STMT_EXEC
;   LNUMH:LNUML — scratch line number; also used as save in DO_LIST (BUG-BASIC-12)
;   R2        — never written by any routine; safe as long-lived scratch
;   TMPH:TMPL — general 16-bit temp; clobbered by PRINT_S16 (loads DIVTAB ptr)
;
; Change history:
;   v1.11 BUG-SCA-12 FIXED: DO_RUN next-line-pointer save/restore used
;           STRA,R0 *SWSTK / LODA,R0 *SWSTK (indirect — dereferences the value
;           stored AT SWSTK as a pointer, then accesses that address). After
;           CLRV, SWSTK=$00:$00, so the first RUN wrote the next-line pointer
;           hi byte into PIPBUG ROM at $0000. Fix: STRA,R0 SWSTK / LODA,R0 SWSTK
;           (direct), matching the correct SWSTK+1 usage on adjacent lines.
;         BUG-SCA-13 FIXED: WinArcadia assembler requires labels to be on their
;           own dedicated line (per header comment). Three labels had code on the
;           same line: UC_DO:, UC_RET:, EW_DS:. WinArcadia silently dropped the
;           instruction on the label line, so UC_DO jumped to RETC,UN instead of
;           SUBI,R0 32 — lowercase input was never uppercased, so every keyword
;           scan failed and every direct command returned ?0. Fix: split all
;           three labels onto their own lines.
;   v1.10 BUG-SCA-11 FIXED: BDRR/BDRA semantics are rn--; if(rn!=0) branch —
;           exit when rn hits zero (not signed underflow to $FF as previously
;           assumed). All v1.9 BDRR conversions that load a count from memory
;           (bodylen, shift count) are correct because N iterations occur for
;           load value N. Two sites had hardcoded wrong loads:
;           (a) CLRV: load was $33 → only 51 iterations, missing last VARS byte
;               at $15B7. Fix: load $34 for 52 iterations.
;           (b) PU16_M10: load was 9 → only 9 multiplications (off by 1 in
;               every multi-digit number). Fix: load 10 for 10 iterations.
;           Also corrected all BDRR loop comments to say "if R3!=0 branch"
;           instead of "while R3>=0 signed".
;   v1.9  BUG-SCA-01 FIXED: CLRV loop used BRNR,R3 (pure test, no decrement) →
;           infinite loop on startup. R3 never reached zero. Fix: BDRR,R3 with
;           initial load adjusted for BDRR semantics (exits after N+1 iters when
;           loaded with N; load $33 for 52 clears, guard zero case not needed as
;           VARS is always 52 bytes). Label CLRV_NC removed (no longer needed).
;         BUG-SCA-02 FIXED: DO_LIST DLS_BLPX body-print loop used BRNR,R3 →
;           infinite loop printing first byte of every stored line body.
;           Fix: BDRR,R3. R3 loaded from memory; guard COMI,R3 $00 / BCTA,EQ
;           DLS_NL before loop entry retained (BDRR with R3=0 would execute once).
;           Label DLS_BNC removed.
;         BUG-SCA-03 FIXED: DO_RUN DR_CPY copy-to-IBUF loop used BRNR,R3 →
;           infinite loop copying line body. Fix: BDRR,R3.
;           Labels DR_TNC, DR_INC removed.
;         BUG-SCA-04 FIXED: STORE_LINE SL_SHLOOP shift loop used BRNR,R3 →
;           infinite loop during any line insertion that requires shifting.
;           Fix: BDRR,R3. Existing zero-count guard (COMI,R3 / BCTA,EQ SL_NOSHIFT)
;           at loop entry retained (BDRR with R3=0 executes once).
;         BUG-SCA-05 FIXED: STORE_LINE SL_WBODY write-body loop used BRNR,R3 →
;           infinite loop writing body bytes. Fix: BDRR,R3.
;           Labels SL_WBNC, SL_WENC removed.
;         BUG-SCA-06 FIXED: FIND_LINE FL_AS advance loop used BRNR,R3 →
;           infinite loop advancing past body bytes; search never found any line
;           beyond the first record. Fix: BDRR,R3. Label FL_ASN removed.
;         BUG-SCA-07 FIXED: FIND_INS FI_AS advance loop — same as BUG-SCA-06.
;           Fix: BDRR,R3. Label FI_ASN removed.
;         BUG-SCA-08 FIXED: DELETE_LINE DL2_SKIP advance loop used BRNR,R3 →
;           infinite loop; deletion never found copy start. Fix: BDRR,R3.
;           Label DL2_SN removed.
;         BUG-SCA-09 FIXED: MUL16 right-operand abs() NEGFLG toggle was inside
;           the carry path only (BCTA,GT jumped over both the hi-byte increment
;           AND the EORI/STRA toggle). For most negative right values (e.g. -3:
;           abs complement+1 = no carry), NEGFLG was never toggled, giving wrong
;           sign: 3*(-3)=+9 instead of -9. Fix: introduce MU_RA_NC label so the
;           no-carry path skips only the hi-byte increment but falls through to
;           the NEGFLG toggle. Same fix applied to DIV16 DV_VA block (BUG-SCA-09b).
;         BUG-SCA-10 FIXED: PARSE_U16 multiply-by-10 loop used BRNR,R3 with
;           LODI,R3 10 — R3 never decremented, so any number with 2+ digits
;           entered an infinite loop during parsing. Fix: BDRR,R3 with load
;           adjusted to 9 (BDRR gives 10 iterations: 9→8→...→0→exit).
;   v1.8  ISSUE-01 RE-FIX: MUL16/DIV16 NEGFLG placement was still wrong.
;           The LODI,R0 1 / STRA,R0 NEGFLG in v1.7 was placed after the
;           hi-byte carry increment, which is only reached on carry. For
;           values like -3 ($FFFD): XOR→$0002, +1→$0003 — no carry, so
;           BCTA,GT branched past NEGFLG=1 to MU_LA/DV_DA. Sign was lost,
;           result printed positive. Fix: introduce MU_LNC/DV_DNC labels,
;           branch there on carry (skipping hi-byte inc), then BOTH paths
;           fall into LODI,R0 1 / STRA,R0 NEGFLG before MU_LA/DV_DA.
;   v1.7  ISSUE-03 FIXED: DO_GOTO set GOTOFLG=$00 (EORZ/STRA) instead of $01.
;           GOTO was silently ignored during RUN — DR_GOTO path never triggered.
;           Fix: LODI,R0 1 / STRA,R0 GOTOFLG.
;         ISSUE-01 FIXED: MUL16/DIV16 NEGFLG reset bug. The abs(left) block
;           contained EORZ,R0 / STRA,R0 NEGFLG AFTER the two's-complement
;           negation carry propagation step. This unconditionally cleared NEGFLG
;           to zero even after it had been set to 1 for a negative left operand.
;           Net effect: negative×anything gave wrong sign (e.g. -3*2=6 not -6).
;           Fix: replace EORZ/STRA in abs(left) blocks with LODI,R0 1 / STRA,R0
;           NEGFLG in both MUL16 and DIV16.
;         ISSUE-02 FIXED: STORE_LINE shift-dest carry corrupted GOTOH.
;           After ADDA,R0 SC1 / STRA,R0 GOTOL, the carry from the low-byte add
;           was lost when LODA,R0 LNUMH loaded LNUMH (clobbering CC). The
;           subsequent BCTA,GT SL_DSNCA tested LNUMH's sign/zero, not carry.
;           Fix: test carry with BCTA,GT before LODA, duplicate LODA on both
;           paths (carry / no-carry), store GOTOH on both paths.
;         ISSUE-05 FIXED: PARSE_RELOP no-match path returned ERRFLG=$00 (success)
;           when no relop character found. DO_IF proceeded as if relop was valid,
;           using the previous RELOP value — silent wrong comparison.
;           Fix: set ERRFLG=$01 before RETC,UN on the no-match path.
;         ISSUE-04 FIXED: SE_SCAN / SE_C2N table-advance used BCTR,GT (relative
;           short branch) to skip TMPH hi-byte increment, but CC after STRA is
;           set by the stored value not the carry. Replaced with carry-safe idiom:
;           test carry via BCTA,GT before STRA, then branch two paths.
;           Note: practical risk was near-zero (KW_TAB <64B, no page wrap), but
;           corrected for correctness.
;         ISSUE-06 FIXED: Removed redundant second NUL check in RDLINE. After
;           BUG-ASM-08 fix (v1.6), the first NUL check at RL_LP entry catches
;           EOF. The second check after RL_STORE was unreachable dead code.
;   v1.6  BUG-BASIC-14 FIXED: DO_LET variable letter saved to SC0 before
;           PARSE_EXPR, but PARSE_EXPR clobbers SC0 (operator stack writes it
;           repeatedly). DL_STORE read the token id, not the letter. All LET
;           statements wrote to the wrong VARS slot.
;           Fix: STRZ,R2 saves letter to R2 (never written by any routine);
;           DL_STORE restores with LODZ,R2 before computing VARS address.
;           DO_INPUT also updated for consistency.
;         BUG-BASIC-15 FIXED: PF_LOADVAR saved variable letter to SC0, called
;           INC_IP (clobbers R0 with new IPL), then used R0 directly for the
;           VARS offset calculation instead of reloading from SC0.
;           Fix: LODA,R0 SC0 added after INC_IP call.
;         BUG-BASIC-16 FIXED: All 15 indexed VARS/stack accesses used
;           STRA,R1 TMPL after ADDZ,R1. ADDZ,R1 means R0 += R1 (ends-in-Z
;           affects R0); R1 is unchanged. Storing R1 always wrote the base
;           address low byte, not the computed offset. This is the v1.4
;           BUG-BASIC-07 "fix" applied backwards — it swapped R0→R1 but R0
;           is correct (R0 holds the sum after ADDZ). The original code was
;           right; the v1.4 fix broke it. All 15 STRA,R1 TMPL → STRA,R0 TMPL.
;         BUG-ASM-08 FIXED: RDLINE entered infinite NUL loop after stdin EOF.
;           GETKEY returns NUL ($00) forever once stdin is exhausted. RDLINE
;           stored NULs filling IBUF, then overflowed into VARS ($1584+),
;           zeroing variable values set by LET during RUN. This is why LET
;           worked (confirmed by watchpoint at $1585) but the value was then
;           clobbered before PRINT could read it.
;           Fix: added COMI,R0 NUL / BCTA,EQ RL_EOL immediately after GETKEY
;           in RL_LP. NUL from stdin EOF is treated as end-of-line.
;   v1.5  BUG-BASIC-09 FIXED: TRY_STORE_LINE/TSL_DONE cleared ERRFLG to $00
;           after storing a numbered line. REPL checks ERRFLG=$01 to skip
;           execution, so every stored line was immediately executed too.
;           Fix: TSL_DONE sets ERRFLG=$01.
;         BUG-BASIC-10 FIXED: FIND_LINE never set ERRFLG=$01 for "not found".
;           ERRFLG was cleared at entry and never set to $01; FL_RET returned
;           with ERRFLG=$00 (same as "found"), so DELETE_LINE always believed
;           a line existed and corrupted the program store on every STORE_LINE.
;           Fix: FL_RET sets ERRFLG=$01 before returning.
;         BUG-BASIC-11 FIXED: FIND_INS used BCTA,UN FI_RET on both GT and EQ
;           hi-byte compare, making the lo-byte check dead code. Lines sharing
;           the same hi byte (e.g. 10 and 20, both hi=$00) were always inserted
;           at the first record found, corrupting sort order.
;           Fix: BCTA,GT FI_RET so EQ falls through to lo-byte comparison.
;         BUG-BASIC-12 FIXED: DO_LIST called PRINT_S16 without saving TMPH:TMPL.
;           PRINT_S16 loads DIVTAB address into TMPH:TMPL, destroying the LIST
;           iterator. Result: infinite loop printing garbage after first line
;           number. Fix: save/restore TMPH:TMPL via LNUMH:LNUML around call.
;         BUG-BASIC-13 FIXED: DO_RUN saved the next-line pointer in SC0:SC1,
;           but SC0:SC1 are general scratch clobbered by STMT_EXEC (PRINT_S16,
;           STORE_LINE, parser all write SC0/SC1). After executing any line the
;           restored TMPH:TMPL was garbage, causing RUN to jump to a random
;           address. Fix: save next-line pointer in SWSTK[0:1] ($152E:$152F),
;           which are unused until GOSUB is implemented.
;   v1.4  BUG-BASIC-07 (INCORRECTLY FIXED — re-fixed in v1.6 above):
;           Changed STRA,R0 TMPL to STRA,R1 TMPL, believing ADDZ,R1 stored
;           the result in R1. Correct understanding: ADDZ,R1 = R0 += R1.
;   v1.3  BUG-BASIC-03..06, BUG-ASM-04/06/10 fixed (see earlier sessions).
;   v1.2  BUG-BASIC-01: All HI/LO operators corrected (66 swapped lines).
;   v1.1  Initial PIPBUG 1 port.

; ─── ASCII ────────────────────────────────────────────────────────────────────
CR      EQU     $0D
LF      EQU     $0A
BS      EQU     $08
SP      EQU     $20
NUL     EQU     $00
DQ      EQU     $22

; ─── PIPBUG 1 I/O entry points ────────────────────────────────────────────────
COUT    EQU     $02B4   ; putchar: R0 = char to output
CHIN    EQU     $0286   ; getchar: blocking: R0 =  key
CRLF    EQU     $008A   ; print CR+LF (no registers used/changed)

; ─── RAM variables — pinned above code, below PROGLIM ────────────────────────────────────────────────────
; BUG-ASM-10 FIX: Addres $1500 pins variables regardless of code growth.
; Code ceiling: ~$14FF (code must not reach $1500 or assembler will error).
; Variables: $1500-$15B8 (185 bytes). Program store: $15B9-$1BFF (1607 bytes).
IPH     EQU $1500   ; interpreter pointer hi
IPL     EQU $1501   ; interpreter pointer lo
PEH     EQU $1502   ; program end pointer hi
PEL     EQU $1503   ; program end pointer lo
RUNFLG  EQU $1504   ; $01=running $00=immediate
GOTOFLG EQU $1505   ; $01=GOTO/GOSUB pending
GOTOH   EQU $1506   ; pending target line hi
GOTOL   EQU $1507   ; pending target line lo
CURH    EQU $1508   ; current line hi  (error reporting)
CURL    EQU $1509   ; current line lo
LNUMH   EQU $150A   ; scratch line number hi
LNUML   EQU $150B   ; scratch line number lo
SC0     EQU $150C   ; scratch byte 0
SC1     EQU $150D   ; scratch byte 1
ERRFLG  EQU $150E   ; error flag $00=ok $01=error/handled
NEGFLG  EQU $150F   ; sign / CHR$ flag
EXPH    EQU $1510   ; expression result hi
EXPL    EQU $1511   ; expression result lo
TMPH    EQU $1512   ; temp 16-bit hi
TMPL    EQU $1513   ; temp 16-bit lo
OPSTK   EQU $1514   ; operator stack [8]  $1514-$151B
VALSH   EQU $151C   ; value stack hi  [8]  $151C-$1523
VALSL   EQU $1524   ; value stack lo  [8]  $1524-$152B
STKIDX  EQU $152C   ; parser stack top ($FF=empty)
SWSP    EQU $152D   ; SW call stack pointer ($FF=empty)
SWSTK   EQU $152E   ; SW call stack 8×2 bytes  $152E-$153D
RELOP   EQU $153E   ; relational op 1-6
IBUF    EQU $1544   ; input buffer 64 bytes  $1544-$1583
VARS    EQU $1584   ; A-Z variables 2 bytes each  $1584-$15B7
PROG    EQU $15B8   ; program store base
PROGLIM EQU $1c00   ; one past end of program store

; ─── CODE starts at $0440 (after Pipbug 1kB ROM + 64B RAM) ───────────────────
        ORG     $0440

; ─── RESET / ENTRY ────────────────────────────────────────────────────────────
RESET:
        LODI,R0 <PROG
        STRA,R0 PEH
        LODI,R0 >PROG
        STRA,R0 PEL
        LODI,R0 $FF
        STRA,R0 SWSP
        EORZ,R0 ; Clear R0
        STRA,R0 RUNFLG
        STRA,R0 GOTOFLG
        ; clear A-Z variables (52 bytes) using IPH:IPL as scratch pointer
        LODI,R0 <VARS
        STRA,R0 IPH
        LODI,R0 >VARS
        STRA,R0 IPL
; BUG-SCA-01 FIX: was LODI,R3 $34 / BRNR,R3 — BRNR never decrements R3.
; BUG-SCA-11 FIX: BDRR semantics are rn--; if(rn!=0) branch — exits when rn
; hits zero. Load N for exactly N iterations: $34→$33→...→$01→$00→exit = 52.
        LODI,R3 $34             ; 52 iterations: R3 counts $34→$33→...→$01→$00→exit
CLRV:
        EORZ,R0 ; Clear R0
        STRA,R0 *IPH
        BSTA,UN INC_IP
        BDRR,R3 CLRV            ; R3--; if R3!=0 branch
        LODI,R0 <BANNER
        STRA,R0 IPH
        LODI,R0 >BANNER
        STRA,R0 IPL
        BSTA,UN PRTSTR

; ─── REPL ────────────────────────────────────────────────────────────────────
REPL:
        LODI,R0 A'>'
        BSTA,UN COUT
        LODI,R0 SP
        BSTA,UN COUT
        BSTA,UN RDLINE
        LODI,R0 <IBUF
        STRA,R0 IPH
        LODI,R0 >IBUF
        STRA,R0 IPL
        BSTA,UN TRY_STORE_LINE
        LODA,R0 ERRFLG
        COMI,R0 $01
        BCTA,EQ REPL
        BSTA,UN STMT_EXEC
        BCTR,UN REPL

; ─── TABLES ───────────────────────────────────────────────────────────────────
BANNER:
        DB CR, LF
        DB A'u',A'B',A'A',A'S',A'I',A'C',A' ',A'2',A'6',A'5',A'0',A' ',A'v',A'1',A'.',A'0'
        DB CR, LF, NUL

; Keyword table: [c1][c2][token]  NUL-terminated.
; Matched on first two uppercase chars; EATWORD skips the rest.
; Token 11 (THEN) matched internally by DO_IF — not dispatched here.
KW_TAB:
        DB A'P',A'R', 1   ; PRINT / PR
        DB A'L',A'E', 2   ; LET   / LE
        DB A'L',A'I', 3   ; LIST  / LI
        DB A'R',A'E', 4   ; REM   / RE
        DB A'R',A'U', 5   ; RUN   / RU
        DB A'E',A'N', 6   ; END   / EN
        DB A'I',A'N', 7   ; INPUT / IN
        DB A'I',A'F', 8   ; IF
        DB A'N',A'E', 9   ; NEW   / NE
        DB A'G',A'O',10   ; GOTO  / GO
        DB A'P',A'O',12   ; POKE  / PO
        DB NUL

; Divisor table for PRINT_S16: big-endian pairs, sentinel $0000
DIVTAB:
        DB $27,$10      ; 10000
        DB $03,$E8      ;  1000
        DB $00,$64      ;   100
        DB $00,$0A      ;    10
        DB $00,$00      ; sentinel

; ─── STMT_EXEC ────────────────────────────────────────────────────────────────
; Decode and dispatch one statement from IP.
; RAS depth: 1 from REPL, or 3 from DO_IF (THEN body).
; Worst inner depth from here: +4 (->DO_xxx->PARSE_EXPR->PARSE_FACTOR->UPCASE)
STMT_EXEC:
        BSTA,UN WSKIP                   ; [+1]
        LODA,R0 *IPH
        COMI,R0 NUL
        ; BCTA,EQ SE_RET  ; blank line
        RETC,EQ ; Blank line

        BSTA,UN GETCI_UC
        STRA,R0 SC0  ; [+1] char1 uppercase, IP advanced
        BSTA,UN GETCI_UC
        STRA,R0 SC1  ; [+1] char2 uppercase, IP advanced

        ; scan KW_TAB with TMPH:TMPL as pointer
        LODI,R0 <KW_TAB
        STRA,R0 TMPH
        LODI,R0 >KW_TAB
        STRA,R0 TMPL
SE_SCAN:
        LODA,R0 *TMPH
        COMI,R0 NUL
        BCTA,EQ SE_SYNERR  ; end of table
        SUBA,R0 SC0
        BCTR,EQ SE_CHK2  ; c1 matches
        ; ISSUE-04 FIX: advance 3 bytes to next entry with correct carry check.
        ; Old code: ADDI/STRA/BCTR,GT — STRA clobbers CC, branch tests stored
        ; value not carry. New code: test CC from ADDI before STRA.
        LODA,R0 TMPL
        ADDI,R0 3
        BCTR,GT SE_SC_NC        ; GT = no carry
        STRA,R0 TMPL
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
        BCTA,UN SE_SCAN
SE_SC_NC:
        STRA,R0 TMPL
        BCTA,UN SE_SCAN
SE_CHK2:
        ; advance to c2
        BSTA,UN INC_TMP
SE_C2N:
        LODA,R0 *TMPH
        SUBA,R0 SC1
        BCTR,EQ SE_MATCH
        ; c2 mismatch: ISSUE-04 FIX: advance 2 more bytes with correct carry check.
        LODA,R0 TMPL
        ADDI,R0 2
        BCTR,GT SE_C2_NC        ; GT = no carry
        STRA,R0 TMPL
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
        BCTA,UN SE_SCAN
SE_C2_NC:
        STRA,R0 TMPL
        BCTA,UN SE_SCAN
SE_MATCH:
        ; advance to token byte
        BSTA,UN INC_TMP
SE_TN:
        LODA,R0 *TMPH
        STRA,R0 SC0  ; SC0 = token id
        BSTA,UN EATWORD                  ; [+1] consume remaining alpha chars

        ; dispatch
        LODA,R0 SC0
        COMI,R0  1
        BCTA,EQ DO_PRINT
        COMI,R0  2
        BCTA,EQ DO_LET
        COMI,R0  3
        BCTA,EQ DO_LIST
        COMI,R0  4
        BCTA,EQ DO_REM
        COMI,R0  5
        BCTA,EQ DO_RUN
        COMI,R0  6
        BCTA,EQ DO_END
        COMI,R0  7
        BCTA,EQ DO_INPUT
        COMI,R0  8
        BCTA,EQ DO_IF
        COMI,R0  9
        BCTA,EQ DO_NEW
        COMI,R0 10
        BCTA,EQ DO_GOTO
SE_SYNERR:
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR

DO_NEW:
        LODI,R0 <PROG
        STRA,R0 PEH
        LODI,R0 >PROG
        STRA,R0 PEL
        ; RETC,UN
        ; drop through
DO_END:
        EORZ,R0 ; Clear R0
        STRA,R0 RUNFLG
        ; drop through
; ─── SIMPLE STATEMENTS ────────────────────────────────────────────────────────
SE_RET:
DO_REM:
        RETC,UN

; ─── DO_PRINT ─────────────────────────────────────────────────────────────────
; PRINT [item {, item}]    item = "string" | expr
; CHR$ flag: NEGFLG=$01 after PARSE_FACTOR detects CHR$ — print EXPL as char.
DO_PRINT:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 NUL ; No opening " so just CRLF
        BCTA,EQ DP_NL

DP_ITEM:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 DQ
        BCTR,EQ DP_STRING
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG  ; clear CHR$ flag before parse
        BSTA,UN PARSE_EXPR               ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ DP_NUM
        BSTA,UN PRTSTR_IP
        BCTA,UN DP_NL  ; [+1] raw text fallback
DP_NUM:
        LODA,R0 NEGFLG
        COMI,R0 $01
        BCTR,EQ DP_CHAR
        BSTA,UN PRINT_S16
        BCTR,UN DP_SEP  ; [+1]
DP_CHAR:
        LODA,R0 EXPL
        BSTA,UN COUT
        BCTR,UN DP_SEP

DP_STRING:
        ; consume opening "
        BSTA,UN INC_IP
DP_SLP:
        LODA,R1 *IPH
        COMI,R1 NUL
        BCTA,EQ DP_SDONE
        COMI,R1 DQ
        BCTR,EQ DP_SCLS
        LODZ,R1
        BSTA,UN COUT
        BSTA,UN INC_IP
        BCTR,UN DP_SLP
DP_SCLS:
        ; consume closing "
        BSTA,UN INC_IP
DP_SDONE:
DP_SEP:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A','
        BCTR,EQ DP_COMMA
        BCTR,UN DP_NL
DP_COMMA:
        BSTA,UN INC_IP
        BCTA,UN DP_ITEM
DP_NL:
        BSTA,UN CRLF
        RETC,UN

; ─── DO_LET / shared store path ───────────────────────────────────────────────
; DO_INPUT jumps to DL_STORE with SC0 = variable letter already set.
DO_LET:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        BSTA,UN UPCASE  ; [+1]
        COMI,R0 A'A'
        BCTR,LT DL_ERR
        COMI,R0 A'Z'+1
        BCTA,LT DL_VAROK
DL_ERR:
        LODI,R0 4
        BCTA,UN DO_ERROR
DL_VAROK:
        STRA,R0 SC0                      ; save variable letter in SC0 (immediate use)
        STRZ,R2                          ; BUG-BASIC-14 FIX: also save in R2 (STRZ stores R0→Rn).
        ; SC0 is general scratch clobbered by PARSE_EXPR (operator-stack ops
        ; write SC0 repeatedly). R2 is never written by any routine and
        ; survives the full PARSE_EXPR call below.
        BSTA,UN INC_IP
DL_EQ:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'='
        BCTA,EQ DL_EQC
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DL_EQC:
        BSTA,UN INC_IP
DL_EX:
        BSTA,UN PARSE_EXPR               ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ DL_STORE
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DL_STORE:
        ; address = VARS + (SC0 - 'A') * 2
        ; BUG-BASIC-14 FIX: restore variable letter from R2 (SC0 was clobbered
        ; by PARSE_EXPR). R2 is caller-saved across PARSE_EXPR (never written
        ; by any routine). DO_INPUT jumps here with letter already in SC0 and R2.
        LODZ,R2                          ; R0 = variable letter (preserved in R2 across PARSE_EXPR)
        STRA,R0 SC0                      ; resync SC0 for any code reading it below
        SUBI,R0 A'A'  ; 0-25
        STRA,R0 SC1
        ADDA,R0 SC1  ; *2  (SC1 = index, R0 = index*2)
        LODI,R1 >VARS
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VARS
        BCTR,GT DL_NC
        ADDI,R0 1
DL_NC:
        STRA,R0 TMPH
        LODA,R0 EXPH
        STRA,R0 *TMPH  ; store hi
        BSTA,UN INC_TMP
DL_NC2:
        LODA,R0 EXPL
        STRA,R0 *TMPH  ; store lo
        RETC,UN

; ─── DO_INPUT ─────────────────────────────────────────────────────────────────
DO_INPUT:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        BSTA,UN UPCASE  ; [+1]
        COMI,R0 A'A'
        BCTR,LT DIN_ERR
        COMI,R0 A'Z'+1
        BCTR,LT DIN_VAROK
DIN_ERR:
        LODI,R0 4
        BCTA,UN DO_ERROR
DIN_VAROK:
        STRA,R0 SC0                      ; save variable letter
        STRZ,R2                          ; also save in R2 for DL_STORE (SC0 clobbered by PARSE_S16)
        BSTA,UN INC_IP
DIN_PR:
        LODI,R0 A'?'
        BSTA,UN COUT
        LODI,R0 SP
        BSTA,UN COUT
        BSTA,UN RDLINE                   ; [+1]
        LODI,R0 <IBUF
        STRA,R0 IPH
        LODI,R0 >IBUF
        STRA,R0 IPL
        BSTA,UN PARSE_S16                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ DL_STORE
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR

; ─── DO_IF ────────────────────────────────────────────────────────────────────
; IF expr relop expr THEN stmt
; Depth at entry: 2 (from REPL->STMT_EXEC) or 4 (from REPL->STMT_EXEC->DO_IF->STMT_EXEC->here)
; After THEN: calls STMT_EXEC at +1, which can call DO_xxx at +1, PARSE_EXPR at +1,
;             PARSE_FACTOR at +1 → max total 2+1+1+1+1+1 = depth 7 OK.
DO_IF:
        BSTA,UN PARSE_EXPR               ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ DIF_LS
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DIF_LS:
        LODA,R0 EXPH
        STRA,R0 TMPH  ; save left in TMPH:TMPL
        LODA,R0 EXPL
        STRA,R0 TMPL
        BSTA,UN PARSE_RELOP              ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ DIF_RP
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DIF_RP:
        BSTA,UN PARSE_EXPR               ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ DIF_EVAL
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DIF_EVAL:
        ; signed 16-bit compare: TMPH:TMPL (left) vs EXPH:EXPL (right)
        ; bias hi bytes by XOR $80 → unsigned compare
        LODA,R0 TMPH
        EORI,R0 $80
        STRA,R0 SC0
        LODA,R0 EXPH
        EORI,R0 $80
        SUBA,R0 SC0             ; biased right.hi - biased left.hi
        BCTR,LT DIF_LT
        BCTR,GT DIF_GT
        ; hi bytes equal: compare lo (unsigned)
        LODA,R0 EXPL
        SUBA,R0 TMPL
        BCTR,LT DIF_LT
        BCTR,GT DIF_GT
        EORZ,R0 ; Clear R0
        STRA,R0 SC1
        BCTR,UN DIF_TH  ; EQ
DIF_LT:
        LODI,R0 $FF
        STRA,R0 SC1
        BCTA,UN DIF_TH  ; LT
DIF_GT:
        EORZ,R0 ; Clear R0
        STRA,R0 SC1  ; GT

DIF_TH:
        ; consume THEN keyword: expect T then H then EATWORD
        BSTA,UN WSKIP                    ; [+1]
        BSTA,UN GETCI_UC                 ; [+1]  must be A'T'
        COMI,R0 A'T'
        BCTR,EQ DIF_TH2
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DIF_TH2:
        BSTA,UN GETCI_UC                 ; [+1]  must be A'H'
        COMI,R0 A'H'
        BCTA,EQ DIF_EW
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DIF_EW:
        BSTA,UN EATWORD                  ; [+1]

        ; test condition using SC1 ($FF=LT $00=EQ $01=GT) vs RELOP
        LODA,R0 RELOP
        COMI,R0 1
        BCTR,EQ DIF_CEQ  ; =
        COMI,R0 2
        BCTR,EQ DIF_CNE  ; <>
        COMI,R0 3
        BCTR,EQ DIF_CLT  ; <
        COMI,R0 4
        BCTR,EQ DIF_CGT  ; >
        COMI,R0 5
        BCTR,EQ DIF_CLE  ; <=
        COMI,R0 6
        BCTR,EQ DIF_CGE  ; >=
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR

DIF_CEQ: 
        LODA,R0 SC1
        COMI,R0 $00
        BCTR,EQ DIF_TRUE
        BCTR,UN DIF_FALSE
DIF_CNE: 
        LODA,R0 SC1
        COMI,R0 $00
        BCFR,EQ DIF_TRUE
        BCTR,UN DIF_FALSE
DIF_CLT: 
        LODA,R0 SC1
        COMI,R0 $FF
        BCTR,EQ DIF_TRUE
        ;BCTR,UN DIF_FALSE
        RETC,UN
DIF_CGT: 
        LODA,R0 SC1
        COMI,R0 $01
        BCTR,EQ DIF_TRUE
        ;BCTR,UN DIF_FALSE
        RETC,UN
DIF_CLE: 
        LODA,R0 SC1
        COMI,R0 $01
        BCFR,EQ DIF_TRUE
        ; BCTR,UN DIF_FALSE
        RETC,UN
DIF_CGE: 
        LODA,R0 SC1
        COMI,R0 $FF
        BCFR,EQ DIF_TRUE
        ; BCTR,UN DIF_FALSE
        RETC,UN
DIF_TRUE:
        BSTA,UN STMT_EXEC                ; [+1]  execute THEN body
DIF_FALSE:
        RETC,UN

; ─── DO_GOTO ──────────────────────────────────────────────────────────────────
DO_GOTO:
        BSTA,UN PARSE_U16                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ DG_OK
        EORZ,R0 ; Clear 
        BCTA,UN DO_ERROR
DG_OK:
        LODA,R0 EXPH
        STRA,R0 GOTOH
        LODA,R0 EXPL
        STRA,R0 GOTOL
        LODI,R0 1               ; ISSUE-03 FIX: was EORZ/STRA ($00) — must be $01
        STRA,R0 GOTOFLG
        LODA,R0 RUNFLG
        COMI,R0 $01
        ;BCTR,EQ DG_RET
        RETC,EQ
        EORZ,R0 ; Clear R0
        STRA,R0 RUNFLG  ; start run if in immediate mode
DG_RET:
        RETC,UN


DO_LIST:
        LODI,R0 <PROG
        STRA,R0 TMPH
        LODI,R0 >PROG
        STRA,R0 TMPL
DLS_LP:
        LODA,R0 TMPH
        SUBA,R0 PEH
        ; BCTA,GT DLS_RET
        RETC,GT
        BCTA,LT DLS_BODY
        LODA,R0 TMPL
        SUBA,R0 PEL
        BCTR,LT DLS_BODY
        ; BCTA,UN DLS_RET
        RETC,UN
DLS_BODY:
        ; line number hi:lo
        LODA,R0 *TMPH
        STRA,R0 EXPH
        BSTA,UN INC_TMP
DLS_N1:
        LODA,R0 *TMPH
        STRA,R0 EXPL
        BSTA,UN INC_TMP
DLS_N2:
        ; BUG-BASIC-12 FIX: PRINT_S16 clobbers TMPH:TMPL (loads DIVTAB ptr).
        ; Save TMPH:TMPL in LNUMH:LNUML and restore after the call.
        LODA,R0 TMPH
        STRA,R0 LNUMH
        LODA,R0 TMPL
        STRA,R0 LNUML
        BSTA,UN PRINT_S16                ; [+1]
        LODA,R0 LNUMH
        STRA,R0 TMPH
        LODA,R0 LNUML
        STRA,R0 TMPL
        LODI,R0 SP
        BSTA,UN COUT
        ; body length into R3
        LODA,R3 *TMPH
        BSTA,UN INC_TMP
DLS_N3:
        ; BUG-SCA-02 FIX: was BRNR,R3 (pure test, R3 never decremented → inf loop).
        ; Guard zero-body case first (BDRR with R3=0 would execute once wrongly).
        COMI,R3 $00
        BCTA,EQ DLS_NL
DLS_BLPX:
        LODA,R0 *TMPH
        BSTA,UN COUT
        BSTA,UN INC_TMP
        BDRR,R3 DLS_BLPX       ; R3--; if R3!=0 branch
DLS_NL:
        BSTA,UN CRLF
        BCTA,UN DLS_LP
DLS_RET:
        ; RETC,UN

; ─── DO_RUN ───────────────────────────────────────────────────────────────────
; Executes stored lines sequentially, honouring GOTOFLG for GOTO/GOSUB/RETURN.
; SC0:SC1 = next-line-pointer saved BEFORE STMT_EXEC so DO_GOSUB can read it.
DO_RUN:
        LODI,R0 1 
        STRA,R0 RUNFLG
        EORZ,R0 ; Clear R0
        STRA,R0 GOTOFLG
        LODI,R0 <PROG
        STRA,R0 TMPH
        LODI,R0 >PROG
        STRA,R0 TMPL
DR_LP:
        LODA,R0 RUNFLG
        COMI,R0 $00
        ; BCTA,EQ DR_RET
        RETC,EQ
        ; end of program?
        LODA,R0 TMPH
        SUBA,R0 PEH
        BCTA,GT DR_STOP
        BCTR,LT DR_EXEC
        LODA,R0 TMPL
        SUBA,R0 PEL
        BCTR,LT DR_EXEC
        BCTA,UN DR_STOP
DR_EXEC:
        ; save line number for error reporting
        LODA,R0 *TMPH
        STRA,R0 CURH
        BSTA,UN INC_TMP
DR_N1:
        LODA,R0 *TMPH
        STRA,R0 CURL
        BSTA,UN INC_TMP
DR_N2:
        ; body length into R3
        LODA,R3 *TMPH
        BSTA,UN INC_TMP
DR_N3:
        ; copy body to IBUF
        LODI,R0 <IBUF
        STRA,R0 IPH
        LODI,R0 >IBUF
        STRA,R0 IPL
        COMI,R3 $00
        BCTA,EQ DR_CD
DR_CPY:
        LODA,R1 *TMPH
        STRA,R1 *IPH
        BSTA,UN INC_TMP
        BSTA,UN INC_IP
        ; BUG-SCA-03 FIX: was BRNR,R3 — R3 never decremented → infinite copy loop.
        BDRR,R3 DR_CPY          ; R3--; if R3!=0 branch
DR_CD:
        LODI,R1 NUL
        STRA,R1 *IPH  ; NUL-terminate
        ; BUG-BASIC-13 FIX: Save next-line pointer in SWSTK[0:1] instead of
        ; SC0:SC1. SC0 and SC1 are scratch bytes clobbered by STMT_EXEC (used
        ; by PRINT_S16, STORE_LINE, parser, etc.).  SWSTK is the GOSUB return
        ; stack, indexed from the top; [0:1] at $152E:$152F are unused while
        ; SWSP=$FF (empty) and GOSUB is not yet implemented.
        LODA,R0 TMPH
        STRA,R0 SC0      ; SC0:SC1 still set (DO_GOSUB reads them for return addr)
        ; BUG-SCA-12 FIX: was STRA,R0 *SWSTK — indirect addressing writes to the
        ; address stored AT SWSTK ($152E:$152F), not into SWSTK itself. After CLRV
        ; SWSTK contains $0000, so the next-line pointer hi byte was written into
        ; PIPBUG ROM at $0000. Fix: direct STRA,R0 SWSTK stores into $152E.
        STRA,R0 SWSTK    ; NLP_H: save hi byte of next-line ptr directly into $152E
        LODA,R0 TMPL
        STRA,R0 SC1
        LODA,R0 TMPL
        STRA,R0 SWSTK+1  ; NLP_L: save lo byte directly into $152F
        ; execute line
        LODI,R0 <IBUF
        STRA,R0 IPH
        LODI,R0 >IBUF
        STRA,R0 IPL
        BSTA,UN STMT_EXEC                ; [+1]
        ; check GOTO/GOSUB/RETURN flag
        LODA,R0 GOTOFLG
        COMI,R0 $01
        BCTR,EQ DR_GOTO
        ; advance: restore next-line pointer from SWSTK[0:1] (SC0:SC1 clobbered)
        ; BUG-SCA-12 FIX: was LODA,R0 *SWSTK (indirect). Direct read from $152E.
        LODA,R0 SWSTK
        STRA,R0 TMPH
        LODA,R0 SWSTK+1
        STRA,R0 TMPL
        BCTA,UN DR_LP
DR_GOTO:
        EORZ,R0 ; Clear R0
        STRA,R0 GOTOFLG
        LODA,R0 GOTOH
        STRA,R0 LNUMH
        LODA,R0 GOTOL
        STRA,R0 LNUML
        BSTA,UN FIND_LINE                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ DR_LP
        LODI,R0 1
        BSTA,UN DO_ERROR  ; [+1] undefined line — returns to REPL
        BCTA,UN DR_LP
DR_STOP:
        EORZ,R0 ; Clear R0
        STRA,R0 RUNFLG
DR_RET:
        RETC,UN

; ─── TRY_STORE_LINE ───────────────────────────────────────────────────────────
; If IP starts with a digit, parse and store/delete the numbered line.
; Returns ERRFLG=$01 if handled as a numbered line, $00 if immediate.
TRY_STORE_LINE:
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        LODA,R0 *IPH
        COMI,R0 A'0'
        ; BCTR,LT TSL_RET
        RETC,LT
        COMI,R0 A'9'+1
        BCTR,LT TSL_NUM
TSL_RET:
        RETC,UN
TSL_NUM:
        BSTA,UN PARSE_U16                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTR,EQ TSL_GOT
        ;BCTR,UN TSL_RET
        RETC,UN
TSL_GOT:
        ; validate 1..32767
        LODA,R0 EXPH
        ANDI,R0 $80
        BCTR,EQ TSL_RNG
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN  ; >=32768 silently ignore
TSL_RNG:
        LODA,R0 EXPH
        COMI,R0 $00
        BCTR,GT TSL_NZ
        LODA,R0 EXPL
        COMI,R0 $00
        ; BCTA,EQ TSL_RET2  ; line 0 invalid
        RETC,EQ
TSL_NZ:
        LODA,R0 EXPH
        STRA,R0 LNUMH
        LODA,R0 EXPL
        STRA,R0 LNUML
        BSTA,UN WSKIP                    ; [+1]  skip space after line number
        LODA,R0 *IPH
        COMI,R0 NUL
        BCTR,EQ TSL_DEL
        BSTR,UN STORE_LINE               ; [+1]
        BCTR,UN TSL_DONE
TSL_DEL:
        BSTA,UN DELETE_LINE              ; [+1]
TSL_DONE:
        LODI,R0 1               ; BUG-BASIC-09 FIX: $01 = "line stored, skip exec"
        STRA,R0 ERRFLG
TSL_RET2:
        RETC,UN

; ─── STORE_LINE ───────────────────────────────────────────────────────────────
; Insert line LNUMH:LNUML with body at IP into program store (sorted).
; Record format: [linehi][linelo][bodylen][body...]
; Strategy: delete existing line, measure body, check space, find insertion
;           point (EXPH:EXPL), shift existing records up, write new record.
STORE_LINE:
        BSTA,UN DELETE_LINE              ; [+1]  remove if exists

        ; measure body length: walk from IP to NUL, count in R3
        LODA,R0 IPH
        STRA,R0 TMPH
        LODA,R0 IPL
        STRA,R0 TMPL  ; TMPH:TMPL = body start (save for write)
        LODI,R3 0
SL_MEAS:
        LODA,R0 *TMPH
        COMI,R0 NUL
        BCTR,EQ SL_MEASD
        BSTA,UN INC_TMP
SL_MNC:
        BIRR,R3 SL_MEAS         ; R3++ then always branch (counts: 0→1→2...)
SL_MEASD:
        ; R3 = body length.  SC0 = body len.  SC1 = record size = 3 + R3.
        STRA,R3 SC0
        LODA,R0 SC0
        ADDI,R0 3
        STRA,R0 SC1

        ; check free space: PROGLIM - PE >= SC1
        LODI,R0 >PROGLIM
        SUBA,R0 PEL
        STRA,R0 TMPL
        LODI,R0 <PROGLIM
        SUBA,R0 PEH
        BCFR,LT SL_NBC
        SUBI,R0 1  ; borrow skip: BCFA,LT
SL_NBC:
        STRA,R0 TMPH            ; TMPH:TMPL = free bytes
        LODA,R0 TMPH
        COMI,R0 $00
        BCTR,GT SL_ROOM
        LODA,R0 TMPL
        SUBA,R0 SC1
        BCFR,LT SL_ROOM  ; free >= needed?
        LODI,R0 3
        BCTA,UN DO_ERROR  ; out of memory

SL_ROOM:
        ; find sorted insertion point → EXPH:EXPL
        BSTA,UN FIND_INS                 ; [+1]  sets TMPH:TMPL
        ; save insertion point in EXPH:EXPL (TMPH:TMPL will be used as walk pointer)
        LODA,R0 TMPH
        STRA,R0 EXPH
        LODA,R0 TMPL
        STRA,R0 EXPL

        ; shift bytes PE-1 down to EXPH:EXPL upward by SC1 positions (backwards copy)
        ; shift count = PE - EXPH:EXPL
        LODA,R0 PEL
        SUBA,R0 EXPL
        STRA,R0 TMPL
        LODA,R0 PEH
        SUBA,R0 EXPH
        BCFR,LT SL_SHCNB
        SUBI,R0 1
SL_SHCNB:
        STRA,R0 TMPH            ; TMPH:TMPL = shift count

        ; if shift count == 0 skip loop
        LODA,R0 TMPH
        COMI,R0 $00
        BCTR,GT SL_DOSHIFT
        LODA,R0 TMPL
        COMI,R0 $00
        BCTA,EQ SL_NOSHIFT
SL_DOSHIFT:
        ; src = PE-1 in NEGFLG:SC1 (use two scratch bytes; LNUMH:LNUML free now)
        LODA,R0 PEL
        SUBI,R0 1
        STRA,R0 LNUML
        LODA,R0 PEH
        BCFA,LT SL_SNBR
        SUBI,R0 1
SL_SNBR:
        STRA,R0 LNUMH           ; LNUMH:LNUML = src = PE-1
        ; dst = src + SC1 (record size = shift amount)
        ; ISSUE-02 FIX: must test carry from ADDA before any LODA clobbers CC.
        ; Old code did STRA / LODA LNUMH / BCTA,GT — LODA wiped the carry.
        ; New code: test carry immediately after ADDA, then load LNUMH on both paths.
        LODA,R0 LNUML
        ADDA,R0 SC1
        STRA,R0 GOTOL
        BCTA,GT SL_DSNCA        ; GT = no carry from low-byte add (CC still valid)
        LODA,R0 LNUMH           ; carry path: hi += 1
        ADDI,R0 1
        STRA,R0 GOTOH
        BCTA,UN SL_DSNCB
SL_DSNCA:
        LODA,R0 LNUMH           ; no-carry path: hi unchanged
        STRA,R0 GOTOH
SL_DSNCB:

        ; use R3 as count (shift count lo; assume <256 for any real program)
        ; BUG-SCA-04 FIX: was BRNR,R3 at loop end — R3 never decremented → infinite shift.
        ; Guard zero case first (BDRR with R3=0 would execute once wrongly).
        LODA,R3 TMPL
SL_SHLOOP:
        COMI,R3 $00
        BCTA,EQ SL_NOSHIFT
        ; read from LNUMH:LNUML
        LODA,R1 *LNUMH
        ; write to GOTOH:GOTOL
        STRA,R1 *GOTOH
        ; decrement both pointers
        LODA,R0 LNUML
        SUBI,R0 1
        STRA,R0 LNUML
        BCFA,LT SL_SRNB
        LODA,R0 LNUMH
        SUBI,R0 1
        STRA,R0 LNUMH
SL_SRNB:
        LODA,R0 GOTOL
        SUBI,R0 1
        STRA,R0 GOTOL
        BCFR,LT SL_DRNB
        LODA,R0 GOTOH
        SUBI,R0 1
        STRA,R0 GOTOH
SL_DRNB:
        BDRR,R3 SL_SHLOOP       ; R3--; if R3!=0 branch

SL_NOSHIFT:
        ; write record at EXPH:EXPL (insertion point)
        ; restore IP body start to TMPH:TMPL (saved at top of STORE_LINE)
        ; TMPH:TMPL currently = shift count — need to reload body start from IP
        ; IP still points to body start (WSKIP was called before STORE_LINE)
        LODA,R0 IPH
        STRA,R0 TMPH
        LODA,R0 IPL
        STRA,R0 TMPL

        LODA,R0 LNUMH
        STRA,R0 *EXPH  ; write line hi
        BSTA,UN INC_EXP
SL_WN1:
        LODA,R0 LNUML
        STRA,R0 *EXPH  ; write line lo
        BSTA,UN INC_EXP
SL_WN2:
        LODA,R0 SC0
        STRA,R0 *EXPH  ; write body length
        BSTA,UN INC_EXP
SL_WN3:
        ; write body bytes (R3 = body len from SC0)
        ; BUG-SCA-05 FIX: was BRNR,R3 — R3 never decremented → infinite write.
        ; Guard zero-body case first.
        LODA,R3 SC0
        COMI,R3 $00
        BCTA,EQ SL_WDONE
SL_WBODY:
        LODA,R1 *TMPH
        STRA,R1 *EXPH  ; copy body byte
        BSTA,UN INC_TMP
        BSTA,UN INC_EXP
        BDRR,R3 SL_WBODY        ; R3--; if R3!=0 branch
SL_WDONE:
        ; update PE += SC1 (record size)
        LODA,R0 PEL
        ADDA,R0 SC1
        STRA,R0 PEL
        BCTR,GT SL_PENC
        LODA,R0 PEH
        ADDI,R0 1
        STRA,R0 PEH
SL_PENC:
        RETC,UN

; ─── DELETE_LINE ──────────────────────────────────────────────────────────────
DELETE_LINE:
        BSTA,UN FIND_LINE                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ DL2_FOUND
        RETC,UN
DL2_FOUND:
        ; record start in TMPH:TMPL.  Get size: 3 + bodylen at TMPH:TMPL+2.
        LODA,R0 TMPH
        STRA,R0 EXPH  ; save record start in EXPH:EXPL
        LODA,R0 TMPL
        STRA,R0 EXPL
        LODA,R0 TMPL
        ADDI,R0 2
        STRA,R0 TMPL
        BCTR,GT DL2_BLN
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
DL2_BLN:
        LODA,R0 *TMPH
        ADDI,R0 3
        STRA,R0 SC0  ; SC0 = record size
        ; advance TMPH:TMPL past record to get src for copy
        LODA,R3 SC0
        SUBI,R3 2  ; R3 = bodylen + 1  (skip len byte + body)
        ; BUG-SCA-08 FIX: was BRNR,R3 — R3 never decremented → infinite advance,
        ; copy source never found, deletion corrupted program store.
DL2_SKIP:
        COMI,R3 $00
        BCTA,EQ DL2_COPY
        BSTA,UN INC_TMP
        BDRR,R3 DL2_SKIP        ; R3--; if R3!=0 branch
        BCTA,UN DL2_COPY        ; R3 wrapped: all bytes skipped
DL2_COPY:
        ; copy TMPH:TMPL..PE-1 to EXPH:EXPL
DL2_LP:
        LODA,R0 TMPH
        SUBA,R0 PEH
        BCTR,GT DL2_DONE
        BCTR,LT DL2_MOV
        LODA,R0 TMPL
        SUBA,R0 PEL
        BCTR,LT DL2_MOV
        BCTR,UN DL2_DONE
DL2_MOV:
        LODA,R1 *TMPH
        STRA,R1 *EXPH
        BSTA,UN INC_TMP
DL2_TNC:
        BSTA,UN INC_EXP
DL2_ENC:
        BCTR,UN DL2_LP
DL2_DONE:
        ; PE -= SC0
        LODA,R0 PEL
        SUBA,R0 SC0
        STRA,R0 PEL
        BCFA,LT DL2_PNC
        LODA,R0 PEH
        SUBI,R0 1
        STRA,R0 PEH
DL2_PNC:
        RETC,UN

; ─── FIND_LINE ────────────────────────────────────────────────────────────────
; Search for line LNUMH:LNUML in program store (sorted ascending).
; Returns: TMPH:TMPL = record start if found; ERRFLG=$00 found / $01 not found.
FIND_LINE:
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        LODI,R0 <PROG
        STRA,R0 TMPH
        LODI,R0 >PROG
        STRA,R0 TMPL
FL_LP:
        LODA,R0 TMPH
        SUBA,R0 PEH
        BCTA,GT FL_RET
        BCTR,LT FL_CHK
        LODA,R0 TMPL
        SUBA,R0 PEL
        BCTR,LT FL_CHK
        BCTA,UN FL_RET
FL_CHK:
        LODA,R0 *TMPH
        SUBA,R0 LNUMH
        BCTR,LT FL_ADV
        BCTA,GT FL_RET  ; stored.hi > target → not found
        ; hi bytes equal: check lo at TMPH:TMPL+1
        LODA,R0 TMPL
        ADDI,R0 1
        STRA,R0 EXPL
        LODA,R0 TMPH
        BCTR,GT FL_LH
        ADDI,R0 1
FL_LH:
        STRA,R0 EXPH                     ; EXPH:EXPL = lo byte address
        LODA,R0 *EXPH
        SUBA,R0 LNUML
        BCTR,LT FL_ADV
        BCTA,GT FL_RET
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN  ; exact match
FL_ADV:
        ; advance TMPH:TMPL by 3 + bodylen
        LODA,R0 TMPL
        ADDI,R0 2
        STRA,R0 TMPL
        BCTR,GT FL_AN
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
FL_AN:
        LODA,R3 *TMPH                    ; bodylen
        BSTA,UN INC_TMP
FL_AN2:
        ; BUG-SCA-06 FIX: was BRNR,R3 — R3 never decremented → never advanced
        ; past body, so search only ever examined first record.
        COMI,R3 $00
        BCTA,EQ FL_LP
FL_AS:
        BSTA,UN INC_TMP
        BDRR,R3 FL_AS            ; R3--; if R3!=0 branch; fall-thru→done
        BCTA,UN FL_LP            ; all body bytes skipped: check next record
FL_RET:
        LODI,R0 1               ; BUG-BASIC-10 FIX: $01 = "not found"
        STRA,R0 ERRFLG
        RETC,UN

; ─── FIND_INS ─────────────────────────────────────────────────────────────────
; Find sorted insertion point for LNUMH:LNUML.
; Returns TMPH:TMPL = address where new record should be inserted.
FIND_INS:
        LODI,R0 <PROG
        STRA,R0 TMPH
        LODI,R0 >PROG
        STRA,R0 TMPL
FI_LP:
        LODA,R0 TMPH
        SUBA,R0 PEH
        BCTA,GT FI_RET
        BCTR,LT FI_CHK
        LODA,R0 TMPL
        SUBA,R0 PEL
        BCTR,LT FI_CHK
        BCTA,UN FI_RET
FI_CHK:
        LODA,R0 *TMPH
        SUBA,R0 LNUMH
        BCTR,LT FI_ADV
        BCTA,GT FI_RET  ; BUG-BASIC-11 FIX: GT only; EQ falls through to lo check
        ; hi bytes equal: check lo
        LODA,R0 TMPL
        ADDI,R0 1
        STRA,R0 EXPL
        LODA,R0 TMPH
        BCTR,GT FI_LH
        ADDI,R0 1
FI_LH:
        STRA,R0 EXPH
        LODA,R0 *EXPH
        SUBA,R0 LNUML
        BCTR,LT FI_ADV
        BCTA,UN FI_RET
FI_ADV:
        LODA,R0 TMPL
        ADDI,R0 2
        STRA,R0 TMPL
        BCTR,GT FI_AN
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
FI_AN:
        LODA,R3 *TMPH
        BSTA,UN INC_TMP
FI_AN2:
        ; BUG-SCA-07 FIX: was BRNR,R3 — same as BUG-SCA-06, insertion point
        ; search always landed at first record position for multi-record stores.
        COMI,R3 $00
        BCTA,EQ FI_LP
FI_AS:
        BSTA,UN INC_TMP
        BDRR,R3 FI_AS            ; R3--; if R3!=0 branch
        BCTA,UN FI_LP            ; all body bytes skipped: check next record
FI_RET:
        RETC,UN

; ─── PARSE_EXPR ───────────────────────────────────────────────────────────────
; Shunting-yard iterative operator-precedence parser.
; Entry: IP at expression.  Exit: EXPH:EXPL = result, ERRFLG=$00.
; RAS budget: this routine is at depth N; calls PARSE_FACTOR at N+1.
; Max depth from caller: +2. PARSE_FACTOR may call PARSE_EXPR for functions
; at N+1+1 = N+2 total extra levels — tight at deepest path, see ARCH §12.
;
; OPSTK[0..STKIDX]: operator stack   '(' = sentinel (prec 0)
; VALSH/VALSL[0..STKIDX]: value stack
;
; Operator precedences: '('=0 (sentinel, never reduces), '+''-'=1, '*''/'=2
; Reduction: while top-op-prec >= cur-op-prec AND top-op != '(': apply top op
PARSE_EXPR:
        LODI,R0 $FF
        STRA,R0 STKIDX
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG

PX_ATOM:
        ; skip spaces then parse one atom (number, variable, unary, paren)
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'('
        BCTA,EQ PX_LPAR
        COMI,R0 A'-'
        BCTR,EQ PX_UNEG
        COMI,R0 A'+'
        BCTA,EQ PX_UPOS
        BSTA,UN PARSE_FACTOR             ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ PX_PUSHV
        RETC,UN

PX_LPAR:
        ; push '(' sentinel onto OPSTK
        BSTA,UN INC_IP
PX_LPN:
        LODA,R0 STKIDX
        ADDI,R0 1
        STRA,R0 STKIDX
        LODI,R1 >OPSTK
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <OPSTK
        BCTR,GT PX_LPNCA
        ADDI,R0 1
PX_LPNCA:
        STRA,R0 TMPH
        LODI,R0 A'('
        STRA,R0 *TMPH
        BCTA,UN PX_ATOM

PX_UNEG:
        ; consume '-', parse factor, negate result
        BSTA,UN INC_IP
PX_UNN:
        BSTA,UN PARSE_FACTOR             ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ PX_NEG
        RETC,UN
PX_NEG:
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        BSTA,UN INC_EXP
        BCTA,UN PX_PUSHV

PX_UPOS:
        ; consume '+', parse factor — result unchanged
        BSTA,UN INC_IP
PX_UPN:
        BSTA,UN PARSE_FACTOR             ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ PX_PUSHV
        RETC,UN

PX_PUSHV:
        ; push EXPH:EXPL to value stack at STKIDX+1
        LODA,R0 STKIDX
        ADDI,R0 1
        STRA,R0 STKIDX
        LODI,R1 >VALSH
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSH
        BCTA,GT PX_VHN
        ADDI,R0 1
PX_VHN:
        STRA,R0 TMPH
        LODA,R0 EXPH
        STRA,R0 *TMPH
        LODA,R0 STKIDX
        LODI,R1 >VALSL
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSL
        BCTA,GT PX_VLN
        ADDI,R0 1
PX_VLN:
        STRA,R0 TMPH
        LODA,R0 EXPL
        STRA,R0 *TMPH

PX_PEEKOP:
        ; peek next char for operator
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH

        COMI,R0 A')'
        BCTA,EQ PX_RPAR  ; A')' → reduce until A'(' sentinel

        BSTA,UN GET_PREC                 ; [+1]  R0 = prec(cur op)  ; 0=not an op
        COMI,R0 $00
        BCTA,EQ PX_RALL  ; end of expression → reduce all
        STRA,R0 SC1                      ; SC1 = cur op prec

PX_REDLP:
        ; while STKIDX >= 1 and top-op-prec >= SC1: reduce
        LODA,R0 STKIDX
        COMI,R0 $00
        BCTA,EQ PX_PUSHOP  ; only 1 value
        ; get top op from OPSTK[STKIDX-1]
        SUBI,R0 1
        LODI,R1 >OPSTK
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <OPSTK
        BCTA,GT PX_TOPNC
        ADDI,R0 1
PX_TOPNC:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 SC0  ; SC0 = top op byte
        COMI,R0 A'('
        BCTA,EQ PX_PUSHOP  ; sentinel → stop reducing
        BSTA,UN GET_PREC_SC0             ; [+1]  R0 = prec(SC0)
        SUBA,R0 SC1                      ; top_prec - cur_prec
        BCTA,LT PX_PUSHOP                ; top_prec < cur_prec → push new op
        BSTA,UN APPLY_OP                 ; [+1]  reduce top pair
        BCTA,UN PX_REDLP

PX_PUSHOP:
        ; push cur op byte onto OPSTK[STKIDX] and consume from IP
        LODA,R0 *IPH
        STRA,R0 SC0
        BSTA,UN INC_IP
PX_PON:
        LODA,R0 STKIDX
        LODI,R1 >OPSTK
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <OPSTK
        BCTA,GT PX_OPN
        ADDI,R0 1
PX_OPN:
        STRA,R0 TMPH
        LODA,R0 SC0
        STRA,R0 *TMPH
        BCTA,UN PX_ATOM                  ; parse next value

PX_RPAR:
        ; consume ')'
        BSTA,UN INC_IP
PX_RPNCA:
        ; reduce until '(' sentinel
PX_RPLP:
        LODA,R0 STKIDX
        COMI,R0 $00
        BCTA,EQ PX_RPDONE  ; guard
        SUBI,R0 1
        LODI,R1 >OPSTK
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <OPSTK
        BCTA,GT PX_RPNCA2
        ADDI,R0 1
PX_RPNCA2:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 SC0
        COMI,R0 A'('
        BCTA,EQ PX_POPSENT
        BSTA,UN APPLY_OP                 ; [+1]
        BCTA,UN PX_RPLP
PX_POPSENT:
        ; pop '(' sentinel: STKIDX-- (removes the op slot; val result stays at top)
        LODA,R0 STKIDX
        SUBI,R0 1
        STRA,R0 STKIDX
PX_RPDONE:
        BCTA,UN PX_PEEKOP                ; continue scanning for more operators

PX_RALL:
        ; reduce all remaining ops
PX_RALL_LP:
        LODA,R0 STKIDX
        COMI,R0 $00
        BCTA,EQ PX_DONE
        SUBI,R0 1
        LODI,R1 >OPSTK
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <OPSTK
        BCTA,GT PX_RANC
        ADDI,R0 1
PX_RANC:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 SC0
        BSTA,UN APPLY_OP                 ; [+1]
        BCTA,UN PX_RALL_LP
PX_DONE:
        ; result is VALSH[0]:VALSL[0]
        LODA,R0 VALSH
        STRA,R0 EXPH
        LODA,R0 VALSL
        STRA,R0 EXPL
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN

; ─── GET_PREC ─────────────────────────────────────────────────────────────────
; R0 = precedence of *IPH  (0=not-an-op, 1=+/-, 2=*/)
GET_PREC:
        LODA,R0 *IPH
        ; fall through to GET_PREC_SC0

; R0 = precedence of char in R0
GET_PREC_SC0:
        COMI,R0 A'+'
        BCTA,EQ GP_LOW
        COMI,R0 A'-'
        BCTA,EQ GP_LOW
        COMI,R0 A'*'
        BCTA,EQ GP_HIGH
        COMI,R0 A'/'
        BCTA,EQ GP_HIGH
        EORZ,R0 ; Clear 
        RETC,UN
GP_LOW:  
        LODI,R0 1
        RETC,UN
GP_HIGH: 
        LODI,R0 2
        RETC,UN

; ─── APPLY_OP ─────────────────────────────────────────────────────────────────
; Apply operator SC0 to top two stack values. Result → VALSH/VALSL[STKIDX-1].
; STKIDX decremented (one value consumed).
; Uses NEGFLG:SC1 as temp for left value during computation.
APPLY_OP:
        ; load right value: VALSH/VALSL[STKIDX]
        LODA,R0 STKIDX
        LODI,R1 >VALSH
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSH
        BCTA,GT AO_RHN
        ADDI,R0 1
AO_RHN:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 EXPH  ; right.hi
        LODA,R0 STKIDX
        LODI,R1 >VALSL
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSL
        BCTA,GT AO_RLN
        ADDI,R0 1
AO_RLN:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 EXPL  ; right.lo

        ; load left value: VALSH/VALSL[STKIDX-1]
        LODA,R0 STKIDX
        SUBI,R0 1
        LODI,R1 >VALSH
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSH
        BCTA,GT AO_LHN
        ADDI,R0 1
AO_LHN:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 NEGFLG  ; left.hi → NEGFLG temp
        LODA,R0 STKIDX
        SUBI,R0 1
        LODI,R1 >VALSL
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSL
        BCTA,GT AO_LLN
        ADDI,R0 1
AO_LLN:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 SC1  ; left.lo → SC1

        ; left = NEGFLG:SC1,  right = EXPH:EXPL
        ; dispatch on SC0
        LODA,R0 SC0
        COMI,R0 A'+'
        BCTA,EQ AO_ADD
        COMI,R0 A'-'
        BCTA,EQ AO_SUB
        COMI,R0 A'*'
        BCTA,EQ AO_MUL
        COMI,R0 A'/'
        BCTA,EQ AO_DIV
        RETC,UN

AO_ADD:
        ; EXPH:EXPL = NEGFLG:SC1 + EXPH:EXPL
        LODA,R0 SC1
        ADDA,R0 EXPL
        STRA,R0 EXPL
        BCTA,GT AO_ADDNC
        LODA,R0 NEGFLG
        ADDI,R0 1
        BCTA,UN AO_ADDHI
AO_ADDNC:
        LODA,R0 NEGFLG
AO_ADDHI:
        ADDA,R0 EXPH
        STRA,R0 EXPH
        BCTA,UN AO_STORE

AO_SUB:
        ; EXPH:EXPL = NEGFLG:SC1 - EXPH:EXPL
        LODA,R0 SC1
        SUBA,R0 EXPL
        STRA,R0 EXPL
        BCFA,LT AO_SUBNB                 ; no borrow → skip hi decrement
        LODA,R0 NEGFLG
        SUBI,R0 1
        BCTA,UN AO_SUBHI
AO_SUBNB:
        LODA,R0 NEGFLG
AO_SUBHI:
        SUBA,R0 EXPH
        STRA,R0 EXPH
        BCTA,UN AO_STORE

AO_MUL:
        ; MUL16: TMPH:TMPL * EXPH:EXPL → EXPH:EXPL  (NEGFLG:SC1 = left)
        LODA,R0 NEGFLG
        STRA,R0 TMPH
        LODA,R0 SC1
        STRA,R0 TMPL
        BSTA,UN MUL16                    ; [+1]
        BCTA,UN AO_STORE

AO_DIV:
        LODA,R0 NEGFLG
        STRA,R0 TMPH
        LODA,R0 SC1
        STRA,R0 TMPL
        BSTA,UN DIV16                    ; [+1]
        ; ERRFLG=$01 on /0 — DO_ERROR called inside DIV16
        BCTA,UN AO_STORE

AO_STORE:
        ; write EXPH:EXPL to VALSH/VALSL[STKIDX-1]; STKIDX--
        LODA,R0 STKIDX
        SUBI,R0 1
        LODI,R1 >VALSH
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSH
        BCTA,GT AO_SHN
        ADDI,R0 1
AO_SHN:
        STRA,R0 TMPH
        LODA,R0 EXPH
        STRA,R0 *TMPH
        LODA,R0 STKIDX
        SUBI,R0 1
        LODI,R1 >VALSL
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VALSL
        BCTA,GT AO_SLN
        ADDI,R0 1
AO_SLN:
        STRA,R0 TMPH
        LODA,R0 EXPL
        STRA,R0 *TMPH
        LODA,R0 STKIDX
        SUBI,R0 1
        STRA,R0 STKIDX
        RETC,UN

; ─── PARSE_FACTOR ─────────────────────────────────────────────────────────────
; Parse one atom: variable A-Z, signed decimal, PEEK(), CHR$(), USR().
; Called from PARSE_EXPR at depth N+1. May call PARSE_EXPR for function args
; (adds 1 more level). Unary - and + handled by PARSE_EXPR before calling here.
; CHR$ result: sets NEGFLG=$01 so DO_PRINT outputs EXPL as a character.
PARSE_FACTOR:
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG  ; clear CHR$ flag
        LODA,R0 *IPH
        BSTA,UN UPCASE  ; [+1]

        ; check for variable A-Z
        COMI,R0 A'A'
        BCTA,LT PF_NUM
        COMI,R0 A'Z'+1
        BCTA,LT PF_LOADVAR

PF_NUM:
        ; decimal number (may have leading '-' but unary is in PARSE_EXPR)
        BSTA,UN PARSE_S16                ; [+1]
        RETC,UN

PF_LOADVAR:
        ; load variable value from VARS
        ; BUG-BASIC-03 FIX: save letter to SC0 BEFORE INC_IP clobbers R0.
        STRA,R0 SC0              ; save variable letter (A-Z)
        BSTA,UN INC_IP
PF_LVNCA:
        ; BUG-BASIC-15 FIX: INC_IP returns new IPL in R0, clobbering the letter.
        ; Reload from SC0 before computing the VARS offset.
        LODA,R0 SC0
        SUBI,R0 A'A'  ; 0-25
        STRA,R0 SC1
        ADDA,R0 SC1  ; *2
        LODI,R1 >VARS
        ADDZ,R1
        STRA,R0 TMPL
        LODI,R0 <VARS
        BCTA,GT PF_LVN
        ADDI,R0 1
PF_LVN:
        STRA,R0 TMPH
        LODA,R0 *TMPH
        STRA,R0 EXPH
        BSTA,UN INC_TMP
PF_LVN2:
        LODA,R0 *TMPH
        STRA,R0 EXPL
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN


PARSE_RELOP:
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'='
        BCTA,EQ PRO_EQ
        COMI,R0 A'<'
        BCTA,EQ PRO_LT
        COMI,R0 A'>'
        BCTA,EQ PRO_GT
        LODI,R0 1               ; ISSUE-05 FIX: no relop found — set error flag
        STRA,R0 ERRFLG          ; (was RETC,UN with ERRFLG=$00 = false success)
        RETC,UN

PRO_EQ:
        BSTA,UN INC_IP
PRO_EQN:
        LODI,R0 1
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN

PRO_LT:
        BSTA,UN INC_IP
PRO_LTN:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'='
        BCTA,EQ PRO_LE
        COMI,R0 A'>'
        BCTA,EQ PRO_NE
        LODI,R0 3
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN
PRO_LE:
        BSTA,UN INC_IP
PRO_LEN:
        LODI,R0 5
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN
PRO_NE:
        BSTA,UN INC_IP
PRO_NEN:
        LODI,R0 2
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN
PRO_GT:
        BSTA,UN INC_IP
PRO_GTN:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'='
        BCTA,EQ PRO_GE
        LODI,R0 4
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN
PRO_GE:
        BSTA,UN INC_IP
PRO_GEN:
        LODI,R0 6
        STRA,R0 RELOP
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        RETC,UN

; ─── PARSE_S16 ────────────────────────────────────────────────────────────────
; Parse optional leading '-' then decimal digits → EXPH:EXPL. ERRFLG=$00 if digits.
PARSE_S16:
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'-'
        BCTA,EQ PS16_NEG
        BCTA,UN PS16_UN
PS16_NEG:
        BSTA,UN INC_IP
PS16_NN:
        LODI,R0 1               ; BUG-BASIC-05 FIX: NEGFLG=1 = "negate result"
        STRA,R0 NEGFLG          ; was EORZ,R0 which cleared flag, skipping negation
PS16_UN:
        BSTA,UN PARSE_U16                ; [+1]
        LODA,R0 ERRFLG
        COMI,R0 $00
        BCTA,EQ PS16_CHK
        RETC,UN
PS16_CHK:
        LODA,R0 NEGFLG
        COMI,R0 $00
        BCTA,EQ PS16_RET
        ; negate EXPH:EXPL
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        BSTA,UN INC_EXP
PS16_RET:
        RETC,UN

; ─── PARSE_U16 ────────────────────────────────────────────────────────────────
; Parse unsigned decimal digits → EXPH:EXPL. ERRFLG=$00 if ≥1 digit.
PARSE_U16:
        EORZ,R0 ; Clear R0
        STRA,R0 EXPH
        STRA,R0 EXPL
        LODI,R0 1               ; BUG-BASIC-06 FIX: ERRFLG=1 = "no digits yet" (failure)
        STRA,R0 ERRFLG          ; was EORZ,R0 meaning "success" before any digit seen
PU16_LP:
        BSTA,UN WSKIP                    ; [+1]
        LODA,R0 *IPH
        COMI,R0 A'0'
        ;BCTA,LT PU16_DONE
        RETC,LT
        COMI,R0 A'9'+1
        BCTA,LT PU16_DIG
        ;BCTA,UN PU16_DONE
        RETC,UN
PU16_DIG:
        SUBI,R0 A'0'
        STRA,R0 SC0  ; digit value 0-9
        BSTA,UN INC_IP
PU16_DNC:
        ; BUG-SCA-10 FIX: EXP = EXP*10.  Was LODI,R3 10 / BRNR,R3 — BRNR never
        ; decrements R3, so loop ran forever for any input with 2+ digits.
        ; BUG-SCA-11 FIX: BDRR semantics are rn--; if(rn!=0) branch. Load N for
        ; exactly N iterations. Need 10 additions so load 10: 10→9→...→1→0→exit.
        LODA,R0 EXPH
        STRA,R0 TMPH
        LODA,R0 EXPL
        STRA,R0 TMPL  ; TMPH:TMPL = old EXP
        EORZ,R0 ; Clear R0
        STRA,R0 EXPH
        STRA,R0 EXPL
        LODI,R3 10              ; 10 iterations: R3 counts 10→9→...→1→0→exit
PU16_M10:
        LODA,R0 EXPL
        ADDA,R0 TMPL
        STRA,R0 EXPL
        BCTA,GT PU16_MNC
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
PU16_MNC:
        LODA,R0 EXPH
        ADDA,R0 TMPH
        STRA,R0 EXPH
        BDRR,R3 PU16_M10       ; R3--; if R3!=0 branch
        ; EXP += digit
        LODA,R0 EXPL
        ADDA,R0 SC0
        STRA,R0 EXPL
        BCTA,GT PU16_DIG_NC
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
PU16_DIG_NC:
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG  ; success: at least one digit
        BCTA,UN PU16_LP
PU16_DONE:
        ; RETC,UN

; ─── MUL16 ────────────────────────────────────────────────────────────────────
; Signed TMPH:TMPL × EXPH:EXPL → EXPH:EXPL  (16-bit two's complement wrap)
MUL16:
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG
        ; abs(left) TMPH:TMPL
        LODA,R0 TMPH
        ANDI,R0 $80
        BCTA,EQ MU_LA
        LODA,R0 TMPH
        EORI,R0 $FF
        STRA,R0 TMPH
        LODA,R0 TMPL
        EORI,R0 $FF
        STRA,R0 TMPL
        LODA,R0 TMPL
        ADDI,R0 1
        STRA,R0 TMPL
        BCTA,GT MU_LNC
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
MU_LNC:
        LODI,R0 1               ; ISSUE-01 FIX (corrected): set NEGFLG=1 on BOTH
        STRA,R0 NEGFLG          ; carry and no-carry paths — left was negative
MU_LA:
        ; abs(right) EXPH:EXPL
        LODA,R0 EXPH
        ANDI,R0 $80
        BCTA,EQ MU_RA
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        LODA,R0 EXPL
        ADDI,R0 1
        STRA,R0 EXPL
        ; BUG-SCA-09 FIX: was BCTA,GT MU_RA — this jumped over BOTH the hi-byte
        ; increment AND the NEGFLG toggle, so for most negative right values (those
        ; whose +1 does not carry to hi byte, e.g. -3→$FFFD, abs=$0003) NEGFLG was
        ; never toggled → wrong sign (3*-3=+9 not -9). Fix: introduce MU_RA_NC so
        ; no-carry path skips only the hi-byte increment, then BOTH paths toggle.
        BCTA,GT MU_RA_NC        ; GT = no carry from lo-byte +1: skip hi increment
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
MU_RA_NC:
        LODA,R0 NEGFLG          ; toggle sign on BOTH carry and no-carry paths
        EORI,R0 $01
        STRA,R0 NEGFLG
MU_RA:
        ; save right in SC0:SC1; result EXP=0
        LODA,R0 EXPH
        STRA,R0 SC0
        LODA,R0 EXPL
        STRA,R0 SC1
        EORZ,R0 ; Clear R0
        STRA,R0 EXPH
        STRA,R0 EXPL
MU_LP:
        LODA,R0 TMPH
        COMI,R0 $00
        BCTA,GT MU_ADD
        LODA,R0 TMPL
        COMI,R0 $00
        BCTA,EQ MU_DONE
MU_ADD:
        LODA,R0 EXPL
        ADDA,R0 SC1
        STRA,R0 EXPL
        BCTA,GT MU_MNC
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
MU_MNC:
        LODA,R0 EXPH
        ADDA,R0 SC0
        STRA,R0 EXPH
        ; TMPH:TMPL-- (left counter)
        LODA,R0 TMPL
        SUBI,R0 1
        STRA,R0 TMPL
        BCFA,LT MU_TNB
        LODA,R0 TMPH
        SUBI,R0 1
        STRA,R0 TMPH
MU_TNB:
        BCTA,UN MU_LP
MU_DONE:
        LODA,R0 NEGFLG
        COMI,R0 $00
        BCTA,EQ MU_RET
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        BSTA,UN INC_EXP
MU_RET:
        EORZ,R0                          ; ISSUE-01 RE-FIX pt2: clear NEGFLG on
        STRA,R0 NEGFLG                   ; exit — dual-use with CHR$ flag in DO_PRINT
        RETC,UN

; ─── DIV16 ────────────────────────────────────────────────────────────────────
; Signed TMPH:TMPL ÷ EXPH:EXPL → EXPH:EXPL  (truncate toward zero)
; ERRFLG=$01 and DO_ERROR called on divide-by-zero.
DIV16:
        EORZ,R0 ; Clear R0
        STRA,R0 ERRFLG
        LODA,R0 EXPH
        COMI,R0 $00
        BCTA,GT DV_NZ
        LODA,R0 EXPL
        COMI,R0 $00
        BCTA,EQ DV_ZERO
DV_NZ:
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG
        ; abs(dividend) TMPH:TMPL
        LODA,R0 TMPH
        ANDI,R0 $80
        BCTA,EQ DV_DA
        LODA,R0 TMPH
        EORI,R0 $FF
        STRA,R0 TMPH
        LODA,R0 TMPL
        EORI,R0 $FF
        STRA,R0 TMPL
        LODA,R0 TMPL
        ADDI,R0 1
        STRA,R0 TMPL
        BCTA,GT DV_DNC
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
DV_DNC:
        LODI,R0 1               ; ISSUE-01 FIX (corrected): set NEGFLG=1 on BOTH
        STRA,R0 NEGFLG          ; carry and no-carry paths — dividend was negative
DV_DA:
        ; abs(divisor) EXPH:EXPL
        LODA,R0 EXPH
        ANDI,R0 $80
        BCTA,EQ DV_VA
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        LODA,R0 EXPL
        ADDI,R0 1
        STRA,R0 EXPL
        ; BUG-SCA-09b FIX: same as MUL16 right-operand fix. BCTA,GT DV_VA jumped
        ; over BOTH hi-byte increment AND NEGFLG toggle for no-carry cases.
        ; Fix: introduce DV_VA_NC so no-carry skips only the hi-byte increment.
        BCTA,GT DV_VA_NC        ; GT = no carry: skip hi increment
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
DV_VA_NC:
        LODA,R0 NEGFLG          ; toggle sign on BOTH paths
        EORI,R0 $01
        STRA,R0 NEGFLG
DV_VA:
        LODA,R0 EXPH
        STRA,R0 SC0  ; divisor hi
        LODA,R0 EXPL
        STRA,R0 SC1  ; divisor lo
        EORZ,R0 ; Clear R0
        STRA,R0 EXPH
        STRA,R0 EXPL  ; quotient = 0
DV_LP:
        ; while TMPH:TMPL >= SC0:SC1
        LODA,R0 TMPH
        SUBA,R0 SC0
        BCTA,LT DV_DONE
        BCTA,GT DV_SUB
        LODA,R0 TMPL
        SUBA,R0 SC1
        BCTA,LT DV_DONE
DV_SUB:
        LODA,R0 TMPL
        SUBA,R0 SC1
        STRA,R0 TMPL
        BCFA,LT DV_SNB
        LODA,R0 TMPH
        SUBI,R0 1
        STRA,R0 TMPH
DV_SNB:
        LODA,R0 TMPH
        SUBA,R0 SC0
        STRA,R0 TMPH
        ; quotient++
        BSTA,UN INC_EXP
        BCTA,UN DV_LP
DV_DONE:
        LODA,R0 NEGFLG
        COMI,R0 $00
        BCTA,EQ DV_RET
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        BSTA,UN INC_EXP
DV_RET:
        EORZ,R0                          ; ISSUE-01 RE-FIX pt2: clear NEGFLG on
        STRA,R0 NEGFLG                   ; exit — dual-use with CHR$ flag in DO_PRINT
        RETC,UN
DV_ZERO:
        LODI,R0 2
        BCTA,UN DO_ERROR  ; divide by zero error

; ─── PRINT_S16 ────────────────────────────────────────────────────────────────
; Print signed 16-bit value EXPH:EXPL as decimal.
; Uses DIVTAB for digit extraction. NEGFLG = leading-zero suppression flag.
PRINT_S16:
        LODA,R0 EXPH
        ANDI,R0 $80
        BCTA,EQ PS16P_POS
        LODI,R0 A'-'
        BSTA,UN COUT
        ; negate
        LODA,R0 EXPH
        EORI,R0 $FF
        STRA,R0 EXPH
        LODA,R0 EXPL
        EORI,R0 $FF
        STRA,R0 EXPL
        BSTA,UN INC_EXP
PS16P_POS:
        LODA,R0 EXPH
        COMI,R0 $00
        BCTA,GT PS16P_NZ
        LODA,R0 EXPL
        COMI,R0 $00
        BCTA,GT PS16P_NZ
        LODI,R0 A'0'
        BSTA,UN COUT
        RETC,UN

PS16P_NZ:
        LODI,R0 <DIVTAB
        STRA,R0 TMPH
        LODI,R0 >DIVTAB
        STRA,R0 TMPL
        EORZ,R0 ; Clear R0
        STRA,R0 NEGFLG  ; leading-zero flag
PS16P_DIVLP:
        ; load next divisor pair from DIVTAB
        LODA,R0 *TMPH
        STRA,R0 SC0  ; div hi
        BSTA,UN INC_TMP
PS16P_D1:
        LODA,R0 *TMPH
        STRA,R0 SC1  ; div lo
        BSTA,UN INC_TMP
PS16P_D2:
        ; sentinel 0,0 → print final ones digit
        LODA,R0 SC0
        COMI,R0 $00
        BCTA,GT PS16P_CNT
        LODA,R0 SC1
        COMI,R0 $00
        BCTA,EQ PS16P_LAST
PS16P_CNT:
        ; count subtractions using R3 (BIRR: increment and branch while nonzero)
        LODI,R3 $00
PS16P_SLP:
        LODA,R0 EXPH
        SUBA,R0 SC0
        BCTA,LT PS16P_EMIT
        BCTA,GT PS16P_DO
        LODA,R0 EXPL
        SUBA,R0 SC1
        BCTA,LT PS16P_EMIT
PS16P_DO:
        LODA,R0 EXPL
        SUBA,R0 SC1
        STRA,R0 EXPL
        BCFA,LT PS16P_SNB
        LODA,R0 EXPH
        SUBI,R0 1
        STRA,R0 EXPH
PS16P_SNB:
        LODA,R0 EXPH
        SUBA,R0 SC0
        STRA,R0 EXPH
        BIRR,R3 PS16P_SLP       ; R3++  ; loop
PS16P_EMIT:
        ; R3 = digit value
        LODA,R0 NEGFLG
        COMI,R0 $00
        BCTA,GT PS16P_FPRINT  ; already printing
        ; leading zero check: LODZ,R3 → R0 = R3
        LODZ,R3                 ; R0 = R3 (digit count, LODZ Rn loads Rn into R0)
        COMI,R0 $00
        BCTA,EQ PS16P_DIVLP  ; skip leading zero
PS16P_FPRINT:
        LODZ,R3                 ; R0 = R3 (digit value 0-9)
        ADDI,R0 A'0'            ; R0 = ASCII digit
        BSTA,UN COUT
        LODI,R0 1               ; BUG-BASIC-04 FIX: NEGFLG=1 = "digits active, print all"
        STRA,R0 NEGFLG          ; was EORZ,R0 which cleared flag, suppressing subsequent digits
        BCTA,UN PS16P_DIVLP
PS16P_LAST:
        LODA,R0 EXPL
        ADDI,R0 A'0'
        BSTA,UN COUT
        RETC,UN

; ─── GETKEY ───────────────────────────────────────────────────────────────────
; Blocking keyboard read via Pipbug CHIN.
; CHIN is blocking — waits for a keypress before returning.
;
; Later Implement Proprietary Bitbanged SENSE input when basic working
; Returns char in R0.  Clobbers R0 only.
GETKEY:
;        BSTA,UN CHIN            ; R0 = char (CHIN blocks until key pressed)
;        RETC,UN

; ─── RDLINE ───────────────────────────────────────────────────────────────────
; Read a line from input into IBUF, echo with backspace support. NUL-terminates.
; Uses GETKEY (via CHIN) for blocking input. Char received in R0 at each step;
; saved to R1 for storage/echo so R0 is free for pointer arithmetic.
RDLINE:
        LODI,R0 <IBUF
        STRA,R0 IPH
        LODI,R0 >IBUF
        STRA,R0 IPL
RL_LP:
        BSTA,UN CHIN          ; [+1] blocking — R0 = char
        COMI,R0 NUL             ; BUG-ASM-08 FIX: NUL = EOF from sim stdin.
        BCTA,EQ RL_EOL          ;   Treat as end-of-line so we don't flood IBUF
        ;                       ;   (and overwrite VARS) after stdin is exhausted.
        STRZ,R1                 ; R1 = char (R0 still has char for CR/BS checks)
        COMI,R1 CR
        BCTA,EQ RL_EOL
        COMI,R1 LF
        BCTA,EQ RL_EOL
        ; ISSUE-06 FIX: removed redundant second COMI,R1 NUL / BCTA,EQ RL_EOL here.
        ; BUG-ASM-08 fix (first NUL check immediately after GETKEY above) already
        ; catches EOF before we reach this point — second check was dead code.
        COMI,R1 BS
        BCTA,EQ RL_BS
        ; buffer full?  IP >= IBUF+63
        ; BUG-BASIC-17 FIX: was SUBA (absolute read) not SUBI (immediate compare).
        ; SUBA,R0 <IBUF reads mem[$0015] (PIPBUG ROM), not the constant $15.
        ; All four pointer comparisons here must use SUBI.
        LODA,R0 IPH
        SUBI,R0 <IBUF           ; compare IPH against IBUF hi byte ($15)
        BCTA,GT RL_FULL
        BCTA,LT RL_STORE
        LODA,R0 IPL
        SUBI,R0 >IBUF+63        ; compare IPL against IBUF lo byte + 63 ($83)
        BCTA,LT RL_STORE
RL_FULL:
        BCTA,UN RL_LP
RL_STORE:
        STRA,R1 *IPH            ; store char to buffer
        LODZ,R1
        BSTA,UN COUT            ; echo char
        BSTA,UN INC_IP
        BCTA,UN RL_LP
RL_BS:
        ; at IBUF start? — no backspace if buffer empty
        LODA,R0 IPH
        SUBI,R0 <IBUF           ; compare IPH against IBUF hi byte ($15)
        BCTA,GT RL_BSDO
        BCTA,LT RL_LP
        LODA,R0 IPL
        SUBI,R0 >IBUF           ; compare IPL against IBUF lo byte ($44)
        BCTA,EQ RL_LP
RL_BSDO:
        LODA,R0 IPL
        SUBI,R0 1
        STRA,R0 IPL
        BCFA,LT RL_BSNB
        LODA,R0 IPH
        SUBI,R0 1
        STRA,R0 IPH
RL_BSNB:
        LODI,R0 BS
        BSTA,UN COUT
        LODI,R0 SP
        BSTA,UN COUT
        LODI,R0 BS
        BSTA,UN COUT
        BCTA,UN RL_LP
RL_EOL:
        LODI,R1 NUL
        STRA,R1 *IPH            ; NUL-terminate buffer
        BSTA,UN CRLF
        RETC,UN

; ─── PRTSTR / PRTSTR_IP ───────────────────────────────────────────────────────
; Print NUL-terminated string at IPH:IPL.
; PRTSTR_IP is the same routine, just an alias for clarity at the call site.
PRTSTR_IP:
PRTSTR:
        LODA,R1 *IPH
        COMI,R1 NUL
        ;BCTA,EQ PRTSTR_RET
        RETC,EQ
        LODZ,R1
        BSTA,UN COUT
        BSTA,UN INC_IP
        BCTR,UN PRTSTR
PRTSTR_RET:
       ; RETC,UN

; ─── WSKIP ────────────────────────────────────────────────────────────────────
WSKIP:
        LODA,R0 *IPH
        COMI,R0 SP
        BCTR,EQ WS_ADV
        RETC,UN
WS_ADV:
        BSTA,UN INC_IP
        BCTA,UN WSKIP

; ─── GETCI_UC ─────────────────────────────────────────────────────────────────
; Read *IPH uppercase into R0, advance IP.
; BUG-ASM-04 FIX: INC_IP clobbers R0 (returns new IPL). Save char in R1
; across the INC_IP call using STRZ,R1 / LODZ,R1 sandwich.
; Clobbers: R1 (caller must not rely on R1 across GETCI_UC call)
GETCI_UC:
        LODA,R0 *IPH
        BSTR,UN UPCASE                   ; [+1] R0 = uppercased char
        STRZ,R1                          ; R1 = char (save before INC_IP clobbers R0)
        BSTA,UN INC_IP                   ; [+1] advance IP (clobbers R0)
        LODZ,R1                          ; R0 = char (restore)
GETCI_UC_RET:
        RETC,UN

; ─── UPCASE ───────────────────────────────────────────────────────────────────
UPCASE:
        COMI,R0 A'a'
        ; BCTA,LT UC_RET
        RETC,LT
        COMI,R0 A'z'+1
        BCTR,LT UC_DO
        ;BCTR,UN UC_RET
        RETC,UN
UC_DO:
        SUBI,R0 32
UC_RET:
        RETC,UN

; ─── EATWORD ──────────────────────────────────────────────────────────────────
; Skip [A-Za-z$] at IP.
EATWORD:
        LODA,R0 *IPH
        BSTR,UN UPCASE  ; [+1]
        COMI,R0 A'A'
        BCTR,LT EW_DS
        COMI,R0 A'Z'+1
        BCTR,LT EW_ADV
EW_DS:
        COMI,R0 A'$'
        BCTR,EQ EW_ADV
        RETC,UN
EW_ADV:
        BSTA,UN INC_IP
        BCTR,UN EATWORD

; ─── SHARED 16-BIT POINTER INCREMENT/DECREMENT SUBROUTINES ───────────────────
; INC_IP  : IPH:IPL  += 1   (clobbers R0)
; INC_TMP : TMPH:TMPL += 1  (clobbers R0)
; INC_EXP : EXPH:EXPL += 1  (clobbers R0)
; DEC_TMP : TMPH:TMPL -= 1  (clobbers R0)
; Rule: NO BSTA inside these — must not consume extra RAS depth.
; Carry idiom: ADDI sets no-carry->GT, carry->EQ/LT.
;   BCTA,GT skip  =  skip hi-byte increment if no carry from lo-byte add.
; Borrow idiom: SUBI sets no-borrow->GT/EQ, borrow->LT.
;   BCFA,LT skip  =  skip hi-byte decrement if no borrow (C=1).

INC_IP:
        LODA,R0 IPL
        ADDI,R0 1
        STRA,R0 IPL
        ;BCTA,GT INC_IP_RET      ; no carry — hi byte unchanged
        RETC,GT
        LODA,R0 IPH
        ADDI,R0 1
        STRA,R0 IPH
INC_IP_RET:
        RETC,UN

INC_TMP:
        LODA,R0 TMPL
        ADDI,R0 1
        STRA,R0 TMPL
        ;BCTA,GT INC_TMP_RET     ; no carry
        RETC,GT
        LODA,R0 TMPH
        ADDI,R0 1
        STRA,R0 TMPH
INC_TMP_RET:
        RETC,UN

INC_EXP:
        LODA,R0 EXPL
        ADDI,R0 1
        STRA,R0 EXPL
        ;BCTA,GT INC_EXP_RET     ; no carry
        RETC,GT
        LODA,R0 EXPH
        ADDI,R0 1
        STRA,R0 EXPH
INC_EXP_RET:
        RETC,UN

DEC_TMP:
        LODA,R0 TMPL
        SUBI,R0 1
        STRA,R0 TMPL
        BCFR,LT DEC_TMP_RET     ; no borrow (C=1) — hi byte unchanged
        LODA,R0 TMPH
        SUBI,R0 1
        STRA,R0 TMPH
DEC_TMP_RET:
        RETC,UN


; ─── DO_ERROR ─────────────────────────────────────────────────────────────────
; Entry: R0 = error code (0-5).
; Saves RUNFLG, clears all run state, prints "?n [IN line]", jumps to REPL.
; This is a tail-jump (BCTA,UN DO_ERROR from callers), so it kills the full RAS.
DO_ERROR:
        STRA,R0 SC0                      ; save error code
        LODA,R0 RUNFLG
        STRA,R0 SC1  ; save run state
        EORZ,R0 ; Clear R0
        STRA,R0 RUNFLG  ; clear run
        LODI,R0 $FF
        STRA,R0 SWSP  ; clear GOSUB stack
        LODI,R0 A'?'
        BSTA,UN COUT
        LODA,R0 SC0
        ADDI,R0 A'0'
        BSTA,UN COUT
        LODA,R0 SC1
        COMI,R0 $01
        BCTR,EQ DE_IN
        BCTR,UN DE_NL
DE_IN:
        LODI,R0 SP
        BSTA,UN COUT
        LODI,R0 A'I'
        BSTA,UN COUT
        LODI,R0 A'N'
        BSTA,UN COUT
        LODI,R0 SP
        BSTA,UN COUT
        LODA,R0 CURH
        STRA,R0 EXPH
        LODA,R0 CURL
        STRA,R0 EXPL
        BSTA,UN PRINT_S16                ; [+1]
DE_NL:
        BSTA,UN CRLF
        BCTA,UN REPL                     ; jump to REPL — clears full hardware RAS
ROMEND: ; so we can measure Binary rom size
        END
