local PLACER = "wp-long-haul-pad-placer"
local DRONE = "wp-long-haul-drone"
local GUI = "wp_long_haul_panel"

local D = defines.direction
local PAD_BY_DIR = {
  [D.north] = "wp-long-haul-pad-north",
  [D.east] = "wp-long-haul-pad-east",
  [D.south] = "wp-long-haul-pad-south",
  [D.west] = "wp-long-haul-pad-west",
}
local DIR_BY_PAD = {}
local PAD_NAMES = {}
for dir, name in pairs(PAD_BY_DIR) do
  DIR_BY_PAD[name] = dir
  PAD_NAMES[#PAD_NAMES + 1] = name
end

-- Drones and pads
local DRONE_STACK = 10
-- Per research tier: drone slots per pad, and payload per drone in grams
-- (item weights are in grams; a rocket lifts 1,000,000).
local TIERS = {
  [0] = { slots = 2, payload = 100 * 1000 }, -- Long Haul Logistics: 20 drones, 100 kg
  [1] = { slots = 3, payload = 250 * 1000 }, -- Cargo capacity 1: 30 drones, 250 kg
  [2] = { slots = 4, payload = 500 * 1000 }, -- Cargo capacity 2: 40 drones, 500 kg
}
local MAX_SLOTS = 4
local RESERVE_DRONES = 2         -- drones a non-hub pad keeps for return trips
local HUB_MEMORY = 5 * 60 * 60   -- a pad counts as a hub for 5 minutes after it supplies something

-- Timing
local DISPATCH_INTERVAL = 60     -- ticks between dispatch passes
local REBALANCE_INTERVAL = 300   -- ticks between rebalancing passes
local LAUNCH_DELAY = 60          -- one launch per pad per second, so planes don't overlap

-- Flight
local SPEED = 0.4                -- tiles per tick (24 tiles/s)
local CRUISE_ALTITUDE = 4        -- tiles
local CLIMB_DISTANCE = 16        -- tiles to climb to (and descend from) cruise altitude
local MAP_UPDATE_INTERVAL = 10   -- ticks between map dot moves
local SOUND_INTERVAL = 28        -- ticks between flying sound loops (clip is ~0.46 s)
local SOUND_RANGE = 48           -- tiles from a player to hear a drone
local MAX_SOUNDS = 6             -- flying sounds per loop, so a swarm doesn't get deafening

-- Power (electric energy interface power_usage is in joules per tick)
local POWER_IDLE = 500000 / 60       -- 500 kW
local POWER_LAUNCH = 1000000 / 60    -- 1 MW for the second of each launch
local MIN_LAUNCH_ENERGY = 1000000    -- buffer must hold 1 MJ to launch (2 MJ when fully powered)
local POWERED_EMPTY_ONLY = false     -- false: empty drones can leave unpowered pads, so they never get stuck

local POWER = "wp-long-haul-pad-power"
local SIGNALS = "wp-long-haul-pad-signals"
local SIGNAL_AVAILABLE = "wp-long-haul-drones-available"
local SIGNAL_TOTAL = "wp-long-haul-drones-total"
local SIGNAL_INBOUND = "wp-long-haul-drones-inbound"
local SIGNAL_NETWORK = "wp-long-haul-network-drones"
-- The four drone statistics, in panel order, with their default signals.
local STATS = { "available", "at_pad", "inbound", "network" }
local DEFAULT_STAT_SIGNALS = {
  available = { type = "virtual", name = SIGNAL_AVAILABLE },
  at_pad = { type = "virtual", name = SIGNAL_TOTAL },
  inbound = { type = "virtual", name = SIGNAL_INBOUND },
  network = { type = "virtual", name = SIGNAL_NETWORK },
}

local function default_stat_signals()
  local copy = {}
  for stat, signal in pairs(DEFAULT_STAT_SIGNALS) do copy[stat] = { type = signal.type, name = signal.name } end
  return copy
end

local CIRCUIT_IDS = { defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }

local COLOR = {
  delivery = { 1, 0.8, 0.1 },    -- yellow
  rebalance = { 0.8, 0.8, 0.8 }, -- grey
  ["return"] = { 0.8, 0.8, 0.8 },
  reroute = { 1, 0.35, 0.3 },    -- red: its pad disappeared
}

local function is_pad(entity)
  return entity and entity.valid and DIR_BY_PAD[entity.name] ~= nil
end

--[[ storage
  pads[id] = {
    id, entity, direction,
    drones = 0,          -- docked in the drone slots, ready to launch
    fill = false,        -- false = spread loads, true = fill drones
    queue = {},          -- loaded drones waiting their turn on the runway
    inbound = {},        -- ["name/quality"] = count of cargo flying here
    inbound_drones = 0,  -- drones flying here
    last_supply_tick,    -- when it last supplied another pad (hub detection)
  }
  Requests live in the pad's own buffer chest logistic sections.
  by_unit[unit_number] = id   -- ids survive rotating, unit numbers don't
  open[player_index] = id     -- whose pad panel is open
  flights[id] = { ... }       -- drones in the air
  launching[pad_id] = true    -- pads with a non-empty queue
]]

local function ensure_storage()
  storage.pads = storage.pads or {}
  storage.by_unit = storage.by_unit or {}
  storage.open = storage.open or {}
  storage.next_id = storage.next_id or 1
  storage.flights = storage.flights or {}
  storage.next_flight_id = storage.next_flight_id or 1
  storage.launching = storage.launching or {}
  for _, data in pairs(storage.pads) do
    data.drones = data.drones or 0
    data.queue = data.queue or {}
    data.inbound = data.inbound or {}
    data.inbound_drones = data.inbound_drones or 0
    if data.read_stats == nil then data.read_stats = true end
    data.stat_signals = data.stat_signals or default_stat_signals()
  end
end

local function get_pad_data(entity)
  local id = entity and entity.valid and storage.by_unit[entity.unit_number]
  return id and storage.pads[id]
end

local function bind(data, entity)
  data.entity = entity
  data.direction = DIR_BY_PAD[entity.name]
  storage.by_unit[entity.unit_number] = data.id
  script.register_on_object_destroyed(entity)
end

-- Hidden helpers under each pad: the power interface and the signal combinator.
local function ensure_companions(data)
  local pad = data.entity
  if not (data.power and data.power.valid) then
    data.power = pad.surface.create_entity({ name = POWER, position = pad.position, force = pad.force })
    if data.power then
      data.power.destructible = false
      data.power.power_usage = POWER_IDLE
      data.power.electric_buffer_size = 2000000
    end
  end
  if not (data.signals and data.signals.valid) then
    data.signals = pad.surface.create_entity({ name = SIGNALS, position = pad.position, force = pad.force })
    if data.signals then data.signals.destructible = false end
    data.signal_cache = nil
  end
  -- Invisible script wires so the drone signals reach whatever the pad is wired to.
  if data.signals then
    for _, id in pairs(CIRCUIT_IDS) do
      local a = pad.get_wire_connector(id, true)
      local b = data.signals.get_wire_connector(id, true)
      if a and b and not a.is_connected_to(b, defines.wire_origin.script) then
        a.connect_to(b, false, defines.wire_origin.script)
      end
    end
  end
end

local function destroy_companions(data)
  if data.power and data.power.valid then data.power.destroy() end
  if data.signals and data.signals.valid then data.signals.destroy() end
end

local function is_powered(data)
  return not (data.power and data.power.valid) or data.power.energy >= MIN_LAUNCH_ENERGY
end

local function item_key(name, quality)
  return name .. "/" .. (quality or "normal")
end

-- Research tier per force, cached until research changes.
local function force_tier(force)
  storage.force_tier = storage.force_tier or {}
  local tier = storage.force_tier[force.index]
  if tier then return tier end
  tier = 0
  local techs = force.technologies
  if techs["wp-long-haul-cargo-capacity-1"] and techs["wp-long-haul-cargo-capacity-1"].researched then tier = 1 end
  if techs["wp-long-haul-cargo-capacity-2"] and techs["wp-long-haul-cargo-capacity-2"].researched then tier = 2 end
  storage.force_tier[force.index] = tier
  return tier
end

local function reset_tiers() storage.force_tier = {} end
script.on_event(defines.events.on_research_finished, reset_tiers)
script.on_event(defines.events.on_research_reversed, reset_tiers)
script.on_event(defines.events.on_force_reset, reset_tiers)
script.on_event(defines.events.on_technology_effects_reset, reset_tiers)

local function drone_slots(data)
  return TIERS[force_tier(data.entity.force)].slots
end

local function drone_capacity(data)
  return drone_slots(data) * DRONE_STACK
end

local function free_room(data)
  return drone_capacity(data) - data.drones - data.inbound_drones
end

local function distance_sq(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return dx * dx + dy * dy
end

-- Requests ---------------------------------------------------------------------

local function clear_sections(point)
  for i = point.sections_count, 1, -1 do point.remove_section(i) end
end

-- Snapshot a pad's logistic sections, then write them to another pad (rotating).
local function read_sections(entity)
  local point = entity.get_requester_point()
  local snapshot = {}
  if not point then return snapshot end
  for _, section in pairs(point.sections) do
    local entry = { group = section.group, active = section.active, multiplier = section.multiplier, filters = {} }
    if section.group == "" then
      for index, filter in pairs(section.filters) do
        if filter.value then entry.filters[index] = filter end
      end
    end
    snapshot[#snapshot + 1] = entry
  end
  return snapshot
end

local function write_sections(entity, snapshot)
  local point = entity.get_requester_point()
  if not point then return end
  clear_sections(point)
  for _, entry in pairs(snapshot) do
    local copy = point.add_section(entry.group ~= "" and entry.group or nil)
    if copy then
      copy.active = entry.active
      copy.multiplier = entry.multiplier
      for index, filter in pairs(entry.filters) do copy.set_slot(index, filter) end
    end
  end
end

-- Apply blueprint request_filters (saved in tags, since the blueprint holds a
-- placer instead of the buffer chest).
local function apply_blueprint_requests(entity, request_filters)
  local point = entity.get_requester_point()
  if not (point and type(request_filters) == "table" and request_filters.sections) then return end
  clear_sections(point)
  for _, section in pairs(request_filters.sections) do
    local copy = point.add_section(section.group)
    if copy then
      if section.active ~= nil then copy.active = section.active end
      if section.multiplier then copy.multiplier = section.multiplier end
      if not section.group then
        for _, f in pairs(section.filters or {}) do
          copy.set_slot(f.index, {
            value = { type = "item", name = f.name, quality = f.quality or "normal", comparator = f.comparator or "=" },
            min = f.count,
            max = f.max_count,
          })
        end
      end
    end
  end
end

local function register_pad(entity, tags)
  local data = {
    id = storage.next_id,
    drones = 0,
    fill = false,
    queue = {},
    inbound = {},
    inbound_drones = 0,
    read_stats = true,
    stat_signals = default_stat_signals(),
  }
  storage.next_id = storage.next_id + 1
  if tags then
    data.fill = tags.wp_fill == true
    if tags.wp_read_stats ~= nil then data.read_stats = tags.wp_read_stats end
    if type(tags.wp_priority) == "number" then data.priority = tags.wp_priority end
    if type(tags.wp_stat_signals) == "table" then
      data.stat_signals = {}
      for _, stat in pairs(STATS) do data.stat_signals[stat] = tags.wp_stat_signals[stat] end
    end
    if tags.wp_request_filters then apply_blueprint_requests(entity, tags.wp_request_filters) end
  end
  storage.pads[data.id] = data
  bind(data, entity)
  ensure_companions(data)
  return data
end

-- Pick up any pads that exist without data (older test saves, the editor).
local function rescan()
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered({ name = PAD_NAMES })) do
      if not get_pad_data(entity) then register_pad(entity) end
    end
  end
end

script.on_init(ensure_storage)
script.on_configuration_changed(function()
  ensure_storage()
  for id, data in pairs(storage.pads) do
    if not (data.entity and data.entity.valid) then storage.pads[id] = nil end
  end
  rescan()
  for _, data in pairs(storage.pads) do ensure_companions(data) end
  storage.force_tier = {}
end)

-- Building -------------------------------------------------------------------

-- The placer is what players, robots and blueprints build. Swap it for the
-- pad that matches its direction right away.
local function swap_placer(placer, player_index, tags)
  local surface, position = placer.surface, placer.position
  local direction, force, quality = placer.direction, placer.force, placer.quality
  local last_user = placer.last_user
  placer.destroy()

  local pad = surface.create_entity({
    name = PAD_BY_DIR[direction] or PAD_BY_DIR[D.north],
    position = position,
    force = force,
    quality = quality,
    player = player_index or last_user,
    create_build_effect_smoke = false,
  })
  if pad then register_pad(pad, tags) end
end

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name == PLACER then
    swap_placer(entity, event.player_index, event.tags)
  elseif is_pad(entity) and not get_pad_data(entity) then
    register_pad(entity, event.tags)
  end
end

local build_filter = { { filter = "name", name = PLACER } }
for _, name in pairs(PAD_NAMES) do build_filter[#build_filter + 1] = { filter = "name", name = name } end

script.on_event(defines.events.on_built_entity, on_built, build_filter)
script.on_event(defines.events.on_robot_built_entity, on_built, build_filter)
script.on_event(defines.events.on_space_platform_built_entity, on_built, build_filter)
script.on_event(defines.events.script_raised_built, on_built, build_filter)
script.on_event(defines.events.script_raised_revive, on_built, build_filter)

-- Removing -------------------------------------------------------------------

-- Docked drones plus drones still waiting on the runway (with their cargo).
local function pad_contents(data)
  local stacks = {}
  local drones = data.drones + #data.queue
  if drones > 0 then stacks[#stacks + 1] = { name = DRONE, count = drones } end
  for _, job in pairs(data.queue) do
    if job.cargo then stacks[#stacks + 1] = job.cargo end
    local dest = storage.pads[job.dest_id]
    if dest then
      dest.inbound_drones = dest.inbound_drones - 1
      if job.cargo then
        local key = item_key(job.cargo.name, job.cargo.quality)
        dest.inbound[key] = (dest.inbound[key] or 0) - job.cargo.count
      end
    end
  end
  data.drones, data.queue = 0, {}
  storage.launching[data.id] = nil
  return stacks
end

-- Mined pads hand back their drones and any waiting cargo, like a roboport.
local function on_mined(event)
  local data = get_pad_data(event.entity)
  if not (data and event.buffer) then return end
  for _, stack in pairs(pad_contents(data)) do event.buffer.insert(stack) end
end

local pad_filter = {}
for _, name in pairs(PAD_NAMES) do pad_filter[#pad_filter + 1] = { filter = "name", name = name } end
script.on_event(defines.events.on_player_mined_entity, on_mined, pad_filter)
script.on_event(defines.events.on_robot_mined_entity, on_mined, pad_filter)
script.on_event(defines.events.on_space_platform_mined_entity, on_mined, pad_filter)

-- Destroyed pads spill them on the ground.
script.on_event(defines.events.on_entity_died, function(event)
  local data = get_pad_data(event.entity)
  if not data then return end
  for _, stack in pairs(pad_contents(data)) do
    event.entity.surface.spill_item_stack({
      position = event.entity.position,
      stack = stack,
      enable_looted = true,
      force = event.entity.force,
    })
  end
end, pad_filter)

script.on_event(defines.events.on_object_destroyed, function(event)
  local id = storage.by_unit[event.useful_id]
  if not id then return end -- rotating unbinds first, so this only fires for real removals
  storage.by_unit[event.useful_id] = nil
  local data = storage.pads[id]
  if data then destroy_companions(data) end
  storage.pads[id] = nil
  storage.launching[id] = nil
end)

-- Rotating a placed pad -------------------------------------------------------
-- (The build preview rotates on its own, because the placer is rotatable.)

local function next_dir(dir, reverse)
  return (dir + (reverse and 12 or 4)) % 16
end

local function rotate_pad(data, reverse)
  local old = data.entity
  local surface, position, force, quality = old.surface, old.position, old.force, old.quality
  local health, last_user = old.health, old.last_user

  -- Park the contents in a script inventory while the entity is swapped.
  local old_inv = old.get_inventory(defines.inventory.chest)
  local temp = game.create_inventory(#old_inv)
  for i = 1, #old_inv do temp[i].transfer_stack(old_inv[i]) end

  local viewers = {}
  for player_index, id in pairs(storage.open) do
    if id == data.id then viewers[#viewers + 1] = player_index end
  end

  local sections = read_sections(old)

  -- Player-made wires and circuit settings, to put back on the new pad.
  local wires = {}
  for _, id in pairs(CIRCUIT_IDS) do
    local connector = old.get_wire_connector(id, false)
    if connector then
      for _, connection in pairs(connector.connections) do
        if connection.origin == defines.wire_origin.player then
          wires[#wires + 1] = { id = id, target = connection.target }
        end
      end
    end
  end
  local behavior = {}
  local old_cb = old.get_control_behavior()
  if old_cb then
    for _, key in pairs({ "circuit_exclusive_mode_of_operation", "circuit_condition_enabled", "circuit_condition",
                          "connect_to_logistic_network", "logistic_condition" }) do
      local ok, value = pcall(function() return old_cb[key] end)
      if ok and value ~= nil then behavior[key] = value end
    end
  end

  storage.by_unit[old.unit_number] = nil
  old.destroy()

  local pad = surface.create_entity({
    name = PAD_BY_DIR[next_dir(data.direction, reverse)],
    position = position,
    force = force,
    quality = quality,
    player = last_user,
    create_build_effect_smoke = false,
  })
  write_sections(pad, sections)

  local new_inv = pad.get_inventory(defines.inventory.chest)
  for i = 1, #temp do new_inv[i].transfer_stack(temp[i]) end
  temp.destroy()
  pad.health = health
  bind(data, pad)
  ensure_companions(data)

  for _, wire in pairs(wires) do
    if wire.target.valid then
      pad.get_wire_connector(wire.id, true).connect_to(wire.target, false, defines.wire_origin.player)
    end
  end
  if next(behavior) then
    local new_cb = pad.get_or_create_control_behavior()
    for key, value in pairs(behavior) do pcall(function() new_cb[key] = value end) end
  end

  for _, player_index in pairs(viewers) do
    local player = game.get_player(player_index)
    if player then player.opened = pad end
  end
end

local function on_rotate(event, reverse)
  local player = game.get_player(event.player_index)
  if not player then return end
  local cursor = player.cursor_stack
  if cursor and cursor.valid_for_read then return end -- holding something: let the game rotate it

  local data = get_pad_data(player.selected)
  if data and player.selected.force == player.force then rotate_pad(data, reverse) end
end

script.on_event("wp-long-haul-rotate", function(event) on_rotate(event, false) end)
script.on_event("wp-long-haul-reverse-rotate", function(event) on_rotate(event, true) end)

-- Drone slots ----------------------------------------------------------------

-- Drones put into the pad's inventory (by hand or inserter) dock into the
-- drone slots; anything over capacity stays in the inventory.
local function absorb_drones(data)
  local free = drone_capacity(data) - data.drones
  if free <= 0 then return end
  local inv = data.entity.get_inventory(defines.inventory.chest)
  local taken = inv.remove({ name = DRONE, count = free })
  data.drones = data.drones + taken
end

-- Drone requests would refill the slots after every launch and break
-- rebalancing, so they're removed (like roboports, bots never deliver drones).
local function strip_drone_requests(data)
  local point = data.entity.get_requester_point()
  if not point then return end
  local removed = false
  for _, section in pairs(point.sections) do
    if section.group == "" and section.is_manual then
      for index, filter in pairs(section.filters) do
        if filter.value and filter.value.name == DRONE then
          section.clear_slot(index)
          removed = true
        end
      end
    end
  end
  if removed then
    rendering.draw_text({
      text = { "wp-long-haul.no-drone-requests" },
      surface = data.entity.surface,
      target = { entity = data.entity, offset = { 0, -3 } },
      color = { 1, 0.4, 0.3 },
      scale = 1.2,
      alignment = "center",
      time_to_live = 240,
    })
  end
end

-- Flights --------------------------------------------------------------------
-- A flight follows a path of points. With fancy flights on, that's a takeoff
-- roll down the origin runway, a curved turn toward the destination, a
-- straight final approach lined up with the destination runway, and a landing
-- roll. With it off, it's a straight line from pad to pad.

local RUNWAY_BACK = 1.5    -- tiles from pad center to the tower end
local RUNWAY_FRONT = 2.5   -- tiles from pad center to the stripe end
local CLIMB_OUT = 15       -- straight climb-out past the runway before turning, in tiles
local APPROACH = 15        -- straight final approach length, in tiles
local TURN_RADIUS = 20     -- tightest turn a drone makes, in tiles (bigger = lazier arcs)

local function fancy_flights()
  return settings.global["wp-long-haul-fancy-flights"].value
end

local function dir_vector(direction)
  local o = direction / 16 * 2 * math.pi
  return { x = math.sin(o), y = -math.cos(o) }
end

local function offset(p, dir, k)
  return { x = p.x + dir.x * k, y = p.y + dir.y * k }
end

local function heading_frame(from, to)
  -- Factorio orientation: 0 = north, clockwise. 64 frames.
  local orientation = math.atan2(to.x - from.x, from.y - to.y) / (2 * math.pi)
  return math.floor(orientation * 64 + 0.5) % 64
end

local function smoothstep(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

-- Turn-radius paths ("Dubins paths"): arc, straight, arc, where every arc has
-- radius TURN_RADIUS. Picks the shortest of the four left/right combinations.
-- Directions are unit vectors in map coordinates (y points south).
local TAU = 2 * math.pi
local function phi_of(d) return math.atan2(d.x, -d.y) end -- 0 = north, clockwise
local function left_of(d) return { x = d.y, y = -d.x } end
local function right_of(d) return { x = -d.y, y = d.x } end

local function side_normal(d, side) return side == "L" and left_of(d) or right_of(d) end

local function turn_delta(from_phi, to_phi, side)
  if side == "R" then return (to_phi - from_phi) % TAU end
  return (from_phi - to_phi) % TAU
end

local function add_turn_path(points, p0, d0, p1, d1)
  local R = TURN_RADIUS
  local best
  for _, a_side in pairs({ "L", "R" }) do
    for _, b_side in pairs({ "L", "R" }) do
      local c0 = offset(p0, side_normal(d0, a_side), R)
      local c1 = offset(p1, side_normal(d1, b_side), R)
      local wx, wy = c1.x - c0.x, c1.y - c0.y
      local dist = math.sqrt(wx * wx + wy * wy)
      local straight, s
      if a_side == b_side then
        if dist < 1e-6 then s, straight = d0, 0 else s, straight = { x = wx / dist, y = wy / dist }, dist end
      elseif dist >= 2 * R then
        straight = math.sqrt(dist * dist - 4 * R * R)
        local w = { x = wx / dist, y = wy / dist }
        local angle = math.atan2(2 * R, straight) * (a_side == "L" and 1 or -1)
        local n = left_of(w)
        s = { x = w.x * math.cos(angle) + n.x * math.sin(angle), y = w.y * math.cos(angle) + n.y * math.sin(angle) }
      end
      if s then
        local phi0, phis, phi1 = phi_of(d0), phi_of(s), phi_of(d1)
        local turn0, turn1 = turn_delta(phi0, phis, a_side), turn_delta(phis, phi1, b_side)
        local length = R * turn0 + straight + R * turn1
        if not best or length < best.length then
          best = { length = length, a = a_side, b = b_side, c0 = c0, c1 = c1, s = s,
                   phi0 = phi0, phis = phis, turn0 = turn0, turn1 = turn1 }
        end
      end
    end
  end

  -- Points every ~2 tiles around each arc; the straight is just its end point.
  local function arc(center, side, start_phi, delta)
    local steps = math.max(1, math.ceil(R * delta / 2))
    local k = side == "L" and 1 or -1
    for i = 1, steps do
      local phi = start_phi + (side == "R" and 1 or -1) * delta * i / steps
      points[#points + 1] = { x = center.x + k * R * math.cos(phi), y = center.y + k * R * math.sin(phi) }
    end
  end
  arc(best.c0, best.a, best.phi0, best.turn0)
  points[#points + 1] = offset(best.c1, side_normal(best.s, best.b), -R) -- start of the second arc
  arc(best.c1, best.b, best.phis, best.turn1)
end

-- start: where the drone is; start_dir: a direction vector it's facing;
-- on_runway: true when it starts parked on a pad (adds the takeoff roll).
local function build_path(start, start_dir, on_runway, dest_pos, dest_direction)
  local points = {}
  local roll_up, roll_down = 0, 0

  if not fancy_flights() then
    points[1] = { x = start.x, y = start.y }
    points[2] = { x = dest_pos.x, y = dest_pos.y }
  else
    local v = dir_vector(dest_direction)
    local p0
    if on_runway then
      points[1] = offset(start, start_dir, -RUNWAY_BACK) -- tower end
      points[2] = offset(start, start_dir, RUNWAY_FRONT) -- lift off past the stripes
      points[3] = offset(points[2], start_dir, CLIMB_OUT) -- climb straight out
      p0 = points[3]
    else
      points[1] = { x = start.x, y = start.y }
      p0 = points[1]
    end
    -- Land on the stripe end heading toward the tower, so approach from beyond it.
    local touchdown = offset(dest_pos, v, RUNWAY_FRONT)
    local final = offset(touchdown, v, APPROACH)
    add_turn_path(points, p0, start_dir, final, { x = -v.x, y = -v.y })
    points[#points + 1] = touchdown
    points[#points + 1] = offset(dest_pos, v, -RUNWAY_BACK) -- roll to a stop by the tower
  end

  local cumulative = { 0 }
  for i = 2, #points do
    local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
    cumulative[i] = cumulative[i - 1] + math.sqrt(dx * dx + dy * dy)
  end
  local total = cumulative[#points]
  if fancy_flights() then
    if on_runway then roll_up = cumulative[2] end
    roll_down = total - cumulative[#points - 1]
  end
  return points, cumulative, total, roll_up, roll_down
end

-- Speed ramps up on the takeoff roll and down on the approach and landing roll.
local function speed_at(flight, s)
  local up
  if s < flight.roll_up then
    up = 0.05 + 0.2 * (s / flight.roll_up)
  else
    up = math.min(SPEED, 0.25 + (SPEED - 0.25) * (s - flight.roll_up) / 10)
  end
  local r = flight.total - s
  local down
  if r < flight.roll_down then
    down = 0.04 + 0.16 * (r / flight.roll_down)
  else
    down = math.min(SPEED, 0.2 + (SPEED - 0.2) * (r - flight.roll_down) / 12)
  end
  return math.max(0.03, math.min(up, down))
end

local function altitude_at(flight, s)
  local air = flight.total - flight.roll_up - flight.roll_down
  if air <= 0 then return 0 end
  local climb = math.min(CLIMB_DISTANCE, air / 2)
  local up = smoothstep((s - flight.roll_up) / climb)
  local down = smoothstep((flight.total - flight.roll_down - s) / climb)
  return CRUISE_ALTITUDE * up * down
end

local function destroy_renders(flight)
  for _, key in pairs({ "plane", "shadow", "map_dot", "map_line" }) do
    local object = flight[key]
    if object and object.valid then object.destroy() end
  end
end

-- Start a drone flying to a pad. Counts it as inbound there.
local function start_flight(surface, start, start_dir, on_runway, dest, cargo, kind)
  local dest_pos = dest.entity.position
  local points, cumulative, total, roll_up, roll_down =
    build_path(start, start_dir, on_runway, dest_pos, dest.direction)
  local variant = cargo and "loaded" or "unloaded"
  local frame = heading_frame(points[1], points[2])
  local color = COLOR[kind] or COLOR.delivery

  local flight = {
    id = storage.next_flight_id,
    surface = surface,
    points = points,
    cumulative = cumulative,
    total = total,
    roll_up = roll_up,
    roll_down = roll_down,
    s = 0,
    segment = 1,
    to = { x = dest_pos.x, y = dest_pos.y },
    dest_id = dest.id,
    cargo = cargo,
    kind = kind,
  }
  storage.next_flight_id = storage.next_flight_id + 1

  -- Shadow first so the plane always draws on top of it.
  flight.shadow = rendering.draw_animation({
    animation = "wp-long-haul-drone-" .. variant .. "-shadow",
    animation_speed = 0,
    animation_offset = frame,
    target = points[1],
    surface = surface,
    render_layer = "air-object",
  })
  flight.plane = rendering.draw_animation({
    animation = "wp-long-haul-drone-" .. variant,
    animation_speed = 0,
    animation_offset = frame,
    target = points[1],
    surface = surface,
    render_layer = "air-object",
  })
  flight.map_dot = rendering.draw_sprite({
    sprite = "item/" .. DRONE,
    target = points[1],
    surface = surface,
    tint = color,
    x_scale = 3,
    y_scale = 3,
    render_mode = "chart",
  })
  flight.map_line = rendering.draw_line({
    color = { color[1] * 0.4, color[2] * 0.4, color[3] * 0.4, 0.4 },
    width = 2,
    from = points[1],
    to = dest_pos,
    surface = surface,
    render_mode = "chart",
  })

  dest.inbound_drones = dest.inbound_drones + 1
  storage.flights[flight.id] = flight
  return flight
end

-- Where the drone is now and which way it's heading, along its path.
local function path_position(flight)
  local points, cumulative = flight.points, flight.cumulative
  local i = flight.segment
  while i < #points - 1 and cumulative[i + 1] <= flight.s do i = i + 1 end
  flight.segment = i
  local a, b = points[i], points[i + 1]
  local length = cumulative[i + 1] - cumulative[i]
  local t = length > 0 and (flight.s - cumulative[i]) / length or 1
  return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }, a, b
end

-- Nearest pad on a surface with a free drone slot.
local function nearest_with_room(surface, position, except_id)
  local best, best_dist
  for _, data in pairs(storage.pads) do
    if data.id ~= except_id and data.entity.valid and data.entity.surface == surface and free_room(data) > 0 then
      local dist = distance_sq(position, data.entity.position)
      if not best or dist < best_dist then best, best_dist = data, dist end
    end
  end
  return best
end

local function spill(surface, position, stack)
  surface.spill_item_stack({ position = position, stack = stack, enable_looted = true })
end

-- The destination vanished: fly on (from wherever the drone is) to the nearest
-- pad with room, cargo and all. Nothing anywhere? Drop everything.
local function reroute(flight, position, heading)
  local fallback = nearest_with_room(flight.surface, position)
  if fallback then
    if flight.cargo then
      local key = item_key(flight.cargo.name, flight.cargo.quality)
      fallback.inbound[key] = (fallback.inbound[key] or 0) + flight.cargo.count
    end
    start_flight(flight.surface, position, heading, false, fallback, flight.cargo, "reroute")
  else
    if flight.cargo then spill(flight.surface, position, flight.cargo) end
    spill(flight.surface, position, { name = DRONE, count = 1 })
  end
end

local function land(flight)
  destroy_renders(flight)
  local dest = storage.pads[flight.dest_id]

  if not (dest and dest.entity.valid) then
    local n = #flight.points
    local a, b = flight.points[n - 1], flight.points[n]
    local length = math.max(0.001, math.sqrt(distance_sq(a, b)))
    reroute(flight, b, { x = (b.x - a.x) / length, y = (b.y - a.y) / length })
    return
  end

  dest.inbound_drones = dest.inbound_drones - 1

  if flight.cargo then
    local cargo = flight.cargo
    local key = item_key(cargo.name, cargo.quality)
    dest.inbound[key] = math.max(0, (dest.inbound[key] or 0) - cargo.count)
    local inserted = dest.entity.get_inventory(defines.inventory.chest).insert(cargo)
    if inserted < cargo.count then
      spill(flight.surface, flight.to, { name = cargo.name, quality = cargo.quality, count = cargo.count - inserted })
    end
  end

  -- Dock if there's a free slot, otherwise take off again, empty.
  if dest.drones < drone_capacity(dest) then
    dest.drones = dest.drones + 1
  else
    local home = nearest_with_room(flight.surface, flight.to, dest.id)
    if home then
      start_flight(flight.surface, dest.entity.position, dir_vector(dest.direction), true, home, nil, "return")
    else
      dest.entity.get_inventory(defines.inventory.chest).insert({ name = DRONE, count = 1 })
    end
  end
end

local function update_flights(tick)
  local landed, rerouted = {}, {}
  local move_map = tick % MAP_UPDATE_INTERVAL == 0

  for id, flight in pairs(storage.flights) do
    if not flight.surface.valid then
      -- Its surface was deleted (Space Exploration and others do this); drop it.
      destroy_renders(flight)
      storage.flights[id] = nil
      goto continue
    end
    if not flight.points then
      -- A straight 0.4.0 flight: give it a two-point path from where it started.
      local from = flight.from or flight.to
      flight.points = { from, flight.to }
      flight.cumulative = { 0, math.sqrt(distance_sq(from, flight.to)) }
      flight.total = math.max(0.001, flight.cumulative[2])
      flight.roll_up, flight.roll_down, flight.segment = 0, 0, 1
      flight.s = flight.duration and math.min(1, (tick - flight.start) / flight.duration) * flight.total or 0
    end
    flight.s = flight.s + speed_at(flight, flight.s)
    if flight.s >= flight.total then
      landed[#landed + 1] = flight
      storage.flights[id] = nil
    else
      local before = flight.segment
      local pos, a, b = path_position(flight)
      local alt = altitude_at(flight, flight.s)
      if flight.plane.valid then
        flight.plane.target = { pos.x, pos.y - alt }
        if flight.segment ~= before then
          local frame = heading_frame(a, b)
          flight.plane.animation_offset = frame
          if flight.shadow.valid then flight.shadow.animation_offset = frame end
        end
      end
      if flight.shadow.valid then flight.shadow.target = { pos.x + alt * 0.5, pos.y } end
      if move_map then
        if flight.map_dot.valid then flight.map_dot.target = pos end
        -- Check now and then that the destination still exists.
        local dest = storage.pads[flight.dest_id]
        if not (dest and dest.entity.valid) then
          local length = math.max(0.001, math.sqrt(distance_sq(a, b)))
          rerouted[#rerouted + 1] = { flight, pos, { x = (b.x - a.x) / length, y = (b.y - a.y) / length } }
          storage.flights[id] = nil
        end
      end
    end
    ::continue::
  end

  -- Landing and rerouting start new flights, so do them after walking the table.
  for _, flight in pairs(landed) do land(flight) end
  for _, r in pairs(rerouted) do
    destroy_renders(r[1])
    reroute(r[1], r[2], r[3])
  end
end

-- Loop the short flying sound for drones near players, a few at a time.
local function play_flying_sounds()
  local played = 0
  for _, player in pairs(game.connected_players) do
    for _, flight in pairs(storage.flights) do
      if played >= MAX_SOUNDS then return end
      if flight.surface.valid and flight.surface == player.surface and flight.plane.valid then
        local pos = flight.plane.target.position
        if pos and distance_sq(pos, player.position) < SOUND_RANGE * SOUND_RANGE then
          flight.surface.play_sound({ path = "wp-long-haul-drone-flying", position = pos })
          played = played + 1
        end
      end
    end
  end
end

-- Launch queue ---------------------------------------------------------------

local function queue_job(data, job)
  table.insert(data.queue, job)
  storage.launching[data.id] = true
end

local function launch_next(data)
  local job = table.remove(data.queue, 1)
  if not job then return end
  local dest = storage.pads[job.dest_id]
  local pad = data.entity

  if not (dest and dest.entity.valid) then
    -- Destination vanished before takeoff: unload and re-dock.
    data.drones = data.drones + 1
    if job.cargo then pad.get_inventory(defines.inventory.chest).insert(job.cargo) end
    return
  end

  -- start_flight counts the drone as inbound; it was pre-counted when queued.
  dest.inbound_drones = dest.inbound_drones - 1
  start_flight(pad.surface, pad.position, dir_vector(data.direction), true, dest, job.cargo, job.kind)
  pad.surface.play_sound({ path = "wp-long-haul-drone-launch", position = pad.position })
end

local function process_launches(tick)
  for id in pairs(storage.launching) do
    local data = storage.pads[id]
    if not (data and data.entity.valid) then
      storage.launching[id] = nil
    elseif tick >= (data.next_launch_tick or 0) then
      local job = data.queue[1]
      local needs_power = job and (job.cargo or POWERED_EMPTY_ONLY)
      if not needs_power or is_powered(data) then
        launch_next(data)
        data.next_launch_tick = tick + LAUNCH_DELAY
        -- Draw 1 MW for the second this launch takes.
        if data.power and data.power.valid then
          data.power.power_usage = POWER_LAUNCH
          data.spike_until = tick + LAUNCH_DELAY
        end
      end
      if #data.queue == 0 then storage.launching[id] = nil end
    end
  end
end

-- Dispatcher -----------------------------------------------------------------

local function items_per_drone(name, force)
  local payload = TIERS[force_tier(force)].payload
  local weight = prototypes.item[name].weight
  if not weight or weight <= 0 then return prototypes.item[name].stack_size end
  return math.max(1, math.floor(payload / weight))
end

local function local_count(pad, item)
  local network = pad.logistic_network
  if not network then return 0 end
  local in_network = network.get_item_count(item)
  local in_pad = pad.get_inventory(defines.inventory.chest).get_item_count(item)
  return math.max(0, in_network - in_pad)
end

-- A pad can supply an item if it holds it and either doesn't request it or its
-- own network can top it back up. That stops two outposts ping-ponging stock.
local function can_supply(pad, item, requested_here)
  local have = pad.get_inventory(defines.inventory.chest).get_item_count(item)
  if have <= 0 then return 0 end
  if requested_here and local_count(pad, item) <= 0 then return 0 end
  return have
end

local function requested_items(pad)
  local point = pad.get_requester_point()
  local result = {}
  if not point then return result end
  for _, f in pairs(point.filters or {}) do
    if f.name and f.name ~= DRONE and (f.count or 0) > 0 then
      result[#result + 1] = { name = f.name, quality = f.quality or "normal", count = f.count }
    end
  end
  return result
end

local function request_lookup(pad)
  local lookup = {}
  for _, r in pairs(requested_items(pad)) do lookup[item_key(r.name, r.quality)] = true end
  return lookup
end

-- Dispatching happens in two steps so every pad gets served:
--   1. collect every unmet request from every pad ("needs"),
--   2. hand out drones one at a time, round-robin across the needs, highest
--      priority first. The starting point rotates each pass so no pad always
--      goes first.

local DEFAULT_PRIORITY = 50
local MAX_PRIORITY = 255

local function pad_priority(data)
  return data.priority or DEFAULT_PRIORITY
end

-- What a pad still needs flown in for one request (0 if nothing).
local function remote_shortfall(data, request)
  local pad = data.entity
  local item = { name = request.name, quality = request.quality }
  local key = item_key(request.name, request.quality)
  local have = pad.get_inventory(defines.inventory.chest).get_item_count(item)
  -- Missing, counting cargo already in the air...
  local shortfall = request.count - have - (data.inbound[key] or 0)
  if shortfall <= 0 then return 0 end
  -- ...minus what local bots can bring from the pad's own network.
  return math.max(0, shortfall - local_count(pad, item))
end

-- Nearest other pad, on another network, with a docked drone and stock to spare.
local function find_supplier(need, candidates)
  local requester = need.data.entity
  local best, best_dist, best_have
  for _, other in pairs(candidates) do
    local pad = other.entity
    if other ~= need.data and other.drones > 0
      and (pad.logistic_network == nil or pad.logistic_network ~= requester.logistic_network) then
      other.lookup = other.lookup or request_lookup(pad)
      local have = can_supply(pad, need.item, other.lookup[need.key])
      if have > 0 then
        local dist = distance_sq(pad.position, requester.position)
        if not best or dist < best_dist then best, best_dist, best_have = other, dist, have end
      end
    end
  end
  return best, best_have
end

-- Load one drone for a need. Returns true if a drone was sent.
local function send_one_drone(need, candidates)
  local supplier, have = find_supplier(need, candidates)
  if not supplier then return false end

  local per_drone = items_per_drone(need.item.name, supplier.entity.force)
  if not need.load then
    if supplier.fill then
      need.load = per_drone
    else
      -- Spread: split across the supplier's idle drones, but keep loads decent (10%+).
      local min_load = math.max(1, math.floor(per_drone * 0.1))
      need.load = math.min(per_drone, math.max(min_load, math.ceil(need.shortfall / supplier.drones)))
    end
  end

  local count = math.min(need.load, per_drone, need.shortfall, have)
  local removed = supplier.entity.get_inventory(defines.inventory.chest).remove({
    name = need.item.name, quality = need.item.quality, count = count,
  })
  if removed <= 0 then return false end

  queue_job(supplier, {
    dest_id = need.data.id,
    cargo = { name = need.item.name, quality = need.item.quality, count = removed },
    kind = "delivery",
  })
  supplier.drones = supplier.drones - 1
  supplier.last_supply_tick = game.tick
  need.data.inbound[need.key] = (need.data.inbound[need.key] or 0) + removed
  need.data.inbound_drones = need.data.inbound_drones + 1
  need.shortfall = need.shortfall - removed
  return true
end

local function dispatch_all()
  storage.dispatch_round = (storage.dispatch_round or 0) + 1

  -- Pads per surface (suppliers can only fly within a surface), and all needs.
  local by_surface, needs_by_surface = {}, {}
  for _, data in pairs(storage.pads) do
    if data.entity.valid then
      data.lookup = nil
      local index = data.entity.surface.index
      by_surface[index] = by_surface[index] or {}
      table.insert(by_surface[index], data)
      for _, request in pairs(requested_items(data.entity)) do
        local shortfall = remote_shortfall(data, request)
        if shortfall > 0 then
          needs_by_surface[index] = needs_by_surface[index] or {}
          table.insert(needs_by_surface[index], {
            data = data,
            item = { name = request.name, quality = request.quality },
            key = item_key(request.name, request.quality),
            shortfall = shortfall,
          })
        end
      end
    end
  end

  for index, needs in pairs(needs_by_surface) do
    local candidates = by_surface[index]

    -- Highest priority first; within a priority, a fixed order to rotate.
    table.sort(needs, function(a, b)
      local pa, pb = pad_priority(a.data), pad_priority(b.data)
      if pa ~= pb then return pa > pb end
      if a.data.id ~= b.data.id then return a.data.id < b.data.id end
      return a.key < b.key
    end)

    -- Walk each priority level, one drone per need per round, until stuck.
    local i = 1
    while i <= #needs do
      local level = pad_priority(needs[i].data)
      local group = {}
      while i <= #needs and pad_priority(needs[i].data) == level do
        group[#group + 1] = needs[i]
        i = i + 1
      end

      local offset = storage.dispatch_round % #group
      local progress = true
      while progress do
        progress = false
        for n = 1, #group do
          local need = group[(n + offset - 1) % #group + 1]
          if need.shortfall > 0 and not need.stuck then
            if send_one_drone(need, candidates) then
              progress = true
            else
              need.stuck = true
            end
          end
        end
      end
    end
  end
end

-- Rebalancing ------------------------------------------------------------------
-- Deliveries leave drones at the receiving pad. Hubs (pads that supplied
-- something recently) keep every drone; other pads keep a small reserve for
-- return trips and send the rest, empty, to the nearest hub with free slots.

local function is_hub(data)
  return data.last_supply_tick ~= nil and game.tick - data.last_supply_tick < HUB_MEMORY
end

local function rebalance_all()
  local hubs_by_surface = {}
  for _, data in pairs(storage.pads) do
    if data.entity.valid and is_hub(data) then
      local index = data.entity.surface.index
      hubs_by_surface[index] = hubs_by_surface[index] or {}
      table.insert(hubs_by_surface[index], data)
    end
  end

  for _, data in pairs(storage.pads) do
    if data.entity.valid and not is_hub(data) and data.drones > RESERVE_DRONES then
      local hubs = hubs_by_surface[data.entity.surface.index] or {}
      local excess = data.drones - RESERVE_DRONES
      local here = data.entity.position

      -- Fill the nearest hub first, then the next nearest, until all are home.
      table.sort(hubs, function(a, b)
        return distance_sq(a.entity.position, here) < distance_sq(b.entity.position, here)
      end)
      for _, hub in pairs(hubs) do
        if excess <= 0 then break end
        local moved = math.min(excess, free_room(hub))
        for _ = 1, moved do
          queue_job(data, { dest_id = hub.id, kind = "rebalance" })
        end
        if moved > 0 then
          data.drones = data.drones - moved
          hub.inbound_drones = hub.inbound_drones + moved
          excess = excess - moved
        end
      end
    end
  end
end

-- GUI ------------------------------------------------------------------------

local function refresh_gui(player)
  local frame = player.gui.relative[GUI]
  local data = storage.pads[storage.open[player.index] or 0]
  if not (frame and data) then return end

  frame.drone_label.caption = { "wp-long-haul.drones-count", data.drones, drone_capacity(data) }
  frame.traffic_label.caption = { "wp-long-haul.traffic", #data.queue, data.inbound_drones }
  frame.power_label.caption = is_powered(data) and { "wp-long-haul.power-ok" } or { "wp-long-haul.power-low" }
  frame.role_label.caption = is_hub(data) and { "wp-long-haul.role-hub" } or { "wp-long-haul.role-outpost", RESERVE_DRONES }
  local slots = frame.drone_slots
  local left = data.drones
  local unlocked = drone_slots(data)
  for i = 1, MAX_SLOTS do
    local button = slots["wp_drone_slot_" .. i]
    if button then
      button.visible = i <= unlocked
      local count = math.min(left, DRONE_STACK)
      left = left - count
      button.sprite = count > 0 and ("item/" .. DRONE) or ""
      button.number = count > 0 and count or nil
    end
  end
end

local function destroy_gui(player)
  local frame = player.gui.relative[GUI]
  if frame then frame.destroy() end
  storage.open[player.index] = nil
end

local function build_gui(player, data)
  destroy_gui(player)
  local frame = player.gui.relative.add({
    type = "frame",
    name = GUI,
    caption = { "wp-long-haul.panel-title" },
    direction = "vertical",
    anchor = {
      gui = defines.relative_gui_type.logistic_container_gui or defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right,
    },
  })

  frame.add({ type = "label", name = "drone_label", style = "caption_label" })
  frame.add({ type = "label", name = "traffic_label" })
  frame.add({ type = "label", name = "power_label" })
  local role = frame.add({ type = "label", name = "role_label", tooltip = { "wp-long-haul.role-tooltip" } })
  role.style.single_line = false
  role.style.maximal_width = 220
  local slots = frame.add({ type = "flow", name = "drone_slots", direction = "horizontal" })
  for i = 1, MAX_SLOTS do
    slots.add({
      type = "sprite-button",
      name = "wp_drone_slot_" .. i,
      style = "slot_button",
      tooltip = { "wp-long-haul.drone-slot-tooltip" },
      tags = { wp_drone_slot = i },
    })
  end

  local priority_row = frame.add({ type = "flow", direction = "horizontal" })
  priority_row.style.vertical_align = "center"
  priority_row.add({ type = "label", caption = { "wp-long-haul.priority" }, tooltip = { "wp-long-haul.priority-tooltip" } })
  local priority = priority_row.add({
    type = "textfield",
    name = "wp_priority",
    text = tostring(pad_priority(data)),
    numeric = true,
    allow_decimal = false,
    allow_negative = false,
    tooltip = { "wp-long-haul.priority-tooltip" },
  })
  priority.style.width = 60

  frame.add({ type = "line" })
  frame.add({
    type = "switch",
    name = "wp_fill_switch",
    switch_state = data.fill and "right" or "left",
    left_label_caption = { "wp-long-haul.spread" },
    left_label_tooltip = { "wp-long-haul.spread-tooltip" },
    right_label_caption = { "wp-long-haul.fill" },
    right_label_tooltip = { "wp-long-haul.fill-tooltip" },
  })
  frame.add({ type = "line" })
  frame.add({
    type = "checkbox",
    name = "wp_read_stats",
    caption = { "wp-long-haul.read-stats" },
    state = data.read_stats,
  }).style.font = "default-bold"
  local stats = frame.add({ type = "table", name = "wp_stats", column_count = 2 })
  stats.style.horizontal_spacing = 12
  for _, stat in pairs(STATS) do
    local label = stats.add({ type = "label", caption = { "wp-long-haul.stat-" .. stat } })
    label.style.width = 170
    local signal = data.stat_signals[stat]
    stats.add({
      type = "choose-elem-button",
      elem_type = "signal",
      signal = signal and signal.name and { type = signal.type, name = signal.name } or nil,
      tags = { wp_stat = stat },
      enabled = data.read_stats,
    })
  end

  frame.add({ type = "line" })
  local hint = frame.add({ type = "label", caption = { "wp-long-haul.requests-hint" } })
  hint.style.single_line = false
  hint.style.maximal_width = 220

  storage.open[player.index] = data.id
  refresh_gui(player)
end

script.on_event(defines.events.on_gui_opened, function(event)
  local player = game.get_player(event.player_index)
  local data = get_pad_data(event.entity)
  if player and data then
    absorb_drones(data)
    build_gui(player, data)
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if player and storage.open[player.index] then destroy_gui(player) end
end)

local function open_data(event)
  return storage.pads[storage.open[event.player_index] or 0]
end

script.on_event(defines.events.on_gui_text_changed, function(event)
  if event.element.name ~= "wp_priority" then return end
  local data = open_data(event)
  if not data then return end
  local value = tonumber(event.element.text)
  if value then data.priority = math.max(0, math.min(MAX_PRIORITY, math.floor(value))) end
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  if event.element.name ~= "wp_read_stats" then return end
  local data = open_data(event)
  if not data then return end
  data.read_stats = event.element.state
  data.signal_cache = nil
  local stats = event.element.parent.wp_stats
  if stats then
    for _, child in pairs(stats.children) do
      if child.type == "choose-elem-button" then child.enabled = data.read_stats end
    end
  end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
  local stat = event.element.tags.wp_stat
  local data = stat and open_data(event)
  if not data then return end
  local value = event.element.elem_value
  data.stat_signals[stat] = value and { type = value.type or "item", name = value.name } or nil
  data.signal_cache = nil
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
  if event.element.name ~= "wp_fill_switch" then return end
  local data = open_data(event)
  if data then data.fill = event.element.switch_state == "right" end
end)

-- Click a drone slot to take those drones out, like a roboport slot.
script.on_event(defines.events.on_gui_click, function(event)
  local slot = event.element.tags.wp_drone_slot
  local data = slot and open_data(event)
  if not (data and data.drones > 0) then return end
  local player = game.get_player(event.player_index)
  local count = math.min(data.drones, DRONE_STACK)
  local inserted = player.insert({ name = DRONE, count = count })
  data.drones = data.drones - inserted
  refresh_gui(player)
end)

-- Requests copy natively between buffer chests; carry the switch along too.
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  local source, destination = get_pad_data(event.source), get_pad_data(event.destination)
  if source and destination then
    destination.fill = source.fill
    destination.priority = source.priority
    destination.read_stats = source.read_stats
    destination.stat_signals = {}
    for _, stat in pairs(STATS) do
      local signal = source.stat_signals[stat]
      destination.stat_signals[stat] = signal and { type = signal.type, name = signal.name } or nil
    end
    destination.signal_cache = nil
  end
end)

-- Ticking --------------------------------------------------------------------

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  if next(storage.launching) then process_launches(tick) end
  if next(storage.flights) then
    update_flights(tick)
    if tick % SOUND_INTERVAL == 0 then play_flying_sounds() end
  end
end)

-- Write the drone counts to a pad's signal combinator (only when they change).
local function update_signals(data, network_total)
  local signals = data.signals
  if not (signals and signals.valid) then return end
  local values = {
    available = data.drones,
    at_pad = data.drones + #data.queue,
    inbound = data.inbound_drones,
    network = network_total,
  }

  -- Add up per signal (two stats can share one signal, like the roboport).
  local sums, order = {}, {}
  if data.read_stats then
    for _, stat in pairs(STATS) do
      local signal = data.stat_signals[stat]
      if signal and signal.name then
        local key = (signal.type or "item") .. "/" .. signal.name
        if not sums[key] then
          sums[key] = { signal = signal, count = 0 }
          order[#order + 1] = key
        end
        sums[key].count = sums[key].count + values[stat]
      end
    end
  end

  local fingerprint = {}
  for _, key in pairs(order) do fingerprint[#fingerprint + 1] = key .. "=" .. sums[key].count end
  fingerprint = table.concat(fingerprint, ";")
  if data.signal_cache == fingerprint then return end
  data.signal_cache = fingerprint

  local cb = signals.get_or_create_control_behavior()
  local section = cb.sections_count > 0 and cb.get_section(1) or cb.add_section()
  local filters = {}
  for i, key in pairs(order) do
    local signal = sums[key].signal
    filters[i] = {
      value = { type = signal.type or "item", name = signal.name, quality = "normal" },
      min = sums[key].count,
    }
  end
  section.filters = filters
end

script.on_nth_tick(30, function(event)
  -- Network totals per surface: docked + waiting on runways + in the air.
  local totals = {}
  for _, data in pairs(storage.pads) do
    if data.entity.valid then
      local index = data.entity.surface.index
      totals[index] = (totals[index] or 0) + data.drones + #data.queue
    end
  end
  for _, flight in pairs(storage.flights) do
    if flight.surface.valid then
      totals[flight.surface.index] = (totals[flight.surface.index] or 0) + 1
    end
  end

  for _, data in pairs(storage.pads) do
    if data.entity.valid then
      strip_drone_requests(data)
      absorb_drones(data)
      if data.spike_until and event.tick >= data.spike_until then
        if data.power and data.power.valid then data.power.power_usage = POWER_IDLE end
        data.spike_until = nil
      end
      update_signals(data, totals[data.entity.surface.index] or 0)
    end
  end
  for player_index in pairs(storage.open) do
    local player = game.get_player(player_index)
    if player then refresh_gui(player) end
  end
end)

script.on_nth_tick(DISPATCH_INTERVAL, dispatch_all)
script.on_nth_tick(REBALANCE_INTERVAL, rebalance_all)

-- Blueprints -----------------------------------------------------------------
-- Save pads as placers with their direction, so ghosts are visible and
-- blueprint rotation turns the pads. Requests ride along in tags.

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local bp = event.stack
  if not (bp and bp.valid_for_read and bp.is_blueprint) then
    bp = player.blueprint_to_setup
    if not (bp and bp.valid_for_read) then bp = player.cursor_stack end
  end
  if not (bp and bp.valid_for_read and bp.is_blueprint) then return end

  local entities = bp.get_blueprint_entities()
  if not entities then return end
  local mapping = event.mapping.get()
  local changed = false

  for _, bp_entity in pairs(entities) do
    if DIR_BY_PAD[bp_entity.name] then
      local data = get_pad_data(mapping[bp_entity.entity_number])
      local tags = bp_entity.tags or {}
      tags.wp_fill = data and data.fill or false
      if data then
        tags.wp_read_stats = data.read_stats
        tags.wp_priority = data.priority
        tags.wp_stat_signals = data.stat_signals
      end
      if bp_entity.request_filters then tags.wp_request_filters = bp_entity.request_filters end
      bp_entity.direction = DIR_BY_PAD[bp_entity.name]
      bp_entity.name = PLACER
      bp_entity.request_filters = nil
      bp_entity.bar = nil
      bp_entity.tags = tags
      changed = true
    end
  end

  if changed then bp.set_blueprint_entities(entities) end
end)
