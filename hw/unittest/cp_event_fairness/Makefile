ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := cp_event_fairness
EVENT_WAIT_FAIRNESS ?= 1

RTL_DIR := $(VORTEX_HOME)/hw/rtl
SRC_DIR := $(VORTEX_HOME)/hw/unittest/$(PROJECT)

CXXFLAGS := -I$(SRC_DIR) -I$(VORTEX_HOME)/hw/unittest/common -I$(SW_COMMON_DIR)
CXXFLAGS += -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw
CXXFLAGS += -DEVENT_WAIT_FAIRNESS=$(EVENT_WAIT_FAIRNESS)
PARAMS += -GENABLE_EVENT_WAIT_FAIRNESS=$(EVENT_WAIT_FAIRNESS)
# 专用测试内存只消费 EVENT 所需的 AXI 字段，其余协议属性有意不使用。
PARAMS += -Wno-UNUSEDSIGNAL

SRCS := $(SRC_DIR)/main.cpp
RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/VX_trace_pkg.sv \
            $(RTL_DIR)/cp/VX_cp_pkg.sv
RTL_INCLUDE := -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(RTL_DIR) \
               -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/mem \
               -I$(RTL_DIR)/fpu -I$(RTL_DIR)/core -I$(RTL_DIR)/cp -I$(SRC_DIR)
TOP := VX_cp_event_fairness_top

include ../common.mk
