#!/bin/bash
# 构建 musl 交叉编译工具链脚本
# 支持 riscv64, loongarch64, aarch64, x86_64 四个架构
# 基于 https://github.com/lyw19b/musl-cross-make.git
# LoongArch64 支持参考: https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
MUSL_CROSS_MAKE_REPO="https://github.com/lyw19b/musl-cross-make.git"
MUSL_CROSS_MAKE_DIR="${MUSL_CROSS_MAKE_DIR:-$(pwd)/musl-cross-make}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$(pwd)/musl-toolchains}"
ARCHITECTURES="${ARCHITECTURES:-riscv64 loongarch64 aarch64 x86_64}"
PARALLEL_JOBS="${PARALLEL_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# 检测操作系统
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

OS=$(detect_os)

# 打印信息
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# 检查依赖
check_dependencies() {
    info "检查依赖..."
    
    local missing_deps=()
    
    # 检查基本工具
    for cmd in git make gcc; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    # macOS 特定依赖
    if [ "$OS" = "macos" ]; then
        if ! command -v gmake &> /dev/null; then
            warn "macOS 建议使用 gmake (GNU Make)，可以通过 'brew install make' 安装"
        fi
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "缺少以下依赖: ${missing_deps[*]}"
    fi
    
    info "依赖检查完成"
}

# 克隆或更新仓库
setup_repo() {
    if [ -d "$MUSL_CROSS_MAKE_DIR" ]; then
        info "musl-cross-make 目录已存在，更新中..."
        cd "$MUSL_CROSS_MAKE_DIR"
        git fetch origin
        git reset --hard origin/master || git reset --hard origin/main
    else
        info "克隆 musl-cross-make 仓库..."
        git clone "$MUSL_CROSS_MAKE_REPO" "$MUSL_CROSS_MAKE_DIR"
    fi
}

# 创建配置文件
create_config() {
    local arch=$1
    local config_file="$MUSL_CROSS_MAKE_DIR/config.mak"
    
    info "为 $arch 创建配置..."
    
    # 根据架构设置目标三元组
    case "$arch" in
        riscv64)
            TARGET="riscv64-linux-musl"
            ;;
        loongarch64)
            TARGET="loongarch64-linux-musl"
            ;;
        aarch64)
            TARGET="aarch64-linux-musl"
            ;;
        x86_64)
            TARGET="x86_64-linux-musl"
            ;;
        *)
            error "不支持的架构: $arch"
            ;;
    esac
    
    # 确保目录存在
    mkdir -p "$MUSL_CROSS_MAKE_DIR"
    cd "$MUSL_CROSS_MAKE_DIR"
    
    # 检查 musl-cross-make 是否存在
    if [ ! -f "$MUSL_CROSS_MAKE_DIR/Makefile" ]; then
        error "musl-cross-make Makefile 不存在，请先运行 setup_repo"
    fi
    
    # 写入配置文件
    cat > "$config_file" <<EOF
# musl-cross-make 配置 - $arch
# 自动生成，请勿手动编辑

TARGET = $TARGET
OUTPUT = $INSTALL_PREFIX/$TARGET

# 通用配置
COMMON_CONFIG += --disable-nls
COMMON_CONFIG += --enable-languages=c,c++

# GCC 配置
GCC_CONFIG += --disable-libsanitizer
GCC_CONFIG += --disable-libvtv
GCC_CONFIG += --disable-libmpx
GCC_CONFIG += --disable-libssp
GCC_CONFIG += --disable-libquadmath
GCC_CONFIG += --disable-decimal-float
GCC_CONFIG += --disable-libgomp
GCC_CONFIG += --disable-libatomic
GCC_CONFIG += --disable-libitm
GCC_CONFIG += --disable-libmudflap
GCC_CONFIG += --disable-libcilkrts
GCC_CONFIG += --disable-libstdc++-v3
GCC_CONFIG += --enable-default-pie
GCC_CONFIG += --enable-tls
GCC_CONFIG += --enable-threads=posix
GCC_CONFIG += --enable-shared
GCC_CONFIG += --enable-static
GCC_CONFIG += --with-system-zlib
GCC_CONFIG += --enable-__cxa_atexit
GCC_CONFIG += --disable-libgcc
GCC_CONFIG += --disable-multilib
GCC_CONFIG += --with-gnu-as
GCC_CONFIG += --with-gnu-ld

# Musl 配置
MUSL_CONFIG += --enable-debug
MUSL_CONFIG += --enable-optimize
EOF

    # LoongArch64 特定配置
    # 参考: https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md
    if [ "$arch" = "loongarch64" ]; then
        cat >> "$config_file" <<EOF

# LoongArch64 特定配置
# 基于 musl-cross-make 的 LoongArch64 支持
GCC_CONFIG += --with-arch=loongarch64
GCC_CONFIG += --with-abi=lp64d
EOF
    fi
    
    # macOS 特定配置
    if [ "$OS" = "macos" ]; then
        # 检测架构
        MACOS_ARCH=$(uname -m)
        if [ "$MACOS_ARCH" = "arm64" ]; then
            BUILD_TRIPLE="aarch64-apple-darwin"
        else
            BUILD_TRIPLE="x86_64-apple-darwin"
        fi
        cat >> "$config_file" <<EOF

# macOS 特定配置
COMMON_CONFIG += --build=$BUILD_TRIPLE
COMMON_CONFIG += --host=$BUILD_TRIPLE
EOF
    fi
    
    info "配置已写入 $config_file"
}

# 构建单个架构的工具链
build_arch() {
    local arch=$1
    
    info "开始构建 $arch 工具链..."
    
    cd "$MUSL_CROSS_MAKE_DIR"
    
    # 清理之前的构建和配置
    if [ -f "$MUSL_CROSS_MAKE_DIR/Makefile" ]; then
        info "清理之前的构建..."
        if [ "$OS" = "macos" ] && command -v gmake &> /dev/null; then
            gmake clean || true
        else
            make clean || true
        fi
    fi
    
    # 创建新配置
    create_config "$arch"
    
    # 构建工具链
    info "使用 $PARALLEL_JOBS 个并行任务构建..."
    if [ "$OS" = "macos" ] && command -v gmake &> /dev/null; then
        MAKE_CMD="gmake"
    else
        MAKE_CMD="make"
    fi
    
    # 执行构建
    if ! $MAKE_CMD -j"$PARALLEL_JOBS"; then
        error "构建 $arch 工具链失败，请检查错误信息"
    fi
    
    info "$arch 工具链构建完成"
}

# 安装工具链
install_toolchain() {
    local arch=$1
    
    info "安装 $arch 工具链到 $INSTALL_PREFIX..."
    
    cd "$MUSL_CROSS_MAKE_DIR"
    
    if [ "$OS" = "macos" ] && command -v gmake &> /dev/null; then
        MAKE_CMD="gmake"
    else
        MAKE_CMD="make"
    fi
    
    # 创建安装目录
    mkdir -p "$INSTALL_PREFIX"
    
    if ! $MAKE_CMD install; then
        error "安装 $arch 工具链失败，请检查错误信息"
    fi
    
    # 验证安装
    case "$arch" in
        riscv64)
            TOOLCHAIN_BIN="$INSTALL_PREFIX/riscv64-linux-musl/bin"
            ;;
        loongarch64)
            TOOLCHAIN_BIN="$INSTALL_PREFIX/loongarch64-linux-musl/bin"
            ;;
        aarch64)
            TOOLCHAIN_BIN="$INSTALL_PREFIX/aarch64-linux-musl/bin"
            ;;
        x86_64)
            TOOLCHAIN_BIN="$INSTALL_PREFIX/x86_64-linux-musl/bin"
            ;;
    esac
    
    if [ -d "$TOOLCHAIN_BIN" ] && [ -f "$TOOLCHAIN_BIN/${arch}-linux-musl-gcc" ]; then
        info "$arch 工具链安装完成: $TOOLCHAIN_BIN"
    else
        warn "$arch 工具链可能未正确安装，请检查 $TOOLCHAIN_BIN"
    fi
}

# 创建环境设置脚本
create_env_script() {
    info "创建环境设置脚本..."
    
    local env_script="$INSTALL_PREFIX/setup-env.sh"
    
    cat > "$env_script" <<'EOF'
#!/bin/bash
# musl 工具链环境设置脚本
# 使用方法: source setup-env.sh [arch]
# 支持的架构: riscv64, loongarch64, aarch64, x86_64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="${1:-riscv64}"

case "$ARCH" in
    riscv64)
        TARGET="riscv64-linux-musl"
        ;;
    loongarch64)
        TARGET="loongarch64-linux-musl"
        ;;
    aarch64)
        TARGET="aarch64-linux-musl"
        ;;
    x86_64)
        TARGET="x86_64-linux-musl"
        ;;
    *)
        echo "不支持的架构: $ARCH"
        echo "支持的架构: riscv64, loongarch64, aarch64, x86_64"
        return 1
        ;;
esac

TOOLCHAIN_BIN="$SCRIPT_DIR/$TARGET/bin"

if [ -d "$TOOLCHAIN_BIN" ]; then
    export PATH="$TOOLCHAIN_BIN:$PATH"
    echo "已设置 $ARCH musl 工具链路径: $TOOLCHAIN_BIN"
else
    echo "错误: 工具链目录不存在: $TOOLCHAIN_BIN"
    return 1
fi
EOF

    chmod +x "$env_script"
    info "环境设置脚本已创建: $env_script"
}

# 主函数
main() {
    info "开始构建 musl 交叉编译工具链"
    info "架构: $ARCHITECTURES"
    info "安装路径: $INSTALL_PREFIX"
    info "操作系统: $OS"
    
    check_dependencies
    setup_repo
    
    # 创建安装目录
    mkdir -p "$INSTALL_PREFIX"
    
    # 构建每个架构
    for arch in $ARCHITECTURES; do
        info "=========================================="
        info "构建架构: $arch"
        info "=========================================="
        build_arch "$arch"
        install_toolchain "$arch"
    done
    
    # 创建环境设置脚本
    create_env_script
    
    info "=========================================="
    info "所有工具链构建完成！"
    info "=========================================="
    info "工具链安装位置: $INSTALL_PREFIX"
    info ""
    info "使用方法:"
    info "  1. 设置环境变量:"
    info "     export PATH=\"$INSTALL_PREFIX/<arch>-linux-musl/bin:\$PATH\""
    info ""
    info "  2. 或使用环境设置脚本:"
    info "     source $INSTALL_PREFIX/setup-env.sh <arch>"
    info ""
    info "示例:"
    info "     source $INSTALL_PREFIX/setup-env.sh riscv64"
    info "     source $INSTALL_PREFIX/setup-env.sh loongarch64"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            MUSL_CROSS_MAKE_REPO="$2"
            shift 2
            ;;
        --dir)
            MUSL_CROSS_MAKE_DIR="$2"
            shift 2
            ;;
        --prefix)
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        --arch)
            ARCHITECTURES="$2"
            shift 2
            ;;
        --jobs)
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --repo URL         musl-cross-make 仓库 URL (默认: $MUSL_CROSS_MAKE_REPO)"
            echo "  --dir DIR          musl-cross-make 源码目录 (默认: ./musl-cross-make)"
            echo "  --prefix DIR       工具链安装路径 (默认: ./musl-toolchains)"
            echo "  --arch ARCHES      要构建的架构，用空格分隔 (默认: $ARCHITECTURES)"
            echo "  --jobs N           并行构建任务数 (默认: 自动检测)"
            echo "  -h, --help         显示此帮助信息"
            exit 0
            ;;
        *)
            error "未知选项: $1"
            ;;
    esac
done

main

