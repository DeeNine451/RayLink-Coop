// R32 W7.2, A21 E-1 (WP11 Server): the done-records of numbered ops across map servers (temp/r30/design/R32-final.md §1 W7.2, §5
// Done = 17, §8a A21). A map server's op that consumes or pays runs once, also when its level moves to another map server:
//   a map server     srv.journal_done(origin, seq, answer) -> a Done entry of its level journal, after the facts of the op's effect,
//                    in the same batch (srv/coop_srv_script.cpp l_journal_done, srv/coop_levels_xfer.cpp journal_done);
//   the world        the journal receiver keeps {origin, seq, answer} per level, bounded, the first answer standing, and raises
//                    coop_op_done(origin, seq, answer) for each new one (host_on_level_journal -> host_take_done);
//   a new map server its snapshot (the world save it is served) carries the store as a chunk of the ALife save; it raises
//                    coop_op_done for each record of its level on its first frame, before it says Ready.
// The rules are pure (xrCoop/srv/coop_levels_journal.h journal::done); the engine's glue is read from its source.
// Coop: none of this runs (no journal, no map server); the last test reads that the co-op's code names none of it.
#include "test_util.h"

#include "srv/coop_levels_journal.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

using namespace coop;
using namespace coop::levels;
namespace jd = coop::levels::journal::done;
using Head = wire::LevelEntityHead;

namespace
{
constexpr uint16_t kCordon = 1;
constexpr uint16_t kMarsh = 2;

std::string answer_of(size_t n, char c = 'a') { return std::string(n, c); }

// ---------------------------------------------------------------- the engine's source (comments blanked, string literals kept)

std::string wp11_engine_src()
{
	return (std::filesystem::path(__FILE__).parent_path().parent_path() / "engine/src").string();
}

std::string wp11_root()
{
	return std::filesystem::path(__FILE__).parent_path().parent_path().string();
}

std::string wp11_read(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// // and /* */ comments blanked, string literals kept (so a callback's name can be read)
std::string wp11_code(const std::string& src)
{
	std::string out = src;
	bool line = false, block = false, str = false, chr = false;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		if (chr)
		{
			if (c == '\\')
				++i;
			else if (c == '\'')
				chr = false;
		}
		else if (line)
		{
			if (c == '\n')
				line = false;
			else
				out[i] = ' ';
		}
		else if (block)
		{
			if (c == '*' && n == '/')
			{
				out[i] = out[i + 1] = ' ';
				++i;
				block = false;
			}
			else if (c != '\n')
				out[i] = ' ';
		}
		else if (str)
		{
			if (c == '\\')
				++i;
			else if (c == '"')
				str = false;
		}
		else if (c == '/' && n == '/')
		{
			line = true;
			out[i] = out[i + 1] = ' ';
			++i;
		}
		else if (c == '/' && n == '*')
		{
			block = true;
			out[i] = out[i + 1] = ' ';
			++i;
		}
		else if (c == '"')
			str = true;
		else if (c == '\'')
			chr = true; // a char literal: '"' must not open a string
	}
	return out;
}

// The body of the first definition `type name(...) {`, "" when there is none.
std::string wp11_body(const std::string& code, const std::string& type, const std::string& name)
{
	std::smatch m;
	const std::regex rx(R"(\b)" + type + R"(\s+)" + name + R"(\s*\([^;{}]*\)\s*\{)");
	if (!std::regex_search(code, m, rx))
		return "";
	const size_t start = size_t(m.position() + m.length());
	int depth = 1;
	for (size_t i = start; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return code.substr(start, i - start);
	}
	return "";
}

bool wp11_has(const std::string& body, std::string_view what) { return body.find(what) != std::string::npos; }

bool wp11_before(const std::string& body, std::string_view first, std::string_view second)
{
	const size_t at = body.find(second);
	return at != std::string::npos && body.find(first) < at;
}
} // namespace

// ---------------------------------------------------------------- the rules

TEST(srv_ops_done_valid)
{
	// an op's number as coop_ops_done.script makes it: a character's world id (0 .. 65534) and a sequence from 1
	CHECK(jd::valid(0, 1, 0));
	CHECK(jd::valid(65534, 0xffffffffu, jd::kMaxAnswer));
	CHECK(!jd::valid(65535, 1, 0));
	CHECK(!jd::valid(0xffffffffu, 1, 0));
	CHECK(!jd::valid(500, 0, 10));
	// the answer goes to Lua in one callback argument (script::kMaxCallbackStr, 4096 bytes): a longer one is no record
	static_assert(jd::kMaxAnswer == 4096, "the engine's callback argument limit (coop_script.h kMaxCallbackStr)");
	CHECK(!jd::valid(500, 7, jd::kMaxAnswer + 1));
	// and it fits the journal's Done body whole
	static_assert(jd::kMaxAnswer <= journal::DoneBody::kMaxAnswer, "a record fits a Done entry");
}

TEST(srv_ops_done_first_answer_stands)
{
	jd::Store s;
	CHECK(s.empty());
	CHECK(s.put(kCordon, 500, 7, "{ok=true}") == jd::Put::Kept);
	CHECK(s.put(kCordon, 500, 7, "{ok=false}") == jd::Put::Repeat); // a retry's answer, a batch sent again: the first stands
	const jd::Record* r = s.find(kCordon, 500, 7);
	REQUIRE(r != nullptr);
	CHECK_EQ(r->answer, std::string("{ok=true}"));
	CHECK_EQ(s.count(kCordon), size_t(1));
	// another op of the same character, the same op number on another level: their own records
	CHECK(s.put(kCordon, 500, 8, "b") == jd::Put::Kept);
	CHECK(s.put(kCordon, 501, 7, "c") == jd::Put::Kept);
	CHECK(s.put(kMarsh, 500, 7, "d") == jd::Put::Kept);
	CHECK_EQ(s.count(kCordon), size_t(3));
	CHECK_EQ(s.count(kMarsh), size_t(1));
	CHECK_EQ(s.levels(), size_t(2));
	CHECK_EQ(s.find(kMarsh, 500, 7)->answer, std::string("d"));
	// what a level gives, in the order the world kept it
	const std::vector<jd::Record> cordon = s.of(kCordon);
	REQUIRE(cordon.size() == 3);
	CHECK(cordon[0].origin == 500 && cordon[0].seq == 7 && cordon[0].answer == "{ok=true}");
	CHECK(cordon[1].origin == 500 && cordon[1].seq == 8);
	CHECK(cordon[2].origin == 501 && cordon[2].seq == 7);
	CHECK(s.of(77).empty());
	// what is no record: refused, nothing kept
	CHECK(s.put(kCordon, 500, 0, "x") == jd::Put::Refused);
	CHECK(s.put(kCordon, 65535, 9, "x") == jd::Put::Refused);
	CHECK(s.put(kCordon, 500, 9, answer_of(jd::kMaxAnswer + 1)) == jd::Put::Refused);
	CHECK(s.put(wire::kNoLevel, 500, 9, "x") == jd::Put::Refused); // a bridge no level names
	CHECK_EQ(s.count(kCordon), size_t(3));
	// an empty answer is an answer
	CHECK(s.put(kCordon, 502, 1, "") == jd::Put::Kept);
	s.clear();
	CHECK(s.empty() && s.levels() == 0 && s.count(kCordon) == 0);
}

TEST(srv_ops_done_store_is_bounded)
{
	// by count: the oldest record of the level goes first; the other levels keep theirs
	{
		jd::Store s;
		CHECK(s.put(kMarsh, 900, 1, "m") == jd::Put::Kept);
		for (uint32_t i = 1; i <= uint32_t(jd::kMaxPerLevel) + 10; ++i)
			CHECK(s.put(kCordon, 500, i, "a") == jd::Put::Kept);
		CHECK_EQ(s.count(kCordon), jd::kMaxPerLevel);
		CHECK(s.find(kCordon, 500, 10) == nullptr);
		CHECK(s.find(kCordon, 500, 11) != nullptr);
		CHECK(s.find(kCordon, 500, uint32_t(jd::kMaxPerLevel) + 10) != nullptr);
		CHECK_EQ(s.evicted(), uint32_t(10));
		CHECK(s.find(kMarsh, 900, 1) != nullptr);
		CHECK(s.of(kCordon).front().seq == 11);
	}
	// by bytes: the answers of a level stay under kMaxBytesPerLevel
	{
		jd::Store s;
		const size_t n = jd::kMaxBytesPerLevel / jd::kMaxAnswer;
		for (uint32_t i = 1; i <= uint32_t(n) + 3; ++i)
			CHECK(s.put(kCordon, 500, i, answer_of(jd::kMaxAnswer)) == jd::Put::Kept);
		CHECK(s.bytes(kCordon) <= jd::kMaxBytesPerLevel);
		CHECK_EQ(s.count(kCordon), n);
		CHECK(s.find(kCordon, 500, 3) == nullptr);
		CHECK(s.find(kCordon, 500, uint32_t(n) + 3) != nullptr);
	}
	// by levels: a level past kMaxLevels is refused, the ones there keep their records
	{
		jd::Store s;
		for (uint16_t l = 0; l < uint16_t(jd::kMaxLevels); ++l)
			CHECK(s.put(l, 500, 1, "a") == jd::Put::Kept);
		CHECK(s.put(uint16_t(jd::kMaxLevels), 500, 1, "a") == jd::Put::Refused);
		CHECK(s.put(0, 500, 2, "b") == jd::Put::Kept);
		CHECK_EQ(s.levels(), jd::kMaxLevels);
	}
}

TEST(srv_ops_done_snapshot_carries_the_records)
{
	jd::Store s;
	CHECK(s.put(kCordon, 500, 7, "{o=\"1:0:7\",ok=true}") == jd::Put::Kept);
	CHECK(s.put(kCordon, 500, 8, "") == jd::Put::Kept);
	CHECK(s.put(kMarsh, 501, 4000000000u, answer_of(jd::kMaxAnswer, 'z')) == jd::Put::Kept);
	Writer w;
	s.write(w);
	CHECK(w.size() <= jd::kMaxSnapshotBytes);
	// a new map server of the Cordon reads the world's snapshot: every record of its level, in order, with its first answer
	jd::Store back;
	Reader r(w.ptr(), w.size());
	REQUIRE(back.read(r));
	CHECK(r.remaining() == 0);
	const std::vector<jd::Record> cordon = back.of(kCordon);
	REQUIRE(cordon.size() == 2);
	CHECK(cordon[0].origin == 500 && cordon[0].seq == 7 && cordon[0].answer == "{o=\"1:0:7\",ok=true}");
	CHECK(cordon[1].origin == 500 && cordon[1].seq == 8 && cordon[1].answer.empty());
	REQUIRE(back.find(kMarsh, 501, 4000000000u) != nullptr);
	CHECK_EQ(back.find(kMarsh, 501, 4000000000u)->answer, answer_of(jd::kMaxAnswer, 'z'));
	// the read store is the world's again: the first answer still stands
	CHECK(back.put(kCordon, 500, 7, "late") == jd::Put::Repeat);
	// an empty store is a snapshot too
	{
		jd::Store none;
		Writer e;
		none.write(e);
		jd::Store got;
		CHECK(got.put(kCordon, 1, 1, "old") == jd::Put::Kept);
		Reader er(e.ptr(), e.size());
		REQUIRE(got.read(er));
		CHECK(got.empty()); // what was there before goes: the snapshot is the whole store
	}
	// a damaged snapshot is refused whole and changes nothing
	const auto refused = [&](const std::vector<uint8_t>& bytes)
	{
		jd::Store got;
		CHECK(got.put(kCordon, 1, 1, "kept") == jd::Put::Kept);
		Reader br(bytes.data(), bytes.size());
		const bool ok = got.read(br);
		CHECK(got.count(kCordon) == 1 && got.find(kCordon, 1, 1) != nullptr);
		return !ok;
	};
	std::vector<uint8_t> cut(w.data().begin(), w.data().end() - 3);
	CHECK(refused(cut));
	std::vector<uint8_t> version = w.data();
	version[0] = 9; // a version this build does not read
	CHECK(refused(version));
	{
		Writer bad; // a record with seq 0
		bad.u32(jd::kVersion);
		bad.u16(1);
		bad.u16(kCordon);
		bad.u16(1);
		bad.u32(500);
		bad.u32(0);
		bad.str("x");
		CHECK(refused(bad.data()));
	}
	{
		Writer bad; // a level counted twice
		bad.u32(jd::kVersion);
		bad.u16(2);
		for (int i = 0; i < 2; ++i)
		{
			bad.u16(kCordon);
			bad.u16(1);
			bad.u32(500);
			bad.u32(uint32_t(i + 1));
			bad.str("x");
		}
		CHECK(refused(bad.data()));
	}
	{
		Writer bad; // more records than a level keeps
		bad.u32(jd::kVersion);
		bad.u16(1);
		bad.u16(kCordon);
		bad.u16(uint16_t(jd::kMaxPerLevel + 1));
		for (uint32_t i = 1; i <= uint32_t(jd::kMaxPerLevel) + 1; ++i)
		{
			bad.u32(500);
			bad.u32(i);
			bad.str("x");
		}
		CHECK(refused(bad.data()));
	}
	{
		Writer bad; // an answer over the limit
		bad.u32(jd::kVersion);
		bad.u16(1);
		bad.u16(kCordon);
		bad.u16(1);
		bad.u32(500);
		bad.u32(1);
		bad.str(answer_of(jd::kMaxAnswer + 1));
		CHECK(refused(bad.data()));
	}
	{
		std::vector<uint8_t> tail = w.data(); // bytes after the last level
		tail.push_back(0);
		CHECK(refused(tail));
	}
}

// ---------------------------------------------------------------- the save loaded, taken once (FE1: the load and adopt rules are pure)

namespace
{
using Took = jd::Loaded::Took;

// the world's store with records of two levels, and its snapshot (the kDoneChunk of the world's save)
std::vector<uint8_t> fe1_snapshot()
{
	jd::Store s;
	s.put(kCordon, 500, 7, "{ok=true}");
	s.put(kMarsh, 501, 3, "m");
	s.put(kCordon, 500, 8, "");
	s.put(kCordon, 502, 1, std::string("a\0b", 3)); // an answer may hold any byte
	Writer w;
	s.write(w);
	return w.data();
}

void fe1_load(jd::Loaded& l, bool reads, const std::vector<uint8_t>& chunk)
{
	l.load(reads, chunk.empty() ? nullptr : chunk.data(), chunk.size());
}
} // namespace

TEST(srv_ops_done_who_loads_the_records)
{
	// the world server (-coop_dedicated) takes its save's records as its store, a map server raises its level's; a co-op process (no
	// journal, no map server) and a player's machine never look for them
	CHECK(jd::loads_records(true, false));
	CHECK(jd::loads_records(false, true));
	CHECK(jd::loads_records(true, true));
	CHECK(!jd::loads_records(false, false));
}

TEST(srv_ops_done_world_server_adopts_its_save)
{
	const std::vector<uint8_t> snap = fe1_snapshot();
	// the world server loads a save with records: its live store becomes the save's, what it held before goes (a load is a world of
	// its own)
	{
		jd::Loaded l;
		CHECK(!l.pending());
		fe1_load(l, jd::loads_records(true, false), snap);
		CHECK(l.pending());
		CHECK_EQ(l.bytes(), snap.size());
		jd::Store live;
		CHECK(live.put(77, 9, 9, "of the world before the load") == jd::Put::Kept);
		CHECK(l.adopt(live) == Took::Taken);
		CHECK(!l.pending());
		CHECK(live.find(77, 9, 9) == nullptr);
		const std::vector<jd::Record> cordon = live.of(kCordon);
		REQUIRE(cordon.size() == 3);
		CHECK(cordon[0].origin == 500 && cordon[0].seq == 7 && cordon[0].answer == "{ok=true}");
		CHECK(cordon[1].origin == 500 && cordon[1].seq == 8 && cordon[1].answer.empty());
		CHECK(cordon[2].origin == 502 && cordon[2].seq == 1 && cordon[2].answer == std::string("a\0b", 3));
		REQUIRE(live.find(kMarsh, 501, 3) != nullptr);
		CHECK(live.put(kCordon, 500, 7, "late") == jd::Put::Repeat); // the save's first answer still stands
		// taken once: the next frames find nothing pending and leave the live store (and what came since) alone
		CHECK(live.put(kMarsh, 501, 4, "came since") == jd::Put::Kept);
		CHECK(l.adopt(live) == Took::Nothing);
		CHECK(live.find(kMarsh, 501, 4) != nullptr);
		CHECK_EQ(live.count(kCordon), size_t(3));
	}
	// a save with no records (an older save, a world that never had one): an empty store
	{
		jd::Loaded l;
		fe1_load(l, true, {});
		CHECK(l.pending());
		jd::Store live;
		CHECK(live.put(kCordon, 1, 1, "old") == jd::Put::Kept);
		CHECK(l.adopt(live) == Took::Taken);
		CHECK(live.empty());
	}
	// records that do not read (cut, another version): none kept, and it is said
	{
		jd::Loaded l;
		fe1_load(l, true, std::vector<uint8_t>(snap.begin(), snap.end() - 2));
		jd::Store live;
		CHECK(live.put(kCordon, 1, 1, "old") == jd::Put::Kept);
		CHECK(l.adopt(live) == Took::Unreadable);
		CHECK(live.empty());
		CHECK(!l.pending());
	}
	// a chunk past the largest snapshot, a chunk cut short by the file: not read, none kept
	{
		jd::Loaded l;
		const std::vector<uint8_t> big(jd::kMaxSnapshotBytes + 1, 0);
		l.load(true, big.data(), big.size());
		CHECK(l.pending());
		CHECK_EQ(l.bytes(), big.size()); // the chunk's size, for the log line that says it does not read
		jd::Store live;
		CHECK(l.adopt(live) == Took::Unreadable);
		CHECK(live.empty());
		l.load(true, nullptr, 40);
		CHECK(l.adopt(live) == Took::Unreadable);
	}
	// a second load replaces the first one not yet taken
	{
		jd::Loaded l;
		fe1_load(l, true, snap);
		fe1_load(l, true, {});
		jd::Store live;
		CHECK(l.adopt(live) == Took::Taken);
		CHECK(live.empty());
	}
}

TEST(srv_ops_done_map_server_replays_its_level)
{
	const std::vector<uint8_t> snap = fe1_snapshot();
	// a starting map server of the Cordon: every record of its level in the save it was served, in the order the world kept them
	{
		jd::Loaded l;
		fe1_load(l, jd::loads_records(false, true), snap);
		std::vector<jd::Record> got{jd::Record{1, 1, "stale"}};
		CHECK(l.replay(kCordon, got) == Took::Taken);
		REQUIRE(got.size() == 3);
		CHECK(got[0].origin == 500 && got[0].seq == 7 && got[0].answer == "{ok=true}");
		CHECK(got[1].origin == 500 && got[1].seq == 8);
		CHECK(got[2].origin == 502 && got[2].seq == 1 && got[2].answer == std::string("a\0b", 3));
		// once per world load: its next frames raise nothing again
		CHECK(l.replay(kCordon, got) == Took::Nothing);
		CHECK(got.empty());
	}
	// the Marsh's map server gets the Marsh's record only; a level with no record gets none
	{
		jd::Loaded l;
		fe1_load(l, true, snap);
		std::vector<jd::Record> got;
		CHECK(l.replay(kMarsh, got) == Took::Taken);
		REQUIRE(got.size() == 1);
		CHECK(got[0].origin == 501 && got[0].seq == 3 && got[0].answer == "m");
		fe1_load(l, true, snap);
		CHECK(l.replay(77, got) == Took::Taken);
		CHECK(got.empty());
	}
	// a save with none, a damaged one
	{
		jd::Loaded l;
		std::vector<jd::Record> got;
		fe1_load(l, true, {});
		CHECK(l.replay(kCordon, got) == Took::Taken);
		CHECK(got.empty());
		std::vector<uint8_t> version = snap;
		version[0] = 9;
		fe1_load(l, true, version);
		CHECK(l.replay(kCordon, got) == Took::Unreadable);
		CHECK(got.empty());
	}
}

TEST(srv_ops_done_coop_process_loads_nothing)
{
	// Coop: the host's process is neither the world server nor a map server; a save that holds the chunk (a server world opened in
	// the co-op) gives it nothing, and its store and frames stay as they are
	const std::vector<uint8_t> snap = fe1_snapshot();
	jd::Loaded l;
	fe1_load(l, jd::loads_records(false, false), snap);
	CHECK(!l.pending());
	CHECK_EQ(l.bytes(), size_t(0));
	jd::Store live;
	CHECK(live.put(kCordon, 1, 1, "untouched") == jd::Put::Kept);
	CHECK(l.adopt(live) == Took::Nothing);
	CHECK(live.find(kCordon, 1, 1) != nullptr);
	std::vector<jd::Record> got;
	CHECK(l.replay(kCordon, got) == Took::Nothing);
	CHECK(got.empty());
}

// ---------------------------------------------------------------- the engine's glue (its source is read)

TEST(srv_ops_done_map_server_journals_the_record)
{
	const std::string src = wp11_engine_src();
	// the Lua binding: a map server only, the number checked, the journal's answer returned
	const std::string script = wp11_code(wp11_read(src + "/xrGame/coop/srv/coop_srv_script.cpp"));
	REQUIRE(!script.empty());
	const std::string binding = wp11_body(script, "int", "l_journal_done");
	REQUIRE(!binding.empty());
	CHECK(wp11_has(binding, "is_map_server()"));
	CHECK(wp11_has(binding, "levels::journal_done("));
	CHECK(wp11_has(binding, "lua_pushboolean(L, "));
	CHECK(wp11_has(script, "{\"journal_done\", &l_journal_done}"));
	// the journal: after the facts of the effect queued so far (g.up), in the same flush, as the frame's batch
	const std::string xfer = wp11_code(wp11_read(src + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	REQUIRE(!xfer.empty());
	const std::string done = wp11_body(xfer, "bool", "journal_done");
	REQUIRE(!done.empty());
	CHECK(wp11_before(done, "is_map_server()", "g.up.push_back("));
	CHECK(wp11_before(done, "journal::done::valid(", "g.up.push_back("));
	CHECK(wp11_before(done, "holder_writes()", "g.up.push_back("));
	CHECK(wp11_before(done, "g.logic_over", "g.up.push_back(")); // the hand-over is over: nothing more goes up
	CHECK(wp11_has(done, "LevelEntityHead::Done"));
	CHECK(!wp11_has(done, "g.batch.add(")); // never ahead of the facts its hooks queued
	const std::string flush = wp11_body(xfer, "void", "client_flush_up");
	CHECK(wp11_has(flush, "case Head::Done:"));
	CHECK(wp11_has(flush, "journal_body(Head::Done, "));
	// declared for the binding in the server's header
	const std::string header = wp11_code(wp11_read(src + "/xrGame/coop/srv/coop_levels_alife.h"));
	CHECK(std::regex_search(header, std::regex(R"(bool\s+journal_done\s*\(\s*uint32_t\s+origin\s*,\s*uint32_t\s+seq\s*,\s*const\s+std::string\s*&\s*answer\s*\)\s*;)")));
}

TEST(srv_ops_done_world_keeps_and_raises)
{
	const std::string xfer = wp11_code(wp11_read(wp11_engine_src() + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	REQUIRE(!xfer.empty());
	// the receiver dispatches Done (host_apply_fact refuses it: A15) to the store
	const std::string journal = wp11_body(xfer, "void", "host_on_level_journal");
	const size_t at = journal.find("case Head::Done:");
	REQUIRE(at != std::string::npos);
	const std::string done_case = journal.substr(at, journal.find("continue;", at) - at);
	CHECK(wp11_has(done_case, "host_take_done(from, e, m.seq, refusals)"));
	const std::string take = wp11_body(xfer, "void", "host_take_done");
	REQUIRE(!take.empty());
	CHECK(wp11_has(take, "mapserver::level_of_bridge(from)"));
	CHECK(wp11_before(take, "g.done.put(", "queue_callback(\"coop_op_done\""));
	CHECK(wp11_has(take, "jd::Put::Kept"));
	CHECK(wp11_has(take, "journal::Refused")); // a record the store refuses is answered in the Ack
	CHECK(wp11_has(take, "g.done_at[level] = mgr().now_ms()"));
	// the answer fits one callback argument
	CHECK(std::regex_search(xfer, std::regex(R"(static_assert\s*\(\s*journal::done::kMaxAnswer\s*<=\s*script::kMaxCallbackStr)")));
	// a held save older than a level's last record is not served to that level's next map server (serve_bridge asks logic_came_since)
	CHECK(wp11_has(wp11_body(xfer, "bool", "logic_came_since"), "g.done_at"));
	// the store is in the world's save (the snapshot a map server is served) and back from it
	CHECK(wp11_has(wp11_body(xfer, "void", "xfer_save"), "kDoneChunk"));
	CHECK(wp11_has(wp11_body(xfer, "void", "xfer_host_frame"), "host_adopt_done()"));
	CHECK(wp11_has(xfer, "g.done.clear()")); // a new session or world starts with the store of its save
}

// FE1 (verifier of E1): the load and the adoption are pinned by what they do (journal::done::loads_records and Loaded, tested above),
// and here by the glue handing them the process's role, the save's chunk and the live store, with no way around them.
TEST(srv_ops_done_glue_loads_and_adopts_the_save)
{
	const std::string xfer = wp11_code(wp11_read(wp11_engine_src() + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	REQUIRE(!xfer.empty());
	// xfer_load: the world server and a map server read the chunk, nobody else; whatever the save holds goes to the pending load,
	// before the transfers' journal (whose missing chunk ends the function)
	const std::string load = wp11_body(xfer, "void", "xfer_load");
	REQUIRE(!load.empty());
	std::smatch m;
	CHECK(std::regex_search(load, m,
	    std::regex(R"(const\s+bool\s+reads\s*=\s*journal::done::loads_records\(\s*dedicated::on\(\)\s*,\s*is_map_server\(\)\s*\)\s*;)")));
	CHECK(std::regex_search(load, std::regex(R"(=\s*reads\s*\?\s*in\.find_chunk\(\s*kDoneChunk\s*\)\s*:\s*0\s*;)")));
	CHECK(load.find("find_chunk(kDoneChunk)") == load.rfind("find_chunk(kDoneChunk)")); // looked for once, under `reads`
	CHECK(std::regex_search(load, std::regex(R"(g\.done_loaded\.load\(\s*reads\s*,)")));
	CHECK(wp11_before(load, "g.done_loaded.load(", "find_chunk(kJournalChunk)"));
	CHECK(wp11_before(load, "journal::done::loads_records(", "g.done_loaded.load("));
	CHECK(!wp11_has(load, "if (false") && !wp11_has(load, "false &&") && !wp11_has(load, "&& false"));
	// host_adopt_done: the pending load becomes the live store (Loaded::adopt: the store cleared, then the save's read whole), nothing
	// returns ahead of it; the levels' marks go with the store it replaced
	const std::string adopt = wp11_body(xfer, "void", "host_adopt_done");
	REQUIRE(!adopt.empty());
	CHECK(wp11_has(adopt, "g.done_loaded.adopt(g.done)"));
	CHECK(!wp11_before(adopt, "return", "g.done_loaded.adopt(g.done)"));
	CHECK(wp11_before(adopt, "g.done_loaded.adopt(g.done)", "g.done_at.clear()"));
	// it runs on the world server's frame, once its world is up
	const std::string host_frame = wp11_body(xfer, "void", "xfer_host_frame");
	CHECK(wp11_before(host_frame, "ai().get_alife()", "host_adopt_done();"));
	CHECK(wp11_before(host_frame, "host_adopt_done();", "g.keeper.resume("));
	// a new session or world does not lose the load not yet taken (xfer_reset clears the live store only)
	CHECK(!wp11_has(wp11_body(xfer, "void", "xfer_reset"), "g.done_loaded"));
}

TEST(srv_ops_done_new_map_server_raises_before_it_serves)
{
	const std::string xfer = wp11_code(wp11_read(wp11_engine_src() + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	REQUIRE(!xfer.empty());
	const std::string frame = wp11_body(xfer, "void", "xfer_client_frame");
	// the first frame of its world (the holder made for it), before the frame's facts and transfers; levels::frame runs it before
	// mapserver::server_frame, which says Ready
	CHECK(wp11_before(frame, "client_remember_held();", "client_replay_done();"));
	CHECK(wp11_before(frame, "client_replay_done();", "client_flush_up();"));
	const std::string replay = wp11_body(xfer, "void", "client_replay_done");
	REQUIRE(!replay.empty());
	// FE1: its own level's records of the pending load (Loaded::replay, tested above), every one raised
	std::smatch m;
	REQUIRE(std::regex_search(replay, m, std::regex(R"(const\s+LevelId\s+(\w+)\s*=\s*mapserver::key\(\)\.level\s*;)")));
	const std::string level = m[1].str();
	REQUIRE(std::regex_search(replay, m, std::regex(R"(g\.done_loaded\.replay\(\s*)" + level + R"(\s*,\s*(\w+)\s*\))")));
	const std::string records = m[1].str();
	CHECK(wp11_before(replay, "is_map_server()", "g.done_loaded.replay("));
	REQUIRE(std::regex_search(replay, m, std::regex(R"(for\s*\(\s*const\s+journal::done::Record\s*&\s*(\w+)\s*:\s*)" + records + R"(\s*\))")));
	const std::string rec = m[1].str();
	CHECK(wp11_before(replay, "g.done_loaded.replay(", "queue_callback(\"coop_op_done\""));
	CHECK(std::regex_search(replay, std::regex(R"(queue_callback\("coop_op_done",\s*\{\s*script::cb_int\(s64\()" + rec + R"(\.origin\)\),\s*script::cb_int\(s64\()" +
	                                    rec + R"(\.seq\)\),\s*answer\s*\}\))")));
	CHECK(wp11_has(replay, "answer.s = " + rec + ".answer;"));
	const std::string levels = wp11_code(wp11_read(wp11_engine_src() + "/xrGame/coop/coop_levels.cpp"));
	CHECK(wp11_before(wp11_body(levels, "void", "frame"), "xfer_client_frame();", "mapserver::server_frame();"));
}

TEST(srv_ops_done_coop_stays_inert)
{
	// the co-op's code names none of it: no binding, no callback, no journal
	const std::string root = wp11_root();
	for (const char* rel : {"engine/src/xrGame/coop/hostplay", "gamedata/scripts"})
		for (const auto& f : std::filesystem::directory_iterator(root + "/" + rel))
		{
			const std::string name = f.path().filename().string();
			const bool hostplay = std::string(rel).find("hostplay") != std::string::npos || name.rfind("coop_hostplay_", 0) == 0;
			if (!hostplay || !f.is_regular_file())
				continue;
			const std::string text = wp11_read(f.path().string());
			CHECK(!wp11_has(text, "journal_done"));
			CHECK(!wp11_has(text, "coop_op_done"));
		}
	// the Core's engine files never call the map server's journal
	for (const auto& f : std::filesystem::directory_iterator(wp11_engine_src() + "/xrGame/coop"))
		if (f.is_regular_file())
			CHECK(!wp11_has(wp11_code(wp11_read(f.path().string())), "journal_done("));
	// the Lua callback is declared and taken only in the server's layer, once that layer answers (coop_mode.when_srv)
	const std::string srv_mode = wp11_read(wp11_root() + "/gamedata/scripts/coop_srv_mode.script");
	CHECK(wp11_before(srv_mode, "coop_mode.when_srv(function()", "RegisterScriptCallback(\"coop_op_done\""));
	// the world's receiver runs in a world server's session only; the map server's replay on a map server's frame only
	const std::string xfer = wp11_code(wp11_read(wp11_engine_src() + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	CHECK(wp11_has(wp11_body(xfer, "void", "client_replay_done"), "is_map_server()"));
	CHECK(wp11_has(wp11_body(xfer, "void", "host_on_level_journal"), "mgr().is_host()"));
}
