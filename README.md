# WePlay: Long Haul Logistics Drones

**A logistics network with no coverage map.** Swarms of cargo airplanes link your outposts to your main base, at any distance. It's an alternative to trains for long distance transportation.

- **Mod portal:** https://mods.factorio.com/mod/WePlayLongHaulLogistics
- **Factorio:** 2.1 (base game; Space Age optional)
- **Requires:** [WePlay: Flight Library](https://mods.factorio.com/mod/WePlayFlightLib) 0.1.6 or newer (installed automatically by the mod manager)
- **License:** [The Unlicense](LICENSE) (public domain)

---

## For players

### What it does

Put a **launch pad** at your main base and another at each outpost. Set requests on the outpost pad like you would on a buffer chest. Anything the outpost's own robots can't supply gets **flown in by cargo airplanes** from another pad. The cargo lands in the pad's inventory, where local robots can use it for construction, requester chests and personal logistics.

Airplanes that pile up at outposts fly themselves home to the nearest hub, so the fleet keeps cycling without any babysitting.

### Getting started

1. Research **Long haul logistics** (after Robotics, Electric energy accumulators and Concrete).
2. Build a **launch pad** inside your main base's robot network, power it, and put some **long haul drones** in it.
3. Build a **launch pad** at your outpost, power it, and add requests in its logistics section.
4. Watch the airplanes take off. ✈️

### Features

- **Launch pads:** 5x5, rotatable buffer chests with 80 slots, using the vanilla logistics picker and logistic groups
- **Drone slots** like a roboport: 20 drones per pad (up to 40 with research), filled by hand or inserter
- **Fair dispatch:** drones are shared round-robin, pads first and then each pad's requests, so small requests always get filled. Plus a **0–255 priority** per pad
- **Spread loads / Fill drones** switch per pad
- **Works with or without roboports:** pads link up at any range, so there's no "not in a logistic network" warning. The pad panel shows whether a pad is inside a robot network, and outside one you load and unload it with inserters
- **Weight-based payload:** 100 kg per drone, 250 kg and 500 kg with research
- **Runway takeoffs, wide banking turns and lined-up landings,** with sounds, and drones visibly roll into their turns
- **Alt-mode cargo icons:** loaded drones show what they're carrying when alt mode is on
- **Map view:** drones can show on the map as dots colored by trip type (map setting, off by default)
- **Power:** 500 kW idle, 1 MW during launches
- **Circuit network:** set requests from combinators, and read drone statistics on any signals you choose
- **Multi-surface friendly:** works with Space Age, Space Exploration and other mods with multiple surfaces

### Research

| Technology | Requires | Unlocks |
|---|---|---|
| Long haul logistics | Robotics, Electric energy accumulators, Concrete | Launch pad, drone, 100 kg payload, 20 drones per pad |
| Long haul cargo capacity 1 | Long haul logistics | 250 kg payload, 30 drones per pad |
| Long haul cargo capacity 2 | Cargo capacity 1, Production science pack | 500 kg payload, 40 drones per pad |

### Tips

- **Hubs** are pads that supplied another pad in the last 5 minutes. They keep all their drones. Every other pad keeps 2 for return trips and sends the rest home.
- **Point outpost runways toward your main base** for the quickest approach.
- **Keep a hub stocked automatically:** wire the pad to an inserter from your drone assembler and enable it when *available drones < 10*.
- **Fancy flight paths** can be turned off in *Settings → Mod settings → Map* for straight pad-to-pad flights. **Separate arrivals and departures**, **Show drones on the map**, **Banking turns** and **Maximum launch pads per force** (default 10, 0 = no limit) are there too.

### Known limitations

- Circuit wires connected to a launch pad aren't saved in blueprints yet.
- With the pad limit on (the default is 10 per force), robots that build a pad over the limit drop it on the ground, marked for pickup.
- Drone requests set by the circuit network can't be blocked yet. Avoid sending drone item signals to a pad in *Set requests* mode.
- A brand-new main base pad only counts as a hub after it first supplies another pad.

Bug reports and ideas are welcome in the mod portal's **Discussion** tab or as GitHub issues.

---

## For modders

### Repository layout

```
WePlayLongHaulLogistics-repo/
├── README.md
├── LICENSE
├── tools/
│   ├── pack_sprites.py          # packs the pad and level drone renders into sheets + .lua sizes
│   └── pack_drone_sprites.py    # packs rendered drone frames (5 banks x 64 headings) into sheets + Lua
└── WePlayLongHaulLogistics/     # ← only this folder goes in the release zip
    ├── info.json
    ├── changelog.txt
    ├── thumbnail.png
    ├── settings.lua             # "Fancy flight paths" runtime setting
    ├── data.lua                 # all prototypes
    ├── control.lua              # dispatcher, flights, GUI, circuits
    ├── prototypes/
    │   ├── pad-sprite.lua           # generated by pack_sprites.py
    │   ├── drone-loaded-sprite.lua  # generated by pack_sprites.py
    │   └── drone-unloaded-sprite.lua
    ├── graphics/
    │   ├── entity/       # pad (4 directions) and drone (64 headings) sheets + shadows
    │   ├── icons/
    │   └── technology/
    ├── sound/
    ├── migrations/
    └── locale/en/locale.cfg
```

> **Release tip:** the mod portal rejects zips that contain scripts like `.py`, so keep `tools/` outside the mod folder.

### Updating the art

Sprites are rendered in Blender and packed with `tools/pack_sprites.py`, which writes a sheet plus a small `.lua` file with the frame size, shift, line length and direction count. `data.lua` reads those files, so after a re-render you only need to replace the PNGs and the `.lua` files. No code changes needed.

- **Pad:** 4 frames in one row, in the order **north, east, south, west**, rendered at 64 px per tile (`scale = 0.5`). The runway's hazard-stripe end is the facing direction.
- **Drones:** 64 headings, 8 per row, **clockwise from north**. The flight library picks a frame from the heading.
- **Rendered bank frames (optional):** render each drone at 5 bank levels × 64 headings (all 64 headings of bank 0, then bank 1, and so on; bank 0 = hard left from the pilot's seat), then pack each drone with `tools/pack_drone_sprites.py`, run from the mod folder:
  ```
  python3 ../tools/pack_drone_sprites.py --hull renders/loaded/hull --shadow renders/loaded/shadow \
      --out graphics/entity/drone-loaded --mod-root . --mod WePlayLongHaulLogistics \
      --name wp-long-haul-drone-loaded --split-banks 5
  ```
  and the same with `unloaded`. `data.lua` loads the generated `drone-animations.lua` from each folder and switches banking from the squeeze trick to real frames. Both drones need the same number of banks.
- **Shadows:** separate sheets with the same layout, drawn with `draw_as_shadow`.
- **Camera tilt:** stretch the scene along the depth axis by `1 / sin(tilt)` so square footprints render square.
- `PAD_SHIFT_NUDGE` at the top of `data.lua` nudges the pad sprite without re-rendering.

### How it works

**Prototypes** (all prefixed `wp-`):

| Name | Type | Purpose |
|---|---|---|
| `wp-long-haul-pad-placer` | simple-entity-with-owner | What players, robots and blueprints build. It rotates natively and gets swapped for the matching pad on build |
| `wp-long-haul-pad-north/east/south/west` | logistic-container (buffer) | The real pad, one prototype per direction so the world, ghosts and GUI preview all show the right runway |
| `wp-long-haul-pad-power` | electric-energy-interface | Hidden. 500 kW idle, raised to 1 MW during launches |
| `wp-long-haul-pad-signals` | constant-combinator | Hidden. Outputs the drone statistics, joined to the pad by script-origin wires |
| `wp-long-haul-drone-loaded/unloaded` (+ `-shadow`) | animation | Flying drones, drawn with `rendering.draw_animation` |
| `wp-long-haul-drone-<variant>-hull-<n>` / `-shadow-<n>` | animation | Rendered bank frames, when present (written by `pack_drone_sprites.py`; the flight library's `split_banks` names) |
| `wp-long-haul` | mod-data | Tells `control.lua` how many bank frames there are |
| `wp-long-haul-drones-available/total/inbound`, `wp-long-haul-network-drones` | virtual-signal | Default statistic signals |

**Runtime overview** (`control.lua`):

- **Pads** are tracked in `storage.pads[id]` by an id of their own, because rotating swaps the entity and changes its unit number. `storage.by_unit` maps unit numbers to ids.
- **Dispatcher** (every 60 ticks): collects every unmet remote request on each surface, then hands out drones one at a time, highest priority first. Within a priority, pads take turns and each pad's requests take turns, with rotating starting points. A request counts as remote only after subtracting cargo already in the air and what the pad's own logistic network holds. Inventories, networks and stock are read once per pass and cached.
- **Launch queue:** each pad launches one drone per second, and only with power when it carries cargo.
- **Flights** are flown by [WePlay: Flight Library](https://mods.factorio.com/mod/WePlayFlightLib): runway takeoffs, turn-radius paths, lined-up landings, altitude, shadows and banking (squeeze trick, or rendered bank frames when present). Long Haul keeps one flight table per drone in `storage.flights`, adds its own fields (destination, cargo, trip kind, alt-mode icon) and calls `Flight.step` once per tick.
- **Traffic pattern:** with *Separate arrivals and departures* on, every flight passes `first_turn = "R"` and `last_turn = "R"` to `Flight.fly_to_pad`, so departures and arrivals use opposite circles around each pad.
- **Culling:** drones more than 160 tiles from every player are hidden and not redrawn, which is most of the per-tick cost. Their map dots still move.
- **Rebalancing** (every 300 ticks): pads that aren't hubs send drones beyond their reserve of 2 to the nearest hub with free slots.
- **Everything is per surface.** Flights over deleted surfaces are cleaned up.

**Tunable constants** at the top of `control.lua`:

| Constant | Default | What it does |
|---|---|---|
| `TIERS` | 2/3/4 slots, 100/250/500 kg | Drone slots and payload per research tier |
| `RESERVE_DRONES` | 2 | Drones a non-hub pad keeps |
| `HUB_MEMORY` | 5 minutes | How long a pad counts as a hub after supplying |
| `LAUNCH_DELAY` | 60 ticks | Time between launches per pad |
| `POWER_IDLE` / `POWER_LAUNCH` | 500 kW / 1 MW | Pad power draw |
| `POWERED_EMPTY_ONLY` | false | Set to true to require power for empty flights too |
| `RENDER_RANGE` | 160 tiles | Drones further than this from every player aren't redrawn |

Flight tuning (speed, cruise altitude, turn radius, climb-out, approach and banking) uses WePlay: Flight Library's `Flight.DEFAULTS`.

### Contributing

Pull requests are welcome! Please keep prototype names prefixed with `wp-` and test on a save with at least two surfaces if you touch the dispatcher or flights.

---

*Part of the **WePlay** mod family. Find the rest on the [mod portal](https://mods.factorio.com/user/afewvowels).*
