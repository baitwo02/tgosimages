OUT ?= build
CC ?= cc
CXX ?= c++
CFLAGS ?= -O2 -Wall -Wextra
CXXFLAGS ?= -O2 -Wall -Wextra

COMMON_INC := common/include
LINUX_OUT := $(OUT)/linux/ivshmem-linux-demo
LINUX_OBJ_DIR := $(OUT)/linux/obj

COMMON_SRCS := \
	common/src/ivc_ring.c \
	common/src/ivc_client.c \
	common/src/ivc_demo.c \
	common/src/ivc_sdk.c

LINUX_C_SRCS := \
	linux/src/ivc_platform.c \
	$(COMMON_SRCS)

LINUX_C_OBJS := $(patsubst %.c,$(LINUX_OBJ_DIR)/%.o,$(LINUX_C_SRCS))
LINUX_CPP_OBJS := $(LINUX_OBJ_DIR)/linux/init.o
LINUX_OBJS := $(LINUX_CPP_OBJS) $(LINUX_C_OBJS)

.PHONY: all linux clean

all: linux

linux: $(LINUX_OUT)

$(LINUX_OUT): $(LINUX_OBJS)
	@mkdir -p $(dir $@)
	$(CXX) -o $@ $^

$(LINUX_OBJ_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(COMMON_INC) -c $< -o $@

$(LINUX_OBJ_DIR)/%.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -I$(COMMON_INC) -c $< -o $@

clean:
	rm -rf $(OUT)
