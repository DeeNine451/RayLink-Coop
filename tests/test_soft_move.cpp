// Anomaly Coop unit tests: the host's move that nobody else notices (xrCoop/coop_soft_move.h, docs/SPLIT_LEVELS.md §7a "Переход
// хоста"): who stays in his world, which map server keeps its process, the window between the go and the end of the parking, and
// what the keep-alive thread does with a packet while the main thread loads a level.
#include "test_util.h"

#include "coop_soft_move.h"

#include <cstring>
#include <memory>
#include <vector>

using namespace coop;
using softmove::Facts;
using softmove::Relay;
using levels::wire::TunnelMsg;

namespace
{
Facts staying()
{
	Facts f;
	f.joined = true;
	f.known = true;
	f.proxy = true;
	f.server_ready = true;
	return f;
}

// [u16 type][payload]
std::vector<uint8_t> packet_of(Msg type, std::vector<uint8_t> payload = {1, 2, 3})
{
	std::vector<uint8_t> out{uint8_t(uint16_t(type) & 0xFF), uint8_t(uint16_t(type) >> 8)};
	out.insert(out.end(), payload.begin(), payload.end());
	return out;
}

std::vector<uint8_t> tunnel_of(uint32_t peer, uint8_t flags, const std::vector<uint8_t>& inner)
{
	TunnelMsg m;
	m.peer = peer;
	m.flags = flags;
	m.packet = inner;
	Writer w(inner.size() + 8);
	REQUIRE(m.write(w));
	std::vector<uint8_t> out{uint8_t(uint16_t(Msg::Tunnel) & 0xFF), uint8_t(uint16_t(Msg::Tunnel) >> 8)};
	out.insert(out.end(), w.ptr(), w.ptr() + w.size());
	return out;
}

int g_a, g_b, g_ms, g_ms2; // their addresses are the transport's handles here

Relay rig()
{
	Relay r;
	r.add_client(&g_a, 11, 1, 7);
	r.add_client(&g_b, 12, 2, 7);
	r.add_bridge(&g_ms, 21, 0x101, 7);
	r.add_bridge(&g_ms2, 22, 0x102, 8);
	return r;
}
} // namespace

// --- who stays

TEST(soft_a_player_in_the_world_of_a_running_map_server_stays)
{
	CHECK(softmove::stays(staying()));
}

TEST(soft_who_cannot_stay_goes_the_old_way)
{
	for (int i = 0; i < 8; ++i)
	{
		Facts f = staying();
		switch (i)
		{
		case 0: f.joined = false; break;
		case 1: f.known = false; break;
		case 2: f.proxy = false; break; // no character: nothing of his to keep
		case 3: f.loading = true; break; // on his loading screen
		case 4: f.joining = true; break;
		case 5: f.choosing = true; break; // in the choice of a character
		case 6: f.server_ready = false; break; // the server of his level is not up, or there is none (the host's old level)
		case 7: f.on_target = true; break; // the host comes to him: his server closes
		}
		CHECK(!softmove::stays(f));
	}
}

TEST(soft_a_map_server_keeps_its_process_unless_the_host_goes_there)
{
	CHECK(softmove::keeps_server(true, true, 7, 8));
	CHECK(!softmove::keeps_server(true, true, 8, 8)); // the host leads that level from now on
	CHECK(!softmove::keeps_server(true, false, 7, 8)); // it is still loading: there is nothing to keep
	CHECK(!softmove::keeps_server(false, true, 7, 8)); // coop_soft_host_move 0: the old path for everybody
}

// --- the window

TEST(soft_window_goes_through_its_stages)
{
	softmove::Window w;
	CHECK(!w.active());
	w.go(5, 1000);
	CHECK(w.active());
	CHECK_EQ(w.target(), uint16_t(5));
	CHECK(w.stage() == softmove::Stage::Going);
	CHECK(!w.overdue(100000, true)); // the save is not written yet: it takes what it takes
	w.saved(3000);
	CHECK(w.stage() == softmove::Stage::Saved);
	w.world_created(9000);
	CHECK(w.stage() == softmove::Stage::World);
	w.world_up(10000);
	CHECK_EQ(w.save_ms(), uint64_t(2000));
	const uint64_t away = w.away_ms(12000);
	CHECK_EQ(away, uint64_t(9000));
	w.clear();
	CHECK(!w.active());
}

TEST(soft_window_keeps_the_clock_of_its_save)
{
	softmove::Window w;
	w.go(5, 1000);
	w.saved(3000, 7200000);
	CHECK_EQ(w.saved_clock(), uint64_t(7200000));
	w.clear();
	CHECK_EQ(w.saved_clock(), uint64_t(0));
}

TEST(soft_clock_goes_only_what_the_new_world_has_not_run_itself)
{
	const uint64_t saved = 7200000;
	// 9.9 s away at factor 10: 99 game seconds. The new world loaded 5.5 s ago and its clock runs from there.
	CHECK_EQ(softmove::clock_behind(saved, 9900, 10.f, saved + 55000), uint64_t(44000));
	CHECK_EQ(softmove::clock_behind(saved, 9900, 10.f, saved), uint64_t(99000)); // a clock that stood all the way
	CHECK_EQ(softmove::clock_behind(saved, 9900, 10.f, saved + 99000), uint64_t(0));
	CHECK_EQ(softmove::clock_behind(saved, 9900, 10.f, saved + 120000), uint64_t(0)); // never back
	CHECK_EQ(softmove::clock_behind(saved, 9900, 0.f, saved), uint64_t(0)); // a stopped clock
	CHECK_EQ(softmove::clock_behind(0, 9900, 10.f, saved), uint64_t(0)); // no clock was read at the save
}

TEST(soft_window_watchdog_counts_from_the_save)
{
	softmove::Window w;
	w.go(5, 1000);
	w.saved(2000);
	CHECK(!w.overdue(2000 + softmove::kReloadWatchMs - 1, true));
	CHECK(w.overdue(2000 + softmove::kReloadWatchMs, true));
	CHECK(!w.overdue(2000 + softmove::kReloadWatchMs, false)); // a level being built runs frames too: that says nothing
	w.world_created(3000);
	CHECK(!w.overdue(1000000, true)); // it came
}

TEST(soft_the_clock_goes_on_by_the_window_at_the_time_factor)
{
	CHECK_EQ(softmove::game_ms_ahead(60000, 12.f), uint64_t(720000));
	CHECK_EQ(softmove::game_ms_ahead(0, 12.f), uint64_t(0));
	CHECK_EQ(softmove::game_ms_ahead(1000, -1.f), uint64_t(0)); // a factor that says nonsense moves nothing
}

// --- the relay

TEST(soft_the_book_waits_for_what_the_map_servers_said_in_the_window)
{
	// a grant answered in the window: its commit is among what waited, its time limit must not run out before that is read
	CHECK(softmove::book_waits(true, false));
	CHECK(softmove::book_waits(false, true));
	CHECK(!softmove::book_waits(false, false));
}

TEST(soft_relay_a_map_message_of_a_player_goes_to_the_map_server_of_his_level)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> p = packet_of(Msg::PlayerState);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Unreliable), p.data(), p.size(), out) == softmove::Take::Sent);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == &g_ms);
	CHECK_EQ(out[0].link, uint32_t(21));
	CHECK(out[0].lane == Lane::Unreliable);
	CHECK_EQ(out[0].type, uint16_t(Msg::Tunnel));
	Reader in(out[0].body.data(), out[0].body.size());
	TunnelMsg m;
	REQUIRE(m.read(in));
	CHECK_EQ(m.peer, uint32_t(1));
	CHECK(mapserver::tunnel_lane(m.flags) == Lane::Unreliable);
	CHECK(m.packet == p);
}

// The road does what the main thread would have done, message by message: one table of routes, two readers of it.
TEST(soft_relay_takes_the_same_route_as_the_main_thread)
{
	const Relay r = rig();
	uint32_t seen = 0;
	for (uint32_t t = uint16_t(Msg::GameBase); t < 0x0400; ++t)
	{
		const Msg msg = static_cast<Msg>(t);
		Scope scope;
		if (!scope_row(msg, scope))
			continue;
		++seen;
		std::vector<Relay::Out> out;
		const std::vector<uint8_t> p = packet_of(msg);
		const softmove::Take take = r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), p.data(), p.size(), out);
		const MsgSender sender = msg_sender(msg);
		if (sender == MsgSender::HostOnly || sender == MsgSender::TrunkOnly || msg == Msg::Tunnel)
		{
			CHECK(take == softmove::Take::Keep);
			continue;
		}
		const mapserver::Incoming go = mapserver::route_incoming(msg, true, false, true);
		CHECK_EQ(out.size(), size_t(go.tunnel ? 1 : 0));
		CHECK((take == softmove::Take::Keep || take == softmove::Take::SentAndKept) == go.here);
		CHECK((take == softmove::Take::Sent || take == softmove::Take::SentAndKept) == go.tunnel);
	}
	CHECK(seen > 50u);
}

TEST(soft_relay_keeps_what_the_world_keeps_and_says_it_went_on)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> vitals = packet_of(Msg::PlayerVitals);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), vitals.data(), vitals.size(), out) == softmove::Take::SentAndKept);
	CHECK_EQ(out.size(), size_t(1));
}

TEST(soft_relay_leaves_a_world_message_to_the_main_thread)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> money = packet_of(Msg::ReqMoney);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), money.data(), money.size(), out) == softmove::Take::Keep);
	CHECK(out.empty());
}

TEST(soft_relay_leaves_core_and_forbidden_messages_to_the_session)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> chat = packet_of(Msg::Chat);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), chat.data(), chat.size(), out) == softmove::Take::Keep);
	// what the session kicks him for: it does, when it is back
	const std::vector<uint8_t> tunnel = tunnel_of(1, 0, packet_of(Msg::PlayerState));
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), tunnel.data(), tunnel.size(), out) == softmove::Take::Keep);
	const std::vector<uint8_t> reset = packet_of(Msg::SessionReset);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), reset.data(), reset.size(), out) == softmove::Take::Keep);
	const std::vector<uint8_t> up = packet_of(Msg::LevelXferUp);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), up.data(), up.size(), out) == softmove::Take::Keep);
	CHECK(out.empty());
}

TEST(soft_relay_a_tunnel_of_a_map_server_reaches_the_player_on_its_lane)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> inner = packet_of(Msg::EntitySnapshot, {9, 8, 7, 6});
	const std::vector<uint8_t> t = tunnel_of(2, TunnelMsg::LaneBulk, inner);
	CHECK(r.on_packet(&g_ms, 21, uint8_t(Lane::Reliable), t.data(), t.size(), out) == softmove::Take::Sent);
	REQUIRE(out.size() == 1);
	CHECK(out[0].to == &g_b);
	CHECK(out[0].lane == Lane::Bulk);
	CHECK_EQ(out[0].type, uint16_t(Msg::EntitySnapshot));
	CHECK_EQ(out[0].body.size(), size_t(4));
	CHECK_EQ(out[0].body[0], uint8_t(9));
}

TEST(soft_relay_all_on_map_reaches_everybody_of_the_level_and_nobody_else)
{
	Relay r = rig();
	int other;
	r.add_client(&other, 13, 3, 8);
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> t = tunnel_of(0, TunnelMsg::AllOnMap, packet_of(Msg::EntitySnapshot));
	CHECK(r.on_packet(&g_ms, 21, uint8_t(Lane::Reliable), t.data(), t.size(), out) == softmove::Take::Sent);
	REQUIRE(out.size() == 2);
	CHECK(out[0].to != &other && out[1].to != &other);
}

TEST(soft_relay_a_player_of_another_level_hears_nothing_of_it)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> t = tunnel_of(1, 0, packet_of(Msg::EntitySnapshot));
	CHECK(r.on_packet(&g_ms2, 22, uint8_t(Lane::Reliable), t.data(), t.size(), out) == softmove::Take::Dropped);
	const std::vector<uint8_t> nobody = tunnel_of(5, 0, packet_of(Msg::EntitySnapshot));
	CHECK(r.on_packet(&g_ms, 21, uint8_t(Lane::Reliable), nobody.data(), nobody.size(), out) == softmove::Take::Dropped);
	CHECK(out.empty());
}

TEST(soft_relay_what_else_a_map_server_says_waits_for_the_world)
{
	const Relay r = rig();
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> up = packet_of(Msg::LevelXferUp);
	CHECK(r.on_packet(&g_ms, 21, uint8_t(Lane::Reliable), up.data(), up.size(), out) == softmove::Take::Keep);
	const std::vector<uint8_t> bad = {uint8_t(uint16_t(Msg::Tunnel) & 0xFF), uint8_t(uint16_t(Msg::Tunnel) >> 8), 1};
	CHECK(r.on_packet(&g_ms, 21, uint8_t(Lane::Reliable), bad.data(), bad.size(), out) == softmove::Take::Dropped);
	CHECK(out.empty());
}

TEST(soft_relay_a_stranger_and_a_short_packet_stay_with_the_session)
{
	const Relay r = rig();
	int stranger;
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> p = packet_of(Msg::PlayerState);
	CHECK(r.on_packet(&stranger, 1, uint8_t(Lane::Reliable), p.data(), p.size(), out) == softmove::Take::Keep);
	const uint8_t one = 1;
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), &one, 1, out) == softmove::Take::Keep);
	CHECK(r.on_packet(&g_a, 99, uint8_t(Lane::Reliable), p.data(), p.size(), out) == softmove::Take::Keep); // another connection in his slot
	CHECK(out.empty());
}

TEST(soft_relay_a_player_whose_map_server_is_not_listed_is_dropped_like_a_stream)
{
	Relay r;
	r.add_client(&g_a, 11, 1, 7);
	std::vector<Relay::Out> out;
	const std::vector<uint8_t> p = packet_of(Msg::PlayerState);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), p.data(), p.size(), out) == softmove::Take::Dropped);
	const std::vector<uint8_t> vitals = packet_of(Msg::PlayerVitals);
	CHECK(r.on_packet(&g_a, 11, uint8_t(Lane::Reliable), vitals.data(), vitals.size(), out) == softmove::Take::Keep);
}
