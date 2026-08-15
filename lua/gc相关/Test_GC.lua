-------------------------------------------------------------------
-- Test_GC.lua
-- 描  述: Lua5.4 GC 参数对比测试 (优化版)
--        - 用极宽松GC替代GC关闭做基线(避免堆膨胀压低性能)
--        - 每次measure开头复位GC模式(防止profile间泄漏)
--        - 加预热run清除冷启动噪声
--        - memPeak改周期采样最大值(而非结束时刻单点)
--        - 修复stepmul默认值标注错误
--        - 完整的指标解读说明
--
-- 使用方式:
--  1) 命令行(推荐):
--          lua54 Test_GC.lua [iter] [repeats]
--     例:  lua54 Test_GC.lua 5000 3
--
--  2) 游戏内 require 调用:
--          local TestGC = require "Test_GC"
--          TestGC.run(5000, 3)                      -- 用内置负载
--          TestGC.run(5000, 3, MyWorkloadFn)        -- 自定义负载
--          TestGC.runSpike(2000)                    -- 突刺测试
--
-- 输出指标(解读):
--   总CPU(s)    : 工作负载总耗时(含运行期间触发的GC)
--   GC占比      : 相对"极宽松GC基线"多出来的耗时百分比
--                 (基线=pause 10000,stepmul 50,几乎不跑GC但避免堆膨胀)
--   驻留内存    : 强制全量回收后还活着的对象大小; 越小说明能回收的回收得越彻底
--   峰值内存    : 工作负载过程中的最大堆占用(周期采样得到,反映GC追不追得上分配)
--   强制GC耗时  : 工作负载结束后调用collectgarbage("collect")的耗时
--                 - 高值+低驻留 = GC在工作期未及时回收垃圾(GC偷懒)
--                 - 高值+高驻留 = long-lived对象积压或内存泄漏(需检查逻辑)
-------------------------------------------------------------------

local M = {}

-- 命令行运行时的时间函数
if not rawget(_G, "GetCurTime") then
    rawset(_G, "GetCurTime", function() return os.time() end)
end

----------------------------------------------------------
-- 1) 默认合成负载: 模拟服务器混合分配模式
--    - 大量短生命表/字符串(立即变垃圾)
--    - 少量长生命缓存(老对象被替换 -> 产生回收)
----------------------------------------------------------
local _longLive = {}

local function defaultStep(i, t1)
    local tmp = {}
    for j = 1, 100 do
        tmp[j] = { id = j, name = "item_" .. t1 .. "_" .. j, data = { 1, 2, 3, j, i } }
    end
    local parts = {}
    for j = 1, 30 do
        parts[j] = tostring(j) .. "_" .. tostring(i)
    end
    local s = table.concat(parts, ",")
    if i % 20 == 0 then
        _longLive[(#_longLive % 1000) + 1] = { time = i, payload = tmp, str = s }
    end
end

-- workloadFn 契约: function(iter, hookFn, sampleStep)
--   iter       : 迭代次数
--   hookFn     : 周期采样钩子(可空),用于采集峰值内存
--   sampleStep : 每隔多少次迭代调用一次 hookFn
-- 自定义负载应遵循此契约;若不关心峰值采样,可忽略后两个参数
local function defaultWorkload(iter, hookFn, sampleStep)
    local t1 = GetCurTime()
    for i = 1, iter do
        defaultStep(i, t1)
        if hookFn and sampleStep and i % sampleStep == 0 then
            hookFn()
        end
    end
end

----------------------------------------------------------
-- 2) 单次测量 (改进版)
--    - measure 开头复位GC为默认模式
--    - memPeak 改成过程中的周期采样最大值
--    - 清场后都调用两次collectgarbage("collect")确保彻底
----------------------------------------------------------
local function measure(iter, workloadFn, setupFn)
    _longLive = {}
    
    -- 【关键改进】每次测量前复位GC为默认模式,防止上次profile污染
    collectgarbage("incremental", 200, 200, 13)
    collectgarbage("collect")
    collectgarbage("collect")

    setupFn()

    local memBeg   = collectgarbage("count")
    local memPeak  = memBeg
    local clockBeg = os.clock()

    -- 【改进】工作负载中周期采样峰值,而非只看结束时刻
    -- 每 iter/20 次采样一次(最多20个样本)
    local sampleStep = math.max(1, math.floor(iter / 20))
    
    workloadFn(iter, function()
        -- 工作负载可调用此钩子进行周期采样
        local cur = collectgarbage("count")
        if cur > memPeak then memPeak = cur end
    end, sampleStep)

    local clockEnd = os.clock()

    local gcBeg = os.clock()
    collectgarbage("collect")
    local gcEnd = os.clock()
    local memAfter = collectgarbage("count")

    return {
        cpu       = clockEnd - clockBeg,
        memBeg    = memBeg,
        memPeak   = memPeak,
        memAfter  = memAfter,
        gcCollect = gcEnd - gcBeg,
    }
end

----------------------------------------------------------
-- 2.5) 突刺检测: 逐 step 计时, 找出单次最大停顿
--      使用 STEP_BATCH=20 增加精度(相比原来的10)
----------------------------------------------------------
local function measureSpike(iter, setupFn)
    _longLive = {}
    collectgarbage("incremental", 200, 200, 13)
    collectgarbage("collect")
    collectgarbage("collect")

    setupFn()

    local t1 = GetCurTime()
    local samples = {}
    -- 【改进】批量大小从10改成20,提高采样精度
    local STEP_BATCH = 20
    for i = 1, iter do
        local t0 = os.clock()
        for k = 1, STEP_BATCH do
            defaultStep((i - 1) * STEP_BATCH + k, t1)
        end
        samples[i] = os.clock() - t0
    end

    -- 排序找 P50/P95/P99/Max
    table.sort(samples)
    local n = #samples
    local sum = 0
    for _, v in ipairs(samples) do sum = sum + v end

    return {
        avg = sum / n,
        p50 = samples[math.floor(n * 0.50)],
        p95 = samples[math.floor(n * 0.95)],
        p99 = samples[math.floor(n * 0.99)],
        max = samples[n],
        maxRatio = samples[n] / (sum / n),
    }
end

local function avgRuns(repeats, iter, workloadFn, setupFn)
    -- 额外跑1次预热(丢弃),清除冷启动噪声
    measure(iter, workloadFn, setupFn)

    local sum = { cpu = 0, memBeg = 0, memPeak = 0, memAfter = 0, gcCollect = 0 }
    for _ = 1, repeats do
        local r = measure(iter, workloadFn, setupFn)
        for k, v in pairs(r) do sum[k] = sum[k] + v end
    end
    for k, v in pairs(sum) do sum[k] = v / repeats end
    return sum
end

----------------------------------------------------------
-- 3) 待测的 GC 参数集
--    【改进】基线改为极宽松GC(pause=10000,stepmul=50),
--           避免GC关闭时堆无限膨胀导致cache局部性变差
--           这样基线CPU更接近真实环境的下界
--
--    incremental: setpause / setstepmul / stepsize
--      - pause     : 上次回收后多久启动新一轮; 越小回收越频繁
--      - stepmul   : 单步推进倍率; 越大每一步走得越多
--    generational: minor multiplier / major multiplier
--      - minorMul  : 新生代触发阈值百分比; 默认 20
--      - majorMul  : major 触发阈值百分比; 默认 100
----------------------------------------------------------
local profiles = {
    {
        name = "极宽松 incremental (基线: pause=10000,stepmul=50)",
        note = "[基线] GC几乎不跑,堆无限膨胀避免,代表性能下界",
        setup = function()
            collectgarbage("incremental", 10000, 50, 13)
        end,
    },
    {
        name = "默认 incremental (pause=200,stepmul=200)",
        note = "Lua 5.4 真实默认值(非原脚本标注的stepmul=100)",
        setup = function()
            collectgarbage("incremental", 200, 200, 13)
        end,
    },
    {
        name = "线上当前 incremental (pause=120,stepmul=300)",
        note = "X-Clash 现行配置,更频繁更激进",
        setup = function()
            collectgarbage("incremental", 120, 300, 13)
        end,
    },
    {
        name = "宽松 incremental (pause=300,stepmul=150)",
        note = "比默认更宽松,GC更少但堆更大",
        setup = function()
            collectgarbage("incremental", 300, 150, 13)
        end,
    },
    {
        name = "激进 incremental (pause=100,stepmul=500)",
        note = "最激进: 高频回收,单步大,可能导致持续GC",
        setup = function()
            collectgarbage("incremental", 100, 500, 13)
        end,
    },
    {
        name = "默认 generational (minor=20,major=100)",
        note = "Lua 5.4 分代GC默认值",
        setup = function()
            collectgarbage("generational", 20, 100)
        end,
    },
    {
        name = "线上当前 generational (minor=30,major=300)",
        note = "X-Clash 分代方案,major阈值高",
        setup = function()
            collectgarbage("generational", 30, 300)
        end,
    },
    {
        name = "宽松 generational (minor=50,major=300)",
        note = "新生代宽松,老年代宽松",
        setup = function()
            collectgarbage("generational", 50, 300)
        end,
    },
    {
        name = "实验 generational (minor=50,major=50)",
        note = "激进的分代:高频full GC",
        setup = function()
            collectgarbage("generational", 50, 50)
        end,
    },
    {
        name = "实验 generational (minor=50,major=80)",
        note = "稍宽松的激进方案",
        setup = function()
            collectgarbage("generational", 50, 80)
        end,
    },
    {
        name = "实验 generational (minor=50,major=100)",
        note = "新生代激进,老年代适中",
        setup = function()
            collectgarbage("generational", 50, 100)
        end,
    },
    {
        name = "实验 incremental (pause=140,stepmul=300)",
        note = "介于线上和默认之间",
        setup = function()
            collectgarbage("incremental", 140, 300, 13)
        end,
    },
    {
        name = "实验 generational (minor=20,major=90)",
        note = "接近默认,微调major",
        setup = function()
            collectgarbage("generational", 20, 90)
        end,
    },
    {
        name = "实验 generational (minor=20,major=80)",
        note = "激进的老年代回收",
        setup = function()
            collectgarbage("generational", 20, 80)
        end,
    },
}

----------------------------------------------------------
-- 4) 主入口
----------------------------------------------------------
local function fmt(num) return string.format("%.3f", num) end
local function fmtKB(num) return string.format("%.1f KB", num) end
local function fmtPct(num) return string.format("%+.1f%%", num) end

function M.run(iter, repeats, workloadFn)
    iter      = iter or 5000
    repeats   = repeats or 3
    workloadFn = workloadFn or defaultWorkload

    print(string.format("Lua版本: %s", _VERSION))
    print(string.format("迭代次数: %d, 每组重复: %d (含1次预热)", iter, repeats))
    print(string.rep("=", 130))

    local results = {}
    for _, p in ipairs(profiles) do
        local r = avgRuns(repeats, iter, workloadFn, p.setup)
        r.name = p.name
        r.note = p.note
        table.insert(results, r)
    end

    -- 用第一个profile(极宽松GC)做对照基线
    local base = results[1].cpu

    print(string.format("%-50s %10s %10s %12s %12s %12s %s",
        "GC配置", "CPU(s)", "GC开销", "驻留内存", "峰值内存", "强制GC(s)", "备注"))
    print(string.rep("-", 150))
    for _, r in ipairs(results) do
        local overhead = base > 0 and ((r.cpu - base) / base * 100) or 0
        print(string.format("%-50s %10s %10s %12s %12s %12s %s",
            r.name,
            fmt(r.cpu),
            r.name:find("基线") and "   -" or fmtPct(overhead),
            fmtKB(r.memAfter),
            fmtKB(r.memPeak),
            fmt(r.gcCollect),
            r.note or ""))
    end
    print(string.rep("=", 130))
    
    print("\n【指标解读】")
    print("  1. GC开销 = (当前CPU - 基线CPU) / 基线CPU")
    print("     - 负数 = 比基线快(不太可能,通常是噪声)")
    print("     - 0-5% = GC开销极低,几乎无影响")
    print("     - 5-20% = 合理范围")
    print("     - >20% = GC成为显著瓶颈")
    print()
    print("  2. 峰值内存 vs 驻留内存")
    print("     - 峰值远大于驻留 = GC追不上分配,堆胀大后才开始收,卡顿明显")
    print("     - 两者接近 = GC跟上分配,内存管理平稳")
    print()
    print("  3. 强制GC耗时 (工作后还要collect多久)")
    print("     - 低值 + 低驻留 = GC在工作期及时回收(最优)")
    print("     - 高值 + 低驻留 = GC偷懒未及时回收,末尾集中补课")
    print("     - 高值 + 高驻留 = 可能有内存泄漏或老对象积压")
    print()
    print("  4. generational vs incremental 对比")
    print("     - generational通常CPU低,但需警惕major扫描卡顿")
    print("     - incremental CPU相对高,但延迟更均匀")
    print()
    print("【建议】")
    print("  1. 先选一个GC开销 <10% 的配置")
    print("  2. 检查峰值内存是否可接受(不能超过内存限制)")
    print("  3. 用runSpike检查是否有 >5ms 的突刺")
    print("  4. 在灰度环境跑2-4周验证")

    return results
end

----------------------------------------------------------
-- 5) 突刺对比入口: 只测每次迭代耗时分布
--    【改进】激进profile不被跳过,因为其突刺行为最该测
----------------------------------------------------------
local function fmtMS(seconds) return string.format("%.3f ms", seconds * 1000) end

function M.runSpike(iter)
    iter = iter or 2000
    print(string.format("Lua版本: %s", _VERSION))
    print(string.format("【突刺检测】迭代次数: %d (每次迭代单独计时,批量大小20step)", iter))
    print(string.rep("=", 130))
    print(string.format("%-50s %10s %10s %10s %10s %12s",
        "GC配置", "平均", "P50", "P95", "P99", "Max(倍率)"))
    print(string.rep("-", 130))

    for _, p in ipairs(profiles) do
        local r = measureSpike(iter, p.setup)
        print(string.format("%-50s %10s %10s %10s %10s %12s",
            p.name,
            fmtMS(r.avg),
            fmtMS(r.p50),
            fmtMS(r.p95),
            fmtMS(r.p99),
            fmtMS(r.max) .. string.format(" (x%.1f)", r.maxRatio)))
    end
    print(string.rep("=", 130))
    print("\n【解读】")
    print("  Max/平均 倍率:")
    print("    - <1.5x = 延迟分布均匀,无明显突刺(ideal)")
    print("    - 1.5-3x = 偶发卡顿,可能单步GC较重")
    print("    - >3x = 严重突刺,存在间歇性长stop")
    print()
    print("  P95/P99 vs 平均:")
    print("    - 接近平均 = 卡顿分布均匀(incremental典型表现)")
    print("    - 远高于平均 = 偶发大卡顿(generational的major扫描典型)")
end

----------------------------------------------------------
-- 6) 命令行直接运行
----------------------------------------------------------
if arg and arg[0] and arg[0]:find("Test_GC") then
    local mode    = arg[1] or "run"
    if mode == "spike" then
        local iter = tonumber(arg[2]) or 2000
        M.runSpike(iter)
    else
        local iter    = tonumber(arg[1]) or 5000
        local repeats = tonumber(arg[2]) or 3
        M.run(iter, repeats)
    end
end

return M
