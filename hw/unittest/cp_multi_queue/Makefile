ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := cp_multi_queue

# 实验11固定使用四队列，并分别编译轮询、严格优先级和Aging三种调度模式。
NUM_QUEUES ?= 4
PRIORITY_ARBITRATION ?= 1
ARBITRATION_AGING ?= 1
EVENT_WAIT_FAIRNESS ?= 1

PARAMS += -GNUM_QUEUES=$(NUM_QUEUES)
PARAMS += -GENABLE_PRIORITY_ARBITRATION=$(PRIORITY_ARBITRATION)
PARAMS += -GENABLE_ARBITRATION_AGING=$(ARBITRATION_AGING)
PARAMS += -GENABLE_EVENT_WAIT_FAIRNESS=$(EVENT_WAIT_FAIRNESS)

RTL_DIR := $(VORTEX_HOME)/hw/rtl
DPI_DIR := $(VORTEX_HOME)/hw/dpi
SRC_DIR := $(VORTEX_HOME)/hw/unittest/$(PROJECT)
CORE_TB_DIR := $(VORTEX_HOME)/hw/unittest/cp_core

CXXFLAGS := -I$(SRC_DIR) -I$(CORE_TB_DIR) -I$(VORTEX_HOME)/hw/unittest/common
CXXFLAGS += -I$(SW_COMMON_DIR) -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw
CXXFLAGS += -DPRIORITY_ARBITRATION=$(PRIORITY_ARBITRATION)
CXXFLAGS += -DARBITRATION_AGING=$(ARBITRATION_AGING)

SRCS := $(SRC_DIR)/main.cpp
RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/VX_trace_pkg.sv \
            $(RTL_DIR)/cp/VX_cp_pkg.sv
RTL_INCLUDE := -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(RTL_DIR) -I$(DPI_DIR) \
               -I$(RTL_DIR)/libs -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/mem \
               -I$(RTL_DIR)/fpu -I$(RTL_DIR)/core -I$(RTL_DIR)/cp \
               -I$(CORE_TB_DIR) -I$(SRC_DIR)
TOP := VX_cp_core_top

include ../common.mk
