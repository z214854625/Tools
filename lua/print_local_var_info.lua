
--[[
	通过debug.getlocal(1, 1) 可以打印局部变量的详细信息 可以重载一下全局的tostring()函数将table详细信息打印出来
	也可以统计 BasicAndDiamondGift中子表的节点数和层级
]]--
local function show1()
    local BasicAndDiamondGift = require "BasicAndDiamondGift"
    -- 专属抽和心愿抽
    local RecruitAct = require "RecruitAct"
    local BossTraining = require "BossTraining"
    local BossTrainingMgr = require "BossTrainingMgr"
    local GiftMgr = require "GiftMgr"
    local GiftMsg = require "GiftMsg"
    local BattleTeaching = require "BattleTeaching"
    local BattleTeachingMgr = require "BattleTeachingMgr"
    local VarAct = require "VarAct"
    --遍历所有local变量
    for i = 1, 200 do
	local varName, varVal = debug.getlocal(1, i)
        if varVal then
            local valtype = type(varVal)
            local count1 = (valtype == "table" and HelpFunc.table_count(varVal) or 1)
            warning("i=", i, varName, ", count=", count1, ", val type=", valtype)
            if valtype == "table" then
                for subName, subVal in pairs(varVal) do
                    local count2 = (type(subVal) == "table" and HelpFunc.table_count(subVal) or 1)
                    print(subName, type(subVal), ", count=", count2)
                end
            end
        end
    end
end
show1()
