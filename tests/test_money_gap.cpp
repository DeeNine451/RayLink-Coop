// Anomaly Coop unit tests: a ReqMoney the host never saw (parity audit 2026-10-31, D11).
// A request the host's rate row drops gets no answer, and the next one that passes sets `acked` past it: the client then
// forgot the change as answered and the delta was gone with no refusal. The host now tells the client which seqs it never
// saw (a note in a balance that does not move `acked`) and the client sends those changes again under new seqs; its own
// sender goes by a Pacer, so an honest burst waits instead of being dropped at all.
#include "test_util.h"

#include "coop_ledger.h"
#include "coop_limits.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace coop;
using namespace coop::ledger;

namespace
{
std::string money_source()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/coop/coop_money.cpp", std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

TEST(money_gap_the_next_seq_is_no_gap)
{
	CHECK_EQ(seq_gap(5, 6), 0u);
}

TEST(money_gap_seqs_the_host_did_not_see)
{
	CHECK_EQ(seq_gap(5, 7), 1u);
	CHECK_EQ(seq_gap(5, 16), 10u);
}

TEST(money_gap_the_first_request_of_a_connection_says_nothing)
{
	CHECK_EQ(seq_gap(0, 900), 0u); // the seq lives as long as the process does
}

TEST(money_gap_a_repeat_is_no_gap)
{
	CHECK_EQ(seq_gap(5, 5), 0u);
	CHECK_EQ(seq_gap(5, 3), 0u);
}

TEST(money_gap_past_a_wrap)
{
	CHECK_EQ(seq_gap(0xFFFFFFFFu, 2u), 2u);
}

TEST(money_gap_of_a_world_that_was_replaced_is_not_asked_for)
{
	CHECK_EQ(seq_gap(5, 5 + kMaxGap + 2), 0u); // a client that was away: its old changes went with their world
}

TEST(money_gap_note_round_trip)
{
	MoneyBalanceMsg m;
	m.balance = 100;
	m.acked_seq = 5;
	m.note = note_gap(6, 3);
	Writer w(kMoneyBalanceSize);
	write(w, m);
	CHECK_EQ(w.size(), kMoneyBalanceSize);
	Reader r(w.ptr(), w.size());
	MoneyBalanceMsg back;
	CHECK(read(r, back));
	CHECK(back.note.kind == NoteKind::Gap);
	CHECK_EQ(back.note.peer, 6u);
	CHECK_EQ(back.note.amount, 3);
	CHECK_EQ(back.acked_seq, 5u);
}

TEST(money_gap_takes_the_skipped_changes_with_their_cause)
{
	std::vector<Pending> pending = {{5, -10, Cause::Script, 0}, {6, 20, Cause::Dialog, 0}, {7, -30, Cause::Transfer, 9},
	    {8, 40, Cause::Script, 0}};
	const std::vector<Pending> skipped = take_skipped(pending, 6, 2);
	CHECK_EQ(skipped.size(), size_t(2));
	CHECK_EQ(skipped[0].delta, 20);
	CHECK(skipped[0].cause == Cause::Dialog);
	CHECK_EQ(skipped[1].ref, 9u);
	CHECK_EQ(pending.size(), size_t(2));
	CHECK_EQ(pending[0].seq, 5u);
	CHECK_EQ(pending[1].seq, 8u);
}

TEST(money_gap_nothing_pending_nothing_taken)
{
	std::vector<Pending> pending;
	CHECK(take_skipped(pending, 6, 2).empty());
}

TEST(money_gap_a_negative_count_takes_nothing)
{
	std::vector<Pending> pending = {{6, 20, Cause::Script, 0}};
	CHECK(take_skipped(pending, 6, 0).empty());
	CHECK_EQ(pending.size(), size_t(1));
}

TEST(money_gap_the_client_goes_by_the_hosts_rate)
{
	const std::string src = money_source();
	const std::string body = between(src, "void client_flush(bool paced)", "\n}\n");
	CHECK(body.find("take(Msg::ReqMoney") != std::string::npos);
	CHECK(limits::client_rule(Msg::ReqMoney) != nullptr);
}

TEST(money_gap_the_host_tells_before_it_applies)
{
	const std::string src = money_source();
	const std::string body = between(src, "void host_on_req(PeerId from, Reader& r)", "\n}\n");
	const size_t gap = body.find("ledger::seq_gap");
	const size_t request = body.find("g_book.on_request");
	CHECK(gap != std::string::npos);
	CHECK(request != std::string::npos);
	CHECK(gap < request); // the note goes out while `acked` still stands before the hole
}
