# The PDA per player: every player sees his own data

Owner 2026-11-16 (build 51, a client of a host who plays, world faction bandit): the ranking list of the "Statistics" tab
appeared on his machine only after the HOST opened its PDA, and his own row there said "Duty". "Go through the whole PDA like
this, so that everybody has his own everything."

Sources: `C/` = the owner's GAMMA scripts as copied to `temp\review\corpus\merged\` (winning files), `S/` = stock Anomaly
(`anomaly-ref\unpacked\scripts`), `E/` = `engine\src`. Routes: `gamedata\configs\coop_route*.ltx` and `coop_compat_*.ltx`
(`coop_route.ltx` header: actor_* callbacks run everywhere, npc_*/monster_*/save_state on the host only).

The facts every tab shares:
- A client loads the host's save at every join and level change. Whatever a script keeps "about the player" in m_data, pstor
  or module locals is the host's there, unless a per-player channel carries it (`coop_core_player` game_statistics,
  `coop_economy_mdata` MANIFEST, `coop_mods_pdata` keys).
- Info portions are group story (`E/xrGame/coop/coop_story.cpp` on_info 3060-3110), except the "machine" ones
  (`E/xrCoop/coop_rules.h` 14-40: `ui_pda`, `actor_is_sleeping`, `sleep_active`, `ui_talk*`, `*_wnd_open`). **`ui_pda_hide` is
  not a machine info**, its pair `ui_pda` is. This matters for every tab that asks "is the PDA open" (see R1).

## Tab by tab

| Tab | What it shows / where it comes from | Filled where today | What a client sees today | Status |
|---|---|---|---|---|
| Карта (map) | Engine map spots (`Level().MapManager()`); primary objects and sleep zones `C/pda.script` 389-431 (`fill_primary_objects`, from `bind_stalker` first update), discovery `C/pda.script` 654-673 (`discover_spots`: `give_info(target)` + `game_statistics.increment_rank(10)`); task spots; player arrows (`coop_allies`, `coop_hud_markers`) | `pda` = view (`coop_route.ltx` 91): runs on each machine; the infos it gives are group story (coop_story pushes them); task spots by `coop_story` (MapSpot, TaskUpdate) | The group's discovered places and tasks (shared by design), his own +10 rank per discovery on his own actor, the players' arrows | OK, group by design |
| Объявления (taskboard) | `pda_taskboard` / `ui_pda_taskboard_tab`: the offers of nearby NPCs (`axr_task_manager.available_tasks`, host data) | `pda_taskboard` = view (`coop_route_quests.ltx` 9); offers asked of the host by `coop_quests_offer.script` 539-570 (patch_taskboard: OnBtnRefreshClicked -> request_offers) | The host's offers for the NPCs near HIM, taken as his own tasks | OK (coop_quests_offer) |
| Статистика, left block | `C/pda.script` 139-180 `get_stat(i)`, called by `E/xrGame/ui/UIRankingWnd.cpp` 226-246 every update | per index, below | per index, below | see "Statistics left block" |
| Статистика, ranking list | `C/pda.script` 470-501 `calculate_rankings` (host ALife), 509-644 `coc_rankings_*` (read by `UIRankingsCoC.cpp` 48-110); client: `coop_quests_pda.script` 54-247 asks the host (quests.rank_req -> host_on_rank_req) | Request sent only from the "ui_pda" info callback (`coop_world_compat.script` 67-75); rows gated by `has_alife_info("ui_pda_hide")` (`C/pda.script` 510, `coop_quests_pda.script` 188) | Before: nothing until the host opened its PDA; then the stock list of his frozen ALife copy (own row = the join save's server object 0: stale faction/rank/reputation) or the host's list | **Fixed (R1)** |
| Отношения (relations) | `S/ui_pda_relations_tab.script` 28, 319-346: `get_actor_true_community()`, `relation_registry.community_goodwill(faction, AC_ID)` | Personal goodwill per character from the host (`coop_story` Relation), the cells/legend by `coop_trader_pda.script` (personal + group numbers) | His own goodwill, the world's faction relations | OK (coop_trader_pda, coop_story) |
| Контакты (contacts) | `S/ui_pda_contacts_tab.script` 117-154: online stalkers near him (`db.OnlineStalkers`, his own level objects); "show all" filter `m_data.actor_contacts` (written by `C/pda.script` 106-109 when a talk opens); the hint numbers from `m_data.se_object[id]` (207-226) | `actor_contacts`: view, on the talking machine, but m_data is the host's save on a client and a client never saves; hint numbers published by `coop_npc_stats.script` | Before: "show all" = the HOST's contacts + his own of this level only (lost at a level change). NPC hint numbers: the host's live ones (coop_npc_stats) | **Fixed (C1)**: `actor_contacts` per player |
| Справочник (encyclopedia) | `C/ui_pda_encyclopedia_tab(_varefined).script`: unlocked articles / notes | `coop_quests_pda.script` 16-19, 426-630: one player's unlock is unlocked for everybody | The group's articles (shared by design, owner decision of W4) | OK, group by design |
| Радио | `S/ui_pda_radio_tab.script` Zone FM; RF receiver (`item_radio`) | `coop_mods_radio.script`: the host's channel clock and RF sources; the tuned frequency `RF_freq` is his own (`coop_economy_mdata` MANIFEST) | The host's station/track, his own frequency | OK |
| Сообщения (news log, NPC PDAs) | Engine news log (`CUILogsWnd`, the actor's news); NPC PDA messages `ui_pda_npc_tab` | News per machine (`E/xrGame/actor_communication.cpp` 41 `client_news_added`, `docs\MESSAGES.md`); NPC PDA messages generated by the host and sent (`coop_quests_pda.script` 250-420) | His own news; the host's NPC PDA messages for loot he holds | OK |

### Statistics left block (`C/pda.script` 139-180)

The counters are `game_statistics.actor_statistics`, carried per player by `coop_core_player.script` 35-39, 186-196 (key
`game_statistics` through `coop_mods_pdata`; achievements stay the group's). So the numbers on a client are his own record, and
the question is only who increments them:

| i | Row | Incremented by | Runs on | A client's own number |
|---|---|---|---|---|
| 0 | time in the Zone | `level.get_start_time()` vs game time | everywhere | the world's (same for all), fine |
| 1 | emissions | `C/surge_manager.script` 317, 331 (`end_surge`) | host; a client's mirror also calls `end_surge` (`coop_main.script` 625-633) | counted on his machine by the mirror: probably right, **live check** |
| 2 | tasks completed | `coop_tasks.script` 118-120 TASK_STATS (the turning-in character) | host decides, the finisher's statistics | his own |
| 3 | monsters killed | `C/bind_monster.script` 202-206 death_callback: `who:id() == AC_ID` -> actor, else `increment_npc_statistic(who)` | host binder; on a client the binder method runs too (`coop_route_binders.ltx` 76, guard) | unclear: on the host his kill counts into his AVATAR's NPC stats; whether his own machine sees `who` = its actor is a **live check** (plan K1) |
| 4 | stalkers killed | `C/game_statistics.script` 194-219 `npc_on_death_callback` | host only (npc_*) | **wrong**: his kills go to his avatar's NPC stats on the host (`increment_npc_statistic`, 216-217), never to his own counter (plan K1) |
| 5 | boxes smashed, 6 stashes found | stock item/box callbacks (actor_*), `coop_core_world.script` 1086 (stash on a client) | owner | his own |
| 7 | psi storms | `C/psi_storm_manager.script` 170, 195 | host; the client mirror calls `finish` (`coop_main.script` 475) | as emissions, **live check** |
| 8 | PDAs delivered, 11 wounded helped | `C/dialogs.script` 973, 1192, 1309 (dialog effects) | the talking player's machine (`dialogs` = host route covers only its registered callbacks; dialog functions run where the dialog runs) | his own, **live check** |
| 9 | helicopters downed | `coop_reputation.script` 181-200 (award of the responsible player) | host -> the player | his own |
| 10 | artefacts detected, artefacts found | `C/game_statistics.script` 161-191 `actor_on_item_take` | owner (his own take) | his own |
| 12 | level changes | `game_statistics.on_level_changing` 266-268 | owner | his own |
| 13-14 | surrenders, field dressings | dialogs / `ui_mutant_loot` 469 | his machine | his own |
| 15 | encyclopedia | `ui_pda_encyclopedia_tab.get_articles_unlocked_count()` | group-shared unlocks | the group's, by design |
| 16 | achievements | `game_achievements` counts | group-shared (`coop_quests_pda` 20-26) | the group's, by design |
| 17 | visited levels | `game_statistics.actor_visited_levels` (coop_core_player sub) | owner | his own |
| 18 | money | `db.actor:money()` | the host ledger, his own balance | his own |

## Fixes done

### R1 - the ranking list asks by itself; no host PDA state; no stale own row (`coop_pda_rankings.script`)

Cause, proven:
1. The only request trigger on a client is the "ui_pda" info callback (`coop_world_compat.script` 67-75). The engine fires
   `actor_on_info_callback` only when the info is new (`E/xrGame/inventory_owner_info.cpp` 52-57). On a client nothing takes
   `ui_pda` away: the stock removes it from the callback of `ui_pda_hide` (`S/info_portions.script` 18, host route
   `coop_route_stock.ltx` 54; `C/item_device.script` 175-180), and `ui_pda_hide` is group story, already in the client's copy, so
   giving it there changes nothing and fires nothing (`coop_story.cpp` 3066-3067). One open (or `ui_pda` in the join save) and the
   client never asked again.
2. The rows hide while `ui_pda_hide` is known (`C/pda.script` 510, `coop_quests_pda.script` 188). On a client that info goes
   away only while the HOST's PDA is open: the host's `ui_pda` callback disables it (`S/info_portions.script` 17, item_device
   174) and coop_story pushes that to everybody (`coop_story.cpp` 3069-3076). Hence "appears only when the host opens it".
3. Before the host's answer the client drew the stock list of its frozen ALife copy; its own row there is server object 0 of
   the join save (`C/pda.script` 585-604: `se_obj:community()`, `rank()`, `reputation()`), which is not his live character - the
   most likely source of "Duty" in his row (the cached path already used his own character, `coop_quests_pda.script` 144-148).
   The engine writes a row's text only when it adds the row (`E/xrGame/ui/UIRankingsCoC.cpp` 56-98), so stock rows stayed on
   screen after the host's answer came.

Rule now (live client only; host and single player run the stock code):
- `pda.coc_rankings_can_show` (called by the window on Show and every 3 s) asks the host itself: the first pass after a pause
  of 4.5 s (the tab was closed) at once, an open tab every 30 s. The request is coop_quests_pda's own `quests.rank_req` (the host
  answers the sender's peer only; the client names only its rank).
- The rows are asked with `ui_pda_hide` unknown (the host's PDA state is not this machine's).
- No row before the host's answer (no stock list of the frozen copy, no stale own row). After a newer answer one pass hides
  every row, the next writes them with the new text. The own row is coop_quests_pda's `own_entry()`: his own character's
  name, community, rank and reputation.
- An answer counts only from peer 0 (`from` given by the engine).

Test: `tests\lua\test_pda_rankings.lua` (20 checks). Red before (13 failed, the fix switched off with
`COOP_PDA_RANKINGS_OFF=1`): no request without the ui_pda callback, rows gated by `ui_pda_hide`, stale own row.

### C1 - contacts talked to are the player's own (`coop_pda_player.script`)

`m_data.actor_contacts` is registered with `coop_mods_pdata.register("actor_contacts", {})`: the host keeps each player's list in
its save, a client gets his own back before any load_state, a new player starts with none. Test:
`tests\lua\test_pda_player.lua` (4 checks; red before: the host's list on a new client, nothing reported, the host's list
after a level change). Note: the keys are object ids of the world; they are the same on the host and the client except the
swapped player ids, which are never contacts.

## Planned (not done here)

- **P1 - `ui_pda_hide` as a machine info (engine).** Today a client closing his PDA asks the host to give `ui_pda_hide`
  (`coop_story.cpp` 3097-3110); the host gives it to ITS actor and its callbacks run there: `info_portions` disables the host's
  own `ui_pda` and `item_device` sets the host's `pda_active = false` while the host may have its PDA open (fluid_aim,
  lower_weapon_sprint, z_beefs_nvgs read `ui_pda`). Fix: add `ui_pda_hide` to `kExact` of `E/xrCoop/coop_rules.h` 29 (and the
  Lua copy `coop_parity.script` 188), with a native test. Then each machine's pair `ui_pda`/`ui_pda_hide` is its own, the client's
  `item_device` callback clears its `ui_pda`, and `coop_world_compat`'s trigger works again on every open. Engine change: not in
  this task's files.
- **K1 - a client's kills.** `npc_on_death_callback` (host only) counts a client's kill into his avatar's NPC stats
  (`C/game_statistics.script` 212-217); `bind_monster` the same (202-206). Design: in a host-side wrapper of
  `game_statistics.increment_npc_statistic`, when `npc` is a player's avatar (`coop_npc_players.peer_of`), send that peer
  `pda.stat { k = <name> }` with `k` from a fixed allow-list (`killed_stalkers`, `killed_stalkers_f/e/n`, `killed_monsters`); the
  client calls `game_statistics.increment_statistic(k)` on its own actor only for a message from peer 0, and the host skips the
  avatar's own NPC counter. Open question for a live check: rank/reputation side effects of `increment_statistic` on the client
  versus the host's own rank bookkeeping of that kill (coop_story Progress), so they are not counted twice. Then remove the
  double count on the monster binder if the client's binder already counts (live log of `killed_monsters` on both machines).
- **E1 - emissions / psi storms / dialog counters: live check only.** Read rows 1, 7, 8, 11 on a client after a surge, a psi
  storm, a PDA delivery and a wounded-help dialog; if they do not move, count them where the client mirror ends the phase
  (`coop_main.script` client_env_tick -> end_surge / finish).
- **R2 - the host's list cost.** `host_on_rank_req` walks the whole ALife twice per request (`coop_quests_pda.script` 58, 91-98).
  With R1 a client with the tab open asks every 30 s. If the host stutters, cache the host's answer for 10 s for all peers (only
  `place` depends on the requester).
