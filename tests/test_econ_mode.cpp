// The engine handlers cannot be linked into this native test binary. Check their
// authority and placement guards in source, and exercise the answers under each mode.
#include "test_util.h"
#include "support/fake_mode.h"

#include <fstream>
#include <regex>

namespace
{
std::string econ_source(const char* name)
{
	const std::string here = __FILE__;
	const size_t slash = here.find_last_of("/\\");
	const std::string root = slash == std::string::npos ? "." : here.substr(0, slash) + "/..";
	std::ifstream in(root + "/engine/src/xrGame/coop/" + name);
	REQUIRE(in.good());
	std::ostringstream out;
	out << in.rdbuf();
	return std::regex_replace(out.str(), std::regex(R"(\s+)"), " ");
}

void check_guard(const std::string& source, const std::string& guard)
{
	if (source.find(guard) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, "missing economy guard: " + guard);
}

void check_econ_answers(const char* name, bool leads_trade, bool decides_world, bool mirror,
    coop::Where placed, coop::Where away, coop::Where joining)
{
	using namespace coop;
	const t::ModeCase& row = t::mode_case(name);
	REQUIRE(std::string(row.name) == name);
	t::FakeMode mode(row);
	mode.place(7, t::Spot::Here);
	mode.place(8, t::Spot::Elsewhere);
	mode.place(9, t::Spot::Joining);

	CHECK_EQ(mode.leads_level(), leads_trade);
	CHECK_EQ(mode.decides_world(), decides_world);
	CHECK_EQ(has(mode.roles(), ProcessRole::Mirror), mirror);
	CHECK_EQ(mode.where(7), placed);
	CHECK_EQ(mode.where(8), away);
	CHECK_EQ(mode.where(9), joining);
}
} // namespace

TEST(econ_trade_is_judged_only_on_the_loaded_level)
{
	const std::string code = econ_source("coop_trade.cpp");
	check_guard(code, "case Op::Deal: if (mode().leads_level() && from != kHostPeer) host_on_deal");
	check_guard(code, "if (mode().leads_level()) host_on_container");
	check_guard(code, "if (!mode().leads_level() || id == kNoId)");
	check_guard(code, "if (!mode().leads_level() || !trade || !trade->pThis.inv_owner)");
	check_guard(code, "void send_container(bool open, u8 kind, u16 local_id) { if (mode().leads_level())");
	check_guard(code, "void print_status() { if (mode().leads_level())");
}

TEST(econ_ammo_and_leases_ask_for_player_placement)
{
	check_guard(econ_source("coop_items.cpp"), "op == Op::SpawnAmmo && mode().where(from) != Where::Away");
	check_guard(econ_source("coop_requests.cpp"),
	    "sync::host_peer_joining(p.id) || mode().where(p.id) == Where::Away");
}

TEST(econ_equipment_carry_is_for_player_mirrors)
{
	const std::string code = econ_source("coop_equip.cpp");
	check_guard(code, "CActor* actor = is_mirror() && g_pGameLevel ?");
	check_guard(code, "if (g_pGameLevel && is_mirror() && join::client_loading_world()");
	check_guard(code, "if (!g_carry.have || !mgr().active() || !is_mirror() || !join::client_loading_world()");
}

TEST(econ_equipment_and_money_still_run_for_live_clients)
{
	const std::string equip = econ_source("coop_equip.cpp");
	check_guard(equip, "const bool live = mode().decides_world() || mgr().is_live_client();");
	check_guard(equip, "if (mode().decides_world() || mgr().is_live_client()) on_equip(from, r);");

	const std::string money = econ_source("coop_money.cpp");
	check_guard(money, "void frame() { if (mgr().is_live_client() || mode().decides_world())");
	check_guard(money, "void client_flush(bool paced) { if (!mgr().is_live_client() && !mode().decides_world()) return;");
}

TEST(econ_world_ledger_asks_for_remote_body_facts)
{
	check_guard(econ_source("coop_money.cpp"),
	    "dialog::host_lock_of(from) != kNoId || (mode().facts_of(join::proxy_of_peer(from), there) && there.talking)");
}

#define ECON_ANSWERS_coop_host true, true, false, Where::Here, Where::Here, Where::Joining
#define ECON_ANSWERS_coop_client false, false, true, Where::Here, Where::Here, Where::Here
#define ECON_ANSWERS_world_server false, true, false, Where::Away, Where::Away, Where::Joining
#define ECON_ANSWERS_map_server true, false, false, Where::Here, Where::Away, Where::Joining
#define ECON_ANSWERS_server_client false, false, true, Where::Here, Where::Away, Where::Here
#define ECON_ANSWERS_none false, false, false, Where::Away, Where::Away, Where::Away

#define ECON_MODE_TEST(name) \
	TEST(econ_mode_##name) \
	{ \
		using coop::Where; \
		check_econ_answers(#name, ECON_ANSWERS_##name); \
	}
MODE_CASES(ECON_MODE_TEST)
#undef ECON_MODE_TEST
