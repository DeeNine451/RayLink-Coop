# A task's audience: who sees a task in a split-levels world

Owner 2026-11-16. In worlds with split levels players may be in different factions. The journal was one for the whole group.
New rule, split-levels worlds only (a world without split levels behaves exactly as before):

- **Side tasks: by relations, the game's own sum.** A task that player P took from giver G is not shown to a player X for whom
  G's faction is an enemy: `relation_registry.community_relation(faction of G, true faction of X) +
  relation_registry.community_goodwill(faction of G, character of X) <= game_relations.ENEMIES` (-1000;
  stock `game_relations.script:34-36, 603`). A "trader" giver is mapped as the stock maps it (`dialogs.script:105-112`: the squad's
  `player_id`, then "trader" -> "stalker"). A task with no giver, or a giver that cannot be resolved, is shown to everybody.
  P always sees his own task.
- **Storyline tasks: strictly by faction.** `drx_sl_*` (not the change-faction ones) and `lttz_*`: only players whose true faction
  is the taker's. A change-faction task (`drx_sl_*_cf_task_*`): the taker alone, and only he turns it in.
- **"Not shown"** for a player: not in his PDA list, no map mark of the task, no message about it (taken / updated / completed /
  failed), no share of its money, items, goodwill, reputation or statistics, no turn-in and no cancel.
- **Decided once, when the task is given, per CHARACTER, and kept for the task's life.** A later change of goodwill re-judges
  nothing. A player who joins later is judged at his join for the tasks that exist then. A faction change of a player re-judges
  only the storyline tasks for him (in if the task's faction is his new one).

Contract of the faction side (`gamedata/scripts/coop_faction.script`, on the authority = the process where `coop.is_host()` is
true): `coop_faction.split_mode()`, `coop_faction.faction_of(peer)`, `coop_faction.faction_of_character(id)`, script callback
`coop_faction_changed(peer, character_id, old, new)`.

Design by a read-only study of 2026-11-16 (CT = `gamedata/scripts/coop_tasks.script`, CS = `engine/src/xrGame/coop/coop_story.cpp`;
line numbers of that day).

## Why Lua alone cannot hide a task

1. The engine mirrors the host's task list to every client: `host_scan_tasks` broadcasts a `TaskUpsert` per changed task
   (CS:545-577, `net::host_broadcast` at CS:574). A client that lacks a recorded task gets it back at the next drift check:
   `client_on_hash` runs `client_reconcile` ("lost here: bring it back", CS:1280-1307, 1294-1298).
2. The drift check is ONE broadcast hash over every non-local task of the host every 10 s (`host_hash_frame` CS:2399-2424,
   `hash_tasks` CS:518-527). A client that marks the id local (`coop.story_local_task`, CS:3301-3321) never matches it: a resync
   request about once a minute for ever, and the mark is process-wide.
3. Turn-in, cancel and stage requests are not checked for who asks (CT:972-1001, CS:1059-1090); rewards and goodwill count
   every player (CT:1308-1325). Those can only be fixed on the host.
4. The host player of a LISTEN world server (peer 0) reads the authority's own `CGameTaskManager`: nothing on a wire hides a task
   from him (`TaskUpdate` / `TaskList` / `StoryHash` are not link messages, `engine/src/xrCoop/coop_local_link.h:66-84`).
   Phase 2, see the end.

## The design

**Core rule: a task with no audience entry behaves as today, byte for byte.** Without split levels no entry is ever made.

### A. The decision (host Lua, new `gamedata/scripts/coop_task_audience.script`)

A new module: `coop_tasks.script` is at Lua's limit of 200 file-level locals.

`aud[id] = { kind = "side" | "story" | "cf", gf = giver faction | nil, sf = story faction, taker = character,
             inn = { [character] = true }, out = { [character] = true } }`

- Classify by id: `drx_sl_*_cf_task_*` -> "cf"; other `drx_sl_*` and `lttz_*` -> "story" (`sf` = the taker's true faction);
  anything else -> "side"; a side task without a resolvable giver gets NO record.
- Judge a character C: the taker is in; story: in iff `faction_of_character(C) == sf`; cf: only the taker; side: out iff the
  sum above is <= -1000.
- When: inside the patched `give_task` on the host (CT:2912), BEFORE the stock give runs (CT:2936): the taker is known
  (CT:2919-2923), the giver is the argument. Every current character is judged (`participant_ids()` and the reward group's
  members, so players who are away are judged too). The result is pushed to the engine before the give, so the first
  `TaskUpsert` is already filtered. A re-give of the same id recomputes the record.
- A finished task KEEPS its record and its engine entry (review of 2026-11-16: the engine keeps a finished task in the journal
  for ever, so dropping the entry at the end showed the finished task to everybody). The record is marked finished, saved,
  pushed again after a load, and nobody is judged into it later. At most 2000 finished records are kept; the oldest go first
  and their tasks then become visible.
- Persistence: with the world's save (the module's own save_state / load_state). After a load everything is pushed to the engine
  again on the first host tick (the engine's table is cleared in `story::reset`, CS:2821). Character ids are the host's own.
- Late joiner: at his `coop_tl_req` (CT:3218) a character in neither `inn` nor `out` of a task is judged, stored, pushed, and
  the engine re-sends his task list. The engine treats an unjudged character as OUT for a task that has an audience.
- Faction change (`coop_faction_changed`): only "story" records are re-judged for that character; push; re-send his list.

Giver's faction, offline-safe (`se = alife_object(id)`): a stalker: `se:community()`; a squad (`se.commander_id`): `se.player_id`,
else the commander's community; "trader": the stock mapping; "monster", unknown, no object: no record, one log line. The giver
reaches the patched `give_task` as its second argument on every path (a dialog on the host `dialogs.script:676-680`; a client's
dialog `client_give` CT:2452-2485 -> `ops.give` CT:923-970; the engine path CS:1016-1057); DRX gives pass the squad id
(`dialogs.script:440-443, 468-471`); a script's give has no giver.

### B. The engine (no message layout changes; only who gets a message)

1. New `engine/src/xrCoop/coop_task_audience.h` (header-only, pure C++17 as its neighbours, unit-testable):
   an audience per task id (a set of character ids) and `allowed(audience or none, character, is_bridge)`:
   no entry -> true; a bridge (a map server, peer >= 0x100) -> true; else membership.
2. CS: the table, cleared in `reset()`; `may_see(peer, task id)`: character 0 for the host peer, else the peer's avatar; no
   avatar yet -> out.
3. `host_scan_tasks` (CS:574): while the table is empty keep `host_broadcast`; a task WITH an entry goes by `host_send` to each
   joined peer that may see it and to each bridge; a task without an entry keeps the broadcast.
4. `send_task_list(to)` (CS:888-904), `send_task_to` (CS:868), `send_targets_to`: skip what the peer may not see.
5. `host_hash_frame` (CS:2412-2422): while the table is empty keep the one broadcast; else per peer, the tasks domain from
   `hash_tasks_for(peer)` (as CS:518-527 plus `may_see`); a bridge gets the unfiltered hash. The client side is unchanged.
6. `host_on_task_give` (CS:1028-1031): a running task the requester may not see: send nothing. `host_on_task_state`
   (CS:1068-1081): a requester who may not see it: no action.
7. Lua bindings in `coop_script.cpp` beside `l_story_local_task`:
   - `coop.story_task_audience(id, { character, ... } | nil) -> bool` (nil removes the entry);
   - `coop.story_resend_tasks(peer) -> bool` (flush, then the full tasks domain to that peer).
   Declared in `coop_story.h`, listed in `tests/lua_exports.txt`.
8. Protocol: unchanged (32). Old and new builds of this release cycle do not mix anyway.

### C. Host Lua (`coop_tasks.script`), every change only for an id that has a record

1. `host_scan` (CT:718-729): `coop_tl` and removals per allowed peer and the bridges instead of -1; a player who is hidden from
   a task now gets its removal.
2. `host_list` / `host_full_sync` (CT:736-770): per-peer lists without what the peer may not see.
3. `news_out` (CT:2700-2722): `coop_tn` only to the allowed peers; `host_news` shows nothing locally when peer 0 is out.
4. `host_on_request` (CT:1017-1039): a player (not a bridge) who is out is refused: a give of a running id answers
   `{ i, d, r = 1 }`, anything else `{ i, d }`; turn-in and cancel only for those who are in (cf: the taker).
5. Rewards (`host_task_callback` CT:1305-1325, the capture at CT:2924-2926): `ctx.personal`, `ctx.group`, `online_peers()`,
   `participants`, `rep_party`, `failure_participants` are cut to `inn`; a recipient who is out is replaced by the taker.

### D. Client Lua: nothing. It only ever receives what it may see.

### E. Map servers

They take every task (they run logic for every task) and their requests are not gated; what they cause still goes through C.5.
Players on a map server's level get the story messages from the world server, so the per-peer filter covers them.

## Order of work

1. `coop_task_audience.h` + `tests/test_task_audience.cpp`.
2. CS, `coop_story.h`, `coop_script.cpp`, `tests/lua_exports.txt`.
3. `coop_task_audience.script` + `tests/lua/test_task_audience.lua`.
4. `coop_tasks.script` (C.1-C.5) + tests (`test_tasks.lua`, `test_tasks_sync.lua`, `test_messages.lua`, `test_reward_group.lua`,
   `test_reputation.lua`, `test_quests.lua` extended; the rest of the suite green).
5. Live: two clients of different factions in a split world.

## Known limits

- Phase 2, not in this plan: the host player of a listen world server (peer 0) needs a filter in the PDA, the active task and the
  map of the host process. A dedicated world server has no such player.
- One journal entry per task id: two players cannot hold the same id at once; an outsider asking for a running id is told
  "not given".
- The DRX storyline bookkeeping is one shared set of variables (CT:107-108, `dialogs.script:440-450`): two factions' chains
  collide whoever sees what. Its own plan follows.
- Map spots that task scripts place without an owner task (assault `red_location`, guider markers, CT:3042-3073) stay visible
  to everybody.

## Not determined by reading (check on the stand or while coding)

1. That the engine's avatar of a peer and Lua's character id of a peer are always the same id on the world server, across a
   reconnect too.
2. That `relation_registry.community_goodwill(faction, character)` on the world gives a client character's real goodwill when
   he is offline there or on a map server's level.
3. Whether Lua's `send(name, payload, -1)` reaches the bridges and whether `players()` lists them (`l_send_event`,
   `coop_script.cpp`).
4. The give path of the PDA task board (`coop_quests_offer.script:279-330`): whether the giver id is always set.
