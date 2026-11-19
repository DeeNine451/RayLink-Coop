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
#pragma once

#include "coop_mode.h"
#include "coop_roles.h"

#include <cstring>
#include <map>
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
};

inline const std::vector<ModeCase>& mode_cases()
{
	using coop::Decider;
	using coop::Where;
	static const std::vector<ModeCase> cases = {
		// the co-op host plays, everybody stands on his one map; he decides for every character
		{"coop_host", {true, true, true, true, coop::host_roles()}, Where::Here, Where::Here, Where::Here, Where::Joining, Where::Here,
			Decider::This, Decider::This, Decider::This, Decider::This, Decider::Nobody, true, true},
		// a co-op client: everybody on the host's map, the host decides
		{"coop_client", {true, false, false, true, coop::client_roles()}, Where::Here, Where::Here, Where::Here, Where::Here, Where::Here,
			Decider::Other, Decider::Other, Decider::Other, Decider::Other, Decider::Nobody, false, true},
		// the world server: no map of a player, its seat a ghost; a map server decides for a placed player, it for one not placed yet
		{"world_server", {false, true, false, false, coop::dedicated_roles()}, Where::Away, Where::Away, Where::Away, Where::Joining,
			Where::Joining, Decider::Nobody, Decider::Other, Decider::Other, Decider::This, Decider::Nobody, true, false},
		// a map server: leads its map, its actor a ghost; the world server decides the world
		{"map_server", {false, false, true, false, coop::map_server_roles()}, Where::Away, Where::Here, Where::Away, Where::Joining,
			Where::Away, Decider::Nobody, Decider::This, Decider::Other, Decider::This, Decider::Nobody, true, true},
		// a player of a server world: his map's server decides, the world server's seat is nobody's character
		{"server_client", {true, false, false, false, coop::client_roles()}, Where::Here, Where::Here, Where::Away, Where::Here,
			Where::Away, Decider::Other, Decider::Other, Decider::Other, Decider::Other, Decider::Nobody, false, true},
		// no session: single player
		{"none", coop::kNoSessionAnswers, Where::Away, Where::Away, Where::Away, Where::Away, Where::Away, Decider::Nobody,
			Decider::Nobody, Decider::Nobody, Decider::Nobody, Decider::Nobody, false, false},
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

	explicit FakeMode(const ModeCase& c) : coop::ModeWithAnswers(c.answers), m_case(c) {}

	// Where peer stands for this process; a peer never placed is a stranger.
	void place(coop::PeerId peer, Spot spot) { m_spots[peer] = spot; }
	// character (this process's numbering) is the character of peer; 0 is this process's own actor unless placed otherwise.
	void character(uint16_t id, coop::PeerId peer) { m_characters[id] = peer; }

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

	std::vector<Sent> delivered; // deliver and stream, when this kind delivers
	std::vector<Sent> sent_up; // up, when this kind sends up
	int installs = 0, frames = 0, overs = 0;

private:
	Spot spot_of(coop::PeerId peer) const
	{
		const auto it = m_spots.find(peer);
		return it == m_spots.end() ? Spot::Stranger : it->second;
	}

	ModeCase m_case;
	std::map<coop::PeerId, Spot> m_spots;
	std::map<uint16_t, coop::PeerId> m_characters;
};
} // namespace t
