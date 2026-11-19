// Anomaly Coop unit tests: the server's part of a session (srv::SessionSrv, xrCoop/srv/coop_session_srv.h; docs/MODES.md section 4,
// critique H10) on real sessions over 127.0.0.1. One test per mode: Server (a world server's bridges and operator, a map server's
// level hosted through its world connection), Co-op (a co-op host has no server part: no bridge, no operator) and none (a session
// that hosts nothing takes nothing). Ports 38641+n.
#include "test_util.h"

#include "coop_mapserver_rules.h"
#include "srv/coop_session_srv.h"

#include <array>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

using namespace coop;

namespace
{
using srv::SessionSrv;
using t::Node;
using Token = std::array<uint8_t, kHelloTokenSize>;

Token token_of(uint8_t first)
{
	Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 5 * i + 1);
	return out;
}

void present(Node& n, const Token& t) { std::memcpy(n.cfg.hello_token.data(), t.data(), t.size()); }

// A map server's connection to the world server: Hello role MapServer with the token of its command line.
void as_map_server(Node& n, const Token& t)
{
	n.cfg.hello_role = kHelloRoleMapServer;
	present(n, t);
}

bool join(Node& host, Node& c, uint16_t port)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	return t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed || c.rejected; }) && c.welcomed;
}

bool refused(Node& host, Node& c, uint16_t port)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	return t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed || c.rejected; }) && c.rejected;
}

Writer payload(uint32_t v)
{
	Writer w;
	w.u32(v);
	return w;
}
} // namespace

// ============================================================================ Server: the world server's bridges

TEST(session_srv_bridge_needs_an_issued_token)
{
	Node host("world", 38641), stranger("x", 38641), ms("ms", 38641);
	host.cfg.host_plays = false; // a world server: its own seat plays no character
	std::vector<PeerId> came;
	SessionSrv(host.s).on_bridge_joined([&came](PeerId id) { came.push_back(id); });
	std::string err;
	REQUIRE(host.host(&err));

	// a token this session never issued: refused, nobody is a bridge
	as_map_server(stranger, token_of(9));
	CHECK(refused(host, stranger, 38641));
	CHECK(SessionSrv(host.s).bridges().empty());

	// the issued one: a bridge under its number's id, in no list of players
	SessionSrv(host.s).issue_bridge(3, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, 38641));
	REQUIRE(t::pump_until({&host.s, &ms.s}, 5000, [&came] { return !came.empty(); }));
	CHECK_EQ(ms.s.self(), mapserver::bridge_peer(3));
	CHECK_EQ(came[0], mapserver::bridge_peer(3));
	const std::vector<PeerId> b = SessionSrv(host.s).bridges();
	REQUIRE(b.size() == 1);
	CHECK_EQ(b[0], mapserver::bridge_peer(3));
	CHECK(SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(3)));
	CHECK(!SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(4)));
	CHECK(host.s.peers().empty());
	CHECK(host.s.players().empty());
}

TEST(session_srv_bridge_token_is_good_once_and_revoked_is_none)
{
	Node host("world", 38642), ms("ms", 38642), again("x", 38642), late("y", 38642), zero("z", 38642);
	host.cfg.host_plays = false;
	std::string err;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, 38642));

	as_map_server(again, token_of(7)); // one process, one use
	CHECK(refused(host, again, 38642));

	SessionSrv(host.s).issue_bridge(4, token_of(8));
	SessionSrv(host.s).revoke_bridge(4); // its process was given up on
	as_map_server(late, token_of(8));
	CHECK(refused(host, late, 38642));

	SessionSrv(host.s).issue_bridge(0, token_of(11)); // no map server has number 0
	as_map_server(zero, token_of(11));
	CHECK(refused(host, zero, 38642));

	const std::vector<PeerId> b = SessionSrv(host.s).bridges();
	REQUIRE(b.size() == 1);
	CHECK_EQ(b[0], mapserver::bridge_peer(2));
}

TEST(session_srv_a_lost_bridge_is_told)
{
	Node host("world", 38643), ms("ms", 38643);
	host.cfg.host_plays = false;
	std::vector<std::pair<PeerId, std::string>> went;
	SessionSrv(host.s).on_bridge_left([&went](PeerId id, const std::string& why) { went.emplace_back(id, why); });
	std::string err;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, 38643));
	REQUIRE(SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(2)));
	ms.s.shutdown("over");
	REQUIRE(t::pump_until({&host.s}, 5000, [&went] { return !went.empty(); }));
	CHECK_EQ(went[0].first, mapserver::bridge_peer(2));
	CHECK(SessionSrv(host.s).bridges().empty());
	CHECK(!SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(2)));
}

// ============================================================================ Server: a map server's level

TEST(session_srv_a_map_servers_level_is_hosted_through_its_world_connection)
{
	Node host("world", 38644), ms("ms", 38644);
	host.cfg.host_plays = false;
	std::vector<levels::wire::TunnelMsg> up;
	std::vector<PeerId> up_from;
	host.s.on(Msg::Tunnel, [&](PeerId from, Reader& r) {
		levels::wire::TunnelMsg m;
		if (m.read(r))
		{
			up.push_back(m);
			up_from.push_back(from);
		}
	});
	std::string err;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, 38644));

	Session level; // after `ms`: the world connection outlives the level hosted through it
	CHECK(!SessionSrv(level).is_virtual());
	REQUIRE(SessionSrv(level).host_virtual(ms.cfg, ms.s, &err));
	CHECK(SessionSrv(level).is_virtual());
	CHECK(level.is_active());
	CHECK_EQ(level.self(), mapserver::bridge_peer(2)); // toward the world it is its bridge
	CHECK(level.session_mode() == SessionMode::Server); // its level is part of its world's session

	std::vector<PeerId> joined, left;
	level.on_peer_joined = [&joined](const PeerInfo& p) { joined.push_back(p.id); };
	level.on_peer_left = [&left](PeerId id, const std::string&) { left.push_back(id); };
	SessionSrv(level).virtual_join(5, "Cy");
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&joined] { return !joined.empty(); }));
	CHECK_EQ(joined[0], PeerId(5));
	REQUIRE(level.peers().size() == 1);
	CHECK_EQ(level.peers()[0].nick, std::string("Cy"));

	// what the level's host code sends him goes up its world connection in a Tunnel
	level.send(5, Lane::Reliable, Msg::ReqResult, payload(99));
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 5000, [&up] { return !up.empty(); }));
	CHECK_EQ(up[0].peer, 5u);
	CHECK(up[0].type() == Msg::ReqResult);
	CHECK(mapserver::tunnel_lane(up[0].flags) == Lane::Reliable);
	CHECK_EQ(up_from[0], mapserver::bridge_peer(2));

	// what he sent comes down in one and runs here as his
	uint32_t got = 0;
	PeerId by = kInvalidPeer;
	level.on(Msg::PlayerShot, [&](PeerId from, Reader& r) {
		by = from;
		got = r.u32();
	});
	const uint8_t packet[6] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8), 7, 0, 0, 0};
	SessionSrv(level).virtual_receive(5, Lane::Reliable, packet, sizeof(packet));
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&got] { return got != 0; }));
	CHECK_EQ(got, 7u);
	CHECK_EQ(by, PeerId(5));

	// he went to another level: nobody here, and a late Tunnel of his runs nothing
	SessionSrv(level).virtual_leave(5, "he moved");
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&left] { return !left.empty(); }));
	CHECK(level.peers().empty());
	got = 0;
	SessionSrv(level).virtual_receive(5, Lane::Reliable, packet, sizeof(packet));
	t::pump_for({&host.s, &ms.s, &level}, 50);
	CHECK_EQ(got, 0u);
	level.shutdown("over");
}

// ============================================================================ Server: the operator of a world server

TEST(session_srv_operator_token_makes_the_operator_and_his_lines_reach_the_hook)
{
	Node host("server", 38645), creator("Creator", 38645), other("Other", 38645);
	host.cfg.host_plays = false;
	std::vector<std::pair<PeerId, std::string>> got;
	SessionSrv(host.s).on_operator_command([&got](PeerId from, const std::string& line) { got.emplace_back(from, line); });
	const Token tok = token_of(5);
	present(creator, tok);
	std::string err;
	REQUIRE(SessionSrv(host.s).host(host.cfg, tok, &err));
	for (uint8_t b : host.cfg.operator_token)
		CHECK_EQ(b, uint8_t(0)); // the caller's config never held the token: the session has its own copy
	REQUIRE(join(host, creator, 38645));
	REQUIRE(join(host, other, 38645));
	REQUIRE(t::pump_until({&host.s, &creator.s, &other.s}, 5000, [&] { return creator.s.self_host_rights(); }));
	CHECK(!other.s.self_host_rights());

	CHECK(creator.s.send_operator_command("coop_status"));
	CHECK(creator.s.send_operator_command("quit")); // not on the list: refused
	CHECK(other.s.send_operator_command("coop_status")); // not the operator: refused
	REQUIRE(t::pump_until({&host.s, &creator.s, &other.s}, 3000, [&got] { return !got.empty(); }));
	t::pump_for({&host.s, &creator.s, &other.s}, 200);
	REQUIRE(got.size() == 1);
	CHECK_EQ(got[0].first, creator.welcome.slot);
	CHECK_EQ(got[0].second, std::string("coop_status"));
	CHECK_EQ(SessionSrv(host.s).operator_refused(), uint64_t(2));
	CHECK(creator.s.is_active() && other.s.is_active()); // a refusal is no kick
}

TEST(session_srv_host_that_cannot_start_says_why)
{
	Node host("server", 38646);
	host.cfg.host_plays = false;
	std::string err;
	REQUIRE(SessionSrv(host.s).host(host.cfg, token_of(5), &err));
	CHECK(!SessionSrv(host.s).host(host.cfg, token_of(6), &err)); // one session, one host()
	CHECK_EQ(err, std::string("session is already active"));
	CHECK(host.s.is_active());
	Node other("other", 38648);
	other.cfg.mode = SessionMode::Server; // a seat that plays with the Server mode: refused by the session as it is
	other.cfg.host_plays = true;
	err.clear();
	CHECK(!SessionSrv(other.s).host(other.cfg, token_of(5), &err));
	CHECK(!err.empty());
	CHECK(!other.s.is_active());
}

// ============================================================================ Co-op: a co-op host has no server part

TEST(session_srv_a_coop_host_has_no_server_part)
{
	Node host("Host", 38647), pal("Pal", 38647), ms("ms", 38647);
	std::string err;
	REQUIRE(host.host(&err)); // a co-op host: its seat plays; it issues no bridge and holds no operator token
	present(pal, token_of(5)); // a player who presents a token anyway
	REQUIRE(join(host, pal, 38647));
	t::pump_for({&host.s, &pal.s}, 100);
	CHECK(!pal.s.self_host_rights());
	CHECK((pal.welcome.flags & WelcomeMsg::HostSeatPlays) != 0);
	CHECK(pal.welcome.mode == SessionMode::Coop);
	as_map_server(ms, token_of(5)); // nobody issued it a token: no map server comes into a co-op session
	CHECK(refused(host, ms, 38647));
	CHECK(SessionSrv(host.s).bridges().empty());
	CHECK(!SessionSrv(host.s).is_virtual());
	CHECK_EQ(SessionSrv(host.s).operator_refused(), uint64_t(0));
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

// ============================================================================ none: a session that hosts nothing

TEST(session_srv_outside_a_session_takes_nothing)
{
	Session idle;
	SessionSrv v(idle);
	v.issue_bridge(1, token_of(3)); // not hosting: no token is kept
	CHECK(v.bridges().empty());
	CHECK(!v.bridge_connected(mapserver::bridge_peer(1)));
	CHECK(!v.is_virtual());
	v.virtual_join(3, "x"); // not a level's host: nobody joins
	CHECK(idle.peers().empty());
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8)};
	v.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	v.virtual_leave(3, "x");
	CHECK(idle.peers().empty());
	CHECK_EQ(v.operator_refused(), uint64_t(0));
	CHECK(!idle.is_active());
}
