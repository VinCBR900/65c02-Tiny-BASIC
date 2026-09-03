tcc -O2 -DASM65C02_MAIN asm65c02.c
tcc -O2 sim65c02.c
copy *.exe ..
pause