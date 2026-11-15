# Storylines that do not cross (split-levels worlds) and the Brain Scorcher pilot

Owner 2026-11-16: with split levels players may be in different factions; "the storylines must not cross, each faction has its
own, the others do not see it"; later, opposite goals for hostile factions (his example: one side switches the Brain Scorcher
off, Monolith switches it on). A read-only study of that day; nothing here is built. Where G.A.M.M.A. has a script it wins;
`axr_task_manager.script`, `dialog_manager.script`, `_g.script`, `dialogs_lostzone.script` exist only in stock. Not decided yet:
whether the key of a chain is the FACTION or a GROUP of players (the owner is weighing groups); the mechanism is the same.

## Three findings that shape everything

1. **The chain's ending needs the Scorcher off.** `dialogs.drx_sl_is_endgame` (gamma `dialogs.script:156-164`): task count >=
   total AND `bar_deactivate_radar_done`. A Monolith chain that keeps the Scorcher on never ends unless the rule is per faction.
2. **A stock Monolith / Sin / Zombied new game starts with the Scorcher already off** (`ui_mm_faction_select.script:21-25`,
   `:210-222`: `bar_deactivate_radar_done`, the Miracle Machine and generators "off" infos). Stock never has a Monolith player in
   a world where the Scorcher is on; the psi zones hurt every actor (`rad_psy_zone_1.ltx` has no faction check).
3. **Stock already switches it back on**: `lttz_ms_protect_brain_scorcher` `on_fail = %-bar_deactivate_radar_done ...%`
   (`tm_lostzone_ms.ltx:371`). That restores only what re-reads the flag; logic that went to a terminal section stays off.

## 1. The state of a faction's own chain (DRX questlines)

- `axr_task_manager.drx_sl_main_honcho_table` (`:23-36`): faction -> start leader. **Two leaders are shared**: bandit and
  renegade both start at Sultan, killer and isg both at Dushman. `drx_sl_honchos_table` (`:38-85`): 25 leaders.
- Task ids, all in the one task manager (global): `drx_sl_<H>_meet_task_N` (`task_manager.ltx`, complete when
  `{-drx_sl_meet_honcho_<H>}`), `drx_sl_<H>_task_N`, `drx_sl_<H>_default_task`, `drx_sl_<H>_cf_task_N` (`tm_*.ltx`),
  `drx_sl_find_wish_granter_task` (one id for the world, `task_manager.ltx:77-86`).
- `xr_effects.drx_sl_meet_random_honcho` (gamma `:700-779`): a random living leader that is not the current one and whose
  surrounding factions are not enemies of `alife():actor():community()` (`:724`); saves `drx_sl_current_honcho`, increments
  `drx_sl_current_task_number`, gives the info `drx_sl_meet_honcho_<H>` and the meet task.
- `setup_questlines(f)` (gamma `xr_effects:823-869`), `cancel_questlines` (`:871-900`: clears the five keys below, disables
  every `drx_sl_meet_honcho_*`, fails EVERY `drx_sl_*` task of `task_info`: all chains and all change-faction tasks).
- Dialog side (gamma `dialogs.script`): `drx_sl_set_finished_task_complete` (`:273-282`) calls `drx_sl_meet_random_honcho()` as a
  dialog action ON THE TALKING PLAYER'S MACHINE; `drx_sl_give_sl_task` (`:429-456`); `axr_task_manager.drx_sl_get_finished_task`
  (`:560-614`) scans every task with the leader's prefix, whoever's chain it is.
- Dialog XML (`gameplay/dialogs.xml`): 11 start dialogs gated by `<has_info>drx_sl_start_game_<H>`, 26 meet dialogs gated only
  by `<has_info>drx_sl_meet_honcho_<H>`, the change-faction dialog by `dont_has_info drx_sl_on_cf_task`.

Per chain (once per faction / group): pstor `drx_sl_total_task_number`, `drx_sl_current_task_number`, `drx_sl_current_honcho`,
`drx_sl_current_task`, `drx_sl_start_task`; infos `drx_sl_start_game_<H>`, `drx_sl_meet_honcho_<H>`,
`drx_sl_on_find_wish_granter`; which tasks belong to the chain (no stock record: must be added).
Per player: `drx_sl_on_cf_task` (today it locks the "join" dialog for everybody).
World fact (stays shared): `drx_sl_task_giver_<id>`, `drx_sl_hostage_giver_<id>`, `drx_sl_npc_stored_task_*`, `<task>_fetch`.

Co-op today: every `drx_sl_*` pstor key is host-owned and mirrored (`coop_tasks.script:100`, a client's `save_var` is routed to
the host `:3075-3088`); infos are the host actor's, a client's give is a request to the host. Nothing in `coop_*.script` touches
`drx_sl_meet_random_honcho`, `setup_questlines`, `cancel_questlines`, `get_finished_task`: they run wherever they are called.

## 2. Several chains at once

What Lua can redirect: `_G.load_var` / `_G.save_var` (global functions). What it cannot: ltx condlists
(`xr_logic.pick_section_from_condlist` calls the userdata's `has_info` / `give_info_portion`, stock `xr_logic.script:385-466`:
every `{-drx_sl_meet_honcho_X} complete` reads the raw name) and dialog `<has_info>` / `<dont_has_info>` (the engine,
`engine/src/xrGame/PhraseScript.cpp:40-64`, against `Actor()` of the machine the dialog runs on, which is the talking player's).

**So info names cannot be given a namespace. They are kept from colliding instead:**
- a **leader claim** on the host: `claim[H] = owner` while an owner's chain has `drx_sl_start_game_<H>` /
  `drx_sl_meet_honcho_<H>` set or a `drx_sl_<H>_*` task open; a co-op copy of `meet_random_honcho(owner)` (the stock body with
  the enemy test against the chain's faction and claimed leaders skipped); `setup_questlines` skips a claimed start leader
  (Sultan, Dushman) and goes straight to a meet task;
- **only the five per-chain pstor keys get a suffix** (`"<key>@<owner>"`), through wrappers of `_G.load_var` / `_G.save_var`
  active inside `with_chain(owner, fn, ...)`; the `drx_sl_` prefix stays, so the mirroring keeps working; a bare key of an old
  save becomes the world faction's;
- **the chain owner of a task** is recorded when it is given inside a scope (`drx_sl_owner@<task_id>`);
- host task callbacks (`drx_sl_meet_random_honcho`, `drx_sl_decrease_sl_tasks_count`, `drx_sl_find_wish_granter`,
  `stalker_ceasefire`) run under the owner of the task; a client's dialog actions that change the chain
  (`drx_sl_set_finished_task_complete`, `..._endgame`, `drx_sl_give_sl_task`) become one request to the host, "advance this
  chain", instead of changing mirrored state on the client;
- `cancel_chain(owner)` replaces `cancel_questlines` in split mode: only that owner's keys, leaders, tasks and claims;
- gates: DXML preconditions on the 26 meet and 11 start dialogs (true outside split mode; else only for the owner of that
  leader's claim), the finished-task lookup skips another owner's tasks, the change-faction lock becomes the player's own;
- the Wish Granter ending is one per world (one task id, one info, and the wish ends the world): the first chain that reaches
  it owns it.

Consequence for the "groups" idea: a leader stands in one chain at a time. Two owners that start at the same leader (two groups
of the same faction, or bandit / renegade, killer / isg) cannot both hold him: the second starts at a random free leader or waits.

## 3. The main stories (Living Legend, Mortal Sin, Operation Afterglow, Hollow Boundaries)

- LL can be started only by stalker, dolg, csky, ecolog, killer, freedom (`dialogs_lostzone_ll.xml:5-37` and five siblings); the
  start gives the global `living_legend`: **LL is already one per world.** MS and OA follow it for the same six; HB is ISG only.
- The middle dialogs (the Doctor `:421`, the Barkeep `:483`, Aslan `:532`, Beard `:697`, Strelok) have no faction condition: in
  co-op any player can advance somebody else's story today.
- World effects of LL (`tm_lostzone_ll.ltx`): squads made and removed (`:22`, `:96`, `:175-176`, `:249`, `:265`, `:296`, `:312`,
  `:328`), routes opened (`:38`, `:112`, `:127`, `:265`), the Scorcher off plus `stalker_ceasefire`, a relation change keyed to
  the completer's faction (`:113-114`, gamma `xr_effects:159-174`). MS: the Limansk war, routes, and fail states that switch the
  Miracle Machine and the Scorcher back on (`tm_lostzone_ms.ltx:352`, `:371`).
- **"Each faction its own copy" is not coherent** for them: one Strelok, one set of routes, one Scorcher.

Rule proposed: a main story is one per world, belongs to whoever started it (the host records the owner at the start dialog),
its tasks, marks and middle dialogs are shown only to the owner's side, its world effects are facts for everybody; one news line
per world-changing step for the others. For a Monolith player LL is a war on his own faction: say it to the owner.

## 4. The Brain Scorcher pilot

State: one info, `bar_deactivate_radar_done`, set by the X10 button (`bunker_primary_switcher.ltx:4-12`, the button ends in a
terminal section) and by the new-game script for Monolith / Sin / Zombied; removed only by MS `on_fail`.
- Re-read the flag (follow a switch back on by themselves): smart terrains' `spawn_num` (`jup_a6.ltx:18,22`, `pri_a15.ltx:14`,
  `pri_a16.ltx:16`, `pri_b36_smart_terrain.ltx:15`, two in the bunker), `sim_avail`, several dialogs, task condlists
  (`tm_radar.ltx:38`, `tm_lostzone_ll.ltx:114`), Fair Fast Travel (`game_fast_travel.script:196-202`, `:291-298`, `:690-694`),
  the chain's ending, co-op `coop_levels_together.ltx:14`.
- One-shot (logic that went to a terminal section, saved per object): the psi fields `rad_psy_zone_1/2/3/8.ltx`,
  `pri_psy_zone_1.ltx`, the antenna particles, the Radar sounds, the bunker restrictors, the button itself; irreversible:
  `bun_krovosos_nest_logic.ltx` (`kill_npc`), `bun_spawn_monolith_ambush.ltx` (`spawn_object`).

To switch it back on for real: make about 20 small logic files two-way (a reverse transition on `{-bar_deactivate_radar_done}`),
re-arm objects already saved in the dead state (`xr_logic.activate_by_section`), re-arm the button with conditions
(`ph_button` takes `on_press` as a condlist), give Monolith psi immunity while it is on (new: stock never needs it), and gate
every new transition by "a split-levels co-op world" so single player and group worlds stay stock.

The pair: "off" exists (`turn_off_brain_scorcher`, Sakharov, `tm_radar.ltx:27-38`; `lttz_ll_turn_off_brain_scorcher`). "On" is
new: a task given by Charon (`lider_monolith_haron`, already a task giver, gamma `tm_pripyat2.ltx:681-719`) to Monolith players
while the Scorcher is off; complete when the re-armed switch drops the info. Against endless flipping: a cooldown of three game
days after each flip and a cap (after the fourth flip the switch locks in its state for good and both tasks fail). The Monolith
chain's ending rule becomes "the Scorcher is ON". New content: 2 task sections, one dialog of 4-6 phrases, about 10 strings,
the ~20 logic files, a script of about 250 lines. No voice, no cutscene, no new spawns.

## 5. Stages and size (the study's estimate)

1. A faction change in split mode stops touching the world's chain. (Built 2026-11-16 in `coop_faction.script`, not committed.)
2. Chain namespace and claims: new `coop_storyline.script`, about 350 lines, about 120 checks.
3. Dialog gates: about 150 lines.
4. Main story ownership: about 120 lines.
5. The Scorcher pilot: about 250 Lua lines, about 20 ltx files, texts, and a run on the stand.
About 8-9 working days in all. Every wrapper is off unless the world has split levels; the DXML preconditions exist always
(the XML is built once per process) and return true elsewhere; single player installs nothing.

## 6. Not determined by reading

- When a client's mirror of the infos updates and what the world server's ghost holds (dialog gates, race windows): stand.
- Whether `alife():actor()` works on a client (the design avoids needing it).
- DXML: removing an existing `<dont_has_info>` node; DLTX overrides of `configs/scripts/**/*.ltx`.
- Whether a restrictor in the dead state keeps `db.storage` and `ini_filename` (needed to re-arm): stand.
- Whether a Monolith character can reach Pripyat by fast travel while the Scorcher is on; whether Charon talks to players.
