ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := cp_runtime_multi_queue
SRC_DIR := $(VORTEX_HOME)/tests/unittest/$(PROJECT)
RT_LIB_DIR := $(ROOT_DIR)/sw/runtime

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors -Werror
CXXFLAGS += -I$(VORTEX_HOME)/sw/runtime/include
CXXFLAGS += -I$(VORTEX_HOME)/sw/runtime/common

all: libvortex-mockcp.so $(PROJECT)

libvortex-mockcp.so: $(SRC_DIR)/mock_backend.cpp
	$(CXX) $(CXXFLAGS) -fPIC -shared $< -pthread -o $@

$(PROJECT): $(SRC_DIR)/main.cpp
	$(CXX) $(CXXFLAGS) $< -L$(RT_LIB_DIR) -lvortex -ldl -pthread \
		-Wl,-rpath,$(RT_LIB_DIR) -o $@

run: all
	LD_LIBRARY_PATH=$(RT_LIB_DIR):$(CURDIR) VORTEX_DRIVER=mockcp ./$(PROJECT)

clean:
	rm -f $(PROJECT) libvortex-mockcp.so

.PHONY: all run clean
