print("lua script-------------------------------")

warning("11 cur mem=", collectgarbage("count")/1024, " objects=", objects, " create_objs_round=", create_objs_round)
objects = {}
collectgarbage("collect")
warning("22 cur mem=", collectgarbage("count")/1024, " objects=", objects, " create_objs_round=", create_objs_round)

--[[
objects = {}
local size_list = {100, 512, 1024, 2048, 8192, 16384}  -- 不同尺寸制造碎片

-- 随机创建不同大小的字符串table
local function create_objs_round(rounds, objs_per_round)
    for r = 1, rounds do
        for i = 1, objs_per_round do
            local size = size_list[math.random(#size_list)]
            -- 构造不同size的字符串（制造分配器空洞）
            local idx = math.random(1, 1000)
            local str = string.rep(table.concat({"C", tostring(idx)}), size)
            if i % 2 == 0 then
                -- 有一半混合不释放
                objects[#objects + 1] = str
            end
        end
        
        -- 随机释放部分对象
        for j = 1, #objects, 3 do
            objects[j] = nil
        end

        -- 主动触发GC
        collectgarbage("collect")

        -- 查看当前Lua的堆内存
        print(string.format("Round %d: collectgarbage count = %.2f M", r, collectgarbage("count")/1024))
        -- 可选：停顿观察top/pmap实际进程物理占用
        os.execute("sleep 0.1")
    end
end

-- 执行模拟 (比如100轮，每轮创建1000个对象)
collectgarbage("collect")
local start_mem = collectgarbage("count")/1024
math.randomseed(os.time())
create_objs_round(100, 1000)
local end_mem = collectgarbage("count")/1024
warning("Test over, please check physical memory usage in system tools/top! start_mem=", start_mem, " end_mem=", end_mem)
--]]