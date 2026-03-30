# EEVDF 是什么（直觉版）

调度器要决定：**下一个 CPU 给谁用**。

**EEVDF**（Earliest Eligible Virtual Deadline First）是 Linux 里在 CFS 之后演进的那类思路中的一种：既考虑 **「公平」**（大家分到的 CPU 时间别差太多），又考虑 **「谁先该跑」**（用截止时间 **deadline** 来比）。

## 可以记三个词

### 虚拟运行时间（vruntime）

像「这个任务已经占了多少**公平份额**意义上的 CPU」。占得越多，数值涨得越快（和优先级 / nice 有关：**优先级高 → 权重高 → vruntime 涨得慢** → 更容易被认为还没「透支」）。

### 资格（eligible）

系统算一个参考时间 **V**（可以理解成：当前就绪队列里大家 vruntime 的某种 **公平水位**）。

**vruntime ≤ V** 的任务算「还没多占 CPU」，**有资格**被认真考虑进下一步选择。

### 虚拟截止时间（deadline）

在 **有资格** 的任务里，选 **deadline 最小** 的（最早该「交作业」的）先跑；若暂时没人有资格，也有 **兜底** 规则保证系统能继续推进。

**兜底规则（本仓库 `sched-eevdf`）**：若就绪队列里 **没有任何** 任务满足 **vruntime ≤ V**（相对公平水位都算「透支」），则不再筛资格，改为 **直接选 deadline 最小** 的那个任务运行。否则可能出现「谁都不该跑」、CPU 空转。实现上对应 `EevdfScheduler::pick_next_task` 里「先找 eligible，找不到则取就绪队列中最早 deadline」的分支（见 `crates/axsched/src/eevdf.rs`）。

## 与本仓库两种实现的关系

- **per-task EEVDF**（`sched-eevdf`，当前内核默认）：每个任务自己带 **vruntime、deadline、nice**，调度器按上面这套规则选下一个任务。

- **EEVDF-class**（`sched-eevdf-class`，可选）：先把任务分到 **交互 / 普通 / 后台** 等类，再按 **类权重**（例如 8:4:1）做更粗粒度的公平——适合对比实验；与 per-task 是 **两条线**，不要与主线内核里「逐任务 EEVDF」混为一谈。

更多与实验、演示、单测相关的文档：

- [`eevdf-nice-benchmark.md`](./eevdf-nice-benchmark.md) — 基准与复现步骤  
- [`eevdf-nice-demo-summary.md`](./eevdf-nice-demo-summary.md) — nice 与前台延迟演示  
- [`eevdf-unit-tests-summary.md`](./eevdf-unit-tests-summary.md) — `eevdf_tests` 单元测试汇报说明  
