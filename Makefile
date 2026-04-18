.PHONY: all tools tools-win roms clean

TOOLS_DIR := tools
ASM := $(TOOLS_DIR)/asm65c02

ROMS := uBASIC.bin uBASIC6502.bin 4kBASIC.bin
SIZES_MD := Sizes.md

all: roms

$(ASM):
	$(MAKE) -C $(TOOLS_DIR) asm65c02

tools: $(ASM)

tools-win:
	$(MAKE) -C $(TOOLS_DIR) windows

roms: $(ROMS) $(SIZES_MD)

uBASIC.bin: uBASIC.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F800-$$FFFF'

uBASIC6502.bin: uBASIC6502.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F800-$$FFFF'

4kBASIC.bin: 4kBASIC.asm $(ASM)
	$(ASM) $< -o $@ -r '$$F000-$$FFFF'

$(SIZES_MD): uBASIC.asm uBASIC6502.asm 4kBASIC.asm $(ASM)
	@{ \
		echo "# ROM Free Space"; \
		echo; \
		echo "Unused ROM space from \`LAST_ROM_CODE\` up to the reset/IRQ vector page (\$$FFFC)."; \
		echo "This excludes the showcase program (assembled into RAM at \$$0200)."; \
		echo; \
		echo "| Source | LAST_ROM_CODE | Free bytes before vectors |"; \
		echo "| --- | --- | ---: |"; \
		for src in uBASIC.asm uBASIC6502.asm 4kBASIC.asm; do \
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

clean:
	rm -f $(ROMS) $(SIZES_MD)
	$(MAKE) -C $(TOOLS_DIR) clean
