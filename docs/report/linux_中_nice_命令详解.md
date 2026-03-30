# Linux 中 nice 的含义与用法

## 一、什么是 nice

在 Linux 中，`nice` 用来控制**进程的调度优先级**。

简单理解：

> nice 表示一个进程对 CPU 的“礼让程度”

- 越“nice”，越愿意把 CPU 让给其他进程
- 越“不 nice”，越倾向于优先占用 CPU

---

## 二、nice 值范围

nice 值的取值范围为：

```
-20 ~ 19
```

| nice 值 | 含义 |
|--------|------|
| -20 | 优先级最高（最不“谦让”） |
| 0 | 默认值 |
| 19 | 优先级最低（最“谦让”） |

---

## 三、基本用法

### 1. 启动进程时设置 nice 值

```bash
nice -n 10 python script.py
```

说明：
- 将进程 nice 值设为 10
- 优先级降低
- 更少占用 CPU 资源

---

### 2. 修改已运行进程（renice）

```bash
renice -n 5 -p 1234
```

说明：
- 修改 PID 为 1234 的进程
- 设置 nice 值为 5

---

## 四、权限限制

| 用户类型 | 可操作范围 |
|----------|------------|
| 普通用户 | 只能增加 nice 值（降低优先级） |
| root 用户 | 可以降低 nice 值（提高优先级） |

示例：

```bash
sudo nice -n -10 python script.py
```

---

## 五、使用场景

### 场景 1：后台任务

运行耗 CPU 的任务时：

```bash
nice -n 15 python train.py
```

效果：
- 程序运行更慢
- 但不会影响系统响应

---

### 场景 2：服务器负载控制

在多任务服务器中：
- 重要服务 → 低 nice 值
- 后台任务 → 高 nice 值

---

## 六、与调度器的关系

nice 值并不是绝对优先级，而是影响调度器（如 CFS）的权重。

特点：

- 不会完全阻止进程运行
- 只是影响 CPU 分配比例

简要理解：

> nice 值越大 → 分到的 CPU 时间越少

---

## 七、总结

- nice 用于控制进程优先级
- 范围：-20 ~ 19
- 值越小，优先级越高
- 值越大，越“谦让”CPU
- 常用于优化系统资源分配

---

## 八、一句话记忆

> nice = 进程对 CPU 的“礼貌程度”

---

## 九、与 StarryOS 实验的关系（本仓库）

在 StarryOS 中，`nice` 通过 `setpriority` 等进入内核，由调度器（如 per-task EEVDF）按 **权重** 参与 CPU 分配。实验演示与概念说明见同目录：

- [EEVDF 是什么（直觉版）](./eevdf-concept.md)
- [nice 与前台延迟演示说明](./eevdf-nice-demo-summary.md)
- [EEVDF 单元测试汇报说明](./eevdf-unit-tests-summary.md)
