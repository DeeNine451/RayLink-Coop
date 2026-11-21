// Anomaly Coop unit tests: the close of the game log (xrCoop/coop_log_close.h, used by xrCore log.cpp). TZ R38 (RL-N8HP-7FDG,
// 2026-11-22): a normal quit ended with exit code 1 and a log that looked complete. After the close the logger dropped every line,
// so a failure in the end of the process (xrDebug::backend: TerminateProcess(1)) told nobody; and the log thread and the closing
// thread drained the queue at once, the later one able to pop an empty std::deque.
#include "test_util.h"

#include "coop_log_close.h"

#include <atomic>
#include <deque>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>

using namespace coop;

namespace
{
// A queue that counts a pop of an empty queue instead of the undefined behaviour of std::queue (MSVC's size wraps to SIZE_MAX).
struct CheckedQueue
{
	std::deque<int> items;
	int empty_pops = 0;
	bool empty() const { return items.empty(); }
	int& front() { return items.front(); }
	void pop()
	{
		if (items.empty())
		{
			++empty_pops;
			return;
		}
		items.pop_front();
	}
};
} // namespace

TEST(log_close_a_line_after_the_close_goes_into_the_file)
{
	CHECK(log_close::route(true) == log_close::Route::Queue);
	CHECK(log_close::route(false) == log_close::Route::Late); // was: dropped
}

TEST(log_close_a_late_line_has_no_time_stamp)
{
	CHECK(log_close::stamp(true, true));
	CHECK(!log_close::stamp(true, false)); // std::put_time after the CRT's exit faulted (the stand, 2026-11-22)
	CHECK(!log_close::stamp(false, true));
	CHECK(!log_close::stamp(false, false));
}

TEST(log_close_take_front_takes_one_record_and_never_pops_an_empty_queue)
{
	CheckedQueue q;
	int got = -1;
	CHECK(!log_close::take_front(q, got));
	CHECK_EQ(got, -1);
	CHECK_EQ(q.empty_pops, 0);
	q.items = {1, 2};
	CHECK(log_close::take_front(q, got));
	CHECK_EQ(got, 1);
	CHECK(log_close::take_front(q, got));
	CHECK_EQ(got, 2);
	CHECK(!log_close::take_front(q, got));
	CHECK_EQ(q.empty_pops, 0);
}

// The interleaving of the old drain, step by step: both drainers saw one record (empty() false under the lock), then each took the
// front and popped under a second hold. The later one popped an empty queue. take_front tests and pops in one hold.
TEST(log_close_the_old_two_step_drain_popped_an_empty_queue)
{
	CheckedQueue q;
	q.items = {7};
	const bool a_sees = !q.empty();
	const bool b_sees = !q.empty();
	CHECK(a_sees && b_sees);
	q.pop(); // the first drainer
	q.pop(); // the second one, on what it had seen
	CHECK_EQ(q.empty_pops, 1);

	CheckedQueue fixed;
	fixed.items = {7};
	int a = 0, b = 0;
	const bool took_a = log_close::take_front(fixed, a);
	const bool took_b = log_close::take_front(fixed, b);
	CHECK(took_a);
	CHECK(!took_b);
	CHECK_EQ(fixed.empty_pops, 0);
}

// Two drainers on one queue, as the log thread and the thread that closes the log: every record is taken exactly once.
TEST(log_close_two_drainers_take_every_record_once)
{
	constexpr int kRecords = 20000;
	std::mutex lock;
	CheckedQueue q;
	for (int i = 0; i < kRecords; ++i)
		q.items.push_back(i);
	std::vector<int> seen(kRecords, 0);
	std::atomic<int> taken{0};
	auto drain = [&] {
		for (;;)
		{
			int r = -1;
			{
				std::lock_guard<std::mutex> g(lock);
				if (!log_close::take_front(q, r))
					return;
			}
			++seen[size_t(r)];
			++taken;
		}
	};
	std::thread t1(drain), t2(drain);
	t1.join();
	t2.join();
	CHECK_EQ(taken.load(), kRecords);
	CHECK_EQ(q.empty_pops, 0);
	int once = 0;
	for (int n : seen)
		once += n == 1 ? 1 : 0;
	CHECK_EQ(once, kRecords);
}

TEST(log_close_take_front_works_on_the_loggers_queue_type)
{
	std::queue<std::string> q; // xr_queue is a std::queue
	q.push("refCount:m_pFactory 1");
	std::string line;
	CHECK(log_close::take_front(q, line));
	CHECK_EQ(line, std::string("refCount:m_pFactory 1"));
	CHECK(q.empty());
	CHECK(!log_close::take_front(q, line));
}

TEST(log_close_late_text_puts_crlf_lines_and_the_header_first)
{
	const std::string header = std::string(log_close::kLateHeader) + "\r\n";
	CHECK_EQ(log_close::late_text("one", true), header + "one\r\n");
	CHECK_EQ(log_close::late_text("one", false), std::string("one\r\n"));
	// a FATAL block of gather_info: its '\n' lines become the file's CRLF lines, a CRLF stays one
	CHECK_EQ(log_close::late_text("\nFATAL ERROR\n\n[error]Expression    : <no expression>\n", false),
	    std::string("\r\nFATAL ERROR\r\n\r\n[error]Expression    : <no expression>\r\n\r\n"));
	CHECK_EQ(log_close::late_text("a\r\nb", false), std::string("a\r\nb\r\n"));
	CHECK_EQ(log_close::late_text("", false), std::string("\r\n"));
	CHECK_EQ(log_close::late_text(nullptr, false), std::string("\r\n"));
}

// The launcher reads a FATAL from the log by a line that is exactly "FATAL ERROR" (rl-core reports/collect.rs is_fatal): a late
// FATAL keeps that line whole.
TEST(log_close_a_late_fatal_keeps_its_fatal_error_line)
{
	const std::string text = log_close::late_text("\nFATAL ERROR\n\n[error]Description   : pure virtual function call\n", true);
	CHECK(text.find("\r\nFATAL ERROR\r\n") != std::string::npos);
	CHECK(text.find("[error]Description   : pure virtual function call\r\n") != std::string::npos);
	CHECK_EQ(text.rfind(log_close::kLateHeader, 0), size_t(0));
}
