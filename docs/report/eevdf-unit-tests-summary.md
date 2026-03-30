# EEVDF 单元测试（`eevdf_tests`）汇报说明

在宿主机仓库根目录执行：

```sh
cargo test -p axsched eevdf_tests -- --nocapture
```

若 **6 个测试全部通过**，说明当前 `eevdf_tests` 模块里与 **EEVDF 语义**相关的用例在你环境中均成立。

## 测试与含义（汇报时可一测一行）

| 测试 | 说明 |
| --- | --- |
| `high_weight_task_gets_earlier_deadline` | 高权重 → 更早 deadline → 调度按 deadline 倾向选它 |
| `eligible_task_preferred_over_earlier_deadline` | 在 **eligible（vruntime ≤ V）** 约束下选人，不是只看「全局最小 deadline」 |
| `deadline_preemption_triggers` | 就绪队列里存在更「该跑」的任务时，触发 **deadline 驱动抢占** |
| `preempted_task_keeps_deadline` | 被抢占且 slice 未耗尽时 **deadline 保留** |
| `set_priority_on_running_task` | 运行中任务仍可 **改 nice** 并保持调度器一致 |
| `set_priority_rejects_out_of_range` | **非法 nice** 被拒绝 |

## 关于 `filtered out`

输出中的 **`N filtered out`** 表示：本次过滤条件只运行名字包含 `eevdf_tests` 的用例，其余调度器测试（如 CFS、FIFO 等）未执行，**不是失败**。

## 与 QEMU 演示的配合

| 演示 | 验证内容 |
| --- | --- |
| QEMU 里 **nice + `time ls`** | 整机 + 用户态接口 + 调度在真实系统上的**效果** |
| 宿主机 **`cargo test -p axsched eevdf_tests`** | **EEVDF 规则本身**（eligible、deadline、抢占、改优先级） |

建议顺序：先播 **单元测试通过**的终端输出，再补一句：**「与 QEMU 实验互补——那边验整机效果，这边验 EEVDF 语义。」**

## 相关概念

术语与直觉说明见：[EEVDF 是什么（直觉版）](./eevdf-concept.md)。
