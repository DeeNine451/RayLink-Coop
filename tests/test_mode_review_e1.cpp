// Anomaly Coop unit tests: the fixes of the review A-REV-E-1 of the mode split (temp/w9rev/A-REV-E-1.md; docs/MODES.md section 4).
//
// Both modes: the switchboard asks the server's layer first, and the co-op layer takes every host start that one left (finding 3).
// Server: a map server's level session loses its LocalLink once its bridge carries it, so a map server delivers to its players only
// and has no link (its reports go up through up(), filtered by map_server_sends; finding 2); one name of each server setting is
// saved in user.ltx (the old coop_* synonyms are typed or read, never written; finding 7).
// Co-op: srv.is_world_server() answers false on a co-op host, whose roles hold WorldServer too (finding 5).
// The engine's files cannot run here: what they do is read from the sources, as tests/test_mode_hooks.cpp does.
#include "test_util.h"

#include "coop_local_link.h"
#include "coop_roles.h"
#include "coop_session.h"
#include "srv/coop_session_srv.h"
#include "support/fake_mode.h"

#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>

using namespace coop;

namespace
{
// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string e1_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string e1_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string e1_code(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr
	} st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				st = St::Line;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
			if (c == '\\')
				++i;
			else if (c == '"')
				st = St::Code;
			break;
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == '\'')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string e1_collapse(const std::string& s)
{
	const std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

bool e1_has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

// The body between the braces that open at `open` (the index of '{'); "" when they do not close.
std::string e1_braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(open + 1, i - 2 - open);
}

// The body of `class <name>` (its braces); "" and a failure when there is none.
std::string e1_class(const std::string& code, const std::string& name)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(R"(\bclass\s+)" + name + R"(\b[^;{]*\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no class " + name);
		return "";
	}
	return e1_braced(code, size_t(m.position(0) + m.length(0) - 1));
}

// The collapsed body of the override `name` in a class body ("<none>" when the class has no such override).
std::string e1_override(const std::string& cls, const std::string& name)
{
	std::smatch m;
	const std::regex rx(R"(\b)" + name + R"(\s*\([^;{)]*\)\s*(?:const\s*)?override\s*\{)");
	if (!std::regex_search(cls, m, rx))
		return "<none>";
	return e1_collapse(e1_braced(cls, size_t(m.position(0) + m.length(0) - 1)));
}

// The collapsed body of the first function whose head matches `head` (a regex ending at the name); "" and a failure when none.
std::string e1_body(const std::string& code, const std::string& head)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "";
	}
	return e1_collapse(e1_braced(code, size_t(m.position(0) + m.length(0) - 1)));
}

// The switchboard's list of the layers as written in its initializer (collapsed), "" when there is none.
std::string e1_layer_list(const std::string& board)
{
	std::smatch m;
	if (!std::regex_search(board, m, std::regex(R"(static\s+const\s+Layers\s+\w+\s*\{\s*\{([^{}]*)\}\s*\}\s*;)")))
		return "";
	return e1_collapse(m[1].str());
}

bool e1_server_first(const std::string& board) { return e1_layer_list(board) == "&srv::layer(), &hostplay::layer()"; }
} // namespace

// Finding 3. A host start (Entry::Host) is the world server's only when the server's layer is asked first: the co-op layer answers
// every host start, so with the two swapped a -coop_dedicated process would host a co-op session (Welcome Coop, the LocalLink
// attached, no in-filter, no bridges, no operator). boot_layers and place_ghost lean on the same order.
TEST(mode_switchboard_asks_the_server_first)
{
	const std::string src = e1_engine_src();
	const std::string board = e1_code(e1_read(src + "/xrGame/coop/coop_mode.cpp"));
	REQUIRE(!board.empty());
	CHECK_EQ(e1_layer_list(board), std::string("&srv::layer(), &hostplay::layer()"));
	// the check itself: a swapped list fails, the same list in another layout passes
	CHECK(!e1_server_first("static const Layers all{{&hostplay::layer(), &srv::layer()}};"));
	CHECK(e1_server_first("static const Layers all{ {\n\t&srv::layer(),\n\t&hostplay::layer() } };"));
	// every question walks that list front to back: each use of it is a range-for over layers().list
	size_t uses = 0, walks = 0;
	for (size_t at = board.find("layers().list"); at != std::string::npos; at = board.find("layers().list", at + 1))
		++uses;
	const std::regex walk(R"(for\s*\(\s*Layer\s*\*\s*layer\s*:\s*layers\s*\(\s*\)\s*\.\s*list\s*\))");
	for (std::sregex_iterator it(board.begin(), board.end(), walk), end; it != end; ++it)
		++walks;
	CHECK(uses > 0);
	CHECK_EQ(walks, uses);
	for (const char* back : {"rbegin", "rend", "list[0]", "list[1]"})
		CHECK(!e1_has(board, back));
	// the server's layer takes a host start only in its own process; the co-op layer takes every other one, with no test of its own
	const std::string srv = e1_class(e1_code(e1_read(src + "/xrGame/coop/srv/coop_srv_mode.cpp")), "ServerLayer");
	CHECK(e1_has(e1_override(srv, "mode_of"), "case Entry::Host: return dedicated::on() ? &world_mode() : nullptr;"));
	const std::string coop_raw = e1_read(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp");
	CHECK(e1_has(coop_raw, "A host that the server layer did not take is the co-op host"));
	const std::string coop = e1_class(e1_code(coop_raw), "CoopLayer");
	CHECK(e1_has(e1_override(coop, "mode_of"), "case Entry::Host: return &host_mode();"));
}

// Finding 2, the fact: a map server's level session (Manager::Manager attaches the LocalLink to every process's session) is
// carried by its bridge once Manager::start_map_server hosts it, and a carried host drops the link (Session::host_carried).
TEST(mode_map_server_level_session_has_no_link_once_hosted)
{
	Session world; // the map server's world connection (Manager::m_world); not connected: enough for a carried host
	Session level; // its level's session (Manager::m_session)
	LocalLink link;
	level.attach_local(&link);
	CHECK(level.local() == &link);
	srv::SessionSrv(level).level_through(world); // MapServerMode::install
	SessionConfig cfg; // a carried host takes its seats from its carrier
	std::string err;
	REQUIRE(level.host(cfg, &err)); // Manager::start_map_server
	CHECK(srv::SessionSrv(level).is_virtual());
	CHECK(level.local() == nullptr); // for the life of that session: no link of a map server sends anything
	level.shutdown("test");
}

// Finding 2, the mode: a map server delivers to the players of its session and to nobody else. It has no link: a send of its
// level session to peer 0 went nowhere (the link is gone) and, sent up its bridge, a HostOnly message (EntitySpawn, ...) from a
// client gets the map server kicked by its world. Its reports go up through up(), filtered by map_server_sends.
TEST(mode_map_server_has_no_link_up)
{
	const std::string srv = e1_code(e1_read(e1_engine_src() + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	REQUIRE(!srv.empty());
	const std::string map = e1_class(srv, "MapServerMode");
	REQUIRE(!map.empty());
	CHECK_EQ(e1_override(map, "deliver"), std::string("to_players(type, payload, lane, except);"));
	CHECK_EQ(e1_override(map, "deliver_links"), std::string(""));
	CHECK(!e1_has(map, "local()"));
	CHECK_EQ(e1_override(map, "up"),
	    std::string("if (!mapserver::map_server_sends(type)) return; mgr().session().send(kHostPeer, lane, type, payload);"));
	// the fake's map server answers the same: nothing reaches a link
	t::FakeMode m(t::mode_case("map_server"));
	CHECK_EQ(std::string(m.name()), std::string("map_server"));
	Writer w(4);
	w.u8(1);
	m.deliver_links(Msg::Chat, w, Lane::Reliable);
	CHECK(m.linked.empty());
	CHECK(!t::mode_case("map_server").delivers_links);
	// the world server's links are its bridges, the co-op host's the host player's link
	CHECK(t::mode_case("world_server").delivers_links);
	CHECK(t::mode_case("coop_host").delivers_links);
}

// Finding 5: a co-op host's roles hold WorldServer (host_roles), so is_world_server() alone answers true there. The table srv.* is
// the server's: it says true only in a -coop_dedicated process (the world server), as its header says.
TEST(mode_srv_is_world_server_only_in_a_dedicated_process)
{
	CHECK(has(host_roles(), ProcessRole::WorldServer)); // why is_world_server() alone is not the server's answer
	CHECK(has(dedicated_roles(), ProcessRole::WorldServer));
	CHECK(!has(map_server_roles(), ProcessRole::WorldServer));
	CHECK(!has(client_roles(), ProcessRole::WorldServer));
	const std::string code = e1_code(e1_read(e1_engine_src() + "/xrGame/coop/srv/coop_srv_script.cpp"));
	REQUIRE(!code.empty());
	CHECK_EQ(e1_body(code, R"(int\s+l_is_world_server)"), std::string("lua_pushboolean(L, dedicated::on() && is_world_server()); return 1;"));
	CHECK(e1_has(e1_collapse(code), "{\"is_world_server\", &l_is_world_server}"));
	// the other four are false in a co-op process by themselves: no -coop_dedicated, no map server, no split session
	CHECK_EQ(e1_body(code, R"(int\s+l_is_dedicated)"), std::string("lua_pushboolean(L, dedicated::on()); return 1;"));
	CHECK_EQ(e1_body(code, R"(int\s+l_dedicated_new_world)"), std::string("lua_pushboolean(L, dedicated::new_world()); return 1;"));
}

// Finding 7: CCC_SaveCFG writes every command in name order, and user.ltx runs in file order: with both names saved the srv_* line
// (after the coop_* one) won over an edit of the coop_* one. The new name is saved; the old one, typed or read from an old user.ltx,
// sets the same variable and is written by nobody, until step S8 (A-S8) removes it.
TEST(mode_srv_console_saves_one_name)
{
	const std::string code = e1_code(e1_read(e1_engine_src() + "/xrGame/coop/srv/coop_srv_console.cpp"));
	REQUIRE(!code.empty());
	std::map<std::string, std::string> cls_of; // command -> class
	const std::regex rx(R"rx(\bCMD[14]\s*\(\s*(\w+)\s*,\s*"(\w+)")rx");
	for (std::sregex_iterator it(code.begin(), code.end(), rx), end; it != end; ++it)
		cls_of[(*it)[2].str()] = (*it)[1].str();
	std::string synonym;
	for (const char* setting : {"max_map_servers", "mapserver_linger", "map_servers_rev"})
	{
		const auto now = cls_of.find(std::string("srv_") + setting);
		const auto old = cls_of.find(std::string("coop_") + setting);
		REQUIRE(now != cls_of.end() && old != cls_of.end());
		CHECK_EQ(now->second, std::string("CCC_Integer")); // saved: CCC_Integer::Save writes "name value"
		CHECK(old->second != "CCC_Integer");
		if (synonym.empty())
			synonym = old->second;
		CHECK_EQ(old->second, synonym); // one class for the three
	}
	REQUIRE(!synonym.empty());
	// that class is a CCC_Integer (the same bounds, the same variable) whose Save writes nothing
	CHECK(std::regex_search(code, std::regex(R"(\bclass\s+)" + synonym + R"(\s+final\s*:\s*public\s+CCC_Integer\b)")) ||
	    std::regex_search(code, std::regex(R"(\bclass\s+)" + synonym + R"(\s*:\s*public\s+CCC_Integer\b)")));
	const std::string cls = e1_class(code, synonym);
	CHECK_EQ(e1_override(cls, "Save"), std::string(""));
	CHECK_EQ(e1_override(cls, "Execute"), std::string("<none>")); // typed, it does what the new name does
}
