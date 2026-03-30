# nice 与前台延迟演示说明（4×`yes` 对照）

在 **相同数量的 CPU 密集型后台任务**（4 个 `yes`）下，只改变 **nice**，对前台 `ls` 的 **wall-clock（`time ls` 的 real）** 影响如下。

## 实测大致范围（示例环境：单核 QEMU）

| 场景 | `time ls` 的 **real** |
| --- | --- |
| 4×默认 `yes` | ~0.6s |
| 4×`nice -n 19 yes` | ~0.05s |
| 4×`nice -n -10 yes` | ~2～3s |

绝对数值会随 QEMU、宿主机负载略有波动；**相对顺序**（nice 19 最快、默认居中、nice -10 最慢）是演示要点。

## 怎么讲清楚

- **nice 19**：后台权重低，CPU 更多让给 shell / `ls` → **前台最快**。
- **默认（nice 0）**：与 shell 大致「公平竞争」→ **中等延迟**。
- **nice -10**：后台权重高，4 个 `yes` 长时间占据运行机会 → 前台 `ls` **经常被排在后面** → **最慢**，可到 **秒级**。

这不是异常，而是 **高优先级后台在单核上强烈挤压交互任务** 的典型现象，说明 **nice → 权重 → 调度** 这条链路在起作用。

## 演示命令（guest shell）

```sh
# 1) 基线：4×默认
killall yes 2>/dev/null
for i in 1 2 3 4; do yes >/dev/null & done
sleep 1
time ls

# 2) 低优先级后台
killall yes 2>/dev/null
for i in 1 2 3 4; do nice -n 19 yes >/dev/null & done
sleep 1
time ls

# 3) 高优先级后台（演示完务必 kill）
killall yes 2>/dev/null
for i in 1 2 3 4; do nice -n -10 yes >/dev/null & done
sleep 1
time ls
killall yes 2>/dev/null
```

## 演示注意

- 跑完 **4×nice -10** 后执行 **`killall yes`**，否则后台持续占满 CPU，shell 会长期卡顿。
- **一句话结论**（可放幻灯片）：在同样 4 个 `yes` 负载下，将后台 nice 从 **19 → 0 → -10**，前台 `ls` 延迟大致从 **约 0.05s** 增至 **约 0.6s** 再增至 **数秒**，方向一致、对比鲜明。

## 相关文档（同目录）

- [EEVDF 是什么（直觉版）](./eevdf-concept.md)
- [Linux 中 nice 的含义与用法](./linux_中_nice_命令详解.md)
- [EEVDF 单元测试汇报说明](./eevdf-unit-tests-summary.md)
