# Build Options
export ARCH := riscv64
export LOG := warn
export DWARF := y
export MEMTRACK := n

# QEMU Options
export BLK := y
export NET := y
export VSOCK := n
export MEM := 1G
export ICOUNT := n

# Generated Options
export A := $(PWD)
export NO_AXSTD := y
export AX_LIB := axfeat
export APP_FEATURES := qemu

ifeq ($(MEMTRACK), y)
	APP_FEATURES += starry-api/memtrack
endif

default: build

ROOTFS_URL = https://github.com/Starry-OS/rootfs/releases/download/20250917
ROOTFS_IMG = rootfs-$(ARCH).img

rootfs:
	@if [ ! -f $(ROOTFS_IMG) ]; then \
		echo "Image not found, downloading..."; \
		curl -f -L $(ROOTFS_URL)/$(ROOTFS_IMG).xz -O; \
		xz -d $(ROOTFS_IMG).xz; \
	fi
	@cp $(ROOTFS_IMG) arceos/disk.img

img:
	@echo -e "\033[33mWARN: The 'img' target is deprecated. Please use 'rootfs' instead.\033[0m"
	@$(MAKE) --no-print-directory rootfs

defconfig justrun clean:
	@make -C arceos $@

build run debug disasm: defconfig
	@make -C arceos $@

# Aliases
rv:
	$(MAKE) ARCH=riscv64 run

la:
	$(MAKE) ARCH=loongarch64 run

vf2:
	$(MAKE) ARCH=riscv64 APP_FEATURES=vf2 MYPLAT=axplat-riscv64-visionfive2 BUS=mmio build

# Musl toolchain build targets
MUSL_TOOLCHAIN_DIR ?= $(PWD)/musl-toolchains
MUSL_CROSS_MAKE_DIR ?= $(PWD)/musl-cross-make

musl-toolchain:
	@echo "构建 musl 交叉编译工具链..."
	@bash scripts/build-musl-toolchain.sh --prefix $(MUSL_TOOLCHAIN_DIR)

musl-toolchain-clean:
	@echo "清理 musl-cross-make 构建目录..."
	@if [ -d "$(MUSL_CROSS_MAKE_DIR)" ]; then \
		cd $(MUSL_CROSS_MAKE_DIR) && make clean || true; \
	fi

musl-toolchain-distclean:
	@echo "完全清理 musl 工具链..."
	@rm -rf $(MUSL_CROSS_MAKE_DIR) $(MUSL_TOOLCHAIN_DIR)

# Setup musl toolchain PATH for current shell
musl-env:
	@if [ -f "$(MUSL_TOOLCHAIN_DIR)/setup-env.sh" ]; then \
		echo "使用以下命令设置环境:"; \
		echo "  source $(MUSL_TOOLCHAIN_DIR)/setup-env.sh $(ARCH)"; \
	else \
		echo "错误: 工具链未构建，请先运行 'make musl-toolchain'"; \
	fi

.PHONY: build run justrun debug disasm clean musl-toolchain musl-toolchain-clean musl-toolchain-distclean musl-env
