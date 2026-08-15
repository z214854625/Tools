-- 创建一个允许自定义字段的表
local function createStrictTable(initialFields)
    local t = initialFields or {}

    -- 设置元表
    local metatable = {
        __newindex = function(table, key, value)
            error("Attempt to add new field '" .. key .. "' to a strict table.", 2)
        end,
        __index = function(table, key)
            return rawget(t, key)  -- 返回实际的字段值
        end,
        __metatable = "This table is strict"  -- 保护元表
    }

    setmetatable(t, metatable)
    return t
end

-- 创建一个只允许自定义字段的严格表
local strictTable = createStrictTable({name = "Ice", age = 3})

-- 测试访问已有字段
print(strictTable.name)  -- 输出: Ice
print(strictTable.age)   -- 输出: 3

-- 尝试添加新字段，应该引发错误
strictTable.gender = "Female"  -- 此行会引发错误

-- 尝试访问元表
print(getmetatable(strictTable))  -- 输出: 是一个保护元表的信息
