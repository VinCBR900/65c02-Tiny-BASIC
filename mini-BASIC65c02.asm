; miniBASIC 65C02 v1.1 -- 4KB Float BASIC (MBF4) for the 65C02
; ORG $F000 (2732 EPROM).  RAM $0000-$0FFF.
; Derived from uBASIC v18.1 (integer 65C02) + miniBASIC 8088 v2.0 (float).
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
; ZP:  $00/$01=IP  $02/$03=PE  $04/$05=LP
;      $06/$07=T0  $08/$09=T1  $0A/$0B=T2
;      $0C/$0D=CURLN  $0E=RUN  $10-$2F=IBUF(32)
;      $30-$33=FLT_A  $34-$37=FLT_B  $38-$3B=free
;      $3C=FLT_SA  $3D=FLT_SB  $3E=FLT_ER  $3F=FLT_DE  $40=FLT_DB
;      $43=RUNSP  $44-$A7=VARS(A-Z,4 bytes each)
;
; TRUE=-1.0  FALSE=0.0
; Errors: ?0=syntax ?1=undef_line ?2=div0 ?3=out_of_mem ?4=bad_var

         .opt proc65c02

IO_OUT   = $E001
IO_IN    = $E004
RAM_TOP  = $1000
IP       = $00
PE       = $02
LP       = $04
T0       = $06
T1       = $08
T2       = $0A
CURLN    = $0C
RUN      = $0E
IBUF     = $10
FLT_A    = $30
FLT_B    = $34
FLT_SA   = $3C
FLT_SB   = $3D
FLT_ER   = $3E
FLT_DE   = $3F
FLT_DB   = $40
RUNSP    = $43
VARS     = $44
VARS_MAX = $67   ; 103; STZ VARS,X for X=103..0 clears $44-$A7 (104 bytes)
FLT_MA   = $AC           ; MUL multiplicand scratch (hi)
FLT_MB   = $AD           ; MUL multiplicand scratch (mid)
FLT_MC   = $AE           ; MUL multiplicand scratch (lo)
FLT_DVH  = $AF           ; DIV divisor scratch (hi)
FLT_DVM  = $B0           ; DIV divisor scratch (mid)
FLT_DVL  = $B1           ; DIV divisor scratch (lo)
FP_IX    = $41           ; FLT_PRINT digit-loop saved digit (=FLT_DB+1)
FP_XSV   = $42           ; FLT_PRINT digit-loop saved X index (=FLT_DB+2)
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

         .ORG $F000
ROMSTART: BRA INIT   ; Kowalski trampoline

; ---- STRING/KEYWORD TABLE (page $F0) ----------------------------------------
STR_PAGE = >STR_BANNER
STR_BANNER: .DB "miniBASIC 65C02"
STR_CRLF:   .DB $0D,$8A
STR_IN:     .DB " IN",$A0
STR_BREAK:  .DB $0D,$0A,"BREA",$CB
KW_TAB:
KW_PRINT:  .DB "PRIN",$D4
KW_IF:     .DB "I",$C6
KW_GOTO:   .DB "GOT",$CF
KW_LIST:   .DB "LIS",$D4
KW_RUN:    .DB "RU",$CE
KW_NEW:    .DB "NE",$D7
KW_INPUT:  .DB "INPU",$D4
KW_REM:    .DB "RE",$CD
KW_END:    .DB "EN",$C4
KW_LET:    .DB "LE",$D4
KW_THEN:   .DB "THE",$CE
KW_CHRS:   .DB "CHR",$A4
KW_POKE:   .DB "POK",$C5
KW_FREE:   .DB "FRE",$C5
KW_PEEK:   .DB "PEE",$CB
KW_USR:    .DB "US",$D2
KW_HELP:   .DB "HEL",$D0
KW_TEND:   .DB 0

; ---- INIT -------------------------------------------------------------------
INIT:    LDX #$FF
         TXS
         CLD
         CLI
INIZ:    STZ 0,X
         DEX
         BPL INIZ
         LDA #<SHOWCASE_END
         STA PE
         LDA #>SHOWCASE_END
         STA PE+1
         LDA #<STR_BANNER
         JSR PUTSTR
         JSR DO_FREE

; ---- MAIN prompt loop -------------------------------------------------------
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
MAIND:   JSR STMT_LINE
         BRA MAIN

; ---- DO_ERROR ---------------------------------------------------------------
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

; ---- IRQ --------------------------------------------------------------------
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

; ---- GETLINE ----------------------------------------------------------------
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

; ---- PNUM: parse decimal int -> T0  (for line numbers) ----------------------
PNUM:    JSR WSKIP
         STZ T0
         STZ T0+1
PNL:     LDA (IP)
         SEC
         SBC #'0'
         BCC PND
         CMP #10
         BCS PND
         PHA
         INC IP
         BNE PNS
         INC IP+1
PNS:     ASL T0
         ROL T0+1
         LDA T0
         STA T2
         LDX T0+1
         ASL T0
         ROL T0+1
         ASL T0
         ROL T0+1
         PLA
         CLC
         ADC T0
         ADC T2
         STA T0
         TXA
         ADC T0+1
         STA T0+1
         BRA PNL
PND:     RTS

; ---- T2DEC ------------------------------------------------------------------
T2DEC:   LDA T2
         BNE T2DL
         DEC T2+1
T2DL:    DEC T2
         LDA T2
         ORA T2+1
         RTS

; ---- DELINE -----------------------------------------------------------------
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

; ---- EDITLN -----------------------------------------------------------------
EDITLN:  JSR PNUM
         LDA T0
         STA CURLN
         LDA T0+1
         STA CURLN+1
         LDA #<PROG
         STA LP
         LDA #>PROG
         STA LP+1
ELFL:    LDA LP
         CMP PE
         BNE ELGO
         LDA LP+1
         CMP PE+1
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
ELSK:    LDY #2
ELSL:    LDA (LP),Y
         INY
         CMP #CR
         BNE ELSL
         TYA
         CLC
         ADC LP
         STA LP
         BCC ELFL
         INC LP+1
         BRA ELFL
ELFD:    JSR DELINE
ELIS:    JSR WPEEK
         CMP #CR
         BNE ELIS2
         JMP ELD         ; no body: done
ELIS2:
INSLINE: LDY #0
ISC:     LDA (IP),Y
         CMP #CR
         BEQ ISE
         INY
         BRA ISC
ISE:     INY
         TYA
         CLC
         ADC #2
         TAX
         PHX
         SEC
         ADC PE
         STA T2
         LDA PE+1
         ADC #0
         STA T2+1
         LDA T2+1
         CMP #>RAM_TOP
         BCC ISOK
         PLX
         LDA #ERR_OM
         JMP DO_ERROR
ISOK:    LDA PE
         SEC
         SBC LP
         STA T2
         LDA PE+1
         SBC LP+1
         STA T2+1
         LDA T2
         ORA T2+1
         BEQ ISSH
         LDA PE
         SEC
         SBC #1
         STA T0
         LDA PE+1
         SBC #0
         STA T0+1
         TXA
         CLC
         ADC T0
         STA T1
         LDA T0+1
         ADC #0
         STA T1+1
ISBK:    LDY #0
         LDA (T0),Y
         STA (T1),Y
         LDA T0
         BNE ISD0
         DEC T0+1
ISD0:    DEC T0
         LDA T1
         BNE ISD1
         DEC T1+1
ISD1:    DEC T1
         JSR T2DEC
         BNE ISBK
ISSH:    PLX
         TXA
         CLC
         ADC PE
         STA PE
         BCC ISHD
         INC PE+1
ISHD:    LDY #0
         LDA CURLN
         STA (LP),Y
         INY
         LDA CURLN+1
         STA (LP),Y
         LDA LP
         CLC
         ADC #2
         STA T0
         LDA LP+1
         ADC #0
         STA T0+1
         DEY
ISCP:    LDA (IP),Y
         STA (T0),Y
         CMP #CR
         BEQ ELD
         INY
         BRA ISCP
ELD:     RTS

; ---- PRNL / PUTSTR / PUTSTRZP -----------------------------------------------
PRNL:    LDA #<STR_CRLF
PUTSTR:  STA T2
PUTSTRZP:
         LDA #STR_PAGE
         STA T2+1
         LDY #0
PSL:     LDA (T2),Y
         BMI PSE
         JSR PUTCH
         INC T2
         BRA PSL
PSE:     AND #$7F
         JMP PUTCH

; ---- DO_FREE ----------------------------------------------------------------
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
         LDA #<KW_FREE
         JSR PUTSTR
         JMP PRNL

; ---- DO_HELP ----------------------------------------------------------------
DO_HELP: LDA #<KW_TAB
         STA T2
DHL:     JSR PUTSTRZP
         INC T2
         LDA (T2),Y
         BEQ DHDN
         LDA #' '
         JSR PUTCH
         BRA DHL
DHDN:    JMP PRNL

; ---- DO_PRINT ---------------------------------------------------------------
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
         BRA DPT
DPNL:    JSR PRNL
         RTS

; ---- DO_LIST ----------------------------------------------------------------
DO_LIST: LDA #<PROG
         STA LP
         LDA #>PROG
         STA LP+1
LSL:     LDA LP
         CMP PE
         BNE LSGO
         LDA LP+1
         CMP PE+1
         BEQ LSDN
LSGO:    LDA (LP)
         STA T0
         LDY #1
         LDA (LP),Y
         STA T0+1
         JSR PRT16
         LDA #' '
         JSR PUTCH
         LDA LP
         CLC
         ADC #2
         STA LP
         BCC LSB
         INC LP+1
LSB:     LDA (LP)
         CMP #CR
         BEQ LSEOL
         JSR PUTCH
         INC LP
         BNE LSB
         INC LP+1
         BRA LSB
LSEOL:   JSR PRNL
         INC LP
         BNE LSL
         INC LP+1
         BRA LSL
LSDN:    RTS

; ---- DO_GOTO ----------------------------------------------------------------
DO_GOTO: JSR EXPR
         JSR FLT_TO_INT
         JSR GOTOL
         BCC DGOK
         LDA #ERR_UL
         JMP DO_ERROR
DGOK:    LDA RUN               ; only valid to collapse the stack via RUNSP
         BEQ RUNGO             ; while already inside an active RUN loop;
         LDX RUNSP             ; RUNSP is stale/uninitialized for an
         TXS                   ; immediate-mode GOTO (stack is already at
RUNGO:   JSR STMT_LINE         ; the correct depth in that case)
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
DO_RUN:  LDA #<PROG
         STA IP
         LDA #>PROG
         STA IP+1
         LDA #$FF
         STA RUN
         BRA RUNLP
RUNEND:
DO_END:  STZ RUN
         RTS

; ---- DO_NEW -----------------------------------------------------------------
DO_NEW:  LDA #<PROG
         STA PE
         LDA #>PROG
         STA PE+1
         LDX #VARS_MAX
DNL:     STZ VARS,X
         DEX
         BPL DNL
         RTS

; ---- DO_POKE ----------------------------------------------------------------
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
         LDY #0
         STA (T1),Y
         RTS

; ---- DO_INPUT ---------------------------------------------------------------
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
         PLA
         TAX
         LDY #0
DILP:    LDA FLT_A,Y
         STA VARS,X
         INX
         INY
         CPY #4
         BNE DILP
DIDN:
ST_NOP:  RTS

; ---- GOTOL ------------------------------------------------------------------
GOTOL:   LDA #<PROG
         STA IP
         LDA #>PROG
         STA IP+1
GTSC:    LDA IP
         CMP PE
         BNE GTGO
         LDA IP+1
         CMP PE+1
         BEQ GTERR
GTGO:    LDA (IP)
         CMP T0
         BNE GTNX
         LDY #1
         LDA (IP),Y
         CMP T0+1
         BEQ GTOK
GTNX:    LDY #2
GTSL:    LDA (IP),Y
         INY
         CMP #CR
         BNE GTSL
         TYA
         CLC
         ADC IP
         STA IP
         BCC GTSC
         INC IP+1
         BRA GTSC
GTOK:    LDA IP
         CLC
         ADC #2
         STA IP
         BCC GTCLC
         INC IP+1
GTCLC:   CLC
         RTS
GTERR:   SEC
         RTS

; ---- EAT_EXPR / EXPR --------------------------------------------------------
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
         LDA FLT_A+3          ; park left operand on hardware stack
         PHA                  ; (FLT_C unsafe: EXPR_ADD below may recurse
         LDA FLT_A+2          ;  via parens back into this relational level)
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         JSR EXPR_ADD          ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         PLA                   ; restore left operand into FLT_A
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
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

; ---- EXPR_ADD ---------------------------------------------------------------
EXPR_ADD:
         JSR EXPR1
EAL:     JSR WPEEK
         CMP #'+'
         BEQ EADO
         CMP #'-'
         BNE EARS
EADO:    PHA                  ; save operator
         LDA FLT_A+3          ; park left operand on hardware stack
         PHA                  ; (FLT_C unsafe: EXPR1 below also uses it,
         LDA FLT_A+2          ;  and can be reached via nested parens)
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         JSR GETCI
         JSR EXPR1             ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         PLA                   ; restore left operand into FLT_A
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
         PLA                   ; pull operator
         CMP #'-'
         BEQ EASB
         JSR FLT_ADD
         BRA EAL
EASB:    JSR FLT_SUB
         BRA EAL
EARS:    RTS

; ---- EXPR1 ------------------------------------------------------------------
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
         LDA FLT_A+3          ; park left operand on hardware stack
         PHA                  ; (FLT_C unsafe: EXPR2 below may recurse via
         LDA FLT_A+2          ;  parens back into EXPR_ADD/EXPR1)
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         JSR GETCI
         JSR EXPR2             ; right -> FLT_A
         JSR FLT_A_TO_B        ; FLT_B = right
         PLA                   ; restore left operand into FLT_A
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
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

; ---- EXPR2 ------------------------------------------------------------------
E2PS:    JSR GETCI
EXPR2:   JSR WPEEK
         CMP #'('
         BNE E2NP2
         JMP E2PR        ; parenthesised expression
E2NP2:
         CMP #'-'
         BEQ E2NG
         CMP #'+'
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
         LDY #0
         LDA (T0),Y
         STA T0
         STZ T0+1
         JMP FLT_FROM_INT
E2NP:    LDA #<KW_USR
         JSR MTCHKW
         BCS E2NU
         JSR EAT_EXPR
         JSR WEAT
         JSR FLT_TO_INT
         LDA T0
         STA T2
         LDA T0+1
         STA T2+1
         JMP USR_CALL
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

; ---- WEAT / GETCI / WSKIP / WPEEK / UC / PRT16 / PUTCH / GETCH / NEG16 ----
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

USR_CALL: JMP (T2)
USR_RET: STA T0
         STZ T0+1
         JMP FLT_FROM_INT

; ---- DO_IF / STMT_LINE / STMT / DO_LET -------------------------------------
DO_IF:   JSR EXPR
         LDA FLT_A
         BEQ DIFDN
         LDA #<KW_THEN
         JSR MTCHKW
STMT_LINE:
         JSR STMT
SLCK:    JSR WPEEK
         CMP #':'
         BNE SLRT
         JSR GETCI
         BRA STMT_LINE
DIFDN:
SLRT:    RTS

STMT:    JSR WPEEK
         CMP #' '
         BCC SLRT
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
STLT:
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
         PLA
         TAX
         LDY #0
DLLP:    LDA FLT_A,Y
         STA VARS,X
         INX
         INY
         CPY #4
         BNE DLLP
         RTS
DLPOP:   PLA
         LDA #ERR_UK
         JMP DO_ERROR
DLD:     RTS

ST_TAB:
         .DB <KW_PRINT,<DO_PRINT,>DO_PRINT
         .DB <KW_IF,   <DO_IF,   >DO_IF
         .DB <KW_GOTO, <DO_GOTO, >DO_GOTO
         .DB <KW_LIST, <DO_LIST, >DO_LIST
         .DB <KW_RUN,  <DO_RUN,  >DO_RUN
         .DB <KW_NEW,  <DO_NEW,  >DO_NEW
         .DB <KW_INPUT,<DO_INPUT,>DO_INPUT
         .DB <KW_REM,  <ST_NOP,  >ST_NOP
         .DB <KW_END,  <DO_END,  >DO_END
         .DB <KW_LET,  <DO_LET,  >DO_LET
         .DB <KW_POKE, <DO_POKE, >DO_POKE
         .DB <KW_FREE, <DO_FREE, >DO_FREE
         .DB <KW_HELP, <DO_HELP, >DO_HELP
         .DB $FF

; ---- MTCHKW -----------------------------------------------------------------
MTCHKW:  STA T1
         LDA #STR_PAGE
         STA T1+1
         LDA IP
         STA LP
         LDA IP+1
         STA LP+1
         JSR WSKIP
MKL:     LDA (T1)
         BMI MKLST
         LDY #0
         BRA MKC
MKLST:   AND #$7F
         LDY #1
MKC:     PHA
         LDA (IP)
         JSR UC
         STA T1+1
         PLA
         CMP T1+1
         BNE MKFL
         LDA #STR_PAGE
         STA T1+1
         JSR GETCI
         CPY #1
         BEQ MKOK
         INC T1
         BRA MKL
MKOK:    CLC
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

FLT_ZERO:
         LDX #3
FZL:     STZ FLT_A,X
         DEX
         BPL FZL
         RTS

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

FLT_ABS: LDA FLT_A+1
         AND #$7F
         STA FLT_A+1
         RTS

SIGN_XOR:
         LDA FLT_A+1
         EOR FLT_B+1
         AND #$80
         STA FLT_SA
         RTS

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

; FLT_FROM_INT: T0 (s16) -> FLT_A
FLT_FROM_INT:
         LDA T0
         ORA T0+1
         BEQ FIIZ
         STZ FLT_SA
         LDA T0+1
         BPL FIP
         LDA #$80
         STA FLT_SA
         LDA #0
         SEC
         SBC T0
         STA T0
         LDA #0
         SBC T0+1
         STA T0+1
FIP:     LDA #$90
         STA FLT_ER
FIN:     LDA T0+1
         BMI FIPK
         ASL T0
         ROL T0+1
         DEC FLT_ER
         BNE FIN
FIIZ:    JMP FLT_ZERO
FIPK:    LDA FLT_ER
         STA FLT_A
         LDA T0+1
         AND #$7F
         ORA FLT_SA
         STA FLT_A+1
         LDA T0
         STA FLT_A+2
         STZ FLT_A+3
         RTS

; FLT_FROM_INT_B: T0 (s16) -> FLT_B
FLT_FROM_INT_B:
         LDA T0
         ORA T0+1
         BEQ FIBZ
         STZ FLT_SB
         LDA T0+1
         BPL FIBP
         LDA #$80
         STA FLT_SB
         LDA #0
         SEC
         SBC T0
         STA T0
         LDA #0
         SBC T0+1
         STA T0+1
FIBP:    LDA #$90
         STA FLT_ER
FIBN:    LDA T0+1
         BMI FIBPK
         ASL T0
         ROL T0+1
         DEC FLT_ER
         BNE FIBN
FIBZ:    STZ FLT_B
         STZ FLT_B+1
         STZ FLT_B+2
         STZ FLT_B+3
         RTS
FIBPK:   LDA FLT_ER
         STA FLT_B
         LDA T0+1
         AND #$7F
         ORA FLT_SB
         STA FLT_B+1
         LDA T0
         STA FLT_B+2
         STZ FLT_B+3
         RTS

; FLT_TO_INT: FLT_A -> T0 (s16, truncate). Uses FLT_DE as scratch.
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

FLT_TEN_B:
         LDA #$84
         STA FLT_B
         LDA #$20
         STA FLT_B+1
         STZ FLT_B+2
         STZ FLT_B+3
         RTS

MUL_BY_TEN:
         JSR FLT_TEN_B
         JMP FLT_MUL

DIV_BY_TEN:
         JSR FLT_TEN_B
         JMP FLT_DIV

; NORM_PACK: normalise mantissa (FLT_A+1:+2:+3), guard (FLT_DB),
;            exp (FLT_ER), sign (FLT_SA) -> FLT_A packed
NORM_PACK:
NPL:     LDA FLT_A+1
         BMI NPRND
         BNE NPBT
         LDA FLT_ER
         SEC
         SBC #8
         BCC NPZE
         BEQ NPZE
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
NPRND:   CLC
         LDA FLT_DB
         ADC #$80
         BCC NPPK
         INC FLT_A+3
         BNE NPPK
         INC FLT_A+2
         BNE NPPK
         INC FLT_A+1
         BNE NPPK
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

; FLT_ADD: FLT_A = FLT_A + FLT_B
FLT_ADD: LDA FLT_A
         BNE FACKB
         JMP FLT_B_TO_A
FACKB:   LDA FLT_B
         BNE FABTH
         RTS
FABTH:   LDA FLT_A
         CMP FLT_B
         BCS FASG
         LDX FLT_A+3
         LDA FLT_B+3
         STA FLT_A+3
         STX FLT_B+3
         LDX FLT_A+2
         LDA FLT_B+2
         STA FLT_A+2
         STX FLT_B+2
         LDX FLT_A+1
         LDA FLT_B+1
         STA FLT_A+1
         STX FLT_B+1
         LDX FLT_A
         LDA FLT_B
         STA FLT_A
         STX FLT_B
FASG:    LDA FLT_A+1
         AND #$80
         STA FLT_SA
         LDA FLT_B+1
         AND #$80
         STA FLT_SB
         LDA FLT_A+1
         ORA #$80
         STA FLT_A+1
         LDA FLT_B+1
         ORA #$80
         STA FLT_B+1
         LDA FLT_A
         STA FLT_ER
         SEC
         SBC FLT_B
         CMP #25
         BCC FA_NALIGN
         JMP FAGON        ; shift >= 25: smaller operand vanishes
FA_NALIGN:
         TAX                  ; X = shift count (was missing -- caused silent corruption)
         STZ FLT_DB
FAAL:    CPX #0
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
FAGON:   STZ FLT_DB
         JMP NORM_PACK

FLT_SUB: JSR FLT_NEGATE_B
         JSR FLT_ADD
         JMP FLT_NEGATE_B

; FLT_CMP: A=$FF(A<B) $00(A=B) $01(A>B). FLT_A preserved; uses T1.
FLT_CMP: LDA FLT_A+3
         PHA
         LDA FLT_A+2
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         JSR FLT_SUB
         LDA FLT_A
         STA T1
         LDA FLT_A+1
         STA T1+1
         PLA
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
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
         LDA FLT_A+1
         ORA #$80
         STA FLT_A+1
         LDA FLT_B+1
         ORA #$80
         STA FLT_B+1
         LDA FLT_A+1
         STA FLT_MA    ; MUL multiplicand hi (free ZP, away from FLT_C)
         LDA FLT_A+2
         STA FLT_MB    ; MUL multiplicand mid
         LDA FLT_A+3
         STA FLT_MC    ; MUL multiplicand lo
         STZ FLT_A+1
         STZ FLT_A+2
         STZ FLT_A+3
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
         LDA FLT_B+1
         ORA #$80
         STA FLT_B+1
         LDA FLT_B+1
         STA FLT_DVH   ; DIV divisor hi
         LDA FLT_B+2
         STA FLT_DVM   ; DIV divisor mid
         LDA FLT_B+3
         STA FLT_DVL   ; DIV divisor lo
         LDA FLT_A+1
         ORA #$80
         STA T0
         LDA FLT_A+2
         STA T0+1
         LDA FLT_A+3
         STA T1
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
FLT_MOD: LDA FLT_A+3
         PHA
         LDA FLT_A+2
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
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
         PLA
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
         JMP FLT_SUB

; FLT_PRINT: print FLT_A as decimal  (6 significant digits)
; Algorithm: handle zero/sign, scale to [1,10), extract 7 digits,
; round, strip trailing zeros, print with decimal point.
; FLT_DE used for decimal exponent; saved in T2 during digit extraction
; (FLT_DE is clobbered by FLT_TO_INT).
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
FPPS:    LDA FLT_A+3
         PHA
         LDA FLT_A+2
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         STZ FLT_DE
FPDN:    JSR FLT_TEN_B
         JSR FLT_CMP
         CMP #$FF
         BEQ FPUP
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
FPDIG:   STX FP_XSV           ; save digit index
         JSR FLT_TO_INT       ; T0 = int(FLT_A)  [0-9]
         LDA T0               ; save digit value NOW before T0 clobbered
         STA FP_IX            ; save digit
         STZ T0+1             ; T0=digit(lo), T0+1=0
         JSR FLT_FROM_INT_B   ; FLT_B = float(digit)  [clobbers FLT_ER, FLT_SB]
         JSR FLT_SUB          ; FLT_A = FLT_A - digit  [clobbers T0,T1,T2,FLT_SA/SB/ER/DB]
         LDA FLT_A
         BEQ FPCL
         LDA FLT_A+1
         BPL FPCL
         JSR FLT_ZERO         ; clamp negative rounding artefact
FPCL:    JSR MUL_BY_TEN       ; FLT_A = fraction * 10  [clobbers T0,T1,T2,X,...]
         LDA FP_IX             ; restore saved digit
         LDX FP_XSV            ; restore digit index
         CLC
         ADC #'0'
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
         TXA
         CMP FLT_DE
         BCC FPSTD
         BEQ FPSTD
         DEX
         BPL FPST
FPSTD:   LDA FLT_DE
         BMI FPLT1
         INC
         STA T2+1             ; T2+1 = integer digit count (de+1)
         LDY #0
FPIT:    CPY #6
         BCS FPPAD            ; ran out of buffered digits: pad with '0'
         LDA IBUF,Y
         JSR PUTCH
         INY
         DEC T2+1
         BNE FPIT
         BRA FPFR
FPPAD:   LDA T2+1             ; still have integer digits left to print
         BEQ FPFR
         LDA #'0'
         JSR PUTCH
         DEC T2+1
         BNE FPPAD
FPFR:    CPY #6
         BCS FPEND
         LDA IBUF,Y
         CMP #'0'
         BEQ FPEND
         LDA #'.'
         JSR PUTCH
FPFRL:   LDA IBUF,Y
         CMP #'0'
         BEQ FPEND
         JSR PUTCH
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
FPLT1L:  LDA IBUF,Y
         CMP #'0'
         BEQ FPEND
         JSR PUTCH
         INY
         CPY #6
         BCC FPLT1L
FPEND:   PLA
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
         RTS

; FLT_PARSE: parse decimal float at IP -> FLT_A
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
         TAX
         JSR GETCI
         JSR MUL_BY_TEN
         STX T0
         STZ T0+1
         JSR FLT_FROM_INT_B
         JSR FLT_ADD
         BRA FPAI
FPDT:    CMP #'.'
         BNE FPSG
         JSR GETCI
         LDA FLT_A+3
         PHA
         LDA FLT_A+2
         PHA
         LDA FLT_A+1
         PHA
         LDA FLT_A
         PHA
         JSR PARSE_FRAC
         JSR FLT_A_TO_B
         PLA
         STA FLT_A
         PLA
         STA FLT_A+1
         PLA
         STA FLT_A+2
         PLA
         STA FLT_A+3
         JSR FLT_ADD
FPSG:    LDA FLT_DE
         BEQ FPSND
         JMP FLT_NEGATE
FPSND:   RTS

; PARSE_FRAC: recursive fractional digits -> FLT_A in [0,1)
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
; SHOWCASE (RAM $0200, pre-loaded for simulator)
; Line format: lo_lineno, hi_lineno, ASCII body, CR
; ===========================================================================
         .ORG $0200
; line 10: REM
         .DB $0A,$00,"REM miniBASIC 65C02 Float BASIC",$0D
; line 20: PRINT header
         .DB $14,$00,"PRINT ",$22,"=== Arithmetic ===",$22,$0D
; line 30: 355/113 ~ pi
         .DB $1E,$00,"PRINT ",$22,"355/113=",$22,";355/113",$0D
; line 40: 1/3
         .DB $28,$00,"PRINT ",$22,"1/3    =",$22,";1/3",$0D
; line 50: 2/3
         .DB $32,$00,"PRINT ",$22,"2/3    =",$22,";2/3",$0D
; line 60: 1.5*1.5
         .DB $3C,$00,"PRINT ",$22,"1.5*1.5=",$22,";1.5*1.5",$0D
; line 70: 10%3
         .DB $46,$00,"PRINT ",$22,"10%3   =",$22,";10%3",$0D
; line 80: sum header
         .DB $50,$00,"PRINT ",$22,"=== Sum 1..100 ===",$22,$0D
; line 90: S=0:I=1
         .DB $5A,$00,"S=0:I=1",$0D
; line 100: loop condition  (GOTO 130 to exit)
         .DB $64,$00,"IF I>100 THEN GOTO 130",$0D
; line 110: loop body
         .DB $6E,$00,"S=S+I:I=I+1:GOTO 100",$0D
; line 130: print result  ($82=130)
         .DB $82,$00,"PRINT ",$22,"Sum=",$22,";S",$0D
; line 140: end  ($8C=140)
         .DB $8C,$00,"END",$0D
SHOWCASE_END:

         .ORG $FFFC
         .DW ROMSTART
         .DW IRQ_HANDLER
