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
    local missing_pkgs=()
    
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
    
    # 检查系统库依赖（Linux）
    if [ "$OS" = "linux" ]; then
        # 检查 zlib 开发库（GCC 构建需要）
        if ! pkg-config --exists zlib 2>/dev/null && [ ! -f /usr/include/zlib.h ] && [ ! -f /usr/local/include/zlib.h ]; then
            missing_pkgs+=("zlib1g-dev")
        fi
        
        # 检查其他常见构建依赖
        if ! command -v bison &> /dev/null; then
            missing_pkgs+=("bison")
        fi
        
        if ! command -v flex &> /dev/null; then
            missing_pkgs+=("flex")
        fi
        
        # texinfo 包提供 makeinfo 命令，而不是 texinfo 命令
        if ! command -v makeinfo &> /dev/null; then
            missing_pkgs+=("texinfo")
        fi
    fi
    
    # macOS 特定库依赖
    if [ "$OS" = "macos" ]; then
        # 检查 zlib（macOS 通常自带，但需要确认）
        if ! pkg-config --exists zlib 2>/dev/null && [ ! -f /usr/include/zlib.h ] && [ ! -f /opt/homebrew/include/zlib.h ] && [ ! -f /usr/local/include/zlib.h ]; then
            missing_pkgs+=("zlib (通过 Homebrew: brew install zlib)")
        fi
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "缺少以下命令: ${missing_deps[*]}"
    fi
    
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        error "缺少以下系统包:\n  ${missing_pkgs[*]}\n\n请安装它们:\n  Ubuntu/Debian: sudo apt-get install ${missing_pkgs[*]}\n  Fedora/RHEL: sudo dnf install ${missing_pkgs[*]//zlib1g-dev/zlib-devel}\n  macOS: brew install ${missing_pkgs[*]//zlib1g-dev/zlib}"
    fi
    
    info "依赖检查完成"
}

# 克隆或更新仓库
setup_repo() {
    if [ -d "$MUSL_CROSS_MAKE_DIR" ]; then
        info "musl-cross-make 目录已存在，尝试更新..."
        cd "$MUSL_CROSS_MAKE_DIR"
        
        # 检查是否是有效的 git 仓库
        if [ -d ".git" ]; then
            # 尝试更新，如果失败则使用本地版本
            if git fetch origin 2>/dev/null; then
                git reset --hard origin/master 2>/dev/null || git reset --hard origin/main 2>/dev/null
                info "仓库更新成功"
            else
                warn "无法连接到 GitHub，使用本地已有仓库继续构建"
                warn "如果构建失败，请检查网络连接后重试"
            fi
        else
            warn "目录存在但不是有效的 git 仓库，跳过更新"
        fi
    else
        info "克隆 musl-cross-make 仓库..."
        if ! git clone "$MUSL_CROSS_MAKE_REPO" "$MUSL_CROSS_MAKE_DIR" 2>/dev/null; then
            error "无法克隆仓库，请检查网络连接。\n可以使用以下镜像：\n  - Gitee: https://gitee.com/mirrors/musl-cross-make.git\n  - 或者手动下载并解压到 $MUSL_CROSS_MAKE_DIR"
        fi
    fi
    
    # 验证仓库是否可用
    if [ ! -f "$MUSL_CROSS_MAKE_DIR/Makefile" ]; then
        error "musl-cross-make Makefile 不存在，请检查仓库是否正确克隆"
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
# 注意：RISC-V 会在特定配置中覆盖共享库设置
GCC_CONFIG += --enable-shared
GCC_CONFIG += --enable-static
GCC_CONFIG += --with-system-zlib
GCC_CONFIG += --enable-__cxa_atexit
GCC_CONFIG += --disable-multilib
GCC_CONFIG += --with-gnu-as
GCC_CONFIG += --with-gnu-ld

# Musl 配置
MUSL_CONFIG += --enable-debug
MUSL_CONFIG += --enable-optimize
EOF

    # RISC-V 特定配置
    # 禁用共享库构建以避免 RISC-V libgcc 的 PIC 重定位问题
    # 对于 musl 工具链，静态链接通常是主要使用方式
    if [ "$arch" = "riscv64" ]; then
        cat >> "$config_file" <<EOF

# RISC-V 特定配置
# 禁用共享库以避免 RISC-V libgcc 的 PIC 重定位问题
# 注意：这会禁用所有共享库，包括 musl，但对于静态链接工具链这是可以接受的
GCC_CONFIG += --disable-shared
GCC_CONFIG += --enable-static
EOF
    fi
    
    # LoongArch64 特定配置
    # 参考: https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md
    # LoongArch64 需要 GCC 13.2.0 或更高版本，以及 Linux 6.7 或更高版本
    if [ "$arch" = "loongarch64" ]; then
        cat >> "$config_file" <<EOF

# LoongArch64 特定配置
# 基于 musl-cross-make 的 LoongArch64 支持
# LoongArch64 需要 GCC 13.2.0+ 和 Linux 6.7+
GCC_VER = 13.2.0
LINUX_VER = 6.7
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
    
    # 执行构建，捕获输出以便在失败时显示
    local build_log=$(mktemp)
    if ! $MAKE_CMD -j"$PARALLEL_JOBS" 2>&1 | tee "$build_log"; then
        warn "构建失败，显示最后的错误信息："
        echo ""
        # 显示日志中最后的错误相关行
        tail -n 50 "$build_log" | grep -i -A 5 -B 5 "error\|failed\|fatal" || tail -n 30 "$build_log"
        echo ""
        rm -f "$build_log"
        error "构建 $arch 工具链失败，请检查上面的错误信息"
    fi
    rm -f "$build_log"
    
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

