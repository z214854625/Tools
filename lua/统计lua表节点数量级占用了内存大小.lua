gPrintMemorytmp = {} 
gPrintMemoryrecord = {} 
function table_nodecount(t)
	local n = 0
	local m = 0
	for k,v in next, t do
		if type(v) == "table" then
			n = n + 1
		end
		m = m + 1
	end
	
	return n,m
end
function GetAllTableNodeSize(t) 
	if gPrintMemoryrecord[t] ~= nil then 
		return 0,0
	end 

	gPrintMemoryrecord[t] = 1 
	local nodecount,allcount = table_nodecount(t)
	for key,value in pairs(t) do 
		if type(value) == "table" then 
			local nc,ac = GetAllTableNodeSize(value) 
			nodecount = nodecount + nc
			allcount = allcount + ac
			if allcount >= 10000 then
				break
			end
		end 
	end 
	return nodecount,allcount
end 

function OutputGTableName(outfile) 
	table.sort(gPrintMemorytmp,function (v1,v2) 
		if v1 == nil then 
			return false 
		end 
		if v2 == nil then 
			return true 
		end 
		return v1[2]>v2[2] end) 
		
	local i=0 
	
	local file = nil
	local totalbytes = collectgarbage("count")
	if outfile ~= "" then
		file = io.open(outfile,"a+")
		file:write("\nLua内存信息："..totalbytes.."\n") 
		file:write("表:索引,总节点数,次级节点数,其他节点数,总表数,次级表数,其他表数,表名\n") 
	else
		error("Lua内存信息："..totalbytes) 
		error("表:索引,总节点数,次级节点数,其他节点数,总表数,次级表数,其他表数,表名") 
	end
	
	for k,c in next,gPrintMemorytmp do 
		if i >= 50 then 
			break 
		end 
		if file ~= nil then
			file:write("表:,"..k..","..c[2]..","..c[3]..","..c[4]..","..c[5]..","..c[6]..","..c[7]..","..c[1].."\n")
		else
			error("表:",k,c[2],c[3],c[4],c[5],c[6],c[7],c[1]) 
		end
		i = i + 1 
	end 
	
	if file ~= nil then
		file:flush()
		file:close()
	end
end 

function LuaTableMemroyInfo(outfile,t) 
	if t == nil then
		t = _G
	end
	for key,value in pairs(t) do 
		if type(value) == "table" then 
			gPrintMemoryrecord = {} 
			local nodecount,allcount = GetAllTableNodeSize(value) 
			local curnode_count,curall_count = table_nodecount(value) 
			if allcount > 1000 then
				table.insert(gPrintMemorytmp,{key,allcount,curall_count,allcount-curall_count,nodecount,curnode_count,nodecount-curnode_count}) 
			end
		end 
	end
	OutputGTableName(outfile) 
	gPrintMemorytmp = {} 
	gPrintMemoryrecord = {} 
end
LuaTableMemroyInfo("node_data.txt",nil)
