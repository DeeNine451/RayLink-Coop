// Anomaly Coop unit tests: the answers of the two modes and of no session as fixed sets (docs/MODES.md section 4, xrCoop/coop_mode.h).
//
// A test of a Core rule runs it once per process kind:
//
//   #include "support/fake_mode.h"
//   for (const t::ModeCase& c : t::mode_cases())
//   {
//       t::FakeMode m(c);
//       m.place(7, t::Spot::Elsewhere);          // peer 7 plays on another map
//       m.character(0x2a, 7);                    // his character is 0x2a here
//       ... the rule under test, given m.where(7), m.decider_of(0x2a), m.decides_world() ...
//   }
//
// or names one set: t::FakeMode m(t::mode_case("map_server")). MODE_CASES(X) lists the six names (X-macro). What the fake answers is
// what the real modes answer (hostplay/coop_hostplay_mode.cpp, srv/coop_srv_mode.cpp, NoneMode; tests/test_mode_answers.cpp checks
// the rows of the real files against these). deliver / stream / up are recorded when the process kind sends them at all.
//
// A-S6-IF (S6): the hooks of the S6 groups answer per kind too (tests/test_mode_s6_answers.cpp checks them, and the real modes'
// answers from their sources). A map server has a level side (m.side(): it records what it was told and keeps its own book of
// balances; m.side().trunk[peer] = character is its table of the level's players). The world server's level answers come from the
// spots and from what the test says of the map servers: m.bridge(peer) (that peer is a map server's bridge), m.level_up(level)
// (the map server of that level is up), m.map_down(peer) (nobody leads the map of that player now). m.world_level(level): the level
// the world server stands on, as a player's loading screen sees it.
//
// VEH-DISC: departure(peer, character) answers Disconnected in every kind but a map server, which answers what its world's LevelMap
// said when that player left its level: m.departed(peer, character, why) writes it, m.came(peer) drops it
// (tests/test_vehicle_departure.cpp checks the real modes' answers against these).
//
// R32 (temp/r30/design/R32-final.md §8): writer_of(root) answers through the pure rule (xrCoop/coop_writer_rules.h writer_of) with the
// kind the answers of the case make (writer::process_kind: a mirror, decides_world, leads_level) and the facts the test gives:
// m.own_level(level) (the map a map server leads), m.lead(level, lead, peer) (the server of a map as this process knows it, the peer
// that names it here), m.moving(character, from) / m.moved(character) (his move fence from that map is open / through),
// m.holds(unit, level, holder[, how]) / m.home(unit) (a map server holds the unit / it is at home in the world). reconcile_world()
// counts in m.reconciles for a map server; save_ready() is false on a world server while m.flush_pending(true) holds
// (tests/test_writer_rules.cpp).
#pragma once

#include "srv/coop_ghost_rules.h"
#include "coop_mode.h"
#include "srv/coop_operator.h"
#include "coop_roles.h"
#include "srv/coop_scope.h"

#include <cstring>
#include <map>
#include <set>
#include <utility>
#include <vector>

namespace t
{
// The six process kinds, in the order of the table of docs/MODES.md section 4 and of the Lua sets (tests/lua/support/mode_*.lua).
#define MODE_CASES(X) X(coop_host) X(coop_client) X(world_server) X(map_server) X(server_client) X(none)

// Where a peer stands as seen by the process under test (the facts a real mode reads from its session and its tables).
enum class Spot : uint8_t
{
	Self, // this process's own seat (peer 0 on a host; a client's own slot)
	Here, // a player whose character is in the world on the map this process has loaded
	Elsewhere, // a player whose character is in the world on another map
	Joining, // a player of the session whose character is not placed in the world yet
	Stranger, // nobody of this session
};

struct ModeCase
{
	const char* name;
	coop::ModeAnswers answers;
	// where(peer) for a peer at each Spot
	coop::Where where_self, where_here, where_elsewhere, where_joining, where_stranger;
	// decider_of(character) for the character of a peer at each Spot (Self: this process's own actor)
	coop::Decider decider_self, decider_here, decider_elsewhere, decider_joining, decider_stranger;
	bool delivers; // deliver / stream reach somebody
	bool sends_up; // up reaches whoever decides for it
	// A-S6-IF (S6)
	bool has_level_side = false; // level() is a LevelSide (a map server)
	bool level_filter = false; // the players of other maps: reaches, led_elsewhere, to_level_of, join_save, join_from_bridge, level_ready
	bool delivers_links = false; // deliver_links reaches a link (the co-op host's player, the world server's bridges; a map server has none)
	bool server_loading_line = false; // load_text names the map server of the level
	bool level_ghost = false; // ghost_said and on_world_live are the level's (its actor is a ghost on a map it leads)
	// INTEG-C (H-OPCMD): an operator's line goes to a world server from here (a player of a server world)
	bool operator_link = false;
	// VEH-DISC: departure() says how a player left (a map server: what its world's LevelMap said, m.departed); the others Disconnected
	bool departure_facts = false;
};

inline const std::vector<ModeCase>& mode_cases()
{
	using coop::Decider;
	using coop::Where;
	// the last five of a row (A-S6-IF): has_level_side, level_filter, delivers_links, server_loading_line, level_ghost; then
	// operator_link (INTEG-C), true for a player of a server world only; then departure_facts (VEH-DISC), true for a map server only
	static const std::vector<ModeCase> cases = {
		// the co-op host plays, everybody stands on his one map; he decides for every character
		{"coop_host", {true, true, true, true, coop::host_roles()}, Where::Here, Where::Here, Where::Here, Where::Joining, Where::Here,
			Decider::This, Decider::This, Decider::This, Decider::This, Decider::Nobody, true, true, false, false, true, false, false},
		// a co-op client: everybody on the host's map, the host decides
		{"coop_client", {true, false, false, true, coop::client_roles()}, Where::Here, Where::Here, Where::Here, Where::Here, Where::Here,
			Decider::Other, Decider::Other, Decider::Other, Decider::Other, Decider::Nobody, false, true, false, false, false, false, false},
		// the world server: no map of a player, its seat a ghost; a map server decides for a placed player, it for one not placed yet
		{"world_server", {false, true, false, false, coop::dedicated_roles()}, Where::Away, Where::Away, Where::Away, Where::Joining,
			Where::Joining, Decider::Nobody, Decider::Other, Decider::Other, Decider::This, Decider::Nobody, true, false, false, true, true,
			false, false},
		// a map server: leads its map, its actor a ghost; the world server decides the world. No link: its bridge carries its level
		// session, which has no LocalLink (review A-REV-E-1, finding 2); its reports go up through up()
		{"map_server", {false, false, true, false, coop::map_server_roles()}, Where::Away, Where::Here, Where::Away, Where::Joining,
			Where::Away, Decider::Nobody, Decider::This, Decider::Other, Decider::This, Decider::Nobody, true, true, true, false, false, true,
			true, false, true},
		// a player of a server world: his map's server decides, the world server's seat is nobody's character
		{"server_client", {true, false, false, false, coop::client_roles()}, Where::Here, Where::Here, Where::Away, Where::Here,
			Where::Away, Decider::Other, Decider::Other, Decider::Other, Decider::Other, Decider::Nobody, false, true, false, false, false,
			true, false, true},
		// no session: single player
		{"none", coop::kNoSessionAnswers, Where::Away, Where::Away, Where::Away, Where::Away, Where::Away, Decider::Nobody,
			Decider::Nobody, Decider::Nobody, Decider::Nobody, Decider::Nobody, false, false, false, false, false, false, false},
	};
	return cases;
}

// The case of that name; the "none" case for a name that is not one (the caller's CHECK on .name shows it).
inline const ModeCase& mode_case(const char* name)
{
	for (const ModeCase& c : mode_cases())
		if (!std::strcmp(c.name, name))
			return c;
	return mode_cases().back();
}

// A map server's side of its level as the fake has it (A-S6-IF): what the Core told it, and a book of balances as the real one keeps.
class FakeLevelSide final : public coop::LevelSide
{
public:
	struct Money
	{
		coop::PeerId peer;
		int64_t delta;
		bool trade;
	};
	struct Up
	{
		coop::EntityUp kind;
		uint16_t id, other;
	};

	void level_money_change(coop::PeerId peer, int64_t delta, bool trade) override
	{
		money_up.push_back({peer, delta, trade});
		if (!delta)
			return;
		uint32_t& b = balances[peer];
		const int64_t next = int64_t(b) + delta;
		b = next < 0 ? 0u : uint32_t(next);
	}
	bool level_balance(coop::PeerId peer, uint32_t& out) const override
	{
		const auto it = balances.find(peer);
		out = it == balances.end() ? 0u : it->second;
		return it != balances.end();
	}
	void level_balance_heard(coop::PeerId peer, uint32_t balance) override { balances[peer] = balance; }
	void level_item_tell(uint16_t id, const std::string&, const std::vector<uint8_t>&) override { items_told.push_back(id); }
	bool level_tent_limit(size_t world_tents, size_t limit) const override { return world_tents >= limit; }
	void level_tent_placed(uint16_t tent, uint16_t) override { tents_up.push_back(tent); }
	bool level_tent_packed(uint16_t tent) override
	{
		tents_packed.push_back(tent);
		return true;
	}
	bool level_in_world(uint16_t character) const override { return in_world.count(character) != 0; }
	void level_marker(const coop::death::Marker&) override { ++markers; }
	uint16_t level_character_of(coop::PeerId peer) const override
	{
		const auto it = trunk.find(peer);
		return it == trunk.end() ? uint16_t(0xffff) : it->second;
	}
	coop::PeerId level_peer_of(uint16_t character) const override
	{
		for (const auto& it : trunk)
			if (it.second == character)
				return it.first;
		return coop::kInvalidPeer;
	}
	void level_entity_up(coop::EntityUp kind, uint16_t id, uint16_t other) override { ups.push_back({kind, id, other}); }
	// INTEG-C (H-FIGHTREP): a fact goes up for a player of this level only
	void level_fight_reputation(uint16_t character, int delta) override
	{
		if (level_peer_of(character) != coop::kInvalidPeer)
			fights.emplace_back(character, delta);
	}

	std::map<coop::PeerId, uint16_t> trunk; // the level's players: peer -> character
	std::set<uint16_t> in_world; // characters whose join on the level is over
	std::map<coop::PeerId, uint32_t> balances;
	std::vector<Money> money_up;
	std::vector<uint16_t> items_told, tents_up, tents_packed;
	std::vector<Up> ups;
	std::vector<std::pair<uint16_t, int>> fights; // level_fight_reputation of a player of the level: character, delta
	int markers = 0;
};

class FakeMode final : public coop::ModeWithAnswers
{
public:
	struct Sent
	{
		coop::Msg type;
		coop::Lane lane;
		coop::PeerId except;
		bool stream;
	};
	struct Link
	{
		coop::PeerId to; // to_level_of: the player; deliver_links: kInvalidPeer
		coop::Msg type;
		coop::Lane lane;
	};

	explicit FakeMode(const ModeCase& c) : coop::ModeWithAnswers(c.answers), m_case(c) {}

	// Where peer stands for this process; a peer never placed is a stranger.
	void place(coop::PeerId peer, Spot spot) { m_spots[peer] = spot; }
	// character (this process's numbering) is the character of peer; 0 is this process's own actor unless placed otherwise.
	void character(uint16_t id, coop::PeerId peer) { m_characters[id] = peer; }
	// A-S6-IF: what the world server knows of the map servers, and the level a loading screen sees the world server on.
	void bridge(coop::PeerId peer) { m_bridges.insert(peer); }
	void level_up(uint16_t level) { m_ready.insert(level); }
	void map_down(coop::PeerId peer) { m_down.insert(peer); }
	void world_level(uint16_t level) { m_world_level = level; }
	// VEH-DISC: what the world's LevelMap said when `peer` left this process's level with `character` (a map server's book); came()
	// drops it, as his virtual peer's return to the level does.
	void departed(coop::PeerId peer, uint16_t character, coop::Departure why) { m_gone[peer] = {character, why}; }
	void came(coop::PeerId peer) { m_gone.erase(peer); }
	FakeLevelSide& side() { return m_side; }
	// R32: what this process's tables say of the roots (writer_of)
	void own_level(uint16_t level) { m_own_level = level; }
	void lead(uint16_t level, coop::writer::Lead l, coop::PeerId peer = coop::kInvalidPeer) { m_leads[level] = {l, peer}; }
	void moving(uint16_t character, uint16_t from) { m_moving[character] = from; }
	void moved(uint16_t character) { m_moving.erase(character); }
	void holds(uint16_t unit, uint16_t level, coop::PeerId holder, coop::writer::Hold how = coop::writer::Hold::Held)
	{
		m_holds[unit] = {how, level, holder};
	}
	void home(uint16_t unit) { m_holds.erase(unit); }
	void flush_pending(bool pending) { m_flush_pending = pending; }
	// The process as the writer rule sees it: the kind of this case's answers, its own map, its world (the host of its session or
	// of its bridge).
	coop::writer::Process process() const
	{
		return {coop::writer::process_kind(coop::has(m_case.answers.roles, coop::ProcessRole::Mirror), m_case.answers.decides_world,
		            m_case.answers.leads_level),
		    m_own_level, coop::kHostPeer};
	}

	const char* name() const override { return m_case.name; }
	coop::Where where(coop::PeerId peer) const override
	{
		switch (spot_of(peer))
		{
		case Spot::Self: return m_case.where_self;
		case Spot::Here: return m_case.where_here;
		case Spot::Elsewhere: return m_case.where_elsewhere;
		case Spot::Joining: return m_case.where_joining;
		case Spot::Stranger: break;
		}
		return m_case.where_stranger;
	}
	coop::Decider decider_of(uint16_t character) const override
	{
		const auto it = m_characters.find(character);
		if (it == m_characters.end())
			return character == 0 ? m_case.decider_self : m_case.decider_stranger;
		switch (spot_of(it->second))
		{
		case Spot::Self: return m_case.decider_self;
		case Spot::Here: return m_case.decider_here;
		case Spot::Elsewhere: return m_case.decider_elsewhere;
		case Spot::Joining: return m_case.decider_joining;
		case Spot::Stranger: break;
		}
		return m_case.decider_stranger;
	}
	bool facts_of(uint16_t, coop::levels::BodyFacts&) const override { return false; }
	void deliver(coop::Msg type, const coop::Writer&, coop::Lane lane, coop::PeerId except) override
	{
		if (m_case.delivers)
			delivered.push_back({type, lane, except, false});
	}
	void stream(coop::Msg type, const coop::Writer&, coop::PeerId except) override
	{
		if (m_case.delivers)
			delivered.push_back({type, coop::Lane::Unreliable, except, true});
	}
	void up(coop::Msg type, const coop::Writer&, coop::Lane lane) override
	{
		if (m_case.sends_up)
			sent_up.push_back({type, lane, coop::kInvalidPeer, false});
	}
	void configure(coop::SessionConfig&) const override {}
	void install(coop::ModeTables&) override { ++installs; }
	void frame() override { ++frames; }
	void session_over() override { ++overs; }
	bool online_elsewhere(uint16_t) const override { return false; }
	bool binder_may_update(CGameObject*) override { return true; }
	void held_update() override {}
	void switched_offline(uint16_t) override {}
	bool takes_own_ids() const override { return false; }
	uint16_t own_free_id() override { return 0xffff; }

	// A-S6-IF (S6), as the real modes answer (srv/coop_srv_mode.cpp, hostplay/coop_hostplay_mode.cpp, Mode's defaults for none)
	coop::LevelSide* level() override { return m_case.has_level_side ? &m_side : nullptr; }
	bool reaches(coop::PeerId peer, coop::Msg type) const override
	{
		return !m_case.level_filter || coop::level_passes(type, true, spot_of(peer) != Spot::Elsewhere);
	}
	void deliver_links(coop::Msg type, const coop::Writer&, coop::Lane lane) override
	{
		if (m_case.delivers_links)
			linked.push_back({coop::kInvalidPeer, type, lane});
	}
	bool led_elsewhere(coop::PeerId peer) const override
	{
		return m_case.level_filter && spot_of(peer) == Spot::Elsewhere && !m_down.count(peer);
	}
	bool to_level_of(coop::PeerId peer, coop::Msg type, const coop::Writer&, coop::Lane lane) override
	{
		if (!led_elsewhere(peer))
			return false;
		to_levels.push_back({peer, type, lane});
		return true;
	}
	bool join_from_bridge(coop::PeerId from, coop::Msg) override { return m_case.level_filter && m_bridges.count(from) != 0; }
	bool join_save(coop::PeerId from, CSE_ALifeHumanStalker&) override
	{
		return m_case.level_filter && spot_of(from) == Spot::Elsewhere;
	}
	bool level_ready(uint16_t level) const override { return !m_case.level_filter || m_ready.count(level) != 0; }
	void on_world_live() override
	{
		if (m_case.level_ghost)
			++lives;
	}
	const char* load_text(uint16_t screen_level, bool world_up) const override
	{
		return m_case.server_loading_line && !world_up && screen_level != m_world_level ? "st_coop_load_server" : nullptr;
	}
	bool ghost_said(const coop::ghost::Said& s) const override { return m_case.level_ghost && coop::ghost::about_actor(s); }
	// INTEG-C (H-OPCMD): the fake has no session; "Sent" stands for a session that took the line
	coop::OperatorSend send_operator_command(const std::string& line) override
	{
		if (!m_case.operator_link)
			return coop::OperatorSend::Unreachable;
		return coop::op::allowed(line) ? coop::OperatorSend::Sent : coop::OperatorSend::Refused;
	}
	// VEH-DISC, as the real modes answer: a map server what its book says of that peer with that character, everybody else Disconnected
	coop::Departure departure(coop::PeerId peer, uint16_t character) const override
	{
		const auto it = m_gone.find(peer);
		if (!m_case.departure_facts || it == m_gone.end() || it->second.first != character)
			return coop::Departure::Disconnected;
		return it->second.second;
	}
	// R32, as the real modes answer: through the pure rule, from the facts the test gave
	coop::writer::Writer writer_of(const coop::writer::RootFacts& r) const override
	{
		coop::writer::Seat seat;
		seat.map = lead_of(r.level);
		if (r.kind == coop::writer::RootKind::Character)
		{
			const auto it = m_moving.find(r.root);
			if (it != m_moving.end())
			{
				seat.from = it->second;
				seat.from_map = lead_of(it->second);
			}
		}
		if (r.kind == coop::writer::RootKind::Unit)
		{
			const auto it = m_holds.find(r.root);
			if (it != m_holds.end())
			{
				seat.hold = it->second.how;
				seat.holder_level = it->second.level;
				seat.holder = it->second.holder;
			}
		}
		return coop::writer::writer_of(r, process(), seat);
	}
	void reconcile_world() override
	{
		if (process().kind == coop::writer::ProcessKind::Level)
			++reconciles;
	}
	bool save_ready(uint64_t) override { return process().kind != coop::writer::ProcessKind::World || !m_flush_pending; }

	std::vector<Sent> delivered; // deliver and stream, when this kind delivers
	std::vector<Sent> sent_up; // up, when this kind sends up
	std::vector<Link> linked; // deliver_links, when this kind has links
	std::vector<Link> to_levels; // to_level_of that went to another process
	int installs = 0, frames = 0, overs = 0, lives = 0;
	int reconciles = 0; // R32: reconcile_world() of a map server

private:
	struct Held
	{
		coop::writer::Hold how;
		uint16_t level;
		coop::PeerId holder;
	};

	Spot spot_of(coop::PeerId peer) const
	{
		const auto it = m_spots.find(peer);
		return it == m_spots.end() ? Spot::Stranger : it->second;
	}
	coop::writer::MapLead lead_of(uint16_t level) const
	{
		const auto it = m_leads.find(level);
		return it == m_leads.end() ? coop::writer::MapLead{} : it->second;
	}

	ModeCase m_case;
	std::map<coop::PeerId, Spot> m_spots;
	std::map<uint16_t, coop::PeerId> m_characters;
	std::set<coop::PeerId> m_bridges, m_down;
	std::set<uint16_t> m_ready;
	uint16_t m_world_level = 0xffff;
	std::map<coop::PeerId, std::pair<uint16_t, coop::Departure>> m_gone; // VEH-DISC: peer -> his character here, how he left
	FakeLevelSide m_side;
	// R32 (writer_of)
	uint16_t m_own_level = coop::writer::kNoLevel;
	std::map<uint16_t, coop::writer::MapLead> m_leads; // map -> its server as this process knows it
	std::map<uint16_t, uint16_t> m_moving; // character -> the map whose move fence is open
	std::map<uint16_t, Held> m_holds; // unit -> who holds it
	bool m_flush_pending = false;
};
} // namespace t
