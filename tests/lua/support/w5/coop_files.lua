COOP_FILES = {
	"coop_client_binders", -- W10: object binders on a client
	"coop_core_chat",
	"coop_core_hud",
	"coop_core_player",
	"coop_core_world",
	"coop_economy_core",
	"coop_economy_give", -- "give how many": the amount window and the split of a box (owner 2026-11-07)
	"coop_economy_group",
	"coop_economy_intent",
	"coop_economy_mdata",
	"coop_economy_money",
	"coop_economy_travel",
	"coop_economy_world",
	"coop_game_record", -- game settings (T4): the catalog and the record are read at run time (coop_settings.rule)
	"coop_game_schema",
	"coop_game_settings", -- the host's game: the record, its callbacks and the save wrapper
	"coop_hostplay_mode", -- S4: the co-op layer of the facade coop_mode
	"coop_main",
	"coop_menu",
	"coop_menu_char",
	"coop_menu_options",
	"coop_mode", -- S4: the mode facade (Core)
	"coop_mods_core",
	"coop_bounty", -- G18-3: bounty squads per character
	"coop_mods_guard", -- B3 review round 1: client guards of mod item paths
	"coop_mods_hf",
	"coop_mods_items",
	"coop_mods_mags",
	"coop_mods_misc",
	"coop_mods_nta",
	"coop_mods_pdata",
	"coop_mods_perks",
	"coop_mods_radio",
	"coop_mods_ammo", -- a client merges its own ammo packs as the host does (complaint 5, build 54)
	"coop_mods_speed", -- movement speed diagnostic, one line per 30 s when it changed (complaint 4, build 54)
	"coop_npc_combat", -- W11: combat_ignore / danger / wounded for every player
	"coop_npc_companions",
	"coop_npc_compat",
	"coop_npc_disguise",
	"coop_npc_effects",
	"coop_npc_logic",
	"coop_npc_meet",
	"coop_npc_players",
	"coop_npc_world",
	"coop_npc_idiots", -- W8: Useful Idiots package searcher (file scope only)
	"coop_quests_core",
	"coop_quests_missions", -- mission audits: dialog actions on the host for a client, a status functor's kill, tissue samples
	"coop_quests_offer",
	"coop_quests_party",
	"coop_quests_pda",
	"coop_quests_scenes",
	"coop_quests_story",
	"coop_route", -- F2 T10: the callback router shim
	"coop_settings",
	"coop_srv_mode", -- S4: the server layer of the facade coop_mode
	"coop_tasks",
	"coop_ui",
	"modxml_coop_menu",
}
