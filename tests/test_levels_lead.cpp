// Anomaly Coop unit tests: multilevel v1, a player's own process leads his map (docs/SPLIT_LEVELS.md §2). Who leads a level,
// the verdict on a move, the roles of a process, which messages reach a player on another level, the vote of the switch
// manager on the level a client leads, and the world server's book of objects held by a client (coop_levels_keeper.h) against
// the real Holder of the transfer core.
#include "test_util.h"

#include "coop_levels_keeper.h"
#include "coop_levels_rules.h"
#include "coop_roles.h"
#include "coop_scope.h"

#include <vector>

using namespace coop;
using namespace coop::levels;

namespace
{
constexpr uint16_t kCordon = 1;
constexpr uint16_t kGarbage = 2;
constexpr uint16_t kAgroprom = 3;
constexpr uint64_t kT0 = 1000;

Seat seat(uint32_t peer, uint16_t level, bool in_world = true, bool plays = true)
{
	Seat s;
	s.peer = peer;
	s.level = level;
	s.in_world = in_world;
	s.plays = plays;
	return s;
}

xfer::Bytes state_of(uint8_t v) { return xfer::Bytes{v, uint8_t(v + 1)}; }

// One client on one level against the keeper, packets delivered by hand.
struct Rig
{
	Keeper keeper;
	xfer::Holder holder{7}; // what the client's Holder calls itself; the wire carries no peer
	uint32_t peer = 2; // his session slot
	uint64_t now = kT0;
	std::vector<Keeper::Change> changes;

	Rig() { keeper.connect(peer); }

	void to_client(const std::vector<xfer::Packet>& down)
	{
		for (const xfer::Packet& p : down)
		{
			xfer::Packet c = p;
			c.from = xfer::kWorld;
			c.to = holder.self();
			to_world(holder.on_packet(c, now));
		}
	}
	void to_world(const std::vector<xfer::Packet>& up, const xfer::Bytes* fresh = nullptr)
	{
		for (const xfer::Packet& p : up)
			to_client(keeper.on_up(peer, p, fresh, now));
		drain();
	}
	void drain()
	{
		for (Keeper::Change& c : keeper.take_changes())
			changes.push_back(std::move(c));
	}
	bool saw(Keeper::Kind kind, uint16_t id) const
	{
		for (const Keeper::Change& c : changes)
			if (c.kind == kind && c.id == id)
				return true;
		return false;
	}
	void take(uint16_t id, uint8_t v)
	{
		const xfer::Bytes fresh = state_of(v);
		to_world(holder.want_online(id, now), &fresh);
	}
};
} // namespace

// ---------------------------------------------------------------- who leads

TEST(lead_host_on_the_level_leads_even_when_a_client_came_first)
{
	Table t;
	t.set(seat(1, kGarbage));
	t.set(seat(0, kGarbage));
	CHECK_EQ(t.leader_of(kGarbage), 0u);
}

TEST(lead_the_first_to_come_leads)
{
	Table t;
	t.set(seat(0, kCordon));
	t.set(seat(2, kGarbage));
	t.set(seat(1, kGarbage)); // seat 1 comes later: arrival counts, not the slot
	CHECK_EQ(t.leader_of(kGarbage), 2u);
	CHECK_EQ(t.leader_of(kCordon), 0u);
	CHECK_EQ(t.leader_of(kAgroprom), kNoLeader);
	CHECK_EQ(t.leader_of(kNoLevel), kNoLeader);
}

TEST(lead_goes_to_the_next_when_the_first_leaves)
{
	Table t;
	t.set(seat(1, kGarbage));
	t.set(seat(2, kGarbage));
	t.set(seat(3, kGarbage));
	t.set(seat(1, kAgroprom));
	CHECK_EQ(t.leader_of(kGarbage), 2u);
	t.remove(2);
	CHECK_EQ(t.leader_of(kGarbage), 3u);
}

// Coming back is a new arrival; staying on the level, whatever else changes in his seat, is not.
TEST(lead_comes_anew_only_with_a_new_level)
{
	Table t;
	t.set(seat(1, kGarbage, false));
	t.set(seat(2, kGarbage));
	t.set(seat(1, kGarbage, true)); // he finished loading: still the first
	CHECK_EQ(t.leader_of(kGarbage), 1u);
	t.set(seat(1, kAgroprom));
	t.set(seat(1, kGarbage));
	CHECK_EQ(t.leader_of(kGarbage), 2u);
}

TEST(lead_a_seat_that_does_not_play_leads_nothing)
{
	Table t;
	t.set(seat(1, kGarbage, true, false));
	CHECK_EQ(t.leader_of(kGarbage), kNoLeader);
}

// ---------------------------------------------------------------- the verdict

TEST(move_a_free_level_goes_and_the_mover_leads_it)
{
	CHECK(decide_player_move(Gate::Free, kNoLeader, 0, 1) == MoveVerdict::Go);
	CHECK(decide_player_move(Gate::BetterTogether, kNoLeader, 0, 1) == MoveVerdict::Go);
}

TEST(move_to_the_hosts_level_goes_a_client_mirrors_the_host)
{
	CHECK(decide_player_move(Gate::Free, 0, 0, 1) == MoveVerdict::Go);
}

TEST(move_to_a_level_another_client_leads_is_refused_until_mirrors_there_exist)
{
	CHECK(decide_player_move(Gate::Free, 2, 0, 1) == MoveVerdict::RefuseLed);
	CHECK(decide_player_move(Gate::Free, 1, 0, 1) == MoveVerdict::Go); // he himself: a seat that repeats its move
}

TEST(move_together_waits_at_the_board_and_a_bad_gate_is_refused)
{
	CHECK(decide_player_move(Gate::Together, kNoLeader, 0, 1) == MoveVerdict::Board);
	CHECK(decide_player_move(Gate(9), kNoLeader, 0, 1) == MoveVerdict::RefuseInvalid);
}

// ---------------------------------------------------------------- the roles

TEST(roles_of_the_host_and_of_a_client_as_before_split_levels)
{
	CHECK_EQ(int(host_roles()), int(uint8_t(ProcessRole::WorldServer) | uint8_t(ProcessRole::MapAuthority) | uint8_t(ProcessRole::Player)));
	CHECK(has(client_roles(false), ProcessRole::Mirror));
	CHECK(has(client_roles(false), ProcessRole::WorldClient));
	CHECK(has(client_roles(false), ProcessRole::Player));
	CHECK(!has(client_roles(false), ProcessRole::MapAuthority));
}

TEST(roles_a_leading_client_stays_a_client_of_the_world)
{
	const uint8_t r = client_roles(true);
	CHECK(has(r, ProcessRole::WorldClient)); // time, story, money still ask the host
	CHECK(has(r, ProcessRole::Player));
	CHECK(has(r, ProcessRole::MapAuthority)); // the objects of his level are his
	CHECK(!has(r, ProcessRole::Mirror));
	CHECK(!has(r, ProcessRole::WorldServer));
}

// ---------------------------------------------------------------- which messages reach another level

// The switch off is the contract of the whole feature: not one message may change its way.
TEST(passes_split_off_every_message_goes_as_before)
{
	uint32_t listed = 0;
	for (uint32_t v = 0; v <= 0xffff; ++v)
	{
		const Msg m = Msg(uint16_t(v));
		if (!scope_listed(m))
			continue;
		++listed;
		CHECK(level_passes(m, false, false));
		CHECK(level_passes(m, false, true));
	}
	CHECK(listed > 100);
}

TEST(passes_the_same_level_gets_everything)
{
	for (uint32_t v = 0; v <= 0xffff; ++v)
		if (scope_listed(Msg(uint16_t(v))))
			CHECK(level_passes(Msg(uint16_t(v)), true, true));
}

TEST(passes_another_level_gets_the_world_and_the_registry_not_the_stream)
{
	// the stream of the host's level means nothing to a player on another one
	CHECK(!level_passes(Msg::EntitySnapshot, true, false));
	CHECK(!level_passes(Msg::EntitySwitch, true, false));
	CHECK(!level_passes(Msg::EntityAnim, true, false));
	CHECK(!level_passes(Msg::PlayerState, true, false));
	CHECK(!level_passes(Msg::ZoneState, true, false));
	CHECK(!level_passes(Msg::EntityHash, true, false));
	// the world is one
	CHECK(level_passes(Msg::TimeSync, true, false));
	CHECK(level_passes(Msg::InfoPortion, true, false));
	CHECK(level_passes(Msg::Emission, true, false));
	CHECK(level_passes(Msg::Chat, true, false));
	// every machine keeps the same registry with the same ids
	CHECK(level_passes(Msg::EntitySpawn, true, false));
	CHECK(level_passes(Msg::EntityDestroy, true, false));
	CHECK(level_passes(Msg::EntityParent, true, false));
	CHECK(level_passes(Msg::EntitySquad, true, false));
	// until weather is per level (plan T15) the sky stays the host's
	CHECK(level_passes(Msg::WeatherSync, true, false));
}

TEST(takes_split_off_every_message_as_before)
{
	for (uint32_t v = 0; v <= 0xffff; ++v)
		if (scope_listed(Msg(uint16_t(v))))
			CHECK(level_takes(Msg(uint16_t(v)), false, false));
}

TEST(takes_a_player_on_another_level_is_heard_for_the_world_and_his_own_data)
{
	// his body is no object here: a shot, a hit or a request of his would act on the host's level at his coordinates
	CHECK(!level_takes(Msg::PlayerState, true, false));
	CHECK(!level_takes(Msg::PlayerShot, true, false));
	CHECK(!level_takes(Msg::PlayerHit, true, false));
	CHECK(!level_takes(Msg::ReqTake, true, false));
	CHECK(!level_takes(Msg::DialogLock, true, false));
	CHECK(!level_takes(Msg::TradeOp, true, false));
	// the world is one, he is a client of it
	CHECK(level_takes(Msg::InfoPortion, true, false));
	CHECK(level_takes(Msg::ReqMoney, true, false));
	CHECK(level_takes(Msg::JoinRequest, true, false));
	CHECK(level_takes(Msg::LevelMove, true, false));
	CHECK(level_takes(Msg::CheckpointClaim, true, false));
	// what he leads
	CHECK(level_takes(Msg::LevelXferUp, true, false));
	CHECK(level_takes(Msg::LevelEntity, true, false));
	// his own data, for the save
	CHECK(level_takes(Msg::PlayerVitals, true, false));
	CHECK(level_takes(Msg::ItemState, true, false));
	// on the host's level nothing changes
	CHECK(level_takes(Msg::PlayerShot, true, true));
}

// ---------------------------------------------------------------- the vote

TEST(vote_what_the_host_does_not_simulate_is_not_transferred)
{
	const LeadAsk a = lead_vote(false, false, false, true);
	CHECK(a.vote == LeadVote::Stock);
	CHECK(!a.ask);
}

TEST(vote_a_creature_near_him_is_asked_for_and_stays_offline_until_granted)
{
	const LeadAsk a = lead_vote(true, false, false, true);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(a.ask);
}

TEST(vote_a_creature_far_from_him_is_left_alone)
{
	const LeadAsk a = lead_vote(true, false, false, false);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(!a.ask);
}

TEST(vote_a_creature_he_holds_follows_the_stock_rules)
{
	const LeadAsk a = lead_vote(true, true, false, false);
	CHECK(a.vote == LeadVote::Stock);
	CHECK(!a.ask);
}

TEST(vote_a_creature_on_its_way_back_stays_offline)
{
	const LeadAsk a = lead_vote(true, true, true, true);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(!a.ask);
}

// ---------------------------------------------------------------- ids

TEST(ids_each_player_has_his_slice_and_nobody_shares_it)
{
	CHECK_EQ(int(leader_ids_of(0)), 0); // the host keeps them out of his generator, he makes none of them
	CHECK_EQ(int(leader_ids_of(8)), 0);
	uint32_t next = kLeaderIdFirst;
	for (uint32_t peer = 1; peer <= kLeaderSlots; ++peer)
	{
		CHECK_EQ(uint32_t(leader_ids_of(peer)), next);
		next += kLeaderIdsEach;
	}
	CHECK(next - 1 < 0xffff); // 0xffff is no id
}

// ---------------------------------------------------------------- the world server's book

TEST(keeper_a_take_marks_the_object_and_the_client_gets_its_state)
{
	Rig r;
	r.take(100, 5);
	CHECK(r.keeper.away(100));
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
	CHECK(r.saw(Keeper::Kind::Mark, 100));
	CHECK(r.holder.authors(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Create);
	CHECK(ev[0].state == state_of(5));
	CHECK_EQ(r.keeper.ledger().journal_size(), size_t(0));
}

TEST(keeper_a_release_brings_the_state_home_once)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.want_offline(100, state_of(9), r.now));
	CHECK(!r.keeper.away(100));
	CHECK(r.saw(Keeper::Kind::Unmark, 100));
	CHECK_EQ(r.changes.size(), size_t(1));
	CHECK(r.changes[0].state == state_of(9));
	CHECK(!r.holder.authors(100));
}

TEST(keeper_a_taken_object_is_nobody_elses)
{
	Rig r;
	r.keeper.connect(3);
	r.take(100, 5);
	r.holder.take_events();
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const xfer::Bytes fresh = state_of(1);
	CHECK(r.keeper.on_up(3, up, &fresh, r.now).empty()); // the other client repeats until it comes back
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
}

TEST(keeper_a_stream_change_reaches_the_host_without_moving_the_owner)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.changed(100, state_of(7), r.now));
	CHECK(r.saw(Keeper::Kind::State, 100));
	CHECK(r.changes[0].state == state_of(7));
	CHECK(r.keeper.away(100));
}

TEST(keeper_a_client_that_leaves_gives_everything_back_at_the_last_state)
{
	Rig r;
	r.take(100, 5);
	r.take(101, 6);
	r.holder.take_events();
	r.to_world(r.holder.changed(100, state_of(7), r.now));
	r.changes.clear();
	r.keeper.disconnect(r.peer, r.now);
	r.drain();
	CHECK(!r.keeper.away(100));
	CHECK(!r.keeper.away(101));
	CHECK(r.saw(Keeper::Kind::Unmark, 100));
	CHECK(r.saw(Keeper::Kind::Unmark, 101));
	for (const Keeper::Change& c : r.changes)
		CHECK(c.state == (c.id == 100 ? state_of(7) : state_of(6)));
	CHECK_EQ(r.keeper.held_by(r.peer), size_t(0));
}

TEST(keeper_a_client_that_comes_back_is_a_new_connection)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.keeper.disconnect(r.peer, r.now);
	r.drain();
	r.keeper.connect(r.peer);
	r.holder = xfer::Holder(7);
	r.take(100, 5);
	CHECK(r.keeper.away(100));
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
}

TEST(keeper_a_message_of_nobody_is_not_heard)
{
	Rig r;
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const xfer::Bytes fresh = state_of(1);
	CHECK(r.keeper.on_up(5, up, &fresh, r.now).empty()); // peer 5 never connected as a leader
	CHECK(!r.keeper.away(100));
}

TEST(keeper_an_object_the_world_does_not_have_is_refused)
{
	Rig r;
	r.to_world(r.holder.want_online(100, r.now), nullptr); // no state: no such object here
	CHECK(!r.keeper.away(100));
	CHECK(!r.holder.authors(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Refused);
}

TEST(keeper_a_destroyed_object_leaves_the_book)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.destroyed(100, r.now));
	CHECK(r.saw(Keeper::Kind::Gone, 100));
	CHECK(!r.keeper.away(100));
}

// The host's copy says the object is not for him (it walked off his level, it is online on the host's level): an old record
// of the ledger does not change that.
TEST(keeper_an_object_that_is_not_his_to_take_is_refused_even_with_a_record)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.to_world(r.holder.want_offline(100, state_of(6), r.now));
	r.holder.take_events();
	r.to_world(r.holder.want_online(100, r.now), nullptr);
	CHECK(!r.keeper.away(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Refused);
}

// His own request repeated (the Grant is on its way) is answered with the same grant, whatever the engine thinks of the
// object now that it is marked.
TEST(keeper_a_request_repeated_gets_the_same_grant)
{
	Rig r;
	const xfer::Bytes fresh = state_of(5);
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const std::vector<xfer::Packet> first = r.keeper.on_up(r.peer, up, &fresh, r.now);
	const std::vector<xfer::Packet> second = r.keeper.on_up(r.peer, up, nullptr, r.now);
	CHECK_EQ(first.size(), size_t(1));
	CHECK_EQ(second.size(), size_t(1));
	CHECK(second[0].op == xfer::Op::Grant);
	CHECK_EQ(second[0].key.gen, first[0].key.gen);
	CHECK(second[0].payload == fresh);
}

// Every op of the transfer goes over the wire and comes back the same.
TEST(keeper_wire_every_op_of_both_directions)
{
	const xfer::Bytes cargo = state_of(3);
	for (xfer::Op op : {xfer::Op::TakeReq, xfer::Op::TakeCommit, xfer::Op::ReleasePrepare, xfer::Op::ReleaseCommit,
	         xfer::Op::SpawnPrepare, xfer::Op::Destroy, xfer::Op::AbortAck, xfer::Op::Snapshot})
	{
		wire::LevelXferUpMsg m;
		CHECK(up_of(xfer::Packet{op, xfer::Key{9, 77}, 1, xfer::kWorld, cargo}, m));
		const xfer::Packet back = packet_of(m);
		CHECK(back.op == op);
		CHECK_EQ(back.key.id, uint16_t(9));
		CHECK_EQ(back.key.gen, 77u);
		CHECK(back.payload == cargo);
	}
	for (xfer::Op op : {xfer::Op::Grant, xfer::Op::Ack, xfer::Op::Done, xfer::Op::Abort, xfer::Op::Drop, xfer::Op::Snapshot})
	{
		wire::LevelXferDownMsg m;
		CHECK(down_of(xfer::Packet{op, xfer::Key{9, 77}, xfer::kWorld, 1, cargo}, m));
		const xfer::Packet back = packet_of(m, 5);
		CHECK(back.op == op);
		CHECK_EQ(back.to, 5u);
		CHECK(back.payload == cargo);
	}
	wire::LevelXferUpMsg u;
	CHECK(!up_of(xfer::Packet{xfer::Op::Grant, xfer::Key{9, 77}, 1, xfer::kWorld, {}}, u));
	wire::LevelXferDownMsg d;
	CHECK(!down_of(xfer::Packet{xfer::Op::TakeReq, xfer::Key{9, 77}, xfer::kWorld, 1, {}}, d));
}

TEST(keeper_a_new_world_forgets_everything_and_reuses_no_peer)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	const xfer::Peer before = r.keeper.ledger().next_peer();
	r.keeper.restart();
	r.drain();
	CHECK(!r.keeper.away(100));
	CHECK_EQ(r.keeper.marked(), size_t(0));
	CHECK(!r.keeper.connected(r.peer));
	CHECK_EQ(r.keeper.ledger().next_peer(), before);
}

// A grant nobody commits (the client went quiet) comes home by itself, and the host's simulation goes on with it.
TEST(keeper_a_grant_lost_in_the_network_comes_home)
{
	Rig q;
	const xfer::Bytes fresh = state_of(5);
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	std::vector<xfer::Packet> grant = q.keeper.on_up(q.peer, up, &fresh, q.now);
	CHECK_EQ(grant.size(), size_t(1));
	CHECK(q.keeper.away(100));
	q.now += xfer::kGrantTimeoutMs + 1;
	std::vector<xfer::Packet> abort = q.keeper.tick(q.now);
	CHECK(!abort.empty());
	CHECK(q.keeper.away(100)); // two-phase: frozen until his AbortAck
	q.to_client(abort);
	CHECK(!q.keeper.away(100));
}
