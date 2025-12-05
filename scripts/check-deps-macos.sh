#!/bin/bash
# macOS 依赖检查脚本

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# 检查是否为 macOS
if [[ "$(uname -s)" != "Darwin" ]]; then
    error "此脚本仅适用于 macOS"
    exit 1
fi

section "检查基本工具"

missing_deps=()

# 检查 Git
if command -v git &> /dev/null; then
    info "Git: $(git --version)"
else
    missing_deps+=("git")
    error "Git 未安装"
fi

# 检查 Make
if command -v make &> /dev/null; then
    MAKE_VERSION=$(make --version 2>/dev/null | head -n1 || echo "未知版本")
    info "Make: $MAKE_VERSION"
    
    # 检查是否为 GNU Make
    if make --version 2>/dev/null | grep -q "GNU Make"; then
        info "  检测到 GNU Make"
    else
        warn "  建议使用 GNU Make (gmake)，可以通过 'brew install make' 安装"
    fi
else
    missing_deps+=("make")
    error "Make 未安装"
fi

# 检查 GCC/Clang
if command -v gcc &> /dev/null; then
    GCC_VERSION=$(gcc --version 2>/dev/null | head -n1 || echo "未知版本")
    info "GCC/Clang: $GCC_VERSION"
elif command -v clang &> /dev/null; then
    CLANG_VERSION=$(clang --version 2>/dev/null | head -n1 || echo "未知版本")
    info "Clang: $CLANG_VERSION"
else
    missing_deps+=("gcc/clang")
    error "GCC 或 Clang 未安装"
fi

section "检查 Homebrew"

if command -v brew &> /dev/null; then
    info "Homebrew: $(brew --version | head -n1)"
else
    warn "Homebrew 未安装"
    warn "  建议安装 Homebrew: https://brew.sh"
    warn "  安装后可以更方便地安装依赖"
fi

section "检查推荐工具"

# 检查 GNU Make (推荐)
if command -v gmake &> /dev/null; then
    info "GNU Make (gmake): $(gmake --version | head -n1)"
else
    warn "GNU Make (gmake) 未安装"
    warn "  安装命令: brew install make"
fi

# 检查其他有用的工具
for tool in wget curl xz; do
    if command -v $tool &> /dev/null; then
        info "$tool: 已安装"
    else
        warn "$tool: 未安装 (可选)"
    fi
done

section "检查 Rust 工具链"

if command -v rustc &> /dev/null; then
    info "Rust: $(rustc --version)"
    if command -v cargo &> /dev/null; then
        info "Cargo: $(cargo --version)"
    else
        warn "Cargo 未安装"
    fi
else
    warn "Rust 未安装"
    warn "  安装命令: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
fi

section "检查 QEMU"

if command -v qemu-system-riscv64 &> /dev/null; then
    QEMU_VERSION=$(qemu-system-riscv64 --version 2>/dev/null | head -n1 || echo "未知版本")
    info "QEMU: $QEMU_VERSION"
    
    # 检查版本 (LoongArch64 需要 QEMU 10+)
    QEMU_VER=$(qemu-system-riscv64 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "0")
    if (( $(echo "$QEMU_VER >= 10.0" | bc -l 2>/dev/null || echo 0) )); then
        info "  QEMU 版本满足要求 (>= 10.0)"
    else
        warn "  LoongArch64 需要 QEMU 10+，当前版本可能不支持"
    fi
else
    warn "QEMU 未安装"
    warn "  安装命令: brew install qemu"
    warn "  注意: LoongArch64 需要 QEMU 10+，可能需要从源码编译"
fi

section "总结"

if [ ${#missing_deps[@]} -eq 0 ]; then
    info "所有必需依赖已安装"
    echo ""
    info "可以开始构建 musl 工具链:"
    echo "  make musl-toolchain"
else
    error "缺少以下必需依赖: ${missing_deps[*]}"
    echo ""
    info "安装建议:"
    if command -v brew &> /dev/null; then
        echo "  brew install git make gcc"
    else
        echo "  1. 安装 Homebrew: https://brew.sh"
        echo "  2. 运行: brew install git make gcc"
    fi
    exit 1
fi

