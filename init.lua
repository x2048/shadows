-- cache
local rays = {
	size = 50,
	interval = 60,
	vector = vector.new(-1, -2, -1),
	transparency = {},
	loaded_blocks = {},
	generation = 3,
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
			self.transparency[id] = 0.9
		elseif node.drawtype == "liquid" or node.drawtype == "flowingliquid" then
			self.transparency[id] = 0.8
		elseif node.drawtype == "allfaces" or node.drawtype == "allfaces_optional" then 
			self.transparency[id] = 0.7
		elseif node.drawtype == "fencelike" or node.drawtype == "raillike" then
			self.transparency[id] = 0.5
		else
			self.transparency[id] = 0
		end 
	end
end

function rays:update_shadows(min, max)
	local vm = minetest.get_voxel_manip(min, vector.add(max, vector.new(1,1,1)))
	local minedge, maxedge = vm:get_emerged_area()
	local va = VoxelArea:new{MinEdge = minedge, MaxEdge = maxedge}

	local data = vm:get_data()
	local maplight = vm:get_light_data() -- light from and to the map
	local light = {}                     -- real daylight spread

	local origin = va:indexp(min)

	for i in va:iterp(min, vector.add(max, vector.new(1,1,1))) do
		light[i] = maplight[i] % 16 -- copy daylight
		maxi = i
	end

	local minlight = minetest.LIGHT_MAX
	local maxlight = 0
	-- rays
	for y = max.y-min.y,0,-1 do
		for z = 0,max.z-min.z do
			for x = 0,max.x-min.x do
				local i = origin + x + y*va.ystride + z*va.zstride
				local delta = ((min.y + y)%(-self.vector.y) == 0 and 1 or 0) -- 2 to 1
				local source = i + va.ystride - self.vector.x * delta - self.vector.z * delta*va.zstride

				local transparency = math.min(self.transparency[ data[i] ], math.min(self.transparency[ data[i - self.vector.x * delta] ], self.transparency[ data[i - self.vector.z * delta * va.zstride] ]))


				light[i] = light[source] * transparency
				if delta > 0 then
					light[i] = light[i] * 2
					source = source + self.vector.x * delta
					light[i] = light[i] + light[source] * transparency
					source = source - self.vector.x * delta + self.vector.z * delta * va.zstride
					light[i] = light[i] + light[source] * transparency
					light[i] = light[i] / 4
				end
				if light[i] < minlight then
					minlight = light[i]
				end
				if light[i] > maxlight then
					maxlight = light[i]
				end
			end
		end
	end

	local dirty = false

	-- decay
	local function _decay(light)
		return math.max(1, light > 6 and light * 0.7 or light * 0.95)
	end

	for y = max.y-min.y,0,-1 do
		for z = 0,max.z-min.z do
			for x = 0,max.x-min.x do
				local i = origin + x + y*va.ystride + z*va.zstride

				if minlight ~= maxlight then
					local daylight = light[i]

					for dy = 1,-1,-1 do
						for dx = -1,1 do
							for dz = -1,1 do
								-- if not self
								if dx ~= 0 or dy ~= 0 or dz ~= 0 then
									local sourcelight = light[i + dx + dy*va.ystride + dz*va.zstride] or 0
									if _decay(sourcelight) > daylight then
										daylight = _decay(sourcelight)
									end
								end
							end
						end
					end
					light[i] = daylight
				end
				local newlight = math.floor(maplight[i] / 16) * 16 + math.floor(light[i])
				if maplight[i] ~= newlight then
					maplight[i] = newlight
					dirty = true
				end
			end
		end
	end


	if dirty then
		vm:set_light_data(maplight)
		vm:write_to_map(false)
	end
	return dirty
end


-- register node transparency
minetest.register_on_mods_loaded(function() rays:load_definitions() end)

local players = {}

local function to_block_pos(pos)
	return vector.new(math.floor(pos.x / 16), math.floor(pos.y / 16), math.floor(pos.z / 16))
end

local function to_node_pos(pos)
	return vector.new(pos.x * 16, pos.y * 16, pos.z * 16)
end

local function same_pos(pos1, pos2)
	return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

minetest.register_on_joinplayer(function(player)
	players[player:get_player_name()] = to_block_pos(player:get_pos())
end)

local queues = { hi = {}, lo = {} }

local function watch_players()
	for name,previous_block in pairs(players) do
		player = minetest.get_player_by_name(name)
		player_block = to_block_pos(player:get_pos())
		if not same_pos(player_block, previous_block) then
			players[name] = player_block
			for y = -5,5 do
				for x = -5,5 do
					for z = -5,5 do
						local block = vector.add(player_block, vector.new(x, y, z))
						if minetest.get_meta(to_node_pos(block)):get_int("shadows") < rays.generation then
							if math.abs(x) + math.abs(y) + math.abs(z) <= 2 then
								table.insert(queues.hi, block)
							else
								table.insert(queues.lo, block)
							end
						end
					end
				end
			end
		end
	end
end

local function update_blocks()
	local start = os.clock()
	-- loop for a fixed budget of 0.5 seconds
	while os.clock() - start < 0.5 do
		local block
		if #queues.hi > 0 then
			block = table.remove(queues.hi)
		elseif #queues.lo > 0 then
			block = table.remove(queues.lo)
		else
			return
		end

		local close_enough = false
		for _,player_block in pairs(players) do
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
					for x = -1,0 do
						for z = -1,0 do
							local chain_block_node = to_node_pos(vector.add(block, vector.new(x,-1,z)))
							if minetest.get_node_or_nil(chain_block_node) ~= nil then
								minetest.get_meta(chain_block_node):set_int("shadows", 0)
							end
						end
					end
				end
			end
		end
	end
end

local function step()
	watch_players()
	update_blocks()
	minetest.chat_send_all("#queues.lo="..#queues.lo.." #queues.hi="..#queues.hi)
	minetest.after(1, step)
end

minetest.after(1, step)
