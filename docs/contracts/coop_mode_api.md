# coop_mode — the Lua mode facade, frozen API (A-S4L, W0)

Frozen 2026-11-18 18:48. After the W0 gate this file and the API it describes change only through the lead.
Source: `gamedata/scripts/coop_mode.script` (Core), `coop_hostplay_mode.script` (hostplay), `coop_srv_mode.script` (srv);
rules: `docs/MODES.md` sections 3-4. Works on today's engine (no new engine API).

Changed 2026-11-19 (A-S4D, the lead's option (a)): **the srv layer answers in a process started with `-coop_dedicated`
from the process's start**, before its session, not only in an active session. Before, a world server was answered by
"none" until its session started (after its world was up, `HostAutostart`), so `when_srv` ran there only after the world
and its save had loaded. What changed: the "Which layer answers" rule and the world server's role below; the world server
column now holds before its session too (row "before its session"); `publish` there sends nothing before the session;
section 4: on a world server `when_srv` functions run at load. Every other process is answered as before (a co-op host,
a co-op client, a map server and a server player before their session: "none"). The facade (`coop_mode.script`), the
hostplay layer and the answer sets of the tests did not change.

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
holds from the process's start (A-S4D): before its session the engine gives it no role (`is_host()` false), no seat
(`self_id()` -1) and no rows of `coop.players()`, and its answers do not depend on them:

| | co-op host | co-op client | world server (`-coop_dedicated`, from its start) | map server | server player | none |
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
- srv: `coop.is_dedicated()` (a process started with `-coop_dedicated`: the world server) from the process's start, before,
  during and after its session (A-S4D); or an active session and (`coop.is_map_server()` or `coop.levels.split()`). World
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
  C++ `mode()` is still none (it is set at `start_host`), while the Lua srv layer answers from the process's start.

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
