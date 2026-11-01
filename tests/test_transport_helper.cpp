// Anomaly Coop unit tests: the transport's helper thread pumps ENet between the owner's frames (owner 2026-10-24:
// "frames must not affect the ping"). Events it takes wait in an inbox for the owner; what the owner believes about a
// peer must stay true until it has seen the event that changes it, exactly as when the owner pumped ENet alone.
#include "test_util.h"

#include "coop_transport.h"

#include <chrono>
#include <memory>
#include <string>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
// The owner side of one transport: every event its service() hands out, in order.
struct Side
{
	net::Transport tr;
	std::vector<net::Event> got;

	void pump()
	{
		net::Event ev;
		while (tr.service(ev) > 0)
			got.push_back(std::move(ev));
	}
	size_t count(net::Event::Type type) const
	{
		size_t n = 0;
		for (const net::Event& e : got)
			n += e.type == type;
		return n;
	}
	// Index in `got` of the n-th (0-based) event of `type`; got.size() if there is none.
	size_t index(net::Event::Type type, size_t n = 0) const
	{
		for (size_t i = 0; i < got.size(); ++i)
			if (got[i].type == type && n-- == 0)
				return i;
		return got.size();
	}
};

template <class F>
bool pump_until(std::initializer_list<Side*> sides, uint32_t ms, F done)
{
	const uint64_t start = t::now_ms();
	for (;;)
	{
		for (Side* s : sides)
			s->pump();
		if (done())
			return true;
		if (t::now_ms() - start >= ms)
			return false;
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}

// Only the other sides pump: the host's owner is between frames (its helper keeps its link, it sees no events).
void others_for(std::initializer_list<Side*> sides, uint32_t ms)
{
	pump_until(sides, ms, [] { return false; });
}

net::Packet small_packet(uint16_t type)
{
	const uint8_t body[4] = {1, 2, 3, 4};
	return net::Transport::make_packet(Lane::Reliable, type, body, sizeof(body), nullptr, 0, {});
}

void connect_one(Side& host, Side& cl, uint16_t port, net::PeerHandle* host_side, net::PeerHandle* client_side)
{
	std::string err;
	REQUIRE(host.tr.listen(port, 4, &err));
	*client_side = cl.tr.connect("127.0.0.1", port, &err);
	REQUIRE(*client_side != nullptr);
	REQUIRE(pump_until({&host, &cl}, 5000, [&] {
		return host.count(net::Event::Type::Connect) == 1 && cl.count(net::Event::Type::Connect) == 1;
	}));
	*host_side = host.got[host.index(net::Event::Type::Connect)].peer;
}
} // namespace

// A leaves and B arrives while the host's owner is between frames. Its helper must not free A's slot (ENet frees it
// when it hands out the DISCONNECT): B would take it, and what the owner still sends "to A" would reach B.
TEST(transport_helper_keeps_a_left_peers_slot_until_the_owner_saw_it_leave)
{
	constexpr uint16_t kPort = 37901;
	Side host, a, b;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump(); // the owner's last frame for now
	net::Transport::disconnect_now(a_peer);
	std::this_thread::sleep_for(std::chrono::milliseconds(100)); // the host's helper took A's goodbye
	std::string err;
	REQUIRE(b.tr.connect("127.0.0.1", kPort, &err) != nullptr);
	REQUIRE(pump_until({&b}, 1500, [&] { return b.count(net::Event::Type::Connect) == 1; })); // the helper let B in

	// The owner has not seen A leave: it still sends to A.
	CHECK(!host.tr.send(on_a, Lane::Reliable, small_packet(0x7001)));
	others_for({&b}, 300);
	CHECK_EQ(b.count(net::Event::Type::Receive), size_t(0));

	// Its next frame: A's leave, then B, on another slot.
	REQUIRE(pump_until({&host, &b}, 2000, [&] {
		return host.count(net::Event::Type::Disconnect) == 1 && host.count(net::Event::Type::Connect) == 2;
	}));
	CHECK(host.got[host.index(net::Event::Type::Disconnect)].peer == on_a);
	CHECK(host.index(net::Event::Type::Disconnect) < host.index(net::Event::Type::Connect, 1));
	CHECK(host.got[host.index(net::Event::Type::Connect, 1)].peer != on_a);
}

// The helper took A's packets into the inbox; then the owner resets A (a replaced link, a kick). ENet would have wiped
// them with the peer's queues: the owner must not get them after the reset.
TEST(transport_helper_inbox_forgets_a_peer_the_owner_reset)
{
	constexpr uint16_t kPort = 37902;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	for (uint16_t i = 0; i < 3; ++i)
		REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(uint16_t(0x7010 + i))));
	a.tr.flush();
	others_for({&a}, 150); // the host's helper took them
	net::Transport::reset(on_a);
	host.pump();
	CHECK_EQ(host.count(net::Event::Type::Receive), size_t(0));
}

// Between the owner's frames the helper hands nothing over, but the link stays prompt: a packet sent to us is
// delivered at the owner's next frame, in order, and nothing is lost or duplicated.
TEST(transport_helper_hands_over_packets_in_order)
{
	constexpr uint16_t kPort = 37903;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	for (uint16_t i = 0; i < 50; ++i)
		REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(uint16_t(0x7100 + i))));
	a.tr.flush();
	others_for({&a}, 150);
	REQUIRE(pump_until({&host, &a}, 2000, [&] { return host.count(net::Event::Type::Receive) == 50; }));
	others_for({&host, &a}, 50);
	CHECK_EQ(host.count(net::Event::Type::Receive), size_t(50));
	uint16_t want = 0x7100;
	for (const net::Event& e : host.got)
		if (e.type == net::Event::Type::Receive)
		{
			REQUIRE(e.bytes.size() >= 2);
			CHECK_EQ(uint16_t(e.bytes[0] | (e.bytes[1] << 8)), want);
			++want;
		}
}

// A sends its last word (a Reject, a Bye) and leaves while the host's owner is between frames. The helper took the
// packet before the goodbye came: the owner gets it, then the DISCONNECT (vault ENet gotcha 10: the goodbye wiped it).
TEST(transport_helper_hands_over_a_leaving_peers_last_packet)
{
	constexpr uint16_t kPort = 37904;
	Side host, a;
	net::PeerHandle on_a = nullptr, a_peer = nullptr;
	connect_one(host, a, kPort, &on_a, &a_peer);

	host.pump();
	REQUIRE(a.tr.send(a_peer, Lane::Reliable, small_packet(0x7201)));
	a.tr.flush();
	others_for({&a}, 100); // the host's helper took it
	net::Transport::disconnect_now(a_peer);
	std::this_thread::sleep_for(std::chrono::milliseconds(100)); // and the goodbye
	REQUIRE(pump_until({&host}, 2000, [&] { return host.count(net::Event::Type::Disconnect) == 1; }));
	REQUIRE(host.count(net::Event::Type::Receive) == 1);
	CHECK(host.index(net::Event::Type::Receive) < host.index(net::Event::Type::Disconnect));
}

// ---------------------------------------------------------------- the relay (xrCoop/coop_soft_move.h)

namespace
{
constexpr uint16_t kStream = uint16_t(Msg::PlayerState); // a map message: it goes to the map server
constexpr uint16_t kVitals = uint16_t(Msg::PlayerVitals); // goes there and stays here too
constexpr uint16_t kMoney = uint16_t(Msg::ReqMoney); // the world's: it waits for the owner
constexpr uint16_t kUp = uint16_t(Msg::LevelXferUp); // a map server's to the world: it waits for the owner

// The host's process, a player and a map server, connected.
struct Road
{
	Side host, a, ms;
	net::PeerHandle on_a = nullptr, on_ms = nullptr, a_peer = nullptr, ms_peer = nullptr;

	explicit Road(uint16_t port)
	{
		connect_one(host, a, port, &on_a, &a_peer);
		std::string err;
		ms_peer = ms.tr.connect("127.0.0.1", port, &err);
		REQUIRE(ms_peer != nullptr);
		REQUIRE(pump_until({&host, &ms}, 5000, [&] {
			return host.count(net::Event::Type::Connect) == 2 && ms.count(net::Event::Type::Connect) == 1;
		}));
		on_ms = host.got[host.index(net::Event::Type::Connect, 1)].peer;
		host.pump();
		host.got.clear();
	}
	void open(size_t inbox_bytes = net::Transport::kRelayInboxBytes)
	{
		auto r = std::make_shared<softmove::Relay>();
		r->add_client(on_a, net::Transport::link_of(on_a), 1, 7);
		r->add_bridge(on_ms, net::Transport::link_of(on_ms), 0x101, 7);
		host.tr.relay_start(r, inbox_bytes);
	}
	// What the map server sends player 1, as a Tunnel.
	void down(uint16_t inner, uint8_t seq)
	{
		levels::wire::TunnelMsg m;
		m.peer = 1;
		m.packet = {uint8_t(inner & 0xFF), uint8_t(inner >> 8), seq};
		Writer w(16);
		REQUIRE(m.write(w));
		REQUIRE(ms.tr.send(ms_peer, Lane::Reliable,
			net::Transport::make_packet(Lane::Reliable, uint16_t(Msg::Tunnel), w.ptr(), w.size(), nullptr, 0, {})));
	}
	void up(uint16_t type, uint8_t seq)
	{
		REQUIRE(a.tr.send(a_peer, Lane::Reliable, net::Transport::make_packet(Lane::Reliable, type, &seq, 1, nullptr, 0, {})));
	}
};

// The seq of every Tunnel the map server got, in order.
std::vector<uint8_t> seqs_at_server(const Side& ms)
{
	std::vector<uint8_t> out;
	for (const net::Event& e : ms.got)
		if (e.type == net::Event::Type::Receive)
		{
			Reader r(e.bytes.data() + 2, e.bytes.size() - 2);
			levels::wire::TunnelMsg m;
			if (m.read(r))
				out.push_back(m.packet.back());
		}
	return out;
}
} // namespace

// The owner loads a level: no service() at all, for longer than it takes the helper to give up on an owner without a hold.
TEST(transport_relay_is_the_road_while_the_owner_is_away)
{
	Road r(37911);
	r.open();
	others_for({&r.a, &r.ms}, 1200);
	r.up(kStream, 1);
	r.down(uint16_t(Msg::EntityState), 2);
	REQUIRE(pump_until({&r.a, &r.ms}, 2000, [&] {
		return r.ms.count(net::Event::Type::Receive) == 1 && r.a.count(net::Event::Type::Receive) == 1;
	}));
	CHECK_EQ(seqs_at_server(r.ms)[0], uint8_t(1));
	const net::Event& e = r.a.got[r.a.index(net::Event::Type::Receive)];
	CHECK_EQ(uint16_t(e.bytes[0] | (e.bytes[1] << 8)), uint16_t(Msg::EntityState));
	CHECK_EQ(e.bytes[2], uint8_t(2));
	CHECK_EQ(r.host.count(net::Event::Type::Receive), size_t(0));
	const net::RelayStats st = r.host.tr.relay_stats();
	CHECK_EQ(st.to_servers, uint64_t(1));
	CHECK_EQ(st.to_players, uint64_t(1));
}

TEST(transport_relay_keeps_the_order_of_a_connection)
{
	Road r(37912);
	r.open();
	for (uint8_t i = 0; i < 200; ++i)
		r.up(kStream, i);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 3000, [&] { return r.ms.count(net::Event::Type::Receive) == 200; }));
	const std::vector<uint8_t> got = seqs_at_server(r.ms);
	for (size_t i = 0; i < got.size(); ++i)
		CHECK_EQ(got[i], uint8_t(i));
}

// What the helper took before the go stands in front of what comes after it.
TEST(transport_relay_takes_what_the_inbox_holds_first)
{
	Road r(37913);
	for (uint8_t i = 0; i < 5; ++i)
		r.up(kStream, i);
	r.a.tr.flush();
	others_for({&r.a, &r.ms}, 150); // into the inbox: the owner is between frames
	r.up(kMoney, 50); // the world's, in the inbox too
	r.a.tr.flush();
	others_for({&r.a, &r.ms}, 100);
	r.open();
	for (uint8_t i = 5; i < 10; ++i)
		r.up(kStream, i);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 2000, [&] { return r.ms.count(net::Event::Type::Receive) == 10; }));
	const std::vector<uint8_t> got = seqs_at_server(r.ms);
	for (size_t i = 0; i < got.size(); ++i)
		CHECK_EQ(got[i], uint8_t(i));
	r.host.pump();
	CHECK_EQ(r.host.count(net::Event::Type::Receive), size_t(1)); // what was not the relay's stayed
}

// What goes on and stays: the main thread gets it marked, or the session would tunnel it a second time.
TEST(transport_relay_marks_what_it_sent_on_and_kept)
{
	Road r(37914);
	r.open();
	r.up(kVitals, 7);
	r.up(kMoney, 8);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 2000, [&] { return r.ms.count(net::Event::Type::Receive) == 1; }));
	REQUIRE(pump_until({&r.host, &r.a, &r.ms}, 2000, [&] { return r.host.count(net::Event::Type::Receive) == 2; }));
	CHECK(r.host.got[r.host.index(net::Event::Type::Receive, 0)].relayed);
	CHECK(!r.host.got[r.host.index(net::Event::Type::Receive, 1)].relayed);
}

// The frames of the old world, of the new world before the parking ends: the owner pumps, and it does not get the road's traffic.
TEST(transport_relay_runs_under_an_owner_that_pumps_too)
{
	Road r(37915);
	r.open();
	r.up(kStream, 3);
	r.up(kMoney, 4);
	r.down(uint16_t(Msg::EntityState), 5);
	r.a.tr.flush();
	r.ms.tr.flush();
	REQUIRE(pump_until({&r.host, &r.a, &r.ms}, 2000, [&] {
		return r.ms.count(net::Event::Type::Receive) == 1 && r.a.count(net::Event::Type::Receive) == 1 &&
		    r.host.count(net::Event::Type::Receive) == 1;
	}));
	const net::Event& e = r.host.got[r.host.index(net::Event::Type::Receive)];
	CHECK_EQ(uint16_t(e.bytes[0] | (e.bytes[1] << 8)), kMoney);
}

// A third player leaves in the middle: the helper never hands a goodbye out (the owner has to see it first), and his neighbours do not
// wait for that. The owner gets it when it comes back.
TEST(transport_relay_a_goodbye_stops_nobody_else)
{
	Road r(37916);
	Side b;
	std::string err;
	const net::PeerHandle b_peer = b.tr.connect("127.0.0.1", 37916, &err);
	REQUIRE(b_peer != nullptr);
	REQUIRE(pump_until({&r.host, &b}, 5000, [&] { return b.count(net::Event::Type::Connect) == 1; }));
	r.host.pump();
	r.open();
	net::Transport::disconnect_now(b_peer);
	others_for({&r.a, &r.ms}, 150);
	for (uint8_t i = 0; i < 20; ++i)
		r.up(kStream, i);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 2000, [&] { return r.ms.count(net::Event::Type::Receive) == 20; }));
	CHECK_EQ(r.host.count(net::Event::Type::Disconnect), size_t(0));
	REQUIRE(pump_until({&r.host, &r.a, &r.ms}, 2000, [&] { return r.host.count(net::Event::Type::Disconnect) == 1; }));
}

// The map server goes down: what its players send has nowhere to go, nothing else happens.
TEST(transport_relay_a_lost_map_server_is_dropped_not_waited_for)
{
	Road r(37917);
	r.open();
	net::Transport::disconnect_now(r.ms_peer);
	others_for({&r.a}, 150);
	r.up(kStream, 1);
	r.a.tr.flush();
	others_for({&r.a}, 150);
	CHECK(r.host.tr.relay_stats().dropped >= 1);
	REQUIRE(pump_until({&r.host, &r.a}, 2000, [&] { return r.host.count(net::Event::Type::Disconnect) == 1; }));
	CHECK(r.host.got[r.host.index(net::Event::Type::Disconnect)].peer == r.on_ms);
}

// Past kMaxInbox events (an owner on a long load) the helper leaves the rest in ENet; the road does not stop for that.
TEST(transport_relay_goes_past_the_inbox_limit_of_events)
{
	Road r(37918);
	r.open();
	constexpr uint32_t kWorldEvents = 5000;
	for (uint32_t i = 0; i < kWorldEvents; ++i)
	{
		const uint8_t seq = uint8_t(i);
		REQUIRE(r.ms.tr.send(r.ms_peer, Lane::Reliable, net::Transport::make_packet(Lane::Reliable, kUp, &seq, 1, nullptr, 0, {})));
		if (i % 256 == 0)
			r.ms.pump();
	}
	r.ms.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 5000, [&] { return r.host.tr.relay_stats().kept >= kWorldEvents; }));
	r.up(kStream, 9);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 2000, [&] { return r.ms.count(net::Event::Type::Receive) == 1; }));
	CHECK(r.host.tr.relay_stats().inbox_max >= kWorldEvents);
	r.host.tr.relay_stop();
	REQUIRE(pump_until({&r.host}, 2000, [&] { return r.host.count(net::Event::Type::Receive) >= kWorldEvents; }));
	CHECK_EQ(r.host.count(net::Event::Type::Receive), size_t(kWorldEvents));
}

// What the world has to hear outgrows what we keep: nothing is lost, the road closes, the old rules hold.
TEST(transport_relay_stops_at_its_byte_limit_and_loses_nothing)
{
	Road r(37919);
	r.open(64); // bytes
	for (uint8_t i = 0; i < 200; ++i)
		r.up(kMoney, i);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.a, &r.ms}, 3000, [&] { return !r.host.tr.relaying(); }));
	CHECK(r.host.tr.relay_stats().overflowed);
	REQUIRE(pump_until({&r.host, &r.a}, 3000, [&] { return r.host.count(net::Event::Type::Receive) == 200; }));
}

// A connection that took a slot of the table is nobody the table knows: its packet goes to the owner.
TEST(transport_relay_an_old_slot_with_a_new_connection_is_a_stranger)
{
	Road r(37920);
	r.open();
	net::Transport::disconnect_now(r.a_peer);
	REQUIRE(pump_until({&r.host, &r.ms}, 2000, [&] { return r.host.count(net::Event::Type::Disconnect) == 1; }));
	Side c;
	std::string err;
	const net::PeerHandle c_peer = c.tr.connect("127.0.0.1", 37920, &err);
	REQUIRE(c_peer != nullptr);
	REQUIRE(pump_until({&r.host, &c, &r.ms}, 5000, [&] { return c.count(net::Event::Type::Connect) == 1; }));
	const uint8_t seq = 1;
	REQUIRE(c.tr.send(c_peer, Lane::Reliable, net::Transport::make_packet(Lane::Reliable, kStream, &seq, 1, nullptr, 0, {})));
	c.tr.flush();
	REQUIRE(pump_until({&r.host, &c, &r.ms}, 2000, [&] { return r.host.count(net::Event::Type::Receive) == 1; }));
	CHECK_EQ(r.ms.count(net::Event::Type::Receive), size_t(0));
}

TEST(transport_relay_stop_gives_the_road_back_to_the_owner)
{
	Road r(37921);
	r.open();
	r.host.tr.relay_stop();
	CHECK(!r.host.tr.relaying());
	r.up(kStream, 1);
	r.a.tr.flush();
	REQUIRE(pump_until({&r.host, &r.a, &r.ms}, 2000, [&] { return r.host.count(net::Event::Type::Receive) == 1; }));
	CHECK_EQ(r.ms.count(net::Event::Type::Receive), size_t(0));
}
