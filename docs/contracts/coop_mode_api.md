# coop_mode — the Lua mode facade, frozen API (A-S4L, W0)

Frozen 2026-11-18 18:48. After the W0 gate this file and the API it describes change only through the lead.
Source: `gamedata/scripts/coop_mode.script` (Core), `coop_hostplay_mode.script` (hostplay), `coop_srv_mode.script` (srv);
rules: `docs/MODES.md` sections 3-4. Works on today's engine (no new engine API).

Changed 2026-11-19 (A-S4D, the lead's option (a)): **the srv layer answers in a process started with `-coop_dedicated`
from `coop_srv_mode.on_game_start` on** (axr_main's file order; before it the facade answers none), before its session,
not only in an active session. Before, a world server was answered by "none" until its session started (after its world
was up, `HostAutostart`), so `when_srv` ran there only after the world and its save had loaded. What changed: the "Which
layer answers" rule and the world server's role below; the world server column now holds before its session too (row
"before its session"); `publish` there sends nothing before the session; section 4: on a world server `when_srv`
functions run at load. Every other process is answered as before (a co-op host, a co-op client, a map server and a
server player before their session: "none"). The facade (`coop_mode.script`), the hostplay layer and the answer sets of
the tests did not change.

Changed 2026-11-20 (A-S6-IF, through the lead's brief): **section 7**, the answers the S6 groups ask: in Lua `hook`,
`facts_of`, `far`, `share_up`, `share_down` (and three optional layer fields); in C++ `Mode::level()` / `LevelSide` and the
world-side `Mode` members, plus two process hooks of `Layer`. Nothing before section 7 changed in behaviour.

Changed 2026-11-20 (review A-REV-E-1, finding 4; wording only): the srv layer of a world server answers from
`coop_srv_mode.on_game_start` on, not from the process's start: axr_main loads every script, then runs `on_game_start` in
file order, so a Core script's file level, or its `on_game_start` that runs before `coop_srv_mode`'s, gets the "none"
answers there. Section 7.3: the hook `levels.bridge_of_player` (B-REV F5).

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

Answers per process (live layers; the test sets model the first, third, fourth and last column). The world server column
holds from `coop_srv_mode.on_game_start` on (A-S4D; axr_main's file order; before it the facade answers none): before
its session the engine gives it no role (`is_host()` false), no seat (`self_id()` -1) and no rows of `coop.players()`,
and its answers do not depend on them:

| | co-op host | co-op client | world server (`-coop_dedicated`, from `coop_srv_mode.on_game_start`) | map server | server player | none |
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
| `publish` goes to | -1 (all) | -1 | -1 (engine adds bridges); before its session not sent | 0 (world server) | -1 | not sent |
| level request | handled here | handled here (the door refuses on a client) | passed to `bridge_of_player(from)` with `_peer`, else here | only from 0 with `_peer`: handled as that peer | handled here | handled here |
| `from_level(from)` (A-FL) | false | false | true when `from` is a currently registered map-server bridge during the active session; false otherwise | false | false | false |
| before its session | none | none | the column above: `where` away and `decider` nobody for every peer, `seat_plays` false (no rows yet), the rest as in the session | none | none | — |

`from_level(from) -> bool` (A-FL, 2026-11-19): whether the event transport's sender is a map server's bridge. `from` is the
sender peer the transport gives; anything but a whole peer id in range, peer 0, a player, an unknown or no longer listed
bridge, an inactive world session, every co-op role, a map server, a server player and offline answer false. A world
server accepts a map's report (story checkpoint, HF / items / mags reports) only when it is true; every refusal still goes
through `coop_trust.pass`. The srv layer reads `coop.levels.map_servers()` on each call: a bridge whose process is closing
can stay listed for a moment after its connection closed (an exact transport-disconnect answer needs a Lua binding of the
engine's own question; not done).

Which layer answers (today's predicates, read only by the layer scripts):
- srv: `coop.is_dedicated()` (a process started with `-coop_dedicated`: the world server) from `coop_srv_mode.on_game_start`
  on (axr_main's file order; before it the facade answers none), before, during and after its session (A-S4D); or an
  active session and (`coop.is_map_server()` or `coop.levels.split()`). World
  server role = `coop.is_dedicated()` or (`coop.is_host()` and not a map server). Until S2 a playing host of a split session
  (the hybrid) is answered by srv from the same predicates.
- hostplay: active session and none of the above.
- none: no active session and not `-coop_dedicated`, or no layer installed. The co-op layer is asked first. A co-op host
  before its session is answered by none, as before.
- A server player's machine knows `split()` from its Welcome (protocol 33 carries the session's mode; S4C: `coop_levels.cpp`
  `split()` on a client is `world_session().session_mode() == SessionMode::Server`), not from its first LevelMap any more:
  from the Welcome on it is answered by srv.
- The C++ `Mode` answers (`coop_mode.h`, `srv/coop_srv_mode.cpp`) differ from this table in three cells, on purpose: a world
  server answers `where(stranger)` = Joining (here: away) and `decider_of(unplaced player)` = This (here: other); a map
  server answers `decider_of(joining player)` = This (here: other). The C++ choice makes `on_host_level(p)` exactly
  `where(p) != Away` (review A-S4C F3). Nobody calls these C++ answers yet; S6 converts code against **this** Lua table and
  settles the C++ one to it first (S6 unit A-S6-T). A fourth difference since A-S4D: before its session a world server's
  C++ `mode()` is still none (it is set at `start_host`), while the Lua srv layer answers from `coop_srv_mode.on_game_start`
  on.

### Server parts in `coop_quests_core` (S4, A-S4ML; accepted by the lead 2026-11-19)

`coop_quests_core.set_part(name, t)` / `part(name)` (`far`, `levels`, `brain`, `audience`, and `talk` = `{ partner(peer) }`
given by `coop_srv_tasks` on every world server: the id of the NPC the player talks to, false for nobody, nil when the engine
does not report it - A-S5T), `share_up` / `share_down` /
`share()` / `shared()` and `add_death_listener` / `death_listeners`: a server script puts itself there from inside
`when_srv`; without a part the Core caller gives the co-op answer. This is the one sanctioned way the Core reaches the
renamed server scripts. Rules: `set_part` is called only inside `when_srv` (L9 catches it at load); the Core never uses a
part's presence as a mode test (`part("far") ~= nil` for "am I a server") - ask `coop_mode` instead; call the part's own
function and use its answer. Guard round 8 catches the misuse as L1 when the part is asked through `coop_quests_core.part`
in an `if` / `and` / `or` / a comparison with nil; it does not yet see it through a local or a getter field (round 9, review
of guard-8 item 2).

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

When they run, per process (A-S4D):
- world server (`-coop_dedicated`): at load, in axr_main's loop of `on_game_start` — the functions of the srv scripts named
  before `coop_srv_mode` when it installs the layer, the others in their own `on_game_start`. That is before the save's
  `load_state` and before the session: a `load_state` handler registered there gets the save, so it must not drop it on a
  session check (`is_active()` / `is_host()` are false until the session starts). `coop_srv_scorcher` checks
  `is_dedicated()` too; it and `coop_srv_task_audience` also read `alife_storage_manager.get_state()` inside `when_srv`
  for a save loaded before the layer answered. A function that sets something up at the actor's first update runs at the
  real first update there; the world's session normally starts before it, but not when the session start is refused and
  retried (a busy port): such a function must not rely on the session either.
- map server and server player: as soon as their session (and on a player's machine its first LevelMap or Welcome) makes
  the layer answer — at load for a map server.

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

## 7. The S6 answers (A-S6-IF, build 57, 2026-11-20)

The answers the S6 groups ask (`temp/b58/s6_map/README.md`, "New answers this map needs"). Frozen names: the C++ members and
types below, the Lua calls `hook`, `facts_of`, `far`, `share_up`, `share_down`, the layer fields `hook`, `facts_of`, `far`,
and the hook names of 7.3. Each has an answer in every process kind; the tests: `tests/test_mode_s6_answers.cpp` (C++, one test
per kind: the fake's answers and the real mode's answer read from its source; none's runs), `tests/lua/test_mode_s6_facade.lua`
(Lua, one part per kind over the real layer scripts).

### 7.1 C++ (`engine/src/xrCoop/coop_mode.h`)

`Mode::level()` → `LevelSide*`: the side of a level that a process leads apart from its world. Only a map server has one
(`srv/coop_srv_mode.cpp` `MapLevelSide`); every other kind answers `nullptr` and the Core does the thing in its own books. The
Core asks `if (LevelSide* l = mode().level()) { l->...; } else { /* its own books */ }`. Ids are this process's numbering.

| hook | `LevelSide` member | the map server's answer (the function it replaces) |
|---|---|---|
| H-MONEY | `level_money_change(peer, delta, trade)` | `levels::up_money` first (a change of 0 asks the world for his balance), then its kept balance (never below 0; a change of 0 keeps no entry) — `coop_money.cpp` `host_adjust` / `host_send_balance` |
| | `level_balance(peer, out)` → bool | the kept balance; false and 0 when the world named none — `host_balance`, `l_money_of` |
| | `level_balance_heard(peer, balance)` | the world's word (`coop_trunk.cpp` `money::server_balance`) |
| H-ITEMTELL | `level_item_tell(id, section, blob)` | `items::level_item_tell` (the Core's ItemState to its players; never route that function back through this one) |
| H-TENT | `level_tent_limit(world_tents, limit)` → bool | `world_tents >= limit` (the Core counts `world_tents_of(key)`: the limit is counted in the world copy) |
| | `level_tent_placed(tent, character)` | `levels::up_tent` (the Core skips `host_set` and the `placed` callback) |
| | `level_tent_packed(tent)` → bool | true: the world's sweep rolls the camp back (the Core skips `host_source_lost`) |
| | `level_in_world(character)` → bool | `join::host_player_in_world` |
| H-DEATHMARK | `level_marker(m)` | the `coop_death_marker` Lua callback with `m` as it is (`map_server_marker`) |
| H-TRUNKPEER | `level_character_of(peer)` → id / 0xffff; `level_peer_of(character)` → peer / kInvalidPeer | `mapserver::trunk_peers().on()` |
| H-ENTITYUP | `level_entity_up(EntityUp kind, id, other)` | Spawned `levels::up_spawned(id)`, Released `levels::xfer_on_released(id)`, Parent `levels::up_parent(id, other)`, Died `levels::up_died(id, other)`; the ALife's thread may call it |

`Mode` members (a "not mine" answer by default, which `NoneMode` keeps; every mode of the two layers writes its own):

| member | none (default) | co-op host | co-op client | world server | map server | server player |
|---|---|---|---|---|---|---|
| `level()` | nullptr | nullptr | nullptr | nullptr | its `MapLevelSide` | nullptr |
| H-REACH `reaches(peer, type)` | true | true | true | `levels::passes_to(type, peer)` | `levels::passes_to` (true for its peers) | true |
| `deliver_links(type, payload, lane)` (A-S5S) | nothing | the host player's link | nothing | the bridges that take `type` (queued while one loads) | its link up to the world | nothing |
| P-B `led_elsewhere(peer)` | false | false | false | the map server of his map is connected | false | false |
| P-B `to_level_of(peer, type, payload, lane)` → sent | false | false | false | to that map server's bridge: true; none: false | false | false |
| H-JOIN `join_from_bridge(from, type)` | false | false | false | `mapserver::is_bridge(from)` | false | false |
| H-JOIN `join_save(from, proxy)` | false | false | false | split and his map not its own: the place to his map's server if it is there, true | false | false |
| H-JOIN `level_ready(level)` | true | true | true | `mapserver::host_ready(level)` | true | true |
| H-JOIN `on_world_live()` | nothing | nothing | nothing | nothing | `world::host_scan_proxies()` | nothing |
| H-LOADTEXT `load_text(screen_level, world_up)` | nullptr | nullptr | nullptr | nullptr | `"st_coop_load_server"` when `!world_up` and the level is not the world server's | the same |
| H-GHOSTSAID `ghost_said(s)` | false | false | false | false | `ghost::about_actor(s)` | false |

`group_travels()` (README row): already a `Mode` answer since S4. The client rows of `where()`: already answered (co-op
client Here, a server player's peer 0 Away).

The process's hooks (`Layer`, asked through the switchboard `coop::place_ghost(objects)` / `coop::console_line(line)` of
`coop_mode.cpp`, the server's layer first): the world server loads its world and has its console **before its session**,
when `mode()` is still none, so these two are not `Mode` members.

| hook | the server's layer | the co-op's layer, none |
|---|---|---|
| H-JOIN `place_ghost(objects)` → taken | a map server loading its world: the ghost at its key's vertex (a world without that place stops the session; true either way); `-coop_dedicated`: `dedicated::place_ghost` (FATAL without a service level), true | false (the Core's role swap) |
| H-SAY `console_line(line)` | `-coop_dedicated`: the window gets the line its log level hides, the running operator's command gets it back | nothing |

### 7.2 Lua (`coop_mode.*`)

| call | co-op host / client | world server (from `coop_srv_mode.on_game_start`) | map server | server player | none |
|---|---|---|---|---|---|
| F-HOOK `hook(name)` → function / nil | nil | the server's function (7.3) | same | same | nil |
| F-BODY `facts_of(peer)` → `{ talking, partner }` / nil | nil | `talking` = `coop.levels.talking(peer)` (nil: the engine lacks it), `partner` = `coop.levels.talk_partner(peer)` or false (nil: the engine lacks it) | nil | nil | nil |
| F-FAR `far()` → view | the stub | `coop_srv_quests_far` (a function it lacks: the stub's) | same | same | the stub |
| F-SHARE `share_up` / `share_down(name, get, set[, every])` → kept | kept by `coop_quests_core`, carried by nobody | kept, carried by `coop_srv_levels_share` | same | same | kept |

- `facts_of` is F-BODY under its C++ twin's name: `body_facts` is an L1 word of the guard in a Core Lua line. A caller writes
  `local f = coop_mode.facts_of(peer); return f == nil or f.talking ~= false` where it read `l.talking(peer)` before.
  `talking` is a boolean or nil, `partner` a whole id 1..65534, false or nil; anything else from a layer is dropped.
- `hook(name)`: ask it when the function is needed, never keep it at load (on a map server and a server player the srv layer
  answers only in the session). A layer answer that is not a function or nil is logged (`! hook answer`) and nil.
- `far()` always returns a table with `in_scope() → nil`, `level_of_id() → nil`, `order() → false`, `fallback() → nil`,
  `with_level_of(peer, fn, ...)`, `with_target(id, peer, what, fn, ...)`, `at_home(fn, ...)` → `fn(...)`, `object() → nil`,
  `note_fail`, `print_status` (nothing) and `add_death_listener(callback, f)`. The stub's `add_death_listener` keeps `f` in
  `coop_quests_core` (where the server's death relay reads it, whenever its layer comes to answer) and registers nothing
  stock: the caller registers its stock callback itself, as today. (The README's "= RegisterScriptCallback" is not taken: the
  callers keep their own registration, which would then run twice in the co-op, and the server's view keeps the relay list
  only, so a map server would lose its stock callback if the caller dropped its own.)
- `share_up` / `share_down` keep the table in every process because a map server's scripts register at `on_game_start`,
  before its layer answers. False: a name that is not a non-empty string, `get` / `set` not functions, `every` not a number >= 0.
- Layer fields `hook(name)`, `facts_of(peer)`, `far()` are optional: a layer without them (the test sets of
  `tests/lua/support/mode_*.lua`) is answered as none answers.

### 7.3 The hook names (F-HOOK)

| name | the srv answer | was |
|---|---|---|
| `storyline.may_take` | `coop_srv_storyline.may_take` | `coop_storyline.may_take` |
| `storyline.client_may_write` | `coop_srv_storyline.client_may_write` | |
| `task_audience.sees_character` | `coop_srv_task_audience.sees_character` | `coop_task_audience` |
| `brain.caches_now` | `coop_srv_levels_brain.caches_now` | `coop_levels_brain` |
| `world.creator` | `coop_game_settings.creator` (Core since A-S4D) | `coop_dedicated.creator` |
| `levels.elsewhere_text` | `coop_srv_levels.elsewhere_text` | `coop_levels` |
| `levels.far_place` | `coop.levels.far_place` | `api.levels.far_place` |
| `levels.module` | a function that returns the module `coop_srv_levels` | `rawget(_G, "coop_levels")` |
| `levels.level_of_player` | `coop.levels.level_of_player` | `coop.levels.level_of_player` |
| `levels.bridge_of_player` | `coop.levels.bridge_of_player` | new (B-REV F5; Core caller `coop_mods_xchg_nimble`) |
| `context` | a function → `{ role = "mapserver" / "host" / "client", split = true }` | `coop_main` `context_now` |

A function is looked up when it is asked: nil when its script or function is not there. A hook name in a Core line is a
string argument: the guard reads no string, so `coop_mode.hook("levels.level_of_player")` is no L1.

**Добавлено интегратором C (сборка 57).**

- LevelSide H-FIGHTREP `level_fight_reputation(character, delta)`: сервер карты отправляет FactMsg наверх как Relation op 17; никто другой на его карте — ничего.
- Mode H-OPCMD `send_operator_command(line)`: none, хост и клиент кооп-режима, сервер мира и сервер карты отвечают Unreachable; игрок сервера — Refused при `!op::allowed`, иначе Sent или Unreachable от сессии.
- Mode VEH-DISC `departure(peer, character)` → `Departure`: none, хост и клиент кооп-режима, сервер мира и игрок сервера отвечают Disconnected; сервер карты — `mapserver::departure_of`: что сказал `LevelMap` мира, когда ушёл его виртуальный узел (нет строки — Disconnected, строка на другой карте — LeftLevel, строка на этой — Replaced; без записи — Disconnected). Ядро спрашивает только пира, которого нет в сессии (`session_facts`).
- Layer `join_request(address, via)`: слой Коопа возвращает приглашение Steam; слой Сервера и none — false.
