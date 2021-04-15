-- cache
local rays = {
	size = 50,
	interval = 60,
	params = {
		minlight = 2,
		threshold = 9,
		a1 = 0.8,
		a2 = 0.85
	},
	vector = vector.new(-1, -2, 1),
	transparency = {},
	buffers = { light = {}, content = {} },
	players = {},
	queues = { lo = {}, hi = {} },
	counters = {},
	generation = 43,
}


function rays:load_definitions()
	for name,node in pairs(minetest.registered_nodes) do
		local id = minetest.get_content_id(name)
		if node._transparency then
			self.transparency[id] = node._transparency
		elseif node.sunlight_propagates then
			self.transparency[id] = 1
		elseif node.drawtype == "airlike" or node.drawtype == "torchlike" or node.drawtype == "firelike" or node.drawtype == "plantlike" then
			self.transparency[id] = 1
		elseif node.drawtype == "glasslike" or node.drawtype == "glasslike_framed" or node.drawtype == "glasslike_framed_optional" then 
			self.transparency[id] = 0.95
		elseif node.drawtype == "liquid" or node.drawtype == "flowingliquid" then
			self.transparency[id] = 0.9
		elseif node.drawtype == "allfaces" or node.drawtype == "allfaces_optional" then 
			self.transparency[id] = 0.8
		elseif node.drawtype == "fencelike" or node.drawtype == "raillike" then
			self.transparency[id] = 0
		else
			self.transparency[id] = 0
		end 
	end
end

function rays:decay(light)
	return math.max(self.params.minlight, light > self.params.threshold and light * self.params.a1 or light * self.params.a2)
end


function rays:update_shadows(min, max)
	local vm = minetest.get_voxel_manip(vector.add(min, vector.new(-1,-1,-1)), vector.add(max, vector.new(1,1,1)))
	local minedge, maxedge = vm:get_emerged_area()
	local va = VoxelArea:new{MinEdge = minedge, MaxEdge = maxedge}

	local data = vm:get_data(self.buffers.content)
	local maplight = vm:get_light_data(self.buffers.light) -- light from and to the map
	local light = {}                     -- real daylight spread

	local origin = va:indexp(min)

	for i in va:iterp(vector.add(min, vector.new(-1,-1,-1)), vector.add(max, vector.new(1,1,1))) do
		light[i] = maplight[i] % 16 -- copy daylight
	end

	local minlight = 99 -- large inital value
	local maxlight = 0
	local i,delta,source,transparency,ilight

	-- rays
	for y = max.y-min.y+1,-1,-1 do
		for z = -1,max.z-min.z+1 do
			for x = -1,max.x-min.x+1 do
				i = origin + x + y*va.ystride + z*va.zstride
				if y >= 0 and y <= max.y - min.y and x >= 0 and x <= max.x - min.x and z >= 0 and z <= max.z - min.z then
					delta = ((min.y + y)%(-self.vector.y) == 0 and 1 or 0) -- 2 to 1
					source = i + va.ystride - self.vector.x * delta - self.vector.z * delta*va.zstride
					-- take the smallest transparency of self, +x and +z. this is to handle edges of walls, houses and caves
					transparency = math.min(self.transparency[ data[i] ], math.min(self.transparency[ data[i - self.vector.x * delta] ], self.transparency[ data[i - self.vector.z * delta * va.zstride] ]))

					if light[source] > minetest.LIGHT_MAX then
						ilight = light[source] * transparency
					else
						ilight = 0
					end
				else
					ilight = light[i]
				end


				if ilight < minlight then
					minlight = ilight
				end
				if ilight > maxlight then
					maxlight = ilight
				end

				light[i] = ilight
			end
		end
	end

	-- propagation / blur
	if minlight ~= maxlight then
		self:inc_counter("blur")

		local points = {}
		for y = max.y-min.y,0,-1 do
			for z = 0,max.z-min.z do
				for x = 0,max.x-min.x do
					-- try current point and it's central reflection
					points[1] = origin + x + y*va.ystride + z*va.zstride
					points[2] = origin + max.x - min.x - x + (max.y - min.y - y)*va.ystride + (max.z - min.z - z)*va.zstride

					for t = 1,2 do
						i = points[t]

						for dy = -1,1 do
							for dx = -1,1 do
								for dz = -1,1 do
									ilight = self:decay(light[i + dx + dy*va.ystride + dz*va.zstride] or 0)
									if ilight > light[i] then
										light[i] = ilight
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- write back to map
	local dirty = false
	for y = max.y-min.y,0,-1 do
		for z = 0,max.z-min.z do
			for x = 0,max.x-min.x do
				i = origin + x + y*va.ystride + z*va.zstride
				ilight = math.floor(maplight[i] / 16) * 16 + math.floor(light[i])
				if maplight[i] ~= ilight then
					maplight[i] = ilight
					dirty = true
				end
			end
		end
	end
	self:inc_counter("calc")

	if dirty then
		vm:set_light_data(maplight)
		vm:write_to_map(false)
		self:inc_counter("update")
	end
	return dirty
end

function rays:inc_counter(name)
	self.counters[name] = (self.counters[name] or 0) + 1
end

function rays:dump_counters()
	local s = "hi="..#rays.queues.hi.." lo="..#rays.queues.lo
	local counters = rays.counters
	rays.counters = {}
	for _,name in ipairs({"ignored", "calc", "blur", "update", "skip", "reset", "requeue" }) do
		s = s.." "..name.."="..(counters[name] or 0)
		counters[name] = nil
	end
	for name,value in pairs(counters) do
		s = s.." "..name.."="..value
	end
	minetest.chat_send_all(s)
end


local function to_block_pos(pos)
	return vector.new(math.floor(pos.x / 16), math.floor(pos.y / 16), math.floor(pos.z / 16))
end

local function to_node_pos(pos)
	return vector.new(pos.x * 16, pos.y * 16, pos.z * 16)
end

local function same_pos(pos1, pos2)
	return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

function rays:watch_players()
	for name,previous_block in pairs(self.players) do
		player = minetest.get_player_by_name(name)
		player_block = to_block_pos(player:get_pos())
		if not same_pos(player_block, previous_block) then
			self.players[name] = player_block
			for y = -3,3 do
				for x = -3,3 do
					for z = -3,3 do
						local block = vector.add(player_block, vector.new(x, y, z))
						if minetest.get_meta(to_node_pos(block)):get_int("shadows") < rays.generation then
							if math.abs(x) + math.abs(y) + math.abs(z) <= 1 then
								table.insert(self.queues.hi, block)
							else
								table.insert(self.queues.lo, block)
							end
						else
							self:inc_counter("ignored")
						end
					end
				end
			end
		end
	end
end

local function mark_block_dirty(block)
	local chain_block_node = to_node_pos(block)
	if minetest.get_node_or_nil(chain_block_node) ~= nil then
		local meta = minetest.get_meta(chain_block_node)
		if meta:get_int("shadows") ~= 0 then
			minetest.get_meta(chain_block_node):set_int("shadows", 0)
			rays:inc_counter("reset")
		end
	end
end

function rays:update_blocks()
	local start = os.clock()
	-- loop for a fixed budget of 0.5 seconds
	while os.clock() - start < 0.5 do
		local block,high_priority
		if #self.queues.hi > 0 then
			block = table.remove(self.queues.hi)
			high_priority = true
		elseif #self.queues.lo > 0 then
			block = table.remove(self.queues.lo)
			high_priority = false
		else
			return
		end

		local close_enough = false
		for _,player_block in pairs(self.players) do
			if math.max(math.max(math.abs(player_block.x-block.x), math.abs(player_block.y-block.y)), math.abs(player_block.z-block.z)) <= 5 then
				close_enough = true
			end
		end

		if close_enough then
			local min = to_node_pos(block)
			if minetest.get_meta(min):get_int("shadows") < rays.generation then
				local max = vector.add(min, vector.new(15,15,15))
				local dirty = rays:update_shadows(min, max)
				minetest.get_meta(min):set_int("shadows", rays.generation)
				if dirty then
					for y = 1,-1,-1 do
						for x = -rays.vector.x,rays.vector.x,rays.vector.x == 0 and 1 or rays.vector.x do
							for z = -rays.vector.z,rays.vector.z,rays.vector.z == 0 and 1 or rays.vector.z do
								if x ~= 0 or y ~= 0 or z ~= 0 then
									mark_block_dirty(vector.add(block, vector.new(x, y, z)))
									if high_priority then
										table.insert(self.queues.lo, vector.add(block, vector.new(x, y, z)))
										self:inc_counter("requeue")
									end
								end
							end
						end
					end
				end
			else
				self:inc_counter("skip")
			end
		end
	end
end

function step()
	rays:watch_players()
	rays:update_blocks()
	rays:dump_counters()
	minetest.after(1, step)
end

minetest.after(1, step)

-- register node transparency
minetest.register_on_mods_loaded(function() rays:load_definitions() end)

minetest.register_on_joinplayer(function(player)
	rays.players[player:get_player_name()] = to_block_pos(player:get_pos())
end)

minetest.register_on_leaveplayer(function(player)
	rays.players[player:get_player_name()] = nil
end)

minetest.register_on_dignode(function(pos)
	local block = to_block_pos(pos)
	mark_block_dirty(block)
	table.insert(rays.queues.hi, block)
end)

minetest.register_on_placenode(function(pos)
	local block = to_block_pos(pos)
	mark_block_dirty(block)
	table.insert(rays.queues.hi, block)
end)
