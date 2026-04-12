# Starry 调度：EEVDF 与 per-CPU 框架

从调度动机与 EEVDF 原理，到 StarryOS 中的实现、per-CPU 异构调度，以及当前能力与边界说明。

## 目录

- [操作系统为什么需要调度器？](#操作系统为什么需要调度器)
- [我的实现](#我的实现)
- [扩展：per-CPU 异构调度](#扩展per-cpu-异构调度)
- [范围与非目标](#范围与非目标)

---

## 操作系统为什么需要调度器？

CPU 一次只能运行一个任务。但电脑上同时有几十个程序在跑，所以操作系统要不停地决定：现在让谁用 CPU？

这个决定的规则，就叫调度算法。

### 最朴素的方法：轮流来

每个任务轮流用 CPU，用一段时间（时间片）就换下一个。这叫**轮转调度（Round Robin）**。

问题：所有任务一视同仁，但有些任务应该比其他任务得到更多 CPU（比如视频播放 vs 后台同步）。

### 加入优先级：虚拟运行时间

EEVDF 的前身 CFS 引入了 vruntime（虚拟运行时间）：

- 每个任务记录自己用了多少"虚拟 CPU 时间"
- 优先级高（权重大）的任务，vruntime 增长慢——同样运行 1 秒，vruntime 只增加 0.5
- 优先级低的任务，vruntime 增长快

CFS 的规则：始终选 vruntime 最小的任务运行。

这样高优先级任务更频繁地被选中，获得更多实际 CPU 时间

#### CFS 的问题 

CFS 选 vruntime 最小的任务，这样无法保证响应时间。

比如：有 10 个任务，你的任务 vruntime 排第 5，要等前 4 个任务的 vruntime 都涨到比你大，才轮到你。理论上这会发生，但没有明确的时间保证，高负载下延迟可能很长。

#### EEVDF 的解法：加入 deadline

EEVDF 在 vruntime 基础上，给每个任务增加一个 deadline（截止期）：

deadline = vruntime + 时间片 / 权重

直觉上：deadline 表示"这个任务最晚应该在什么虚拟时刻完成本轮服务"。

同时定义系统虚拟时间 V = 所有任务 vruntime 的加权平均，代表"公平线"。

eligible 任务：vruntime ≤ V，即这个任务还没有超额消费 CPU。

EEVDF 的选人规则：

在所有 eligible 任务中，选 deadline 最小的。

#### 为什么需要 eligible 判断？

只按 deadline 选任务会有问题。考虑一个刚从睡眠醒来的任务：

- 它睡眠期间没有用 CPU，vruntime 没有增长
- 其他任务一直在跑，vruntime 一直在涨
- 所以它醒来后，vruntime 相对其他任务很小，deadline 也很小

如果只选 deadline 最小的，这个任务会一直被选中，反复占用 CPU：

```
任务 A（一直在跑）：vruntime = 100，deadline = 110
任务 B（刚睡醒）：  vruntime = 5，  deadline = 15

选 B，跑完，vruntime = 15，deadline = 25  → 还是选 B
选 B，跑完，vruntime = 25，deadline = 35  → 还是选 B
……直到 B 的 vruntime 追上 A，A 才有机会
```

A 被长时间饿死。

加上 eligible 判断后：

V = (100 + 5) / 2 = 52（所有任务的加权平均）

B 的 vruntime = 5 ≤ V = 52，eligible，可以被选。B 运行后 vruntime 增长，V 也随之上升。当 B 的 vruntime 追上 V 时，B 不再 eligible，A 就有机会了。

关键区别：没有 eligible 时，B 要跑到追上 A（差距 95）才让出来；有 eligible 时，B 只要追上平均线 V 就让出来。A 等待的时间大大缩短。

eligible 控制的是"你最多能超前于平均线多少"，而不是"你要追上最慢的那个任务"。

#### 为什么这样更好？

- **公平**：eligible 判断确保没有任务能无限超额消费 CPU
- **延迟可控**：deadline 给每个任务一个明确的"最晚被服务时刻"，延迟有上界
- **自然抢占**：有 deadline 更早的 eligible 任务到来时，可以打断当前任务

---

## 我的实现

实现在 StarryOS 上，作为可插拔调度器模块。

### 数据结构

调度器同时维护三个有序结构：

```
ready_queue:    BTreeMap<(deadline, id), Task>   // 按截止期排序
vrt_set:        BTreeSet<(vruntime, id)>          // 按 vruntime 排序
id_to_deadline: BTreeMap<id, deadline>            // 从 id 反查 deadline
```

以及两个增量计数器：

```
total_weighted_vrt / total_weight   // 用于 O(1) 计算系统虚拟时间 V
```

任何任务的入队和出队，三个结构同时更新，始终保持同步。

**为什么需要两个有序结构？**

- `ready_queue` 按 deadline 排序，可以 O(1) 取出 deadline 最小的任务
- 但判断 eligible 需要找"vruntime ≤ V 的任务中 deadline 最小的"，按 deadline 排的结构无法高效做这个查询
- `vrt_set` 按 vruntime 排序，可以用范围查询快速找到所有 vruntime ≤ V 的任务
- `id_to_deadline` 是反查表，通过 vrt_set 找到任务 id 后，用它定位 ready_queue 中的位置

### 选任务（pick_next_task）

```
计算 V = total_weighted_vrt / total_weight

if ready_queue 中 deadline 最小的任务，其 vruntime ≤ V：
    直接取它                    ← 快路径，O(1)，覆盖绝大多数情况
else：
    用 vrt_set 范围查询，找所有 vruntime ≤ V 的任务
    取其中 deadline 最小的      ← 慢路径，O(log N)

    如果没有 eligible 任务：
        取 deadline 最小的任务  ← fallback，保证调度器不卡死
```

快路径覆盖了绝大多数正常情况——min-deadline 的任务通常本身就是 eligible 的。

### 抢占（task_tick）

每个时钟中断触发一次：

1. 当前任务的 vruntime 增加 `1024² / weight`
2. 时间片减 1，归零则触发抢占
3. 检查 ready_queue 头部：若存在 eligible 且 deadline 更早的任务，立即抢占

### 返回队列（put_prev_task）

任务让出 CPU 时，需要重新计算 deadline 再入队：

- **时间片耗尽**：重置为完整时间片，`deadline = vruntime + 完整时间片 / weight`
- **被抢占**（时间片还有剩余）：
  - 若原 deadline 仍然有效，保留不变，任务保持原来的队列位置
  - 若原 deadline 已过期，用**剩余时间片**重新计算：`deadline = vruntime + 剩余时间片 / weight`

被抢占时用剩余时间片而非完整时间片，是为了避免对已经运行了一半的任务给予额外奖励。

### 优先级

使用与 Linux 相同的 nice → weight 映射表，nice 范围 -20 到 +19，对应权重 88761 到 15。

调用 `set_priority` 时，任务从队列中取出，更新权重，重新计算 deadline，再入队。

### 验证

**单元测试**

| 测试 | 内容 | 结果 |
|------|------|------|
| 等权重公平性 | 3 个 nice=0 任务跑 9000 tick | CPU 占比误差 ±5% 以内 |
| 加权公平性 | nice -5/0/+5（权重比 3121:1024:335）跑 15000 tick | CPU 占比符合权重比，误差 ±10% |
| 抢占截止期修正 | 验证剩余时间片 vs 完整时间片 | deadline 计算正确 |
| fallback 统计 | 强制无 eligible 场景 | fallback 计数正常递增 |

**QEMU 实测**

在 StarryOS 上运行 SHA 压测：

```
picks=2041  preempt=9  slice_expired=1177  fallback=0
```

- `fallback=0`：全程所有任务均保持 eligible，调度器工作在理想状态
- `preempt=9`：deadline 驱动的抢占正常触发
- `slice_expired=1177`：绝大多数任务正常耗尽时间片

---

## 扩展：per-CPU 异构调度

### 问题

StarryOS 原本的调度器是编译时全局确定的——所有 CPU 用同一种算法。但不同场景对调度的需求不同：

- 实时任务希望用 FIFO，绑定到指定 CPU，不被其他任务打断
- 交互任务希望用 EEVDF，保证延迟上界
- 批处理任务用轮转（RR）即可，不需要复杂的优先级计算

因此希望每个 CPU 在运行时独立选择调度算法。

### 方案：元数据分离

调度状态（vruntime、deadline、时间片、nice 值）不放在任务结构体里，而是存在调度器自己的 BTreeMap 中：

```
scheduler.metadata: BTreeMap<task_id, EevdfMeta>
```

任务结构体只需实现一个最小接口：

```rust
trait HasSchedulerId {
    fn sched_id(&self) -> u64;
}
```

这样任务本身是纯粹的 `TaskInner`，不携带任何调度字段。

### 跨调度器迁移

元数据分离的核心好处：同一个 `Arc<Task>` 可以直接从一个调度器移到另一个，无需类型转换。

```rust
// 从 EEVDF 取出任务
let task = eevdf.remove_task(&t);
// 直接放入 FIFO，类型完全一致
fifo.add_task(task);
```

旧调度器的元数据（vruntime 等）在 `remove_task` 时自动清理，新调度器在 `add_task` 时重新初始化自己需要的元数据。

### 实现结构

```
PerCpuScheduler<T>
├── Eevdf(MetadataEevdf<T>)   ← ready_queue + vrt_set + metadata BTreeMap
├── Fifo(MetadataFifo<T>)     ← VecDeque
└── Rr(MetadataRr<T>)         ← VecDeque + 每任务剩余时间片表
```

### 使用方式

通过编译时环境变量 `CPU_SCHED` 指定每个 CPU 的调度算法，无需改代码：

```bash
CPU_SCHED="0:eevdf,1:fifo" make run SMP=2
```

格式：`<cpu_id>:<算法>` 用逗号分隔，支持 `eevdf`、`fifo`、`rr`，未指定的 CPU 默认使用 EEVDF。

`CPU_SCHED` 由 build script 在编译时读取，写入生成文件，baked 进二进制。`CPU_SCHED` 变化时 Cargo 自动触发重新编译，无需手动 clean。

调用链：

```
axruntime::rust_main()
  → axtask::setup_per_cpu_schedulers(CPU_SCHED_CONFIG)  ← 编译时 baked 的配置字符串
  → axtask::init_scheduler()                            ← CPU 0 按配置初始化
  → (CPU 1 启动) init_scheduler_secondary()             ← CPU 1 同样读取配置
```

配置存储在一个全局原子数组里（每 CPU 一格），`setup_per_cpu_schedulers` 解析字符串后写入，`init_scheduler` / `init_scheduler_secondary` 读取，之后不再变更。

### 验证

| 测试 | 内容 |
|------|------|
| `fifo_picks_in_insertion_order` | FIFO 按入队顺序出队 |
| `fifo_never_preempts_on_tick` | FIFO 不触发抢占 |
| `rr_preempts_after_slice_expires` | RR 在时间片耗尽后触发抢占 |
| `eevdf_fairness_equal_weight` | 等权重 3 任务，CPU 占比误差 ±5% |
| `task_migrates_between_schedulers` | 同一 Arc<Task> 从 EEVDF 迁移到 FIFO，无需类型转换 |

**QEMU 实测（SMP=2）**

```bash
CPU_SCHED="0:eevdf,1:fifo" make run SMP=2 LOG=info
```

启动日志：

```
CPU 0 uses EEVDF scheduler.
use per-cpu (EEVDF / FIFO / RR) scheduler.
...
Secondary CPU 1 started.
CPU 1 uses FIFO scheduler.
```

系统正常启动进入 shell，无 panic。CPU 0 使用 EEVDF，CPU 1 使用 FIFO，两个 CPU 各自按配置独立运行。

## 范围与非目标

### 与 Linux「调度类」语义的差异

当前 Starry 里「多种调度算法并存」主要指：在启用 **`sched-per-cpu`** 时，**不同 CPU** 可选用不同的 `SchedulerKind`（EEVDF / FIFO / RR），例如通过上文中的 `CPU_SCHED` 在编译期指定。

这与 Linux 里常见的 **每个线程 / 进程** 选用 `SCHED_FIFO`、`SCHED_RR`、`SCHED_OTHER` 等 **policy** 不是同一层语义：后者是 **per-task** 的调度策略选择，涉及优先级继承、带宽、与 POSIX 行为的交互等，复杂度和本文描述的 per-CPU 异构算法 **不在一个阶段**。

上文「元数据分离、同一 `Arc<Task>` 跨调度器迁移」面向的是：**统一任务类型** 与 **按 CPU 切换算法** 的工程需求；**按任务粒度选择不同调度策略**（真正的多「调度类」在同一调度框架下共存）属于后续演进方向，尚未作为本文档承诺的行为。

### Cargo feature 与两条实现路径

构建时通过 Cargo feature 组合选择调度实现，常见情形如下：

- **启用 `sched-per-cpu`**：`AxTask` 为纯 `TaskInner`，调度元数据存放在 `PerCpuScheduler` 内部表结构中；本文「元数据分离」「`HasSchedulerId`」等描述主要针对这一路。
- **仅启用 `sched-eevdf`（未启用 `sched-per-cpu`）**：任务类型为 `EevdfEntity<TaskInner>`，vruntime / deadline 等字段包在实体内部，由 `EevdfScheduler` 驱动。

两条路径对应不同的类型与调度器实现，**不会在同一构建中混用**；与 EEVDF 相关的算法细节在两条路径中各有实现，维护时需注意行为一致性问题。

### 与主线内核演进的关系

Linux 主线中，EEVDF 进入默认公平调度路径、sched_ext 等机制带来可扩展调度能力，这是 Starry 长期参照的 **方向**。Starry 侧以统一的 `BaseScheduler` trait（见 `crates/axsched/src/lib.rs`）、按阶段增加策略与可观测性为手段，**对齐思路与可测试子目标**，而非逐行复刻内核或用户态 BPF 调度框架。