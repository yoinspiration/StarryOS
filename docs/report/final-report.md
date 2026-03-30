# StarryOS 中 EEVDF 与 nice 调度实验报告

## 1. 摘要

本报告围绕 StarryOS 中的调度优化工作展开：在内核中使用 per-task EEVDF 调度路径，并打通 `nice` / `setpriority` 到调度权重的作用链路。我们在相同后台负载（4 个 `yes`）下对比不同 `nice` 设置对前台命令 `ls` 的影响，观察到明显分层：`nice 19` 时约 0.04 到 0.05s，默认优先级约 0.60 到 0.63s，`nice -10` 时可上升到 2 到 3s。与此同时，`cargo test -p axsched eevdf_tests -- --nocapture` 的 6 个 EEVDF 语义测试全部通过，覆盖了资格判定、deadline 驱动抢占与优先级边界。结果表明该实现能够有效调节后台 CPU 竞争对前台交互响应的影响，并具备可复现的验证路径。

## 2. 背景与目标

在多任务系统中，后台 CPU 密集任务很容易影响前台交互体验。对于 OS 实验项目，除了“能跑”之外，还需要回答两个问题：

1. 优先级接口（`nice`/`setpriority`）是否真的进入内核调度逻辑；
2. 调度策略是否能在高负载下保持可解释、可验证的行为。

本次工作的目标是：

- 基于 EEVDF 思路完成 StarryOS 调度路径实现与接线；
- 用可复现实验展示 `nice` 对前台延迟的影响；
- 用单元测试验证 EEVDF 关键语义，而不只停留在现象层面。

## 3. 相关概念

### 3.1 nice 的作用

`nice` 值范围为 `-20 ~ 19`。一般而言：

- 值越小（如 `-10`），任务权重越高，更容易获得 CPU；
- 值越大（如 `19`），任务权重越低，更倾向于“让出”CPU。

因此，`nice` 不是“绝对抢占开关”，而是通过调度器权重影响 CPU 时间分配比例。

### 3.2 EEVDF 直觉

EEVDF（Earliest Eligible Virtual Deadline First）可从三个关键词理解：

- `vruntime`：任务在“公平意义”下已经使用的 CPU 份额；
- `eligible`：相对系统公平水位 `V`，满足 `vruntime <= V` 的任务属于“有资格”候选；
- `deadline`：在有资格任务中，优先选择虚拟截止时间更早者。

当暂时没有任务满足 `eligible` 时，调度器采用兜底规则（直接取最早 deadline）保证系统持续推进。

### 3.3 per-task EEVDF 

- per-task EEVDF（`sched-eevdf`）：每个任务单独维护 `vruntime/deadline/nice`；



## 4. 实现内容概述

本阶段工作的核心是把“概念、接口、行为验证”串成闭环：

1. **调度实现层**：实现并接入 per-task EEVDF 路径；
2. **接口层**：让 `nice`/`setpriority` 能作用到调度权重；
3. **验证层**：提供 guest 侧演示与 host 侧单元测试；
4. **文档层**：沉淀可复现步骤与解释文档。

配套文档位于 `docs/report/`，包括概念说明、演示步骤、单元测试说明和 Linux `nice` 背景。

## 5. 实验设计与复现步骤

### 5.1 实验目标

在相同后台负载数量下，仅改变后台任务 `nice`，观察前台 `ls` 的 wall-clock（`time ls` 的 `real`）变化。

### 5.2 实验环境（本次实测）

- 平台：`riscv64-qemu-virt`（StarryOS guest）
- 负载：4 个后台 `yes > /dev/null`
- 指标：`time ls` 的 `real`

### 5.3 复现实验命令（guest）

```sh
# A. 默认优先级（base）
killall yes 2>/dev/null
for i in 1 2 3 4; do yes >/dev/null & done
sleep 1
time ls

# B. 低优先级后台（nice 19）
killall yes 2>/dev/null
for i in 1 2 3 4; do nice -n 19 yes >/dev/null & done
sleep 1
time ls

# C. 高优先级后台（nice -10）
killall yes 2>/dev/null
for i in 1 2 3 4; do nice -n -10 yes >/dev/null & done
sleep 1
time ls
killall yes 2>/dev/null
```

## 6. 结果与分析

### 6.1 实测结果（同样 4 个 `yes`）

| 场景 | `time ls` 的 real（大致范围） |
| --- | --- |
| 4×默认 `yes` | ~0.60 到 0.63s |
| 4×`nice -n 19 yes` | ~0.04 到 0.05s |
| 4×`nice -n -10 yes` | ~2 到 3s |

### 6.2 结果解读

- `nice 19`：后台权重降低，前台 `ls` 更容易获得 CPU，延迟显著下降；
- 默认：前后台竞争相对均衡，延迟居中；
- `nice -10`：后台任务权重提高，前台更容易被挤压，延迟上升到秒级。

该现象说明了 `nice -> 权重 -> 调度行为` 的作用链路是有效的。

## 7. 验证与测试

### 7.1 EEVDF 语义单元测试（host）

运行：

```sh
cargo test -p axsched eevdf_tests -- --nocapture
```

结果：6/6 通过。

覆盖点包括：

- 高权重任务更早 deadline；
- eligible 约束下的任务选择；
- deadline 驱动抢占触发；
- 抢占后 deadline 保留语义；
- 运行中优先级更新与非法 nice 拒绝。

### 7.2 系统级可运行性

在整机层面，`make ARCH=riscv64 ci-test` 可正常启动到 BusyBox shell，说明当前调度路径在系统集成层可运行。

## 8. 局限与后续工作

当前结果主要证明了单核 + 典型 CPU 压力下的行为正确性，仍有进一步空间：

- 增加多核（SMP）场景测试；
- 扩展 workload（不仅 `yes`/`ls`）；
- 增加更系统化的统计输出与长期基准；
- 在同等条件下对比其他调度策略，量化 tail latency 差异。

## 9. 结论

本次工作完成了 StarryOS 中 per-task EEVDF 相关链路的实现与验证。实验表明，在相同后台压力下，调整 `nice` 能显著改变前台响应时延；单元测试进一步验证了 EEVDF 的关键语义（eligible、deadline、抢占、优先级边界）。整体上，这一实现既有可观测的整机效果，也有可复现的代码级验证依据。

## 10. 参考与附录

### 10.1 报告子文档（`docs/report/`）

- `linux_中_nice_命令详解.md`
- `eevdf-concept.md`
- `eevdf-nice-demo-summary.md`
- `eevdf-unit-tests-summary.md`

### 10.2 扩展材料

- `docs/eevdf-nice-benchmark.md`（自动化基准流程与更详细结果说明）
