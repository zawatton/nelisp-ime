ROOT := ../..
BUILD := build
APP := $(BUILD)/NelispIME.app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
SOURCES := $(wildcard NelispIME/*.m)
.PHONY: all clean install smoke
all: $(MACOS)/NelispIME
$(MACOS)/NelispIME: $(SOURCES) NelispIME/NelispEngineClient.h NelispIME/NelispInputController.h NelispIME/Info.plist $(ROOT)/target/nelisp $(ROOT)/packages/nelisp-ime/data/nelisp-ime-dictionary-data.el
	mkdir -p $(MACOS) $(RESOURCES)/nelisp-root/packages/nelisp-json/src $(RESOURCES)/nelisp-root/packages/nelisp-ime/src $(RESOURCES)/nelisp-root/packages/nelisp-ime/data
	clang -fobjc-arc -fmodules -Wall -Wextra -framework Cocoa -framework InputMethodKit $(SOURCES) -o $@
	cp NelispIME/Info.plist $(CONTENTS)/Info.plist
	cp $(ROOT)/target/nelisp $(RESOURCES)/nelisp
	cp $(ROOT)/packages/nelisp-json/src/nelisp-json.el $(RESOURCES)/nelisp-root/packages/nelisp-json/src/
	cp $(ROOT)/packages/nelisp-ime/src/*.el $(RESOURCES)/nelisp-root/packages/nelisp-ime/src/
	cp $(ROOT)/packages/nelisp-ime/data/nelisp-ime-dictionary-data.el $(RESOURCES)/nelisp-root/packages/nelisp-ime/data/
	sips -s format tiff NelispIME/Assets/icon.svg --out $(RESOURCES)/NelispIME.tiff >/dev/null
	codesign --force --deep --sign - $(APP)
install: all
	mkdir -p "$(HOME)/Library/Input Methods"
	ditto $(APP) "$(HOME)/Library/Input Methods/NelispIME.app"
smoke: all
	clang -fobjc-arc -fmodules -Wall -Wextra -framework Foundation NelispIME/NelispEngineClient.m Smoke.m -o $(BUILD)/engine-smoke
	NELISP_IME_RUNTIME="$(abspath $(ROOT)/target/nelisp)" NELISP_IME_ROOT="$(abspath $(ROOT))" $(BUILD)/engine-smoke
	plutil -lint $(CONTENTS)/Info.plist
clean:
	rm -rf $(BUILD)
