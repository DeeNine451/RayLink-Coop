// Anomaly Coop unit tests: which item-state tags differ between the host copy and the owner (coop_item_tags.h, R3 В1).
#include "test_util.h"

#include "coop_item_tags.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

using namespace coop;

namespace
{
using UpgradeList = std::vector<std::string>;

// Same field names as ItemData in coop_items.cpp (diverged() reads exactly these).
struct Item
{
	bool has_cond = false;
	std::uint16_t cond = 0;
	bool has_upgrades = false;
	UpgradeList upgrades;
	bool has_box = false;
	std::uint16_t box = 0;
	bool has_addons = false;
	std::uint8_t addons = 0;
	bool has_scope = false;
	std::uint8_t scope = 0;
	bool has_main = false;
	std::uint16_t main_count = 0;
	std::uint8_t main_type = 0;
	bool has_launcher = false;
	std::uint16_t gl_count = 0;
	std::uint8_t gl_type = 0;
	bool has_uses = false;
	std::uint8_t uses = 0;
};

// Upgrade order does not matter, like same_upgrades() in coop_items.cpp.
bool same_upgrades(const UpgradeList& a, const UpgradeList& b)
{
	if (a.size() != b.size())
		return false;
	for (const std::string& s : a)
		if (std::find(b.begin(), b.end(), s) == b.end())
			return false;
	return true;
}

std::uint32_t diff(const Item& cur, const Item& owner)
{
	return itemtags::diverged(cur, owner, same_upgrades);
}

// A weapon the way capture_object() reports it: every tag but the scope one.
Item weapon_without_scopes()
{
	Item d;
	d.has_cond = true;
	d.cond = 65535;
	d.has_upgrades = true;
	d.has_addons = true;
	d.addons = 0;
	d.has_main = true;
	d.main_count = 8;
	d.main_type = 1;
	return d;
}

Item food()
{
	Item d;
	d.has_cond = true;
	d.cond = 65535;
	d.has_upgrades = true;
	d.has_uses = true;
	d.uses = 4;
	return d;
}
} // namespace

TEST(item_tags_scope_rules)
{
	CHECK(!itemtags::scope_tag_applies(0)); // pistols, knife
	CHECK(itemtags::scope_tag_applies(1));
	CHECK(itemtags::scope_tag_applies(5));
	CHECK(!itemtags::scope_index_ok(0, 0)); // a weapon without scopes takes no scope index
	CHECK(!itemtags::scope_index_ok(255, 0));
	CHECK(itemtags::scope_index_ok(0, 1));
	CHECK(!itemtags::scope_index_ok(1, 1));
	CHECK(itemtags::scope_index_ok(4, 5));
	CHECK(!itemtags::scope_index_ok(5, 5));
}

TEST(item_tags_equal_states_do_not_differ)
{
	CHECK_EQ(diff(weapon_without_scopes(), weapon_without_scopes()), 0u);
	CHECK_EQ(diff(food(), food()), 0u);
	CHECK_EQ(diff(Item(), Item()), 0u);

	Item scoped = weapon_without_scopes();
	scoped.has_scope = true;
	scoped.scope = 2;
	CHECK_EQ(diff(scoped, scoped), 0u);
}

// R3 В1: the host copy of a pistol reported a scope tag, the owner's state had none -> never equal, "stuck" forever.
TEST(item_tags_scope_tag_the_owner_never_sent_is_not_enforced)
{
	const Item owner = weapon_without_scopes();
	Item host = weapon_without_scopes();
	host.has_scope = true;
	host.scope = 0;
	CHECK_EQ(diff(host, owner), 0u);
	host.scope = 3;
	CHECK_EQ(diff(host, owner), 0u);
}

// The same holds for any tag the owner left out (a partial state enforces only what it says).
TEST(item_tags_tags_the_owner_left_out_are_not_compared)
{
	const Item owner = weapon_without_scopes();
	Item host = weapon_without_scopes();
	host.has_uses = true;
	host.uses = 2;
	host.has_box = true;
	host.box = 30;
	host.has_launcher = true;
	host.gl_count = 1;
	CHECK_EQ(diff(host, owner), 0u);
}

TEST(item_tags_each_differing_tag_is_reported_alone)
{
	struct Case
	{
		itemtags::Bit bit;
		void (*owner)(Item&); // makes the owner carry the tag
		void (*host)(Item&); // makes the host copy carry another value
	};
	const Case cases[] = {
		{itemtags::Cond, [](Item& d) { d.cond = 100; }, [](Item& d) { d.cond = 101; }},
		{itemtags::Upgrades, [](Item& d) { d.upgrades = {"up_a"}; }, [](Item& d) { d.upgrades = {"up_b"}; }},
		{itemtags::Box, [](Item& d) { d.has_box = true; d.box = 10; }, [](Item& d) { d.has_box = true; d.box = 11; }},
		{itemtags::Addons, [](Item& d) { d.addons = 1; }, [](Item& d) { d.addons = 3; }},
		{itemtags::Scope, [](Item& d) { d.has_scope = true; d.scope = 1; }, [](Item& d) { d.has_scope = true; d.scope = 2; }},
		{itemtags::Main, [](Item& d) { d.main_count = 5; }, [](Item& d) { d.main_count = 6; }},
		{itemtags::Launcher, [](Item& d) { d.has_launcher = true; d.gl_count = 1; d.gl_type = 0; },
			[](Item& d) { d.has_launcher = true; d.gl_count = 1; d.gl_type = 1; }},
		{itemtags::Uses, [](Item& d) { d.has_uses = true; d.uses = 3; }, [](Item& d) { d.has_uses = true; d.uses = 2; }},
	};
	std::uint32_t covered = 0;
	for (const Case& c : cases)
	{
		Item owner = weapon_without_scopes();
		Item host = weapon_without_scopes();
		c.owner(owner);
		c.host(host);
		CHECK_EQ(diff(host, owner), std::uint32_t(c.bit));
		covered |= c.bit;
	}
	CHECK_EQ(covered, itemtags::kAll);
}

// A tag the owner carries and the host copy cannot report is a difference (the copy cannot take it).
TEST(item_tags_tag_missing_on_the_host_copy_differs)
{
	Item owner = food();
	owner.has_scope = true;
	owner.scope = 1;
	CHECK_EQ(diff(food(), owner), std::uint32_t(itemtags::Scope));

	Item no_uses = food();
	no_uses.has_uses = false;
	CHECK_EQ(diff(no_uses, food()), std::uint32_t(itemtags::Uses));
}

TEST(item_tags_several_tags_and_upgrade_order)
{
	Item owner = food();
	owner.upgrades = {"a", "b"};
	Item host = food();
	host.upgrades = {"b", "a"};
	CHECK_EQ(diff(host, owner), 0u); // order does not matter

	host.upgrades = {"a"};
	host.uses = 1;
	host.cond = 7;
	CHECK_EQ(diff(host, owner), std::uint32_t(itemtags::Cond | itemtags::Upgrades | itemtags::Uses));
}

// The upgrade lists are only compared when the owner carries them.
TEST(item_tags_upgrades_compared_only_when_the_owner_has_them)
{
	int calls = 0;
	auto counting = [&](const UpgradeList& a, const UpgradeList& b)
	{
		++calls;
		return same_upgrades(a, b);
	};
	Item owner = food();
	Item host = food();
	owner.has_upgrades = false;
	host.upgrades = {"x"};
	CHECK_EQ(itemtags::diverged(host, owner, counting), 0u); // the host copy has the tag, the owner does not: ignored
	CHECK_EQ(calls, 0);

	owner.has_upgrades = true;
	CHECK_EQ(itemtags::diverged(host, owner, counting), std::uint32_t(itemtags::Upgrades));
	CHECK_EQ(calls, 1);
}

// Live report 2026-11-08 (GAMMA): a client loots a corpse's M4. The host moves it into his character, his take callback
// (grok_gun_condition_fixed) pins it at 0.83, then the host's push of its own copy (the corpse's 0.15, the NPC's 12
// rounds) arrives. Before the fix the push replaced everything: the gun went red in his hands until the next shot pinned
// it again ("repaired itself"), and the host and the others kept the red copy meanwhile.
namespace
{
std::uint16_t q(double c) { return std::uint16_t(c * 65535.0 + 0.5); }

struct Take
{
	Item base; // the client's copy right before the take (stale: spawn values)
	Item now; // after its own take callbacks
	Item host; // the host's push
};

Take looted_m4()
{
	Take t;
	t.base = weapon_without_scopes();
	t.base.cond = q(0.60);
	t.base.main_count = 30;
	t.now = t.base;
	t.now.cond = q(0.83); // GAMMA pins a taken gun
	t.host = weapon_without_scopes();
	t.host.cond = q(0.15); // death_manager's condition of the corpse's gun
	t.host.main_count = 12; // the NPC fired 18 rounds on the host
	return t;
}
} // namespace

TEST(item_tags_owner_take_change_survives_the_host_push)
{
	const Take t = looted_m4();
	const std::uint32_t mine = itemtags::changed_since(t.now, t.base, same_upgrades);
	CHECK_EQ(mine, std::uint32_t(itemtags::Cond));
	const Item merged = itemtags::take_push(t.host, t.now, mine);
	CHECK_EQ(merged.cond, q(0.83)); // the owner's condition stays
	CHECK_EQ(merged.main_count, 12); // the host's magazine is fresher than the stale copy
	CHECK(merged.has_cond && merged.has_main && merged.has_addons);
	CHECK_EQ(diff(merged, t.host), std::uint32_t(itemtags::Cond)); // differs from the host only where the owner acted
}

TEST(item_tags_untouched_take_takes_the_whole_host_state)
{
	Take t = looted_m4();
	t.now = t.base;
	const std::uint32_t mine = itemtags::changed_since(t.now, t.base, same_upgrades);
	CHECK_EQ(mine, 0u);
	const Item merged = itemtags::take_push(t.host, t.now, mine);
	CHECK_EQ(diff(merged, t.host), 0u);
	CHECK_EQ(diff(t.host, merged), 0u);
}

TEST(item_tags_changed_since_sees_every_tag_either_way)
{
	Item base = food();
	Item now = base;
	now.uses = 3; // ate a portion
	CHECK_EQ(itemtags::changed_since(now, base, same_upgrades), std::uint32_t(itemtags::Uses));
	now = base;
	now.has_uses = false; // a tag only the base carries
	CHECK_EQ(itemtags::changed_since(now, base, same_upgrades), std::uint32_t(itemtags::Uses));
	CHECK_EQ(itemtags::changed_since(base, now, same_upgrades), std::uint32_t(itemtags::Uses));
	now = base;
	now.cond = q(0.5);
	now.has_box = true; // a new tag
	CHECK_EQ(itemtags::changed_since(now, base, same_upgrades), std::uint32_t(itemtags::Cond | itemtags::Box));
}

TEST(item_tags_take_push_never_keeps_the_owners_upgrades)
{
	Take t = looted_m4();
	t.now.upgrades = {"up_a"};
	t.host.upgrades = {"up_b"};
	const std::uint32_t mine = itemtags::changed_since(t.now, t.base, same_upgrades);
	CHECK_EQ(mine, std::uint32_t(itemtags::Cond | itemtags::Upgrades));
	const Item merged = itemtags::take_push(t.host, t.now, mine);
	CHECK(merged.upgrades == UpgradeList{"up_b"}); // the host's list (coop_ledger.h)
	CHECK_EQ(merged.cond, q(0.83));
}

TEST(item_tags_take_push_keeps_every_owner_tag)
{
	Take t = looted_m4();
	t.now.addons = 2;
	t.now.has_scope = true;
	t.now.scope = 1;
	t.now.main_count = 0; // unloaded right after the take
	t.now.main_type = 2;
	t.now.has_launcher = true;
	t.now.gl_count = 1;
	t.now.has_uses = true;
	t.now.uses = 2;
	t.now.has_box = true;
	t.now.box = 5;
	const std::uint32_t mine = itemtags::changed_since(t.now, t.base, same_upgrades);
	const Item merged = itemtags::take_push(t.host, t.now, mine);
	CHECK_EQ(diff(merged, t.now) & itemtags::kOwnerTakeTags, 0u);
	CHECK_EQ(diff(t.now, merged) & itemtags::kOwnerTakeTags, 0u);
}

// The owner tells the host only what it changed itself since the take: the rest of its copy may be stale.
TEST(item_tags_only_tags_makes_a_partial_state)
{
	const Take t = looted_m4();
	const Item part = itemtags::only_tags(t.now, itemtags::Cond);
	CHECK(part.has_cond);
	CHECK_EQ(part.cond, q(0.83));
	CHECK(!part.has_upgrades && !part.has_box && !part.has_addons && !part.has_scope);
	CHECK(!part.has_main && !part.has_launcher && !part.has_uses);
	// the host enforces only what the partial state carries: its fresher magazine is not "diverged"
	CHECK_EQ(diff(t.host, part), std::uint32_t(itemtags::Cond));
	const Item all = itemtags::only_tags(t.now, itemtags::kAll);
	CHECK_EQ(diff(all, t.now), 0u);
	CHECK_EQ(diff(t.now, all), 0u);
}

TEST(item_tags_names)
{
	for (std::uint32_t bit = 1; bit <= itemtags::Uses; bit <<= 1)
	{
		const char* n = itemtags::name(itemtags::Bit(bit));
		CHECK(n && *n && std::string(n) != "?");
	}
	CHECK_EQ(std::string(itemtags::name(itemtags::Scope)), std::string("scope"));
}

// Live report 2026-11-08 (stable 41.6, G.A.M.M.A.): a client fits a scope to his SR-3M. The clone is his own item, made at
// once on his machine from his live weapon (0.83, GAMMA's pin); the host builds its copy from its own view of the source
// and pushes it into his hands (host_push) - it showed 7 %. An item the owner made itself keeps all of the owner's tags
// over that push; only the upgrade list is the host's, as for a take.
namespace
{
Take scoped_sr3m()
{
	Take t;
	t.now = weapon_without_scopes();
	t.now.cond = q(0.83);
	t.now.main_count = 20;
	t.now.has_scope = true;
	t.now.scope = 1;
	t.base = Item(); // a made item has no copy from before a take
	t.host = t.now;
	t.host.cond = q(0.07); // the host's stale view of the source
	t.host.main_count = 15;
	t.host.has_upgrades = true;
	t.host.upgrades = {"up_sr3m_a"};
	return t;
}
} // namespace

TEST(item_tags_made_here_item_keeps_all_owner_tags_over_the_push)
{
	const Take t = scoped_sr3m();
	const std::uint32_t mine = itemtags::push_keeps(true, 0u);
	CHECK_EQ(mine, itemtags::kOwnerTakeTags);
	const Item merged = itemtags::take_push(t.host, t.now, mine);
	CHECK_EQ(merged.cond, q(0.83)); // not the host's 7 %
	CHECK_EQ(merged.main_count, 20);
	CHECK(merged.has_scope && merged.scope == 1);
	CHECK(merged.has_upgrades && merged.upgrades == UpgradeList{"up_sr3m_a"}); // the list stays the host's
}

TEST(item_tags_taken_item_keeps_only_what_its_take_changed)
{
	const Take t = looted_m4();
	const std::uint32_t changed = itemtags::changed_since(t.now, t.base, same_upgrades);
	CHECK_EQ(itemtags::push_keeps(false, changed), std::uint32_t(itemtags::Cond));
	CHECK_EQ(itemtags::push_keeps(false, itemtags::kAll), itemtags::kOwnerTakeTags); // never the upgrade list
	CHECK_EQ(itemtags::push_keeps(false, 0u), 0u);
}

// ---------------------------------------------------------------- TZ R32 W8.2 (protocol 34): a version per tagged field

namespace
{
constexpr itemtags::Bit kEveryBit[] = {itemtags::Cond, itemtags::Upgrades, itemtags::Box, itemtags::Addons, itemtags::Scope,
	itemtags::Main, itemtags::Launcher, itemtags::Uses};

std::vector<std::uint8_t> versions_bytes(const itemtags::FieldVersions& v, std::uint32_t mask)
{
	Writer w;
	itemtags::write_versions(w, v, mask);
	return w.data();
}

bool read_whole(const std::vector<std::uint8_t>& b, itemtags::FieldVersions& v, std::uint32_t& mask)
{
	Reader r(b.data(), b.size());
	return itemtags::read_versions(r, v, mask) && r.remaining() == 0;
}

itemtags::FieldVersions sample_versions()
{
	itemtags::FieldVersions v;
	std::uint16_t n = 1;
	for (const itemtags::Bit b : kEveryBit)
		v.set(b, std::uint16_t(n++ * 1000 + 7));
	return v;
}
} // namespace

TEST(item_tags_versions_one_per_tag)
{
	static_assert(itemtags::kTagCount == sizeof(kEveryBit) / sizeof(kEveryBit[0]), "one version per tag");
	std::uint32_t all = 0;
	for (size_t i = 0; i < itemtags::kTagCount; ++i)
	{
		CHECK_EQ(itemtags::tag_index(kEveryBit[i]), i);
		all |= kEveryBit[i];
	}
	CHECK_EQ(all, itemtags::kAll);
	// not one tag: no index
	CHECK_EQ(itemtags::tag_index(0u), itemtags::kTagCount);
	CHECK_EQ(itemtags::tag_index(itemtags::Cond | itemtags::Uses), itemtags::kTagCount);
	CHECK_EQ(itemtags::tag_index(1u << 8), itemtags::kTagCount);
	// a new state has no deliberate write of its decider on any tag
	const itemtags::FieldVersions none;
	for (const itemtags::Bit b : kEveryBit)
		CHECK_EQ(none.get(b), std::uint16_t(0));
	// the blob tag after the last tag coop_items.cpp has (TagCartridges = 11): a reader of protocol 33 skips it by its length
	static_assert(itemtags::kVersionsTag == 12, "the blob tag after TagCartridges = 11");
}

TEST(item_tags_versions_round_trip)
{
	const itemtags::FieldVersions v = sample_versions();
	// every tag: u8 mask, 8 x u16, lowest bit first
	std::vector<std::uint8_t> b = versions_bytes(v, itemtags::kAll);
	REQUIRE(b.size() == size_t(1 + 8 * 2));
	CHECK_EQ(int(b[0]), int(itemtags::kAll));
	CHECK_EQ(int(b[1] | (b[2] << 8)), 1007); // Cond, little endian as every u16 of the wire
	CHECK_EQ(int(b[15] | (b[16] << 8)), 8007); // Uses, last
	itemtags::FieldVersions back;
	std::uint32_t mask = 0;
	CHECK(read_whole(b, back, mask));
	CHECK_EQ(mask, itemtags::kAll);
	CHECK(back == v);
	CHECK(versions_bytes(back, mask) == b);

	// a part: the condition and the portions only (what a decider writes on purpose most); the others read as 0
	b = versions_bytes(v, itemtags::Cond | itemtags::Uses);
	REQUIRE(b.size() == size_t(1 + 2 * 2));
	CHECK(read_whole(b, back, mask));
	CHECK_EQ(mask, std::uint32_t(itemtags::Cond | itemtags::Uses));
	CHECK_EQ(back.get(itemtags::Cond), std::uint16_t(1007));
	CHECK_EQ(back.get(itemtags::Uses), std::uint16_t(8007));
	CHECK_EQ(back.get(itemtags::Upgrades), std::uint16_t(0));
	CHECK_EQ(back.get(itemtags::Main), std::uint16_t(0));

	// every single tag alone
	for (const itemtags::Bit bit : kEveryBit)
	{
		b = versions_bytes(v, bit);
		CHECK_EQ(b.size(), size_t(3));
		CHECK(read_whole(b, back, mask));
		CHECK_EQ(mask, std::uint32_t(bit));
		CHECK_EQ(back.get(bit), v.get(bit));
	}

	// none: the mask alone; bits outside the tags are not written
	b = versions_bytes(v, 0u);
	CHECK_EQ(b.size(), size_t(1));
	CHECK(read_whole(b, back, mask));
	CHECK_EQ(mask, 0u);
	CHECK(versions_bytes(v, itemtags::kAll | (1u << 9)) == versions_bytes(v, itemtags::kAll));
}

TEST(item_tags_versions_refused_whole)
{
	const std::vector<std::uint8_t> b = versions_bytes(sample_versions(), itemtags::kAll);
	for (size_t cut = 0; cut < b.size(); ++cut)
	{
		Reader r(b.data(), cut);
		itemtags::FieldVersions v = sample_versions();
		std::uint32_t mask = 5;
		CHECK(!itemtags::read_versions(r, v, mask));
		CHECK_EQ(mask, 0u); // nothing of a cut payload is kept
		CHECK(v == itemtags::FieldVersions());
	}
	// the mask is a u8 and kAll fills it: no bit names a field that has no version. What follows the versions of the mask is the
	// caller's to refuse (the blob tag's length bounds the payload), as every reader of the wire leaves it
	Writer w2;
	w2.u8(0);
	w2.u16(7);
	Reader r2(w2.ptr(), w2.size());
	itemtags::FieldVersions v2;
	std::uint32_t mask2 = 0;
	CHECK(itemtags::read_versions(r2, v2, mask2));
	CHECK_EQ(r2.remaining(), size_t(2));
}

TEST(item_tags_a_deliberate_write_moves_its_versions_on)
{
	itemtags::FieldVersions v;
	itemtags::bump(v, itemtags::Uses);
	CHECK_EQ(v.get(itemtags::Uses), std::uint16_t(1));
	CHECK_EQ(v.get(itemtags::Cond), std::uint16_t(0)); // only the tags written
	itemtags::bump(v, itemtags::Uses | itemtags::Cond);
	CHECK_EQ(v.get(itemtags::Uses), std::uint16_t(2));
	CHECK_EQ(v.get(itemtags::Cond), std::uint16_t(1));
	itemtags::bump(v, 0u);
	CHECK_EQ(v.get(itemtags::Uses), std::uint16_t(2));
	// 0 means "never written": the version after 65535 is 1
	v.set(itemtags::Box, 0xFFFF);
	itemtags::bump(v, itemtags::Box);
	CHECK_EQ(v.get(itemtags::Box), std::uint16_t(1));
	CHECK_EQ(itemtags::next_version(0), std::uint16_t(1));
	CHECK_EQ(itemtags::next_version(41), std::uint16_t(42));
	CHECK_EQ(itemtags::next_version(0xFFFF), std::uint16_t(1));
}

TEST(item_tags_a_report_counts_only_on_the_latest_version_of_its_field)
{
	// The decider (the writer of a medkit) took 2 of its 5 uses on purpose (a script's set_remaining_uses): version 1 of Uses.
	// The owner's game reported "5 uses" before that push reached it (made on version 0): stale, refused. His own wear of the
	// condition is on the latest version of Cond (nobody wrote it): kept. g4 F1/F2: a stale report never restores a debit.
	itemtags::FieldVersions latest;
	itemtags::bump(latest, itemtags::Uses);
	itemtags::FieldVersions stale; // the owner had applied nothing of the decider's
	const std::uint32_t carried = itemtags::Uses | itemtags::Cond;
	CHECK_EQ(itemtags::fresh(latest, stale, carried), std::uint32_t(itemtags::Cond));

	// He applies the push (version 1 of Uses), then eats one portion himself: his report is made on version 1, it counts
	itemtags::FieldVersions applied;
	itemtags::take(applied, latest, itemtags::Uses);
	CHECK_EQ(applied.get(itemtags::Uses), std::uint16_t(1));
	CHECK_EQ(itemtags::fresh(latest, applied, carried), carried);

	// The decider writes the condition too (version 1 of Cond) before his next report: the condition of that report is stale, his
	// portions are not
	itemtags::bump(latest, itemtags::Cond);
	CHECK_EQ(itemtags::fresh(latest, applied, carried), std::uint32_t(itemtags::Uses));
	// only the tags the report carries are asked about
	CHECK_EQ(itemtags::fresh(latest, applied, itemtags::Box), std::uint32_t(itemtags::Box));
	CHECK_EQ(itemtags::fresh(latest, applied, 0u), 0u);
	CHECK_EQ(itemtags::fresh(latest, applied, itemtags::kAll | (1u << 12)), itemtags::kAll & ~std::uint32_t(itemtags::Cond));

	// take() moves only the tags of the push
	itemtags::take(applied, latest, itemtags::Cond);
	CHECK_EQ(applied.get(itemtags::Cond), std::uint16_t(1));
	CHECK(applied == latest);
	// a version that wrapped is still one value: fresh compares, it does not order
	latest.set(itemtags::Uses, 0xFFFF);
	applied.set(itemtags::Uses, 0xFFFF);
	itemtags::bump(latest, itemtags::Uses);
	CHECK_EQ(itemtags::fresh(latest, applied, itemtags::Uses), 0u);
	itemtags::take(applied, latest, itemtags::Uses);
	CHECK_EQ(itemtags::fresh(latest, applied, itemtags::Uses), std::uint32_t(itemtags::Uses));
}

TEST(item_tags_versions_ride_the_blob_as_a_tag_older_readers_skip)
{
	// The ItemState blob is u8 version, then {u8 tag, varu len, payload} (coop_items.cpp write_data); a reader skips a tag it does
	// not know by its length. The versions are such a tag: a reader of protocol 33 reads the condition after it as before.
	Writer payload;
	itemtags::write_versions(payload, sample_versions(), itemtags::Cond | itemtags::Uses);
	Writer blob;
	blob.u8(1); // the blob's own version byte
	blob.u8(itemtags::kVersionsTag);
	blob.varu(payload.size());
	blob.bytes(payload.ptr(), payload.size());
	blob.u8(1); // TagCondition
	blob.varu(2);
	blob.u16(40000);
	// an old reader: skips 12 by length, finds the condition
	Reader r(blob.ptr(), blob.size());
	CHECK_EQ(int(r.u8()), 1);
	bool found = false;
	std::uint16_t cond = 0;
	while (r.ok() && r.remaining() > 0)
	{
		const std::uint8_t tag = r.u8();
		const std::uint64_t len = r.varu();
		REQUIRE(r.ok() && len <= r.remaining());
		if (tag == 1)
		{
			cond = r.u16();
			found = true;
		}
		else
			r.skip(size_t(len));
	}
	CHECK(found && cond == 40000);
	// a new reader: the tag's payload is exactly the versions
	Reader p(payload.ptr(), payload.size());
	itemtags::FieldVersions v;
	std::uint32_t mask = 0;
	CHECK(itemtags::read_versions(p, v, mask) && p.remaining() == 0);
	CHECK_EQ(v.get(itemtags::Uses), std::uint16_t(8007));
}
