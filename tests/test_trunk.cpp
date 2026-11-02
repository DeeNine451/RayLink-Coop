// Anomaly Coop unit tests: the trunk between the host's process and a map server (F3a, plan §1.3) on real sessions over the loopback:
// Hello role MapServer (the token, no player slot), TrunkOnly from a bridge alone, and the two sessions of a map server: the
// connection to the world server and the host of its level, whose players are virtual peers behind Msg::Tunnel. The rig does what
// coop_trunk.cpp does in the game: the host's in-filter tunnels a map message, the Tunnel handlers of both sides unwrap it. A client
// talks to the host's process alone and his session has no idea that a map server exists.
#include "test_util.h"

#include "coop_mapserver_rules.h"

#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
using t::Node;
using levels::wire::TunnelMsg;

constexpr uint32_t kMs = 2; // the number of the map server of the rig

mapserver::Token token_of(uint8_t first)
{
	mapserver::Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 3 * i);
	return out;
}

// The host's process, a map server (its connection `world` and the host of its level `map`), and clients.
struct Trunk
{
	explicit Trunk(uint16_t port) : host("Boss", port), world("ms", port), port_(port)
	{
		host.s.on(Msg::Tunnel, [this](PeerId from, Reader& r) {
			// coop_trunk.cpp host_on_tunnel
			TunnelMsg m;
			if (m.read(r))
			{
				Writer w(m.packet.size());
				w.bytes(m.packet.data() + 2, m.packet.size() - 2);
				host.s.send(m.peer, mapserver::tunnel_lane(m.flags), m.type(), w);
				last_bridge = from;
			}
		});
		world.s.on(Msg::Tunnel, [this](PeerId, Reader& r) {
			// coop_trunk.cpp server_on_tunnel
			TunnelMsg m;
			if (m.read(r))
				map.virtual_receive(m.peer, mapserver::tunnel_lane(m.flags), m.packet.data(), m.packet.size());
		});
		map.set_log([this](const char* line) { world.log.emplace_back(line); });
		host_filter_self() = this;
		host.s.set_in_filter(&Trunk::in_filter);
	}
	~Trunk() { host_filter_self() = nullptr; }

	static Trunk*& host_filter_self()
	{
		static Trunk* self = nullptr;
		return self;
	}

	// coop_trunk.cpp host_incoming: every player of the rig stands on the map server's level.
	static bool in_filter(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		return host_filter_self()->incoming(from, type, lane, packet, size);
	}
	bool incoming(PeerId from, Msg type, Lane lane, const uint8_t* packet, size_t size)
	{
		const mapserver::Incoming go = mapserver::route_incoming(type, true, false, host.s.bridge_connected(mapserver::bridge_peer(kMs)));
		if (go.tunnel)
		{
			TunnelMsg m;
			m.peer = from;
			m.flags = mapserver::tunnel_lane_flags(lane);
			m.packet.assign(packet, packet + size);
			Writer w(size + 8);
			if (m.write(w))
				host.s.send(mapserver::bridge_peer(kMs), lane, Msg::Tunnel, w);
		}
		return go.here;
	}

	void pump_once()
	{
		const uint64_t now = t::now_ms();
		host.s.update(now);
		world.s.update(now);
		map.update(now);
		for (auto& c : clients)
			c->s.update(now);
	}
	bool pump(uint32_t timeout_ms, const std::function<bool()>& done)
	{
		const uint64_t start = t::now_ms();
		for (;;)
		{
			pump_once();
			if (done())
				return true;
			if (t::now_ms() - start > timeout_ms)
				return false;
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
	}

	bool start()
	{
		std::string err;
		return host.host(&err);
	}

	// The map server connects with the token its command line would carry, then hosts its level.
	bool connect_server()
	{
		host.s.issue_bridge(kMs, token_of(7));
		world.cfg.hello_role = kHelloRoleMapServer;
		world.cfg.hello_token = token_of(7);
		std::string err;
		if (!world.connect(port_, &err))
			return false;
		if (!pump(5000, [this] { return world.s.is_active(); }))
			return false;
		return map.host_virtual(world.cfg, world.s, &err);
	}

	Node& add_client(const std::string& nick)
	{
		clients.push_back(std::make_unique<Node>(nick, port_));
		Node& c = *clients.back();
		std::string err;
		REQUIRE(c.connect(port_, &err));
		REQUIRE(pump(5000, [&c] { return c.s.is_active(); }));
		return c;
	}

	Node host;
	Node world;
	Session map;
	PeerId last_bridge = kInvalidPeer;
	std::vector<std::unique_ptr<Node>> clients;

private:
	uint16_t port_;
};

Writer payload(uint32_t v)
{
	Writer w;
	w.u32(v);
	return w;
}
} // namespace

// ---------------------------------------------------------------- Hello

TEST(trunk_hello_only_loopback_token)
{
	Trunk k(37201);
	REQUIRE(k.start());
	// a token the session did not issue
	Node stranger("x", 37201);
	stranger.cfg.hello_role = kHelloRoleMapServer;
	stranger.cfg.hello_token = token_of(9);
	std::string err;
	REQUIRE(stranger.connect(37201, &err));
	const auto both = [&] {
		k.host.s.update(t::now_ms());
		stranger.s.update(t::now_ms());
		return stranger.rejected;
	};
	k.host.s.issue_bridge(kMs, token_of(7));
	const uint64_t start = t::now_ms();
	while (!both() && t::now_ms() - start < 5000)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	CHECK(stranger.rejected);
	CHECK(k.host.s.bridges().empty());
	CHECK(k.host.s.peers().empty());

	// the issued one: a bridge, not a player
	REQUIRE(k.connect_server());
	CHECK_EQ(k.world.s.self(), mapserver::bridge_peer(kMs));
	CHECK_EQ(k.map.self(), mapserver::bridge_peer(kMs));
	REQUIRE(k.host.s.bridges().size() == 1);
	CHECK_EQ(k.host.s.bridges()[0], mapserver::bridge_peer(kMs));
	CHECK(k.host.s.bridge_connected(mapserver::bridge_peer(kMs)));
	CHECK(k.host.s.peers().empty());
	CHECK(k.host.s.players().empty());
}

TEST(trunk_a_token_is_good_once)
{
	Trunk k(37202);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node again("x", 37202);
	again.cfg.hello_role = kHelloRoleMapServer;
	again.cfg.hello_token = token_of(7);
	std::string err;
	REQUIRE(again.connect(37202, &err));
	CHECK(k.pump(5000, [&] {
		again.s.update(t::now_ms());
		return again.rejected;
	}));
	CHECK_EQ(k.host.s.bridges().size(), size_t(1));
}

TEST(trunk_a_revoked_token_is_no_token)
{
	Trunk k(37203);
	REQUIRE(k.start());
	k.host.s.issue_bridge(kMs, token_of(7));
	k.host.s.revoke_bridge(kMs);
	Node late("x", 37203);
	late.cfg.hello_role = kHelloRoleMapServer;
	late.cfg.hello_token = token_of(7);
	std::string err;
	REQUIRE(late.connect(37203, &err));
	CHECK(k.pump(5000, [&] {
		late.s.update(t::now_ms());
		return late.rejected;
	}));
	CHECK(k.host.s.bridges().empty());
}

TEST(trunk_a_map_server_takes_no_player_slot)
{
	Trunk k(37204);
	k.host.cfg.max_players = 2;
	REQUIRE(k.start());
	k.add_client("Al");
	Node late("Bo", 37204); // the session is full ...
	std::string err;
	REQUIRE(late.connect(37204, &err));
	CHECK(k.pump(5000, [&] {
		late.s.update(t::now_ms());
		return late.rejected;
	}));
	CHECK(late.reject.reason == RejectReason::SessionFull);
	REQUIRE(k.connect_server()); // ... and a map server still comes
	CHECK_EQ(k.host.s.peers().size(), size_t(1));
}

TEST(trunk_a_lost_bridge_is_told_and_a_new_process_takes_its_number)
{
	Trunk k(37205);
	std::vector<PeerId> came, went;
	k.host.s.on_bridge_joined = [&](PeerId id) { came.push_back(id); };
	k.host.s.on_bridge_left = [&](PeerId id, const std::string&) { went.push_back(id); };
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	CHECK(k.pump(5000, [&] { return came.size() == 1; }));
	k.map.shutdown("over");
	k.world.s.shutdown("over");
	CHECK(k.pump(5000, [&] { return went.size() == 1; }));
	CHECK(k.host.s.bridges().empty());
	k.host.s.issue_bridge(kMs, token_of(40));
	Node next("ms", 37205);
	next.cfg.hello_role = kHelloRoleMapServer;
	next.cfg.hello_token = token_of(40);
	std::string err;
	REQUIRE(next.connect(37205, &err));
	CHECK(k.pump(5000, [&] {
		next.s.update(t::now_ms());
		return next.s.is_active();
	}));
	CHECK_EQ(next.s.self(), mapserver::bridge_peer(kMs));
}

TEST(trunk_seven_map_servers_stand_beside_a_full_session)
{
	Trunk k(37209);
	REQUIRE(k.start());

	for (int i = 0; i < 7; ++i)
		k.add_client("P" + std::to_string(i));
	std::vector<std::unique_ptr<Node>> servers;
	std::string err;
	for (uint32_t n = 1; n <= mapserver::kMaxBridges; ++n)
	{
		k.host.s.issue_bridge(n, token_of(uint8_t(20 + n)));
		servers.push_back(std::make_unique<Node>("ms", uint16_t(37209)));
		servers.back()->cfg.hello_role = kHelloRoleMapServer;
		servers.back()->cfg.hello_token = token_of(uint8_t(20 + n));
		REQUIRE(servers.back()->connect(37209, &err));
	}
	CHECK(k.pump(10000, [&] {
		for (auto& s : servers)
			s->s.update(t::now_ms());
		return k.host.s.bridges().size() == mapserver::kMaxBridges;
	}));
	CHECK_EQ(k.host.s.peers().size(), size_t(7));
	for (uint32_t n = 1; n <= mapserver::kMaxBridges; ++n)
		CHECK_EQ(servers[n - 1]->s.self(), mapserver::bridge_peer(n));
}

// ---------------------------------------------------------------- TrunkOnly

TEST(trunk_only_messages_pass_from_a_bridge_and_kick_anybody_else)
{
	Trunk k(37206);
	std::vector<PeerId> at_host;
	k.host.s.on(Msg::LevelXferUp, [&at_host](PeerId from, Reader&) { at_host.push_back(from); });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& player = k.add_client("Al");

	k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, Writer());
	CHECK(k.pump(5000, [&] { return !at_host.empty(); }));
	REQUIRE(at_host.size() == 1);
	CHECK_EQ(at_host[0], mapserver::bridge_peer(kMs));
	CHECK(!k.world.disconnected);

	player.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, Writer());
	CHECK(k.pump(5000, [&] { return player.disconnected || player.rejected; }));
	CHECK_EQ(at_host.size(), size_t(1));
}

TEST(trunk_a_tunnel_from_a_player_is_refused)
{
	Trunk k(37207);
	bool ran = false;
	REQUIRE(k.start());
	k.host.s.on(Msg::Tunnel, [&ran](PeerId, Reader&) { ran = true; });
	Node& player = k.add_client("Al");
	TunnelMsg m;
	m.peer = 1;
	m.packet = {uint8_t(uint16_t(Msg::PlayerState) & 0xff), uint8_t(uint16_t(Msg::PlayerState) >> 8)};
	Writer w;
	REQUIRE(m.write(w));
	player.s.send(kHostPeer, Lane::Reliable, Msg::Tunnel, w);
	CHECK(k.pump(5000, [&] { return player.disconnected || player.rejected; }));
	CHECK(!ran);
}

TEST(trunk_a_bridge_is_not_filtered_nor_limited)
{
	Trunk k(37208);
	uint32_t heard = 0;
	k.host.s.on(Msg::LevelHash, [&heard](PeerId, Reader&) { ++heard; });
	k.host.s.limit_rate(Msg::LevelHash, 1, 100000);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	for (int i = 0; i < 20; ++i)
		k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelHash, Writer());
	CHECK(k.pump(5000, [&] { return heard == 20; }));
}

TEST(trunk_a_bridge_knows_the_players_and_the_players_do_not_know_it)
{
	Trunk k(37219);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	REQUIRE(k.pump(5000, [&] { return k.world.s.peer(a.s.self()) != nullptr; }));
	CHECK_EQ(k.world.s.peer(a.s.self())->nick, std::string("Al"));
	CHECK_EQ(a.s.peers().size(), size_t(1)); // the host, nobody else
}

// ---------------------------------------------------------------- the two sessions of a map server

TEST(virtual_a_players_map_message_runs_on_the_map_server_as_his)
{
	Trunk k(37210);
	std::vector<uint32_t> at_map;
	std::vector<PeerId> from_map;
	bool here = false;
	k.host.s.on(Msg::PlayerShot, [&here](PeerId, Reader&) { here = true; });
	k.map.on(Msg::PlayerShot, [&](PeerId from, Reader& r) {
		from_map.push_back(from);
		at_map.push_back(r.u32());
	});
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	k.map.virtual_join(a.s.self(), "Al");
	k.pump_once();
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(4711));
	REQUIRE(k.pump(5000, [&] { return !at_map.empty(); }));
	CHECK_EQ(at_map[0], 4711u);
	CHECK_EQ(from_map[0], a.s.self());
	CHECK(!here); // the world server does not act on the stream of another level
}

TEST(virtual_what_the_map_server_sends_reaches_the_player_from_the_host)
{
	Trunk k(37211);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	std::vector<uint32_t> got;
	std::vector<PeerId> from;
	a.s.on(Msg::ReqResult, [&](PeerId f, Reader& r) {
		from.push_back(f);
		got.push_back(r.u32());
	});
	k.map.virtual_join(a.s.self(), "Al");
	k.map.send(a.s.self(), Lane::Reliable, Msg::ReqResult, payload(99));
	REQUIRE(k.pump(5000, [&] { return !got.empty(); }));
	CHECK_EQ(got[0], 99u);
	CHECK_EQ(from[0], kHostPeer); // his session talks to the host, there is nothing else for it
	CHECK_EQ(k.last_bridge, mapserver::bridge_peer(kMs));
}

TEST(virtual_two_clients_on_one_level_see_each_other_through_the_map_server)
{
	Trunk k(37212);
	k.map.on(Msg::PlayerShot, [&k](PeerId from, Reader& r) {
		Writer w;
		w.u32(r.u32());
		k.map.broadcast(Lane::Reliable, Msg::PlayerShot, w, from); // the host's code of a level: to the others
	});
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	Node& b = k.add_client("Bo");
	std::vector<uint32_t> at_a, at_b;
	a.s.on(Msg::PlayerShot, [&at_a](PeerId, Reader& r) { at_a.push_back(r.u32()); });
	b.s.on(Msg::PlayerShot, [&at_b](PeerId, Reader& r) { at_b.push_back(r.u32()); });
	k.map.virtual_join(a.s.self(), "Al");
	k.map.virtual_join(b.s.self(), "Bo");
	k.pump_once();
	CHECK_EQ(k.map.peers().size(), size_t(2));
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(5));
	REQUIRE(k.pump(5000, [&] { return !at_b.empty(); }));
	CHECK_EQ(at_b[0], 5u);
	CHECK(at_a.empty());
}

TEST(virtual_an_unreliable_stream_keeps_its_lane)
{
	Trunk k(37213);
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	std::vector<uint32_t> got;
	a.s.on(Msg::EntitySnapshot, [&got](PeerId, Reader& r) { got.push_back(r.u32()); });
	k.map.virtual_join(a.s.self(), "Al");
	k.map.send(a.s.self(), Lane::Unreliable, Msg::EntitySnapshot, payload(1));
	CHECK(k.pump(5000, [&] { return !got.empty(); }));
	CHECK_EQ(k.world.s.stats(uint16_t(Msg::Tunnel)).sent_count, 1ull);
}

TEST(virtual_it_asks_the_world_server_as_a_client)
{
	Trunk k(37214);
	std::vector<PeerId> from;
	k.host.s.on(Msg::ReqMoney, [&from](PeerId f, Reader&) { from.push_back(f); });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	k.map.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, Writer());
	REQUIRE(k.pump(5000, [&] { return !from.empty(); }));
	CHECK_EQ(from[0], mapserver::bridge_peer(kMs));
}

TEST(virtual_a_player_who_left_is_nobody_here)
{
	Trunk k(37215);
	uint32_t ran = 0;
	k.map.on(Msg::PlayerShot, [&ran](PeerId, Reader&) { ++ran; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	std::vector<PeerId> joined, left;
	k.map.on_peer_joined = [&](const PeerInfo& p) { joined.push_back(p.id); };
	k.map.on_peer_left = [&](PeerId id, const std::string&) { left.push_back(id); };
	k.map.virtual_join(3, "Cy");
	k.pump_once();
	REQUIRE(joined.size() == 1);
	const uint8_t packet[6] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8), 1, 0, 0, 0};
	k.map.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u);
	k.map.virtual_leave(3, "he moved");
	k.pump_once();
	REQUIRE(left.size() == 1);
	CHECK(k.map.peers().empty());
	k.map.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u);
}

TEST(virtual_a_message_only_the_host_sends_is_ignored_and_nobody_is_kicked)
{
	Trunk k(37216);
	uint32_t ran = 0;
	k.map.on(Msg::ReqResult, [&ran](PeerId, Reader&) { ++ran; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	k.map.virtual_join(3, "Cy");
	k.pump_once();
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::SessionReset) & 0xff), uint8_t(uint16_t(Msg::SessionReset) >> 8)};
	k.map.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(k.map.peers().size(), size_t(1));
	CHECK(k.world.s.is_active());
}

TEST(virtual_the_epoch_is_the_worlds)
{
	Trunk k(37217);
	k.host.s.set_world_epoch(4);
	REQUIRE(k.start());
	k.host.s.set_world_epoch(4);
	REQUIRE(k.connect_server());
	CHECK_EQ(k.world.s.world_epoch(), 4u);
	CHECK_EQ(k.map.world_epoch(), 4u);
	uint32_t ran = 0;
	k.map.on(Msg::PlayerShot, [&ran](PeerId, Reader&) { ++ran; });
	k.map.virtual_join(3, "Cy");
	k.host.s.set_world_epoch(5);
	k.map.set_world_epoch(5); // the game does it at the SessionReset: both of its sessions move
	CHECK_EQ(k.world.s.world_epoch(), 5u);
	k.pump_once();
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8)};
	k.map.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	k.pump_once();
	CHECK_EQ(ran, 1u); // a virtual peer is in the world of its map server
}

TEST(virtual_a_broadcast_of_the_world_reaches_the_bridge_and_a_stream_does_not)
{
	Trunk k(37218);
	uint32_t world = 0, stream = 0;
	k.world.s.on(Msg::TimeSync, [&world](PeerId, Reader&) { ++world; });
	k.world.s.on(Msg::EntitySnapshot, [&stream](PeerId, Reader&) { ++stream; });
	REQUIRE(k.start());
	REQUIRE(k.connect_server());
	Node& a = k.add_client("Al");
	uint32_t at_a = 0;
	a.s.on(Msg::EntitySnapshot, [&at_a](PeerId, Reader&) { ++at_a; });
	k.host.s.broadcast(Lane::Reliable, Msg::EntitySnapshot, Writer());
	k.host.s.broadcast(Lane::Reliable, Msg::TimeSync, Writer());
	CHECK(k.pump(5000, [&] { return world == 1 && at_a == 1; }));
	CHECK_EQ(stream, 0u);
}

// ---------------------------------------------------------------- the host's move (Session::soft_park, xrCoop/coop_soft_move.h)

namespace
{
// The rig at the go: a player on the level of the map server; the host's main thread stops here.
struct Move : Trunk
{
	explicit Move(uint16_t port) : Trunk(port)
	{
		REQUIRE(start());
		REQUIRE(connect_server());
		a = &add_client("Al");
		map.virtual_join(a->s.self(), "Al");
		pump_once();
	}
	void park()
	{
		host.s.soft_park({Session::SoftPlayer{a->s.self(), 7}}, {Session::SoftServer{mapserver::bridge_peer(kMs), 7}});
	}
	// Everybody but the host's main thread.
	bool away(uint32_t timeout_ms, const std::function<bool()>& done)
	{
		const uint64_t start = t::now_ms();
		for (;;)
		{
			const uint64_t now = t::now_ms();
			world.s.update(now);
			map.update(now);
			for (auto& c : clients)
				c->s.update(now);
			if (done())
				return true;
			if (t::now_ms() - start > timeout_ms)
				return false;
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
	}
	Node* a = nullptr;
};
} // namespace

TEST(soft_a_player_and_his_map_server_talk_while_the_host_loads)
{
	Move k(37230);
	std::vector<uint32_t> at_map, at_player;
	k.map.on(Msg::PlayerShot, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, k.a->s.self());
		at_map.push_back(r.u32());
	});
	k.a->s.on(Msg::ReqResult, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		at_player.push_back(r.u32());
	});
	k.park();
	k.away(1300, [] { return false; }); // longer than the helper keeps a link without an owner
	k.a->s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(1));
	k.map.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(2));
	REQUIRE(k.away(3000, [&] { return !at_map.empty() && !at_player.empty(); }));
	CHECK_EQ(at_map[0], 1u);
	CHECK_EQ(at_player[0], 2u);
	const Session::SoftStats st = k.host.s.soft_stats();
	CHECK_EQ(st.to_servers, uint64_t(1));
	CHECK_EQ(st.to_players, uint64_t(1));
}

TEST(soft_what_a_parked_player_says_to_the_world_waits_and_keeps_its_order)
{
	Move k(37231);
	std::vector<uint32_t> got;
	k.host.s.on(Msg::ReqMoney, [&](PeerId, Reader& r) { got.push_back(r.u32()); });
	k.park();
	for (uint32_t i = 0; i < 40; ++i)
		k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(i));
	k.away(200, [] { return false; });
	t::pump_for({&k.host.s}, 100); // the frames of the old world, of the new one: the parking holds
	CHECK(got.empty());
	k.host.s.soft_release();
	REQUIRE(k.pump(3000, [&] { return got.size() == 40; }));
	for (uint32_t i = 0; i < 40; ++i)
		CHECK_EQ(got[i], i);
}

TEST(soft_the_parking_lasts_until_the_inbox_is_empty_too)
{
	// A connection's queue can run dry while the transport still holds what the road sent on: read outside the parking, it would go
	// to the map server a second time.
	Move k(37233);
	std::vector<uint32_t> at_map;
	k.map.on(Msg::PlayerVitals, [&](PeerId, Reader& r) { at_map.push_back(r.u32()); });
	k.park();
	k.away(1300, [] { return false; }); // longer than the helper keeps a link without an owner
	for (uint32_t i = 0; i < 5; ++i)
		k.a->s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, payload(i));
	REQUIRE(k.away(3000, [&] { return at_map.size() == 5; }));
	k.host.s.limit_events_per_update(1);
	k.host.s.soft_release();
	CHECK(k.host.s.soft_replaying());
	k.pump(400, [] { return false; });
	CHECK(!k.host.s.soft_replaying());
	CHECK_EQ(at_map.size(), size_t(5));
}

TEST(soft_the_epoch_moves_under_the_parked_without_a_word)
{
	Move k(37232);
	const uint32_t before = k.a->s.world_epoch();
	std::vector<uint32_t> at_world;
	k.host.s.on(Msg::ReqMoney, [&](PeerId, Reader& r) { at_world.push_back(r.u32()); });
	std::vector<uint32_t> at_player, at_bridge;
	k.a->s.on(Msg::ReqResult, [&](PeerId, Reader& r) { at_player.push_back(r.u32()); });
	k.world.s.on(Msg::LevelXferDown, [&](PeerId, Reader& r) { at_bridge.push_back(r.u32()); });
	k.park();
	k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(1));
	k.away(100, [] { return false; });
	k.host.s.set_world_epoch(before + 1);
	k.host.s.soft_keep_out();
	k.host.s.soft_release();
	k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(2));
	k.host.s.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(3));
	k.host.s.send(mapserver::bridge_peer(kMs), Lane::Reliable, Msg::LevelXferDown, payload(4));
	REQUIRE(k.pump(3000, [&] { return at_world.size() == 2 && !at_player.empty() && !at_bridge.empty(); }));
	CHECK_EQ(k.a->s.world_epoch(), before); // he has not heard of it, and he is not disconnected or stale for it
	CHECK(!k.host.logged("dropped: made in world epoch"));
}

// A message the world keeps and the map server needs too: the road sent it, the session must not tunnel it a second time.
TEST(soft_what_goes_both_ways_reaches_the_map_server_once)
{
	Move k(37233);
	uint32_t at_map = 0, at_world = 0;
	k.map.on(Msg::PlayerVitals, [&](PeerId, Reader&) { ++at_map; });
	k.host.s.on(Msg::PlayerVitals, [&](PeerId, Reader&) { ++at_world; });
	k.park();
	k.a->s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, payload(1));
	REQUIRE(k.away(3000, [&] { return at_map == 1; }));
	CHECK_EQ(at_world, 0u);
	k.host.s.soft_release();
	REQUIRE(k.pump(3000, [&] { return at_world == 1; }));
	k.away(100, [] { return false; });
	CHECK_EQ(at_map, 1u);
}

TEST(soft_what_the_old_world_says_to_the_parked_is_gone_and_the_new_worlds_comes_first)
{
	Move k(37234);
	std::vector<uint32_t> got;
	k.a->s.on(Msg::ReqResult, [&](PeerId, Reader& r) { got.push_back(r.u32()); });
	k.park();
	k.host.s.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(1)); // the old world's last frames
	k.host.s.soft_keep_out(); // the new world exists
	k.host.s.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(2));
	k.host.s.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(3));
	t::pump_for({&k.host.s, &k.a->s}, 100);
	CHECK(got.empty());
	k.host.s.soft_release();
	k.host.s.send(k.a->s.self(), Lane::Reliable, Msg::ReqResult, payload(4));
	REQUIRE(k.pump(3000, [&] { return got.size() == 3; }));
	CHECK_EQ(got[0], 2u);
	CHECK_EQ(got[1], 3u);
	CHECK_EQ(got[2], 4u);
	const Session::SoftStats st = k.host.s.soft_stats();
	CHECK_EQ(st.dropped_out, uint64_t(1));
	CHECK_EQ(st.held_out, uint64_t(2));
}

// The bucket of a client knows one arrival time; his messages of a minute run in one go, and a lost script event is lost for good.
TEST(soft_what_waited_is_no_flood)
{
	Move k(37235);
	k.host.s.limit_rate(Msg::ReqMoney, 1, 1000000);
	uint32_t got = 0;
	k.host.s.on(Msg::ReqMoney, [&](PeerId, Reader&) { ++got; });
	k.park();
	for (uint32_t i = 0; i < 5; ++i)
		k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(i));
	k.away(200, [] { return false; });
	k.host.s.soft_release();
	REQUIRE(k.pump(3000, [&] { return got == 5; }));
}

// What runs in slices after the move: what comes meanwhile stays behind it.
TEST(soft_what_comes_during_the_replay_goes_behind_it)
{
	Move k(37236);
	std::vector<uint32_t> got;
	k.host.s.on(Msg::ReqMoney, [&](PeerId, Reader& r) { got.push_back(r.u32()); });
	k.park();
	constexpr uint32_t kMany = 3000;
	for (uint32_t i = 0; i < kMany; ++i)
	{
		k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(i));
		if (i % 256 == 0)
			k.a->s.update(t::now_ms());
	}
	k.away(500, [] { return false; });
	t::pump_for({&k.host.s}, 50); // into the parked queue
	k.host.s.soft_release();
	k.a->s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(kMany));
	REQUIRE(k.pump(5000, [&] { return got.size() == kMany + 1; }));
	for (uint32_t i = 0; i <= kMany; ++i)
		CHECK_EQ(got[i], i);
}

// The world's traffic of a map server waits like a player's.
TEST(soft_what_a_map_server_tells_the_world_waits_too)
{
	Move k(37237);
	std::vector<uint32_t> got;
	k.host.s.on(Msg::LevelXferUp, [&](PeerId, Reader& r) { got.push_back(r.u32()); });
	k.park();
	k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, payload(1));
	k.world.s.send(kHostPeer, Lane::Reliable, Msg::LevelXferUp, payload(2));
	k.away(200, [] { return false; });
	t::pump_for({&k.host.s}, 100);
	CHECK(got.empty());
	k.host.s.soft_release();
	REQUIRE(k.pump(3000, [&] { return got.size() == 2; }));
	CHECK_EQ(got[0], 1u);
	CHECK_EQ(got[1], 2u);
}

// Who is not in the move goes the ordinary way all the time.
TEST(soft_a_player_who_is_not_parked_is_not_touched)
{
	Move k(37238);
	Node& b = k.add_client("Bo");
	std::vector<uint32_t> at_world, at_player;
	k.host.s.on(Msg::ReqMoney, [&](PeerId, Reader& r) { at_world.push_back(r.u32()); });
	b.s.on(Msg::ReqResult, [&](PeerId, Reader& r) { at_player.push_back(r.u32()); });
	k.park();
	CHECK(k.host.s.soft_parked(k.a->s.self()));
	CHECK(!k.host.s.soft_parked(b.s.self()));
	b.s.send(kHostPeer, Lane::Reliable, Msg::ReqMoney, payload(1));
	k.host.s.send(b.s.self(), Lane::Reliable, Msg::ReqResult, payload(2));
	REQUIRE(k.pump(3000, [&] { return !at_world.empty() && !at_player.empty(); }));
}

// He leaves in the middle: he is gone when the session hears it, what he said with him, nobody else is touched.
TEST(soft_a_parked_player_who_leaves_leaves)
{
	Move k(37239);
	Node& b = k.add_client("Bo");
	k.map.virtual_join(b.s.self(), "Bo");
	std::vector<uint32_t> at_map;
	k.map.on(Msg::PlayerShot, [&](PeerId, Reader& r) { at_map.push_back(r.u32()); });
	k.host.s.soft_park({Session::SoftPlayer{k.a->s.self(), 7}, Session::SoftPlayer{b.s.self(), 7}},
	    {Session::SoftServer{mapserver::bridge_peer(kMs), 7}});
	const PeerId gone = k.a->s.self();
	k.a->s.shutdown("bye");
	k.away(300, [] { return false; });
	b.s.send(kHostPeer, Lane::Reliable, Msg::PlayerShot, payload(5));
	REQUIRE(k.away(3000, [&] { return !at_map.empty(); }));
	k.host.s.soft_release();
	REQUIRE(k.pump(5000, [&] { return !k.host.left.empty(); }));
	CHECK_EQ(k.host.left[0].first, gone);
}
