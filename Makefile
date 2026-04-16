.PHONY: all tools tools-win roms clean

TOOLS_DIR := tools
ASM := $(TOOLS_DIR)/asm65c02

ROMS := uBASIC.bin uBASIC6502.bin 4kBASIC.bin

all: roms

$(ASM):
	$(MAKE) -C $(TOOLS_DIR) asm65c02

tools: $(ASM)

tools-win:
	$(MAKE) -C $(TOOLS_DIR) windows

roms: $(ROMS)

uBASIC.bin: uBASIC.asm | $(ASM)
	$(ASM) $< -o $@ -r '$$F800-$$FFFF'

uBASIC6502.bin: uBASIC6502.asm | $(ASM)
	$(ASM) $< -o $@ -r '$$F800-$$FFFF'

4kBASIC.bin: 4kBASIC.asm | $(ASM)
	$(ASM) $< -o $@ -r '$$F000-$$FFFF'

clean:
	rm -f $(ROMS)
	$(MAKE) -C $(TOOLS_DIR) clean
