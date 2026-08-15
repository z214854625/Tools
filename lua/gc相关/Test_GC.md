# Test_GC.lua 测试脚本分析

> 文件路径: [BinServer/Server/CommonLua/Lua/Test_GC.lua](./Test_GC.lua)
> 目的: Lua 5.4 GC 参数对比测试，用于评估 `Utils.set_gc()` 该如何调

---

## 一、脚本各部分作用

### 1. 文件头（第 1–21 行）
注释说明用法和指标含义。**测的是什么**：列出整个测试给出的 5 个核心指标含义，用于后面对结果做出解读。

- `总CPU(s)`：负载总耗时（含运行期间被夹在中间触发的 GC）
- `GC占比`：相对"GC关闭基线"多出来的百分比，等价于"GC 在该参数下吃掉了多少 CPU"
- `驻留内存`：强制 collect 后还活着的对象大小，**衡量"该回收的有没有回收掉"**
- `峰值内存`：负载结束时瞬时内存，**衡量"GC 追不追得上分配速度"**
- `强制GC耗时`：负载跑完后 `collectgarbage("collect")` 的耗时，**反映堆里残留垃圾的多少**

---

### 2. GetCurTime 兜底（第 25–28 行）

```lua
if not rawget(_G, "GetCurTime") then
    rawset(_G, "GetCurTime", function() return os.time() end)
end
```

**作用**：脚本既要能在游戏内被 `require` 跑（用项目自带的 `GetCurTime`），又要能在命令行 `lua54 Test_GC.lua` 直接跑。命令行环境没有这个全局函数，所以注入一个兜底实现。**它本身不参与测试**，只是兼容层。

---

### 3. 合成负载 `defaultWorkload`（第 35–53 行）

这是被测对象 —— **一个刻意设计成"既有大量短生命垃圾、又有少量长生命对象"的混合分配模式**，模拟服务器真实场景。

| 代码段 | 测的是什么 |
|---|---|
| `tmp = {}` + `for j=1,100` 内层循环建表 | **大量瞬时垃圾**：每轮 i 创建一个含 100 个嵌套 table 的 tmp，下一轮就成了垃圾。这是 GC 主战场。 |
| `parts[]` + `table.concat` | **大量瞬时字符串**：30 个临时字符串通过 concat 合并，给字符串内部化和短期 GC 压力。 |
| `if i % 20 == 0 then _longLive[...] = ...` | **少量长生命对象 + 替换**：每 20 轮往一个 1000 容量环形缓存里塞一份引用。被替换出去的旧条目变成可回收对象，专门用来**触发 generational 的 major collection 和 incremental 的回收周期**。 |
| `local t1 = GetCurTime()` 拼到 name 字段 | 让 name 字段每次跑都不同，**避免 Lua 的字符串内部化把所有 "item_..." 当作同一个，误以为没产生新字符串**。 |

`_longLive` 设成 module-level（第 35 行）而不是 local，是因为 `measure` 每次开测前要把它清空（第 59 行），重置堆状态。

---

### 4. 单次测量 `measure`（第 58–85 行）

```lua
_longLive = {}
collectgarbage("collect")     -- 跑两次确保 finalizer 也清理
collectgarbage("collect")
setupFn()                      -- 应用本轮要测的 GC 参数
```

**作用**：把每个 profile 放进同一个干净的起点 —— 不然上一轮残留的对象会污染下一轮。

```lua
local memBeg   = collectgarbage("count")
local clockBeg = os.clock()
workloadFn(iter)
local clockEnd = os.clock()
local memPeak  = collectgarbage("count")
```

**测的是**：负载本身的 CPU 时间 + 跑完时的内存峰值。`os.clock()` 是进程 CPU 时间，比 `os.time()` 精确。

```lua
local gcBeg = os.clock()
collectgarbage("collect")
local gcEnd = os.clock()
local memAfter = collectgarbage("count")
```

**测的是**：跑完后做一次"全量回收"的耗时和回收后剩多少。如果 `gcCollect` 很大说明运行期间 GC 没追上、堆里积了大量未清理对象；如果 `memAfter` 比基线大说明有被引用持有的对象残留（潜在泄漏）。

---

### 5. 多次平均 `avgRuns`（第 87–95 行）

对同一参数跑 N 次取平均。**作用**：单次测量噪声大（os.clock 抖动 + GC 触发时机不一致），多次平均让结果更稳定。

---

### 6. 参数集 `profiles`（第 106–158 行）

整个测试的"对照实验组"，每一项的设计意图：

| 编号 | profile | 设计意图 / 测什么 |
|---|---|---|
| 1 | **GC关闭(基线)** | 用 `collectgarbage("stop")` 关 GC，得到"无 GC 开销时的纯负载耗时"。**所有其它行的"GC开销"百分比都以它为分母** |
| 2 | 默认 incremental (200, 100) | Lua 5.4 出厂默认值，作为 incremental 的"标尺" |
| 3 | **线上当前 incremental (120, 300)** | `Utils.set_gc()` 现在 incremental 分支用的参数，要评估的就是它 |
| 4 | 宽松 incremental (200, 200) | pause 给回 200，stepmul 适中，**测"放宽 pause 是否能降 CPU"** |
| 5 | 激进 incremental (100, 500) | 故意拉到极端，**测下限边界**，看 pause 100 + 大 stepmul 会不会陷入持续 GC |
| 6 | 默认 generational (20, 100) | Lua 5.4 generational 出厂默认值，作为 generational 的"标尺" |
| 7 | **线上当前 generational (30, 300)** | `Utils.set_gc()` 跨服分支用的参数，要评估的就是它 |
| 8 | 宽松 generational (50, 300) | minor 阈值放到 50，**测"减少 minor 触发次数能否再降 CPU"** |

注意基线那一项有 `teardown`：测完要 `restart` 把 GC 打开，避免污染下一项。

---

### 7. 主入口 `M.run`（第 167–208 行）

```lua
local base = results[1].cpu
```

拿基线 CPU 作分母 —— `(this.cpu - base) / base * 100` 就是该参数的纯 GC 开销百分比。

打印部分按 `%-50s %10s ...` 对齐输出表格。

---

### 8. 命令行直跑入口（第 213–217 行）

```lua
if arg and arg[0] and arg[0]:find("Test_GC") then
```

**作用**：当作 entry script 跑时执行 run；被 `require` 加载时不自动跑（因为 require 进来时 `arg[0]` 不会是这个文件名）。两种使用方式（命令行 / 游戏内 require）由这里区分。

---

## 二、整体测试逻辑

把"同一份负载"扔给 8 套不同的 GC 配置，每套跑 N 次取平均，统一对比 4 个维度：CPU 开销百分比 / 峰值内存 / 驻留内存 / 强制 GC 耗时。这 4 个维度合起来能回答 3 个问题：

1. **该参数省不省 CPU？** 看 `GC开销%`
2. **该参数追得上分配速度吗？** 看 `峰值内存` 是否暴涨
3. **该参数回收彻不彻底？** 看 `强制GC耗时` 和 `驻留内存`

要替换成真实业务负载，把内置的 `defaultWorkload` 换掉就行（第 170 行 `workloadFn or defaultWorkload`）。

---

## 三、collectgarbage 参数详解

### 1. `collectgarbage("incremental", 100, 500, 13)`

切换到 **增量式 GC**，并一次性设置 3 个参数。

| 位置 | 参数名 | 示例值 | 含义 |
|---|---|---|---|
| 2 | **pause** | 100 | "暂停"百分比 —— 上一轮 GC 完成后，**当存活内存增长到上次的 pause%** 时，启动下一轮回收。<br>• 默认 200 ⇒ 内存翻倍才回收<br>• 100 ⇒ 没增长就立刻回收（≤100 几乎是"一直在 GC"）<br>• 越小 ⇒ 回收越频繁 ⇒ CPU 开销越高，但峰值内存更低 |
| 3 | **stepmul** | 500 | "步长倍率"百分比 —— GC 每"步"推进多少工作量，**相对于分配速度的倍数**。<br>• 默认 100 ⇒ 分配 100 字节就回收 100 字节<br>• 500 ⇒ 分配 100 字节就回收 500 字节（追得更猛）<br>• 越大 ⇒ 单步卡顿越长，但总能跟上分配 |
| 4 | **stepsize** | 13 | 单步分配 log2 字节数（**2^13 = 8KB** 触发一次 GC step）。<br>• 默认就是 13<br>• 越大 ⇒ GC step 触发越不频繁、单次做的活越多<br>• 越小 ⇒ 触发更频繁、单次更轻 |

**整体效果**：pause=100 + stepmul=500 是"激进追赶"组合 —— 几乎不留间隙 + 每步推得猛。理论上内存能压到最低，但 CPU 会爆（实测里就是那个 +60000% 的元凶）。

---

### 2. `collectgarbage("generational", 20, 100)`

切换到 **分代式 GC**（Lua 5.4 新增），设置 2 个阈值。

| 位置 | 参数名 | 示例值 | 含义 |
|---|---|---|---|
| 2 | **minor multiplier** | 20 | **小回收（minor）触发阈值** —— 当**新分配**的内存增长到"上次 major 后存活内存"的 20% 时，触发一次 minor GC（只扫新生代）。<br>• 越小 ⇒ minor 触发越频繁、回收新生代越及时<br>• 越大 ⇒ 新生代攒得多再回收 |
| 3 | **major multiplier** | 100 | **大回收（major）触发阈值** —— 当**存活的总内存**相对上次 major 后增长到 100% 时（即翻倍），触发一次 major GC（全堆扫描）。<br>• 越小 ⇒ major 越频繁，老对象回收及时但开销大<br>• 越大 ⇒ 老对象积得多再清，CPU 开销低但峰值高 |

**整体效果**：(20, 100) 是 Lua 5.4 的官方默认值。分代式假设大多数对象"朝生夕死" —— minor 频繁地清新生代（便宜），major 攒到内存翻倍再做一次（贵但少）。

---

## 四、两种 GC 模式的本质区别

| | incremental | generational |
|---|---|---|
| 思路 | 把一次完整 GC 切成很多"步"穿插到运行中 | 区分"新对象"和"老对象"，多扫新生代少扫老生代 |
| 适合 | 长生命对象多、堆稳定 | 短生命对象多、分配频繁 |
| 参数维度 | pause + stepmul + stepsize | minor% + major% |
| 项目应用 | 普通区服默认走这里 | 跨服 `vaildWorlds` 命中时走这里 |

简单记：

- **incremental 的两个数字**：管"什么时候开始" 和 "每步干多少"
- **generational 的两个数字**：管"什么时候做小回收" 和 "什么时候做大回收"

---

## 五、实测结果参考（iter=1000, repeats=2）

| GC配置 | CPU开销 | 峰值内存 | 驻留内存 |
|---|---|---|---|
| GC关闭(基线) | - | 32.2 MB | 1.7 MB |
| 默认 incremental (200/100) | +19.9% | 2.2 MB | 1.6 MB |
| **线上当前 incremental (120/300)** | **+48.1%** | 1.7 MB | 1.6 MB |
| 宽松 incremental (200/200) | +8.8% | 2.1 MB | 1.6 MB |
| 激进 incremental (100/500) | +60110% ⚠️ | 1.6 MB | 1.6 MB |
| 默认 generational (20/100) | -2.3% | 1.8 MB | 1.6 MB |
| **线上当前 generational (30/300)** | -5.6% | 1.8 MB | 1.6 MB |
| 宽松 generational (50/300) | -6.5% | 2.1 MB | 1.6 MB |

### 关键结论

1. **当前 incremental (pause=120, stepmul=300) 的 CPU 开销最高（+48%）** —— pause 压到 120 导致几乎每次回收完立刻又启动新一轮，反而比默认的 200 更耗。建议改回 `pause=200, stepmul=200` 这一档，CPU 开销从 +48% 降到 +9%，峰值内存只增 0.4MB。
2. **generational 全面优于 incremental**（这一类负载下）。当前线上 `generational(30, 300)` 已经接近最优；如果玩家服走 generational 分支，目前的参数是合理的。
3. **`pause=100` 是雷区** —— 60110% 不是 bug 是真实表现，pause=100 在 stepmul 大的情况下会陷入"持续 GC"。`set_gc` 里千万别这么设。

---

## 六、使用方式

### 命令行直接运行
```bash
lua54 Test_GC.lua [iter] [repeats]
# 例:
lua54 Test_GC.lua 8000 3
```

### 游戏内 require 调用
```lua
local TestGC = require "Test_GC"
TestGC.run(5000, 3)                    -- 用内置合成负载
TestGC.run(5000, 3, MyWorkloadFn)      -- 用自定义负载函数(更贴近实际)
```

### 自定义负载示例
```lua
TestGC.run(5000, 3, function(iter)
    for i = 1, iter do
        Utils.GetAllHeroPower(someDbid)
    end
end)
```
