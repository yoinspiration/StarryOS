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

```bash
# 1. 检查依赖
bash scripts/check-deps-macos.sh

# 2. 安装缺失的依赖 (如果需要)
brew install git make gcc

# 3. 构建工具链
make musl-toolchain
```

## 更多信息

详细文档请参考 [Musl 工具链构建指南](musl-toolchain-build.md)
