// Anomaly Coop unit tests: who sees a task in a split-levels world (xrCoop/coop_task_audience.h,
// docs/plans/2026-11-16-task-audience.md B.1): the host sends a task, the task list and the tasks hash to each player by the
// task's audience; a task without one, and a world without any, go as before.
#include "test_util.h"

#include "coop_task_audience.h"

#include <string>

using coop::task_audience::allowed;
using coop::task_audience::kMaxEntries;
using coop::task_audience::kMaxIdLength;
using coop::task_audience::kMaxMembers;
using coop::task_audience::kNoCharacter;
using coop::task_audience::Members;
using coop::task_audience::Table;

// A task with no entry is everybody's: the host player, a client, a character not known yet, a bridge.
TEST(task_audience_no_entry_is_everybody)
{
	Table t;
	CHECK(t.allowed("esc_task", 0, false));
	CHECK(t.allowed("esc_task", 500, false));
	CHECK(t.allowed("esc_task", kNoCharacter, false));
	CHECK(t.allowed("esc_task", kNoCharacter, true));
	CHECK(allowed(nullptr, 7, false));
	CHECK(t.set("other_task", {500}) == Table::Set::Added);
	CHECK(t.allowed("esc_task", 501, false)); // another task's entry changes nothing here
}

TEST(task_audience_entry_is_its_members_only)
{
	Table t;
	CHECK(t.set("drx_sl_task_1", {500, 0, 502}) == Table::Set::Added);
	CHECK(t.allowed("drx_sl_task_1", 0, false));
	CHECK(t.allowed("drx_sl_task_1", 500, false));
	CHECK(t.allowed("drx_sl_task_1", 502, false));
	CHECK(!t.allowed("drx_sl_task_1", 501, false));
	CHECK(!t.allowed("drx_sl_task_1", 1, false));
	const Members* m = t.find("drx_sl_task_1");
	REQUIRE(m != nullptr);
	CHECK_EQ(m->size(), size_t(3));
	CHECK(t.find("drx_sl_task_") == nullptr); // a prefix is another id
}

// A peer with no character on the host yet is out of every task that has an entry, and only of those.
TEST(task_audience_unknown_character_is_out)
{
	Table t;
	CHECK(t.set("t", {500}) == Table::Set::Added);
	CHECK(!t.allowed("t", kNoCharacter, false));
	CHECK(!t.allowed("t", 600, false));
	CHECK(t.allowed("free", kNoCharacter, false));
}

// A map server runs every task's logic: it gets every task, the empty audience's too.
TEST(task_audience_bridge_is_always_in)
{
	Table t;
	CHECK(t.set("t", {500}) == Table::Set::Added);
	CHECK(t.set("nobody", {}) == Table::Set::Added); // an empty audience is valid
	CHECK(t.allowed("t", kNoCharacter, true));
	CHECK(t.allowed("t", 600, true));
	CHECK(t.allowed("nobody", kNoCharacter, true));
	CHECK(!t.allowed("nobody", 0, false));
	CHECK(!t.allowed("nobody", 500, false));
}

TEST(task_audience_remove_is_everybody_again)
{
	Table t;
	CHECK(t.set("t", {500}) == Table::Set::Added);
	CHECK(!t.allowed("t", 501, false));
	CHECK(t.remove("t"));
	CHECK(t.allowed("t", 501, false));
	CHECK(t.find("t") == nullptr);
	CHECK(!t.remove("t")); // twice: nothing there
	CHECK(t.empty());
}

// A faction change or a late joiner judged: Lua sends the whole set again.
TEST(task_audience_replacing_an_entry)
{
	Table t;
	CHECK(t.set("t", {500, 501}) == Table::Set::Added);
	CHECK(t.set("t", {501, 500}) == Table::Set::Unchanged); // the order does not matter
	CHECK(t.set("t", {500, 500, 501}) == Table::Set::Unchanged); // nor repeats
	CHECK(t.set("t", {501, 502}) == Table::Set::Replaced);
	CHECK(!t.allowed("t", 500, false)); // lost it
	CHECK(t.allowed("t", 502, false)); // gained it
	CHECK(t.allowed("t", 501, false));
	CHECK_EQ(t.size(), size_t(1));
}

// The "keep the old broadcast" switch: no entry at all.
TEST(task_audience_empty_table_reports_empty)
{
	Table t;
	CHECK(t.empty());
	CHECK_EQ(t.size(), size_t(0));
	CHECK(t.set("a", {}) == Table::Set::Added);
	CHECK(!t.empty());
	CHECK(t.set("b", {1}) == Table::Set::Added);
	CHECK(t.remove("a"));
	CHECK(!t.empty());
	t.clear(); // story::reset
	CHECK(t.empty());
	CHECK(t.allowed("b", 2, false));
}

// What the binding refuses changes nothing.
TEST(task_audience_refused_changes_nothing)
{
	Table t;
	CHECK(t.set("t", {500}) == Table::Set::Added);
	CHECK(t.set("", {500}) == Table::Set::Refused);
	CHECK(t.set(std::string(kMaxIdLength + 1, 'x'), {500}) == Table::Set::Refused);
	CHECK(t.set(std::string(kMaxIdLength, 'x'), {500}) == Table::Set::Added);
	CHECK(t.set("t", {500, kNoCharacter}) == Table::Set::Refused);
	std::vector<uint16_t> many;
	for (uint16_t i = 0; i < kMaxMembers + 1; ++i)
		many.push_back(i);
	CHECK(t.set("t", many) == Table::Set::Refused);
	CHECK(t.allowed("t", 500, false)); // the old entry stands
	CHECK(!t.allowed("t", 0, false));
	many.pop_back();
	CHECK(t.set("t", many) == Table::Set::Replaced); // exactly kMaxMembers
	CHECK(t.allowed("t", 0, false));
}

TEST(task_audience_table_is_bounded)
{
	Table t;
	size_t added = 0;
	for (size_t i = 0; i < kMaxEntries; ++i)
		added += t.set("task_" + std::to_string(i), {1}) == Table::Set::Added ? 1 : 0;
	CHECK_EQ(added, kMaxEntries);
	CHECK(t.set("one_more", {1}) == Table::Set::Refused);
	CHECK(t.allowed("one_more", 2, false)); // still everybody's
	CHECK(t.set("task_0", {2}) == Table::Set::Replaced); // an existing entry still changes
	CHECK(t.remove("task_1"));
	CHECK(t.set("one_more", {1}) == Table::Set::Added);
}
