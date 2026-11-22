#include "test_util.h"

#include "coop_throw_rules.h"

using coop::throws::ConsumeAt;
using coop::throws::consume_at;
using coop::throws::may_start;

// R32 W7 follow-up (WP8b): a grenade made by a create that is still pending and thrown at once was refused by the
// authority (it does not have the item yet), and its hand destroy, held by the lease rule until Confirmed, then used it
// up with no blast. The throw must not start on a player's machine while the item's lease waits.
TEST(throw_a_players_machine_does_not_start_a_throw_of_a_lease_pending_item)
{
	CHECK(!may_start(true, true));
}

TEST(throw_a_confirmed_item_is_thrown_as_before)
{
	CHECK(may_start(true, false));
}

TEST(throw_the_authority_and_single_player_are_never_held)
{
	// The Coop host and a map server make the throw themselves; no session: stock. No lease is pending there anyway.
	CHECK(may_start(false, false));
	CHECK(may_start(false, true));
}

// Addendum PJ3: a host save inside a client's 3 s throw window kept the hand grenade, and a world load cleared the
// removal record, so the grenade came back after the load although it had been thrown.
TEST(throw_a_save_removes_a_thrown_hand_item_that_is_not_yet_due)
{
	CHECK(consume_at(true, false, true) == ConsumeAt::Remove);
}

TEST(throw_a_due_record_removes_the_item_as_before)
{
	CHECK(consume_at(false, true, true) == ConsumeAt::Remove);
	CHECK(consume_at(true, true, true) == ConsumeAt::Remove);
}

TEST(throw_a_record_not_due_and_no_save_waits_for_the_owners_destroy)
{
	CHECK(consume_at(false, false, true) == ConsumeAt::Keep);
}

TEST(throw_a_reused_id_is_never_removed_by_an_old_record)
{
	// The thrown item is gone and its id now names something else: neither a save nor the deadline removes it.
	CHECK(consume_at(true, false, false) == ConsumeAt::Keep);
	CHECK(consume_at(false, true, false) == ConsumeAt::Keep);
	CHECK(consume_at(true, true, false) == ConsumeAt::Keep);
}
