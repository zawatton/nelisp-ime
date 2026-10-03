ROOT := ../..
CXX ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror
THREAD_FLAGS ?= -pthread
.PHONY: smoke fault-smoke clean
smoke: build/common-smoke
	./build/common-smoke "$(abspath $(ROOT)/target/nelisp)" "$(abspath $(ROOT))" "$(abspath build/learning.json)"
fault-smoke: build/fault-smoke build/fault-runtime
	NELISP_IME_FAULT_MODE=normal timeout 8s ./build/fault-smoke "$(abspath build/fault-runtime)"
build/common-smoke: nelisp_ime_client.cpp nelisp_ime_client.hpp smoke.cpp
	mkdir -p build
	$(CXX) $(CXXFLAGS) $(THREAD_FLAGS) nelisp_ime_client.cpp smoke.cpp -o $@
build/fault-smoke: nelisp_ime_client.cpp nelisp_ime_client.hpp fault_smoke.cpp
	mkdir -p build
	$(CXX) $(CXXFLAGS) $(THREAD_FLAGS) nelisp_ime_client.cpp fault_smoke.cpp -o $@
build/fault-runtime: fault_runtime.cpp
	mkdir -p build
	$(CXX) $(CXXFLAGS) $(THREAD_FLAGS) fault_runtime.cpp -o $@
clean:
	rm -rf build
