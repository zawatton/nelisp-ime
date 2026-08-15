ROOT := ../..
CXX ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror
.PHONY: smoke clean
smoke: build/common-smoke
	./build/common-smoke "$(abspath $(ROOT)/target/nelisp)" "$(abspath $(ROOT))" "$(abspath build/learning.json)"
build/common-smoke: nelisp_ime_client.cpp nelisp_ime_client.hpp smoke.cpp
	mkdir -p build
	$(CXX) $(CXXFLAGS) nelisp_ime_client.cpp smoke.cpp -o $@
clean:
	rm -rf build
