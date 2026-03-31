# StarryOS 中 EEVDF 与 nice 调度实验报告

## 目录

- [1. 摘要](#1-摘要)
- [2. 背景与目标](#2-背景与目标)
- [3. 相关概念](#3-相关概念)
- [4. 实现内容概述](#4-实现内容概述)
- [5. 实验设计与复现步骤](#5-实验设计与复现步骤)
- [6. 结果与分析](#6-结果与分析)
- [7. 验证与测试](#7-验证与测试)
- [8. 已知局限](#8-已知局限)
- [9. 后续工作](#9-后续工作)
- [10. 结论](#10-结论)
- [11. 参考与附录](#11-参考与附录)

## 1. 摘要

本报告围绕 StarryOS 中的调度优化工作展开：在内核中使用 per-task EEVDF 调度路径，并打通 `nice` / `setpriority` 到调度权重的作用链路。我们在相同后台负载（4 个 `yes`）下对比不同 `nice` 设置对前台命令 `ls` 的影响，观察到明显分层：`nice 19` 时约 0.04 到 0.05s，默认优先级约 0.60 到 0.63s，`nice -10` 时可上升到 2 到 3s。与此同时，`cargo test -p axsched eevdf_tests -- --nocapture` 的 11 个测试全部通过，覆盖资格判定、deadline 驱动抢占、优先级边界与统计计数路径。结果表明该实现能够有效调节后台 CPU 竞争对前台交互响应的影响，并具备可复现的验证路径。

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

当前实现中，`V` 取就绪队列 `vruntime` 的按权重平均值，这与 `nice -> weight` 的公平目标保持一致，也使 eligible 判定具备稳定、可解释的中心水位。

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

### 6.3 可选深化结果（SMP=2 + 第二工作负载）

在 `smp=2` 下完成了两组补充验证：

1. `yes + ls` 回归脚本可在双核下稳定运行，且 `nice19` 相比 `base` 继续保持更优 `p95/p99/max`。
2. 第二工作负载选用 `sha256sum /bin/busybox`（`N=50`）做 base/nice19 对比，结果如下：

| Scenario | N | p50 | p95 | p99 | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| base | 50 | 0.390 | 0.390 | 0.400 | 0.400 |
| nice19 | 50 | 0.080 | 0.120 | 0.120 | 0.120 |

该结果说明：即使在双核与更重探针下，降低后台 nice 仍可显著改善前台 tail latency，结论不局限于单核 `ls` 场景。

## 7. 验证与测试

### 7.1 EEVDF 语义单元测试（host）

运行：

```sh
cargo test -p axsched eevdf_tests -- --nocapture
```

结果：11/11 通过。

覆盖点包括：

- 高权重任务更早 deadline；
- eligible 约束下的任务选择；
- deadline 驱动抢占触发；
- 抢占后 deadline 保留语义；
- 运行中优先级更新与非法 nice 拒绝；
- 轻量统计接口计数：`picks_total`、`preempt_by_deadline`、`slice_expired`；
- 兜底分支计数：`fallback_no_eligible`（测试态强制覆盖）。

### 7.2 系统级可运行性

在整机层面，`make ARCH=riscv64 ci-test` 可正常启动到 BusyBox shell，说明当前调度路径在系统集成层可运行。

### 7.3 可观测性增强（per-task EEVDF）

为提升运行时可见性，当前实现已在 `sched-eevdf` 路径提供：

- 统计 API：`set_eevdf_stats_enabled`、`eevdf_stats`、`reset_eevdf_stats`
- 周期日志开关：`set_eevdf_stats_log_config(enabled, interval_ticks)`

其中周期日志默认关闭；启用后会按间隔输出 `picks_total / preempt_by_deadline / slice_expired / fallback_no_eligible`，可用于现场演示与实验对照。

### 7.4 一条命令演示与启停负载观测（guest）

为便于现场汇报，本阶段新增演示 feature：`eevdf-stats-demo`。启用后，系统启动即开启 EEVDF 周期统计日志（示例间隔 256 tick）。

host 侧启动命令：

```sh
make run LOG=info FEATURES=eevdf-stats-demo
```

guest 侧最小复现步骤：

```sh
# 1) 施加负载
yes >/dev/null &
yes >/dev/null &
yes >/dev/null &
yes >/dev/null &

# 2) 观察一段 eevdf stats 日志后停止负载
killall yes
```

本次实测现象（与日志一致）：

- 施压阶段：`picks_total` 与 `slice_expired` 快速持续增长（例如 `49 -> 600`、`15 -> 527`）。
- 停压后：`killall yes` 对应任务收到 `SIGTERM` 并退出，统计进入平台期（例如 `2093 -> 2112` 后基本不再增长）。
- `fallback_no_eligible` 持续为 0，符合当前 `V`（就绪队列 `vruntime` 加权平均）定义下的常见运行行为。

该观测形成了“加压增长、停压趋稳”的闭环证据，可直接用于导师现场演示与报告截图说明。

SMP=2 补充观测（`make run LOG=info FEATURES=eevdf-stats-demo SMP=2`）显示：

- 启动日志可见 `Secondary CPU 1 started/init OK`，确认双核生效；
- 周期统计同时出现 `eevdf stats cpu0` 与 `eevdf stats cpu1`，说明主核与副核 runqueue 均已开启统计日志；
- 空闲阶段两路计数保持平台化（例如 `cpu0: picks_total=7`、`cpu1: picks_total=9`），符合“无显著负载时仅少量系统活动”的预期。

当前日志格式已升级为 `total[...] + delta[...]`：

- `total`：自启动以来累计计数；
- `delta`：当前日志窗口内新增计数（相邻两次日志差分）；
- 在空闲阶段，实测 `delta[picks=0 preempt=0 slice_expired=0 fallback=0]`，可直接作为“当前窗口调度活跃度接近 0”的证据。

该结果进一步证明：当前 demo 方案在多核场景下也具备可观测性，可用于展示每 CPU 的调度统计视角。

进一步地，对负载日志 `bench-results/serial-load-20260331-060723.log` 使用
`scripts/parse-eevdf-stats-log.sh` 进行 `delta` 聚合统计，得到：

- `cpu1`: `windows=124`、`nonzero_windows=116`、`sum_delta_picks=5864`、`sum_delta_preempt=3`、`sum_delta_slice=5839`、`sum_delta_fallback=0`
- `cpu0`: `windows=124`、`nonzero_windows=116`、`sum_delta_picks=5852`、`sum_delta_preempt=0`、`sum_delta_slice=5838`、`sum_delta_fallback=0`

该结果说明在持续负载阶段两核窗口级调度活跃度均显著上升，且两核活动总量接近；同时 `sum_delta_fallback=0` 继续符合当前实现的常见运行行为预期。

## 8. 已知局限

为避免结论外推过度，本报告明确以下边界条件：

- **教学实现定位**：当前 per-task EEVDF 以“可解释、可验证、可演示”为主要目标，属于课程/实验导向实现，并非以完整复刻 Linux 生产调度器为目标。
- **与 Linux 主线差距**：已实现核心语义（`vruntime`、`eligible`、`deadline` 与抢占），但在工程化程度、可观测性与复杂场景覆盖方面，仍与 Linux 主线实现存在差距。
- **测试边界（单核为主）**：当前主结论仍以单核 `yes + ls` 为主，虽已补充 `smp=2` 与第二工作负载样本，但规模仍有限，尚不足以替代系统化多核压测。

## 9. 后续工作

- 增加多核（SMP）场景测试；
- 扩展 workload（不仅 `yes`/`ls`）；
- 增加更系统化的统计输出与长期基准；
- 在同等条件下对比其他调度策略，量化 tail latency 差异。

### 9.1 可直接执行的可选深化

1. **SMP=2 对比（base / nice19）**

   - host 侧使用双核启动（示例）：
     - `make ARCH=riscv64 SMP=2 run`
   - guest 侧执行现有回归脚本：
     - `sh /root/bench-regression-eevdf.sh`
   - 将结果与单核基线（同脚本输出）对比，观察 `p95/p99/max` 是否仍保持 `nice19` 优势。

2. **第二工作负载（除 `yes+ls` 外）**

   脚本已支持探针参数：`PROBE_NAME` + `PROBE_CMD`。例如使用 BusyBox 哈希任务作为前台探针：

   - `PROBE_NAME=busybox_sha256 PROBE_CMD='sha256sum /bin/busybox >/dev/null' sh /root/bench-regression-eevdf.sh`

   输出会生成独立文件（例如 `busybox_sha256-latest.tsv`），可与 `ls` 探针结果并列放入报告，提升结论说服力。

3. **样本量参数化（便于快速试跑与正式复现）**

   脚本支持 `SAMPLES`（逗号分隔），默认 `50,200`。例如：

   - `SAMPLES=30,100 sh /root/bench-regression-eevdf.sh`

## 10. 结论

本次工作完成了 StarryOS 中 per-task EEVDF 相关链路的实现与验证。实验表明，在相同后台压力下，调整 `nice` 能显著改变前台响应时延；单元测试进一步验证了 EEVDF 的关键语义（eligible、deadline、抢占、优先级边界）。整体上，这一实现既有可观测的整机效果，也有可复现的代码级验证依据。

## 11. 参考与附录

### 11.1 报告子文档（`docs/report/`）

- `linux_中_nice_命令详解.md`
- `eevdf-concept.md`
- `eevdf-nice-demo-summary.md`
- `eevdf-unit-tests-summary.md`

### 11.2 扩展材料

- `docs/eevdf-nice-benchmark.md`（自动化基准流程与更详细结果说明）
