gPrintMemorytmp = {} 
gPrintMemoryrecord = {} 
function table_nodecount(t)
	local n = 0
	local m = 0
	local size = 0
	for k,v in next, t do
		if type(v) == "table" then
			n = n + 1
		end
		m = m + 1
		
		if type(k) == "string" then
			size = size + string.len(k)
		else
			size = size + 8
		end
		
		if type(v) == "string" then
			size = size + string.len(v)
		else
			size = size + 8
		end
	end
	
	return n,m, size
end
function GetAllTableNodeSize(t) 
	if gPrintMemoryrecord[t] ~= nil then 
		return 0,0, 0
	end 

	gPrintMemoryrecord[t] = 1 
	local nodecount,allcount,size = table_nodecount(t)
	for key,value in pairs(t) do 
		if type(value) == "table" then 
			local nc,ac,sz = GetAllTableNodeSize(value) 
			nodecount = nodecount + nc
			allcount = allcount + ac
			size = size +sz
		end 
	end 
	return nodecount,allcount,size
end 

function OutputGTableName() 
	table.sort(gPrintMemorytmp,function (v1,v2) 
		if v1 == nil then 
			return false 
		end 
		if v2 == nil then 
			return true 
		end 
		return v1[8]>v2[8] end) 
		
	local i=0 
	for k,c in next,gPrintMemorytmp do 
		if i >= 100 then 
			break 
		end 
		error("table:",k,c[1],c[2],c[3],c[4],c[5],c[6],c[7], c[8]) 
		i = i + 1 
	end 
end 

function PrintTables(t) 
	error("lua mem=", math.ceil(collectgarbage("count")/1024).."M")
	error("index   allcount   curall_count      allcount-curall_count     nodecount   curnode_count    nodecount-curnode_count ,size")
	
	local dataCount = 0
	for key,value in pairs(t) do 
		dataCount = dataCount + 1
		if type(value) == "table" then 
			gPrintMemoryrecord = {} 
			local nodecount,allcount,size = GetAllTableNodeSize(value) 
			local curnode_count,curall_count,cur_size = table_nodecount(value) 
			if allcount > 100 then
			    --                            索引   总节点数   首层节点数      总接点数-首层节点数     总的表结构节点数   首层节点总数    总节点数-首层几点总数
				--table.insert(gPrintMemorytmp,{key,   allcount,  curall_count,   allcount-curall_count,  nodecount,         curnode_count,  nodecount-curnode_count, size}) 
				print(key,   allcount,  curall_count,   allcount-curall_count,  nodecount,         curnode_count,  nodecount-curnode_count, size)
			end
			dataCount = dataCount + allcount
		end 
	end
	
	OutputGTableName() 
	
	error("all count " .. dataCount)
	gPrintMemorytmp = {} 
	gPrintMemoryrecord = {} 
end
PrintTables(_G)

--print("dimensionwar team count = " , CPP_GetCountDimensionWarTeamInfo())