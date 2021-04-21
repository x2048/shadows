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
	counters = {},
	blocksize = 16,
	depth = 7,
	hfov = 1.7,
	vfov = 1.1,
	generation = 49,
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
	-- mark edges as dirty for chained processing
	-- every edge has coordinates (x,y,z) and coords can take values 0 (coord == 0), 1 (coord > 0 and < max), 2 (coord == max)
	-- index in the edges = x + 3*y + 9*z
	local edges,ei = {}, 0
	local dirty = false
	for y = max.y-min.y,0,-1 do
		for z = 0,max.z-min.z do
			for x = 0,max.x-min.x do
				i = origin + x + y*va.ystride + z*va.zstride
				ilight = math.floor(maplight[i] / 16) * 16 + math.floor(light[i])
				if math.abs(maplight[i] - ilight) > 0.1 then
					maplight[i] = ilight

					-- calculate index of the edge
					ei = (x > 0 and 1 or 0) + (x == max.x-min.x and 1 or 0) +
							3 * ((y > 0 and 1 or 0) + (y == max.y-min.y and 1 or 0)) +
							9 * ((z > 0 and 1 or 0) + (z == max.z-min.z and 1 or 0))

					edges[ei] = true
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
	return dirty and edges or false
end

function rays:inc_counter(name)
	self.counters[name] = (self.counters[name] or 0) + 1
end

function rays:dump_counters()
	local queue_length = 0
	local queue
	for _,state in pairs(self.players) do
		queue = state.queue or {}
		queue_length = queue_length + #queue - (queue.count or 0)
	end
	local s = "queue_length="..queue_length
	local counters = rays.counters
	rays.counters = {}
	for _,name in ipairs({"ignore", "queue", "dequeue", "calc", "blur", "update", "skip", "reset", "requeue" }) do
		s = s.." "..name.."="..(counters[name] or 0)
		counters[name] = nil
	end
	for name,value in pairs(counters) do
		s = s.." "..name.."="..value
	end
	minetest.chat_send_all(s)
end


local function to_block_pos(pos)
	return vector.new(math.floor(pos.x / rays.blocksize), math.floor(pos.y / rays.blocksize), math.floor(pos.z / rays.blocksize))
end

local function to_node_pos(pos)
	return vector.new(pos.x * rays.blocksize, pos.y * rays.blocksize, pos.z * rays.blocksize)
end

local function same_pos(pos1, pos2)
	return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

function rays:watch_players()
	for name,previous in pairs(self.players) do
		player = minetest.get_player_by_name(name)
		local look_direction = vector.normalize(player:get_look_dir())
		player_block = to_block_pos(player:get_pos())
		if not (vector.equals(player_block, previous.block or vector.new(0,0,0)) and vector.equals(look_direction, previous.direction or vector.new(0,1,0)) and self.generation == previous.generation) then
			self.players[name] = { block = player_block, direction = look_direction, generation = rays.generation, queue = {} }

			local side = vector.normalize(vector.cross(look_direction, vector.new(0, 1, 0)))
			local up = vector.normalize(vector.cross(look_direction, side))
			local block,node_pos

			for d = 0,self.depth do
				for u = -math.floor(self.hfov*d),math.floor(self.hfov*d) do
					for w = -math.floor(self.vfov*d),math.floor(self.vfov*d) do
						block = vector.add(player_block, vector.multiply(look_direction, d))
						block = vector.add(block, vector.multiply(side, u))
						block = vector.add(block, vector.multiply(up, w))
						block = vector.floor(block)

						node_pos = to_node_pos(block)


						if minetest.get_node_or_nil(node_pos) ~= nil and minetest.get_meta(node_pos):get_int("shadows") < self.generation then
							table.insert(self.players[name].queue, block)
							self:inc_counter("queue")
						else
							self:inc_counter("ignore")
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
	local queues = {}
	for _, state in pairs(self.players) do
		if state.queue ~= nil and #state.queue > 0 then
			table.insert(queues, state.queue)
		end
	end

	if #queues == 0 then
		return
	end

	local start = os.clock()
	local i = 1
	local empty_queues = 0
	-- loop for a fixed budget of 0.5 seconds or until everything's processed
	while os.clock() - start < 0.5 and empty_queues < #queues do
		local block
		if #queues[i] > (queues[i].count or 0) then
			-- this is a fancy way to dequeue from the head of the queue
			queues[i].count = (queues[i].count or 0) + 1
			block = queues[i][queues[i].count]
			queues[i][queues[i].count] = nil
			self:inc_counter("dequeue")
		elseif queues[i].count ~= nil then
			empty_queues = empty_queues + 1
			queues[i].count = nil
		end

		if block ~= nil then
			local min = to_node_pos(block)
			if minetest.get_meta(min):get_int("shadows") < self.generation then
				local max = vector.add(min, vector.new(self.blocksize-1,self.blocksize-1,self.blocksize-1))
				local edges = rays:update_shadows(min, max)
				minetest.get_meta(min):set_int("shadows", rays.generation)
				if edges then
					for y = 1,-1,-1 do
						for x = -rays.vector.x,rays.vector.x,rays.vector.x == 0 and 1 or rays.vector.x do
							for z = -rays.vector.z,rays.vector.z,rays.vector.z == 0 and 1 or rays.vector.z do
								local ei = (x + 1) + 3 * (y + 1) + 9 * (z + 1)
								if (x ~= 0 or y ~= 0 or z ~= 0) and edges[ei] then
									mark_block_dirty(vector.add(block, vector.new(x, y, z)))
								end
							end
						end
					end
				end
			else
				self:inc_counter("skip")
			end
		end
		i = i % #queues + 1
	end
end

local m2pi = math.pi * 2
function rays:update_vector()
	local time = math.floor(48 * minetest.get_timeofday()) / 48
	local adj_time = math.min(19/24, 6/24 + math.max(0, time - 7/24) * 6/5)
	local new_vector = vector.new(math.floor(0.5-math.sin(m2pi * adj_time)), -1 - math.abs(math.floor(2 * math.cos(m2pi * adj_time))), math.floor(math.cos(m2pi * adj_time)))
	if not vector.equals(self.vector, new_vector) then
		self.vector = new_vector
		self.generation = math.floor(48 * (minetest.get_day_count() + time))
	end
end

function step()
	rays:watch_players()
	rays:update_blocks()
	rays:update_vector()
	--rays:dump_counters()
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
end)

minetest.register_on_placenode(function(pos)
	local block = to_block_pos(pos)
	mark_block_dirty(block)
end)
