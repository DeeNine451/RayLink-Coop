// Anomaly Coop unit tests: admission of an item move into a container on the process that decides (xrCoop/coop_move_admission.h,
// F4 G6-1, finding m17:4 - Hideout Furniture's stash capacity was checked only in the mover's window, so two players filling
// one stash at once went over it). coop_requests.cpp asks the mods' move rules (coop_mods_move_limits.admit, Lua) before
// apply_move, for a client's request (host_move) and this process's own moves (host_transfer_item); the moves it let in are
// held here until the container's game inventory shows them.
#include "test_util.h"

#include "coop_move_admission.h"

#include <cmath>
#include <limits>

using namespace coop::admission;

namespace
{
constexpr uint16_t kBox = 10, kOtherBox = 11, kNoId = 0xffff;
constexpr uint64_t kT0 = 100000;

bool near(float a, float b) { return std::fabs(a - b) < 1e-4f; }

// Hideout Furniture's rule as coop_mods_move_limits.script's hf_capacity applies it (stash_capacities.script:105-111):
// the weight the box's game inventory shows + the held moves + the item, over the capacity -> refused.
Answer hf_rule(float capacity, float shown, const Pending& p, float item)
{
	return shown + p.weight + item > capacity ? Answer::Refuse : Answer::Admit;
}
} // namespace

// The ledger counts the moves it holds per container: how many and their weight (what the rules add to the game inventory).
TEST(move_admission_ledger_counts_pending)
{
	Ledger l;
	CHECK(l.hold(kBox, 1, 6.f, kT0));
	CHECK(l.hold(kBox, 2, 4.f, kT0));
	CHECK(l.hold(kBox, 3, 0.5f, kT0));
	CHECK(l.hold(kOtherBox, 4, 2.f, kT0));
	const Pending box = l.pending(kBox);
	CHECK_EQ(box.count, 3u);
	CHECK(near(box.weight, 10.5f));
	CHECK_EQ(l.pending(kOtherBox).count, 1u);
	CHECK(near(l.pending(kOtherBox).weight, 2.f));
	CHECK_EQ(l.pending(12).count, 0u);
	CHECK(near(l.pending(12).weight, 0.f));
	CHECK_EQ(l.size(), size_t(4));
	CHECK(l.holds(1));
	CHECK(!l.holds(5));
}

// Release on apply: a held move whose item the container's game inventory shows now (Landed) is counted by the rules
// themselves and leaves the ledger; one that went elsewhere (Gone: moved on, released, the container gone) leaves too.
TEST(move_admission_release_on_apply)
{
	Ledger l;
	l.hold(kBox, 1, 6.f, kT0);
	l.hold(kBox, 2, 4.f, kT0);
	l.hold(kBox, 3, 1.f, kT0);
	l.hold(kOtherBox, 4, 2.f, kT0);
	uint32_t asked_other = 0;
	const uint32_t released = l.settle(kBox, kT0 + 16, [&](uint16_t item, uint16_t container) {
		if (container != kBox)
			++asked_other;
		return item == 1 ? Track::Landed : item == 3 ? Track::Gone : Track::Waiting;
	});
	CHECK_EQ(released, 2u);
	CHECK_EQ(asked_other, 0u); // only that container's moves are asked about
	CHECK_EQ(l.pending(kBox).count, 1u);
	CHECK(near(l.pending(kBox).weight, 4.f));
	CHECK_EQ(l.pending(kOtherBox).count, 1u);
	CHECK(!l.holds(1));
	CHECK(l.holds(2));
}

// Release on refusal: apply_move did not do a move that was held (the engine refused it, somebody was first).
TEST(move_admission_release_on_refusal)
{
	Ledger l;
	CHECK_EQ(decide(l, Answer::Admit, kBox, 7, 6.f, kT0), Verdict::Ok);
	CHECK_EQ(l.pending(kBox).count, 1u);
	CHECK(l.release(7));
	CHECK_EQ(l.pending(kBox).count, 0u);
	CHECK(near(l.pending(kBox).weight, 0.f));
	CHECK(!l.release(7)); // not held any more
	CHECK(!l.release(8));
	CHECK_EQ(l.size(), size_t(0));
}

// The rules' answer: let in -> Ok and held; refused -> Full, nothing held; no rule for this container or the asking failed
// -> Unknown: the move goes on as in the stock game and is not held.
TEST(move_admission_verdicts)
{
	Ledger l;
	CHECK_EQ(decide(l, Answer::Refuse, kBox, 1, 6.f, kT0), Verdict::Full);
	CHECK_EQ(decide(l, Answer::NoRule, kBox, 2, 6.f, kT0), Verdict::Unknown);
	CHECK_EQ(decide(l, Answer::Failed, kBox, 3, 6.f, kT0), Verdict::Unknown);
	CHECK_EQ(l.size(), size_t(0));
	CHECK_EQ(decide(l, Answer::Admit, kBox, 4, 6.f, kT0), Verdict::Ok);
	CHECK(l.holds(4));
	// no container or no item: nothing to hold, nothing to judge
	CHECK_EQ(decide(l, Answer::Admit, kNoId, 5, 6.f, kT0), Verdict::Unknown);
	CHECK_EQ(decide(l, Answer::Admit, kBox, kNoId, 6.f, kT0), Verdict::Unknown);
	CHECK_EQ(l.size(), size_t(1));
	CHECK_EQ(verdict_of(Answer::Admit), Verdict::Ok);
	CHECK_EQ(verdict_of(Answer::Refuse), Verdict::Full);
	CHECK_EQ(verdict_of(Answer::NoRule), Verdict::Unknown);
	CHECK_EQ(verdict_of(Answer::Failed), Verdict::Unknown);
}

// Finding m17:4: a stash of 60 kg holds 50 kg; two players put 6 kg each into it in the same frame. Each window saw 50 kg
// and let it through. The decider: the first is let in and held (its game inventory still shows 50 kg), the second sees
// 50 + 6 held + 6 > 60 and is refused. When the first lands, the box shows 56 kg and the ledger is empty.
TEST(move_admission_two_quick_moves_into_a_nearly_full_stash)
{
	Ledger l;
	float shown = 50.f; // what iterate_inventory_box weighs now
	l.settle(kBox, kT0, [](uint16_t, uint16_t) { return Track::Waiting; });
	CHECK_EQ(decide(l, hf_rule(60.f, shown, l.pending(kBox), 6.f), kBox, 21, 6.f, kT0), Verdict::Ok);
	l.settle(kBox, kT0, [](uint16_t, uint16_t) { return Track::Waiting; }); // same frame: not in the game inventory yet
	CHECK_EQ(decide(l, hf_rule(60.f, shown, l.pending(kBox), 6.f), kBox, 22, 6.f, kT0), Verdict::Full);
	CHECK_EQ(l.pending(kBox).count, 1u);
	// the next frame: the first move landed
	shown = 56.f;
	l.settle(kBox, kT0 + 16, [](uint16_t item, uint16_t) { return item == 21 ? Track::Landed : Track::Waiting; });
	CHECK_EQ(l.pending(kBox).count, 0u);
	// 4 kg still fit (56 + 4 = 60: the capacity itself is allowed, stash_capacities.script:108 refuses only above it)
	CHECK_EQ(decide(l, hf_rule(60.f, shown, l.pending(kBox), 4.f), kBox, 23, 4.f, kT0 + 16), Verdict::Ok);
	CHECK_EQ(decide(l, hf_rule(60.f, shown, l.pending(kBox), 0.01f), kBox, 24, 0.01f, kT0 + 16), Verdict::Full);
}

// The ledger is bounded: kMaxHeld moves at once in all containers (a client's requests never grow it without limit; an
// item is held at most once). One more is refused (Full) until the old ones expire kTtlMs after they were held.
TEST(move_admission_verdict_at_the_bound)
{
	Ledger l;
	for (uint32_t i = 0; i < kMaxHeld; ++i)
		REQUIRE(decide(l, Answer::Admit, uint16_t(1 + i % 7), uint16_t(100 + i), 0.1f, kT0) == Verdict::Ok);
	CHECK_EQ(l.size(), size_t(kMaxHeld));
	CHECK_EQ(decide(l, Answer::Admit, kBox, 60000, 0.1f, kT0 + kTtlMs), Verdict::Full); // still within their time
	CHECK(!l.holds(60000));
	CHECK_EQ(decide(l, Answer::Admit, kBox, 60000, 0.1f, kT0 + kTtlMs + 1), Verdict::Ok); // the old ones expired
	CHECK_EQ(l.size(), size_t(1));
}

TEST(move_admission_full_ledger_reclaims_landed_moves_from_other_stashes)
{
	Ledger ledger;
	static constexpr uint16_t waiting_item = 100;
	static constexpr uint16_t gone_item = 101;
	constexpr uint16_t new_item = 60000;
	for (uint32_t i = 0; i < kMaxHeld; ++i)
		REQUIRE(ledger.hold(kBox, uint16_t(waiting_item + i), 0.1f, kT0));

	const uint64_t now = kT0 + 16;
	const uint32_t dropped = ledger.settle(kOtherBox, now, [](uint16_t item, uint16_t) {
		if (item == waiting_item)
			return Track::Waiting;
		return item == gone_item ? Track::Gone : Track::Landed;
	});
	CHECK_EQ(dropped, kMaxHeld - 1);
	CHECK_EQ(decide(ledger, Answer::Admit, kOtherBox, new_item, 1.f, now), Verdict::Ok);
	CHECK_EQ(ledger.pending(kBox).count, 1u);
	CHECK(ledger.holds(waiting_item));
	CHECK_EQ(ledger.pending(kOtherBox).count, 1u);
	CHECK(ledger.holds(new_item));
}

// A held move expires kTtlMs after it was held (a game object that never shows it must not block the container for good);
// a clock that went back (a new session's clock) expires it too.
TEST(move_admission_held_moves_expire)
{
	Ledger l;
	l.hold(kBox, 1, 6.f, kT0);
	const auto waiting = [](uint16_t, uint16_t) { return Track::Waiting; };
	CHECK_EQ(l.settle(kBox, kT0 + kTtlMs, waiting), 0u);
	CHECK_EQ(l.pending(kBox).count, 1u);
	CHECK_EQ(l.settle(kBox, kT0 + kTtlMs + 1, waiting), 1u);
	CHECK_EQ(l.pending(kBox).count, 0u);
	l.hold(kBox, 2, 6.f, kT0);
	CHECK_EQ(l.settle(kBox, kT0 - 1, waiting), 1u);
	CHECK_EQ(l.size(), size_t(0));
}

// One item goes one way: holding it again (into another container) replaces its earlier move.
TEST(move_admission_same_item_is_held_once)
{
	Ledger l;
	l.hold(kBox, 5, 6.f, kT0);
	l.hold(kOtherBox, 5, 6.f, kT0 + 1);
	CHECK_EQ(l.pending(kBox).count, 0u);
	CHECK_EQ(l.pending(kOtherBox).count, 1u);
	CHECK_EQ(l.size(), size_t(1));
}

// Weights come from the game (CInventoryItem::Weight), never from a client; still a number that is not finite, below zero or
// beyond kMaxWeight is not added as it is.
TEST(move_admission_weight_bounds)
{
	CHECK(near(held_weight(6.f), 6.f));
	CHECK(near(held_weight(-3.f), 0.f));
	CHECK(near(held_weight(std::numeric_limits<float>::quiet_NaN()), 0.f));
	CHECK(near(held_weight(std::numeric_limits<float>::infinity()), 0.f));
	CHECK(near(held_weight(1e30f), kMaxWeight));
	Ledger l;
	l.hold(kBox, 1, std::numeric_limits<float>::quiet_NaN(), kT0);
	l.hold(kBox, 2, 2.f, kT0);
	CHECK(near(l.pending(kBox).weight, 2.f));
}

// Each deciding process keeps its own ledger (the co-op host; in the Server mode the map server of each level: a stash is on
// one level, its players' moves reach that map server only).
TEST(move_admission_one_ledger_per_process)
{
	Ledger map_a, map_b;
	CHECK_EQ(decide(map_a, Answer::Admit, kBox, 1, 6.f, kT0), Verdict::Ok);
	CHECK_EQ(map_b.pending(kBox).count, 0u);
	CHECK_EQ(map_a.pending(kBox).count, 1u);
	map_a.clear();
	CHECK_EQ(map_a.size(), size_t(0));
}
