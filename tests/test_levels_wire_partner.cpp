// Anomaly Coop unit tests: the talk partner in LevelBodyFacts (build 57, protocol 33, step S3 of
// docs/plans/2026-11-18-two-modes.md, unit A-S3P). The owner asked whom a player on a map server's level talks to: the world server
// has no game object of his body and knew only `talking` (protocol 23). The map server of his level now says whom, next to
// `talking`: u16 partner, the NPC of his talk lock there (dialog::host_lock_of) in the world server's numbering, 0xffff none. The
// world server keeps a partner only while he talks (kept_partner); Lua reads it as coop.levels.talk_partner(peer).
#include "test_util.h"
#include "srv/coop_levels_wire.h"

#include <cstdint>
#include <vector>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
std::vector<uint8_t> written(const LevelBodyFacts& f)
{
	Writer w;
	f.write(w);
	return w.data();
}
} // namespace

TEST(levels_wire_partner_is_none_by_default)
{
	LevelBodyFacts f;
	CHECK_EQ(f.partner, kNoObject);
	const std::vector<uint8_t> b = written(f);
	Reader r(b.data(), b.size());
	LevelBodyFacts g;
	g.partner = 5;
	CHECK(g.read(r));
	CHECK_EQ(g.partner, kNoObject); // nobody, as sent
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(levels_wire_partner_round_trips_right_after_talking)
{
	LevelBodyFacts a;
	a.fight = 1;
	a.talking = 1;
	a.partner = 0x1234;
	a.place = 3;
	a.source = 777;
	const std::vector<uint8_t> b = written(a);
	// u8 fight, u8 talking, u16 partner, u8 place, u16 source, then the footing of build 57 (21 bytes): 2 bytes more than protocol 32
	CHECK_EQ(b.size(), size_t(7 + 21));
	CHECK_EQ(int(b[0]), 1);
	CHECK_EQ(int(b[1]), 1);
	CHECK_EQ(int(b[2]), 0x34); // little endian, as every u16 of the wire
	CHECK_EQ(int(b[3]), 0x12);
	CHECK_EQ(int(b[4]), 3); // place follows the partner
	Reader r(b.data(), b.size());
	LevelBodyFacts g;
	CHECK(g.read(r));
	CHECK_EQ(g.fight, uint8_t(1));
	CHECK_EQ(g.talking, uint8_t(1));
	CHECK_EQ(g.partner, uint16_t(0x1234));
	CHECK_EQ(g.place, uint8_t(3));
	CHECK_EQ(g.source, uint16_t(777));
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(levels_wire_partner_cut_anywhere_is_refused_whole)
{
	LevelBodyFacts a;
	a.talking = 1;
	a.partner = 900;
	a.source = 12;
	const std::vector<uint8_t> b = written(a);
	for (size_t cut = 0; cut < b.size(); ++cut)
	{
		Reader r(b.data(), cut);
		LevelBodyFacts g;
		g.partner = 7;
		CHECK(!g.read(r));
		CHECK_EQ(g.partner, kNoObject); // nothing of a cut report is kept
		CHECK_EQ(g.talking, uint8_t(0));
	}
}

TEST(levels_wire_partner_is_kept_only_while_he_talks)
{
	LevelBodyFacts f;
	f.partner = 42;
	f.talking = 0;
	CHECK_EQ(kept_partner(f), kNoObject); // a partner without a talk lock says nothing
	f.talking = 1;
	CHECK_EQ(kept_partner(f), uint16_t(42));
	f.partner = kNoObject;
	CHECK_EQ(kept_partner(f), kNoObject); // he talks and the map server named nobody
	f.talking = 2; // any non-zero byte is a talk, as `talking` always read
	f.partner = 3;
	CHECK_EQ(kept_partner(f), uint16_t(3));
}
