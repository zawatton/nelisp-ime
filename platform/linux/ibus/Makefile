PREFIX ?= /usr
.PHONY: check smoke desktop-check install
check:
	python3 -m py_compile ibus-engine-nelisp nelisp_client.py desktop-entry-app.py verify-desktop.py verify-desktop-suite.py
	xmllint --noout nelisp-ime.xml
smoke: check
	NELISP_IME_RUNTIME="$(abspath ../../../target/nelisp)" NELISP_IME_ROOT="$(abspath ../../..)" XDG_DATA_HOME="$(abspath build/data)" python3 smoke.py
desktop-check: check
	NELISP_IME_RUNTIME="$(abspath ../../../target/nelisp)" NELISP_IME_ROOT="$(abspath ../../..)" python3 verify-desktop-suite.py build/desktop
install:
	install -Dm755 ibus-engine-nelisp "$(DESTDIR)$(PREFIX)/libexec/ibus-engine-nelisp"
	install -Dm644 nelisp_client.py "$(DESTDIR)$(PREFIX)/libexec/nelisp_client.py"
	install -Dm644 nelisp-ime.xml "$(DESTDIR)$(PREFIX)/share/ibus/component/nelisp-ime.xml"
