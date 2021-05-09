local shadows = {
	map_params = {
		decay_minimum_light = 3,
		decay_light_threshold = 9,
		decay_factor_bright = 0.8,
		decay_factor_dark = 0.85,
		follow_sun = false,
		blocksize = 16,
	},
	max_distance = 7,
	time_budget = 500,
	log_counters = false,
	hfov = 1.1,
	vfov = 1.4,
	vector = vector.new(-1, -2, 1),
	transparency = {},
	buffers = { light = {}, content = {} },
	players = {},
	counters = {},
}

local storage = minetest.get_mod_storage()

-- initialize
function shadows:initialize()
	-- read from minetest.conf using initial settings as defaults
	self.map_params.decay_minimum_light = tonumber(minetest.settings:get("shadows.decay_minimum_light")) or self.map_params.decay_minimum_light
	self.map_params.decay_light_threshold = tonumber(minetest.settings:get("shadows.decay_light_threshold")) or self.map_params.decay_light_threshold
	self.map_params.decay_factor_bright = tonumber(minetest.settings:get("shadows.decay_factor_bright")) or self.map_params.decay_factor_bright
	self.map_params.decay_factor_dark = tonumber(minetest.settings:get("shadows.decay_factor_dark")) or self.map_params.decay_factor_dark
	self.map_params.follow_sun = minetest.settings:get("shadows.follow_sun") == nil and self.map_params.follow_sun or minetest.settings:get("shadows.follow_sun") == "true"

	self.max_distance = tonumber(minetest.settings:get("shadows.max_distance")) or self.max_distance
	self.time_budget = tonumber(minetest.settings:get("shadows.time_budget")) or self.time_budget
	self.log_counters = minetest.settings:get("shadows.log_counters") == nil and self.log_counters or minetest.settings:get("shadows.log_counters") == "true"

	-- detect changed settings and set the generation
	self.params_dirty = false

	for key,value in pairs(self.map_params) do
		if tostring(value) ~= storage:get(key) then
			storage:set_string(key, tostring(value))
			self.params_dirty = true
		end
	end

	if storage:get("generation") ~= nil and not self.params_dirty then
		self.generation = tonumber(storage:get("generation"))
	end
end

shadows:initialize()

function shadows:load_definitions()
	for name,node in pairs(minetest.registered_nodes) do
		local id = minetest.get_content_id(name)
		if node._transparency then
			self.transparency[id] = node._transparency
		elseif id == minetest.CONTENT_IGNORE or node.sunlight_propagates then
			self.transparency[id] = 1
		elseif node.drawtype == "airlike" or node.drawtype == "torchlike" or node.drawtype == "firelike" or node.drawtype == "plantlike" then
			self.transparency[id] = 1
		elseif node.drawtype == "glasslike" or node.drawtype == "glasslike_framed" or node.drawtype == "glasslike_framed_optional" then 
			self.transparency[id] = 0.95
		elseif node.drawtype == "liquid" or node.drawtype == "flowingliquid" then
			self.transparency[id] = 0.9
		elseif node.drawtype == "allfaces" or node.drawtype == "allfaces_optional" then 
			self.transparency[id] = 0.8
		elseif node.drawtype == "normal" then
			self.transparency[id] = 0	 -- solid
		else
			self.transparency[id] = 0.01 -- not fully solid but casts shadow
		end 
	end
end

local function decay_light(light, min, th, fbright, fdark)
	return math.max(min, light >= th and light * fbright or light * fdark)
end


function shadows:update_shadows(min, max)
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

	-- shadows
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
						ilight = light[source] * transparency -- project ray
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
		local strides = { 1, va.ystride, va.zstride }
		for y = 0,max.y-min.y do
			for z = 0,max.z-min.z do
				for x = 0,max.x-min.x do
					-- try current point and it's central reflection
					points[1] = origin + x + y*va.ystride + z*va.zstride
					points[2] = origin + max.x - min.x - x + (max.y - min.y - y)*va.ystride + (max.z - min.z - z)*va.zstride

					for t = 1,2 do
						i = points[t]

						-- only propagate light through non-solid nodes
						if self.transparency[ data[i] ] ~= 0 then
							for d = -1,1,2 do
								for stride = 1,#strides do
									ilight = decay_light((light[i + d*strides[stride]] or 0),
											self.map_params.decay_minimum_light,
											self.map_params.decay_light_threshold,
											self.map_params.decay_factor_bright,
											self.map_params.decay_factor_dark)
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
	for y = 0,max.y-min.y do
		for z = 0,max.z-min.z do
			for x = 0,max.x-min.x do
				i = origin + x + y*va.ystride + z*va.zstride
				ilight = math.max(light[i], math.floor(maplight[i] / 16)) -- copy nightlight / artificial light
				ilight = math.floor(maplight[i] / 16) * 16 + math.floor(ilight)
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

if shadows.log_counters then
	function shadows:inc_counter(name)
		self.counters[name] = (self.counters[name] or 0) + 1
	end

	function shadows:dump_counters()
		if not self.log_counters then
			return
		end

		local queue_length = 0
		local queue
		for _,state in pairs(self.players) do
			queue = state.queue or {}
			queue_length = queue_length + #queue - (queue.count or 0)
		end
		local s = "queue_length="..queue_length
		local counters = self.counters
		self.counters = {}
		for _,name in ipairs({"ignore", "queue", "dequeue", "calc", "blur", "update", "skip", "reset", "requeue" }) do
			s = s.." "..name.."="..(counters[name] or 0)
			counters[name] = nil
		end
		for name,value in pairs(counters) do
			s = s.." "..name.."="..value
		end
		s = s.." generation="..self.generation
		s = s.." params_dirty="..tostring(self.params_dirty)
		s = s.." params="..dump(self.map_params,"")
		minetest.chat_send_all(s)
	end
else
	function shadows:inc_counter(name) end
	function shadows:dump_counters() end
end

local function to_block_pos(pos, bs)
	return vector.new(math.floor(pos.x / bs), math.floor(pos.y / bs), math.floor(pos.z / bs))
end

local function to_node_pos(pos, bs)
	return vector.new(pos.x * bs, pos.y * bs, pos.z * bs)
end

function shadows:watch_players()
	-- ensure generation is set
	if self.generation == nil then
		self.generation = 48*(minetest.get_day_count() + minetest.get_timeofday())
		minetest.chat_send_all("setting new generation to "..self.generation)
		storage:set_string("generation", tostring(self.generation))
	end

	-- scan players and update the queues
	for name,previous in pairs(self.players) do
		player = minetest.get_player_by_name(name)
		local look_direction = vector.normalize(player:get_look_dir())
		player_block = to_block_pos(player:get_pos(), self.map_params.blocksize)
		self.players[name] = { block = player_block, direction = look_direction, generation = shadows.generation, queue = {} }

		local side = vector.normalize(vector.cross(look_direction, vector.new(0, 1, 0)))
		local up = vector.normalize(vector.cross(look_direction, side))
		local block,node_pos

		local blocks_queued = 0
		local n = 4
		local blocks_seen = {}
		for d = 0,n*self.max_distance do
			for u = 0,math.floor(self.hfov*d) do
				for v = 0,math.floor(self.vfov*d) do
					for su=-1,1,2 do
						for sv=-1,1,2 do
							if blocks_queued >= 100 then
								break
							end

							block = vector.add(player_block, vector.multiply(look_direction, d/n))
							block = vector.add(block, vector.multiply(side, su*u/n))
							block = vector.add(block, vector.multiply(up, sv*v/n))
							block = vector.floor(block)

							if blocks_seen[minetest.hash_node_position(block)] then
								break
							end
							blocks_seen[minetest.hash_node_position(block)] = true

							node_pos = to_node_pos(block, self.map_params.blocksize)


							if minetest.get_node_or_nil(node_pos) ~= nil and minetest.get_meta(node_pos):get_int("shadows:gen") < self.generation then
								table.insert(self.players[name].queue, block)
								blocks_queued = blocks_queued + 1
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
end

function shadows:mark_block_dirty(block)
	local chain_block_node = to_node_pos(block, self.map_params.blocksize)
	if minetest.get_node_or_nil(chain_block_node) ~= nil then
		local meta = minetest.get_meta(chain_block_node)
		if meta:get_int("shadows:gen") ~= 0 then
			minetest.get_meta(chain_block_node):set_int("shadows:gen", 0)
			shadows:inc_counter("reset")
		end
	end
end

function shadows:update_blocks()
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
	-- loop for the configurd budget or until everything's processed
	while os.clock() - start < self.time_budget / 1000 and empty_queues < #queues do
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
			local min = to_node_pos(block, self.map_params.blocksize)
			if minetest.get_meta(min):get_int("shadows:gen") < self.generation then
				local max = vector.add(min, vector.new(self.map_params.blocksize-1,self.map_params.blocksize-1,self.map_params.blocksize-1))
				local edges = shadows:update_shadows(min, max)
				minetest.get_meta(min):set_int("shadows:gen", shadows.generation)
				if edges then
					for y = 1,-1,-1 do
						for x = -shadows.vector.x,shadows.vector.x,shadows.vector.x == 0 and 1 or shadows.vector.x do
							for z = -shadows.vector.z,shadows.vector.z,shadows.vector.z == 0 and 1 or shadows.vector.z do
								local ei = (x + 1) + 3 * (y + 1) + 9 * (z + 1)
								if (x ~= 0 or y ~= 0 or z ~= 0) and edges[ei] then
									self:mark_block_dirty(vector.add(block, vector.new(x, y, z)))
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
function shadows:update_vector()
	if not self.map_params.follow_sun then
		return
	end
	local time = math.floor(48 * minetest.get_timeofday()) / 48
	local adj_time = math.min(19/24, 6/24 + math.max(0, time - 7/24) * 6/5)
	local new_vector = vector.new(math.floor(0.5-math.sin(m2pi * adj_time)), -1 - math.abs(math.floor(2 * math.cos(m2pi * adj_time))), math.floor(math.cos(m2pi * adj_time)))
	if not vector.equals(self.vector, new_vector) then
		self.vector = new_vector
		self.generation = math.floor(48 * (minetest.get_day_count() + time))
	end
end

function step()
	local time = minetest.get_timeofday()
	if time >= 4/24 and time < 20/24 then
		shadows:watch_players()
		shadows:update_vector()
		shadows:update_blocks()
		shadows:dump_counters()
	end
	minetest.after(1, step)
end

minetest.after(1, step)

-- register node transparency
minetest.register_on_mods_loaded(function() shadows:load_definitions() end)

minetest.register_on_joinplayer(function(player)
	shadows.players[player:get_player_name()] = to_block_pos(player:get_pos(), shadows.map_params.blocksize)
end)

minetest.register_on_leaveplayer(function(player)
	shadows.players[player:get_player_name()] = nil
end)

minetest.register_on_dignode(function(pos)
	local block = to_block_pos(pos, shadows.map_params.blocksize)
	shadows:mark_block_dirty(block)
end)

minetest.register_on_placenode(function(pos)
	local block = to_block_pos(pos, shadows.map_params.blocksize)
	shadows:mark_block_dirty(block)
end)
