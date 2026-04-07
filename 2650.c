// INCLUDES---------------------------------------------------------------

#ifdef AMIGA
    #include "amiga.h"
    #include <proto/locale.h>  // GetCatalogStr()
    #include <proto/dos.h>     // Write()
#endif
#ifdef WIN32
    #include "ibm.h"
    #define EXEC_TYPES_H
    #include "resource.h"
#endif

#include <stdio.h>             // zprintf()
#include <stdlib.h>            // for malloc(), calloc(), free(), rand()
#include <string.h>            // strcpy()

#include "aa.h"
#define CATCOMP_NUMBERS
#define CATCOMP_BLOCK
#include "aa_strings.h"

// DEFINES----------------------------------------------------------------

// #define LOGFP
// log 8K BASIC floating point operations (CD2650)

// Length of tape marks/space "half-cycles" in CPU cycles
// At 1 MHz:
#define MARKLENGTH         208 // length of mark  half-cycle (1     MHz / 2400 Hz / 2 ==  208.3')
#define CYCLELENGTH        312 // halfway between MARKLENGTH and SPACELENGTH
#define SPACELENGTH        416 // length of space half-cycle (1     MHz / 1200 Hz / 2 ==  416.6')
// At 1.183 MHz:
#define CD2650_MARKLENGTH  246 // length of mark  half-cycle (1.183 MHz / 2400 Hz / 2 == ~246   )
#define CD2650_CYCLELENGTH 369 // halfway between CD2650_MARKLENGTH and CD2650_SPACELENGTH
#define CD2650_SPACELENGTH 492 // length of space half-cycle (1.183 MHz / 1200 Hz / 2 == ~492   )

// Volume to record cassettes at
#define TAPEVOLUME         0x60               // 3/4 volume. Maximum is 0x7F.
#define LOWPULSE          (0x80 - TAPEVOLUME) // 3/4 volume. Minimum is 0x00.
#define HIGHPULSE         (0x80 + TAPEVOLUME) // 3/4 volume. Maximum is 0xFF.

#define CCFIELD            ((psl & PSL_CC) >> 6)
#ifdef GAMER
    #define gosub          pushras(); branch(OPERAND & 0x80);
    #define zgoto          branch(OPERAND & 0x80);
    #define ZERO_BYTES     ;
    #define ONE_BYTE       iar = WRAPMEM(1);
    #define TWO_BYTES      iar = WRAPMEM(2);
    #define THREE_BYTES    iar = WRAPMEM(3);
    #define RUNTOLOOPEND   ;
#else
    #define gosub          oldiar = iar; pushras(); branch(OPERAND & 0x80); if (ininterrupt < 8) { coverage[iar] |= COVERAGE_CALLSINT; } else { coverage[iar] &= ~(COVERAGE_DEPTH); coverage[iar] |= COVERAGE_CALLS | ((ULONG) (psu & PSU_SP) << COVERAGE_BITSHIFT); }
    #define zgoto          oldiar = iar;            branch(OPERAND & 0x80); if (ininterrupt < 8) { coverage[iar] |= COVERAGE_JUMPSINT; } else { coverage[iar] |= COVERAGE_JUMPS; }
    #define ZERO_BYTES     oldiar = iar;
    #define ONE_BYTE       oldiar = iar; iar = WRAPMEM(1); if (log_illegal && oldiar > iar) logiar();
    #define TWO_BYTES      oldiar = iar; iar = WRAPMEM(2); if (log_illegal && oldiar > iar) logiar();
    #define THREE_BYTES    oldiar = iar; iar = WRAPMEM(3); if (log_illegal && oldiar > iar) logiar();
    #define RUNTOLOOPEND   if (runtoloopend) { do_runtoloopend(); }
#endif
// #define REG_CYCLES      cycles_2650 += table_duration_2650[opcode]; justdone = table_duration_2650[opcode] / 3;
#define REG_CYCLES         if (supercpu) { cycles_2650 += 3; justdone = 1; } else { cycles_2650 += 6; justdone = 2; }
#define THREE_CYCLES       cycles_2650 +=  3; justdone = 1;
#define SIX_CYCLES         cycles_2650 +=  6; justdone = 2;
#define NINE_CYCLES        cycles_2650 +=  9; justdone = 3;
#define TWELVE_CYCLES      cycles_2650 += 12; justdone = 4;
#define FIFTEEN_CYCLES     cycles_2650 += 15; justdone = 5;
#define EIGHTEEN_CYCLES    cycles_2650 += 18; justdone = 6;
#define WRITEREGCC(a, b)   writereg(a, (UBYTE) (b)); set_cc(r[a])
#ifdef GAMER
    #define CHECKCOMI(a) ;
#else
    #define CHECKCOMI(a) \
    if (loginefficient) \
    {   nextopcode = memory[WRAPMEM(2)]; \
        if (nextopcode == (228 + (a)) && memory[WRAPMEM(3)] == 0) \
        {   DISCARD getfriendly(WRAPMEM(2)); \
            zprintf \
            (   TEXTPEN_LOG, \
                "Omit %s at %s.\n\n", \
                opcodes[style][nextopcode].name, \
                friendly \
            ); \
            set_pause(TYPE_LOG); \
    }   }
#endif

// #define EMULATEKEYBOARD
// whether to emulate TWIN keyboard interrupt inhibiting
// (causes problems with SDOS 4.2 after pressing DEL key)

// EXPORTED TABLES--------------------------------------------------------

EXPORT const int relative_2650[0x100] =
{     0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
     16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
     32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
     48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    -64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,
    -48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,
    -32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,
    -16,-15,-14,-13,-12,-11,-10, -9, -8, -7, -6, -5, -4, -3, -2, -1,
      0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
     16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
     32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
     48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    -64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,-52,-51,-50,-49,
    -48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,
    -32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,
    -16,-15,-14,-13,-12,-11,-10, -9, -8, -7, -6, -5, -4, -3, -2, -1
};

EXPORT int table_size_2650[256] =
{   1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, //   0.. 15 (LOD)
    3, 3, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, //  16.. 31 (SPSW/RETC/BCTR/BCTA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, //  32.. 47 (EOR)
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, //  48.. 63 (REDC/RETE/BSTR/BSTA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, //  64.. 79 (HALT/AND)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, //  80.. 95 (RRR/REDE/BRNR/BRNA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, //  96..111 (IOR)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 112..127 (REDD/CPSW/PPSW/BSNR/BSNA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 128..143 (ADD)
    1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, // 144..159 (LPSW/DAR/BCFR/ZBRR/BCFA/BXA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 160..175 (SUB)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 176..191 (WRTC/TPSW/BSFR/ZBSR/BSFA/BSXA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 192..207 (NOP/STR)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 208..223 (RRL/WRTE/BIRR/BIRA)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, // 224..239 (COM)
    1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3  // 240..255 (WRTD/TMI/BDRR/BDRA)
};

EXPORT const UBYTE table_opcolours_2650[2][256] = {
#ifdef THOLIN
{ // 2650A
    ORANGE, ORANGE, ORANGE,ORANGE,ORANGE,ORANGE,ORANGE, ORANGE, ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,//   0.. 15 (LOD)
    RED,    RED,    GREY1,GREY1,YELLOW, YELLOW, YELLOW, YELLOW, BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  //  16.. 31 (SPSW/RETC/BCTx)
    PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  32.. 47 (EOR)
    CYAN,   CYAN,   CYAN, CYAN, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,//  48.. 63 (REDC/RETE/BSTx)
    WHITE,  PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  64.. 79 (HALT/AND)
    PURPLE, PURPLE, PURPLE,PURPLE,CYAN, CYAN,   CYAN,   CYAN,   BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  //  80.. 95 (RRR/REDE/BRNx)
    PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  96..111 (IOR)
    CYAN,   CYAN,   CYAN, CYAN, GREY1,  GREY1,  GREY1,  GREY1,  YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,// 112..127 (REDD/CPSW/PPSW/BSNx)
    GREEN,  GREEN,  GREEN,GREEN,GREEN,  GREEN,  GREEN,  GREEN,  GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 128..143 (ADD)
    RED,    RED,    GREY1,GREY1,GREEN,  GREEN,  GREEN,  GREEN,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 144..159 (LPSW/DAR/BCFR/ZBRR/BCFA/BXA)
    GREEN,  GREEN,  GREEN,GREEN,GREEN,  GREEN,  GREEN,  GREEN,  GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 160..175 (SUB)
    CYAN,   CYAN,   CYAN, CYAN, GREY1,  GREY1,  RED,    RED,    YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,// 176..191 (WRTC/TPSW/BSFR/ZBSR/BSFA/BSXA)
    WHITE,  ORANGE, ORANGE,ORANGE,RED,  RED,    RED,    RED,    ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,// 192..207 (NOP/STR)
    PURPLE, PURPLE, PURPLE,PURPLE,CYAN, CYAN,   CYAN,   CYAN,   BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 208..223 (RRL/WRTE/BIRx)
    DKBLUE, DKBLUE, DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE, DKBLUE, DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,// 224..239 (COM)
    CYAN,   CYAN,   CYAN, CYAN, WHITE,  RED,    RED,    RED,    BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 240..255 (WRTD/TMI/BDRx)
},
{ // 2650B
    ORANGE, ORANGE, ORANGE,ORANGE,ORANGE,ORANGE,ORANGE, ORANGE, ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,//   0.. 15 (LOD)
    GREY1,  GREY1,  GREY1,GREY1,YELLOW, YELLOW, YELLOW, YELLOW, BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  //  16.. 31 (SPSW/RETC/BCTx)
    PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  32.. 47 (EOR)
    CYAN,   CYAN,   CYAN, CYAN, YELLOW, YELLOW, YELLOW, YELLOW, YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,//  48.. 63 (REDC/RETE/BSTx)
    WHITE,  PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  64.. 79 (HALT/AND)
    PURPLE, PURPLE, PURPLE,PURPLE,CYAN, CYAN,   CYAN,   CYAN,   BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  //  80.. 95 (RRR/REDE/BRNx)
    PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE, PURPLE, PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,PURPLE,//  96..111 (IOR)
    CYAN,   CYAN,   CYAN, CYAN, GREY1,  GREY1,  GREY1,  GREY1,  YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,// 112..127 (REDD/CPSW/PPSW/BSNx)
    GREEN,  GREEN,  GREEN,GREEN,GREEN,  GREEN,  GREEN,  GREEN,  GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 128..143 (ADD)
    RED,    RED,    GREY1,GREY1,GREEN,  GREEN,  GREEN,  GREEN,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 144..159 (LPSW/DAR/BCFR/ZBRR/BCFA/BXA)
    GREEN,  GREEN,  GREEN,GREEN,GREEN,  GREEN,  GREEN,  GREEN,  GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 160..175 (SUB)
    CYAN,   CYAN,   CYAN, CYAN, GREY1,  GREY1,  RED,    RED,    YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,YELLOW,// 176..191 (WRTC/TPSW/BSFR/ZBSR/BSFA/BSXA)
    WHITE,  ORANGE, ORANGE,ORANGE,RED,  RED,    RED,    RED,    ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,ORANGE,// 192..207 (NOP/STR)
    PURPLE, PURPLE, PURPLE,PURPLE,CYAN, CYAN,   CYAN,   CYAN,   BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 208..223 (RRL/WRTE/BIRx)
    DKBLUE, DKBLUE, DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE, DKBLUE, DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,DKBLUE,// 224..239 (COM)
    CYAN,   CYAN,   CYAN, CYAN, WHITE,  RED,    RED,    RED,    BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  BLUE,  // 240..255 (WRTD/TMI/BDRx)
} /*
Orange     = Load/Store
Red        = Unused
Grey       = Status Reg.
Yellow     = Subroutine (medium blue in original)
Light Blue = Branch
Purple     = Logical
Cyan       = I/O
White      = Misc.
Green      = Arithmetic
Dark Blue  = Compare */
#else
{ // 2650A
    PURPLE, RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //   0.. 15 (LOD)
    PURPLE, PURPLE, BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  16.. 31 (SPSW/RETC/BCTx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  32.. 47 (EOR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  48.. 63 (REDC/RETE/BSTx)
    YELLOW, RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  64.. 79 (HALT/AND)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  80.. 95 (RRR/REDE/BRNx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  96..111 (IOR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 112..127 (REDD/CPSW/PPSW/BSNx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 128..143 (ADD)
    PURPLE, PURPLE, BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 144..159 (LPSW/DAR/BCFR/ZBRR/BCFA/BXA)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 160..175 (SUB)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   PURPLE, PURPLE, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 176..191 (WRTC/TPSW/BSFR/ZBSR/BSFA/BSXA)
    YELLOW, RED,    RED,  RED,  PURPLE, PURPLE, PURPLE, PURPLE, RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 192..207 (NOP/STR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 208..223 (RRL/WRTE/BIRx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 224..239 (COM)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 240..255 (WRTD/TMI/BDRx)
},
{ // 2650B
    PURPLE, RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //   0.. 15 (LOD)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  16.. 31 (SPSW/RETC/BCTx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  32.. 47 (EOR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  48.. 63 (REDC/RETE/BSTx)
    YELLOW, RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  64.. 79 (HALT/AND)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, //  80.. 95 (RRR/REDE/BRNx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   //  96..111 (IOR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 112..127 (REDD/CPSW/PPSW/BSNx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 128..143 (ADD)
    PURPLE, PURPLE, BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 144..159 (LPSW/DAR/BCFR/ZBRR/BCFA/BXA)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 160..175 (SUB)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   PURPLE, PURPLE, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 176..191 (WRTC/TPSW/BSFR/ZBSR/BSFA/BSXA)
    YELLOW, RED,    RED,  RED,  PURPLE, PURPLE, PURPLE, PURPLE, RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 192..207 (NOP/STR)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 208..223 (RRL/WRTE/BIRx)
    RED,    RED,    RED,  RED,  RED,    RED,    RED,    RED,    RED,   RED,   RED,   RED,   RED,   RED,   RED,   RED,   // 224..239 (COM)
    BLUE,   BLUE,   BLUE, BLUE, BLUE,   BLUE,   BLUE,   BLUE,   GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, GREEN, // 240..255 (WRTD/TMI/BDRx)
}
#endif
};

EXPORT const TEXT table_addrmode_2650[2][256 + 1] = {
{  "-GGGIIIIRRRRAAAA" \
   "--IIGGGGRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGTTTTRRRRAAAA" \
   "TGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "--IIGGGGRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGII--RRRRAAAA" \
   "TGGG----RRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA"
},
{  "-GGGIIIIRRRRAAAA" \
   "AAIIGGGGRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGTTTTRRRRAAAA" \
   "TGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "--IIGGGGRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGII--RRRRAAAA" \
   "TGGG----RRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA" \
   "GGGGIIIIRRRRAAAA"
} };
/* Addressing modes are:
A = Absolute
G = reGister
I = Immediate
R = Relative
T = impliciT
- = illegal

Indirect addressing instructions require 15 or 18 cycles (6 more than usual).

S/I = Sense          (PSU)
F/O = Flag           (PSU)
I/F = II             (PSU)
P   = SP             (PSU)
T   = condiTion code (PSL)
D/H = IDC            (PSL)
R/B = RS             (PSL)
W   = WC             (PSL)
O/V = OVF            (PSL)
M/L = COM            (PSL)
C   = C              (PSL)
RAS, IAR/PC are not shown.
*/

EXPORT const STRPTR tokenname[LASTTOKEN - FIRSTTOKEN + 1][STYLES] = {
{ "R0"  , "R0"  , "A"    , "R0",   ".0"    },
{ "R1"  , "R1"  , "B"    , "R1",   ".1"    },
{ "R2"  , "R2"  , "C"    , "R2",   ".2"    },
{ "R3"  , "R3"  , "D"    , "R3",   ".3"    },
{ "R4"  , "R4"  , "B'"   , "R4",   ".4"    },
{ "R5"  , "R5"  , "C'"   , "R5",   ".5"    },
{ "R6"  , "R6"  , "D'"   , "R6",   ".6"    },
{ "PSU" , "PSU" , "U"    , "PSU",  ".U"    }, // should support R8 for this (like TVGC book)
{ "PSL" , "PSL" , "L"    , "PSL",  ".L"    }, // should support R7 for this (like TVGC book)
{ "SP"  , "SP"  , "STACK", "SP",   ".SP"   },
{ "CC"  , "CC"  , "CC"   , "CC",   ".CC"   },
{ "IAR" , "IAR" , "PC"   , "PC",   ".PC"   },
{ "RAS0", "RAS0", "RAS0" , "RAS0", ".RAS0" },
{ "RAS1", "RAS1", "RAS1" , "RAS1", ".RAS1" },
{ "RAS2", "RAS2", "RAS2" , "RAS2", ".RAS2" },
{ "RAS3", "RAS3", "RAS3" , "RAS3", ".RAS3" },
{ "RAS4", "RAS4", "RAS4" , "RAS4", ".RAS4" },
{ "RAS5", "RAS5", "RAS5" , "RAS5", ".RAS5" },
{ "RAS6", "RAS6", "RAS6" , "RAS6", ".RAS6" },
{ "RAS7", "RAS7", "RAS7" , "RAS7", ".RAS7" },
};

// IMPORTED VARIABLES-----------------------------------------------------

IMPORT       int                      binbug_baudrate,
                                      binbug_biosver,
                                      cd2650_biosver,
                                      cd2650_dosver,
                                      connected,
                                      cpuy,
                                      fastcd2650,
                                      logbios,
                                      loginefficient,
                                      log_illegal,
                                      log_interrupts,
                                      logsubroutines,
                                      logreadwrites,
                                      machine,
                                      memmap,
                                      malzak_x,
                                      n1, n2, n3, n4,
                                      otl,
                                      pausebreak,
                                      pauselog,
                                      pipbug_biosver,
                                      phunsy_biosver,
                                      pvibase,
                                      recmode,
                                      runtointerrupt,
                                      runtoloopend,
                                      s_id,
                                      s_io,
                                      selbst_biosver,
                                      starscroll,
                                      step,
                                      style,
                                      supercpu,
                                      tapemode,
                                      tapekind,
                                      trace,
                                      useguideray,
                                      verbosity,
                                      watchreads,
                                      watchwrites,
                                      wheremusicmouse[2],
                                      whichcpu,
                                      whichgame;
IMPORT       TEXT                     addrstr[32 + 1 + 1],
                                      friendly[FRIENDLYLENGTH + 1];
IMPORT       UBYTE                    g_bank1[1024],
                                      g_bank2[16],
                                      glow,
                                      ininterrupt,
                                      lb_bank,
                                      malzak_field[16][16],
                                      memory_effects[512],
                                      s_tapeport,
                                      s_toggles,
                                      keys_column[7],
                                      tapeskewage,
                                      tt_scrncode;
IMPORT       UWORD                    console[4],
                                      mirror_r[32768],
                                      mirror_w[32768];
IMPORT       ULONG                    binbug_interface,
                                      cpb,
                                      frames,
                                      inverttape,
                                      oldcycles,
                                      paused,
                                      sound,
                                      tapewriteprotect,
                                      tt_scrntill,
                                      verbosetape;
IMPORT       FLAG                     halted,
                                      priflag[32];
IMPORT       UBYTE*                   TapeCopy;
IMPORT       FILE*                    TapeHandle;
IMPORT       struct ConditionalStruct bp[32768],
                                      wp[ALLTOKENS];
IMPORT       struct FlagNameStruct    flagname[CPUTIPS];
IMPORT       struct IOPortStruct      ioport[258];
IMPORT const struct KnownStruct       known[KNOWNGAMES];
IMPORT       struct MachineStruct     machines[MACHINES];
IMPORT       struct OpcodeStruct      opcodes[3][256];
IMPORT       TEXT                     asciiname_short[259][3 + 1];
IMPORT       ASCREEN                  screen[BOXWIDTH][BOXHEIGHT];
IMPORT const STRPTR                   pristring[32];
#ifdef AMIGA
    IMPORT   struct Catalog*          CatalogPtr;
#endif
#ifdef WIN32
    IMPORT   int                      CatalogPtr;
#endif

// MODULE VARIABLES-------------------------------------------------------

MODULE FLAG    pausing = FALSE;
MODULE UBYTE   after, before,
               nextopcode,
               oldpsl, oldpsu, oldr[7];

// EXPORTED VARIABLES-----------------------------------------------------

EXPORT UBYTE   psu,
               psl,
               memory[32768],
               oldtapebyte,
               opcode,
               rr, // register (0..6)
               r[7], // register is a reserved word
               tapebyte;
EXPORT UWORD   iar,
               mirror_r[32768],
               mirror_w[32768],
               oldiar          = 0x0000,
               ras[8];
EXPORT ULONG   asicreads[32768],
               asicwrites[32768],
               coverage[32768],
               cycles_2650,
               cycles_prev,
               ea,
               oldtapecycle,
               samplewhere     = 0,
               tapelength      = 0;
EXPORT TEXT    friendly2[FRIENDLYLENGTH + 1],
               stringchar[19 + 1], // enough for "%1,1,1,1,1,1,1,1"
               v_bin[3 + 8 + 1]; // enough for "'B'01010101"
EXPORT int     addr,
               interrupt_2650,
               justdone        = 0,
               slice_2650,
               traceorstep     = FALSE,
               tt_scrn;
EXPORT char    psubits[5 + 1],
               pslbits[6 + 1],
               v[2 + 1];
EXPORT double  samplewhere_f   = 0.0,
               tapespeed;
EXPORT STRPTR  timeunitstr1,
               timeunitstr2;
EXPORT MEMFLAG memflags[ALLTOKENS];

// MODULE FUNCTIONS-------------------------------------------------------

MODULE __inline void set_cc(UBYTE n);
MODULE __inline void branch(int indirect);
MODULE void compare(UBYTE first, UBYTE second);
MODULE UBYTE add(UBYTE dest, UBYTE source);
MODULE UBYTE subtract(UBYTE dest, UBYTE source);
MODULE void ABS_EA(void);
MODULE void BRA_EA(void);
MODULE void REL_EA(void);
MODULE void ZERO_EA(void);
MODULE UBYTE cpuread_2650(int address);
MODULE __inline void cpuwrite_2650(int address, UBYTE data);
MODULE __inline UBYTE readreg(int whichreg);
MODULE __inline void writereg(int whichreg, UBYTE data);
MODULE __inline void cpu_emu(void);
#ifndef GAMER
    MODULE void checkabsbranch(void);
    MODULE void checkrelbranch(void);
    MODULE void check_handler(void);
    MODULE void do_runtoloopend(void);
    MODULE void logiar(void);
    MODULE void logindirectbios(void);
    MODULE void runto(void);
#endif

// CODE-------------------------------------------------------------------

EXPORT void cpu_2650_untapable(void)
{   FAST ULONG endcycle;

    // assert(slice_2650 >= 1);

    endcycle = cycles_2650 + slice_2650;
    if (endcycle < cycles_2650)
    {   // cycle counter will overflow, so we need to use the slow method
        while (slice_2650 >= 1)
        {   oldcycles = cycles_2650;
            checkstep();
            one_instruction();
            slice_2650 -= (cycles_2650 - oldcycles);
    }   }
    else
    {   // cycle counter will not overflow, so we can use a faster method
        oldcycles = cycles_2650;
        while (cycles_2650 < endcycle)
        {   checkstep();
            one_instruction();
        }
        slice_2650 -= (cycles_2650 - oldcycles);
}   }

EXPORT void cpu_2650_tapable(void)
{   FAST ULONG endcycle;

    // assert(slice_2650 >= 1);

    endcycle = cycles_2650 + slice_2650;
    if (endcycle < cycles_2650)
    {   // cycle counter will overflow, so we need to use the slow method
        while (slice_2650 >= 1)
        {   oldcycles = cycles_2650;
            checkstep();
            do_tape();
            one_instruction();
            slice_2650 -= (cycles_2650 - oldcycles);
    }   }
    else
    {   // cycle counter will not overflow, so we can use a faster method
        oldcycles = cycles_2650;
        while (cycles_2650 < endcycle)
        {   checkstep();
            do_tape();
            one_instruction();
        }
        slice_2650 -= (cycles_2650 - oldcycles);
}   }

EXPORT void one_instruction(void)
{
#ifdef LOGFP
    PERSIST float number1, number2;
    FAST    float number3;
    PERSIST FLAG  sub      = FALSE,
                  abnormal = FALSE;
    FAST    int   number;

    if (machine == CD2650 && whichgame != -1 && (known[whichgame].complang == CL_8KB13 || whichgame == 642 || whichgame == 643 || whichgame == 834 || whichgame == 835)) // don't hardcode these numbers
    {   switch (iar)
        {
        case 0x3269:
            number = (memory[0x327B] * 256) + memory[0x327C];
            number1 = basic_to_float(number);
            zprintf
            (   TEXTPEN_LOG,
                "Popped %02X %02X%02X%02X (%f). BASIC SP is now $%02X%02X.\n",
                memory[number], memory[number + 1], memory[number + 2], memory[number + 3],
                number1,
                memory[0x32CF], memory[0x32D0]
            );
        acase 0x3293:
            number = (memory[0x327B] * 256) + memory[0x327C];
            number1 = basic_to_float(number);
            zprintf
            (   TEXTPEN_LOG,
                "Pushed %02X %02X%02X%02X (%f). BASIC SP is now $%02X%02X.\n",
                memory[number], memory[number + 1], memory[number + 2], memory[number + 3],
                number1,
                memory[0x32CF], memory[0x32D0]
            );
        acase 0x32C2:
            zprintf
            (   TEXTPEN_LOG,
                "Adjusted BASIC SP, now $%02X%02X!\n", 
                memory[0x32CF], memory[0x32D0]
            );
        acase 0x37BF:
            number1 = basic_to_float(0x2748); // needed later
            number2 = basic_to_float(0x274D); // needed later
            zprintf
            (   TEXTPEN_LOG,
                "%02X %02X%02X%02X - %02X %02X%02X%02X (%f - %f = %f)\n",
                memory[0x2748], memory[0x2749], memory[0x274A], memory[0x274B],
                memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                number1,
                number2,
                number1 - number2
            );
            sub = TRUE;
        acase 0x37EF:
            sub = FALSE;
        acase 0x37F2:
            if (!sub)
            {   number1 = basic_to_float(0x2748);
                number2 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "%02X %02X%02X%02X + %02X %02X%02X%02X (%f + %f = %f)\n",
                    memory[0x2748], memory[0x2749], memory[0x274A], memory[0x274B],
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1,
                    number2,
                    number1 + number2
                );
            }
        acase 0x3814: // ROOF
            number3 = basic_to_float(0x274D);
            zprintf
            (   TEXTPEN_LOG,
                "Rounding %02X%02X%02X%02X (%f)!\n",
                memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                number3
            );
            if (sub)
            {   sub = FALSE;
            }
        acase 0x389C:
            if (r[0] == 0)
            {   number1 = basic_to_float(0x2748);
                number2 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "%02X %02X%02X%02X * %02X %02X%02X%02X (%f * %f = %f)\n",
                    memory[0x2748], memory[0x2749], memory[0x274A], memory[0x274B],
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1,
                    number2,
                    number1 * number2
                );
            } else
            {   number1 = basic_to_float(0x2748);
                number2 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "%02X %02X%02X%02X / %02X %02X%02X%02X (%f / %f = %f)\n",
                    memory[0x2748], memory[0x2749], memory[0x274A], memory[0x274B],
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1,
                    number2,
                    number1 / number2
                );
            }
        acase 0x3994: // NORM
            if (!zisnormal(0x274D))
            {   abnormal = TRUE;
                number1 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "Normalizing %02X ",
                    memory[0x274D]
                );
                zprintf
                (   TEXTPEN_ERROR,
                    "%X",
                    (memory[0x274E] & 0xF0) >> 4
                );
                zprintf
                (   TEXTPEN_LOG,
                    "%X%02X%02X (%f)\n",
                    memory[0x274E] & 0x0F, memory[0x274F], memory[0x2750],
                    number1
                );
            } else
            {   abnormal = FALSE;
            }
        acase 0x399E:
            if (abnormal && (psl & 0xC0) == 0x80) // LT
            {   abnormal = FALSE;
                number1 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "to          %02X %02X%02X%02X (%f).\n",
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1
                );
            }
        acase 0x39A2:
            if (abnormal && (psl & 0xC0) == 0x40) // GT
            {   abnormal = FALSE;
                number1 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "to          %02X %02X%02X%02X (%f).\n",
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1
                );
            }
        acase 0x39C4:
            if (abnormal)
            {   abnormal = FALSE;
                number1 = basic_to_float(0x274D);
                zprintf
                (   TEXTPEN_LOG,
                    "to          %02X %02X%02X%02X (%f).\n",
                    memory[0x274D], memory[0x274E], memory[0x274F], memory[0x2750],
                    number1
                );
            }
        acase 0x39C5: // ECONST
            zprintf(TEXTPEN_LOG, "Parsing integer part...\n");
        acase 0x3A02: // ECONS1
            zprintf(TEXTPEN_LOG, "Parsing fractional part...\n");
    }   }
#endif

    // iar = mirror_r[iar];
    opcode = memory[iar];

#ifndef GAMER
    coverage[iar] |= COVERAGE_OPCODE;
    if (log_illegal)
    {   if (coverage[iar] & COVERAGE_OPERAND)
        {   DISCARD getfriendly(iar);
            zprintf(TEXTPEN_LOG, LLL(MSG_OPCODEOPERAND, "The byte at %s, now an opcode, has previously been an operand!\n\n"), friendly);
            set_pause(TYPE_LOG);
        }
        if ((memflags[iar] & (ASIC | NOREAD | READONCE | AUDIBLE | VISIBLE)) || iar != mirror_r[iar])
        {   DISCARD getfriendly(iar);
            zprintf(TEXTPEN_LOG, "Opcode at %s is in an unusual memory region!\n\n", friendly);
        }
        if (table_size_2650[opcode] >= 2)
        {   coverage[WRAPMEM(1)] |= COVERAGE_OPERAND;
            if (coverage[WRAPMEM(1)] & COVERAGE_OPCODE)
            {   DISCARD getfriendly(WRAPMEM(1));
                zprintf(TEXTPEN_LOG, LLL(MSG_1STOPERANDOPCODE, "The byte at %s, now the 1st byte of an operand, has previously been an opcode!\n\n"), friendly);
                set_pause(TYPE_LOG);
            }
            if ((memflags[iar + 1] & (ASIC | NOREAD | READONCE | AUDIBLE | VISIBLE)) || iar + 1 != mirror_r[iar + 1])
            {   DISCARD getfriendly(iar + 1);
                zprintf(TEXTPEN_LOG, "Operand at %s is in an unusual memory region!\n\n", friendly);
            }
            if (table_size_2650[opcode] == 3)
            {   coverage[WRAPMEM(2)] |= COVERAGE_OPERAND;
                if (coverage[WRAPMEM(2)] & COVERAGE_OPCODE)
                {   DISCARD getfriendly(WRAPMEM(2));
                    zprintf(TEXTPEN_LOG, LLL(MSG_2NDOPERANDOPCODE, "The byte at %s, now the 2nd byte of an operand, has previously been an opcode!\n\n"), friendly);
                    set_pause(TYPE_LOG);
                }
                if ((memflags[iar + 2] & (ASIC | NOREAD | READONCE | AUDIBLE | VISIBLE)) || iar + 2 != mirror_r[iar + 2])
                {   DISCARD getfriendly(iar + 2);
                    zprintf(TEXTPEN_LOG, "Operand at %s is in an unusual memory region!\n\n", friendly);
    }   }   }   }
    else
    {   if (table_size_2650[opcode] >= 2)
        {   coverage[WRAPMEM(1)] |= COVERAGE_OPERAND;
            if (table_size_2650[opcode] == 3)
            {   coverage[WRAPMEM(2)] |= COVERAGE_OPERAND;
    }   }   }

    if (traceorstep)
    {   tracecpu_2650(TRUE, FALSE);
        saytrace();
        cpu_emu();
        if (verbosity == 1)
        {   table_trace();
        } elif (verbosity == 2)
        {   view_cpu_2650(FALSE);
        }
        if (verbosity >= 1 && step)
        {   view_next_2650();
        }
        update_monitor(FALSE);
        if (trace && useguideray)
        {   draw_guide_ray(FALSE);
        }
        updatescreen();
        if (trace && useguideray)
        {   draw_guide_ray(TRUE);
        }

        if (step)
        {   step = FALSE;
            traceorstep = (trace || step) ? TRUE : FALSE;
            memflags[iar] &= ~(STEPPOINT);
            emu_pause(); // this is recursive! :-(
        }

        if (!pausing)
        {   // if not pausing, we just checkinput() once
            do
            {
#ifdef WIN32
                wa_checkinput();
                process_code();
#endif
#ifdef AMIGA
                aa_checkinput();
#endif
            } while (paused);
    }   }
    else
    {   cpu_emu();
    }

    if (pausing)
    {   runto();
    }
#endif
}

MODULE __inline void cpu_emu(void)
{   switch (opcode)
    {
    case 0:                                                 // LODZ r0
#ifndef GAMER
        if (log_illegal)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_INDETERMINATE,
                    "Instruction at %s executed indeterminate opcode $00 (LODZ r0)!\n\n" // should use CALM notation if in CALM mode
                ),
                friendly
            );
            set_pause(TYPE_LOG);
        }
        if (loginefficient)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_REPLACE,
                    "Replace %s with %s at %s.\n\n"
                ),
                opcodes[style][   0].name, // LODZ r0
                opcodes[style][0x60].name, // IORZ r0
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
        DISCARD readreg(0); // or this could be considered to be a write
        set_cc(r[0]); // yes, the CC is set according to the *old* value!
        ONE_BYTE;
        REG_CYCLES;
    acase 1:                                                // LODZ r1
    case 2:                                                 // LODZ r2
    case 3:
        GET_RR;
        WRITEREGCC(0, r[rr]);
        ONE_BYTE;
        REG_CYCLES;
    acase 4:                                                // LODI,r0
#ifndef GAMER
        if (loginefficient)
        {   if (OPERAND == 0)
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Replace %s with %s at %s.\n\n",
                    opcodes[style][   4].name, // LODI,r0
                    opcodes[style][0x20].name, // EORZ r0
                    friendly
                );
                set_pause(TYPE_LOG);
            }
            CHECKCOMI(0);
        }
#endif
        WRITEREGCC(0, OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 5:                                                // LODI,r1
    case 6:                                                 // LODI,r2
    case 7:                                                 // LODI,r3
        if
        (   whichgame == PIPBUG_MORSEPOS
         && opcode  == 6 // LODI,r2
         && (   iar == 0x49B
             || iar == 0x4AC
        )   )
        {   // assert(machine == PIPBUG);
            playsound(FALSE);
        } elif
        (   whichgame == PIANOPOS
         && opcode == 5 // LODI,r1
         && iar == 0x1816
        )
        {   // assert(machine == PHUNSY);
            playsound(FALSE);
        }

        CHECKCOMI(opcode & 3);

        GET_RR;
        WRITEREGCC(rr, OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 8:                                                // LODR,r0
        REL_EA();
#ifndef GAMER
        if (loginefficient)
        {   if
            (    (OPERAND & 0x80) == 0x00     // direct
             &&  (memflags[ea    ] & NOWRITE) // reading from ROM
             && !(memflags[ea    ] & ASIC)    // really
             &&  (memflags[ea + 1] & NOWRITE) // reading from ROM
             && !(memflags[ea + 1] & ASIC)    // really
            ) // wrapping issues!
            {   DISCARD getfriendly(iar);
                dec_to_hex(cpuread_2650((int) ea));
                zprintf
                (   TEXTPEN_LOG,
                    "Replace %s with %s %s at %s.\n\n",
                    opcodes[style][8].name, // LODR,r0
                    opcodes[style][4].name, // LODI,r0
                    v,
                    friendly
                );
                set_pause(TYPE_LOG);
            }
            CHECKCOMI(0);
        }
#endif
        WRITEREGCC(0, cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 9:                                                // LODR,r1
    case 10:                                                // LODR,r2
    case 11:                                                // LODR,r3
        REL_EA();
#ifndef GAMER
        if (loginefficient)
        {   if
            (    (OPERAND & 0x80) == 0x00     // direct
             &&  (memflags[ea    ] & NOWRITE) // reading from ROM
             && !(memflags[ea    ] & ASIC)    // really
             &&  (memflags[ea + 1] & NOWRITE) // reading from ROM
             && !(memflags[ea + 1] & ASIC)    // really
            ) // wrapping issues!
            {   DISCARD getfriendly(iar);
                dec_to_hex(cpuread_2650((int) ea));
                zprintf
                (   TEXTPEN_LOG,
                    "Replace %s with %s %s at %s.\n\n",
                    opcodes[style][opcode    ].name, // LODA,rn
                    opcodes[style][opcode - 4].name, // LODI,rn
                    v,
                    friendly
                );
                set_pause(TYPE_LOG);
            }
            CHECKCOMI(opcode & 3);
        }
#endif
        GET_RR;
        WRITEREGCC(rr, cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 12:                                               // LODA,r0
#ifndef GAMER
        if (iar == 0x79E && machine == ELEKTOR && verbosetape)
        {   zprintf(TEXTPEN_TAPE, "Found start of block.\n");
        }
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 13:                                                // LODA,r1
    case 14:                                                // LODA,r2
    case 15:                                                // LODA,r3
        if (iar == 0x369 && machine == BINBUG && binbug_biosver == BINBUG_61 && binbug_baudrate == BINBUG_BAUDRATE_2400 && opcode == 0x0D)
        {   // patch for BINBUG 6.1 because the table at DL1 ($2CC) does not extend far enough to cover 2400/4800 baud
            if (r[2] == 2)
            {   WRITEREGCC(0, 0x0A); // $0B also works
            } elif (r[2] == 1)
            {   WRITEREGCC(0, 0x0C); // $0D also works
        }   }
        else
        {   ABS_EA(); // calls GET_RR for us
#ifndef GAMER
            if (loginefficient)
            {   if
                (    (OPERAND & 0xE0) == 0x00     // direct, non-indexed
                 &&  (memflags[ea    ] & NOWRITE) // reading from ROM
                 && !(memflags[ea    ] & ASIC)    // really
                 &&  (memflags[ea + 1] & NOWRITE) // reading from ROM
                 && !(memflags[ea + 1] & ASIC)    // really
                ) // wrapping issues!
                {   DISCARD getfriendly(iar);
                    dec_to_hex(OPERAND),
                    zprintf
                    (   TEXTPEN_LOG,
                        "Replace %s with %s %s at %s.\n\n",
                        opcodes[style][opcode    ].name, // LODA,rn
                        opcodes[style][opcode - 8].name, // LODI,rn
                        v,
                        friendly
                    );
                    set_pause(TYPE_LOG);
                }
                CHECKCOMI(opcode & 3);
            }
#endif
            WRITEREGCC(rr, cpuread_2650((int) ea));
        }
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 16:                                               // LDPL addr
        if (supercpu)
        {   BRA_EA();
            psl = cpuread_2650((int) ea);
#ifndef GAMER
            if (log_illegal && (psl & PSL_CC) == 0xC0)
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL
                    (   MSG_ENGINE_CCUN,
                        "%s instruction at %s is setting the Condition Code to %11 (UN)!\n\n"
                    ),
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
            }
#endif
            if (OPERAND & 0x80)
            {   EIGHTEEN_CYCLES;
            } else
            {   TWELVE_CYCLES;
            }
            THREE_BYTES;
        } else
        {
#ifndef GAMER
            if (log_illegal)
            {   zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_UNDEFINED,
                        "Instruction at $%04X executed undefined opcode $%02X!\n\n"
                    ),
                    (int) iar,
                    (int) opcode
                );
            }
#endif
            if (machine == INTERTON)
            {   THREE_BYTES;
            } else
            {   ONE_BYTE; // eg. the tested ARCADIA
            }
            SIX_CYCLES; // guess
        }
    acase 17:                                               // STPL addr
        if (supercpu)
        {   BRA_EA();
            cpuwrite_2650((int) ea, psl);
            if (OPERAND & 0x80)
            {   EIGHTEEN_CYCLES;
            } else
            {   TWELVE_CYCLES;
            }
            THREE_BYTES;
        } else
        {
#ifndef GAMER
            if (log_illegal)
            {   zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_UNDEFINED,
                        "Instruction at $%04X executed undefined opcode $%02X!\n\n"
                    ),
                    (int) iar,
                    (int) opcode
                );
            }
#endif
            ONE_BYTE; // tested on Arcadia and Interton
            SIX_CYCLES; // guess
        }
    acase 18:                                               // SPSU
        WRITEREGCC(0, psu);
        ONE_BYTE;
        SIX_CYCLES;
    acase 19:                                               // SPSL
        WRITEREGCC(0, psl);
        ONE_BYTE;
        SIX_CYCLES;
    acase 20:                                               // RETC,eq
    case 21:                                                // RETC,gt
    case 22:                                                // RETC,lt
        if (BRANCHCODE == CCFIELD)
        {   pullras();
        } else
        {   ONE_BYTE;
        }
        NINE_CYCLES;
    acase 0x17:                                             // RETC,un
        pullras();
        NINE_CYCLES;
    acase 24:                                               // BCTR,eq
    case 25:                                                // BCTR,gt
    case 26:                                                // BCTR,lt
        if (BRANCHCODE == CCFIELD)
        {   REL_EA();
            ea = mirror_r[ea];
            checkrelbranch();
            zgoto;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 27:                                               // BCTR,un
        REL_EA();
        ea = mirror_r[ea];
        checkrelbranch();
        zgoto;
    acase 28:                                               // BCTA,eq
    case 29:                                                // BCTA,gt
        if (BRANCHCODE == CCFIELD)
        {   BRA_EA();
            checkabsbranch();
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 30:                                               // BCTA,lt
        if
        (   iar == 0x4A5
         && (whichgame == MUSIC1POS || whichgame == MUSIC2POS)
        )
        {   // assert(machine == PIPBUG);
            playsound(FALSE);
        }
        if (BRANCHCODE == CCFIELD)
        {   BRA_EA();
            checkabsbranch();
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 31:                                               // BCTA,un
        BRA_EA();
        checkabsbranch();
        zgoto;
    acase 32:                                               // EORZ r0
        writereg(0, 0);
        psl &= ~(PSL_CC); // clear CC bits of PSL (ie. CC = "eq")
        ONE_BYTE;
        REG_CYCLES;
    acase 33:                                               // EORZ r1
    case 34:                                                // EORZ r2
    case 35:                                                // EORZ r3
        GET_RR;
        WRITEREGCC(0, r[0] ^ readreg(rr));
        ONE_BYTE;
        REG_CYCLES;
    acase 36:                                               // EORI,r0
        CHECKCOMI(0);
        WRITEREGCC(0, r[0] ^ OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 37:                                               // EORI,r1
    case 38:                                                // EORI,r2
    case 39:                                                // EORI,r3
        CHECKCOMI(opcode & 3);
        GET_RR;
        WRITEREGCC(rr, r[rr] ^ OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 40:                                               // EORR,r0
        REL_EA();
        WRITEREGCC(0, r[0] ^ cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 41:                                               // EORR,r1
    case 42:                                                // EORR,r2
    case 43:                                                // EORR,r3
        REL_EA();
        GET_RR;
        WRITEREGCC(rr, r[rr] ^ cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 44:                                               // EORA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 45:                                                // EORA,r1
    case 46:                                                // EORA,r2
    case 47:                                                // EORA,r3
        ABS_EA(); // calls GET_RR for us
        WRITEREGCC(rr, r[rr] ^ cpuread_2650((int) ea));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 48:                                               // REDC r0
    case 49:                                                // REDC r1
    case 50:                                                // REDC r2
    case 51:                                                // REDC r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        WRITEREGCC(rr, readport(PORTC));
        ONE_BYTE;
        SIX_CYCLES;
    acase 52:                                               // RETE,eq
    case 53:                                                // RETE,gt
    case 54:                                                // RETE,lt
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " $%X (%s)!\n\n",
                (long unsigned int) opcode,
                                    opcodes[style][opcode].name
            );
        }
#endif
        if (BRANCHCODE == CCFIELD)
        {
#ifndef GAMER
            if (log_interrupts && (psu & PSU_II))
            {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSENABLED, "%s at $%04X (rastline %d): interrupts are now disinhibited (enabled)."), opcodes[style][opcode].name, iar, cpuy);
                zprintf(TEXTPEN_LOG, " ");
                if (interrupt_2650)
                {   zprintf(TEXTPEN_LOG, LLL(MSG_ANINTERRUPTPENDING, "An interrupt is pending!\n\n"));
                } else
                {   zprintf(TEXTPEN_LOG, LLL(MSG_NOINTERRUPTPENDING, "No interrupt is pending.\n\n"));
            }   }
#endif
            psu &= ~(PSU_II); // clear II bit (PSU &= %11011111)
            pullras();
#ifndef GAMER
            if (log_interrupts)
            {   check_handler();
            }
#endif
            NINE_CYCLES;
            checkinterrupt();
        } else
        {   ONE_BYTE;
            NINE_CYCLES;
        }
    acase 55:                                               // RETE,un
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " $37 (RETE,un)!\n\n"
            );
        }
        if (log_interrupts && (psu & PSU_II))
        {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSENABLED, "%s at $%04X (rastline %d): interrupts are now disinhibited (enabled)."), opcodes[style][opcode].name, iar, cpuy);
            zprintf(TEXTPEN_LOG, " ");
            if (interrupt_2650)
            {   zprintf(TEXTPEN_LOG, LLL(MSG_ANINTERRUPTPENDING, "An interrupt is pending!\n\n"));
            } else
            {   zprintf(TEXTPEN_LOG, LLL(MSG_NOINTERRUPTPENDING, "No interrupt is pending.\n\n"));
        }   }
#endif
        psu &= ~(PSU_II); // clear II bit (PSU &= %11011111)
        pullras();
#ifndef GAMER
        if (log_interrupts)
        {   check_handler();
        }
#endif
        NINE_CYCLES;
        checkinterrupt();
    acase 56:                                               // BSTR,eq
    case 57:                                                // BSTR,gt
    case 58:                                                // BSTR,lt
        if (BRANCHCODE == CCFIELD)
        {   REL_EA();
            ea = mirror_r[ea];
            gosub;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 59:                                               // BSTR,un
#ifndef GAMER
        if (loginefficient)
        {   nextopcode = memory[WRAPMEM(2)];
            if (nextopcode == 0x17) // RETC,un
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_REPLACE2,
                        "Replace %s and %s with %s at %s.\n\n"
                    ),
                    opcodes[style][    opcode].name, // BSTR,un
                    opcodes[style][nextopcode].name, // RETC,un
                    opcodes[style][        27].name, // BCTR,un
                    friendly
                );
                set_pause(TYPE_LOG);
        }   }
#endif
        REL_EA();
        ea = mirror_r[ea];
        gosub;
    acase 60:                                               // BSTA,eq
    case 61:                                                // BSTA,gt
    case 62:                                                // BSTA,lt
        if (BRANCHCODE == CCFIELD)
        {   BRA_EA();
            gosub;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 63:                                               // BSTA,un
#ifndef GAMER
        if (loginefficient)
        {   nextopcode = memory[WRAPMEM(3)];
            if (nextopcode == 0x17) // RETC,un
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_REPLACE2,
                        "Replace %s and %s with %s at %s.\n\n"
                    ),
                    opcodes[style][    opcode].name, // BSTA,un
                    opcodes[style][nextopcode].name, // RETC,un
                    opcodes[style][        31].name, // BCTA,un
                    friendly
                );
                set_pause(TYPE_LOG);
        }   }
#endif
        if (whichgame == MIKITMUSICPOS && iar >= 0x528 && iar <= 0x560)
        {   // assert(machine == MIKIT);
            playsound(FALSE);
        }
        BRA_EA();
        gosub;
    acase 64:                                               // HALT
#ifndef GAMER
        if (log_illegal && !halted)
        {   DISCARD getfriendly(iar);
            zprintf(TEXTPEN_LOG, "Instruction at %s executed HALT opcode!\n", friendly);
            if (psu & PSU_II)
            {   zprintf(TEXTPEN_LOG, "Warning: interrupts are inhibited!\n\n", friendly);
            } else
            {   zprintf(TEXTPEN_LOG, "\n");
            }
            halted = TRUE;
            set_pause(TYPE_LOG);
        }
#endif
        ZERO_BYTES;
        REG_CYCLES;
        if (machine == TWIN && whichcpu == 0)
        {   master_to_slave();
        }
    acase 65:                                               // ANDZ r1
    case 66:                                                // ANDZ r2
    case 67:                                                // ANDZ r3
        GET_RR;
        WRITEREGCC(0, r[0] & readreg(rr));
        ONE_BYTE;
        REG_CYCLES;
    acase 68:                                               // ANDI,r0
        CHECKCOMI(0);
        WRITEREGCC(0, r[0] & OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 69:                                               // ANDI,r1
    case 70:                                                // ANDI,r2
    case 71:                                                // ANDI,r3
        CHECKCOMI(opcode & 3);
        GET_RR;
        WRITEREGCC(rr, r[rr] & OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 72:                                               // ANDR,r0
        REL_EA();
        WRITEREGCC(0, r[0] & cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 73:                                               // ANDR,r1
    case 74:                                                // ANDR,r2
    case 75:                                                // ANDR,r3
        REL_EA();
        GET_RR;
        WRITEREGCC(rr, r[rr] & cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 76:                                               // ANDA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 77:                                                // ANDA,r1
    case 78:                                                // ANDA,r2
    case 79:                                                // ANDA,r3
        ABS_EA(); // calls GET_RR for us
        WRITEREGCC(rr, r[rr] & cpuread_2650((int) ea));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 80:                                               // RRR,r0
    case 81:                                                // RRR,r1
    case 82:                                                // RRR,r2
    case 83:                                                // RRR,r3
        GET_RR;
        before = r[rr];
        after = (before & 0xFE) >> 1;
        if (psl & PSL_WC)
        {   if (psl & PSL_C)
            {   after |= 0x80;
            }
            writereg(rr, after);
            psl &= 0x1A; // ccdR,WoMc, Clear CC, IDC, OVF, C; preserve RS, WC, COM
            if (before & 1)
            {   psl |= PSL_C;
            }
            if (after & 0x20)
            {   psl |= PSL_IDC;
            }
            if ((before & 0x80) != (after & 0x80) && before <= 0x7F)
            {   psl |= PSL_OVF;
        }   }
        else
        {   if (before & 1)
            {   after |= 0x80;
            }
            writereg(rr, after);
            psl &= 0x3F; // ccDR,WOMC. Clear CC; preserve IDC, RS, WC, OVF, COM, C (OVF and C bit preservation confirmed on real machine)
        }
        if (r[rr] >= 128)
        {   psl |= 0x80; // CC = %10 (LT)
        } elif (r[rr] > 0)
        {   psl |= 0x40; // CC = %01 (GT)
        }
        ONE_BYTE;
        SIX_CYCLES;
    acase 84:                                               // REDE,r0
    case 85:                                                // REDE,r1
    case 86:                                                // REDE,r2
    case 87:                                                // REDE,r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        WRITEREGCC(rr, readport(OPERAND));
        TWO_BYTES;
        NINE_CYCLES;
    acase 88:                                               // BRNR,r0
    case 89:                                                // BRNR,r1
    case 90:                                                // BRNR,r2
    case 91:                                                // BRNR,r3
        GET_RR;
        if (readreg(rr))
        {   REL_EA();
            ea = mirror_r[ea];
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 92:                                               // BRNA,r0
    case 93:                                                // BRNA,r1
    case 94:                                                // BRNA,r2
    case 95:                                                // BRNA,r3
        GET_RR;
        if (readreg(rr))
        {   BRA_EA();
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 96:                                               // IORZ r0
        // r[0] |= r[0]; is not needed
        DISCARD readreg(0); // or can be considered to be a write
        set_cc(r[0]);
        ONE_BYTE;
        REG_CYCLES;
    acase 97:                                               // IORZ r1
    case 98:                                                // IORZ r2
    case 99:                                                // IORZ r3
        GET_RR;
        WRITEREGCC(0, r[0] | readreg(rr));
        ONE_BYTE;
        REG_CYCLES;
    acase 100:                                              // IORI,r0
        CHECKCOMI(0);
        WRITEREGCC(0, r[0] | OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 101:                                              // IORI,r1
    case 102:                                               // IORI,r2
    case 103:                                               // IORI,r3
        CHECKCOMI(opcode & 3);
        GET_RR;
        WRITEREGCC(rr, r[rr] | OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 104:                                              // IORR,r0
        REL_EA();
        WRITEREGCC(0, r[0] | cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 105:                                              // IORR,r1
    case 106:                                               // IORR,r2
    case 107:                                               // IORR,r3
        REL_EA();
        GET_RR;
        WRITEREGCC(rr, r[rr] | cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 108:                                              // IORA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 109:                                               // IORA,r1
    case 110:                                               // IORA,r2
    case 111:                                               // IORA,r3
        ABS_EA(); // calls GET_RR for us
        WRITEREGCC(rr, r[rr] | cpuread_2650((int) ea));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 112:                                              // REDD r0
    case 113:                                               // REDD r1
    case 114:                                               // REDD r2
    case 115:                                               // REDD r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        WRITEREGCC(rr, readport(PORTD));
        ONE_BYTE;
        SIX_CYCLES;
    acase 116:                                              // CPSU
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x07) != 7 && (OPERAND & psu & 0x07))
        {   getfriendly(iar);
            zprintf(TEXTPEN_LOG, LLL(MSG_MODIFYINGSP, "%s is modifying the SP at %s.\n\n"), opcodes[style][opcode].name, friendly);
            set_pause(TYPE_LOG);
        }

        if (loginefficient)
        {   if
            (   (!supercpu && (OPERAND & PSU_WRITABLE_A) == 0)
             || ( supercpu && (OPERAND & PSU_WRITABLE_B) == 0)
            )
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Omit %s at %s.\n\n",
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
        }   }
        if (log_interrupts && (psu & PSU_II) && (OPERAND & PSU_II))
        {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSENABLED, "%s at $%04X (rastline %d): interrupts are now disinhibited (enabled)."), opcodes[style][opcode].name, iar, cpuy);
            zprintf(TEXTPEN_LOG, " ");
            
            if (interrupt_2650)
            {   zprintf(TEXTPEN_LOG, LLL(MSG_ANINTERRUPTPENDING, "An interrupt is pending!\n\n"));
            } else
            {   zprintf(TEXTPEN_LOG, LLL(MSG_NOINTERRUPTPENDING, "No interrupt is pending.\n\n"));
        }   }
#endif
        if (supercpu)
        {   psu &= (~(OPERAND & PSU_WRITABLE_B));
        } else
        {   psu &= (~(OPERAND & PSU_WRITABLE_A));
        }
#ifdef DEBUGPSU
        zprintf(TEXTPEN_VERBOSE, "Code at $%X wrote $%X to PSU at clock %d (frame %d, raster %d)!\n", iar, psu, cycles_2650, frames, cpuy);
        zprintf(TEXTPEN_VERBOSE, "Active axis is now %s!\n", (psu & PSU_F) ? "vertical" : "horizontal");
#endif
        TWO_BYTES;
        NINE_CYCLES;
        if (machine == PIPBUG && tt_scrn == 0 && !(psu & PSU_F))
        {   tt_scrn     = 1;
            tt_scrncode = 0;
            tt_scrntill = cycles_2650 + cpb + (cpb / 2);
        }
        checkinterrupt();
    acase 117:                                              // CPSL
#ifndef GAMER
        if (loginefficient)
        {   if (OPERAND == 0)
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Omit %s at %s.\n\n",
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
            } elif (OPERAND == 0xC0)
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_REPLACE,
                        "Replace %s with %s at %s.\n\n"
                    ),
                    opcodes[style][0x75].name, // CPSL
                    opcodes[style][0xE0].name, // COMZ r0
                    friendly
                );
                set_pause(TYPE_LOG);
        }   }
#endif
        psl &= (~OPERAND);
        TWO_BYTES;
        NINE_CYCLES;
    acase 118:                                              // PPSU
#ifndef GAMER
        if (log_illegal && ((~(psu & 0x07)) & (OPERAND & 0x07)))
        {   getfriendly(iar);
            zprintf(TEXTPEN_LOG, LLL(MSG_MODIFYINGSP, "%s is modifying the SP at %s.\n\n"), opcodes[style][opcode].name, friendly);
            set_pause(TYPE_LOG);
        }

        if (loginefficient)
        {   if
            (   (!supercpu && (OPERAND & PSU_WRITABLE_A) == 0)
             || ( supercpu && (OPERAND & PSU_WRITABLE_B) == 0)
            )
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Omit %s at %s.\n\n",
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
        }   }
#endif

        if (!(psu & PSU_II) && (OPERAND & PSU_II))
        {   interrupt_2650 = FALSE; // any pending interrupts are cleared
#ifndef GAMER
            if (log_interrupts)
            {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSDISABLED, "%s at $%04X (rastline %d): interrupts are now inhibited (disabled).\n\n"), opcodes[style][opcode].name, iar, cpuy);
            }
#endif
        }

        if (supercpu)
        {   psu |= (OPERAND & PSU_WRITABLE_B);
        } else
        {   psu |= (OPERAND & PSU_WRITABLE_A);
        }
#ifdef DEBUGPSU
        zprintf(TEXTPEN_VERBOSE, "Code at $%X wrote $%X to PSU at clock %d (frame %d, raster %d)!\n", iar, psu, cycles_2650, frames, cpuy);
        zprintf(TEXTPEN_VERBOSE, "Active axis is now %s!\n", (psu & PSU_F) ? "vertical" : "horizontal");
#endif
        TWO_BYTES;
        NINE_CYCLES;
        // checkinterrupt() isn't needed as this instruction can only ever inhibit interrupts, not disinhibit them
    acase 119:                                              // PPSL
#ifndef GAMER
        if (loginefficient && OPERAND == 0)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Omit %s at %s.\n\n",
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
        psl |= OPERAND;
#ifndef GAMER
        if (log_illegal && (psl & PSL_CC) == 0xC0)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL
                (   MSG_ENGINE_CCUN,
                    "%s instruction at %s is setting the Condition Code to %11 (UN)!\n\n"
                ),
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
        TWO_BYTES;
        NINE_CYCLES;
    acase 120:                                              // BSNR,r0
        if (readreg(0))
        {   REL_EA();
            ea = mirror_r[ea];
            gosub;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 121:                                              // BSNR,r1
    case 122:                                               // BSNR,r2
    case 123:                                               // BSNR,r3
        GET_RR;
        if (readreg(rr))
        {   REL_EA();
            ea = mirror_r[ea];
            gosub;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 124:                                              // BSNA,r0
        if (readreg(0))
        {   BRA_EA();
            gosub;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 125:                                              // BSNA,r1
    case 126:                                               // BSNA,r2
    case 127:                                               // BSNA,r3
        GET_RR;
        if (readreg(rr))
        {   BRA_EA();
            gosub;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 128:                                              // ADDZ r0
        writereg(0, add(r[0], r[0]));
        ONE_BYTE;
        REG_CYCLES;
    acase 129:                                              // ADDZ r1
    case 130:                                               // ADDZ r2
    case 131:                                               // ADDZ r3
        GET_RR;
        writereg(0, add(r[0], readreg(rr)));
        ONE_BYTE;
        REG_CYCLES;
    acase 132:                                              // ADDI,r0
    case 133:                                               // ADDI,r1
    case 134:                                               // ADDI,r2
    case 135:                                               // ADDI,r3
#ifndef GAMER
        if (loginefficient)
        {   nextopcode = memory[WRAPMEM(2)];
            if (OPERAND == 1 && (nextopcode == 152 || nextopcode == 156)) // BCFR,eq or BCFA,eq
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_REPLACE2,
                        "Replace %s and %s with %s at %s.\n\n"
                    ),
                    opcodes[style][    opcode].name, // ADDI,r0
                    opcodes[style][nextopcode].name, // BCFR,eq or BCFA,eq
                    opcodes[style][opcode - 132 + nextopcode - 152 + 216].name, // BIRR,r0 or BIRA,r0
                    friendly
                );
                set_pause(TYPE_LOG);
            }
            CHECKCOMI(opcode & 3);
        }
#endif
        GET_RR;
        writereg(rr, add(r[rr], OPERAND));
        TWO_BYTES;
        SIX_CYCLES;
    acase 136:                                              // ADDR,r0
        REL_EA();
        writereg(0, add(r[0], cpuread_2650((int) ea)));
        TWO_BYTES;
        NINE_CYCLES;
    acase 137:                                              // ADDR,r1
    case 138:                                               // ADDR,r2
    case 139:                                               // ADDR,r3
        REL_EA();
        GET_RR;
        writereg(rr, add(r[rr], cpuread_2650((int) ea)));
        TWO_BYTES;
        NINE_CYCLES;
    acase 140:                                              // ADDA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 141:                                               // ADDA,r1
    case 142:                                               // ADDA,r2
    case 143:                                               // ADDA,r3
        ABS_EA(); // calls GET_RR for us
        writereg(rr, add(r[rr], cpuread_2650((int) ea)));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 0x90:
    case 0x91:
#ifndef GAMER
        if (log_illegal)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_UNDEFINED,
                    "Instruction at $%04X executed undefined opcode $%02X!\n\n"
                ),
                (int) iar,
                (int) opcode
            );
            set_pause(TYPE_LOG);
        }
#endif
        ONE_BYTE; // tested on Arcadia and Interton
        SIX_CYCLES; // guess
    acase 146:                                              // LPSU
#ifndef GAMER
        if (log_illegal && (r[0] & 0x07) != 0 && (r[0] & 0x07) != (psu & 0x07))
        {   getfriendly(iar);
            zprintf(TEXTPEN_LOG, LLL(MSG_MODIFYINGSP, "%s is modifying the SP at %s.\n\n"), opcodes[style][opcode].name, friendly);
            set_pause(TYPE_LOG);
        }
#endif

        if (!(psu & PSU_II))
        {   if (r[0] & PSU_II)
            {   if (log_interrupts && interrupt_2650)
                {   zprintf(TEXTPEN_LOG, "Cleared pending interrupt!\n");
                }
                interrupt_2650 = FALSE; // any pending interrupts are cleared
                if (log_interrupts)
                {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSDISABLED, "%s at $%04X (rastline %d): interrupts are now inhibited (disabled).\n\n"), opcodes[style][opcode].name, iar, cpuy);
        }   }   }
        else
        {   if (log_interrupts && !(r[0] & PSU_II))
            {   zprintf(TEXTPEN_LOG, LLL(MSG_INTERRUPTSENABLED, "%s at $%04X (rastline %d): interrupts are now disinhibited (enabled). "), opcodes[style][opcode].name, iar, cpuy);
                if (interrupt_2650)
                {   zprintf(TEXTPEN_LOG, LLL(MSG_ANINTERRUPTPENDING, "An interrupt is pending!\n\n"));
                } else
                {   zprintf(TEXTPEN_LOG, LLL(MSG_NOINTERRUPTPENDING, "No interrupt is pending.\n\n"));
        }   }   }

        psu &= 0x80; // clear all except Sense bit
        if (supercpu)
        {   psu |= (readreg(0) & PSU_WRITABLE_B);
        } else
        {   psu |= (readreg(0) & PSU_WRITABLE_A);
        }
#ifdef DEBUGPSU
        zprintf(TEXTPEN_VERBOSE, "Code at $%X wrote $%X to PSU at clock %d (frame %d, raster %d)!\n", iar, psu, cycles_2650, frames, cpuy);
        zprintf(TEXTPEN_VERBOSE, "Active axis is now %s!\n", (psu & PSU_F) ? "vertical" : "horizontal");
#endif
        ONE_BYTE;
        SIX_CYCLES;
        if (machine == PIPBUG && tt_scrn == 0 && !(psu & PSU_F))
        {   tt_scrn     = 1;
            tt_scrncode = 0;
            tt_scrntill = cycles_2650 + cpb + (cpb / 2);
        }
        checkinterrupt();
    acase 147:                                              // LPSL
        psl = readreg(0);
#ifndef GAMER
        if (log_illegal && (psl & PSL_CC) == 0xC0)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL
                (   MSG_ENGINE_CCUN,
                    "%s instruction at %s is setting the Condition Code to %11 (UN)!\n\n"
                ),
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
        ONE_BYTE;
        SIX_CYCLES;
    acase 148:                                              // DAR  r0
        if ((psl & PSL_C) == 0)
        {   // add ten to the tens digit (the high nybble)
            WRITEREGCC(0, r[0] + 0xA0); // 160. overflow OK. %1010,0000
        }
        if ((psl & PSL_IDC) == 0)
        {   // OR the high nybble with the (low nybble + 10)
            WRITEREGCC(0, (r[0] & 0xF0) | ((r[0] + 0x0A) & 0x0F));
        }
        ONE_BYTE;
        NINE_CYCLES;
    acase 149:                                              // DAR  r1
    case 150:                                               // DAR  r2
    case 151:                                               // DAR  r3
        GET_RR;
        if ((psl & PSL_C) == 0)
        {   // add ten to the tens digit (the high nybble)
            WRITEREGCC(rr, r[rr] + 0xA0); // 160. overflow OK. %1010,0000
        }
        if ((psl & PSL_IDC) == 0)
        {   // OR the high nybble with the (low nybble + 10)
            WRITEREGCC(rr, (r[rr] & 0xF0) | ((r[rr] + 0x0A) & 0x0F));
        }
        ONE_BYTE;
        NINE_CYCLES;
    acase 152:                                              // BCFR,eq
    case 153:                                               // BCFR,gt
    case 154:                                               // BCFR,lt
        if (BRANCHCODE != CCFIELD)
        {   REL_EA();
            ea = mirror_r[ea];
#ifndef GAMER
            if (loginefficient && ea == (ULONG) WRAPMEM(2))
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Omit %s at %s.\n\n",
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
            }
#endif
            zgoto;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 155:                                              // ZBRR
        ZERO_EA();
#ifndef GAMER
        checkrelbranch();
#endif
        zgoto;
    acase 156:                                              // BCFA,eq
    case 157:                                               // BCFA,gt
    case 158:                                               // BCFA,lt
        if (BRANCHCODE != CCFIELD)
        {   BRA_EA();
#ifndef GAMER
            if (loginefficient && ea == (ULONG) WRAPMEM(3))
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    "Omit %s at %s.\n\n",
                    opcodes[style][opcode].name,
                    friendly
                );
                set_pause(TYPE_LOG);
            }
#endif
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 159:                                              // BXA,r3
        BRA_EA();
        if (psl & PSL_RS)
        {   ea = (ea + readreg(6)) & AMSK;
        } else
        {   ea = (ea + readreg(3)) & AMSK;
        }
        zgoto;
    acase 160:                                              // SUBZ r0
        // This is just as small and fast as EORZ r0, so we don't log it as inefficient.
        // Also, its effects can be different (eg. borrow can be applied).
        writereg(0, subtract(r[0], r[0])); // not just r[0] = 0; because we need to set PSW bits
        ONE_BYTE;
        REG_CYCLES;
    acase 161:                                              // SUBZ r1
    case 162:                                               // SUBZ r2
    case 163:                                               // SUBZ r3
        GET_RR;
        writereg(0, subtract(r[0], r[rr])); // not just r[0] = 0; because we need to set PSW bits
        ONE_BYTE;
        REG_CYCLES;
    acase 164:                                              // SUBI,r0
    case 165:                                               // SUBI,r1
    case 166:                                               // SUBI,r2
    case 167:                                               // SUBI,r3
#ifndef GAMER
        if (loginefficient)
        {   nextopcode = memory[WRAPMEM(2)];
            if (OPERAND == 1 && (nextopcode == 152 || nextopcode == 156)) // BCFR,eq or BCFA,eq
            {   DISCARD getfriendly(iar);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_REPLACE2,
                        "Replace %s and %s with %s at %s.\n\n"
                    ),
                    opcodes[style][    opcode].name, // SUBI,rn
                    opcodes[style][nextopcode].name, // BCFR,eq or BCFA,eq
                    opcodes[style][opcode - 164 + nextopcode - 152 + 248].name, // BDRR,rn or BDRA,rn
                    friendly
                );
                set_pause(TYPE_LOG);
            }
            CHECKCOMI(opcode & 3);
        }
#endif
        GET_RR;
        writereg(rr, subtract(r[rr], OPERAND));
        TWO_BYTES;
        SIX_CYCLES;
    acase 168:                                              // SUBR,r0
        REL_EA();
        writereg(0, subtract(r[0], cpuread_2650((int) ea)));
        TWO_BYTES;
        NINE_CYCLES;
    acase 169:                                              // SUBR,r1
    case 170:                                               // SUBR,r2
    case 171:                                               // SUBR,r3
        REL_EA();
        GET_RR;
        writereg(rr, subtract(r[rr], cpuread_2650((int) ea)));
        TWO_BYTES;
        NINE_CYCLES;
    acase 172:                                              // SUBA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 173:                                               // SUBA,r1
    case 174:                                               // SUBA,r2
    case 175:                                               // SUBA,r3
        ABS_EA(); // this calls GET_RR for us
        writereg(rr, subtract(r[rr], cpuread_2650((int) ea)));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 176:                                              // WRTC r0
    case 177:                                               // WRTC r1
    case 178:                                               // WRTC r2
    case 179:                                               // WRTC r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        writeport(PORTC, readreg(rr));
        ONE_BYTE; // needed even for Instructor
        SIX_CYCLES;
        if (machine == INSTRUCTOR)
        {   ioport[0xFC].contents = iar % 256;
            ioport[0xFD].contents = iar / 256;
            iar                   = 0x1800;
        }
    acase 180:                                              // TPSU
        psl &= 0x3F; // set CC to %00xxxxxx ("eq")
        if ((psu & OPERAND) < OPERAND)
        {   psl |= 0x80; // set CC to %10xxxxxx ("lt")
        }
        TWO_BYTES;
        NINE_CYCLES;
    acase 181:                                              // TPSL
        psl &= 0x3F; // set CC to %00xxxxxx ("eq")
        if ((psl & OPERAND) < OPERAND)
        {   psl |= 0x80; // set CC to %10xxxxxx ("lt")
        }
        TWO_BYTES;
        NINE_CYCLES;
    acase 184:                                              // BSFR,eq
    case 185:                                               // BSFR,gt
    case 186:                                               // BSFR,lt
        if (BRANCHCODE != CCFIELD)
        {   REL_EA();
            ea = mirror_r[ea];
            gosub;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
        }
    acase 187:                                              // ZBSR
        if (iar == 0x1771 && whichgame == RYTMONPOS)
        {   zprintf(TEXTPEN_RTTY, "%c", readreg(0));
        }
        ZERO_EA();
        gosub;
    acase 188:                                              // BSFA,eq
    case 189:                                               // BSFA,gt
    case 190:                                               // BSFA,lt
        if (BRANCHCODE != CCFIELD)
        {   BRA_EA();
            gosub;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
        }
    acase 191:                                              // BSXA,r3
        BRA_EA();
        if (psl & PSL_RS)
        {   ea = (ea + readreg(6)) & AMSK;
        } else
        {   ea = (ea + readreg(3)) & AMSK;
        }
        gosub;
    acase 192:                                              // NOP
        ONE_BYTE;
#ifndef GAMER
        if (loginefficient)
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Omit %s at %s.\n\n",
                opcodes[style][0xC0].name, // NOP
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
        REG_CYCLES;
    acase 193:                                              // STRZ r1
    case 194:                                               // STRZ r2
        GET_RR;
        WRITEREGCC(rr, readreg(0));
        ONE_BYTE;
        REG_CYCLES;
    acase 195:                                              // STRZ r3
        GET_RR;
        WRITEREGCC(rr, readreg(0));
        if
        (   (whichgame == SI50_THEMEPOS   && iar ==   0x1F)
         || (whichgame == PHUNSY_THEMEPOS && iar == 0x1819)
        )
        {   playsound(FALSE);
        }
        ONE_BYTE;
        REG_CYCLES;
    acase 200:                                              // STRR,r0
        REL_EA();
        cpuwrite_2650((int) ea, readreg(0));
        TWO_BYTES;
        NINE_CYCLES;
    acase 201:                                              // STRR,r1
    case 202:                                               // STRR,r2
    case 203:                                               // STRR,r3
        REL_EA();
        GET_RR;
        cpuwrite_2650((int) ea, readreg(rr));
        TWO_BYTES;
        NINE_CYCLES;
    acase 204:                                              // STRA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    //lint -fallthrough
    case 205:                                               // STRA,r1
    case 206:                                               // STRA,r2
    case 207:                                               // STRA,r3
        ABS_EA(); // this calls GET_RR for us
        cpuwrite_2650((int) ea, readreg(rr));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 208:                                              // RRL,r0
    case 209:                                               // RRL,r1
    case 210:                                               // RRL,r2
    case 211:                                               // RRL,r3
        GET_RR;
        if
        (   machine == PHUNSY
         && opcode == 208 // rrl,r0
         && (   (whichgame == BELMACHPOS  && iar == 0x182A)
             || (whichgame == BELMACH0POS && iar == 0x303A)
        )   )
        {   playsound(FALSE);
        }
        before = r[rr];
        after = (before & 0x7F) << 1;
        if (psl & PSL_WC)
        {   if (psl & PSL_C)
            {   after |= 1;
            }
            writereg(rr, after);
            psl &= 0x1A; // ccdR,WoMc, Clear CC, IDC, OVF, C; preserve RS, WC, COM
            if (before & 0x80)
            {   psl |= PSL_C;
            }
            if (after & 0x20)
            {   psl |= PSL_IDC;
            }
            if ((before & 0x80) != (after & 0x80) && (before <= 0x7F || before >= 0xC0))
            {   psl |= PSL_OVF;
        }   }
        else
        {   if (before & 0x80)
            {   after |= 1;
            }
            writereg(rr, after);
            psl &= 0x3F; // ccDRWOMC. Clear CC; preserve IDC, RS, WC, OVF, COM, C (OVF & C bit preservation confirmed on real machine)
        }
        if (r[rr] >= 128)
        {   psl |= 0x80; // CC = %10 (LT)
        } elif (r[rr] > 0)
        {   psl |= 0x40; // CC = %01 (GT)
        }
        ONE_BYTE;
        SIX_CYCLES;
    acase 212:                                              // WRTE r0
    case 213:                                               // WRTE r1
    case 214:                                               // WRTE r2
    case 215:                                               // WRTE r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        writeport(OPERAND, readreg(rr));
        TWO_BYTES;
        NINE_CYCLES;
    acase 216:                                              // BIRR,r0
    case 217:                                               // BIRR,r1
    case 218:                                               // BIRR,r2
    case 219:                                               // BIRR,r3
        GET_RR;
        writereg(rr, (UBYTE) (r[rr] + 1)); // overflow is OK
        if (r[rr])
        {   REL_EA();
            ea = mirror_r[ea];
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 220:                                              // BIRA,r0
    case 221:                                               // BIRA,r1
    case 222:                                               // BIRA,r2
    case 223:                                               // BIRA,r3
        GET_RR;
        writereg(rr, (UBYTE) (r[rr] + 1)); // overflow is OK
        if (r[rr])
        {   BRA_EA();
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 224:                                              // COMZ r0
        psl &= ~(PSL_CC); // clear CC bits of PSL
        ONE_BYTE;
        REG_CYCLES;
    acase 225:                                              // COMZ r1
    case 226:                                               // COMZ r2
    case 227:                                               // COMZ r3
        GET_RR;
        compare(readreg(0), readreg(rr));
        ONE_BYTE;
        REG_CYCLES;
    acase 228:                                              // COMI,r0
        compare(readreg(0), OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 229:                                              // COMI,r1
    case 230:                                               // COMI,r2
    case 231:                                               // COMI,r3
        GET_RR;
        compare(readreg(rr), OPERAND);
        TWO_BYTES;
        SIX_CYCLES;
    acase 232:                                              // COMR,r0
        REL_EA();
        compare(readreg(0), cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 233:                                              // COMR,r1
    case 234:                                               // COMR,r2
    case 235:                                               // COMR,r3
        REL_EA();
        GET_RR;
        compare(readreg(rr), cpuread_2650((int) ea));
        TWO_BYTES;
        NINE_CYCLES;
    acase 236:                                              // COMA,r0
#ifndef GAMER
        if (log_illegal && (OPERAND & 0x60)) // indexed
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(MSG_OPERANDANDINDEX, "%s is used as an operand and index for %s at %s.\n\n"),
                flagname[NAME_R0].shorter[style],
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        }
    //lint -fallthrough
#endif
    case 237:                                               // COMA,r1
    case 238:                                               // COMA,r2
    case 239:                                               // COMA,r3
        ABS_EA(); // this calls GET_RR for us
        compare(readreg(rr), cpuread_2650((int) ea));
        if (OPERAND & 0x80)
        {   EIGHTEEN_CYCLES;
        } else
        {   TWELVE_CYCLES;
        }
        THREE_BYTES;
    acase 240:                                              // WRTD r0
    case 241:                                               // WRTD r1
    case 242:                                               // WRTD r2
    case 243:                                               // WRTD r3
#ifndef GAMER
        if (log_illegal && machine == ARCADIA)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_STRANGE,
                    "Instruction at $%X executed strange opcode"
                ),
                (long unsigned int) iar
            );
            zprintf
            (   TEXTPEN_LOG,
                " %s!\n\n",
                opcodes[style][opcode].name
            );
        }
#endif
        GET_RR;
        writeport(PORTD, readreg(rr));
        ONE_BYTE;
        SIX_CYCLES;
    acase 244:                                              // TMI,r0
        psl &= 0x3F; // set CC to %00 ("eq")
        if ((readreg(0) & OPERAND) < OPERAND)
        {   psl |= 0x80; // set CC to %10 ("lt")
        }
        TWO_BYTES;
        NINE_CYCLES;
    acase 245:                                              // TMI,r1
    case 246:                                               // TMI,r2
    case 247:                                               // TMI,r3
        GET_RR;
        psl &= 0x3F; // set CC to %00 ("eq")
        if ((readreg(rr) & OPERAND) < OPERAND)
        {   psl |= 0x80; // set CC to %10 ("lt")
        }
        TWO_BYTES;
        NINE_CYCLES;
    acase 248:                                              // BDRR,r0
    case 249:                                               // BDRR,r1
    case 250:                                               // BDRR,r2
    case 251:                                               // BDRR,r3
        GET_RR;
        writereg(rr, (UBYTE) (r[rr] - 1)); // underflow is OK
        if (r[rr])
        {   REL_EA();
            ea = mirror_r[ea];
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   TWO_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 252:                                              // BDRA,r0
    case 253:                                               // BDRA,r1
    case 254:                                               // BDRA,r2
    case 255:                                               // BDRA,r3
        GET_RR;
        writereg(rr, (UBYTE) (r[rr] - 1)); // underflow is OK
        if (r[rr])
        {   BRA_EA();
#ifndef GAMER
            coverage[ea ] |= COVERAGE_LOOPSTART;
            coverage[iar] |= COVERAGE_LOOPEND;
#endif
            zgoto;
        } else
        {   THREE_BYTES;
            NINE_CYCLES;
            RUNTOLOOPEND;
        }
    acase 0xB6:
    case 0xB7:
    case 0xC4:
    case 0xC5:
    case 0xC6:
    case 0xC7:
#ifndef GAMER
        if (log_illegal)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_UNDEFINED,
                    "Instruction at $%04X executed undefined opcode $%02X!\n\n"
                ),
                (int) iar,
                (int) opcode
            );
            set_pause(TYPE_LOG);
        }
#endif
        TWO_BYTES; // tested on Arcadia and Interton
        SIX_CYCLES; // guess
}   }

// SUPPORT FUNCTIONS------------------------------------------------------

MODULE __inline void set_cc(UBYTE n) // set CC
{   psl &= ~(PSL_CC); // clear CC bits of PSL

    if (n >= 128)
    {   psl |= 0x80; // CC = %10
    } elif (n > 0)
    {   psl |= 0x40; // CC = %01
}   }

EXPORT void pushras(void)
{   FAST int i,
             sp;

    // store address
    ras[psu & PSU_SP] = (iar & PAGE) + ((iar + table_size_2650[opcode]) & NONPAGE);

    if (logsubroutines)
    {   sp = (psu & PSU_SP);
        // zprintf(TEXTPEN_LOG, "%d: ", sp);
        if (sp)
        {   for (i = 0; i < sp; i++)
            {   zprintf(TEXTPEN_LOG, " ");
        }   }
        DISCARD getfriendly(ea);
        zprintf
        (   TEXTPEN_LOG,
            LLL(
                MSG_CPU_CALLING,
                "Calling subroutine %s from $%X...\n\n"
            ),
            friendly,
            iar
        );
        set_pause(TYPE_LOG);
    }

    // increment SP
    if ((psu & PSU_SP) == 7) // overflow
    {   psu &= ~(PSU_SP); // set SP to 0

        if (log_illegal || logsubroutines)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_SUBROUTINEOVERFLOW,
                    "Stack overflow at $%X!\n\n"
                ),
                (unsigned int) iar
            );
            set_pause(TYPE_LOG);
    }   }
    else
    {   psu++;
}   }

EXPORT void pullras(void)
{   FAST int i,
             sp;

    // decrement SP
    if ((psu & PSU_SP) == 0) // underflow
    {   psu |= PSU_SP; // set SP to 7

        if (log_illegal || logsubroutines)
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_UNDERFLOW,
                    "Stack underflow at $%X!\n\n"
                ),
                (unsigned int) iar
            );
            set_pause(TYPE_LOG);
    }   }
    else psu--;

    if (logsubroutines)
    {   // if psu & PSU_SP is used instead of sp, this doesn't indent properly! (Visual C++ bug?)
        sp = psu & PSU_SP;
        // zprintf(TEXTPEN_LOG, "%d: ", sp);
        if (sp)
        {   for (i = 0; i < sp; i++)
            {   zprintf(TEXTPEN_LOG, " ");
        }   }
        zprintf
        (   TEXTPEN_LOG,
            LLL(
                MSG_CPU_RETURNING,
                "Returning to $%X from subroutine or interrupt at $%X.\n\n"
            ),
            ras[psu & PSU_SP],
            (unsigned int) iar // should use friendly instead
        );
        set_pause(TYPE_LOG);
    }

    oldiar = iar;
    iar = ras[psu & PSU_SP];

    if ((psu & PSU_SP) == ininterrupt)
    {   ininterrupt = 8;
}   }

MODULE __inline void branch(int indirect)
{   /* page 0 is $0000..$1FFF
       page 1 is $2000..$3FFF
       page 2 is $4000..$5FFF
       page 3 is $6000..$7FFF
    ippaaaaa aaaaaaaa
    i = indirect flag
    p = page
    a = address on page */

    if
    (   machine != INSTRUCTOR
     && (machine != CD2650 || cd2650_dosver != DOS_P1DOS || cd2650_biosver != CD2650_IPL)
     && logbios
     && !trace
     && (memflags[ea] & BIOS)
     && (   !(memflags[iar] & BIOS) // we don't log the monitor calling itself
         || (machine == PIPBUG && pipbug_biosver == PIPBUG_PIPBUG2BIOS && iar >= 0x3 && iar <= 0x15) // zero page vector table
    )   )
    {   DISCARD getfriendly(ea);
        zprintf
        (   TEXTPEN_LOG,
            LLL(
                MSG_CPU_LOGMONITOR,
                "BIOS code at %s was called by game code at $%X.\n"
            ),
            friendly,
            (unsigned int) iar
        );
        switch (machine)
        {
        case  ELEKTOR:             elektor_biosdetails(ea);
        acase PIPBUG: case BINBUG: pipbin_biosdetails(ea);
        acase CD2650:              cd2650_biosdetails1(ea);
        acase PHUNSY:              phunsy_biosdetails(ea);
        acase SELBST:              selbst_biosdetails(ea);
        acase TWIN:                twin_biosdetails(ea);
        }
        zprintf(TEXTPEN_LOG, "\n");
        set_pause(TYPE_LOG);
    }
    iar = (UWORD) ea;
    if (indirect)
    {   FIFTEEN_CYCLES;
    } else
    {   NINE_CYCLES;
}   }

MODULE void compare(UBYTE first, UBYTE second)
{   int d;

    psl &= 0x3F; // clear CC
    if (psl & PSL_COM) // unsigned compare
    {   d = (UBYTE) first - (UBYTE) second;
    } else
    {   d = (SBYTE) first - (SBYTE) second;
    }
    if (d < 0)
    {   psl |= 0x80; // %10 = lt
    } elif (d > 0)
    {   psl |= 0x40; // %01 = gt
}   }

// Add source to destination
MODULE UBYTE add(UBYTE dest, UBYTE source)
{   FAST UBYTE dest_nybble;
    FAST int   dest_int;

    before      =   dest;
    dest_int    =   (int) before + (int) source;
    dest_nybble =  (before & 0x0F) + (source & 0x0F); // "overflow" (>= 16) is OK
    dest        +=  source; // overflow is OK
    if ((psl & PSL_WC) && (psl & PSL_C))
    {   dest++; // overflow is OK
        dest_nybble++; // "overflow" (>= 16) is OK
        dest_int++;
    }
    psl &= 0x1A; // ccdR,WoMc. Clear CC, IDC, OVF, C; preserve RS, WC, COM (OVF behaviour confirmed on real machine)
    if (dest_int >= 256)
    {   psl |= PSL_C; // means a carry was generated
    }
    if (dest_nybble >= 16)
    {   psl |= PSL_IDC;
    }
    if ((before & 0x80) == (source & 0x80) && (before & 0x80) != (dest & 0x80))
    {   psl |= PSL_OVF;
    }
    if (dest >= 128)
    {   psl |= 0x80; // CC = %10 (LT)
    } elif (dest > 0)
    {   psl |= 0x40; // CC = %01 (GT)
    }

    return dest;
}

// Subtract source (subtrahend) from destination (minuend)
MODULE UBYTE subtract(UBYTE dest, UBYTE source)
{   FAST SBYTE dest_nybble;
    FAST int   dest_int;

    before      =   dest;
    dest_int    =   (int) before - (int) source;
    dest_nybble =  (before & 0x0F) - (source & 0x0F);
    dest        -= source; // underflow is OK
    if ((psl & PSL_WC) && !(psl & PSL_C))
    {   dest--; // underflow is OK
        dest_nybble--;
        dest_int--;
    }
    psl &= 0x1A; // ccdR,WoMc, Clear CC, IDC, OVF, C; preserve RS, WC, COM (OVF behaviour confirmed on real machine)
    if (dest_int >= 0)
    {   psl |= PSL_C;   // means a borrow was *not* generated
    }
    if (dest_nybble >= 0)
    {   psl |= PSL_IDC; // means a borrow was *not* generated
    }
    if ((before & 0x80) != (source & 0x80) && (before & 0x80) != (dest & 0x80))
    {   psl |= PSL_OVF;
    }
    if (dest >= 128)
    {   psl |= 0x80; // CC = %10
    } elif (dest > 0)
    {   psl |= 0x40; // CC = %01
    }

    return dest;
}

/* ABS_EA(), etc. don't use cpuread_2650(), because they simply calculate an
   address (ie. a number), they don't actually look at the contents of
   that address. */

// ** build effective address with absolute addressing (non-branch) **
// called by LODA, EORA, ANDA, IORA, SUBA, ADDA, STRA, COMA
// ABS_EA() uses GET_RR; the others don't!
MODULE void ABS_EA(void)
{   /* build effective address within current 8K page */

    OPERAND = memory[WRAPMEM(1)];
    ea = (iar & PAGE) + (((OPERAND << 8) + memory[WRAPMEM(2)]) & NONPAGE);
    GET_RR;
    if
    (   loginefficient
     && (OPERAND & 0x60) == 0x00 // non-indexed
     && (int) ea >= WRAPMEM(2 - 64)
     && (int) ea <= WRAPMEM(2 + 63)
    )
    {   DISCARD getfriendly(iar);
        zprintf
        (   TEXTPEN_LOG,
            LLL(
                MSG_CPU_REPLACE,
                "Replace %s with %s at %s.\n\n"
            ),
            opcodes[style][opcode    ].name, // LODA/EORA/ANDA/IORA/ADDA/SUBA/STRA/COMA
            opcodes[style][opcode - 4].name, // LODR/EORR/ANDR/IORR/ADDR/SUBR/STRR/COMR
            friendly
        );
        set_pause(TYPE_LOG);
    }

    if (OPERAND & 0x80) /* indirect addressing? */
    {   addr = (int) mirror_r[ea]; // needed for eg. Interton BOWLING, etc.
        coverage[addr] |= COVERAGE_ADDRESS;
        /* build indirect 32K address */
        ea = memory[addr] << 8;
        if ((++addr & NONPAGE) == 0)
        {   addr -= PLEN; /* page wrap */
        }
        ea = (ea + memory[addr]) & AMSK;
        coverage[addr] |= COVERAGE_ADDRESS;
    }

    /* check indexed addressing modes */
    switch (OPERAND & 0x60)
    {
    case 0x20: /* auto increment indexed */
        r[rr]++;
        ea = (ea & PAGE) + ((ea + r[rr]) & NONPAGE);
        rr = 0; /* absolute addressing reg is R0 */
    acase 0x40: /* auto decrement indexed */
        r[rr]--;
        ea = (ea & PAGE) + ((ea + r[rr]) & NONPAGE);
        rr = 0; /* absolute addressing reg is R0 */
    acase 0x60: /* indexed */
        ea = (ea & PAGE) + ((ea + r[rr]) & NONPAGE);
        rr = 0; /* absolute addressing reg is R0 */
 // adefault: // eg. $00 (not indexed)
}   }

// ** build effective address with absolute addressing (branch) **
// called by BCTA, BRNA, BCFA, BIRA, BDRA, BXA, BSXA, BSTA, BSNA, BSFA
MODULE void BRA_EA(void)
{   /* build address in 32K address space */

    OPERAND = memory[WRAPMEM(1)];
    ea = ((OPERAND << 8) + memory[WRAPMEM(2)]) & AMSK;
    if (loginefficient)
    {   if
        (   ((ea & 0x1FFF) <=   63 || (ea & 0x1FFF) >= 0x1F80) // zero page
         && (opcode        == 0x1F || opcode        ==   0x3F) // BCTA,un or BSTA,un
        )
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_REPLACE,
                    "Replace %s with %s at %s.\n\n"
                ),
                opcodes[style][opcode       ].name, // BCTA,un/BSTA,un
                opcodes[style][opcode + 0x7C].name, // ZBRR,un/ZBSR,un
                friendly
            );
            set_pause(TYPE_LOG);
        } elif ((int) ea >= WRAPMEM(2 - 64) && (int) ea <= WRAPMEM(2 + 63))
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_REPLACE,
                    "Replace %s with %s at %s.\n\n"
                ),
                opcodes[style][opcode    ].name, // BCTA/BSTA/BRNA/BSNA/BIRA/BDRA/BCFA/BSFA
                opcodes[style][opcode - 4].name, // BCTR/BSTR/BRNR/BSNR/BIRR/BDRR/BCFR/BSFR
                friendly
            );
            set_pause(TYPE_LOG);
    }   }
    ea = mirror_r[ea]; // all branches are considered to be reads

    if (OPERAND & 0x80) // indirect addressing?
    {   addr = (int) ea;
        coverage[addr] |= COVERAGE_ADDRESS;
        logindirectbios();
        /* build indirect 32K address */
        ea = memory[addr] << 8;
        if ((++addr & NONPAGE) == 0)
        {   addr -= PLEN; /* page wrap */
        }
        coverage[addr] |= COVERAGE_ADDRESS;
        ea = (ea + memory[addr]) & AMSK;
        ea = mirror_r[ea]; // needed for eg. Spider's Web
}   }

// ** build effective add ress with relative addressing **
// called by LODR, BCTR, BSTR, EORR, ANDR, BRNR, IORR, BSNR, ADDR,
// BCFR, SUBR, BSFR, STRR, BIRR, COMR, BDRR
MODULE void REL_EA(void)
{   /* build effective address within current 8K page */

    OPERAND = memory[WRAPMEM(1)];
    ea = (iar & PAGE) + ((iar + 2 + relative_2650[OPERAND]) & NONPAGE);

/* Mirroring is not done here.
For relative branch instructions, mirroring is handled by the calling
routine (after calling this routine).
  For relative non-branch instructions, mirroring is handled by cpuread_2650().
*/

    if (OPERAND & 0x80) /* indirect bit set? */
    {   addr = (int) ea;
        coverage[addr] |= COVERAGE_ADDRESS;
        logindirectbios();
        /* build indirect 32K address */
        ea = memory[addr] << 8;
        if ((++addr & NONPAGE) == 0)
        {   addr -= PLEN; /* page wrap */
        }
        coverage[addr] |= COVERAGE_ADDRESS;
        ea = (ea + memory[addr]) & AMSK;
}   }

// ** build effective address with zero relative addressing **
// called by ZBRR, ZBSR
MODULE void ZERO_EA(void)
{   /* build effective address from 0 */

    OPERAND = memory[WRAPMEM(1)];
    ea = (relative_2650[OPERAND] & NONPAGE);
    // ea = mirror_r[ea]; // all branches are considered to be reads
    // not really necessary, as there is no mirroring done of $0000..$007F
    // nor $7F80..$7FFF.

    if (OPERAND & 0x80) // indirect bit set?
    {   addr = (int) ea;
        coverage[addr] |= COVERAGE_ADDRESS;
        // we are making an assumption that the USE monitor switches to the
        // main register bank when these functions are called; this assumption is
        // probably not true.
        logindirectbios();
        /* build indirect 32K address */
        ea = memory[addr] << 8;
        if ((++addr & NONPAGE) == 0)
        {   addr -= PLEN; /* page wrap */
        }
        coverage[addr] |= COVERAGE_ADDRESS;
        ea = (ea + memory[addr]) & AMSK;
}   }

#ifndef GAMER
MODULE void do_runtoloopend(void)
{   DISCARD getfriendly(iar);
    zprintf
    (   TEXTPEN_DEBUG,
        LLL(
            MSG_CPU_REACHEDLOOPEND,
            "Reached end of loop at %s.\n\n"
        ),
        friendly
    );
    set_pause(TYPE_RUNTO);
}

MODULE void logiar(void)
{   DISCARD getfriendly(oldiar);
    zprintf
    (   TEXTPEN_LOG,
        LLL(
            MSG_WRAPPED,
            "IAR has wrapped after instruction at %s (%u %s)!\n\n"
        ),
        friendly,
        scale_time(cycles_2650),
        timeunitstr2
    );
}
#endif

EXPORT void checkinterrupt(void)
{   FAST int   i,
               intlevel;
#ifndef GAMER
    FAST UBYTE sp;
#endif

    if (interrupt_2650 && !(psu & PSU_II))
    {   if (machine == TWIN)
        {   // choose the lowest-numbered (most important) interrupt to service first
            intlevel = 32;
            for (i = 0; i < 32; i++)
            {   if
                (   priflag[i]
#ifdef EMULATEKEYBOARD
                 && ((i !=  4 && i != 5) || (ioport[0xE9].contents & CRT_TTY ))
#endif
                 && ( i != 10            || (ioport[0xEA].contents & PRT_INT ))
                 && ( i != 11            || (ioport[0xEA].contents & DISK_INT))
                )
                {   priflag[i] = FALSE;
                    intlevel = i;
                    break;
            }   }
            if (intlevel == 32)
            {   return;
        }   }

#ifndef GAMER
        if (trace || runtointerrupt || logsubroutines || log_interrupts)
        {   if (logsubroutines)
            {   sp = (psu & PSU_SP);
                // zprintf(TEXTPEN_TRACE, "%d: ", sp);
                if (sp)
                {   for (i = 0; i < (int) sp; i++)
                    {   zprintf(TEXTPEN_TRACE, " ");
                }   }
                set_pause(TYPE_LOG);
            }
            if (logsubroutines || log_interrupts)
            {   set_pause(TYPE_LOG);
            }

            if (machine == TWIN)
            {   zprintf
                (   TEXTPEN_LOG,
                    LLL
                    (   MSG_CPU_INTERRUPTPRI,
                        "Generated interrupt of priority %d (%s) at %u %s.\n"
                    ),
                    intlevel,
                    pristring[intlevel],
                    scale_time(cycles_2650),
                    timeunitstr2
                );
            } else
            {   zprintf
                (   TEXTPEN_LOG,
                    LLL
                    (   MSG_CPU_INTERRUPT,
                        "Handling interrupt at rastline %d (%u %s). Interrupts are now inhibited (disabled).\n"
                    ),
                    cpuy,
                    scale_time(cycles_2650),
                    timeunitstr2
                );
                if (!log_interrupts)
                {   zprintf(TEXTPEN_LOG, "\n");
            }   }
            if (runtointerrupt)
            {   set_pause(TYPE_RUNTO);
        }   }

        if (machine == TWIN && logbios && intlevel >= 16 && intlevel <= 21) // SVC
        {   view_svc(intlevel - 15);
        }
#endif

        oldpsu = psu;
        oldpsl = psl;
        for (i = 0; i < 7; i++)
        {   oldr[i] = r[i];
        }
        // We could also check for corruption of the Return Address Stack

        halted = FALSE;
        psu |= PSU_II; // set II bit (PSU |= %00100000)
        ras[psu & PSU_SP] = iar;
        ininterrupt = (psu & PSU_SP);
        switch (machine)
        {
        case INTERTON:
        case ELEKTOR:
        case MALZAK:
            ea = 0x0003;
        acase ZACCARIA:
            if (memmap == MEMMAP_ASTROWARS || memmap == MEMMAP_GALAXIA)
            {   ea = 0x0003;
            } else
            {   // assert(memmap == MEMMAP_LASERBATTLE || memmap == MEMMAP_LAZARIAN);
                ea = 0x000A;
            }
        acase INSTRUCTOR:
            if (s_id == INTDIR_DIRECT)
            {   ea = 0x0007;
            } else
            {   // assert(s_id == INTERRUPTS_INDIRECT);
                /* Is it allowed for the address at $0007..$0008 to refer
                to pages 1..3, or only page 0?
                We don't allow it, but perhaps it is allowed:
                "This instruction causes the processor to clear address
                bits #13 and #14, the page address bits." But at what
                point are they cleared? */
#ifndef GAMER
                coverage[7] |= COVERAGE_ADDRESS;
#endif
                // "Interrupts always drive the processor to page zero." - S2650 CPU manual
                ea = ((memory[7] * 256) + memory[8]) & NONPAGE;
                // we should probably direct this through the mirroring subsystem
            }
        acase TWIN:
            ea = intlevel * 2;
        acase PHUNSY:
            if (phunsy_biosver == PHUNSY_PHUNSY)
            {   ea = 0x1D;
            } else
            {   // assert(phunsy_biosver == PHUNSY_MINIMONITOR);
                if   (keys_column[5] & 1) ea =      0; // Reset key
                elif (keys_column[5] & 2) ea = 0x1FEC; // Halt  key
                elif (keys_column[5] & 4) ea = ((memory[0x1FF8] * 256) + memory[0x1FF9]) & NONPAGE; // resolves to $1E3D (DUMPCASS)
                elif (keys_column[5] & 8) ea = ((memory[0x1FF6] * 256) + memory[0x1FF7]) & NONPAGE; // resolves to $1EDD (LOADCASS)
                else                      ea = ((memory[0x1FF4] * 256) + memory[0x1FF5]) & NONPAGE; // resolves to $1F3F (KEYBOARD)
            }
     /* adefault:
            interrupts aren't supported (nor used on the real machine, presumably)
            for ARCADIA, PIPBUG, CD2650.
            They are used by the BINBUG DOSes but we don't emulate them yet */
        }

        // increment SP
        if ((psu & PSU_SP) == 7) // overflow
        {   psu &= ~(PSU_SP); // set SP to 0

            if (log_illegal || log_interrupts)
            {   zprintf
                (   TEXTPEN_LOG,
                    LLL(
                        MSG_CPU_INTERRUPTOVERFLOW,
                        "Interrupt has caused a stack overflow!\n\n"
                )   );
                set_pause(TYPE_LOG);
        }   }
        else
        {   psu++;
        }
        branch(machine == INSTRUCTOR && s_id == INTDIR_INDIRECT);
        interrupt_2650 = FALSE;
}   }

MODULE UBYTE cpuread_2650(int address)
{   FAST FLAG  printed;
    FAST UBYTE t;

    /* assert(address <= 32767);

    Reads to memory from the UVI/PVI do not go through this routine.
    Strictly speaking, we should use this routine for ALL CPU read
    accesses, eg. reading opcodes/operands, relative addresses, etc.
    Currently, we only use it for absolute accesses: LODA, STRA, etc.

    Testing on an authentic Emerson Arcadia 2001 console has been
    undertaken to make the read/write property emulation as accurate as
    possible. However, this has not occurred for the Interton VC 4000.

    Reads of read-once registers, even if it is the second or later read,
    are not logged as illegal reads.

    Reads of unused ROM areas (eg. $0800..$0FFF for 2K ROMs) are not
    logged as illegal reads. */

#ifdef GAMER
    address = (int) mirror_r[address];
#else
    coverage[address] |= COVERAGE_READ;

    if (mirror_r[address] != address)
    {   if (logreadwrites && mirror_r[address] != address)
        {   DISCARD getfriendly((int) mirror_r[address]);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_ENGINE_READMIRROR,
                    "Instruction at $%X (raster %d) read from mirrored address $%X (resolves to %s)!\n\n"
                ),
                (unsigned int) iar,
                (long int)     cpuy,
                (unsigned int) address,
                               friendly
            );
            set_pause(TYPE_LOG);
        }
        address = (int) mirror_r[address];
        coverage[address] |= COVERAGE_READ;
    }

    if (log_illegal && (machine == ARCADIA || machine == INTERTON) && !(coverage[address] & COVERAGE_WRITE) && !(memflags[address] & NOWRITE))
    {    getfriendly((int) address);
         zprintf(TEXTPEN_LOG, "Uninitialized byte at %s has been read by code at $%X!\n\n", friendly, iar);
         set_pause(TYPE_LOG);
    }

    if (!(memflags[address] & SPECIALREAD))
    {   return memory[address];
    }

    if (memflags[address] & ASIC)
    {   if (machine == ARCADIA)
        {   switch (address)
            {
            case  A_SPRITE0Y:        asicreads[iar] |= ASIC_UVI_SPRITE0Y;
            acase A_SPRITE0X:        asicreads[iar] |= ASIC_UVI_SPRITE0X;
            acase A_SPRITE1Y:        asicreads[iar] |= ASIC_UVI_SPRITE1Y;
            acase A_SPRITE1X:        asicreads[iar] |= ASIC_UVI_SPRITE1X;
            acase A_SPRITE2Y:        asicreads[iar] |= ASIC_UVI_SPRITE2Y;
            acase A_SPRITE2X:        asicreads[iar] |= ASIC_UVI_SPRITE2X;
            acase A_SPRITE3Y:        asicreads[iar] |= ASIC_UVI_SPRITE3Y;
            acase A_SPRITE3X:        asicreads[iar] |= ASIC_UVI_SPRITE3X;
            acase A_VSCROLL:         asicreads[iar] |= ASIC_UVI_VSCROLL;
            acase A_PITCH:           asicreads[iar] |= ASIC_UVI_PITCH;
            acase A_VOLUME:          asicreads[iar] |= ASIC_UVI_VOLUME;
            acase A_CHARLINE:        asicreads[iar] |= ASIC_UVI_CHARLINE;
            acase A_P1LEFTKEYS:      asicreads[iar] |= ASIC_UVI_P1LEFTKEYS;
            acase A_P1MIDDLEKEYS:    asicreads[iar] |= ASIC_UVI_P1MIDDLEKEYS;
            acase A_P1RIGHTKEYS:     asicreads[iar] |= ASIC_UVI_P1RIGHTKEYS;
            acase A_P1PALLADIUM:     asicreads[iar] |= ASIC_UVI_P1PALLADIUM;
            acase A_P2LEFTKEYS:      asicreads[iar] |= ASIC_UVI_P2LEFTKEYS;
            acase A_P2MIDDLEKEYS:    asicreads[iar] |= ASIC_UVI_P2MIDDLEKEYS;
            acase A_P2RIGHTKEYS:     asicreads[iar] |= ASIC_UVI_P2RIGHTKEYS;
            acase A_P2PALLADIUM:     asicreads[iar] |= ASIC_UVI_P2PALLADIUM;
            acase A_CONSOLE:         asicreads[iar] |= ASIC_UVI_CONSOLE;
            acase A_GFXMODE:         asicreads[iar] |= ASIC_UVI_GFXMODE;
            acase A_BGCOLOUR:        asicreads[iar] |= ASIC_UVI_BGCOLOUR;
            acase A_SPRITES23CTRL:   asicreads[iar] |= ASIC_UVI_SPRITES23CTRL;
            acase A_SPRITES01CTRL:   asicreads[iar] |= ASIC_UVI_SPRITES01CTRL;
            acase A_BGCOLLIDE:       asicreads[iar] |= ASIC_UVI_BGCOLLIDE;
            acase A_SPRITECOLLIDE:   asicreads[iar] |= ASIC_UVI_SPRITECOLLIDE;
            acase A_P2PADDLE:        asicreads[iar] |= ASIC_UVI_P2PADDLE;
            acase A_P1PADDLE:        asicreads[iar] |= ASIC_UVI_P1PADDLE;
        }   }
        else
        {   // assert(machines[machine].pvis);
            switch (address - pvibase)
            {
            case  PVI_SPRITE0AX    : asicreads[iar] |= ASIC_PVI_SPRITE0AX;
            acase PVI_SPRITE0BX    : asicreads[iar] |= ASIC_PVI_SPRITE0BX;
            acase PVI_SPRITE0AY    : asicreads[iar] |= ASIC_PVI_SPRITE0AY;
            acase PVI_SPRITE0BY    : asicreads[iar] |= ASIC_PVI_SPRITE0BY;
            acase PVI_SPRITE1AX    : asicreads[iar] |= ASIC_PVI_SPRITE1AX;
            acase PVI_SPRITE1BX    : asicreads[iar] |= ASIC_PVI_SPRITE1BX;
            acase PVI_SPRITE1AY    : asicreads[iar] |= ASIC_PVI_SPRITE1AY;
            acase PVI_SPRITE1BY    : asicreads[iar] |= ASIC_PVI_SPRITE1BY;
            acase PVI_SPRITE2AX    : asicreads[iar] |= ASIC_PVI_SPRITE2AX;
            acase PVI_SPRITE2BX    : asicreads[iar] |= ASIC_PVI_SPRITE2BX;
            acase PVI_SPRITE2AY    : asicreads[iar] |= ASIC_PVI_SPRITE2AY;
            acase PVI_SPRITE2BY    : asicreads[iar] |= ASIC_PVI_SPRITE2BY;
            acase PVI_SPRITE3AX    : asicreads[iar] |= ASIC_PVI_SPRITE3AX;
            acase PVI_SPRITE3BX    : asicreads[iar] |= ASIC_PVI_SPRITE3BX;
            acase PVI_SPRITE3AY    : asicreads[iar] |= ASIC_PVI_SPRITE3AY;
            acase PVI_SPRITE3BY    : asicreads[iar] |= ASIC_PVI_SPRITE3BY;
            acase PVI_SIZES        : asicreads[iar] |= ASIC_PVI_SIZES;
            acase PVI_SPR01COLOURS : asicreads[iar] |= ASIC_PVI_SPR01COLOURS;
            acase PVI_SPR23COLOURS : asicreads[iar] |= ASIC_PVI_SPR23COLOURS;
            acase PVI_SCORECTRL    : asicreads[iar] |= ASIC_PVI_SCORECTRL;
            acase PVI_BGCOLOUR     : asicreads[iar] |= ASIC_PVI_BGCOLOUR;
            acase PVI_PITCH        : asicreads[iar] |= ASIC_PVI_PITCH;
            acase PVI_SCORELT      : asicreads[iar] |= ASIC_PVI_SCORELT;
            acase PVI_SCORERT      : asicreads[iar] |= ASIC_PVI_SCORERT;
            acase PVI_BGCOLLIDE    : asicreads[iar] |= ASIC_PVI_BGCOLLIDE;
            acase PVI_SPRITECOLLIDE: asicreads[iar] |= ASIC_PVI_SPRITECOLLIDE;
            acase PVI_P1PADDLE     : asicreads[iar] |= ASIC_PVI_P1PADDLE;
            acase PVI_P2PADDLE     : asicreads[iar] |= ASIC_PVI_P2PADDLE;
            adefault:
                switch (address)
                {
                case  IE_NOISE       : asicreads[iar] |= ASIC_IE_NOISE;
                acase IE_P1LEFTKEYS  :
                case  IE_P1MIDDLEKEYS:
                case  IE_P1RIGHTKEYS : asicreads[iar] |= ASIC_IE_P1KEYS;
                acase IE_CONSOLE     : asicreads[iar] |= ASIC_IE_CONSOLE;
                acase IE_P2LEFTKEYS  :
                case  IE_P2MIDDLEKEYS:
                case  IE_P2RIGHTKEYS : asicreads[iar] |= ASIC_IE_P2KEYS;
    }   }   }   }

    if (logreadwrites)
    {   switch (machine)
        {
        case ARCADIA:
            if
            (   (memory[A_CHARLINE] <= 0xFC || (memory[A_CHARLINE] == 0xFF && (address == A_P1PADDLE || address == A_P2PADDLE)))
             && ((memflags[address] & ASIC) || (address >= 0x1980 && address <= 0x19BF))
             && address != A_CHARLINE // because surely it is a valid technique to read CHARLINE; that is its purpose
            )
            {   DISCARD getfriendly((int) address);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(MSG_READDURINGREDRAW, "Instruction at $%X (raster %d) read from UVI address %s during redraw!\n\n"),
                    (unsigned int) iar,
                    (long int)     cpuy,
                                   friendly
                );
                set_pause(TYPE_LOG);
            }
        acase INTERTON:
        case ELEKTOR:
            if
            (   (address == pvibase + PVI_P1PADDLE || address == pvibase + PVI_P2PADDLE)
             && !(memory[pvibase + PVI_SPRITECOLLIDE] & 0x40) // if VRST bit is clear (not in vertical retrace)
            )
            {   DISCARD getfriendly((int) address);
                zprintf
                (   TEXTPEN_LOG,
                    LLL(MSG_READDURINGREDRAW2, "Instruction at $%X (raster %d) read from PVI address %s during redraw!\n\n"), // redraw is the opposite of retrace
                    (unsigned int) iar,
                    (long int)     cpuy,
                                   friendly
                );
                set_pause(TYPE_LOG);
    }   }   }
#endif

    if (memflags[address] & READONCE)
    {   t = memory[address];
        memory[address] = machines[machine].readonce;
    } elif (memflags[address] & NOREAD)
    /* It would be better to make a memread[32768] array, containing what
       values each read-only address returns. (Setting memory[] as
       appropriate wouldn't work, because of write-only registers.) */
    {   switch (machine)
        {
        case ARCADIA:
            t = 0xFF; // some really return eg. $40, $C0 instead of $FF
        acase INTERTON:
            // GRNDPRIX attempts to read from $1F6E..$1F70!
            // not sure whether NOISE ($1E80) is R/W or -/W! (assuming R/W)
            if (address == IE_NOISE)
            {   t = 0x0C; // assuming same behaviour as Elektor
            } elif
            (   // It would probably be better to handle these in setmemmap().
                (address >= 0x1F30 && address <= 0x1F3F)
             || (address >= 0x1F6E && address <= 0x1F7F)
             || (address >= 0x1FAE && address <= 0x1FBF) // this region is $00 for Elektor, so perhaps also for Interton?
            )
            {   t = 0xFF; // same as how MESS V2 initializes these regions
            } else
            {   t = 0x00;
                /* this is assumed rather than known behaviour, but:
                Interton BLACKJAC expects the high nybble (at least) of $1E8F to be $0! */
            }
        acase ELEKTOR:
            if (address >= 0x1000 && address <= 0x15FF)
            {   // assert(memmap == MEMMAP_E);
                t = 0xFF; // games which attempt to sense whether in mode "E"/"F" expect unavailable memory to return $FF
            } elif (address >= 0x1D80 && address <= 0x1DBE)
            {   t = 0x80;
                // TESTER2.tvc proves that $1D80 reads as $80.
            } elif (address >= 0x1DC0 && address <= 0x1DFF)
            {   t = 0xC0;
                // TESTER2.tvc proves that $1DC0 reads as $C0.
            } elif (address == IE_NOISE)
            {   t = 0x0C;
                // TESTER2.tvc proves that NOISE reads as $0C.
            } elif
            (   (address >= 0x1E8F && address <= 0x1E97)
             || (address >= 0x1E9C && address <= 0x1EA7)
             || (address >= 0x1EAF && address <= 0x1EB7)
             || (address >= 0x1EBC && address <= 0x1EC7)
             || (address >= 0x1ECF && address <= 0x1ED7)
             || (address >= 0x1EDC && address <= 0x1EE7)
             || (address >= 0x1EEF && address <= 0x1EF7)
             || (address >= 0x1EFC && address <= 0x1EFF)
            )
            {   t = 0x0F;
                // TESTER2.tvc proves that $1E93 reads as $0F.
            } else
            {   // eg. $1FAE..$1FBF, $1FC0..$1FC9
                // Elektor Labyrinth reads $1FB3..$1FB5 and expects them to be $00.
                // Also, TESTER2.tvc proves that $1FB8 reads as $00.
                // Elektor CarRace works best when SPRITES23CTRL reads as $00.
                t = 0;
            }
        adefault:
            t = 0; // not sure what unmapped PVI areas should return
        }
#ifndef GAMER
        if (logreadwrites)
        {   DISCARD getfriendly(address);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_ENGINE_ILLEGALREAD,
                    "Instruction at $%X (raster %d) is reading $%02X from unreadable address %s!\n\n"
                ),
                (int) iar,
                cpuy,
                (int) t,
                friendly
            );
            set_pause(TYPE_LOG);
        }
#endif
    } elif (memflags[address] & BANKED)
    {   // assert(!(memflags & READONCE));
        switch (machine)
        {
        case ELEKTOR:
            // assert(memmap == MEMMAP_F);
            // assert(address == E_RANDOM1E || address == E_RANDOM1G || address == E_RANDOM2);
            if (recmode == RECMODE_PLAY)
            {   t = loadbyte();
            } else
            {   if (connected == NET_SERVER)
                {   t = rand() % 256;
                    DISCARD NetSendByte(t); // should check return code!
                } elif (connected == NET_CLIENT)
                {   t = NetReceiveByte(); // should check return code!
                } else
                {   t = rand() % 256;
                }
                if (recmode == RECMODE_RECORD)
                {   savebyte(t);
            }   }
        acase INSTRUCTOR:
            // assert(address == S_IOPORT);
            if (s_io == PARALLEL_MEMMAPPED)
            {   t = s_toggles;
            } else
            {   t = memory[address];
            }
        acase ZACCARIA: // but not MALZAK!
            if (!(psu & PSU_F))
            {   if (          address >= 0x1800 && address <= 0x1BFF)
                {   t = g_bank1[address - 0x1800];
                } elif (memmap == MEMMAP_ASTROWARS)
                {   // assert(address >= 0x1C00 && address <= 0x1CFF);
                    t = g_bank2[(address - 0x1C00) & 0xF];
                } else
                {   // assert(memmap == MEMMAP_GALAXIA);
                    // assert(address >= 0x1400 && address <= 0x14FF);
                    t = g_bank2[(address - 0x1400) & 0xF]; // the game doesn't actually seem to ever do this
            }   }
            else
            {   t = memory[address];
    }   }   }
    else
    {   t = memory[address];
    }

#ifndef GAMER
    if (memflags[address] & WATCHPOINT)
    {   if
        (   watchreads
         && (   !(memflags[address] & BANKED)
             || (psu & PSU_F)
           )
         && conditional(&wp[address], 0, FALSE, 0)
        )
        {   // assert(disassembling);
            DISCARD getfriendly(address);
            if (ISQWERTY)
            {   sprintf(stringchar, " [%s]", asciiname_short[t]);
            } elif (machine == ARCADIA)
            {   arcadia_stringchar(t, address);
            } elif (machine == INTERTON || machine == ELEKTOR)
            {   ie_stringchar(t, address);
            } else
            {   sprintf(stringchar, " ['%c']", guestchar(t));
            }

            number_to_friendly(oldiar, (STRPTR) friendly2, TRUE, 0);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_ENGINE_HITWP,
                    "Instruction at $%X (raster %d) is reading $%X%s from %s! Previous IAR/PC was %s.\n" // yes, just one \n
                ),
                (unsigned int) iar,
                (long int)     cpuy,
                               t,
                               stringchar,
                               friendly,
                               friendly2
            );
            printed = TRUE;
            set_pause(TYPE_BP);
        } else
        {   printed = FALSE;
        }

        if
        (   (memflags[address] & READONCE)
         &&  watchwrites
         && (watchwrites == WATCH_ALL || machines[machine].readonce != memory[address])
         && conditional(&wp[address], machines[machine].readonce, TRUE, 0)
        )
        {   zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_ENGINE_READONCE,
                    "Read-once register %s has been reset to $%X!\n" // yes, just one \n
                ),
                               friendly,
                (unsigned int) machines[machine].readonce
            );
            zprintf(TEXTPEN_LOG, "\n");
            set_pause(TYPE_BP);
        } elif (printed)
        {   zprintf(TEXTPEN_LOG, "\n");
    }   }
#endif

    return t;
}

MODULE __inline void cpuwrite_2650(int address, UBYTE data)
{   /* assert(address < 32768);

    Writes to memory from the CPU always go through this routine.

    The game can never write to semi-mirrored registers, as they are
    all read-only. They can only be set by the PVI.

       1. Resolve write mirrors.
       2. Mark as written (at the pre- and post-mirroring addresses).
       3. If read-only
           log to user
           return
       4. If watchpoint
           log to user
       5. Write the byte. */

#ifdef GAMER
    address = (int) mirror_w[address]; // but this won't work for BINBUG
#else
    coverage[address] |= COVERAGE_WRITE;
    if (mirror_w[address] != address)
    {   if (logreadwrites)
        {   DISCARD getfriendly((int) mirror_w[address]);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_WRITEMIRROR,
                    "Instruction at $%X (raster %d) is writing $%X to mirrored address $%X (resolves to %s)!\n\n"
                ),
                (long unsigned int) iar,
                (long int)          cpuy,
                                    data,
                (long unsigned int) address,
                                    friendly
            );
            set_pause(TYPE_LOG);
        }
        address = (int) mirror_w[address];
        coverage[address] |= COVERAGE_WRITE;
    }

    if (!(memflags[address] & SPECIALWRITE))
    {   memory[address] = data;
        return;
    }

    if (memflags[address] & ASIC)
    {   if (machine == ARCADIA)
        {   switch (address)
            {
            case  A_SPRITE0Y:        asicwrites[iar] |= ASIC_UVI_SPRITE0Y;
            acase A_SPRITE0X:        asicwrites[iar] |= ASIC_UVI_SPRITE0X;
            acase A_SPRITE1Y:        asicwrites[iar] |= ASIC_UVI_SPRITE1Y;
            acase A_SPRITE1X:        asicwrites[iar] |= ASIC_UVI_SPRITE1X;
            acase A_SPRITE2Y:        asicwrites[iar] |= ASIC_UVI_SPRITE2Y;
            acase A_SPRITE2X:        asicwrites[iar] |= ASIC_UVI_SPRITE2X;
            acase A_SPRITE3Y:        asicwrites[iar] |= ASIC_UVI_SPRITE3Y;
            acase A_SPRITE3X:        asicwrites[iar] |= ASIC_UVI_SPRITE3X;
            acase A_VSCROLL:         asicwrites[iar] |= ASIC_UVI_VSCROLL;
            acase A_PITCH:           asicwrites[iar] |= ASIC_UVI_PITCH;
            acase A_VOLUME:          asicwrites[iar] |= ASIC_UVI_VOLUME;
            acase A_CHARLINE:        asicwrites[iar] |= ASIC_UVI_CHARLINE;
            acase A_P1LEFTKEYS:      asicwrites[iar] |= ASIC_UVI_P1LEFTKEYS;
            acase A_P1MIDDLEKEYS:    asicwrites[iar] |= ASIC_UVI_P1MIDDLEKEYS;
            acase A_P1RIGHTKEYS:     asicwrites[iar] |= ASIC_UVI_P1RIGHTKEYS;
            acase A_P1PALLADIUM:     asicwrites[iar] |= ASIC_UVI_P1PALLADIUM;
            acase A_P2LEFTKEYS:      asicwrites[iar] |= ASIC_UVI_P2LEFTKEYS;
            acase A_P2MIDDLEKEYS:    asicwrites[iar] |= ASIC_UVI_P2MIDDLEKEYS;
            acase A_P2RIGHTKEYS:     asicwrites[iar] |= ASIC_UVI_P2RIGHTKEYS;
            acase A_P2PALLADIUM:     asicwrites[iar] |= ASIC_UVI_P2PALLADIUM;
            acase A_CONSOLE:         asicwrites[iar] |= ASIC_UVI_CONSOLE;
            acase A_GFXMODE:         asicwrites[iar] |= ASIC_UVI_GFXMODE;
            acase A_BGCOLOUR:        asicwrites[iar] |= ASIC_UVI_BGCOLOUR;
            acase A_SPRITES23CTRL:   asicwrites[iar] |= ASIC_UVI_SPRITES23CTRL;
            acase A_SPRITES01CTRL:   asicwrites[iar] |= ASIC_UVI_SPRITES01CTRL;
            acase A_BGCOLLIDE:       asicwrites[iar] |= ASIC_UVI_BGCOLLIDE;
            acase A_SPRITECOLLIDE:   asicwrites[iar] |= ASIC_UVI_SPRITECOLLIDE;
            acase A_P2PADDLE:        asicwrites[iar] |= ASIC_UVI_P2PADDLE;
            acase A_P1PADDLE:        asicwrites[iar] |= ASIC_UVI_P1PADDLE;
        }   }
        else
        {   // assert(machines[machine].pvis);
            switch (address - pvibase)
            {
            case  PVI_SPRITE0AX    : asicwrites[iar] |= ASIC_PVI_SPRITE0AX;
            acase PVI_SPRITE0BX    : asicwrites[iar] |= ASIC_PVI_SPRITE0BX;
            acase PVI_SPRITE0AY    : asicwrites[iar] |= ASIC_PVI_SPRITE0AY;
            acase PVI_SPRITE0BY    : asicwrites[iar] |= ASIC_PVI_SPRITE0BY;
            acase PVI_SPRITE1AX    : asicwrites[iar] |= ASIC_PVI_SPRITE1AX;
            acase PVI_SPRITE1BX    : asicwrites[iar] |= ASIC_PVI_SPRITE1BX;
            acase PVI_SPRITE1AY    : asicwrites[iar] |= ASIC_PVI_SPRITE1AY;
            acase PVI_SPRITE1BY    : asicwrites[iar] |= ASIC_PVI_SPRITE1BY;
            acase PVI_SPRITE2AX    : asicwrites[iar] |= ASIC_PVI_SPRITE2AX;
            acase PVI_SPRITE2BX    : asicwrites[iar] |= ASIC_PVI_SPRITE2BX;
            acase PVI_SPRITE2AY    : asicwrites[iar] |= ASIC_PVI_SPRITE2AY;
            acase PVI_SPRITE2BY    : asicwrites[iar] |= ASIC_PVI_SPRITE2BY;
            acase PVI_SPRITE3AX    : asicwrites[iar] |= ASIC_PVI_SPRITE3AX;
            acase PVI_SPRITE3BX    : asicwrites[iar] |= ASIC_PVI_SPRITE3BX;
            acase PVI_SPRITE3AY    : asicwrites[iar] |= ASIC_PVI_SPRITE3AY;
            acase PVI_SPRITE3BY    : asicwrites[iar] |= ASIC_PVI_SPRITE3BY;
            acase PVI_SIZES        : asicwrites[iar] |= ASIC_PVI_SIZES;
            acase PVI_SPR01COLOURS : asicwrites[iar] |= ASIC_PVI_SPR01COLOURS;
            acase PVI_SPR23COLOURS : asicwrites[iar] |= ASIC_PVI_SPR23COLOURS;
            acase PVI_SCORECTRL    : asicwrites[iar] |= ASIC_PVI_SCORECTRL;
            acase PVI_BGCOLOUR     : asicwrites[iar] |= ASIC_PVI_BGCOLOUR;
            acase PVI_PITCH        : asicwrites[iar] |= ASIC_PVI_PITCH;
            acase PVI_SCORELT      : asicwrites[iar] |= ASIC_PVI_SCORELT;
            acase PVI_SCORERT      : asicwrites[iar] |= ASIC_PVI_SCORERT;
            acase PVI_BGCOLLIDE    : asicwrites[iar] |= ASIC_PVI_BGCOLLIDE;
            acase PVI_SPRITECOLLIDE: asicwrites[iar] |= ASIC_PVI_SPRITECOLLIDE;
            acase PVI_P1PADDLE     : asicwrites[iar] |= ASIC_PVI_P1PADDLE;
            acase PVI_P2PADDLE     : asicwrites[iar] |= ASIC_PVI_P2PADDLE;
            adefault:
                // assert(machine == INTERTON || machine == ELEKTOR); (coin-ops don't have ASIC flag set for these addresses)
                switch (address)
                {
                case  IE_NOISE     :                                             asicwrites[iar] |= ASIC_IE_NOISE;
                acase IE_P1LEFTKEYS: case  IE_P1MIDDLEKEYS: case IE_P1RIGHTKEYS: asicwrites[iar] |= ASIC_IE_P1KEYS;
                acase IE_CONSOLE   :                                             asicwrites[iar] |= ASIC_IE_CONSOLE;
                acase IE_P2LEFTKEYS: case  IE_P2MIDDLEKEYS: case IE_P2RIGHTKEYS: asicwrites[iar] |= ASIC_IE_P2KEYS;
    }   }   }   }

    if
    (   logreadwrites
     && machine == ARCADIA
     && memory[A_CHARLINE] <= 0xFC
     && ((memflags[address] & ASIC) || (address >= 0x1980 && address <= 0x19BF))
    )
    {   DISCARD getfriendly((int) address);
        zprintf
        (   TEXTPEN_LOG,
            LLL(MSG_WROTEDURINGREDRAW, "Instruction at $%X (raster %d) wrote to UVI address %s during redraw!\n\n"),
            (unsigned int) iar,
            (long int)     cpuy,
                           friendly
        );
        set_pause(TYPE_LOG);
    }
#endif

    if (memflags[address] & NOWRITE)
    {
#ifndef GAMER
        if (logreadwrites && (memflags[address] & NOWRITE))
        {   DISCARD getfriendly(address);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_CPU_ILLEGALWRITE,
                    "Instruction at $%X (raster %d) is attempting to write $%X to unwritable address %s!\n\n"
                ),
                (int) iar,
                (int) cpuy,
                      data,
                      friendly
            );
            set_pause(TYPE_LOG);
        }
#endif

        return;
    }

#ifndef GAMER
    if
    (   (memflags[address] & WATCHPOINT)
     && watchwrites != WATCH_NONE
     && (watchwrites == WATCH_ALL || data != memory[address])
     && conditional(&wp[address], data, TRUE, 0)
    )
    {   // assert(!disassembling);
        DISCARD getfriendly(address);
        if (ISQWERTY)
        {   sprintf(stringchar, " [%s]", asciiname_short[data]);
        } elif (machine == ARCADIA)
        {   arcadia_stringchar(data, address);
        } elif (machine == INTERTON || machine == ELEKTOR)
        {   ie_stringchar(data, address);
        } else
        {   sprintf(stringchar, " ['%c']", guestchar(data));
        }

        number_to_friendly(oldiar, (STRPTR) friendly2, TRUE, 0);
        zprintf
        (   TEXTPEN_LOG,
            LLL
            (   MSG_CPU_HITWP,
                "Instruction at $%X (raster %d) is writing $%X%s to %s! Previous IAR/PC was %s.\n\n"
            ),
            (int) iar,
            (int) cpuy,
                  data,
                  stringchar,
                  friendly,
                  friendly2
        );
        set_pause(TYPE_BP);
    }
#endif

    if (memflags[address] & BANKED)
    {   switch (memmap)
        {
        case MEMMAP_N:
        case MEMMAP_O:
            // assert(address == S_IOPORT);
            if (s_io == PARALLEL_MEMMAPPED)
            {   glow = data;
            } else
            {   memory[address] = data;
            }
        acase MEMMAP_LASERBATTLE:
        case  MEMMAP_LAZARIAN:
            // assert(address >= 0x1800);
            // assert(address <= 0x1BFF);
            if (lb_bank == 1)
            {   memory_effects[(address - 0x1800) & 0x1FF] = data;
            } else
            {   memory[address] = data;
            }
        acase MEMMAP_ASTROWARS:
        case  MEMMAP_GALAXIA:
            if (psu & PSU_F)
            {   if (memmap == MEMMAP_ASTROWARS && address >= 0x1C00 && address <= 0x1CFF)
                {   g_bank2[(address - 0x1C00) & 0xF] = data;
                } else
                {   memory[address] = data;
            }   }
            else
            {   if (address >= 0x1800 && address <= 0x1BFF)
                {   g_bank1[address - 0x1800] = data;
                } else
                {   memory[address] = data;
            }   }
        acase MEMMAP_MALZAK1:
        case  MEMMAP_MALZAK2:
            malzak_field[malzak_x / 16][(address - 0x1600) / 16] = memory[address] = data;
    }   }
    else
    {   memory[address] = data;
        if (memflags[address] & AUDIBLE)
        {   playsound(FALSE);
}   }   }

EXPORT void do_tape(void)
{   FAST ULONG cycles_since,
               prevsamplewhere;

    if (tapemode > TAPEMODE_STOP)
    {   // assert(TAPABLE);
        prevsamplewhere =  samplewhere;
        cycles_since    =  cycles_2650 - cycles_prev;
        samplewhere_f   += ((double) cycles_since / tapespeed); // this may lose some precision over time, but not enough to be significant
        samplewhere     =  (ULONG) samplewhere_f;
        cycles_prev     =  cycles_2650;

        if (tapemode == TAPEMODE_PLAY)
        {   if (samplewhere > prevsamplewhere)
            {   // assert(samplewhere == prevsamplewhere + 1);

                if (samplewhere >= tapelength)
                {   tapemode      = TAPEMODE_STOP;
                    samplewhere   = tapelength;
                    samplewhere_f = (double) samplewhere;
                    // update_tapedeck(FALSE); will happen later in the frame
                } else
                {   DISCARD fread(&tapebyte, 1, 1, TapeHandle);
                    if (tapekind == KIND_8SVX || tapekind == KIND_AIFF)
                    {   tapebyte ^= 0x80; // convert from signed to unsigned
                    }
                    if (inverttape)
                    {   tapebyte ^= 0xFF; // ie. tapebyte = 255 - tapebyte;
                    }

                    switch (machine)
                    {
                    case ELEKTOR:
                        memory[E_CASIN] = (tapebyte < tapeskewage) ? 0 : 0xFF; // we should probably use cpuwrite_2650()
                        // Elektor BIOS only cares whether CASIN is different (at all) from its previous value (ie. there has been a transition)
                    acase PIPBUG:
                    case BINBUG:
                    case PHUNSY:
                    case SELBST:
                        if (machine == BINBUG && binbug_interface == ACOS)
                        {   ioport[0x32].contents &= 0x7F; // we don't writeport() for this, but probably should
                            if (tapebyte >= tapeskewage)
                            {   ioport[0x32].contents |= 0x80;
                        }   }
                        else
                        {   if (tapebyte < tapeskewage && oldtapebyte >= tapeskewage)
                            {   if (cycles_2650 - oldtapecycle >= CYCLELENGTH * 2)
                                {   psu &= ~(PSU_S); // clear bit ("space")
                                } else
                                {   psu |=   PSU_S ; // set   bit ("mark" )
                                }
                                oldtapecycle = cycles_2650;
                            }
                            oldtapebyte = tapebyte;
                        }
                    acase CD2650:
                        if (tapebyte < tapeskewage && oldtapebyte >= tapeskewage)
                        {   if (cycles_2650 - oldtapecycle >= (ULONG) (CD2650_CYCLELENGTH * (fastcd2650 ? 3 : 2)))
                            {   psu &= ~(PSU_S); // clear bit ("space")
                            } else
                            {   psu |=   PSU_S ; // set   bit ("mark" )
                            }
                            oldtapecycle = cycles_2650;
                        }
                        oldtapebyte = tapebyte;
                    acase INSTRUCTOR:
                        if (tapebyte < tapeskewage)
                        {   psu &= ~(PSU_S);
                        } else
                        {   psu |=   PSU_S ;
            }   }   }   }

            if (verbosetape)
            {   verbosetape_load();
        }   }
        else
        {   // assert(tapemode == TAPEMODE_RECORD);
            if (samplewhere > prevsamplewhere)
            {   // assert(samplewhere == prevsamplewhere + 1);

                switch (machine)
                {
                case ELEKTOR:
                    tapebyte = memory[E_CASOUT]; // we don't use cpuread_2650() for this
                    // The only values the BIOS ever uses for CASOUT are $00 and $FF
                acase CD2650:
                    if (fastcd2650)
                    {   if (psu & PSU_F)
                        {   if (cycles_2650 % (ULONG) (CD2650_MARKLENGTH  * 3) < (ULONG) ((CD2650_MARKLENGTH  * 3) / 2))
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                        }   }
                        else
                        {   if (cycles_2650 % (ULONG) (CD2650_SPACELENGTH * 3) < (ULONG) ((CD2650_SPACELENGTH * 3) / 2))
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                    }   }   }
                    else
                    {   if (psu & PSU_F)
                        {   if (cycles_2650 % (ULONG) (CD2650_MARKLENGTH  * 2) < (ULONG)   CD2650_MARKLENGTH           )
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                        }   }
                        else
                        {   if (cycles_2650 % (ULONG) (CD2650_SPACELENGTH * 2) < (ULONG)   CD2650_SPACELENGTH          )
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                    }   }   }
                acase PIPBUG:
                case PHUNSY:
                case SELBST:
                case BINBUG:
                    if (machine == BINBUG && binbug_interface == ACOS)
                    {   if (ioport[0x32].contents & 1) // we probably should use readport() for this
                        {   tapebyte = LOWPULSE;
                        } else
                        {   tapebyte = HIGHPULSE;
                    }   }
                    else
                    {   if (psu & PSU_F)
                        {   if (cycles_2650 % ( MARKLENGTH * 2) <  MARKLENGTH)
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                        }   }
                        else
                        {   if (cycles_2650 % (SPACELENGTH * 2) < SPACELENGTH)
                            {   tapebyte = HIGHPULSE;
                            } else
                            {   tapebyte = LOWPULSE;
                    }   }   }
                acase INSTRUCTOR:
                    if     (s_tapeport == 0x10)
                    {   tapebyte = LOWPULSE;
                    } elif (s_tapeport == 0x18)
                    {   tapebyte = HIGHPULSE;
                    } else
                    {   tapebyte = 0x80;
                }   }

                if (inverttape)
                {   tapebyte ^= 0xFF; // ie. tapebyte = 255 - tapebyte;
                }
                if (TapeCopy && samplewhere < (ULONG) otl && !tapewriteprotect)
                {   TapeCopy[samplewhere] = tapebyte;
                }
                if (tapewriteprotect)
                {   if (tapekind == KIND_8SVX || tapekind == KIND_AIFF)
                    {   tapebyte =    0; // silence
                    } else
                    {   tapebyte = 0x80; // silence
                    }
                    if (samplewhere >= (ULONG) otl)
                    {   fwrite(&tapebyte, 1, 1, TapeHandle);
                    } else
                    {   fseek(TapeHandle, 1, SEEK_CUR);
                    }
                    tapebyte = 0x80; // silence
                } else
                {   if (tapekind == KIND_8SVX || tapekind == KIND_AIFF)
                    {   tapebyte ^= 0x80; // convert from unsigned to signed (temporarily)
                        fwrite(&tapebyte, 1, 1, TapeHandle);
                        tapebyte ^= 0x80; // convert from signed to unsigned
                    } else
                    {   fwrite(&tapebyte, 1, 1, TapeHandle);
                }   }
                if (tapelength < samplewhere)
                {   // assert(samplewhere == tapelength + 1);
                    tapelength = samplewhere;
            }   }

            if (verbosetape)
            {   verbosetape_save();
}   }   }   }

MODULE void check_handler(void)
{   FAST FLAG done;
    FAST int  i;

    // assert(log_interrupts);

    // Ideally this would use CALM notation when appropriate
    done = FALSE;
    if ((oldpsu & 0x7F) != (psu & 0x7F))
    {   done = TRUE;
        zprintf(TEXTPEN_LOG, "PSU has not been restored correctly at $%X (old $%02X vs. new $%02X):\n", iar, oldpsu, psu);
        // game cannot set Sense bit
        if ((oldpsu & 0x40) != (psu & 0x40)) zprintf(TEXTPEN_LOG, " F (Flag) bit is different.\n");
        // II bit will always be clear in both
        if ((oldpsu & 0x10) != (psu & 0x10)) zprintf(TEXTPEN_LOG, " UF1 (User Flag #1) bit is different.\n");
        if ((oldpsu & 0x08) != (psu & 0x08)) zprintf(TEXTPEN_LOG, " UF2 (User Flag #2) bit is different.\n");
        if ((oldpsu & 0x07) != (psu & 0x07)) zprintf(TEXTPEN_LOG, " SP (Stack Pointer) is wrong!\n");
    }
    if (oldpsl != psl)
    {   done = TRUE;
        zprintf(TEXTPEN_LOG, "PSL has not been restored correctly at $%X (old $%02X vs. new $%02X):\n", iar, oldpsl, psl);
        if ((oldpsl & 0xC0) != (psl & 0xC0)) zprintf(TEXTPEN_LOG, " CC (Condition Code) is different.\n");
        if ((oldpsl & 0x20) != (psl & 0x20)) zprintf(TEXTPEN_LOG, " IDC (Inter-Digit Carry) bit is different.\n");
        if ((oldpsl & 0x10) != (psl & 0x10)) zprintf(TEXTPEN_LOG, " RS (Register Select) bit is different.\n");
        if ((oldpsl & 0x08) != (psl & 0x08)) zprintf(TEXTPEN_LOG, " WC (With Carry) bit is different.\n");
        if ((oldpsl & 0x04) != (psl & 0x04)) zprintf(TEXTPEN_LOG, " OVF (Overflow) bit is different.\n");
        if ((oldpsl & 0x02) != (psl & 0x02)) zprintf(TEXTPEN_LOG, " COM (Compare) bit is different.\n");
        if ((oldpsl & 0x01) != (psl & 0x01)) zprintf(TEXTPEN_LOG, " C (Carry) bit is different.\n");
    }
    for (i = 0; i < 7; i++)
    {   if (oldr[i] != r[i])
        {   done = TRUE;
            zprintf(TEXTPEN_LOG, "R%d has not been restored correctly at $%X (old $%02X vs. new $%02X)!\n", i, iar, oldr[i], r[i]);
    }   }
    // We could also check for corruption of the Return Address Stack

    if (done)
    {   zprintf(TEXTPEN_LOG, "\n");
        set_pause(TYPE_LOG);
}   }

MODULE __inline UBYTE readreg(int whichreg)
{   FAST UBYTE t;

    t = r[whichreg];
#ifndef GAMER
    if (memflags[TOKEN_R0 + whichreg] & WATCHPOINT)
    {   if
        (   watchreads
         && conditional(&wp[TOKEN_R0 + whichreg], 0, FALSE, 0)
        )
        {   if (ISQWERTY)
            {   sprintf(stringchar, " [%s]", asciiname_short[t]);
            } elif (machine != INTERTON)
            {   sprintf(stringchar, " ['%c']", guestchar(t));
            } else
            {   stringchar[0] = EOS;
            }
            number_to_friendly(oldiar, (STRPTR) friendly2, TRUE, 0);
            zprintf
            (   TEXTPEN_LOG,
                LLL(
                    MSG_ENGINE_HITWP,
                    "Instruction at $%X (raster %d) is reading $%X%s from %s! Previous IAR/PC was %s.\n" // yes, just one \n
                ),
                (unsigned int) iar,
                (long int)     cpuy,
                               t,
                               stringchar,
                               tokenname[whichreg][style], // this only works if registers are the first tokens
                               friendly2
            );
            zprintf(TEXTPEN_LOG, "\n");
            set_pause(TYPE_BP);
    }   }
#endif

    return t;
}

MODULE __inline void writereg(int whichreg, UBYTE data)
{
#ifndef GAMER
    if
    (   (memflags[TOKEN_R0 + whichreg] & WATCHPOINT)
     && watchwrites != WATCH_NONE
     && (watchwrites == WATCH_ALL || data != r[whichreg])
     && conditional(&wp[TOKEN_R0 + whichreg], data, TRUE, 0)
    )
    {   DISCARD getfriendly(TOKEN_R0 + whichreg);
        if (ISQWERTY)
        {   sprintf(stringchar, " [%s]", asciiname_short[data]);
        } elif (machine != INTERTON)
        {   sprintf(stringchar, " ['%c']", guestchar(data));
        } else
        {   stringchar[0] = EOS;
        }
        number_to_friendly(oldiar, (STRPTR) friendly2, TRUE, 0);
        zprintf
        (   TEXTPEN_LOG,
            LLL
            (   MSG_CPU_HITWP,
                "Instruction at $%X (raster %d) is writing $%X%s to %s! Previous IAR/PC was %s.\n\n"
            ),
            (int) iar,
            (int) cpuy,
                  data,
                  stringchar,
                  tokenname[whichreg][style], // this only works if registers are the first tokens
                  friendly2
        );
        set_pause(TYPE_BP);
    }
#endif

    r[whichreg] = data;
}

#ifndef GAMER
MODULE void checkabsbranch(void)
{   if (loginefficient)
    {   if (ea == (ULONG) WRAPMEM(3)) // any jump to the next opcode
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Omit %s at %s.\n\n",
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        } elif
        (   memory[ea] == opcode -  8 // BCTA,cc (28..31) -> RETC,cc (20..23): suggest RETC,cc
         || memory[ea] ==          23 // BCTA,cc (28..31) -> RETC,UN (    23): suggest RETC,cc
        )
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Replace %s with %s at %s.\n\n",
                opcodes[style][opcode    ].name,
                opcodes[style][opcode - 8].name,
                friendly
            );
            set_pause(TYPE_LOG);
        } elif
        (   memory[ea] == opcode + 24 // BCTA,cc (28..31) -> RETE,cc (52..55): suggest RETE,cc
         || memory[ea] ==          23 // BCTA,cc (28..31) -> RETE,UN (    55): suggest RETE,cc
        )
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Replace %s with %s at %s.\n\n",
                opcodes[style][opcode     ].name,
                opcodes[style][opcode + 24].name,
                friendly
            );
            set_pause(TYPE_LOG);
}   }   }

MODULE void checkrelbranch(void)
{   if (loginefficient)
    {   if (ea == (ULONG) WRAPMEM(2)) // any jump to the next opcode
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Omit %s at %s.\n\n",
                opcodes[style][opcode].name,
                friendly
            );
            set_pause(TYPE_LOG);
        } elif (opcode == 155)
        {   if
            (   memory[ea] == 23 // ZBRR (155) -> RETC,un (23): suggest RETC,un (23)
             || memory[ea] == 55 // ZBRR (155) -> RETE,un (55): suggest RETE,un (55)
            )
            DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Replace %s with %s at %s.\n\n",
                opcodes[style][opcode    ].name,
                opcodes[style][memory[ea]].name,
                friendly
            );
            set_pause(TYPE_LOG);
        } elif
        (   memory[ea] == opcode -  4 // BCTR,cc (24..27) -> RETC,cc (20..23): suggest RETC,cc
         || memory[ea] ==          23 // BCTR,cc (24..27) -> RETC,UN (    23): suggest RETC,cc
        )
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Replace %s with %s at %s.\n\n",
                opcodes[style][opcode    ].name,
                opcodes[style][opcode - 4].name,
                friendly
            );
            set_pause(TYPE_LOG);
        } elif
        (   memory[ea] == opcode + 28 // BCTR,cc (24..27) -> RETE,cc (52..55): suggest RETE,cc
         || memory[ea] ==          23 // BCTR,cc (24..27) -> RETE,UN (    55): suggest RETE,cc
        )
        {   DISCARD getfriendly(iar);
            zprintf
            (   TEXTPEN_LOG,
                "Replace %s with %s at %s.\n\n",
                opcodes[style][opcode     ].name,
                opcodes[style][opcode + 28].name,
                friendly
            );
            set_pause(TYPE_LOG);
}   }   }

EXPORT void set_pause(int thetype)
{   if
    (   (thetype == TYPE_BP    && pausebreak)
     || (thetype == TYPE_LOG   && pauselog  )
     ||  thetype == TYPE_RUNTO
    )
    {   pausing = TRUE;
}   }

MODULE void runto(void)
{   pausing = FALSE;
    emu_pause();
    update_monitor(FALSE); // because emu_pause() doesn't do it

    while (paused)
    {
#ifdef WIN32
        wa_checkinput();
        process_code();
#endif
#ifdef AMIGA
        aa_checkinput();
#endif
}   }

EXPORT void checkstep(void)
{   if (memflags[iar] & (STEPPOINT | BREAKPOINT))
    {   if (memflags[iar] & STEPPOINT)
        {   memflags[iar] &= ~(STEPPOINT);

            zprintf
            (   TEXTPEN_DEBUG,
                LLL(
                    MSG_CPU_REACHEDSUBEND,
                    "Reached end of subroutine or interrupt and returned to $%X.\n\n"
                ),
                (unsigned int) iar // should use friendly instead
            );
            set_pause(TYPE_RUNTO);
        }
        if (memflags[iar] & BREAKPOINT)
        {   if (conditional(&bp[iar], 0, FALSE, 0))
            {   DISCARD getfriendly(iar);
                number_to_friendly(oldiar, (STRPTR) friendly2, TRUE, 0);
                zprintf
                (   TEXTPEN_DEBUG,
                    LLL(
                        MSG_CPU_HITBP,
                        "Hit code breakpoint at %s! Previous IAR/PC was %s.\n\n"
                    ),
                    friendly,
                    friendly2
                );
                set_pause(TYPE_BP);
        }   }
        if (pausing)
        {   runto();
}   }   }
#endif

MODULE void logindirectbios(void)
{
#ifndef GAMER
    if
    (   (    machine == INSTRUCTOR
         || (machine == CD2650 && cd2650_dosver == DOS_P1DOS && cd2650_biosver == CD2650_IPL)
        )
     && logbios
     && !(memflags[iar] & BIOS) // we don't log the monitor calling itself
     &&  (memflags[ea ] & BIOS)
    )
    {   DISCARD getfriendly(ea);
        zprintf
        (   TEXTPEN_LOG,
            LLL(MSG_VECTORCALLED, "%s vector at %s was called by game code at $%X.\n"),
            "P1 DOS",
            friendly,
            (unsigned int) iar
        );
        switch (machine)
        {
        case  INSTRUCTOR: instructor_biosdetails(ea);
        acase CD2650:     cd2650_biosdetails2(ea);
        }
        zprintf(TEXTPEN_LOG, "\n");
        set_pause(TYPE_LOG);
    }
#endif
}
