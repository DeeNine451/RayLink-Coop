// Anomaly Coop unit tests: the world's acceptance of a map server's journal (TZ Р32, temp/r30/design/R32-final.md §1 W2b, W3,
// §6 test_levels_accept.cpp; R32-addendum-gaps2.md P1): xrCoop/srv/coop_levels_accept.h over the writer rule of
// xrCoop/coop_writer_rules.h, the way srv/coop_levels_alife.cpp host_apply_fact fills it on the world server.
//
// Server mode only (the world server and its map servers); the co-op has no map servers and no journal.
#include "test_util.h"
#include "coop_writer_rules.h"
#include "srv/coop_levels_accept.h"

#include <cstdint>

namespace w = coop::writer;
namespace acc = coop::levels::accept;
namespace jr = coop::levels::journal;
using H = coop::levels::wire::LevelEntityHead;

namespace
{
constexpr uint16_t kA = 5; // led by the map server behind kBridgeA
constexpr uint16_t kB = 7; // led by the map server behind kBridgeB
constexpr uint16_t kU = 11; // no server leads it
constexpr coop::PeerId kBridgeA = 101, kBridgeB = 102;

const w::Process kWS{w::ProcessKind::World, w::kNoLevel, coop::kHostPeer};
const w::MapLead kLedA{w::Lead::Leads, kBridgeA};
const w::MapLead kStoppingA{w::Lead::Stopping, kBridgeA};
const w::MapLead kLedB{w::Lead::Leads, kBridgeB};
const w::MapLead kUnled{w::Lead::None, coop::kInvalidPeer};

// The world server's writer of a root, as world_writer_of (srv/coop_srv_mode.cpp) fills the seat.
w::Writer resident(uint16_t id, uint16_t level, w::MapLead lead)
{
	w::Seat s;
	s.map = lead;
	return w::writer_of(w::RootFacts{w::RootKind::Resident, id, level}, kWS, s);
}

w::Writer unit_held_by(uint16_t id, coop::PeerId bridge, uint16_t level)
{
	w::Seat s;
	s.hold = w::Hold::Held;
	s.holder = bridge;
	s.holder_level = level;
	return w::writer_of(w::RootFacts{w::RootKind::Unit, id, level}, kWS, s);
}

w::Writer unit_home(uint16_t id, uint16_t level)
{
	return w::writer_of(w::RootFacts{w::RootKind::Unit, id, level}, kWS, w::Seat{});
}

// A player's character standing on `level`; `from`: the map he left while his move fence is open.
w::Writer character(uint16_t id, uint16_t level, w::MapLead lead, uint16_t from = w::kNoLevel, w::MapLead from_lead = w::MapLead{})
{
	w::Seat s;
	s.map = lead;
	s.from = from;
	s.from_map = from_lead;
	return w::writer_of(w::RootFacts{w::RootKind::Character, id, level}, kWS, s);
}

// An entry from map server A (level kA) about an object the world has, same identity, no fence.
acc::Facts from_a(uint8_t op, w::Writer writer)
{
	acc::Facts f;
	f.op = op;
	f.sender = kBridgeA;
	f.sender_level = kA;
	f.epoch = 7;
	f.exists = true;
	f.same = true;
	f.writer = writer;
	return f;
}

bool refused_for(const acc::Verdict& v, jr::Why why) { return !v.ok && v.why == uint8_t(why); }
} // namespace

TEST(accept_kinds_of_every_journal_op)
{
	for (uint8_t op : {H::Destroy, H::Parent, H::Died, H::State, H::Item, H::Spawn, H::Tent, H::Stash, H::Logic, H::Joined, H::Left,
	         H::Info})
		CHECK(acc::kind_of(op) == acc::Kind::Fact);
	CHECK(acc::kind_of(H::Ask) == acc::Kind::Ask);
	for (uint8_t op : {H::Money, H::IdAsk, H::Carry, H::Done, H::Flushed})
		CHECK(acc::kind_of(op) == acc::Kind::Own);
	// every op a journal carries has a kind; the journal's own pass the acceptance (their own rules decide them)
	for (uint8_t op = 0; op <= jr::kLastOp; ++op)
		if (jr::known_op(op) && acc::kind_of(op) == acc::Kind::Own)
		{
			acc::Facts f;
			f.op = op;
			CHECK(acc::accepts(f).ok);
		}
}

// D1, G3, cleanup M2: the holder's release of a member of a squad it holds is applied (the root is the squad, the writer its holder).
TEST(accept_holder_destroy_of_held_member)
{
	const acc::Facts f = from_a(H::Destroy, unit_held_by(900, kBridgeA, kA));
	CHECK(acc::accepts(f).ok);
	// another map server's squad, a squad at home: not A's to release
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, unit_held_by(900, kBridgeB, kB))), jr::NotWriter));
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, unit_home(900, kA))), jr::NotWriter));
}

// A ground item, a box, a body on A's own map: A writes them while it leads or stops (§8a A4); on an unled map the world does.
TEST(accept_resident_by_the_lead_of_its_map)
{
	CHECK(acc::accepts(from_a(H::Destroy, resident(300, kA, kLedA))).ok);
	CHECK(acc::accepts(from_a(H::Destroy, resident(300, kA, kStoppingA))).ok);
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, resident(300, kB, kLedB))), jr::NotWriter));
	CHECK(refused_for(acc::accepts(from_a(H::Destroy, resident(300, kU, kUnled))), jr::NotWriter));
}

// cleanup M3: a death of another object under a reused id (its section differs) is refused, as any fact of another object.
TEST(accept_died_of_another_object_refused)
{
	acc::Facts f = from_a(H::Died, unit_held_by(900, kBridgeA, kA));
	f.same = acc::identity(0x1111, 0x2222, 0, 0, 0);
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = acc::identity(0x1111, 0x1111, 0, 0, 0);
	CHECK(acc::accepts(f).ok);
}

// A unit granted again since: the old grant's gen is another object.
TEST(accept_identity_by_keeper_generation)
{
	CHECK(acc::identity(0x10, 0x10, 5, 5, 0));
	CHECK(!acc::identity(0x10, 0x10, 6, 5, 0)); // granted again since
	CHECK(!acc::identity(0x10, 0x10, 5, 0, 0)); // gen 0 for a unit that is no spawn of the sender
	// its own spawn, named before the world's Ack reached it, and not moved since
	CHECK(acc::identity(0x10, 0x10, 9, 0, 9));
	CHECK(!acc::identity(0x10, 0x10, 12, 0, 9)); // it moved since its spawn: the gen-0 word is stale
	CHECK(!acc::identity(0x10, 0x11, 9, 0, 9)); // another section all the same
}

// W4: the old writer's facts after its fence are refused, whatever the writer rule says.
TEST(accept_entry_past_the_fence_refused)
{
	acc::Facts f = from_a(H::Destroy, resident(300, kA, kLedA));
	f.fence = 10;
	f.epoch = 10;
	CHECK(acc::accepts(f).ok);
	f.epoch = 11;
	CHECK(refused_for(acc::accepts(f), jr::PastFence));
	f.op = H::Ask;
	f.writer = w::this_process();
	f.root_level = kA;
	CHECK(refused_for(acc::accepts(f), jr::PastFence));
}

// gap-mk F1: a level's logic asks the world to release a world record of that level (xcv's phantoms that went home).
TEST(accept_ask_on_its_own_map_only)
{
	acc::Facts f = from_a(H::Ask, w::this_process());
	f.root_level = kA;
	CHECK(acc::accepts(f).ok);
	f.root_level = kB;
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
	f.root_level = w::kNoLevel; // an object of no map: money, story, records
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
	// a map server's object is asked of that map server, not of the world
	f.root_level = kA;
	f.writer = w::other(kBridgeA);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = w::this_process();
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = true;
	f.exists = false;
	CHECK(refused_for(acc::accepts(f), jr::Unknown));
	// a map server that leads no map has no map to ask about
	f.exists = true;
	f.sender_level = w::kNoLevel;
	f.root_level = w::kNoLevel;
	CHECK(refused_for(acc::accepts(f), jr::NotOwnLevel));
}

// F1 (role-guards): a map server's spawn under a root it does not write; its id slice; a repeat.
TEST(accept_spawn_root_slice_and_repeat)
{
	acc::Facts f = from_a(H::Spawn, w::other(kBridgeA));
	f.exists = false;
	f.id_in_slice = true;
	CHECK(acc::accepts(f).ok);
	// into the inventory of a squad another map server holds, into a box of another map
	f.writer = unit_held_by(900, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = resident(301, kB, kLedB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	// under an id of another slice
	f.writer = w::other(kBridgeA);
	f.id_in_slice = false;
	CHECK(refused_for(acc::accepts(f), jr::IdRange));
	// the world has it: the same object is a repeat (taken, nothing changes), another object under that id is refused
	f.id_in_slice = true;
	f.exists = true;
	f.same = true;
	const acc::Verdict again = acc::accepts(f);
	CHECK(again.ok && again.repeat);
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::IdRange));
	// nothing is made under the ghost
	f.exists = false;
	f.ghost = true;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
}

TEST(accept_spawn_stands_on_the_senders_map)
{
	CHECK(acc::spawn_on_senders_map(kA, kA));
	CHECK(acc::spawn_on_senders_map(w::kNoLevel, kA)); // a unit born at no vertex yet
	CHECK(!acc::spawn_on_senders_map(kB, kA));
	CHECK(!acc::spawn_on_senders_map(kA, w::kNoLevel)); // no map of its own: nothing is its to make
}

// A Parent changes two roots: both must be the sender's (an item taken from A's box into a squad B holds is not A's alone).
TEST(accept_parent_needs_both_roots)
{
	acc::Facts f = from_a(H::Parent, resident(300, kA, kLedA)); // from a box on A
	f.two_roots = true;
	f.writer_new = unit_held_by(900, kBridgeA, kA); // into an NPC of a squad A holds
	CHECK(acc::accepts(f).ok);
	f.writer_new = unit_held_by(901, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer_new = w::other(kBridgeA); // put down on A's map
	f.writer = unit_home(902, kA); // out of a squad at home in the world
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
}

// P1: a placement (tent, furniture, campfire) is the object's Spawn plus the item's Destroy; the Destroy may come after the player's
// move. While his move fence is open the map he left still writes him and his items: its Destroy is taken. After the fence the new
// map writes him: the old map's word is refused, and an entry after its Flushed is past the fence.
TEST(accept_p1_item_destroy_after_the_players_move)
{
	// he stands on B now, A is behind his open move fence
	const w::Writer during = character(2001, kB, kLedB, kA, kLedA);
	CHECK(during == w::other(kBridgeA));
	acc::Facts item = from_a(H::Destroy, during); // the item's root is his character
	CHECK(acc::accepts(item).ok);
	// the placed object itself: a resident of A, A's to make
	acc::Facts tent = from_a(H::Spawn, w::other(kBridgeA));
	tent.exists = false;
	tent.id_in_slice = true;
	CHECK(acc::accepts(tent).ok);
	// the fence is through: B writes him
	item.writer = character(2001, kB, kLedB);
	CHECK(refused_for(acc::accepts(item), jr::NotWriter));
	// A's entry came after its Flushed for that move
	item.writer = during;
	item.fence = 6;
	CHECK(refused_for(acc::accepts(item), jr::PastFence));
	// A stopping still writes until its Stopped (§8a A4)
	item.fence = w::kNoFence;
	item.writer = character(2001, kB, kLedB, kA, kStoppingA);
	CHECK(acc::accepts(item).ok);
}

// world-view D3: a member joins a squad: the creature's old root and the squad both are the sender's; a Left needs the squad.
TEST(accept_joined_and_left)
{
	acc::Facts f = from_a(H::Joined, unit_held_by(950, kBridgeA, kA)); // a lone creature A holds
	f.two_roots = true;
	f.writer_new = unit_held_by(900, kBridgeA, kA);
	CHECK(acc::accepts(f).ok);
	f.writer = unit_home(950, kA); // a creature at home in the world
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	acc::Facts left = from_a(H::Left, unit_held_by(900, kBridgeA, kA));
	CHECK(acc::accepts(left).ok);
	left.writer = unit_held_by(900, kBridgeB, kB);
	CHECK(refused_for(acc::accepts(left), jr::NotWriter));
	left.exists = false;
	CHECK(refused_for(acc::accepts(left), jr::Unknown));
}

// W1.5: the ghost (actor 0 where the actor plays nobody) is nobody's: no fact about it is taken.
TEST(accept_nothing_of_the_ghost)
{
	acc::Facts f = from_a(H::Info, w::nobody());
	f.ghost = true;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
	f.op = H::Destroy;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
	f.op = H::Ask;
	CHECK(refused_for(acc::accepts(f), jr::Ghost));
}

// The reasons come in one order: no object, the ghost, another object, then who writes it.
TEST(accept_reasons_in_order)
{
	acc::Facts f = from_a(H::State, character(2001, kB, kLedB));
	f.exists = false;
	f.same = false;
	CHECK(refused_for(acc::accepts(f), jr::Unknown));
	f.exists = true;
	CHECK(refused_for(acc::accepts(f), jr::Identity));
	f.same = true;
	CHECK(refused_for(acc::accepts(f), jr::NotWriter));
	f.writer = character(2001, kA, kLedA);
	CHECK(acc::accepts(f).ok);
	// every reason has a name for the log and is a reason the Ack may carry
	for (uint8_t why = 1; why <= jr::kLastWhy; ++why)
		CHECK(jr::why_name(why)[0] != '?');
}
