# Musl 交叉编译工具链构建指南

本文档介绍如何使用 [musl-cross-make](https://github.com/lyw19b/musl-cross-make.git) 从源码构建 musl 交叉编译工具链，支持 riscv64、loongarch64、aarch64、x86_64 四个架构。

## 概述

musl-cross-make 是一个用于构建 musl libc 交叉编译工具链的构建系统。本项目集成了该仓库，并提供了自动化构建脚本，可以在 Linux 和 macOS 上编译出四个架构的 musl 工具链。

## 前置要求

### Linux

```bash
sudo apt update
sudo apt install -y build-essential git make gcc g++ wget
```

### Windows

Windows 上不能直接运行 bash 脚本，需要通过以下方式之一：

**方式 1: 使用 WSL (Windows Subsystem for Linux) - 推荐**

1. 安装 WSL2:

   ```powershell
   # 在 PowerShell (管理员权限) 中运行
   wsl --install
   ```

2. 在 WSL 中按照 Linux 的步骤操作:

   ```bash
   # 在 WSL 终端中
   sudo apt update
   sudo apt install -y build-essential git make gcc g++ wget
   ```

3. 在 WSL 中构建工具链:
   ```bash
   bash scripts/build-musl-toolchain.sh
   ```

**方式 2: 使用 Git Bash 或 MSYS2**

理论上可以使用 Git Bash 或 MSYS2，但需要确保所有依赖（make、gcc 等）都已正确安装。推荐使用 WSL。

**注意**: Windows 原生环境不支持，因为 musl-cross-make 需要 Unix 环境。

### macOS

1. 安装 Homebrew (如果尚未安装):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

2. 安装基本依赖:

   ```bash
   brew install git make gcc
   ```

3. 检查依赖 (可选):
   ```bash
   bash scripts/check-deps-macos.sh
   ```

**注意**: macOS 上建议使用 GNU Make (`gmake`)，可以通过 `brew install make` 安装。

## 快速开始

### 方法 1: 使用 Makefile 目标

```bash
# 构建所有四个架构的工具链
make musl-toolchain

# 指定安装路径
make musl-toolchain MUSL_TOOLCHAIN_DIR=/opt/musl-toolchains
```

### 方法 2: 直接使用脚本

```bash
# 构建所有架构
bash scripts/build-musl-toolchain.sh

# 只构建特定架构
bash scripts/build-musl-toolchain.sh --arch "riscv64 loongarch64"

# 指定安装路径
bash scripts/build-musl-toolchain.sh --prefix /opt/musl-toolchains

# 查看所有选项
bash scripts/build-musl-toolchain.sh --help
```

## 脚本选项

`scripts/build-musl-toolchain.sh` 支持以下选项:

- `--repo URL`: musl-cross-make 仓库 URL (默认: https://github.com/lyw19b/musl-cross-make.git)
- `--dir DIR`: musl-cross-make 源码目录 (默认: ./musl-cross-make)
- `--prefix DIR`: 工具链安装路径 (默认: ./musl-toolchains)
- `--arch ARCHES`: 要构建的架构，用空格分隔 (默认: riscv64 loongarch64 aarch64 x86_64)
- `--jobs N`: 并行构建任务数 (默认: 自动检测)

## 使用构建的工具链

### 设置环境变量

构建完成后，工具链会安装到指定目录 (默认为 `./musl-toolchains`)。每个架构的工具链位于独立的子目录中:

```
musl-toolchains/
├── riscv64-linux-musl/
│   └── bin/
├── loongarch64-linux-musl/
│   └── bin/
├── aarch64-linux-musl/
│   └── bin/
└── x86_64-linux-musl/
    └── bin/
```

### 方法 1: 使用环境设置脚本

```bash
# 设置 riscv64 工具链
source musl-toolchains/setup-env.sh riscv64

# 设置 loongarch64 工具链
source musl-toolchains/setup-env.sh loongarch64
```

### 方法 2: 手动设置 PATH

```bash
# riscv64
export PATH="$PWD/musl-toolchains/riscv64-linux-musl/bin:$PATH"

# loongarch64
export PATH="$PWD/musl-toolchains/loongarch64-linux-musl/bin:$PATH"

# aarch64
export PATH="$PWD/musl-toolchains/aarch64-linux-musl/bin:$PATH"

# x86_64
export PATH="$PWD/musl-toolchains/x86_64-linux-musl/bin:$PATH"
```

### 验证安装

设置环境变量后，可以验证工具链是否可用:

```bash
# 检查编译器
riscv64-linux-musl-gcc --version
loongarch64-linux-musl-gcc --version

# 检查工具链路径
which riscv64-linux-musl-gcc
```

## 在 StarryOS 中使用

### 使用本地编译的工具链

1. 构建工具链:

   ```bash
   make musl-toolchain
   ```

2. 设置环境变量:

   ```bash
   source musl-toolchains/setup-env.sh riscv64
   ```

3. 构建 StarryOS:
   ```bash
   make ARCH=riscv64 build
   ```

### 在 Makefile 中指定工具链路径

如果不想修改全局 PATH，可以在构建时指定 `CROSS_COMPILE`:

```bash
# 使用本地编译的工具链
make ARCH=riscv64 build \
  CROSS_COMPILE=$(pwd)/musl-toolchains/riscv64-linux-musl/bin/riscv64-linux-musl-
```

## 架构特定说明

### LoongArch64

LoongArch64 工具链需要特殊的配置。构建脚本会自动应用以下配置:

- `--with-arch=loongarch64`
- `--with-abi=lp64d`

这些配置基于 [musl-cross-make 的 LoongArch64 支持](https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md)。该仓库专门为 LoongArch64 架构提供了完整的交叉编译工具链支持。

### macOS 交叉编译

在 macOS 上构建 Linux 工具链时，构建脚本会自动检测系统架构并设置相应的构建配置:

- **Apple Silicon (arm64)**: `--build=aarch64-apple-darwin --host=aarch64-apple-darwin`
- **Intel (x86_64)**: `--build=x86_64-apple-darwin --host=x86_64-apple-darwin`

这确保了在 macOS 上可以成功编译出所有四个架构的 musl 工具链，包括 LoongArch64。

## 清理

```bash
# 清理构建文件 (保留源码)
make musl-toolchain-clean

# 完全清理 (删除源码和安装目录)
make musl-toolchain-distclean
```

## 故障排除

### 构建失败

1. **检查依赖**: 确保所有必需的工具都已安装
2. **检查磁盘空间**: 构建过程需要大量磁盘空间 (建议至少 10GB)
3. **检查网络**: 构建过程需要下载源码，确保网络连接正常
4. **查看日志**: 构建失败时会显示错误信息，根据错误信息排查

### macOS 特定问题

1. **GNU Make**: 如果遇到 Makefile 语法错误，尝试安装 GNU Make:

   ```bash
   brew install make
   ```

   然后使用 `gmake` 代替 `make`

2. **权限问题**: 如果遇到权限错误，确保有写入权限:

   ```bash
   chmod -R u+w musl-cross-make musl-toolchains
   ```

3. **QEMU 版本**: LoongArch64 需要 QEMU 10+，macOS 上的 Homebrew 版本可能较旧，需要从源码编译:
   ```bash
   brew install --build-from-source qemu
   ```

### 并行构建问题

如果遇到并行构建问题，可以减少并行任务数:

```bash
bash scripts/build-musl-toolchain.sh --jobs 2
```

## 参考资源

- [musl-cross-make 仓库](https://github.com/lyw19b/musl-cross-make) - 支持 LoongArch64 的 musl 交叉编译工具链构建系统
- [LoongArch64 README](https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md) - LoongArch64 架构的详细构建说明
- [musl libc 官网](https://musl.libc.org/) - musl C 标准库官方文档

### LoongArch64 支持说明

本项目使用的 musl-cross-make 仓库 (https://github.com/lyw19b/musl-cross-make.git) 提供了对 LoongArch64 架构的完整支持。该仓库基于标准的 musl-cross-make，并添加了 LoongArch64 的交叉编译支持。

理论上，可以在该仓库的基础上编译出四个架构的 musl 工具链：

- **riscv64-linux-musl**
- **loongarch64-linux-musl**
- **aarch64-linux-musl**
- **x86_64-linux-musl**

在 macOS 上，构建脚本会自动检测系统架构并设置相应的构建配置，确保可以成功编译出所有四个架构的工具链。

## 贡献

如果遇到问题或有改进建议，欢迎提交 Issue 或 Pull Request。
