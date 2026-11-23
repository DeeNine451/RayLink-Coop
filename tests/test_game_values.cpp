// Anomaly Coop unit tests: the engine's part of "Game settings" that needs no engine (coop_game_values.h;
// docs/GAME_SETTINGS.md §1.2, §3.4, §3.5): the white list of the 18 game rules, the layer that sets them over the
// machine's console values and gives them back, the new game that waits in memory, and the world's group.
#include "test_util.h"

#include "coop_game_values.h"

#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

using namespace coop::game;

namespace
{
// The engine's console as the layer sees it: a map of values, every set recorded.
struct FakeConsole : CvarConsole
{
	std::map<std::string, std::string> values;
	std::vector<std::string> sets; // "name=value", in the order of the calls
	std::vector<std::string> gets;

	bool get(const std::string& name, std::string& value) override
	{
		gets.push_back(name);
		const auto it = values.find(name);
		if (it == values.end())
			return false;
		value = it->second;
		return true;
	}

	void set(const std::string& name, const std::string& value) override
	{
		sets.push_back(name + "=" + value);
		const auto it = values.find(name);
		if (it != values.end())
			it->second = value;
	}
};

std::string repeat(char c, size_t n) { return std::string(n, c); }
} // namespace

// §1.2: the white list is the rules of the table, nothing else, each once. Row 18 is "stalkers finish a downed player"
// (coop_npc_finish_downed, registered by the NPC AI, coop_ai.cpp). The three rules of the hybrid (split levels, story maps
// together, the world started by the game) are gone with it (owner 2026-11-18, docs/MODES.md section 7).
TEST(game_values_cvar_list_is_the_eighteen_rules)
{
	const char* expected[] = {
		"coop_friendly_fire", "coop_max_new_characters", "coop_share_rewards", "coop_death_mode", "coop_death_drop",
		"coop_bleedout", "coop_revive_health", "coop_respawn_delay", "coop_contusion", "coop_death_money",
		"coop_death_wear", "coop_death_rank", "coop_hardcore_new_kit", "coop_checkpoints_group",
		"coop_autosave_interval", "coop_autosave_count", "coop_death_share", "coop_npc_finish_downed",
	};
	CHECK_EQ(kGameCvarCount, size_t(18));
	CHECK_EQ(sizeof(expected) / sizeof(expected[0]), kGameCvarCount);
	for (size_t i = 0; i < kGameCvarCount; ++i)
	{
		CHECK_EQ(std::string(kGameCvars[i]), std::string(expected[i]));
		CHECK(cvar_allowed(expected[i]));
		for (size_t j = i + 1; j < kGameCvarCount; ++j)
			CHECK(kGameCvars[i] != kGameCvars[j]);
	}
}

// A world saved before (a hybrid world, a server world) still carries c|coop_split_levels, c|coop_story_together and
// c|coop_world_server in its record (tools/persisted_keys.txt: the keys never go). They are no console rules any more: the layer
// refuses them, sets nothing and holds nothing, and the load goes on (a refusal is a log line, never fatal).
TEST(game_values_the_rules_of_the_hybrid_are_refused_and_change_nothing)
{
	CHECK(!cvar_allowed("coop_split_levels"));
	CHECK(!cvar_allowed("coop_story_together"));
	CHECK(!cvar_allowed("coop_world_server"));
	CHECK(!cvar_allowed("coop_max_map_servers")); // a machine setting (the host's PC), not a rule of the game
	CHECK(!cvar_allowed("coop_mapserver_linger"));

	FakeConsole con;
	con.values["coop_split_levels"] = "0";
	con.values["coop_story_together"] = "0";
	con.values["coop_world_server"] = "0";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_split_levels", "1") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_story_together", "1") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_world_server", "1") == CvarVerdict::NotAllowed);
	CHECK(con.sets.empty());
	CHECK(con.gets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(layer.release(con), size_t(0));

	// a rule that stays is taken as before, next to them
	con.values["coop_friendly_fire"] = "1";
	CHECK(layer.apply(con, "coop_friendly_fire", "0") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_friendly_fire"], std::string("1"));
}

TEST(game_values_cvar_apply_remembers_machine_once)
{
	FakeConsole con;
	con.values["coop_bleedout"] = "0";
	CvarLayer layer;

	CHECK(layer.apply(con, "coop_bleedout", "1") == CvarVerdict::Applied);
	CHECK_EQ(con.values["coop_bleedout"], std::string("1"));
	CHECK(layer.apply(con, "coop_bleedout", "2") == CvarVerdict::Applied);
	CHECK_EQ(con.values["coop_bleedout"], std::string("2"));
	CHECK_EQ(layer.held(), size_t(1));

	// The second apply did not take the first game value for the machine's.
	const std::string* machine = layer.machine("coop_bleedout");
	REQUIRE(machine != nullptr);
	CHECK_EQ(*machine, std::string("0"));

	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_bleedout"], std::string("0"));
}

TEST(game_values_cvar_release_restores_all_and_clears)
{
	FakeConsole con;
	con.values["coop_bleedout"] = "60";
	con.values["coop_death_mode"] = "checkpoint";
	con.values["coop_friendly_fire"] = "1";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_bleedout", "30") == CvarVerdict::Applied);
	CHECK(layer.apply(con, "coop_death_mode", "hardcore") == CvarVerdict::Applied);
	CHECK(layer.apply(con, "coop_friendly_fire", "0") == CvarVerdict::Applied);
	CHECK_EQ(layer.held(), size_t(3));

	CHECK_EQ(layer.release(con), size_t(3));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
	CHECK_EQ(con.values["coop_death_mode"], std::string("checkpoint"));
	CHECK_EQ(con.values["coop_friendly_fire"], std::string("1"));
	CHECK_EQ(layer.held(), size_t(0));
	CHECK(layer.machine("coop_bleedout") == nullptr);

	// A second release has nothing to give back: not one more console call, and a value the player has changed
	// since (menu, console) is not written over.
	con.values["coop_bleedout"] = "99";
	const size_t calls = con.sets.size();
	CHECK_EQ(layer.release(con), size_t(0));
	CHECK_EQ(con.sets.size(), calls);
	CHECK_EQ(con.values["coop_bleedout"], std::string("99"));
}

// A new activation after a release takes the machine's value of that moment, not the one of the first activation.
TEST(game_values_cvar_apply_after_release_remembers_again)
{
	FakeConsole con;
	con.values["coop_autosave_count"] = "10";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_autosave_count", "3") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_autosave_count"], std::string("10"));

	con.values["coop_autosave_count"] = "20"; // the player changed it in the main menu
	CHECK(layer.apply(con, "coop_autosave_count", "5") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_autosave_count"], std::string("20"));
}

TEST(game_values_cvar_not_whitelisted_refused)
{
	FakeConsole con;
	con.values["coop_nick"] = "Stalker";
	con.values["fov"] = "67.5";
	con.values["coop_money_max"] = "1000";
	con.values["coop_friendly_fire"] = "1";
	CvarLayer layer;

	CHECK(layer.apply(con, "coop_nick", "Hacker") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "fov", "120") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_money_max", "9") == CvarVerdict::NotAllowed); // a technical limit, not a game rule
	CHECK(layer.apply(con, "", "1") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "quit", "1") == CvarVerdict::NotAllowed);
	// The name is exact: one console command must not be held under two spellings (the second would take the game
	// value of the first for the machine's).
	CHECK(layer.apply(con, "Coop_Friendly_Fire", "0") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_friendly_fire ", "0") == CvarVerdict::NotAllowed);
	CHECK(layer.apply(con, "coop_friendly_fire;quit", "0") == CvarVerdict::NotAllowed);

	CHECK(con.sets.empty());
	CHECK(con.gets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(con.values["coop_nick"], std::string("Stalker"));
	CHECK_EQ(con.values["fov"], std::string("67.5"));
}

TEST(game_values_cvar_value_validated)
{
	// Valid: a number, a token name, a signed number, the longest allowed.
	CHECK(cvar_value_valid("0"));
	CHECK(cvar_value_valid("0.3"));
	CHECK(cvar_value_valid("-1"));
	CHECK(cvar_value_valid("60."));
	CHECK(cvar_value_valid("checkpoint"));
	CHECK(cvar_value_valid(repeat('1', 64)));

	// Not valid: nothing, too long, a second command (';'), a line break, anything that splits the console line.
	CHECK(!cvar_value_valid(""));
	CHECK(!cvar_value_valid(repeat('1', 65)));
	CHECK(!cvar_value_valid("1;quit"));
	CHECK(!cvar_value_valid("1\nquit"));
	CHECK(!cvar_value_valid("1\r"));
	CHECK(!cvar_value_valid("1 2"));
	CHECK(!cvar_value_valid(" 1"));
	CHECK(!cvar_value_valid("1\t"));
	CHECK(!cvar_value_valid("\"1\""));
	CHECK(!cvar_value_valid(std::string("1\0" "2", 3)));
	CHECK(!cvar_value_valid("\xD0\xBF")); // not ASCII
	// What atof reads as a NaN or an infinity: a NaN would pass the console's range check.
	CHECK(!cvar_value_valid("nan"));
	CHECK(!cvar_value_valid("NaN"));
	CHECK(!cvar_value_valid("-nan"));
	CHECK(!cvar_value_valid("inf"));
	CHECK(!cvar_value_valid("+Infinity"));
	CHECK(cvar_value_valid("na")); // short of the word
	CHECK(cvar_value_valid("hardcore"));
	CHECK(cvar_value_valid("lose"));

	FakeConsole con;
	con.values["coop_bleedout"] = "60";
	CvarLayer layer;
	const char* bad[] = {"", "1;quit", "1\nquit", "1 2"};
	for (const char* v : bad)
		CHECK(layer.apply(con, "coop_bleedout", v) == CvarVerdict::BadValue);
	CHECK(layer.apply(con, "coop_bleedout", repeat('9', 65)) == CvarVerdict::BadValue);
	CHECK(con.sets.empty());
	CHECK(con.gets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
}

// A rule the console does not know (coop_death_share before its build lands) is refused, never fatal.
TEST(game_values_cvar_unknown_command_refused)
{
	FakeConsole con; // knows nothing
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_death_share", "150") == CvarVerdict::Unknown);
	CHECK(con.sets.empty());
	CHECK_EQ(layer.held(), size_t(0));
	CHECK_EQ(layer.release(con), size_t(0));

	// The others of the same call still go through.
	con.values["coop_bleedout"] = "60";
	CHECK(layer.apply(con, "coop_death_share", "150") == CvarVerdict::Unknown);
	CHECK(layer.apply(con, "coop_bleedout", "30") == CvarVerdict::Applied);
	CHECK_EQ(layer.release(con), size_t(1));
	CHECK_EQ(con.values["coop_bleedout"], std::string("60"));
}

// A machine value that cannot be given back (a token that shows "?", an empty status) is not touched at all:
// release would have nothing valid to write.
TEST(game_values_cvar_unrestorable_machine_value_refused)
{
	FakeConsole con;
	con.values["coop_death_drop"] = "?";
	con.values["coop_death_mode"] = "";
	CvarLayer layer;
	CHECK(layer.apply(con, "coop_death_drop", "lose") == CvarVerdict::Unknown);
	CHECK(layer.apply(con, "coop_death_mode", "hardcore") == CvarVerdict::Unknown);
	CHECK(con.sets.empty());
	CHECK_EQ(layer.held(), size_t(0));
}

TEST(game_values_cvar_machine_value_lookup)
{
	FakeConsole con;
	con.values["coop_revive_health"] = "0.3";
	CvarLayer layer;
	CHECK(layer.machine("coop_revive_health") == nullptr); // nothing held: the console shows the machine's value
	CHECK(layer.machine("coop_nick") == nullptr);

	CHECK(layer.apply(con, "coop_revive_health", "0.5") == CvarVerdict::Applied);
	const std::string* m = layer.machine("coop_revive_health");
	REQUIRE(m != nullptr);
	CHECK_EQ(*m, std::string("0.3"));
	CHECK(layer.machine("coop_bleedout") == nullptr);

	layer.release(con);
	CHECK(layer.machine("coop_revive_health") == nullptr);
}

TEST(game_values_pending_take_clears)
{
	Pending p;
	std::string payload, faction;
	CHECK(!p.staged());
	CHECK(!p.take(payload, faction)); // nothing staged

	CHECK(p.stage("record-1", "stalker"));
	CHECK(p.staged());
	CHECK_EQ(p.faction(), std::string("stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("record-1"));
	CHECK_EQ(faction, std::string("stalker"));

	// Taken once: the second take is empty, and so is what the world start reads.
	payload = "left";
	faction = "left";
	CHECK(!p.take(payload, faction));
	CHECK(!p.staged());
	CHECK_EQ(p.faction(), std::string());
}

TEST(game_values_pending_stage_replaces_and_limits)
{
	Pending p;
	std::string payload, faction;

	CHECK(p.stage("first", "dolg"));
	CHECK(p.stage("second", "freedom")); // a new stage replaces the old one
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("second"));
	CHECK_EQ(faction, std::string("freedom"));

	// Binary payload: zero bytes stay.
	const std::string binary("a\0b\xFF", 4);
	CHECK(p.stage(binary, "stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK(payload == binary);

	// 256 KiB is the limit, one more is refused.
	CHECK(p.stage(repeat('x', kMaxPendingPayload), "stalker"));
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload.size(), kMaxPendingPayload);
	CHECK_EQ(kMaxPendingPayload, size_t(256 * 1024));
	CHECK(!p.stage(repeat('x', kMaxPendingPayload + 1), "stalker"));

	// A refused stage drops the game staged before it: the screen that failed to stage its game must not start the
	// world with the previous one.
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage(repeat('x', kMaxPendingPayload + 1), "stalker"));
	CHECK(!p.staged());
	CHECK(!p.take(payload, faction));

	// Nothing to carry, or a faction that is not a name: refused (and the old one dropped, as above).
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage("", "stalker"));
	CHECK(!p.staged());
	CHECK(p.stage("kept?", "stalker"));
	CHECK(!p.stage("x", "a b"));
	CHECK(!p.staged());
	CHECK(!p.stage("x", ""));
}

TEST(game_values_world_faction_name_checked)
{
	CHECK(world_faction_valid("stalker"));
	CHECK(world_faction_valid("csky"));
	CHECK(world_faction_valid("Some_Mod-faction.2"));
	CHECK(world_faction_valid(repeat('a', 64)));

	CHECK(!world_faction_valid(""));
	CHECK(!world_faction_valid("a b"));
	CHECK(!world_faction_valid(repeat('a', 65)));
	CHECK(!world_faction_valid("a/b"));
	CHECK(!world_faction_valid("a;b"));
	CHECK(!world_faction_valid("a\nb"));
	CHECK(!world_faction_valid(std::string("a\0b", 3)));
}

TEST(game_values_start_mode_names)
{
	CHECK(start_mode("new") == StartMode::New);
	CHECK(start_mode("load") == StartMode::Load);
	CHECK(start_mode("") == StartMode::Other);
	CHECK(start_mode("NEW") == StartMode::Other); // the engine compares exactly (alife_simulator.cpp)
	CHECK(start_mode("spawn") == StartMode::Other);
	CHECK(start_mode(nullptr) == StartMode::Other);
	CHECK_EQ(std::string(start_mode_name(StartMode::New)), std::string("new"));
	CHECK_EQ(std::string(start_mode_name(StartMode::Load)), std::string("load"));
}

// before_world_start: a new game takes the group of the staged game, a load drops what was staged.
TEST(game_values_world_start_new_takes_staged_faction)
{
	Pending p;
	std::string world = "old-game-faction";
	CHECK(p.stage("record", "monolith"));

	on_world_start(StartMode::New, p, world);
	CHECK_EQ(world, std::string("monolith"));
	// The group is read, the game stays staged: Lua takes it (coop.game.take_new) in the call that follows.
	std::string payload, faction;
	REQUIRE(p.take(payload, faction));
	CHECK_EQ(payload, std::string("record"));

	// A new game with nothing staged (single player, a console `start`) has no group, and the one of the last
	// game does not stay.
	world = "monolith";
	on_world_start(StartMode::New, p, world);
	CHECK_EQ(world, std::string());
}

TEST(game_values_world_start_load_drops_stale_pending)
{
	Pending p;
	std::string world = "monolith";
	CHECK(p.stage("record", "dolg"));

	on_world_start(StartMode::Load, p, world);
	CHECK(!p.staged()); // the staged game belongs to a start that never came
	std::string payload, faction;
	CHECK(!p.take(payload, faction));
	// The last game's group does not leak into the loaded one; Lua sets the loaded game's own.
	CHECK_EQ(world, std::string());
}

TEST(game_values_world_start_other_mode_changes_nothing)
{
	Pending p;
	std::string world = "monolith";
	CHECK(p.stage("record", "dolg"));
	on_world_start(StartMode::Other, p, world);
	CHECK(p.staged());
	CHECK_EQ(world, std::string("monolith"));
}

// Report #5 (builds 55-58): a level change starts the next world from "<save>/single/alife" (CALifeSimulator drops the
// fourth part, change_level puts the autosave's name in front), so m_new_or_load is "" there. The name change_level gave
// the line makes that start a load of the save, and the hook is called with ("load", that name).
TEST(game_values_world_start_after_level_change_is_a_load)
{
	const WorldStart slot = world_start("", "coop_auto_6b00c4e3-f16d_1", "coop_auto_6b00c4e3-f16d_1");
	CHECK(slot.mode == StartMode::Load);
	CHECK_EQ(slot.save, std::string("coop_auto_6b00c4e3-f16d_1"));
	CHECK_EQ(std::string(start_mode_name(slot.mode)), std::string("load"));

	// The stock name of a level change outside a session (the first one of a new world: fake_start to its start), as the
	// next world reads it (IGame_Persistent::params lowers it)
	const WorldStart stock = world_start("", "player - autosave", "player - autosave");
	CHECK(stock.mode == StartMode::Load);
	CHECK_EQ(stock.save, std::string("player - autosave"));

	// No slot took the save: the next level loads from the temporary name, and so does the hook
	const WorldStart temp = world_start("", "coop_auto_tmp", "coop_auto_tmp");
	CHECK(temp.mode == StartMode::Load);
	CHECK_EQ(temp.save, std::string("coop_auto_tmp"));
}

TEST(game_values_world_start_without_level_change_stays_other)
{
	// Empty mode and nothing remembered (a console `start server(x/single/alife)`): left alone, as before
	const WorldStart none = world_start("", "coop_auto_x_1", "");
	CHECK(none.mode == StartMode::Other);
	CHECK_EQ(none.save, std::string("coop_auto_x_1"));
	CHECK_EQ(std::string(start_mode_name(none.mode)), std::string());

	// A name remembered for another save is not this start's
	CHECK(world_start("", "coop_auto_x_1", "coop_auto_x_2").mode == StartMode::Other);
	// Compared exactly: the engine remembers the name the way the next world parses it
	CHECK(world_start("", "player - autosave", "Player - autosave").mode == StartMode::Other);
	// An empty remembered name never matches an empty one
	CHECK(world_start("", "", "").mode == StartMode::Other);
	CHECK(world_start(nullptr, nullptr, "x").mode == StartMode::Other);
	CHECK_EQ(world_start(nullptr, nullptr, "x").save, std::string());
}

TEST(game_values_world_start_engine_word_wins)
{
	// The engine's own word wins over a remembered name: a menu load, a quick load (restart_simulator says "load"), a new game
	const WorldStart load = world_start("load", "s1", "coop_auto_x_1");
	CHECK(load.mode == StartMode::Load);
	CHECK_EQ(load.save, std::string("s1"));
	const WorldStart fresh = world_start("new", "all", "coop_auto_x_1");
	CHECK(fresh.mode == StartMode::New);
	CHECK_EQ(fresh.save, std::string("all"));
	CHECK(world_start("NEW", "all", "").mode == StartMode::Other); // exactly, like alife_simulator.cpp
}

TEST(game_values_next_load_is_taken_once)
{
	NextLoad next;
	CHECK_EQ(next.take(), std::string()); // nothing remembered
	next.remember("coop_auto_x_1");
	next.remember("coop_auto_x_2"); // the last line written is the one the next world starts from
	CHECK_EQ(next.take(), std::string("coop_auto_x_2"));
	// Every world start takes it: a later start without the engine's word is not taken for that save's load
	CHECK_EQ(next.take(), std::string());
	CHECK(world_start("", "coop_auto_x_2", next.take()).mode == StartMode::Other);
}

// ---------------------------------------------------------------- report #5: the engine's wiring, read from its source
// world_start decides only with the save the engine hands it. These lock the places that hand it over (verifier of
// O3-lateswitch: with any of them dropped every suite stayed green, so a stock merge or a refactor that loses one brings
// the late switch-on back on every level change of a Coop host and of single player):
//   - CALifeUpdateManager::change_level and load_game remember the save the next world loads, once its line is final;
//   - remember_next_load cuts the line with the parse the next world uses (IGame_Persistent::Start);
//   - before_world_start takes the name at every world start and gives the rule's answer to the hook;
//   - CALifeSimulator calls before_world_start before the first on_game_start and before the world is loaded.
namespace
{
// An engine file under engine/src/xrGame, as the build reads it; "" when it is not there (the checks then fail).
std::string engine_source(const char* name)
{
	std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/" + name, std::ios::binary);
	return std::string(std::istreambuf_iterator<char>(f), {});
}

// The body of the definition that starts with head: from its '{' in column 0 to the next '}' in column 0 (the engine's
// layout of a function); "" when not found. A constructor's initializer list may stand between them, a ';' may not (that
// is a declaration).
std::string function_body(const std::string& src, const std::string& head)
{
	for (auto at = src.find(head); at != std::string::npos; at = src.find(head, at + 1))
	{
		const auto open = src.find("\n{", at);
		if (open == std::string::npos)
			return {};
		if (src.find(';', at) < open)
			continue;
		const auto close = src.find("\n}", open + 2);
		if (close != std::string::npos)
			return src.substr(open + 1, close - open + 1);
	}
	return {};
}

// The text between the first '(' at or after `at` and the next ')'; "" when there is none.
std::string call_argument(const std::string& s, size_t at)
{
	const auto open = s.find('(', at);
	const auto close = open == std::string::npos ? open : s.find(')', open);
	return close == std::string::npos ? std::string() : s.substr(open + 1, close - open - 1);
}

// The statement at `at` stands at the top level of a function body (one tab after a line break), outside every branch.
bool top_level(const std::string& s, size_t at)
{
	return at != std::string::npos && at >= 2 && s[at - 1] == '\t' && s[at - 2] == '\n';
}

constexpr auto npos = std::string::npos;
} // namespace

TEST(game_values_wiring_level_change_remembers_the_next_load)
{
	const std::string s = function_body(engine_source("alife_update_manager.cpp"), "bool CALifeUpdateManager::change_level(");
	REQUIRE(!s.empty());
	const auto call = s.find("coop::game::remember_next_load(");
	REQUIRE(call != npos);
	CHECK(s.find("coop::game::remember_next_load(", call + 1) == npos); // once
	CHECK_EQ(call_argument(s, call), std::string("**m_server_command_line"));
	// After the last write of the line (the autosave's name, then the slot the save went to): the name the next world loads
	const auto last_write = s.rfind("*m_server_command_line =");
	CHECK(last_write != npos && last_write < call);
	// After both saves, at the top level of the body: reached in a session (coop_auto_N, coop_auto_tmp) and outside one
	// ("<user> - autosave", the world server's name)
	const auto commit = s.find("coop::autosave::level_change_commit()");
	const auto stock_save = s.find("save(autoave_name);");
	CHECK(commit != npos && commit < call);
	CHECK(stock_save != npos && stock_save < call);
	CHECK(top_level(s, call));
	// No way out between the first write of the line and the call
	CHECK(s.find("return", s.find("*m_server_command_line =")) > call);
}

TEST(game_values_wiring_load_from_a_running_game_remembers_the_next_load)
{
	const std::string s = function_body(engine_source("alife_update_manager.cpp"), "bool CALifeUpdateManager::load_game(");
	REQUIRE(!s.empty());
	const auto write = s.find("*m_server_command_line = S1;");
	const auto call = s.find("coop::game::remember_next_load(");
	REQUIRE(write != npos);
	REQUIRE(call != npos);
	CHECK(s.find("coop::game::remember_next_load(", call + 1) == npos);
	const std::string arg = call_argument(s, call);
	CHECK(arg == "S1" || arg == "**m_server_command_line");
	CHECK(write < call);
	CHECK(top_level(s, call));
	// A missing save returns before the line is written, and nothing is remembered for it
	const auto missing = s.find("return (false);");
	CHECK(missing != npos && missing < write);
	CHECK(call < s.rfind("return (true);"));
}

TEST(game_values_wiring_next_load_is_parsed_like_the_next_world)
{
	const std::string s = function_body(engine_source("coop/coop_game_settings.cpp"), "void remember_next_load(");
	REQUIRE(!s.empty());
	const auto parsed = s.find("IGame_Persistent::params parsed;");
	const auto cut = s.find("parsed.parse_cmd_line(");
	const auto keep = s.find("g_next_load.remember(parsed.m_game_or_spawn)");
	CHECK(parsed != npos && cut != npos && keep != npos);
	CHECK(parsed < cut && cut < keep);
	CHECK(call_argument(s, cut).find("command_line") != npos);
	CHECK(s.find("g_next_load.remember(", keep + 1) == npos);
	// The next world cuts the same line with the same function, so "Player - autosave" is remembered as it will read it
	const std::string start = function_body(engine_source("../xrEngine/IGame_Persistent.cpp"), "void IGame_Persistent::Start(");
	REQUIRE(!start.empty());
	CHECK(start.find("m_game_params.parse_cmd_line(op)") != npos);
}

TEST(game_values_wiring_world_start_takes_the_name_and_calls_the_hook)
{
	const std::string s = function_body(engine_source("coop/coop_game_settings.cpp"), "void before_world_start(");
	REQUIRE(!s.empty());
	// Taken at every world start, before the first way out: a name never outlives the start it was meant for
	const auto take = s.find("const std::string remembered = g_next_load.take();");
	REQUIRE(take != npos);
	CHECK(take < s.find("return"));
	CHECK(top_level(s, take));
	// The rule gets the engine's word, this world's save and the remembered name; the old decision by the word alone is gone
	const auto rule = s.find("world_start(p.m_new_or_load, p.m_game_or_spawn, remembered)");
	REQUIRE(rule != npos);
	CHECK(take < rule);
	CHECK(s.find("start_mode(p.m_new_or_load)") == npos);
	// The world's group and the hook follow the rule's answer
	const auto group = s.find("on_world_start(start.mode, g_pending, g_world_faction)");
	const auto hook = s.find("call_hook(");
	CHECK(group != npos && rule < group);
	REQUIRE(hook != npos);
	CHECK(s.find("call_hook(", hook + 1) == npos);
	CHECK(rule < hook);
	CHECK(s.find("call_hook(start_mode_name(start.mode), start.save.c_str())") == hook);
}

TEST(game_values_wiring_hook_runs_before_on_game_start_and_the_load)
{
	const std::string s = function_body(engine_source("alife_simulator.cpp"), "CALifeSimulator::CALifeSimulator(");
	REQUIRE(!s.empty());
	const auto hook = s.find("coop::game::before_world_start();");
	REQUIRE(hook != npos);
	CHECK(s.find("coop::game::before_world_start(", hook + 1) == npos);
	// Before the stock start_game_callback (the first on_game_start of every script) and before the save is loaded (Lua's
	// load_state then finds the record in force and takes its early return)
	const auto on_game_start = s.find("functor();");
	const auto load = s.find("load(p.m_game_or_spawn");
	CHECK(on_game_start != npos && hook < on_game_start);
	CHECK(load != npos && hook < load);
}
