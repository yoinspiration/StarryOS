#!/usr/bin/env sh
# EEVDF 统计演示：在 guest 内跑固定 CPU/调度负载，串口上应出现周期性
#   "eevdf stats cpuN: picks_total=..." 行（需内核以 eevdf-stats-demo 构建且 LOG=info）。
#
# 主机侧一键（示例）：
#   make run LOG=info FEATURES=eevdf-stats-demo
# 进入 shell 后（可将本脚本拷入 guest 执行）：
#   sh demo-eevdf-stats.sh
#
# 间隔为 init 中配置的 256 个 tick，与平台 HZ 有关。

set -e

echo "EEVDF demo: 4x yes + 20x time ls (watch serial for eevdf stats lines)"
(killall yes 2>/dev/null) || true
i=1
while [ "$i" -le 4 ]; do
	yes >/dev/null &
	i=$((i + 1))
done
sleep 2
i=1
while [ "$i" -le 20 ]; do
	time ls >/dev/null
	i=$((i + 1))
done
(killall yes 2>/dev/null) || true
echo "Done."
