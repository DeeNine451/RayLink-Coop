// INTEG-C (rv_A-S6-E-net, fix 1: the layer handoff): Steam is the co-op's only (docs/MODES.md section 8). The invite polling, the
// address file, the overlay's invite window and their Lua exports live in the co-op layer (hostplay/coop_hostplay_steam.cpp); the Core's
// autostart only takes an address a layer was asked to join (Layer::join_request) into its retry queue, before a session as during one,
// and keeps its rules: the same address while in that game changes nothing; another one stops the session first and starts the
// retries from zero. The native target does not link xrGame: the wiring is read from the sources.
#include "test_util.h"
#include "coop_mode.h"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace
{
std::string game_source(const char* file)
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto dir = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::ifstream in(dir + "/../engine/src/xrGame/coop/" + file, std::ios::binary);
	return {std::istreambuf_iterator<char>(in), {}};
}

std::string_view section(std::string_view source, std::string_view start, std::string_view end)
{
	const size_t first = source.find(start);
	REQUIRE(first != std::string_view::npos);
	const size_t last = source.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return source.substr(first, last - first);
}

bool has(std::string_view code, std::string_view what) { return code.find(what) != std::string_view::npos; }

size_t at(std::string_view code, std::string_view what)
{
	const size_t p = code.find(what);
	CHECK(p != std::string_view::npos);
	return p;
}

class QuietLayer final : public coop::Layer
{
public:
	const char* name() const override { return "quiet"; }
	bool boot_frame() override { return false; }
	coop::Mode* mode_of(coop::Entry, coop::SessionMode) override { return nullptr; }
};
} // namespace

TEST(hostplay_steam_a_layer_asks_no_join_by_default)
{
	QuietLayer l;
	std::string address = "unchanged", via = "nobody";
	CHECK(!l.join_request(address, via));
	CHECK_EQ(address, std::string("unchanged"));
	CHECK_EQ(via, std::string("nobody"));
}

TEST(hostplay_steam_core_keeps_only_the_retry_queue)
{
	const std::string manager = game_source("coop_manager.cpp");
	REQUIRE(!manager.empty());
	CHECK(!has(manager, "RAYLINK_STEAM"));
	CHECK(!has(manager, "SteamAPI_"));
	CHECK(!has(manager, "Steam"));
	CHECK(!has(game_source("coop_script.cpp"), "steam_invite"));
	CHECK(!has(manager, "steam_join"));
	CHECK(!has(manager, "next_steam_join"));
	const auto autostart = section(manager, "void Manager::autostart()", "\n}");
	const size_t boots = at(autostart, "boot_layers()");
	const size_t ask = at(autostart, "layer_join_request(invite, via)");
	const size_t host = at(autostart, "start_host(g_auto.host_port)");
	CHECK(boots < ask);
	CHECK(ask < host);
	const auto take = section(autostart, "layer_join_request(invite, via)", "start_host(g_auto.host_port)");
	const size_t same = at(take, "if (!active() || g_auto.connect != invite.c_str())");
	const size_t stop_first = at(take, "stop(\"joined a friend through an invite\")");
	CHECK(!has(autostart, "Steam"));
	const size_t h = at(take, "g_auto.host = false;");
	const size_t c = at(take, "g_auto.connect = invite.c_str();");
	const size_t tries = at(take, "g_auto.connect_tries = 0;");
	const size_t next = at(take, "g_auto.next_connect = 0;");
	const size_t welcomed = at(take, "g_auto.welcomed = false;");
	CHECK(same < stop_first);
	CHECK(stop_first < h);
	CHECK(h < c);
	CHECK(c < tries);
	CHECK(tries < next);
	CHECK(next < welcomed);
}

TEST(hostplay_steam_the_layer_polls_and_exports)
{
	const std::string steam = game_source("hostplay/coop_hostplay_steam.cpp");
	REQUIRE(!steam.empty());
	CHECK(has(steam, "// Кооп: только там, где хост играет сам (docs/MODES.md)"));
	CHECK(has(steam, "L\"RAYLINK_STEAM_JOIN\""));
	CHECK(has(steam, "steam_join::parse_tunnel(text, tunnel)"));
	CHECK(has(steam, "constexpr u32 kSteamJoinPollMs = 500;"));
	CHECK(has(steam, "\"steam_invite_ready\""));
	CHECK(has(steam, "\"steam_invite\""));
	CHECK(has(steam, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog"));
	const std::string layer = game_source("hostplay/coop_hostplay_mode.cpp");
	REQUIRE(!layer.empty());
	const auto coop_layer = section(layer, "class CoopLayer final", "\n};");
	CHECK(has(coop_layer, "bool join_request(std::string& address, std::string& via) override"));
	CHECK(has(coop_layer, "steam::poll(mgr().now_ms(), address)"));
	CHECK(has(coop_layer, "via = \"a Steam invite\";"));
	CHECK(has(coop_layer, "void register_lua(lua_State* L) override { steam::register_lua(L); }"));
	const std::string board = game_source("coop_mode.cpp");
	REQUIRE(!board.empty());
	const auto ask = section(board, "bool layer_join_request(std::string& address, std::string& via)", "\n}");
	CHECK(has(ask, "layer->join_request(address, via)"));
	CHECK(!has(ask, "boot_frame"));
}
