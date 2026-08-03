# =============================================================================
# Makefile  --  65C02 Tiny BASIC build (native tools/ROMs + web/Wasm demo) (v2)
#
# Usage:
#   make roms        -- build native uBASIC6502.bin/mini-BASIC65c02.bin/
#                        4kBASIC.bin (ROM-range binaries, for burning to
#                        actual EEPROM/flash) plus tools/asm65c02
#   make native-smoke -- native build sanity check for sim65c02.c
#   make web-dist     -- build dist/ (index.html + sim65c02.js/.wasm +
#                         assets/*.bin) for the GitHub Pages browser demo
#   make clean        -- remove all generated files
#
# History:
#   v2 (Aug 2026) — Web-assets ROMs (web/assets/*.bin) are now built WITHOUT
#     -r (full 64KB flat image) instead of the ROM-only address range used
#     by `make roms`. Root cause: uBASIC6502.asm/mini-BASIC65c02.asm's INIT
#     points PE at a pre-assembled "showcase" demo program that lives in
#     RAM (around $0200), separate from the ROM code range. The ROM-range
#     -r binaries never included that RAM data, so the browser build (which
#     only loads what's in the .bin) had PE pointing past real data into
#     zeroed memory -- RUN/LIST would walk it as a bogus program and spew
#     garbage lines forever. sim65c02.c's load_bin() already supports a
#     65536-byte flat image (loads verbatim at $0000), and asm65c02 already
#     supports a full-range dump when -r is omitted, so this only needed a
#     Makefile change -- no ROM source or C changes. `make roms` (native
#     ROM-chip images) is unaffected and still uses -r.
#     Also fixed WEB_ROMS never including 4kBASIC.bin (web-assets silently
#     built only 2 of the 3 ROMs). Added -DSIM_BROWSER_BINONLY to web-dist's
#     emcc invocation (see sim65c02.c v14) so the wasm build compiles out
#     the embedded assembler, which isn't needed for a .bin-only front end
#     and was otherwise ~37MB of static data that failed to link at
#     Emscripten's default 16MB initial memory.
#   v1 (2026) — Original native + web-dist build (archived).
# =============================================================================

.PHONY: all tools tools-win roms web-assets web-dist native-smoke clean clean-web-assets clean-web-dist

TOOLS_DIR := tools
ASM := $(TOOLS_DIR)/asm65c02
SIM_SRC := $(TOOLS_DIR)/sim65c02.c
DIST_DIR := dist
EMCC ?= emcc

ROMS := uBASIC6502.bin mini-BASIC65c02.bin 4kBASIC.bin
WEB_ASSETS_DIR := web/assets
WEB_ROMS := $(WEB_ASSETS_DIR)/uBASIC6502.bin $(WEB_ASSETS_DIR)/mini-BASIC65c02.bin $(WEB_ASSETS_DIR)/4kBASIC.bin
WASM_EXPORTS := ["_sim65c02_select","_sim65c02_input","_sim65c02_run_chunk","_sim65c02_cycles","_sim65c02_set_io_addrs","_sim65c02_set_maxcycles"]
SIZES_MD := Sizes.md
LSTS := uBASIC6502.LST mini-BASIC65c02.LST 4kBASIC.LST

all: roms

$(ASM): $(TOOLS_DIR)/asm65c02.c
	$(CC) $(CFLAGS) -O2 -DASM65C02_MAIN -o $@ $<

tools: $(ASM)

native-smoke:
	$(CC) $(CFLAGS) -O2 -Wall -Wextra -o /tmp/sim65c02 $(SIM_SRC)

tools-win:
	$(MAKE) -C $(TOOLS_DIR) windows

roms: $(ROMS) $(SIZES_MD)

web-assets: $(WEB_ROMS)

web-dist: web-assets
	mkdir -p $(DIST_DIR)
	cp web/index.html $(DIST_DIR)/index.html
	cp -R $(WEB_ASSETS_DIR) $(DIST_DIR)/assets
	$(EMCC) $(SIM_SRC) \
		-O2 \
		-DSIM_BROWSER_BINONLY \
		-s MODULARIZE=0 \
		-s EXPORTED_RUNTIME_METHODS='["cwrap"]' \
		-s EXPORTED_FUNCTIONS='$(WASM_EXPORTS)' \
		-s ALLOW_MEMORY_GROWTH=1 \
		-s FORCE_FILESYSTEM=1 \
		-s INVOKE_RUN=0 \
		-s EXIT_RUNTIME=0 \
		--preload-file $(WEB_ASSETS_DIR)@assets \
		-o $(DIST_DIR)/sim65c02.js

uBASIC6502.bin: uBASIC6502.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F800-$$FFFF'

mini-BASIC65c02.bin: mini-BASIC65c02.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F000-$$FFFF'

4kBASIC.bin: 4kBASIC.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F000-$$FFFF'

$(WEB_ASSETS_DIR):
	mkdir -p $@

$(WEB_ASSETS_DIR)/uBASIC6502.bin: uBASIC6502.asm $(ASM) | $(WEB_ASSETS_DIR)
	$(ASM) $< -o $@ -NoList

$(WEB_ASSETS_DIR)/mini-BASIC65c02.bin: mini-BASIC65c02.asm $(ASM) | $(WEB_ASSETS_DIR)
	$(ASM) $< -o $@ -NoList

$(WEB_ASSETS_DIR)/4kBASIC.bin: 4kBASIC.asm $(ASM) | $(WEB_ASSETS_DIR)
	$(ASM) $< -o $@ -NoList

$(SIZES_MD): uBASIC6502.asm mini-BASIC65c02.asm 4kBASIC.asm $(ASM)
	@{ \
		echo "# ROM Free Space"; \
		echo; \
		echo "Unused ROM space from \`LAST_ROM_CODE\` up to the reset/IRQ vector page (\$$FFFC)."; \
		echo "This excludes the showcase program (assembled into RAM at \$$0200)."; \
		echo; \
		echo "| Source | LAST_ROM_CODE | Free bytes before vectors |"; \
		echo "| --- | --- | ---: |"; \
		for src in uBASIC6502.asm mini-BASIC65c02.asm 4kBASIC.asm; do \
			dump=`$(ASM) $$src --dump-all`; \
			last_hex=`printf '%s\n' "$$dump" | sed -n 's/^ *\(\$$[0-9A-F]\{4\}\)  LAST_ROM_CODE$$/\1/p'`; \
			if [ -z "$$last_hex" ]; then \
				last_hex=`printf '%s\n' "$$dump" | sed -n 's/^ROM footprint: \$$[0-9A-F]\{4\}-\(\$$[0-9A-F]\{4\}\).*/\1/p'`; \
			fi; \
			last_dec=$$((0x$${last_hex#\$$})); \
			free_dec=$$((0xFFFC - last_dec)); \
			printf '| %s | %s | %d (0x%X) |\n' "$$src" "$$last_hex" "$$free_dec" "$$free_dec"; \
		done; \
	} > $(SIZES_MD)

clean-web-assets:
	rm -f $(WEB_ROMS)

clean-web-dist:
	rm -rf $(DIST_DIR)

clean: clean-web-assets clean-web-dist
	rm -f $(ROMS) $(SIZES_MD) $(LSTS) $(ASM)
