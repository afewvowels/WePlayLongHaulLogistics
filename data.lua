local util = require("util")
if not circuit_connector_definitions then require("circuit-connector-sprites") end
local pad_sprite = require("prototypes.pad-sprite")
local drone_sprites = {
  loaded = require("prototypes.drone-loaded-sprite"),
  unloaded = require("prototypes.drone-unloaded-sprite"),
}

local GFX = "__WePlayLongHaulLogistics__/graphics/entity/"
local ICON = "__WePlayLongHaulLogistics__/graphics/icons/wp-long-haul-pad.png"
local DRONE_ICON = "__WePlayLongHaulLogistics__/graphics/icons/wp-long-haul-drone.png"
-- graphics/technology/wp-long-haul-logistics.png (256x256) is ready for the research later

-- Nudge the pad sprite (in tiles, +y is down) to line it up with the selection
-- box without re-rendering. Applied on top of the shift from pad-sprite.lua.
local PAD_SHIFT_NUDGE = { 0, 0 }

local function nudged(shift)
  return { shift[1] + PAD_SHIFT_NUDGE[1], shift[2] + PAD_SHIFT_NUDGE[2] }
end

local PAD_COLLISION = { { -2.4, -2.4 }, { 2.4, 2.4 } }
local PAD_SELECTION = { { -2.5, -2.5 }, { 2.5, 2.5 } }
local DIRECTIONS = { "north", "east", "south", "west" } -- frame order in the sheets

-- All four directions, for the rotatable placer.
local function pad_picture_4way()
  return {
    sheets = {
      {
        filename = GFX .. "wp-long-haul-pad.png",
        width = pad_sprite.diffuse.width,
        height = pad_sprite.diffuse.height,
        frames = 4,
        shift = nudged(pad_sprite.diffuse.shift),
        scale = 0.5,
      },
      {
        filename = GFX .. "wp-long-haul-pad-shadow.png",
        width = pad_sprite.shadow.width,
        height = pad_sprite.shadow.height,
        frames = 4,
        shift = nudged(pad_sprite.shadow.shift),
        scale = 0.5,
        draw_as_shadow = true,
      },
    },
  }
end

-- One direction, cut from the same sheets, for each container.
local function pad_picture(frame)
  return {
    layers = {
      {
        filename = GFX .. "wp-long-haul-pad.png",
        width = pad_sprite.diffuse.width,
        height = pad_sprite.diffuse.height,
        x = frame * pad_sprite.diffuse.width,
        shift = nudged(pad_sprite.diffuse.shift),
        scale = 0.5,
      },
      {
        filename = GFX .. "wp-long-haul-pad-shadow.png",
        width = pad_sprite.shadow.width,
        height = pad_sprite.shadow.height,
        x = frame * pad_sprite.shadow.width,
        shift = nudged(pad_sprite.shadow.shift),
        scale = 0.5,
        draw_as_shadow = true,
      },
    },
  }
end

-- What the player places, and what ghosts and blueprints use. It rotates
-- natively, so R works in the build preview and blueprint rotation works.
-- control.lua swaps it for the matching pad the moment it's built.
data:extend({
  {
    type = "simple-entity-with-owner",
    name = "wp-long-haul-pad-placer",
    localised_name = { "entity-name.wp-long-haul-pad" },
    icon = ICON,
    hidden_in_factoriopedia = true,
    flags = { "placeable-player", "player-creation", "not-upgradable" },
    minable = { mining_time = 0.5, result = "wp-long-haul-pad" },
    placeable_by = { item = "wp-long-haul-pad", count = 1 },
    max_health = 500,
    collision_box = PAD_COLLISION,
    selection_box = PAD_SELECTION,
    render_layer = "object",
    picture = pad_picture_4way(),
  },
})

-- The real pads: 5x5 buffer chests, so requests use the vanilla picker and
-- local bots can stock them and take deliveries from them. One prototype per
-- direction so the world, ghosts and the GUI preview all look right.
for frame, dir in pairs(DIRECTIONS) do
  data:extend({
    {
      type = "logistic-container",
      logistic_mode = "buffer",
      -- Pads link up with each other at any range, so no "not in a logistic network" warning.
      render_not_in_network_icon = false,
      name = "wp-long-haul-pad-" .. dir,
      localised_name = { "entity-name.wp-long-haul-pad" },
      localised_description = { "entity-description.wp-long-haul-pad" },
      icon = ICON,
      hidden_in_factoriopedia = dir ~= "north",
      flags = { "placeable-player", "player-creation" },
      minable = { mining_time = 0.5, result = "wp-long-haul-pad" },
      placeable_by = { item = "wp-long-haul-pad", count = 1 },
      max_health = 500,
      corpse = "big-remnants",
      collision_box = PAD_COLLISION,
      selection_box = PAD_SELECTION,
      inventory_size = 80,
      picture = pad_picture(frame - 1),
      -- Wire connection point on the bottom-right corner of the pad.
      circuit_wire_max_distance = 9,
      circuit_connector = circuit_connector_definitions.create_vector(universal_connector_template, {
        { variation = 26, main_offset = util.by_pixel(62, 58), shadow_offset = util.by_pixel(68, 64), show_shadow = true },
      }),
    },
  })
end

data:extend({
  {
    type = "item",
    name = "wp-long-haul-pad",
    icon = ICON,
    subgroup = "logistic-network",
    order = "c[signal]-z[wp-long-haul-pad]",
    place_result = "wp-long-haul-pad-placer",
    stack_size = 10,
  },

  {
    type = "recipe",
    name = "wp-long-haul-pad",
    enabled = false, -- unlocked by the Long Haul Logistics research
    energy_required = 10,
    ingredients = {
      { type = "item", name = "accumulator", amount = 1 },
      { type = "item", name = "electric-engine-unit", amount = 10 },
      { type = "item", name = "steel-plate", amount = 20 },
      { type = "item", name = "advanced-circuit", amount = 10 },
      { type = "item", name = "concrete", amount = 20 },
    },
    results = { { type = "item", name = "wp-long-haul-pad", amount = 1 } },
  },

  {
    type = "item",
    name = "wp-long-haul-drone",
    icon = DRONE_ICON,
    subgroup = "logistic-network",
    order = "c[signal]-z[wp-long-haul-zdrone]",
    stack_size = 10,
  },

  {
    type = "recipe",
    name = "wp-long-haul-drone",
    enabled = false, -- unlocked by the Long Haul Logistics research
    energy_required = 10,
    ingredients = {
      { type = "item", name = "flying-robot-frame", amount = 1 },
      { type = "item", name = "electric-engine-unit", amount = 2 },
      { type = "item", name = "steel-plate", amount = 5 },
      { type = "item", name = "advanced-circuit", amount = 5 },
    },
    results = { { type = "item", name = "wp-long-haul-drone", amount = 1 } },
  },

  -- Fire on the normal rotate keys (R / Shift+R) so placed pads can rotate.
  {
    type = "custom-input",
    name = "wp-long-haul-rotate",
    key_sequence = "",
    linked_game_control = "rotate",
  },
  {
    type = "custom-input",
    name = "wp-long-haul-reverse-rotate",
    key_sequence = "",
    linked_game_control = "reverse-rotate",
  },
})

-- Flying drones: 64 headings each, clockwise from north. The script picks the
-- frame for the drone's heading (animation_speed 0 + animation_offset).
for variant, sheet in pairs(drone_sprites) do
  data:extend({
    {
      type = "animation",
      name = "wp-long-haul-drone-" .. variant,
      filename = GFX .. "wp-long-haul-drone-" .. variant .. ".png",
      width = sheet.diffuse.width,
      height = sheet.diffuse.height,
      frame_count = sheet.diffuse.direction_count,
      line_length = sheet.diffuse.line_length,
      shift = sheet.diffuse.shift,
      scale = 0.5,
    },
    {
      type = "animation",
      name = "wp-long-haul-drone-" .. variant .. "-shadow",
      filename = GFX .. "wp-long-haul-drone-" .. variant .. "-shadow.png",
      width = sheet.shadow.width,
      height = sheet.shadow.height,
      frame_count = sheet.shadow.direction_count,
      line_length = sheet.shadow.line_length,
      shift = sheet.shadow.shift,
      scale = 0.5,
      draw_as_shadow = true,
    },
  })
end

-- Sounds (from Radar Probe Drone Launcher for now).
data:extend({
  {
    type = "sound",
    name = "wp-long-haul-drone-launch",
    filename = "__WePlayLongHaulLogistics__/sound/wp-long-haul-drone-launch.ogg",
    volume = 0.7,
    audible_distance_modifier = 0.8,
  },
  {
    type = "sound",
    name = "wp-long-haul-drone-flying",
    filename = "__WePlayLongHaulLogistics__/sound/wp-long-haul-drone-flying.ogg",
    volume = 0.35,
    audible_distance_modifier = 0.6,
  },
})

-- Hidden helpers that live under each pad ---------------------------------------

local HIDDEN_FLAGS = {
  "not-on-map", "not-blueprintable", "not-deconstructable", "not-selectable-in-game",
  "not-flammable", "not-repairable", "not-upgradable",
}

-- Power: 500 kW idle; control.lua raises it to 1 MW for the second of a launch.
data:extend({
  {
    type = "electric-energy-interface",
    name = "wp-long-haul-pad-power",
    localised_name = { "entity-name.wp-long-haul-pad" },
    icon = ICON,
    hidden = true,
    flags = HIDDEN_FLAGS,
    max_health = 1,
    collision_box = PAD_COLLISION, -- so poles covering any part of the pad power it
    collision_mask = { layers = {} },
    energy_source = {
      type = "electric",
      usage_priority = "secondary-input",
      buffer_capacity = "2MJ",
      input_flow_limit = "2MW",
      output_flow_limit = "0W",
    },
    energy_usage = "500kW",
    picture = util.empty_sprite(),
  },
})

-- Signals: a hidden constant combinator, joined to the pad by script wires,
-- that outputs the drone counts onto whatever network the pad is wired into.
local signals = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
signals.name = "wp-long-haul-pad-signals"
signals.localised_name = { "entity-name.wp-long-haul-pad" }
signals.icon = ICON
signals.icons = nil
signals.hidden = true
signals.flags = HIDDEN_FLAGS
signals.minable = nil
signals.placeable_by = nil
signals.fast_replaceable_group = nil
signals.next_upgrade = nil
signals.collision_mask = { layers = {} }
signals.selection_box = nil
signals.sprites = util.empty_sprite()
signals.activity_led_sprites = util.empty_sprite()
signals.draw_circuit_wires = false
signals.corpse = nil
signals.dying_explosion = nil
data:extend({ signals })

data:extend({
  { type = "item-subgroup", name = "wp-long-haul-signals", group = "signals", order = "z[wp-long-haul]" },
})

local function signal_icon(tint)
  return { { icon = DRONE_ICON, tint = tint } }
end

data:extend({
  {
    type = "virtual-signal",
    name = "wp-long-haul-drones-available",
    icons = signal_icon({ 0.6, 1, 0.6 }),
    subgroup = "wp-long-haul-signals",
    order = "z[wp-long-haul]-a",
  },
  {
    type = "virtual-signal",
    name = "wp-long-haul-drones-total",
    icons = signal_icon({ 1, 1, 1 }),
    subgroup = "wp-long-haul-signals",
    order = "z[wp-long-haul]-b",
  },
  {
    type = "virtual-signal",
    name = "wp-long-haul-drones-inbound",
    icons = signal_icon({ 1, 0.85, 0.3 }),
    subgroup = "wp-long-haul-signals",
    order = "z[wp-long-haul]-c",
  },
  {
    type = "virtual-signal",
    name = "wp-long-haul-network-drones",
    icons = signal_icon({ 0.5, 0.8, 1 }),
    subgroup = "wp-long-haul-signals",
    order = "z[wp-long-haul]-d",
  },
})

-- Research ---------------------------------------------------------------------

local TECH_GFX = "__WePlayLongHaulLogistics__/graphics/technology/"

local function capacity_icons()
  if util.technology_icon_constant_capacity then
    return util.technology_icon_constant_capacity(TECH_GFX .. "wp-long-haul-cargo-capacity.png")
  end
  return { { icon = TECH_GFX .. "wp-long-haul-cargo-capacity.png", icon_size = 256 } }
end

data:extend({
  {
    type = "technology",
    name = "wp-long-haul-logistics",
    icon = TECH_GFX .. "wp-long-haul-logistics.png",
    icon_size = 256,
    prerequisites = { "robotics", "electric-energy-accumulators", "concrete" },
    effects = {
      { type = "unlock-recipe", recipe = "wp-long-haul-pad" },
      { type = "unlock-recipe", recipe = "wp-long-haul-drone" },
    },
    unit = {
      count = 150,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
  },
  {
    type = "technology",
    name = "wp-long-haul-cargo-capacity-1",
    icons = capacity_icons(),
    prerequisites = { "wp-long-haul-logistics" },
    effects = {
      { type = "nothing", effect_description = { "wp-long-haul.effect-payload", "250" } },
      { type = "nothing", effect_description = { "wp-long-haul.effect-slot", "30" } },
    },
    unit = {
      count = 300,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
      },
      time = 30,
    },
    upgrade = true,
  },
  {
    type = "technology",
    name = "wp-long-haul-cargo-capacity-2",
    icons = capacity_icons(),
    prerequisites = { "wp-long-haul-cargo-capacity-1", "production-science-pack" },
    effects = {
      { type = "nothing", effect_description = { "wp-long-haul.effect-payload", "500" } },
      { type = "nothing", effect_description = { "wp-long-haul.effect-slot", "40" } },
    },
    unit = {
      count = 500,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "chemical-science-pack", 1 },
        { "production-science-pack", 1 },
      },
      time = 45,
    },
    upgrade = true,
  },
})
