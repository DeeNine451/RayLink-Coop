// Anomaly Coop unit tests: the move rules for a move into a player's character (R32 WP18 P4, temp/r30/design/R32-final.md
// §8a A21 E-3; xrCoop/coop_move_admission.h route_of / judge / refusal_text).
//
// The Weapon Showcase display copy rule (coop_mods_hf.script hf_showcase_display, in coop_mods_move_limits.admit) refuses every
// move of a display copy, but the engine's admitted_move (coop_requests.cpp) asked the move rules only for a container: a move
// whose destination root is a player was applied unasked, so a player could still pick a display copy up. Now the decider (the
// co-op host; in the Server mode the map server of the player's level, and the world server for its own script moves) asks:
//   - onto the ground: nothing (the stock game's limits), as before;
//   - into a character whose root is a player: the rules, with nothing held and no admission book (no settle, hold or release);
//     only a refusal stops the move (Reason::NotAllowed, the rule's text or "refused by a move rule"); a let-in, no rule or a
//     failed asking moves it as in the stock game;
//   - into any other container: as before (the held moves of that container are passed in, a let-in is held).
#include "test_util.h"

#include "coop_move_admission.h"

#include <string>

using namespace coop::admission;

namespace
{
constexpr uint16_t kBox = 10, kHostActor = 0, kClientCharacter = 500;
constexpr uint64_t kT0 = 200000;
} // namespace

// The ground is never asked, whatever the root flag says (kNoObject has no root).
TEST(move_admission_player_ground_is_never_asked)
{
	CHECK(route_of(kNoObject, false) == Route::Stock);
	CHECK(route_of(kNoObject, true) == Route::Stock);
	Ledger l;
	CHECK(judge(l, Route::Stock, Answer::Refuse, kNoObject, 1, 1.f, kT0) == Verdict::Unknown);
	CHECK_EQ(l.size(), size_t(0));
}

// A destination whose root is a player (the host's own character id 0, a client's character, anything inside one) is asked.
TEST(move_admission_player_destination_is_asked)
{
	CHECK(route_of(kHostActor, true) == Route::Ask);
	CHECK(route_of(kClientCharacter, true) == Route::Ask);
	CHECK(route_of(kBox, false) == Route::AskAndHold);
}

// R32 P4: a refusal (the display copy rule) stops a take into a player: Full is what admitted_move turns into NotAllowed.
TEST(move_admission_player_refusal_stops_the_take)
{
	Ledger l;
	CHECK(judge(l, Route::Ask, Answer::Refuse, kClientCharacter, 630, 3.5f, kT0) == Verdict::Full);
	CHECK(judge(l, Route::Ask, Answer::Refuse, kHostActor, 631, 3.5f, kT0) == Verdict::Full);
	CHECK_EQ(l.size(), size_t(0));
}

// A let-in, no rule or a failed asking moves the item as in the stock game (Unknown): an ordinary pickup is unchanged.
TEST(move_admission_player_other_answers_move_as_stock)
{
	Ledger l;
	CHECK(judge(l, Route::Ask, Answer::Admit, kClientCharacter, 7, 2.f, kT0) == Verdict::Unknown);
	CHECK(judge(l, Route::Ask, Answer::NoRule, kClientCharacter, 8, 2.f, kT0) == Verdict::Unknown);
	CHECK(judge(l, Route::Ask, Answer::Failed, kClientCharacter, 9, 2.f, kT0) == Verdict::Unknown);
	CHECK(judge(l, Route::Ask, Answer::NoRule, kHostActor, 9, 2.f, kT0) == Verdict::Unknown);
}

// No admission book for a player: a let-in into a player is not held (a player's game inventory is no rule's weight, and a
// held move would count against nothing and could never "land" in a container), a held container move stays as it was.
TEST(move_admission_player_take_never_touches_the_book)
{
	Ledger l;
	CHECK(l.hold(kBox, 1, 6.f, kT0));
	CHECK(judge(l, Route::Ask, Answer::Admit, kClientCharacter, 2, 4.f, kT0) == Verdict::Unknown);
	CHECK(judge(l, Route::Ask, Answer::Refuse, kClientCharacter, 1, 4.f, kT0) == Verdict::Full);
	CHECK_EQ(l.size(), size_t(1));
	CHECK(l.holds(1));
	CHECK(!l.holds(2));
	CHECK_EQ(l.pending(kClientCharacter).count, 0u);
	CHECK_EQ(l.pending(kBox).count, 1u);
}

// A full book never refuses a pickup ("too many moves in flight" is a container's limit only).
TEST(move_admission_player_full_book_does_not_refuse_a_take)
{
	Ledger l;
	for (uint32_t i = 0; i < kMaxHeld; ++i)
		REQUIRE(l.hold(kBox, uint16_t(1000 + i), 0.f, kT0));
	CHECK(judge(l, Route::AskAndHold, Answer::Admit, kBox + 1, 9, 1.f, kT0) == Verdict::Full);
	CHECK(judge(l, Route::Ask, Answer::Admit, kClientCharacter, 9, 1.f, kT0) == Verdict::Unknown);
	CHECK(judge(l, Route::Ask, Answer::NoRule, kClientCharacter, 9, 1.f, kT0) == Verdict::Unknown);
	CHECK_EQ(l.size(), size_t(kMaxHeld));
}

// A container is judged as before: judge on AskAndHold is decide() for every answer.
TEST(move_admission_player_container_unchanged)
{
	const Answer answers[] = {Answer::Admit, Answer::Refuse, Answer::NoRule, Answer::Failed};
	for (Answer a : answers)
	{
		Ledger by_judge, by_decide;
		const Verdict j = judge(by_judge, Route::AskAndHold, a, kBox, 3, 2.f, kT0);
		const Verdict d = decide(by_decide, a, kBox, 3, 2.f, kT0);
		CHECK(j == d);
		CHECK_EQ(by_judge.size(), by_decide.size());
		CHECK_EQ(by_judge.holds(3), by_decide.holds(3));
	}
}

// The text a refused move logs (and the decider's log line names): the rule's own, or the default.
TEST(move_admission_player_refusal_text)
{
	CHECK_EQ(std::string(refusal_text(nullptr)), std::string("refused by a move rule"));
	CHECK_EQ(std::string(refusal_text("")), std::string("refused by a move rule"));
	CHECK_EQ(std::string(refusal_text("a weapon showcase display copy")), std::string("a weapon showcase display copy"));
}
