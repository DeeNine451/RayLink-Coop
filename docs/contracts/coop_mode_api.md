# coop_mode — the Lua mode facade, frozen API (A-S4L, W0)

Frozen 2026-11-18 18:48. After the W0 gate this file and the API it describes change only through the lead.
Source: `gamedata/scripts/coop_mode.script` (Core), `coop_hostplay_mode.script` (hostplay), `coop_srv_mode.script` (srv);
rules: `docs/MODES.md` sections 3-4. Works on today's engine (no new engine API).

## 1. Rules for callers

- Call as a global module, `coop_mode.x(...)`. **No new `local`** for it (L7: `coop_tasks` 197/200, `coop_npc_companions` 181).
  The engine auto-loads the script on first use (`script_engine.cpp auto_load`).
- Ask only about a player, a map or this process's own actor. There is **no** "which mode is this" function, by design.
- The facade never reads a mode predicate; only the two layer scripts do. Core code must not either (L1/L2).
- A srv script registers callbacks, condition functions, events and saves **only inside `coop_mode.when_srv(fn)`** (L9).

## 2. Questions

`peer` is a peer id (host numbering, 0 = the host's / the world server's seat). A peer that is not a whole number >= 0 gets
the "none" answer without asking a layer.

| Function | Returns | Meaning |
|---|---|---|
| `where(peer)` | `"here"` / `"away"` / `"joining"` | is that player's character on the map this process has loaded; joining = in the world, not placed / not spawned yet |
| `decider(peer)` | `"this"` / `"other"` / `"nobody"` | who decides for that player's character: this process, another process, nobody (no such player, or a ghost) |
| `actor_is_player()` | bool | this process's own actor is a player (false: a server's ghost) |
| `decides_world()` | bool | this process decides the world: offline, time, story, money, the save |
| `leads_here()` | bool | this process leads the map it has loaded: objects, AI, physics |
| `is_player_mirror()` | bool | a player's machine whose objects are copies (replaces the two different `is_client()`) |
| `seat_plays(peer)` | bool | that seat plays a character (`seat_plays(0)`: is the host's seat a player) |
| `group_travels()` | bool | the group moves between maps together |

Answers per process (live layers; the test sets model the first, third, fourth and last column):

| | co-op host | co-op client | world server (`-coop_dedicated`) | map server | server player | none |
|---|---|---|---|---|---|---|
| `where(self)` | here | here | away (ghost) | away (ghost) | here | away |
| `where(p)` | here; joining before his character is in the world | same | away; joining before he is placed | here on its map, away elsewhere, joining unplaced | here on my map, away elsewhere | away |
| `decider(p)` known player | this | other | other | this on its map, other elsewhere | other | nobody |
| `decider` stranger / own ghost | nobody | nobody | nobody | nobody | nobody | nobody |
| `actor_is_player()` | true | true | false | false | true | true |
| `decides_world()` | true | false | true | false | false | false |
| `leads_here()` | true | false | false | true | false | false |
| `is_player_mirror()` | false | true | false | false | true | false |
| `seat_plays(p)` | p has a row in `coop.players()` | same | same; own seat false | same; own seat false | same | false |
| `group_travels()` | true | true | false | false | false | false |
| `publish` goes to | -1 (all) | -1 | -1 (engine adds bridges) | 0 (world server) | -1 | not sent |
| level request | handled here | handled here (the door refuses on a client) | passed to `bridge_of_player(from)` with `_peer`, else here | only from 0 with `_peer`: handled as that peer | handled here | handled here |

Which layer answers (today's predicates, read only by the layer scripts):
- srv: active session and (`coop.is_map_server()` or `coop.is_dedicated()` or `coop.levels.split()`). World server role =
  `coop.is_host()`. Until S2 a playing host of a split session (the hybrid) is answered by srv from the same predicates.
- hostplay: active session and none of the above.
- none: no active session, or no layer installed. The co-op layer is asked first.
- A server player's machine knows `split()` only from its first LevelMap (S3 moves the mode into Welcome): until then it
  is answered by hostplay, as today's code behaves.

## 3. Delivery

`on_level_request(name, fn[, door]) -> bool` — registers event `name` (through `coop_main.add_event_handler`): a player's
request to the logic of the map he stands on.
- `fn(payload, from, relayed)` runs on the process that leads his map; `from` = the player; `relayed` = another process
  passed it on (its door ran there). `payload` is the encoded flat table (`coop_main.decode`), without `_peer`.
- `door(payload, from) -> true` (optional) runs first on the process the player's request reached, before it is handled
  or passed on; anything but `true` drops it. Not run for a relayed request.
- Replaces `coop_main.add_level_handler` (callers switch in their own units) and is what `coop_mods_core.on(verb, f, "host")`
  now uses (door = its side and rate checks).

`publish(verb, t) -> bool` — world data this process changed, to those who keep the world: event `verb` (no prefix added),
`t` a flat table (`coop_main.encode`) or a string sent as it is. True when the engine took it. `coop_mods_core.publish`
goes through it (`"mods." .. verb`, its size limit and counters stay).

## 4. when_srv and the layers

`when_srv(fn[, layer]) -> bool` — `fn()` runs once in this Lua state, as soon as the srv layer answers: at once when it
does now, else on the first question or the first `actor_on_update` after that. In order of registration; an error is
logged (`[coop-mode] ! when_srv`) and does not stop the others; a `when_srv` inside a running fn runs in the same pass.
In the co-op and in single player the functions never run. Registrations they make stay for the Lua state.
`layer`: the srv layer itself; only `coop_srv_mode.script` passes it (L9 lets a srv script call nothing at load but
`coop_mode.when_srv`). A layer whose name is not `"srv"` is refused there.

`install(layer) -> bool`, `uninstall(name) -> bool` — `name` is `"hostplay"` or `"srv"`. A layer is a table:

```lua
{ name = "hostplay" | "srv",
  applies = function() -> bool end,               -- this layer answers now
  where = function(peer) end, decider = function(peer) end, seat_plays = function(peer) end,
  actor_is_player = ..., decides_world = ..., leads_here = ..., is_player_mirror = ..., group_travels = ...,
  publish_to = function(verb) -> target number | nil end,     -- nil: not sent
  level_request = function(name, payload, from)
      -> "here", payload, player, relayed | "pass", target peer, payload | "drop" end }
```
Every field must be a function (else `install` refuses). An answer that raises or is not a valid word is replaced by the
"none" answer and logged (`[coop-mode] ! <layer>.<fn>` / `! where answer`). `print_status()` logs the installed layers,
which one answers and how many `when_srv` functions wait (diagnostics only; not wired into `coop_status` yet).

Layer scripts: `coop_hostplay_mode.on_game_start()` → `coop_mode.install(LAYER)`;
`coop_srv_mode.on_game_start()` → `coop_mode.when_srv(started, LAYER)` (logs `[srv] mode: world server | map server | player`).
Both expose `LAYER`. In S4C their predicates move to `srv.*`; only these two files change for that.

## 5. Tests

- `tests/lua/support/mode_hostplay.lua`, `mode_srv_world.lua` (`set.bridge = 0x101`: requests are passed there),
  `mode_srv_map.lua`, `mode_none.lua`: fixed answer tables (layer shape above, plus `set = "<name>"`).
- `tests/lua/support/modes.lua` (`local modes = dofile(...)`):
  `modes.SETS`; `modes.names([value])` — the sets `COOP_LUA_MODE` names (blank/comma list), all when unset or `all`;
  `modes.set(name[, overrides])` — a fresh set; `modes.install(facade, name[, overrides])` — both layers out, the set in
  (`none`: out only), returns the set; `modes.each(facade, fn[, overrides])` — `fn(name, set)` per set;
  `modes.live(facade[, load])` — the real layer scripts, started as axr_main does.
- A Core test loops `for _, name in ipairs(modes.names()) do modes.install(coop_mode, name) ... end`; the runner runs it
  once per set (section 6). Layer tests: `test_hostplay_mode.lua`, `test_srv_mode.lua`; facade: `test_mode_facade.lua`.

## 6. For the lead (not done by A-S4L: not its files)

Harness — the facade and its layers must be loaded where the game's axr_main would load them (without these, 6 files
fail: `mods_route`, `mods_deploy_host`, `mods_flows_host`, `mods_flows_extra_host`, `mods_wpo_split`, `w5_mods`):

1. `tests/lua/support/stubs_mods.lua`, `start_all()`:
   ```lua
   MODE_FILES = { "coop_hostplay_mode", "coop_mode", "coop_srv_mode" }
   function start_all()
   	load_script("coop_main")
   	for _, n in ipairs(MODE_FILES) do load_script(n) end
   	for _, n in ipairs(MODS_FILES) do load_script(n) end
   	coop_main.on_game_start()
   	for _, n in ipairs(MODE_FILES) do _G[n].on_game_start() end
   	for _, n in ipairs(MODS_FILES) do _G[n].on_game_start() end
   end
   ```
2. `tests/lua/support/w5/coop_files.lua`: add `"coop_hostplay_mode"`, `"coop_mode"`, `"coop_srv_mode"` to `COOP_FILES`.
3. `tests/lua/test_mods_wpo_split.lua`, in each world before `load_script(W, "coop_mods_core")`:
   `for _, n in ipairs({ "coop_hostplay_mode", "coop_mode", "coop_srv_mode" }) do load_script(W, n) end`, and before
   `W.coop_economy_mdata.on_game_start()`: `for _, n in ipairs({ ... same ... }) do W[n].on_game_start() end`.

Runner — the set loop goes into the driver `tests/lua/run_all.lua` (`tools/test_lua.cmd` only starts it; no line there):
after `os.execute("mkdir " .. OUT_DIR .. " 2>nul")` add `SETS` and `runs_of(list)` (a test whose text has `modes.names(`
or `modes.each(` becomes four runs `{ name, stem = stem .. "@" .. set, set }`), and run each with
`os.execute("set COOP_LUA_MODE=" .. (t.set or "") .. "&& " .. RUNLUA .. " " .. TEST_DIR .. BS .. t.name .. " > " .. out .. " 2>&1")`
over `runs_of(tests)`. Verified text: `temp/s4l/make_mirror.py` (`patch_sets`).

`tools/layers.txt`: no new rows. `coop_mode.script` is core by default; `coop_hostplay_mode.script` is covered by
`hostplay gamedata/scripts/coop_hostplay_*.script`, `coop_srv_mode.script` by `srv gamedata/scripts/coop_srv_*.script`.
Neither layer script is reached by the Core (`check_layers.core_reach`). `layers_allow.txt`: 6 entries of
`coop_mods_core.script` are stale (the old relay and publish): `check_layers: OK (4617 files, ceiling 2335, used 2329)`
at 2026-11-18 18:52; `--write-allow` drops them (the other executors' work moves `used` too).
