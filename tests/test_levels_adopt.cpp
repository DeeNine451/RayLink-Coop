// Anomaly Coop unit tests: R32 §8a A17 (fix package A, task A4), a creature that leaves a squad a map server holds inherits the
// squad's hold. The world server's Keeper (xrCoop/srv/coop_levels_keeper.h over the Ledger of coop_xfer.h) and a map server's Holder
// (coop_xfer_holder.h), packets delivered by hand, as srv/coop_levels_xfer.cpp drives them: the map server adopts the member at its
// Left hook (client_adopt_left -> Holder::adopt), the world at applying that Left (coop_levels_alife.cpp leave_squad ->
// host_adopt_member -> Keeper::adopt); a Joined into a squad the map server writes drops the member's own hold on both sides
// (client_flush_up -> Holder::forget, host_member_joined -> Keeper::drop_own).
//
// Before the fix the world applied the Left with coop_leave_member: the creature became a lone NPC the world simulated and nobody
// held, the Joined that followed was refused (NotWriter: the world wrote the creature's old root) and the repair undid the move on the
// map server as well.
//
// Server mode only (the world server and its map servers); the co-op has no map servers and no transfers.
#include "test_util.h"

#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"
#include "srv/coop_levels_journal.h"
#include "srv/coop_levels_keeper.h"

#include <cstddef>
#include <cstdint>
#include <vector>

using namespace coop;
using namespace coop::levels;

namespace
{
namespace w = coop::writer;
namespace acc = coop::levels::accept;
namespace jr = coop::levels::journal;
using H = wire::LevelEntityHead;

constexpr uint32_t kBridgeA = 0x101; // the session peer of map server A on the world server
constexpr uint32_t kBridgeB = 0x102;
constexpr uint16_t kMapA = 5;
constexpr uint16_t kS1 = 0x2000; // a squad A holds (granted, or born)
constexpr uint16_t kS2 = 0x2100; // another squad A holds or bore
constexpr uint16_t kM = 0x2001; // the creature that moves from S1 to S2
constexpr uint16_t kCrc = 0x5151;

xfer::Bytes bytes(uint8_t v) { return xfer::Bytes{v, uint8_t(v + 1), uint8_t(v + 2)}; }

// One map server (A) against the world's keeper.
struct Rig
{
	Keeper keeper;
	xfer::Holder holder{7};
	uint64_t now = 1000;
	std::vector<Keeper::Change> changes;

	Rig() { keeper.connect(kBridgeA); }

	void to_map(const std::vector<xfer::Packet>& down)
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
			to_map(keeper.on_up(kBridgeA, p, fresh, now));
		drain();
	}
	void drain()
	{
		for (Keeper::Change& c : keeper.take_changes())
			changes.push_back(std::move(c));
	}
	size_t count(Keeper::Kind kind, uint16_t id) const
	{
		size_t n = 0;
		for (const Keeper::Change& c : changes)
			n += c.kind == kind && c.id == id ? 1u : 0u;
		return n;
	}
	size_t count_of(uint16_t id) const
	{
		size_t n = 0;
		for (const Keeper::Change& c : changes)
			n += c.id == id ? 1u : 0u;
		return n;
	}
	const xfer::Bytes* unmark_state(uint16_t id) const
	{
		for (const Keeper::Change& c : changes)
			if (c.kind == Keeper::Kind::Unmark && c.id == id)
				return &c.state;
		return nullptr;
	}
	// The world grants `id` to A, A commits (a squad near its player).
	void take(uint16_t id, uint8_t v)
	{
		const xfer::Bytes fresh = bytes(v);
		to_world(holder.want_online(id, now), &fresh);
		holder.take_events();
	}
	// A makes `id` under its slice and the world answers (a born unit).
	void bear(uint16_t id, uint8_t v) { to_world(holder.spawned(id, bytes(v), now)); }
	void tick(uint64_t ms)
	{
		now += ms;
		to_world(holder.tick(now));
		to_map(keeper.tick(now));
		drain();
	}
	// The Left of `member` from `unit`: the map server's hook (Holder::adopt), then the world's apply of the journal entry
	// (Keeper::adopt with the world's copy of the creature).
	bool left(uint16_t unit, uint16_t member)
	{
		const bool map = holder.adopt(member, unit, xfer::Bytes(), now);
		const bool world = keeper.adopt(member, unit, kBridgeA, bytes(9));
		drain();
		return map && world;
	}
	// The Joined of `member` into `unit`: the map server's flush (a squad it writes: its own hold of the member ends), the world's
	// apply (host_member_joined).
	void joined(uint16_t unit, uint16_t member)
	{
		if (holder.authors(unit))
			holder.forget(member);
		keeper.drop_own(member, kBridgeA, now);
		drain();
	}
	uint32_t world_gen(uint16_t id) const
	{
		uint32_t spawn = 0;
		return keeper.gen_held_by(id, kBridgeA, spawn);
	}
	// The world's identity check of a head A writes for an object whose root is `root` (A6: the gen A's Holder holds the root under).
	bool same(uint16_t root) const
	{
		uint32_t spawn = 0;
		const uint32_t here = keeper.gen_held_by(root, kBridgeA, spawn);
		return acc::identity(kCrc, kCrc, here, holder.gen(root), spawn);
	}
	// The world's writer of a unit root, as world_writer_of fills the seat from the keeper (levels::holder_of).
	w::Writer writer_of_unit(uint16_t root) const
	{
		w::Seat s;
		if (keeper.holder_of(root) != Keeper::kNoSession)
		{
			s.hold = w::Hold::Held;
			s.holder = PeerId(keeper.holder_of(root));
			s.holder_level = kMapA;
		}
		return w::writer_of(w::RootFacts{w::RootKind::Unit, root, kMapA},
		    w::Process{w::ProcessKind::World, w::kNoLevel, kHostPeer}, s);
	}
	// The world's acceptance of A's Joined of `member` (root: the member itself, loose) into `squad`.
	acc::Verdict accepts_joined(uint16_t squad, uint16_t member) const
	{
		acc::Facts f;
		f.op = H::Joined;
		f.sender = PeerId(kBridgeA);
		f.sender_level = kMapA;
		f.exists = true;
		f.writer = writer_of_unit(member);
		f.two_roots = true;
		f.writer_new = writer_of_unit(squad);
		return acc::accepts(f);
	}
};
} // namespace

// The scenario of the WP3 review: A holds S1 (granted) with member M and bore S2; a stock move (companion recruit, a squad split)
// runs S1:unregister_member(M), then S2:register_member(M). Left is taken and M is A's at once under S1's gen on both sides; Joined
// is taken (both roots are A's) and M's own hold ends on both sides without bringing it home or destroying it.
TEST(levels_adopt_left_then_joined_from_the_holder_of_both)
{
	Rig r;
	r.take(kS1, 1);
	r.bear(kS2, 2);
	REQUIRE(r.holder.authors(kS1) && r.holder.authors(kS2));
	// before the Left the world writes M through S1 (A's): after it M is A's on its own, not the world's
	CHECK(r.left(kS1, kM));
	CHECK(r.holder.authors(kM));
	CHECK(r.keeper.away(kM));
	CHECK_EQ(r.keeper.holder_of(kM), kBridgeA);
	CHECK(r.writer_of_unit(kM) == w::other(PeerId(kBridgeA)));
	CHECK_EQ(r.holder.gen(kM), r.holder.gen(kS1)); // A16: one gen for its root, the squad's
	CHECK_EQ(r.world_gen(kM), r.holder.gen(kM));
	CHECK(r.same(kM));
	CHECK(r.count(Keeper::Kind::Gone, kM) == 0 && r.count(Keeper::Kind::Unmark, kM) == 0);
	// Joined into S2: taken
	CHECK(r.accepts_joined(kS2, kM).ok);
	r.changes.clear();
	r.joined(kS2, kM);
	CHECK(!r.holder.authors(kM));
	CHECK(!r.keeper.away(kM));
	CHECK(!r.keeper.ledger().registered(kM));
	CHECK(r.changes.empty()); // no Unmark (it is not home), no Gone (it is not destroyed): a member of S2, held away with S2
	// the audit finds nothing: A reports S1 and S2, the world gives A exactly those
	std::vector<xfer::Finding> found;
	r.to_map(r.keeper.audit(kBridgeA, Keeper::bare(r.holder.report()), xfer::kAllBuckets, found));
	CHECK(found.empty());
	// S2 comes home with its members' states: one Unmark of S2, nothing of M on its own
	r.changes.clear();
	r.to_world(r.holder.want_offline(kS2, bytes(3), r.now));
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kS2), size_t(1));
	CHECK_EQ(r.count_of(kM), size_t(0));
}

// The defect the fix removes: with the world's old Left (the creature at home, no hold) A's Joined is refused, NotWriter.
TEST(levels_adopt_without_the_hold_the_joined_was_refused)
{
	Rig r;
	r.take(kS1, 1);
	r.bear(kS2, 2);
	// the world's old Left: nothing adopted, M is the world's (coop_leave_member: a lone creature of the world)
	const acc::Verdict v = r.accepts_joined(kS2, kM);
	CHECK(!v.ok);
	CHECK_EQ(v.why, uint8_t(jr::NotWriter));
	CHECK(r.writer_of_unit(kM) == w::this_process());
}

// Left and no Joined: M stays A's on its own; its hand-back brings it home exactly once with A's state.
TEST(levels_adopt_left_then_hand_back_comes_home_once)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	r.changes.clear();
	r.to_world(r.holder.want_offline(kM, bytes(7), r.now)); // ReleasePrepare -> Ack -> ReleaseCommit -> Done
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kM), size_t(1));
	const xfer::Bytes* st = r.unmark_state(kM);
	CHECK(st != nullptr && *st == bytes(7));
	CHECK(r.count(Keeper::Kind::Gone, kM) == 0);
	CHECK(!r.holder.authors(kM));
	CHECK(!r.keeper.away(kM));
	for (int i = 0; i < 20; ++i)
		r.tick(1000);
	CHECK_EQ(r.count_of(kM), size_t(1)); // nothing repeated, nothing undone
	CHECK(r.keeper.away(kS1)); // S1 is still A's
	CHECK_EQ(r.count_of(kS1), size_t(0));
}

// Left and no Joined, then A is lost: M comes home once, at the state the world adopted it with (or the last A streamed).
TEST(levels_adopt_left_then_lost_comes_home_once)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	r.changes.clear();
	r.keeper.disconnect(kBridgeA, r.now);
	r.drain();
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kM), size_t(1));
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kS1), size_t(1));
	CHECK(r.count(Keeper::Kind::Gone, kM) == 0);
	const xfer::Bytes* st = r.unmark_state(kM);
	CHECK(st != nullptr && *st == bytes(9));
	CHECK(!r.keeper.away(kM));
}

// A loose held M streams like any held unit: the world's copy follows, and that is what it comes home with when A is lost.
TEST(levels_adopt_a_loose_member_streams_its_state)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	r.to_world(r.holder.changed(kM, bytes(20), r.now));
	const xfer::Bytes* confirmed = r.keeper.ledger().last_confirmed(kM);
	CHECK(confirmed != nullptr && *confirmed == bytes(20));
	r.changes.clear();
	r.keeper.disconnect(kBridgeA, r.now);
	r.drain();
	const xfer::Bytes* st = r.unmark_state(kM);
	CHECK(st != nullptr && *st == bytes(20));
}

// (e) A Died of the loose M, a Parent of an item it carries, a Destroy of it: their heads name M's root with the gen A's Holder holds
// it under, the world's keeper has the same, so the identity check takes them; the writer of the root is A.
TEST(levels_adopt_facts_of_a_loose_member_are_taken)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	CHECK(r.same(kM)); // Died of M, Parent of M's gun: root M
	CHECK(r.writer_of_unit(kM) == w::other(PeerId(kBridgeA)));
	uint32_t spawn = 0;
	const uint32_t here = r.keeper.gen_held_by(kM, kBridgeA, spawn);
	CHECK(!acc::identity(kCrc, kCrc, here, 0, spawn)); // gen 0 is no spawn of A's: refused
	CHECK(!acc::identity(kCrc, kCrc, here, here + 1, spawn));
	// its Destroy goes on the transfer lane and releases it on the world (Gone), once
	r.changes.clear();
	r.to_world(r.holder.destroyed(kM, r.now));
	CHECK_EQ(r.count(Keeper::Kind::Gone, kM), size_t(1));
	CHECK(!r.keeper.ledger().registered(kM));
}

// A squad A bore whose spawn the world has not answered yet (A names it gen 0): a member that leaves it gets gen 0 too, the world's
// record takes the spawn's allowance, and A's SpawnPrepare of the member is answered with the squad's spawn gen.
TEST(levels_adopt_from_a_squad_whose_spawn_is_unanswered)
{
	Rig r;
	const std::vector<xfer::Packet> prepare = r.holder.spawned(kS1, bytes(1), r.now);
	REQUIRE(prepare.size() == 1);
	const std::vector<xfer::Packet> ack = r.keeper.on_up(kBridgeA, prepare[0], nullptr, r.now); // the Ack stays on its way
	r.drain();
	REQUIRE(ack.size() == 1);
	CHECK_EQ(r.holder.gen(kS1), 0u);
	REQUIRE(r.left(kS1, kM));
	CHECK(r.holder.authors(kM));
	CHECK_EQ(r.holder.gen(kM), 0u);
	CHECK(r.same(kM)); // gen 0: its own spawn's allowance
	CHECK(r.same(kS1));
	r.tick(0); // the member's SpawnPrepare, answered with the squad's spawn gen
	CHECK(r.holder.gen(kM) != 0u);
	CHECK_EQ(r.holder.gen(kM), r.world_gen(kM));
	r.to_map(ack); // the squad's Ack at last
	CHECK_EQ(r.holder.gen(kS1), r.holder.gen(kM));
	CHECK(r.same(kM));
	CHECK(r.same(kS1));
}

// A16 (and the identity of a squad on its way home): while S1 is Releasing the world names it with the gen A held it under until
// A hears the world's Ack, not the Ack's new gen; a member that leaves it then is adopted under that gen on both sides.
TEST(levels_adopt_from_a_releasing_squad_names_the_held_gen)
{
	Rig r;
	r.take(kS1, 1);
	const uint32_t held = r.holder.gen(kS1);
	const std::vector<xfer::Packet> prepare = r.holder.want_offline(kS1, bytes(4), r.now);
	REQUIRE(prepare.size() == 1);
	const std::vector<xfer::Packet> ack = r.keeper.on_up(kBridgeA, prepare[0], nullptr, r.now);
	r.drain();
	REQUIRE(ack.size() == 1);
	CHECK(r.keeper.ledger().phase(kS1) == xfer::Phase::Releasing);
	CHECK(r.keeper.ledger().gen(kS1) != held); // the Ack's gen
	CHECK_EQ(r.world_gen(kS1), held); // what A's heads name until the Ack reaches it
	CHECK(r.same(kS1));
	REQUIRE(r.left(kS1, kM));
	CHECK_EQ(r.holder.gen(kM), held);
	CHECK(r.same(kM));
	r.changes.clear();
	r.to_map(ack); // S1 goes home; M stays A's
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kS1), size_t(1));
	CHECK_EQ(r.count_of(kM), size_t(0));
	CHECK(r.keeper.away(kM));
	CHECK(r.holder.authors(kM));
}

// Nothing is adopted from a squad the sender does not hold, nor a creature another map server holds; a creature of the world's own
// earlier record (a transfer long over) is adopted.
TEST(levels_adopt_refuses_what_is_not_the_senders)
{
	Rig r;
	r.keeper.connect(kBridgeB);
	r.take(kS1, 1);
	CHECK(!r.holder.adopt(kM, 0x3000, xfer::Bytes(), r.now)); // a squad A does not write
	CHECK(!r.keeper.adopt(kM, 0x3000, kBridgeA, bytes(9)));
	CHECK(!r.keeper.adopt(kM, kS1, kBridgeB, bytes(9))); // B does not hold S1
	CHECK(!r.keeper.adopt(kS1, kS1, kBridgeA, bytes(9)));
	// M is B's (granted to B)
	{
		xfer::Holder b(8);
		const xfer::Bytes fresh = bytes(5);
		std::vector<xfer::Packet> up = b.want_online(kM, r.now);
		for (size_t guard = 0; !up.empty() && guard < 8; ++guard)
		{
			std::vector<xfer::Packet> next;
			for (const xfer::Packet& p : up)
				for (xfer::Packet d : r.keeper.on_up(kBridgeB, p, &fresh, r.now))
				{
					d.from = xfer::kWorld;
					d.to = b.self();
					for (const xfer::Packet& q : b.on_packet(d, r.now))
						next.push_back(q);
				}
			up = next;
		}
		REQUIRE(b.authors(kM));
		CHECK(!r.keeper.adopt(kM, kS1, kBridgeA, bytes(9)));
		CHECK_EQ(r.keeper.holder_of(kM), kBridgeB);
	}
	// a creature the world granted to A once and took back: its record is the world's, it moves to A under S1's gen
	Rig r2;
	r2.take(kS1, 1);
	r2.take(kM, 2);
	r2.to_world(r2.holder.want_offline(kM, bytes(3), r2.now));
	REQUIRE(!r2.keeper.away(kM));
	REQUIRE(r2.keeper.ledger().registered(kM));
	CHECK(r2.left(kS1, kM));
	CHECK_EQ(r2.world_gen(kM), r2.holder.gen(kS1));
	CHECK(r2.same(kM));
}

// A creature A holds on its own already (granted alone) keeps its own hold and gen at a Left: both sides leave it as it is.
TEST(levels_adopt_a_creature_held_already_keeps_its_hold)
{
	Rig r;
	r.take(kS1, 1);
	r.take(kM, 2);
	const uint32_t own = r.holder.gen(kM);
	REQUIRE(own != 0 && own != r.holder.gen(kS1));
	CHECK(r.left(kS1, kM));
	CHECK_EQ(r.holder.gen(kM), own);
	CHECK_EQ(r.world_gen(kM), own);
	CHECK(r.same(kM));
}

// (c) A creature A bore joins a squad A bore (create_npc): its own spawn record ends at the Joined on both sides, no change goes out,
// and a late copy of its SpawnPrepare registers nothing (a tombstone); a later Left adopts it again from the squad.
TEST(levels_adopt_a_born_member_that_joins_has_no_hold_of_its_own)
{
	Rig r;
	r.bear(kS1, 1);
	const std::vector<xfer::Packet> prepare = r.holder.spawned(kM, bytes(2), r.now);
	REQUIRE(prepare.size() == 1);
	r.to_world(prepare);
	REQUIRE(r.holder.authors(kM) && r.keeper.away(kM));
	r.changes.clear();
	r.joined(kS1, kM);
	CHECK(!r.holder.authors(kM));
	CHECK(!r.keeper.ledger().registered(kM));
	CHECK(r.changes.empty());
	CHECK(r.keeper.on_up(kBridgeA, prepare[0], nullptr, r.now).empty()); // the late copy
	CHECK(!r.keeper.ledger().registered(kM));
	CHECK(r.left(kS1, kM));
	CHECK_EQ(r.holder.gen(kM), r.holder.gen(kS1));
	CHECK(r.same(kM));
}

// A Joined into a squad A does not write (the world's own, another map server's) is refused by the world (NotWriter: the new root
// is not A's) and changes nothing of M's hold on either side.
TEST(levels_adopt_joined_into_a_squad_not_written_here_keeps_the_hold)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.left(kS1, kM));
	const acc::Verdict v = r.accepts_joined(0x3000, kM); // a squad at home in the world
	CHECK(!v.ok);
	CHECK_EQ(v.why, uint8_t(jr::NotWriter));
	// A's flush keeps the hold (it does not write that squad); the world refused it: host_member_joined is never reached
	if (r.holder.authors(0x3000))
		r.holder.forget(kM);
	CHECK(r.holder.authors(kM));
	CHECK(r.keeper.away(kM));
	CHECK(r.same(kM));
}

// ---------------------------------------------------------------- fix round 2 (the verifier's findings on package A)

namespace
{
// The map server's pending ups of a frame as srv/coop_levels_xfer.cpp queues them (State::Up: op, a, b).
struct Up
{
	uint8_t op;
	uint16_t a;
	uint16_t b;
};

// The Left hook's question (client_adopt_left) as the engine fills it for a living creature on the ground that transfers.
jr::LeftAdoptFacts left_facts(const xfer::Holder& holder, uint16_t unit, uint16_t member, const jr::ReleasesUnderWay& releasing)
{
	jr::LeftAdoptFacts f;
	f.squad_written = holder.authors(unit);
	f.member_written = holder.authors(member);
	f.living_creature = true;
	f.releasing = releasing.under_way(member);
	return f;
}
} // namespace

// The marks of the creatures whose release is under way on a map server: taken at the Released hook, forgotten when an object is made
// under the id again or once no object stands under it.
TEST(levels_adopt_releases_under_way)
{
	jr::ReleasesUnderWay r;
	CHECK(!r.under_way(kM));
	r.released(kM);
	r.released(kS2);
	CHECK(r.under_way(kM) && r.under_way(kS2));
	r.prune([](uint16_t id) { return id == kM; }); // M still stands (its release runs), S2 is gone from the registry
	CHECK(r.under_way(kM));
	CHECK(!r.under_way(kS2));
	r.spawned(kM); // a new object under the id: nothing of it is on its way out
	CHECK(!r.under_way(kM));
	CHECK_EQ(r.size(), size_t(0));
	r.released(kM);
	r.clear();
	CHECK(!r.under_way(kM));
}

// The Left hook adopts a living creature that leaves a squad the map server writes, unless it writes the creature already or the
// creature's release is under way.
TEST(levels_adopt_who_is_adopted_at_a_left)
{
	jr::LeftAdoptFacts f;
	f.squad_written = true;
	f.living_creature = true;
	CHECK(jr::adopts_at_left(f));
	f.releasing = true;
	CHECK(!jr::adopts_at_left(f)); // fix round 2, finding 1
	f.releasing = false;
	f.member_written = true;
	CHECK(!jr::adopts_at_left(f)); // it keeps its own hold
	f.member_written = false;
	f.living_creature = false;
	CHECK(!jr::adopts_at_left(f)); // dead (the death chain's Left), in a holder, a player's character, one that does not transfer
	f.living_creature = true;
	f.squad_written = false;
	CHECK(!jr::adopts_at_left(f)); // a squad not written here (yet: the flush asks again)
}

// Fix round 2, finding 1: a script's raw alife():release of a living member M of S1, which A holds. The stock release runs the Released
// hook first (M is still S1's: its Destroy goes at the end of the frame, its head naming S1), then S1:unregister_member(M) and the Left
// hook, M alive and still registered. M is on its way out, so it is not adopted there: at the flush A does not hold M, its Destroy is
// journaled (the world releases it from S1 under S1's gen) and nothing of M is held on either side. Before the fix the Left adopted M,
// its Destroy went on the transfer lane, where the world has no record of M, the world adopted M from the Left after it, and the audit
// brought M home alive (levels_adopt_a_released_member_adopted_came_home_alive).
TEST(levels_adopt_a_released_member_is_not_adopted)
{
	Rig r;
	r.take(kS1, 1);
	jr::ReleasesUnderWay releasing;
	std::vector<Up> ups;
	// the Released hook
	releasing.released(kM);
	const jr::CreaturePlace p = jr::creature_place(ups, kM, kS1, kS1);
	CHECK(!p.before_left);
	CHECK_EQ(p.squad, kS1);
	ups.insert(ups.begin() + std::ptrdiff_t(p.at), Up{uint8_t(H::Destroy), kM, 0xffff});
	const uint32_t head_gen = r.holder.gen(p.squad);
	// the Left hook, then the flush asks again for a Left: neither adopts
	ups.push_back(Up{uint8_t(H::Left), kS1, kM});
	CHECK(!jr::adopts_at_left(left_facts(r.holder, kS1, kM, releasing)));
	// the flush: the Destroy first, of a creature A does not hold: journaled, its head naming S1 with the gen the world gives A for it
	REQUIRE(ups.front().op == uint8_t(H::Destroy));
	CHECK(!r.holder.authors(kM));
	uint32_t spawn = 0;
	CHECK(acc::identity(kCrc, kCrc, r.keeper.gen_held_by(kS1, kBridgeA, spawn), head_gen, spawn));
	CHECK(!jr::adopts_at_left(left_facts(r.holder, kS1, kM, releasing)));
	// the world released M (release_here); its Left after it names no object and is refused: nothing of M in the keeper, ever
	r.changes.clear();
	for (int round = 0; round < 3; ++round)
	{
		std::vector<xfer::Finding> found;
		r.to_map(r.keeper.audit(kBridgeA, Keeper::bare(r.holder.report()), xfer::kAllBuckets, found));
		r.drain();
		CHECK(found.empty());
		r.tick(10000);
	}
	CHECK(!r.keeper.ledger().registered(kM));
	CHECK(!r.keeper.away(kM));
	CHECK_EQ(r.count_of(kM), size_t(0));
	CHECK(r.keeper.away(kS1));
	// M left the registry: its mark goes
	releasing.prune([](uint16_t) { return false; });
	CHECK(!releasing.under_way(kM));
}

// The defect finding 1 named, step by step: with M adopted at that Left, the Destroy goes on the transfer lane and the world, which
// never gave M to A on its own, releases nothing; the Left after it adopts M on the world for A, which has nothing of M; the audit
// finds M lost and brings it home alive.
TEST(levels_adopt_a_released_member_adopted_came_home_alive)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.holder.adopt(kM, kS1, xfer::Bytes(), r.now)); // the hook before the fix
	r.changes.clear();
	r.to_world(r.holder.destroyed(kM, r.now)); // its Destroy on the transfer lane
	CHECK_EQ(r.count(Keeper::Kind::Gone, kM), size_t(0)); // the world released nothing
	CHECK(!r.holder.authors(kM));
	CHECK(r.keeper.adopt(kM, kS1, kBridgeA, bytes(9))); // the journal's Left, applied after
	size_t findings = 0;
	for (int round = 0; round < 4 && r.count(Keeper::Kind::Unmark, kM) == 0; ++round)
	{
		std::vector<xfer::Finding> found;
		r.to_map(r.keeper.audit(kBridgeA, Keeper::bare(r.holder.report()), xfer::kAllBuckets, found));
		r.drain();
		findings += found.size();
		r.tick(10000);
	}
	CHECK(findings > 0);
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kM), size_t(1)); // it walks again in the world
	CHECK_EQ(r.count(Keeper::Kind::Gone, kM), size_t(0));
}

// The same release with a flush between the Released hook and the Left hook (a transfer packet of a hook in between sends the frame
// so far): the Destroy went up journaled already; the Left hook, M still alive and registered, does not adopt it either.
TEST(levels_adopt_a_released_member_is_not_adopted_after_a_flush)
{
	Rig r;
	r.take(kS1, 1);
	jr::ReleasesUnderWay releasing;
	releasing.released(kM);
	CHECK(!r.holder.authors(kM)); // the flush journals its Destroy
	releasing.prune([](uint16_t id) { return id == kM; }); // the flush's prune: M still stands, its release runs
	CHECK(!jr::adopts_at_left(left_facts(r.holder, kS1, kM, releasing)));
	CHECK(!r.holder.authors(kM));
	// a creature of S1 whose release is not under way is adopted at its Left, as A17 says
	CHECK(jr::adopts_at_left(left_facts(r.holder, kS1, kS2, releasing)));
}

// Fix round 2, finding 2: A makes S2 and moves M into it from S1 (which A holds) in one frame: a squad split, a recruit into a new
// companion squad. A's hooks: S2's Spawn queued, Left(S1,M) (A adopts M), Joined(S2,M). A's flush: S2's Spawn, written where it stands
// now (M listed), and its SpawnPrepare; the Left (A holds M already); the Joined (A writes S2: M's own hold ends). The world: S2's Spawn
// binds M in S2 (coop_bind_members) before the Left comes; the Left finds M bound elsewhere and only takes it off S1's list (no
// adoption, nothing of M changes); the Joined is a repeat, taken (both roots are A's). Both sides end with M in S2, with no hold of
// its own, its root S2 under one gen. Before the fix the world adopted M at the Left and cleared its squad (m_group_id), the Joined's
// repeat did not restore it and dropped the mark: M nobody's, every later fact of A about it refused (NotWriter).
TEST(levels_adopt_a_member_moved_into_a_squad_made_in_the_same_frame)
{
	Rig r;
	r.take(kS1, 1);
	REQUIRE(r.holder.adopt(kM, kS1, xfer::Bytes(), r.now)); // the Left hook
	// the flush: S2's Spawn and its SpawnPrepare (the world answers it: S2 is A's born unit)
	r.to_world(r.holder.spawned(kS2, bytes(2), r.now));
	REQUIRE(r.holder.authors(kS2));
	REQUIRE(r.keeper.away(kS2));
	CHECK(!jr::adopts_at_left(left_facts(r.holder, kS1, kM, jr::ReleasesUnderWay()))); // the flush's Left: A holds M already
	if (r.holder.authors(kS2)) // the flush's Joined into a squad A writes
		r.holder.forget(kM);
	CHECK(!r.holder.authors(kM));
	// the world's Left: M is bound in S2 (its Spawn listed it), not in S1
	acc::LeaveFacts leave;
	leave.listed = true;
	leave.bound = true;
	leave.living = true;
	leave.bound_elsewhere = true;
	CHECK(acc::leave_plan(leave) == acc::Leave::Unlist); // no Keeper::adopt
	CHECK(!r.keeper.away(kM));
	// the world's Joined: M's root before it is S2 (bound there), S2 is A's: taken; no own hold of M to drop
	acc::Facts f;
	f.op = H::Joined;
	f.sender = PeerId(kBridgeA);
	f.sender_level = kMapA;
	f.exists = true;
	f.writer = r.writer_of_unit(kS2);
	f.two_roots = true;
	f.writer_new = r.writer_of_unit(kS2);
	CHECK(acc::accepts(f).ok);
	CHECK(!r.keeper.drop_own(kM, kBridgeA, r.now));
	CHECK(!r.keeper.ledger().registered(kM));
	// A16: a later head of A about M (its Died, a Parent of its gun) names S2 with the gen both sides give it
	CHECK(r.same(kS2));
	CHECK(r.writer_of_unit(kS2) == w::other(PeerId(kBridgeA)));
	// the audit finds nothing: A reports S1 and S2, the world gives A exactly those
	std::vector<xfer::Finding> found;
	r.to_map(r.keeper.audit(kBridgeA, Keeper::bare(r.holder.report()), xfer::kAllBuckets, found));
	CHECK(found.empty());
	// S2 comes home with M in it: nothing of M on its own
	r.changes.clear();
	r.to_world(r.holder.want_offline(kS2, bytes(3), r.now));
	CHECK_EQ(r.count(Keeper::Kind::Unmark, kS2), size_t(1));
	CHECK_EQ(r.count_of(kM), size_t(0));
}

// Fix round 2, finding 4: the audit's heal of S1's member list on the world (A's report does not list M) is a Left A's Holder never
// adopted at: it takes M home in the world (today's way), it does not mark M as A's.
TEST(levels_adopt_a_healed_left_takes_the_member_home)
{
	acc::LeaveFacts f;
	f.listed = true;
	f.bound = true;
	f.living = true;
	f.heal = true;
	CHECK(acc::leave_plan(f) == acc::Leave::Home);
	f.heal = false;
	CHECK(acc::leave_plan(f) == acc::Leave::Adopt); // the map server's own Left of the same member
}
