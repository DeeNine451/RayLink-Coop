// Anomaly Coop unit tests: R32 fix package A (the Server mode's levels code after the WP3/WP4 reviews). The pure parts (the journal
// receiver's rule of a batch before Ready, the born-unit question) and the engine's glue, whose source is read (the engine is not
// built into the test exe): srv/coop_levels_alife.cpp (the world's acceptance and apply), srv/coop_levels_xfer.cpp (the journal, the
// transfers), coop_items.cpp (the item facts' source).
//   A1  a Spawn under a block the world gave the sender is its own (host_id_is_senders), not only its slice;
//   A2  a root-less Spawn needs the sender's lead of its map (tests/test_levels_accept.cpp has the rule);
//   A3  a batch of the current bridge of a map before its Ready is applied and answered;
//   A4  §8a A17, a creature leaving a held squad inherits the hold (tests/test_levels_adopt.cpp has the protocol);
//   A5  release_here decides by accept::release_plan (tests/test_levels_accept.cpp);
//   A6  xfer_authors under the transfers' lock, on the terms of xfer_stock_rules;
//   A7  xfer_born: a unit whose Spawn waits in the frame's journal;
//   A8  the ItemFacts source from items::level_facts_source;
//   A9  the auditor's hash after the frame's facts.
// Fix round 2 (the verifier's findings): a member whose release is under way is not adopted at its Left (1); a Left of a member a
// newer squad bound first only unlists it (2); the writer rule names the map server through its hand-back (3); the audit's heal of a
// Left takes the member home (4).
// Server mode only; the co-op has no map servers, no journal and no transfers.
#include "test_util.h"

#include "srv/coop_levels_journal.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace
{
namespace jr = coop::levels::journal;
using H = coop::levels::wire::LevelEntityHead;

// The code of an engine file, comments and literals blanked.
std::string engine_code(const char* relative)
{
	const auto path = std::filesystem::path(__FILE__).parent_path().parent_path() / "engine/src" / relative;
	std::ifstream in(path, std::ios::binary);
	REQUIRE(in.is_open());
	std::ostringstream source;
	source << in.rdbuf();
	const std::regex comments_and_literals(R"cpp(//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])')cpp");
	return std::regex_replace(source.str(), comments_and_literals, " ");
}

// The body of the definition `type name(...) {` (its braces matched), empty when there is none.
std::string_view body_of(const std::string& code, const char* type, const char* name)
{
	std::smatch match;
	const std::regex definition(std::string(R"(\b)") + type + R"(\s+)" + name + R"(\s*\([^;{}]*\)\s*\{)");
	if (!std::regex_search(code, match, definition))
		return {};
	const size_t start = size_t(match.position() + match.length());
	int depth = 1;
	for (size_t i = start; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return std::string_view(code).substr(start, i - start);
	}
	return {};
}

bool has(std::string_view body, std::string_view what) { return body.find(what) != std::string_view::npos; }

bool before(std::string_view body, std::string_view first, std::string_view second)
{
	const size_t at = body.find(second);
	return at != std::string_view::npos && body.find(first) < at;
}

const char* const kAlife = "xrGame/coop/srv/coop_levels_alife.cpp";
const char* const kXfer = "xrGame/coop/srv/coop_levels_xfer.cpp";

struct Up
{
	uint8_t op;
	uint16_t a;
	uint16_t b;
};
} // namespace

// A3: the world applies (and answers) a batch of a connected map server and of the current bridge of a map that has not said Ready
// yet; a bridge no map names any more stays dropped.
TEST(levels_fixa_batches_before_ready_are_applied)
{
	CHECK(jr::applies_batch_of(true, true));
	CHECK(jr::applies_batch_of(true, false)); // connected: as before
	CHECK(jr::applies_batch_of(false, true)); // Starting: its batches count (the acceptance refuses what it may not write)
	CHECK(!jr::applies_batch_of(false, false)); // cut or lost: nothing of it counts
}

// A7: a Spawn of the unit waits among the frame's ups.
TEST(levels_fixa_a_spawn_queued_in_the_frame)
{
	std::vector<Up> ups;
	CHECK(!jr::spawn_queued(ups, 0x9001));
	ups.push_back(Up{uint8_t(H::Parent), 0x9001, 0x10});
	ups.push_back(Up{uint8_t(H::Spawn), 0x9002, 0xffff});
	CHECK(!jr::spawn_queued(ups, 0x9001)); // a move of it is no spawn
	CHECK(jr::spawn_queued(ups, 0x9002));
	ups.push_back(Up{uint8_t(H::Spawn), 0x9001, 0xffff});
	CHECK(jr::spawn_queued(ups, 0x9001));
}

// A1, A2, A5, A4 (the world's side of A17): the acceptance and the apply in srv/coop_levels_alife.cpp.
TEST(levels_fixa_world_apply_glue)
{
	const std::string code = engine_code(kAlife);
	const auto fact = body_of(code, "ApplyVerdict", "apply_entry"); // host_apply_fact's body (fix round 2: shared with host_apply_heal)
	REQUIRE(!fact.empty());
	// A1: the id of a Spawn is the sender's when it is of its slice or of a block this world gave it
	CHECK(has(fact, "f.id_in_slice = host_id_is_senders(author, id)"));
	CHECK(!has(fact, "leader_ids_of("));
	// A2: a root-less Spawn names the map it stands on and the sender's lead of its own map; no "its map, so its own" any more
	CHECK(has(fact, "f.rootless = true"));
	CHECK(has(fact, "f.spawn_level = at"));
	CHECK(has(fact, "f.sender_leads = of_senders_map == writer::other(author)"));
	CHECK(!has(fact, "? writer::other(author) :"));
	// A4: a Left goes by leave_squad, a Joined drops the member's own hold after it joined
	CHECK(has(fact, "leave_squad(author, *squad, *member, origin)"));
	CHECK(!has(fact, "squad->coop_leave_member("));
	CHECK(before(fact, "squad->coop_join_member(b.member)", "host_member_joined(author, b.member)"));
	const auto leave = body_of(code, "bool", "leave_squad");
	REQUIRE(!leave.empty());
	CHECK(before(leave, "host_adopt_member(author, squad.ID, member.ID, state_of(&member))", "squad.coop_leave_member_held(member.ID)"));
	CHECK(before(leave, "squad.coop_leave_member_held(member.ID)", "squad.coop_leave_member(member.ID)")); // today's way: the fallback
	CHECK(has(leave, "member.g_Alive()"));
	// the member stays online elsewhere, out of the squad and out of this world's registries
	const auto held = body_of(code, "bool", "CSE_ALifeOnlineOfflineGroup::coop_leave_member_held");
	REQUIRE(!held.empty());
	CHECK(has(held, "m->m_group_id = 0xffff"));
	CHECK(has(held, "m->m_bOnline = true"));
	CHECK(has(held, "m_members.erase(I)"));
	CHECK(has(held, "scheduled().remove(m)"));
	CHECK(has(held, "graph().remove(m, vertex, false)"));
	CHECK(!has(held, "scheduled().add"));
	CHECK(!has(held, "graph().add"));
	CHECK(!has(held, "unregister_member"));
	CHECK(!has(held, "switch_online"));
	// A5: release_here asks the pure plan
	const auto release = body_of(code, "bool", "release_here");
	CHECK(has(release, "accept::release_plan(f)"));
	CHECK(before(release, "plan.take_squad_vertex", "alife_rw().release(e, true)"));
	CHECK(before(release, "plan.clear_online", "alife_rw().release(e, true)"));
}

// A3, A4 (the map server's side and the world's keeper), A6, A7, A8, A9: srv/coop_levels_xfer.cpp.
TEST(levels_fixa_xfer_glue)
{
	const std::string code = engine_code(kXfer);
	// A3: a batch of a Starting map server's current bridge goes through the acceptance and is answered
	const auto journal = body_of(code, "void", "host_on_level_journal");
	REQUIRE(!journal.empty());
	CHECK(has(journal, "journal::applies_batch_of(g.keeper.connected(from), mapserver::bridge_of(mapserver::level_of_bridge(from)) == from)"));
	CHECK(before(journal, "journal::applies_batch_of(", "host_apply_fact(from, e, why, m.seq)"));
	CHECK(before(journal, "host_apply_fact(from, e, why, m.seq)", "net::host_send(from, Msg::LevelJournalAck, w)"));
	CHECK(!has(journal, "if (!g.keeper.connected(from))\n\t{")); // the old early drop
	// A4: the map server adopts at the Left hook, again at the flush (a squad flushed only now), drops its own hold at a Joined into
	// a squad it writes, and undoes an adoption whose Left goes after a death or a release
	CHECK(has(body_of(code, "void", "up_member"), "client_adopt_left(squad, member, mgr().now_ms())"));
	const auto adopt = body_of(code, "void", "client_adopt_left");
	CHECK(before(adopt, "g.holder->authors(unit)", "g.holder->adopt(id, unit,"));
	CHECK(has(adopt, "c->g_Alive()"));
	const auto flush = body_of(code, "void", "client_flush_up");
	CHECK(before(flush, "journal_body(u8(u.op), body, body.member)", "g.holder->forget(body.member)"));
	CHECK(has(flush, "client_adopt_left(u.a, u.b, mgr().now_ms())"));
	CHECK(before(body_of(code, "void", "up_died"), "if (p.before_left)", "client_unadopt(victim)"));
	CHECK(before(body_of(code, "void", "xfer_on_released"), "if (p.before_left)", "client_unadopt(local_id)"));
	CHECK(has(body_of(code, "bool", "host_adopt_member"), "g.keeper.adopt(member, squad, u32(bridge), state)"));
	CHECK(has(body_of(code, "void", "host_member_joined"), "g.keeper.drop_own(member, u32(bridge), mgr().now_ms())"));
	// A6: the writer rule's question under the lock, of a holder of this world; the repair asks the holder itself. Fix round 2
	// (verifier finding 3): also while it hands everything back, a unit on its way home is its until the world's Ack (W1.3), as the
	// world's keeper says: the hand-back stops the switch vote and the scheduler only
	const auto authors = body_of(code, "bool", "xfer_authors");
	CHECK(before(authors, "xrCriticalSectionGuard guard(g.lock)", "g.holder->authors("));
	CHECK(has(authors, "holder_writes()"));
	const auto writes = body_of(code, "bool", "holder_writes");
	CHECK(has(writes, "g.holder_world == join::world_generation()"));
	CHECK(!has(writes, "handing_back"));
	CHECK(has(body_of(code, "bool", "xfer_stock_rules"), "g.handing_back"));
	CHECK(has(body_of(code, "void", "xfer_scheduled"), "g.handing_back"));
	CHECK(!has(body_of(code, "void", "client_on_journal_ack"), "xfer_authors("));
	// A7: xfer_born
	const auto born = body_of(code, "bool", "xfer_born");
	REQUIRE(!born.empty());
	CHECK(before(born, "xrCriticalSectionGuard guard(g.lock)", "journal::spawn_queued(g.up, local_id)"));
	CHECK(has(born, "holder_writes()"));
	CHECK(has(born, "transfers(e)"));
	// A8: the ItemFacts source is the one note_facts recorded, Decider when none
	CHECK(before(flush, "items::level_facts_source(u.a)", "items::level_item_state(u.a, section, blob)"));
	CHECK(has(flush, "body.source = noted != journal::ItemFactsBody::Loot ? noted : u8(journal::ItemFactsBody::Decider)"));
	CHECK(!has(flush, "body.source = journal::ItemFactsBody::Decider;"));
	// A9: the hash after the frame's facts
	CHECK(before(body_of(code, "void", "client_audit"), "client_send_all()", "net::client_send(Msg::LevelHash, w)"));
}

// A8: the item engine records the source of a fact before it raises the entry, so the flush always finds it.
TEST(levels_fixa_item_facts_source_is_noted_first)
{
	const std::string code = engine_code("xrGame/coop/coop_items.cpp");
	const auto note = body_of(code, "void", "note_facts");
	REQUIRE(!note.empty());
	CHECK(before(note, "pending = source", "side->level_item_facts_up(id)"));
	CHECK(has(body_of(code, "u8", "level_facts_source"), "g_facts_source.erase(it)")); // read once
}

// ---------------------------------------------------------------- fix round 2 (the verifier's findings on package A)

// Finding 1: a creature whose release is under way is never adopted at the Left its release raises (the Released hook runs first,
// then the squad's unregister_member, the creature still alive and registered). Its Destroy, queued at the Released hook, then goes in
// the journal (it is no unit of its own on either side) and releases it on the world from its squad. The mark is taken at the Released
// hook before anything else (a refused create's quiet release too), forgotten when an object is made under the id or none stands
// under it; a Left or a Joined of a quiet creature (the world never had it) is not journaled.
TEST(levels_fixa2_a_member_on_its_way_out_is_not_adopted)
{
	const std::string code = engine_code(kXfer);
	const auto released = body_of(code, "void", "xfer_on_released");
	REQUIRE(!released.empty());
	CHECK(before(released, "xrCriticalSectionGuard guard(g.lock)", "g.releasing.released(local_id)"));
	CHECK(before(released, "g.releasing.released(local_id)", "g.quiet.count(local_id)"));
	const auto adopt = body_of(code, "void", "client_adopt_left");
	REQUIRE(!adopt.empty());
	CHECK(has(adopt, "f.releasing = g.releasing.under_way(member)"));
	CHECK(before(adopt, "journal::adopts_at_left(f)", "g.holder->adopt(id, unit,"));
	const auto spawned = body_of(code, "void", "up_spawned");
	CHECK(before(spawned, "g.releasing.spawned(id)", "entities::client_applying()"));
	CHECK(before(body_of(code, "void", "client_flush_up"), "g.releasing.prune(", "for (const State::Up& u : due)"));
	CHECK(has(body_of(code, "void", "xfer_reset"), "g.releasing.clear()"));
	const auto member = body_of(code, "void", "up_member");
	CHECK(before(member, "g.quiet.count(member)", "g.up.push_back("));
	CHECK(before(member, "g.up.push_back(", "client_adopt_left(squad, member, mgr().now_ms())"));
}

// Findings 2 and 4: the world applies a Left by accept::leave_plan (tests/test_levels_accept.cpp accept_fixa_leave_plan). A member a
// newer squad bound first is only unlisted (its m_group_id, m_bOnline and registries stay its new squad's); the audit's heal of a
// member list goes by host_apply_heal, whose Left takes the member home (no hold the map server never took).
TEST(levels_fixa2_the_world_applies_a_left_by_its_plan)
{
	const std::string code = engine_code(kAlife);
	const auto leave = body_of(code, "bool", "leave_squad");
	REQUIRE(!leave.empty());
	CHECK(has(leave, "f.bound_elsewhere = member.m_group_id != 0xffff && member.m_group_id != squad.ID"));
	CHECK(has(leave, "f.heal = origin == Origin::Heal"));
	CHECK(before(leave, "accept::leave_plan(f)", "squad.coop_unlist_member(member.ID)"));
	CHECK(has(leave, "case accept::Leave::Unlist: return squad.coop_unlist_member(member.ID)"));
	CHECK(before(leave, "case accept::Leave::Adopt:", "host_adopt_member(author, squad.ID, member.ID, state_of(&member))"));
	CHECK(has(leave, "case accept::Leave::NotMember: return false"));
	const auto unlist = body_of(code, "bool", "CSE_ALifeOnlineOfflineGroup::coop_unlist_member");
	REQUIRE(!unlist.empty());
	CHECK(has(unlist, "m_members.erase(I)"));
	CHECK(!has(unlist, "m_group_id"));
	CHECK(!has(unlist, "m_bOnline"));
	CHECK(!has(unlist, "scheduled()"));
	CHECK(!has(unlist, "graph()"));
	CHECK(!has(unlist, "unregister_member"));
	CHECK(has(body_of(code, "ApplyVerdict", "host_apply_fact"), "return apply_entry(author, e, why, epoch, Origin::Journal)"));
	CHECK(has(body_of(code, "ApplyVerdict", "host_apply_heal"), "return apply_entry(author, e, why, epoch, Origin::Heal)"));
	const std::string xfer = engine_code(kXfer);
	const auto heal = body_of(xfer, "bool", "host_heal_member");
	CHECK(has(heal, "host_apply_heal(from, e, why, g.received.last(u32(from)))"));
	CHECK(!has(heal, "host_apply_fact("));
}
