.PHONY: all tools tools-win roms web-assets web-dist native-smoke clean clean-web-assets clean-web-dist

TOOLS_DIR := tools
ASM := $(TOOLS_DIR)/asm65c02
SIM_SRC := $(TOOLS_DIR)/sim65c02.c
DIST_DIR := dist
EMCC ?= emcc

ROMS := uBASIC6502.bin mini-BASIC65c02.bin 4kBASIC.bin
WEB_ASSETS_DIR := web/assets
WEB_ROMS := $(WEB_ASSETS_DIR)/uBASIC6502.bin $(WEB_ASSETS_DIR)/mini-BASIC65c02.bin
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
		-s MODULARIZE=0 \
		-s EXPORTED_RUNTIME_METHODS='["cwrap"]' \
		-s EXPORTED_FUNCTIONS='$(WASM_EXPORTS)' \
		-s ALLOW_MEMORY_GROWTH=1 \
		-s INITIAL_MEMORY=67108864 \
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
	$(ASM) $< -o $@ -r '$$F800-$$FFFF' -NoList

$(WEB_ASSETS_DIR)/mini-BASIC65c02.bin: mini-BASIC65c02.asm $(ASM) | $(WEB_ASSETS_DIR)
	$(ASM) $< -o $@ -r '$$F000-$$FFFF' -NoList

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
