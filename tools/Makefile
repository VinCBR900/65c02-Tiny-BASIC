CC ?= gcc
CFLAGS ?= -O2
WINCC ?= x86_64-w64-mingw32-gcc
WIN_CFLAGS ?= -O2

.PHONY: all windows clean

all: asm65c02 sim65c02 sim65c02_interactive

windows: asm65c02.exe sim65c02.exe sim65c02_interactive.exe

asm65c02: asm65c02.c
	$(CC) $(CFLAGS) -DASM65C02_MAIN -o $@ $<

sim65c02: sim65c02.c asm65c02.c
	$(CC) $(CFLAGS) -o $@ sim65c02.c

sim65c02_interactive: sim65c02_interactive.c asm65c02.c
	$(CC) $(CFLAGS) -o $@ sim65c02_interactive.c

asm65c02.exe: asm65c02.c
	$(WINCC) $(WIN_CFLAGS) -DASM65C02_MAIN -o $@ $<

sim65c02.exe: sim65c02.c asm65c02.c
	$(WINCC) $(WIN_CFLAGS) -o $@ sim65c02.c

sim65c02_interactive.exe: sim65c02_interactive_win32.c asm65c02.c
	$(WINCC) $(WIN_CFLAGS) -o $@ sim65c02_interactive_win32.c

clean:
	rm -f asm65c02 sim65c02 sim65c02_interactive
	rm -f asm65c02.exe sim65c02.exe sim65c02_interactive.exe
