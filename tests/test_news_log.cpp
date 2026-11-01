// Anomaly Coop unit tests: a client's PDA log (xrCoop/coop_news_log.h).
// Live 2026-11-01: a client read the host's "You are hosting a co-op session" in the log of his PDA.
#include "test_util.h"

#include "coop_news_log.h"

#include <string>
#include <vector>

using namespace coop;

namespace
{
using Log = std::vector<std::string>;
}

TEST(news_log_a_client_does_not_get_the_hosts_log)
{
	Log own;
	Log actor{"You are hosting a co-op session.", "the host's deal"};
	news_log::on_actor_spawn(true, actor, own);
	CHECK(actor.empty());
}

TEST(news_log_a_client_keeps_his_lines_over_a_new_world)
{
	Log own;
	news_log::on_news(true, own, std::string("a stalker died"));
	news_log::on_news(true, own, std::string("my task"));
	Log actor{"You are hosting a co-op session."};
	news_log::on_actor_spawn(true, actor, own);
	CHECK(actor == (Log{"a stalker died", "my task"}));
}

TEST(news_log_the_host_keeps_what_the_save_has)
{
	Log own;
	news_log::on_news(false, own, std::string("not written down"));
	CHECK(own.empty());
	Log actor{"You are hosting a co-op session."};
	news_log::on_actor_spawn(false, actor, own);
	CHECK(actor == (Log{"You are hosting a co-op session."}));
}
