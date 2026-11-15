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

-- Flight (speeds, turn radius, banking and so on are WePlay Flight Library defaults)
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
  storage.show_routes = nil
  for _, flight in pairs(storage.flights) do
    -- Route lines were removed in 1.0.1.
    if flight.map_line and flight.map_line.valid then flight.map_line.destroy() end
    flight.map_line = nil
  end
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

-- Optional limit on pads per force (map setting, 0 = no limit), for performance.
local function pad_count(force)
  local n = 0
  for _, data in pairs(storage.pads) do
    if data.entity.valid and data.entity.force == force then n = n + 1 end
  end
  return n
end

-- Over the limit: remove the new pad and hand the item back (to the player, or
-- on the ground marked for pickup when a robot built it).
local function refuse_pad(placer, event, limit)
  local surface, position, force = placer.surface, placer.position, placer.force
  local item = { name = "wp-long-haul-pad", count = 1, quality = placer.quality.name }
  placer.destroy()
  local player = event.player_index and game.get_player(event.player_index)
  local message = { "wp-long-haul.pad-limit", limit }
  if player and player.insert(item) > 0 then
    player.create_local_flying_text({ text = message, position = position })
    return
  end
  local spilled = surface.spill_item_stack({ position = position, stack = item, enable_looted = true, force = force })
  for _, e in pairs(spilled or {}) do
    if e.valid then e.order_deconstruction(force) end
  end
  rendering.draw_text({
    text = message, surface = surface, target = position, color = { 1, 0.4, 0.3 },
    scale = 1.2, alignment = "center", time_to_live = 300, forces = { force },
  })
end

local LIMITED_BUILDS = {
  [defines.events.on_built_entity] = true,
  [defines.events.on_robot_built_entity] = true,
  [defines.events.on_space_platform_built_entity] = true,
}

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  if entity.name == PLACER then
    local limit = settings.global["wp-long-haul-max-pads"].value
    if limit > 0 and LIMITED_BUILDS[event.name] and pad_count(entity.force) >= limit then
      refuse_pad(entity, event, limit)
      return
    end
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
-- Flying is done by WePlay Flight Library. Each drone in the air is one flight
-- table in storage.flights: the library's fields (mode, pos, heading, bank,
-- render objects...) plus Long Haul's own: id, dest_id, cargo, kind, to, and
-- the alt-mode cargo icon.

local Flight = require("__WePlayFlightLib__/flight")

local RENDER_RANGE = 160    -- tiles: drones further than this from every player aren't redrawn
local CULL_INTERVAL = 15    -- ticks between "is anyone close enough to see it?" checks per drone
local DEST_CHECK = 10       -- ticks between checks that a drone's destination pad still exists
local DRONE_ANIM = "wp-long-haul-drone-" -- + "loaded" / "unloaded" (+ "-shadow")

-- Settings and sprite info, read once and refreshed when settings change.
local cfg
local function get_cfg()
  if cfg then return cfg end
  local g = settings.global
  cfg = {
    fancy = g["wp-long-haul-fancy-flights"].value,
    map_dots = g["wp-long-haul-show-map-drones"].value,
    banking = g["wp-long-haul-banking"].value,
    max_pads = g["wp-long-haul-max-pads"].value,
    traffic = g["wp-long-haul-traffic-pattern"].value,
  }
  -- Rendered bank frames, if the sheets are in the mod: one animation per bank,
  -- "wp-long-haul-drone-loaded-0" (hard left) ... "-4" (hard right).
  local info = prototypes.mod_data["wp-long-haul"]
  cfg.banks = info and info.data.banks or 1
  -- pack_drone_sprites.py names bank animations "<name>-hull-<n>" / "<name>-shadow-<n>".
  cfg.body_suffix = cfg.banks > 1 and "-hull" or ""
  return cfg
end

local function flight_options(surface, position, direction, cargo, kind)
  local c = get_cfg()
  local name = DRONE_ANIM .. (cargo and "loaded" or "unloaded")
  return {
    surface = surface,
    position = position,
    direction = direction,
    sprites = { body = name .. c.body_suffix, shadow = name .. "-shadow" },
    map = { sprite = "item/" .. DRONE, tint = COLOR[kind] or COLOR.delivery, scale = 3, visible = c.map_dots },
    banks = c.banks,
    split_banks = c.banks > 1,
    banking_off = not c.banking,
  }
end

-- Alt-mode icon of the cargo, riding along above the drone.
local ICON_BACKGROUND = "utility/entity_info_dark_background"
local function add_cargo_icon(f)
  local cargo = f.cargo
  if not cargo then return end
  local target = Flight.air(f)
  if helpers.is_valid_sprite_path(ICON_BACKGROUND) then
    f.r_icon_bg = rendering.draw_sprite({
      sprite = ICON_BACKGROUND, target = target, surface = f.surface,
      x_scale = 0.5, y_scale = 0.5, only_in_alt_mode = true, render_layer = "air-entity-info-icon",
    })
  end
  f.r_icon = rendering.draw_sprite({
    sprite = "item/" .. cargo.name, target = target, surface = f.surface,
    x_scale = 0.45, y_scale = 0.45, only_in_alt_mode = true, render_layer = "air-entity-info-icon",
  })
  if cargo.quality and cargo.quality ~= "normal" and helpers.is_valid_sprite_path("quality/" .. cargo.quality) then
    f.r_icon_quality = rendering.draw_sprite({
      sprite = "quality/" .. cargo.quality, target = target, surface = f.surface,
      x_scale = 0.2, y_scale = 0.2, only_in_alt_mode = true, render_layer = "air-entity-info-icon",
    })
  end
end

local ICON_KEYS = { "r_icon_bg", "r_icon", "r_icon_quality" }

local function move_cargo_icon(f)
  if not f.r_icon then return end
  local air = Flight.air(f)
  for _, key in pairs(ICON_KEYS) do
    local r = f[key]
    if r and r.valid then
      if key == "r_icon_quality" then r.target = { x = air.x - 0.22, y = air.y + 0.22 } else r.target = air end
    end
  end
end

-- Drones far from every player are hidden and not redrawn: the library skips
-- render objects that aren't on the flight table, so park them in f.held.
local DRAWN_KEYS = { "r_body", "r_shadow", "r_glow" }

local function set_drawn(f, drawn)
  if (not f.hidden) == drawn then return end
  if drawn then
    for key, r in pairs(f.held or {}) do
      f[key] = r
      if r.valid then
        r.visible = true
        if f.split_banks and f.anim[key] then r.animation = f.anim[key] .. "-" .. f.bank_index end
      end
    end
    f.held, f.hidden = nil, nil
    f.frame = -1 -- refresh the heading frame on the next redraw
  else
    f.held = {}
    for _, key in pairs(DRAWN_KEYS) do
      local r = f[key]
      if r then
        f.held[key] = r
        if r.valid then r.visible = false end
        f[key] = nil
      end
    end
    f.hidden = true
  end
  for _, key in pairs(ICON_KEYS) do
    local r = f[key]
    if r and r.valid then r.visible = drawn end
  end
  if drawn then move_cargo_icon(f) end
end

local function destroy_flight(f)
  if f.held then
    for key, r in pairs(f.held) do f[key] = r end
    f.held = nil
  end
  Flight.destroy(f)
  for _, key in pairs(ICON_KEYS) do
    local r = f[key]
    if r and r.valid then r.destroy() end
    f[key] = nil
  end
end

-- Track a new flight heading for `dest`. Counts it as inbound there.
local function register_flight(f, dest, cargo, kind)
  f.id = storage.next_flight_id
  storage.next_flight_id = storage.next_flight_id + 1
  f.dest_id = dest.id
  f.cargo = cargo
  f.kind = kind
  local to = dest.entity.position
  f.to = { x = to.x, y = to.y }
  dest.inbound_drones = dest.inbound_drones + 1
  add_cargo_icon(f)
  storage.flights[f.id] = f
  return f
end

-- Traffic pattern: departures and arrivals both turn right, which puts them on
-- opposite circles around every pad (departures climb out and turn off to one
-- side, arrivals swing in from the other), so the two streams don't overlap.
local TRAFFIC_TURN = "R"

-- Take off from a pad's runway and fly to land on another pad.
local function launch_flight(origin, dest, cargo, kind)
  local c = get_cfg()
  local pad = origin.entity
  local f = Flight.new(flight_options(pad.surface, pad.position, origin.direction, cargo, kind))
  Flight.fly_to_pad(f, dest.entity.position, Flight.dir_vector(dest.direction), {
    from_pad = pad.position,
    from_dir = Flight.dir_vector(origin.direction),
    straight = not c.fancy,
    first_turn = c.traffic and TRAFFIC_TURN or nil,
    last_turn = c.traffic and TRAFFIC_TURN or nil,
  })
  return register_flight(f, dest, cargo, kind)
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

-- The destination vanished: turn (in the air) toward the nearest pad with room,
-- cargo and all. Nothing anywhere? Drop everything where the drone is.
local function reroute(f)
  local pos = Flight.ground(f)
  local fallback = nearest_with_room(f.surface, pos)
  if not fallback then
    if f.cargo then spill(f.surface, pos, f.cargo) end
    spill(f.surface, pos, { name = DRONE, count = 1 })
    destroy_flight(f)
    storage.flights[f.id] = nil
    return
  end
  if f.cargo then
    local key = item_key(f.cargo.name, f.cargo.quality)
    fallback.inbound[key] = (fallback.inbound[key] or 0) + f.cargo.count
  end
  fallback.inbound_drones = fallback.inbound_drones + 1
  f.dest_id, f.kind = fallback.id, "reroute"
  local to = fallback.entity.position
  f.to = { x = to.x, y = to.y }
  local c = get_cfg()
  Flight.fly_to_pad(f, to, Flight.dir_vector(fallback.direction), {
    straight = not c.fancy,
    last_turn = c.traffic and TRAFFIC_TURN or nil,
  })
  if f.r_map and f.r_map.valid then f.r_map.color = COLOR.reroute end
end

-- Unload at the destination, then dock, or take off again empty if it's full.
local function arrive(f, dest)
  dest.inbound_drones = dest.inbound_drones - 1

  if f.cargo then
    local cargo = f.cargo
    local key = item_key(cargo.name, cargo.quality)
    dest.inbound[key] = math.max(0, (dest.inbound[key] or 0) - cargo.count)
    local inserted = dest.entity.get_inventory(defines.inventory.chest).insert(cargo)
    if inserted < cargo.count then
      spill(f.surface, f.to, { name = cargo.name, quality = cargo.quality, count = cargo.count - inserted })
    end
  end

  if dest.drones < drone_capacity(dest) then
    dest.drones = dest.drones + 1
  else
    local home = nearest_with_room(f.surface, f.to, dest.id)
    if home then
      launch_flight(dest, home, nil, "return")
    else
      -- Nowhere to go: park it in the pad's inventory (it docks once a slot frees
      -- up), or drop it next to the pad if the inventory is full too.
      local parked = dest.entity.get_inventory(defines.inventory.chest).insert({ name = DRONE, count = 1 })
      if parked == 0 then spill(f.surface, f.to, { name = DRONE, count = 1 }) end
    end
  end
end

-- A flight saved by Long Haul 1.0.x (before the flight library): finish it at once.
local function finish_old_flight(f)
  for _, key in pairs({ "plane", "shadow", "map_dot", "map_line" }) do
    local r = f[key]
    if r and r.valid then r.destroy() end
  end
  local dest = storage.pads[f.dest_id]
  if dest and dest.entity.valid then
    arrive(f, dest)
  else
    if f.cargo then spill(f.surface, f.to, f.cargo) end
    spill(f.surface, f.to, { name = DRONE, count = 1 })
  end
end

local function update_flights(tick)
  local c = get_cfg()
  local banking_off = not c.banking

  -- Where players are, per surface, for culling far-away drones.
  local viewers = {}
  for _, player in pairs(game.connected_players) do
    local index = player.surface_index
    viewers[index] = viewers[index] or {}
    table.insert(viewers[index], player.position)
  end
  local range_sq = RENDER_RANGE * RENDER_RANGE
  local check_dest = tick % DEST_CHECK == 0
  local landed, rerouted, old = {}, {}, {}

  for id, f in pairs(storage.flights) do
    if not f.mode then
      old[#old + 1] = f
      storage.flights[id] = nil
    elseif not f.surface.valid then
      -- Its surface was deleted (Space Exploration and others do this); drop it.
      destroy_flight(f)
      storage.flights[id] = nil
    else
      f.banking_off = banking_off
      if (tick + id) % CULL_INTERVAL == 0 then
        local near = false
        for _, pos in pairs(viewers[f.surface.index] or {}) do
          local dx, dy = pos.x - f.pos.x, pos.y - f.pos.y
          if dx * dx + dy * dy < range_sq then near = true break end
        end
        set_drawn(f, near)
      end

      local event = Flight.step(f)
      if event == "landed" then
        landed[#landed + 1] = f
      else
        if not f.hidden then move_cargo_icon(f) end
        if check_dest then
          local dest = storage.pads[f.dest_id]
          if not (dest and dest.entity.valid) then rerouted[#rerouted + 1] = f end
        end
      end
    end
  end

  -- These can start new flights, so do them after walking the table.
  for _, f in pairs(old) do finish_old_flight(f) end
  for _, f in pairs(rerouted) do reroute(f) end
  for _, f in pairs(landed) do
    local dest = storage.pads[f.dest_id]
    if dest and dest.entity.valid then
      destroy_flight(f)
      storage.flights[f.id] = nil
      arrive(f, dest)
    else
      reroute(f) -- the pad vanished in the last few ticks: take off again
    end
  end
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if not event.setting:find("^wp%-long%-haul%-") then return end
  cfg = nil
  local c = get_cfg()
  if event.setting == "wp-long-haul-show-map-drones" then
    for _, f in pairs(storage.flights) do
      if f.mode then Flight.set_map_visible(f, c.map_dots) end
    end
  end
end)

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
    if job.cargo then
      local inserted = pad.get_inventory(defines.inventory.chest).insert(job.cargo)
      if inserted < job.cargo.count then
        spill(pad.surface, pad.position, { name = job.cargo.name, quality = job.cargo.quality, count = job.cargo.count - inserted })
      end
    end
    return
  end

  -- launch_flight counts the drone as inbound; it was pre-counted when queued.
  dest.inbound_drones = dest.inbound_drones - 1
  launch_flight(data, dest, job.cargo, job.kind)
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

--[[ Dispatching, once a second:
  1. collect every unmet request from every pad ("needs"),
  2. hand out drones one at a time, highest priority first. Within a priority,
     pads take turns, and each pad's requests take turns, so a pad with ten
     requests doesn't crowd out a pad with one, and a huge request doesn't
     starve a small one. Starting points rotate each pass.

  Everything read from the game during a pass (inventories, logistic networks,
  stock counts) is cached in `pass`, so a busy pass doesn't ask the game the
  same question once per drone.
]]

local DEFAULT_PRIORITY = 50
local MAX_PRIORITY = 255

local function pad_priority(data)
  return data.priority or DEFAULT_PRIORITY
end

local function new_pass()
  return { inv = {}, net = {}, local_counts = {}, stock = {}, lookup = {} }
end

local function pass_inventory(pass, data)
  local inv = pass.inv[data.id]
  if not inv then
    inv = data.entity.get_inventory(defines.inventory.chest)
    pass.inv[data.id] = inv
  end
  return inv
end

local function pass_network(pass, data)
  local net = pass.net[data.id]
  if net == nil then
    net = data.entity.logistic_network or false
    pass.net[data.id] = net
  end
  return net
end

-- How many of an item the pad's own robot network holds outside the pad.
local function local_count(pass, data, item, key)
  local counts = pass.local_counts[data.id]
  if not counts then
    counts = {}
    pass.local_counts[data.id] = counts
  end
  local count = counts[key]
  if count == nil then
    local net = pass_network(pass, data)
    count = 0
    if net then
      count = math.max(0, net.get_item_count(item) - pass_inventory(pass, data).get_item_count(item))
    end
    counts[key] = count
  end
  return count
end

local function request_lookup(pass, data)
  local lookup = pass.lookup[data.id]
  if not lookup then
    lookup = {}
    for _, r in pairs(requested_items(data.entity)) do lookup[item_key(r.name, r.quality)] = true end
    pass.lookup[data.id] = lookup
  end
  return lookup
end

-- What a pad can send of an item this pass. A pad supplies an item if it holds
-- it and either doesn't request it or its own network can top it back up, which
-- stops two outposts ping-ponging stock. Counted down as drones are loaded.
local function stock_of(pass, data, item, key)
  local stock = pass.stock[data.id]
  if not stock then
    stock = {}
    pass.stock[data.id] = stock
  end
  local have = stock[key]
  if have == nil then
    have = pass_inventory(pass, data).get_item_count(item)
    if have > 0 and request_lookup(pass, data)[key] and local_count(pass, data, item, key) <= 0 then have = 0 end
    stock[key] = have
  end
  return have
end

-- What a pad still needs flown in for one request (0 if nothing).
local function remote_shortfall(pass, data, request, item, key)
  local have = pass_inventory(pass, data).get_item_count(item)
  -- Missing, counting cargo already in the air...
  local shortfall = request.count - have - (data.inbound[key] or 0)
  if shortfall <= 0 then return 0 end
  -- ...minus what local bots can bring from the pad's own network.
  return math.max(0, shortfall - local_count(pass, data, item, key))
end

-- Nearest other pad, on another network, with a docked drone and stock to spare.
local function find_supplier(pass, need, candidates)
  local requester = need.data
  local requester_net = pass_network(pass, requester)
  local here = requester.entity.position
  local best, best_dist, best_have
  for _, other in pairs(candidates) do
    if other ~= requester and other.drones > 0 then
      local net = pass_network(pass, other)
      if not net or not requester_net or net ~= requester_net then
        local have = stock_of(pass, other, need.item, need.key)
        if have > 0 then
          local dist = distance_sq(other.entity.position, here)
          if not best or dist < best_dist then best, best_dist, best_have = other, dist, have end
        end
      end
    end
  end
  return best, best_have
end

-- Load one drone for a need. Returns true if a drone was sent.
local function send_one_drone(pass, need, candidates)
  local supplier, have = find_supplier(pass, need, candidates)
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
  local removed = pass_inventory(pass, supplier).remove({
    name = need.item.name, quality = need.item.quality, count = count,
  })
  if removed <= 0 then
    pass.stock[supplier.id][need.key] = 0
    return false
  end
  pass.stock[supplier.id][need.key] = have - removed

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

-- Hand out drones within one priority level: pads take turns, and within a
-- pad its requests take turns. One drone per pad per round, until no pad can
-- get another one.
local function serve_level(pass, pads, needs_by_pad, candidates, round)
  local pad_offset = round % #pads
  local cursor = {}
  local progress = true
  while progress do
    progress = false
    for n = 1, #pads do
      local id = pads[(n + pad_offset - 1) % #pads + 1]
      local list = needs_by_pad[id]
      local start = cursor[id] or (round % #list)
      for k = 0, #list - 1 do
        local index = (start + k) % #list + 1
        local need = list[index]
        if need.shortfall > 0 and not need.stuck then
          cursor[id] = index -- next turn starts with the request after this one
          if send_one_drone(pass, need, candidates) then
            progress = true
            break
          end
          need.stuck = true -- nobody can supply it right now; try the pad's next request
        end
      end
    end
  end
end

local function dispatch_all()
  storage.dispatch_round = (storage.dispatch_round or 0) + 1
  local round = storage.dispatch_round
  local pass = new_pass()

  -- Pads per surface (drones only fly within a surface), and every unmet need.
  local by_surface, needs_by_surface = {}, {}
  for _, data in pairs(storage.pads) do
    if data.entity.valid then
      local index = data.entity.surface.index
      by_surface[index] = by_surface[index] or {}
      table.insert(by_surface[index], data)
      for _, request in pairs(requested_items(data.entity)) do
        local item = { name = request.name, quality = request.quality }
        local key = item_key(request.name, request.quality)
        local shortfall = remote_shortfall(pass, data, request, item, key)
        if shortfall > 0 then
          needs_by_surface[index] = needs_by_surface[index] or {}
          table.insert(needs_by_surface[index], { data = data, item = item, key = key, shortfall = shortfall })
        end
      end
    end
  end

  for index, needs in pairs(needs_by_surface) do
    -- Highest priority first; within a priority, a fixed order to rotate through.
    table.sort(needs, function(a, b)
      local pa, pb = pad_priority(a.data), pad_priority(b.data)
      if pa ~= pb then return pa > pb end
      if a.data.id ~= b.data.id then return a.data.id < b.data.id end
      return a.key < b.key
    end)

    local i = 1
    while i <= #needs do
      local level = pad_priority(needs[i].data)
      local pads, needs_by_pad = {}, {}
      while i <= #needs and pad_priority(needs[i].data) == level do
        local need = needs[i]
        local id = need.data.id
        if not needs_by_pad[id] then
          needs_by_pad[id] = {}
          pads[#pads + 1] = id
        end
        table.insert(needs_by_pad[id], need)
        i = i + 1
      end
      serve_level(pass, pads, needs_by_pad, by_surface[index], round)
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
  local network = data.entity.logistic_network
  frame.network_label.caption = network and { "wp-long-haul.network-in" } or { "wp-long-haul.network-out" }
  frame.network_label.tooltip = network and { "wp-long-haul.network-in-tooltip" } or { "wp-long-haul.network-out-tooltip" }
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
  frame.add({ type = "label", name = "network_label" })
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
    if tick % SOUND_INTERVAL == 0 then
      Flight.play_sounds(storage.flights, "wp-long-haul-drone-flying", SOUND_RANGE, MAX_SOUNDS)
    end
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

  local open_pads = {}
  for _, id in pairs(storage.open) do open_pads[id] = true end
  local full_check = event.tick % 300 == 0

  for _, data in pairs(storage.pads) do
    if data.entity.valid then
      -- Drone requests: checked every 5 s, or every 0.5 s while the pad's panel is open.
      if full_check or open_pads[data.id] then strip_drone_requests(data) end
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
