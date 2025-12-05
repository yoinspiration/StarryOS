# Musl 工具链快速开始

## 快速构建

```bash
# 构建所有四个架构 (riscv64, loongarch64, aarch64, x86_64)
make musl-toolchain

# 或使用脚本
bash scripts/build-musl-toolchain.sh
```

## 使用构建的工具链

```bash
# 设置环境 (选择需要的架构)
source musl-toolchains/setup-env.sh riscv64
source musl-toolchains/setup-env.sh loongarch64
source musl-toolchains/setup-env.sh aarch64
source musl-toolchains/setup-env.sh x86_64

# 验证安装
riscv64-linux-musl-gcc --version
```

## 在 StarryOS 中使用

```bash
# 1. 构建工具链
make musl-toolchain

# 2. 设置环境
source musl-toolchains/setup-env.sh riscv64

# 3. 构建 StarryOS
make ARCH=riscv64 build
```

## macOS 用户

在 macOS 上可以成功编译出所有四个架构的 musl 工具链（riscv64、loongarch64、aarch64、x86_64）。

```bash
# 1. 检查依赖
bash scripts/check-deps-macos.sh

# 2. 安装缺失的依赖 (如果需要)
brew install git make gcc

# 3. 构建所有架构的工具链
make musl-toolchain

# 或只构建特定架构
bash scripts/build-musl-toolchain.sh --arch "loongarch64"

# 4. 测试构建的工具链
source musl-toolchains/setup-env.sh loongarch64
loongarch64-linux-musl-gcc --version
```

**注意**: LoongArch64 支持基于 [lyw19b/musl-cross-make](https://github.com/lyw19b/musl-cross-make.git)，详细说明请参考 [README.LoongArch.md](https://github.com/lyw19b/musl-cross-make/blob/master/README.LoongArch.md)。

## Windows 用户

Windows 上不能直接运行 bash 脚本，需要使用 **WSL (Windows Subsystem for Linux)**：

```bash
# 1. 安装 WSL2 (在 PowerShell 管理员权限下)
wsl --install

# 2. 在 WSL 中安装依赖
sudo apt update
sudo apt install -y build-essential git make gcc g++ wget

# 3. 在 WSL 中构建工具链
bash scripts/build-musl-toolchain.sh

# 4. 使用工具链
source musl-toolchains/setup-env.sh riscv64
```

**注意**: Windows 原生环境不支持，因为 musl-cross-make 需要 Unix 环境（bash、make、gcc 等）。

## 更多信息

详细文档请参考 [Musl 工具链构建指南](musl-toolchain-build.md)
