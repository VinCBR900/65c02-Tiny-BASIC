#!/usr/bin/env bash
set -euo pipefail

cc=${CC:-cc}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
asm_src="$repo_root/tools/asm65c02.c"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
asm_bin="$tmp/asm65c02"

"$cc" -O2 -DASM65C02_MAIN -o "$asm_bin" "$asm_src"

cat >"$tmp/acc_zp.asm" <<'ASM'
.org $8000
inc a
dec a
asl a
lsr a
rol a
ror a
sta $af
lda $af
FLT_DVH = $af
sta FLT_DVH
lda FLT_DVH
ASM
"$asm_bin" "$tmp/acc_zp.asm" -o "$tmp/acc_zp.bin" -r '$8000-$800F' >/dev/null
bytes=$(od -An -tx1 "$tmp/acc_zp.bin" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
expected='1a 3a 0a 4a 2a 6a 85 af a5 af 85 af a5 af 00 00'
if [[ "$bytes" != "$expected" ]]; then
    echo "unexpected accumulator/ZP bytes" >&2
    echo "expected: $expected" >&2
    echo "actual:   $bytes" >&2
    exit 1
fi
grep -q '8000  1A .*inc a' "$tmp/acc_zp.LST"
grep -q '8006  85 AF .*sta \$af' "$tmp/acc_zp.LST"

cat >"$tmp/overflow.asm" <<'ASM'
.org $FFFE
.byte 1,2,3
ASM
if "$asm_bin" "$tmp/overflow.asm" -o "$tmp/overflow.bin" -r '$FFFE-$FFFF' >"$tmp/overflow.out" 2>"$tmp/overflow.err"; then
    echo "overflow assembly unexpectedly succeeded" >&2
    exit 1
fi
test -f "$tmp/overflow.LST"
test ! -f "$tmp/overflow.bin"
grep -q 'Address $10000 exceeds 64K address space' "$tmp/overflow.err"
if "$asm_bin" "$tmp/overflow.asm" >"$tmp/overflow_human.out" 2>"$tmp/overflow_human.err"; then
    echo "overflow human report unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'ROM footprint: address-space overflow; footprint is invalid' "$tmp/overflow_human.out"

cat >"$tmp/word.asm" <<'ASM'
.org $8000
TARGET = $10035
.word TARGET
ASM
if "$asm_bin" "$tmp/word.asm" >"$tmp/word.out" 2>"$tmp/word.err"; then
    echo "out-of-range .word unexpectedly succeeded" >&2
    exit 1
fi
grep -q ".word 'TARGET': value \$10035 exceeds 16 bits" "$tmp/word.out"
grep -q 'TARGET.*$10035 USED' "$tmp/word.LST"

"$asm_bin" "$tmp/acc_zp.asm" -NoList >/dev/null
rm -f "$tmp/acc_zp.LST"
"$asm_bin" "$tmp/acc_zp.asm" -NoList >/dev/null
test ! -e "$tmp/acc_zp.LST"
