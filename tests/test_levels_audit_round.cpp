// Server-only ownership audit: a round is proved by one full book from each challenged bridge.
#include "test_util.h"

#include "coop_levels_wire.h"
#include "coop_world_gate.h"
#include "srv/coop_levels_audit.h"
#include "srv/coop_session_srv.h"

#include <filesystem>
#include <fstream>
#include <regex>
#include <string_view>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
constexpr PeerId kA = mapserver::bridge_peer(1);
constexpr PeerId kB = mapserver::bridge_peer(2);
constexpr uint32_t kFull = xfer::kAllBuckets;

struct AuditLog
{
	std::vector<std::string> lines;

	template <class... Args>
	void operator()(const char* format, Args... args)
	{
		char line[128];
		std::snprintf(line, sizeof(line), format, args...);
		lines.emplace_back(line);
	}
};

// The audited hooks live in xrGame, which the native test binary does not link.
std::string_view function_body(const std::string& code, const char* name)
{
	std::smatch match;
	const std::regex definition(std::string(R"(\bvoid\s+)") + name + R"(\s*\([^;{}]*\)\s*\{)");
	if (!std::regex_search(code, match, definition))
		return {};

	const size_t start = static_cast<size_t>(match.position() + match.length());
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

bool appears_before(std::string_view body, std::string_view first, std::string_view second)
{
	const size_t second_pos = body.find(second);
	return second_pos != std::string_view::npos && body.find(first) < second_pos;
}
} // namespace

TEST(levels_audit_round_logs_begin_and_one_ack_per_bridge)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	CHECK_EQ(round, 1u);
	REQUIRE(log.lines.size() == 1);
	CHECK_EQ(log.lines.front(), "[coop] levels audit begin round=1 bridges=2");
	CHECK(audit.reply(round, kB, kFull, log));
	CHECK(audit.reply(round, kA, kFull, log));
	REQUIRE(log.lines.size() == 3);
	CHECK_EQ(log.lines[1], "[coop] levels audit ack round=1 peer=258 mask=ffffffff");
	CHECK_EQ(log.lines[2], "[coop] levels audit ack round=1 peer=257 mask=ffffffff");
}

TEST(levels_audit_round_refuses_late_replies_from_a_previous_round)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t old = audit.begin({kA, kB}, log);
	CHECK(audit.reply(old, kA, kFull, log));
	const uint32_t current = audit.begin({kA, kB}, log);
	CHECK_EQ(current, 2u);
	CHECK_EQ(log.lines.back(), "[coop] levels audit begin round=2 bridges=2");
	CHECK(!audit.reply(old, kA, kFull, log)); // late duplicate
	CHECK(!audit.reply(old, kB, kFull, log)); // first reply, but round superseded
	REQUIRE(log.lines.size() == 5);
	CHECK_EQ(log.lines[3], "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	CHECK_EQ(log.lines[4], "[coop] levels audit refused round=1 peer=258 mask=ffffffff total=2");
	CHECK(audit.reply(current, kB, kFull, log));
	CHECK(audit.reply(current, kA, kFull, log));
}

TEST(levels_audit_round_refuses_a_connection_that_was_not_challenged)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA}, log);
	CHECK(!audit.reply(round, kB, kFull, log));
	REQUIRE(log.lines.size() == 2);
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=1 peer=258 mask=ffffffff total=1");
	CHECK(audit.reply(round, kA, kFull, log));
}

TEST(levels_audit_round_refuses_a_bridge_challenged_only_in_an_earlier_round)
{
	srv::LevelsAudit audit;
	AuditLog log;
	audit.begin({kA, kB}, log);
	const uint32_t current = audit.begin({kA}, log);
	CHECK(!audit.reply(current, kB, kFull, log));
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=2 peer=258 mask=ffffffff total=1");
	CHECK(audit.reply(current, kA, kFull, log));
}

TEST(levels_audit_round_refuses_duplicate_and_partial_replies_without_using_another_slot)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	CHECK(audit.reply(round, kA, kFull, log));
	CHECK(!audit.reply(round, kA, kFull, log));
	CHECK(!audit.reply(round, kB, 1u, log));
	REQUIRE(log.lines.size() == 4);
	CHECK_EQ(log.lines[2], "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	CHECK_EQ(log.lines[3], "[coop] levels audit refused round=1 peer=258 mask=00000001 total=2");
	CHECK(audit.reply(round, kB, kFull, log));
}

TEST(levels_audit_round_disconnect_and_reset_remove_pending_replies)
{
	srv::LevelsAudit audit;
	AuditLog log;
	const uint32_t round = audit.begin({kA, kB}, log);
	audit.disconnect(kA);
	CHECK(!audit.reply(round, kA, kFull, log)); // a new connection using the same slot
	CHECK(audit.reply(round, kB, kFull, log)); // the other bridge still owes its reply
	const uint32_t next = audit.begin({kA}, log);
	CHECK(audit.reply(next, kA, kFull, log)); // after its own new challenge
	const uint32_t before_reset = audit.begin({kA}, log);
	audit.clear();
	CHECK(!audit.reply(before_reset, kA, kFull, log));
	CHECK_EQ(audit.begin({}, log), before_reset + 1);
	CHECK_EQ(log.lines.back(), "[coop] levels audit begin round=4 bridges=0");
	CHECK(!audit.reply(before_reset + 1, kA, kFull, log));
}

TEST(levels_audit_round_wire_keeps_ids_senders_and_world_gate)
{
	static_assert(static_cast<uint16_t>(Msg::LevelResync) == 0x01DAu);
	static_assert(static_cast<uint16_t>(Msg::LevelEntity) == 0x01D5u);
	static_assert(static_cast<uint8_t>(LevelEntityHead::Report) == 6u);
	CHECK_EQ(msg_sender(Msg::LevelResync), MsgSender::HostOnly);
	CHECK_EQ(msg_sender(Msg::LevelEntity), MsgSender::TrunkOnly);
	CHECK_EQ(wgate::need_of(Msg::LevelResync), wgate::Need::Drop);
	CHECK_EQ(wgate::need_of(Msg::LevelEntity), wgate::Need::Hold);
}

TEST(levels_audit_round_wire_legacy_request_and_report_have_the_same_prefix)
{
	const uint32_t expected = 0xFEDCBA98u;
	LevelResyncMsg request;
	request.mask = kFull;
	Writer down;
	request.write(down);
	srv::write_audit_round(down, 0);
	CHECK_EQ(down.size(), size_t(4));
	Reader legacy_down(down.ptr(), down.size());
	LevelResyncMsg decoded_request;
	uint32_t round = expected;
	REQUIRE(decoded_request.read(legacy_down) && srv::read_audit_round(legacy_down, round));
	CHECK_EQ(round, 0u);
	srv::write_audit_round(down, expected);
	CHECK(down.data() == std::vector<uint8_t>({0xff, 0xff, 0xff, 0xff, 0x98, 0xba, 0xdc, 0xfe}));
	Reader extended_down(down.ptr(), down.size());
	REQUIRE(decoded_request.read(extended_down)); // the legacy reader can use the base message
	CHECK_EQ(decoded_request.mask, kFull);
	REQUIRE(srv::read_audit_round(extended_down, round));
	CHECK_EQ(round, expected);
	CHECK_EQ(extended_down.remaining(), size_t(0));

	LevelEntityHead head;
	head.op = LevelEntityHead::Report;
	LevelReportBody book;
	book.buckets = kFull;
	book.rows.push_back({9, 42});
	Writer up;
	head.write(up);
	REQUIRE(book.write(up));
	srv::write_audit_round(up, 0);
	CHECK_EQ(up.size(), size_t(13));
	Reader legacy_up(up.ptr(), up.size());
	LevelReportBody decoded_book;
	REQUIRE(head.read(legacy_up) && decoded_book.read(legacy_up) && srv::read_audit_round(legacy_up, round));
	CHECK_EQ(round, 0u);
	srv::write_audit_round(up, expected);
	CHECK_EQ(up.size(), size_t(17));
	Reader extended_up(up.ptr(), up.size());
	REQUIRE(head.read(extended_up) && decoded_book.read(extended_up)); // legacy readers use the same rows
	CHECK_EQ(head.op, LevelEntityHead::Report);
	CHECK_EQ(decoded_book.buckets, kFull);
	REQUIRE(decoded_book.rows.size() == 1);
	CHECK_EQ(decoded_book.rows[0].id, 9u);
	CHECK_EQ(decoded_book.rows[0].gen, 42u);
	REQUIRE(srv::read_audit_round(extended_up, round));
	CHECK_EQ(round, expected);
	CHECK_EQ(extended_up.remaining(), size_t(0));
}

TEST(levels_audit_round_wire_refuses_malformed_extensions)
{
	const uint8_t bytes[] = {1, 2, 3, 4, 5};
	for (const size_t size : {1u, 2u, 3u, 5u})
	{
		Reader bad(bytes, size);
		uint32_t round = 0;
		CHECK(!srv::read_audit_round(bad, round));
	}
	const uint8_t zero[4] = {};
	Reader bad(zero, sizeof(zero));
	uint32_t round = 0;
	CHECK(!srv::read_audit_round(bad, round));
}

TEST(levels_audit_round_transport_disconnect_clears_the_challenged_bridge_slot)
{
	constexpr uint16_t port = 39357;
	t::Node world("world", port), first("first", port), replacement("replacement", port);
	world.cfg.host_plays = false;
	srv::SessionSrv bridges(world.s);
	srv::LevelsAudit audit;
	AuditLog log;
	uint32_t left = 0;
	uint32_t replies = 0;
	bridges.on_bridge_left([&](PeerId from, const std::string&) {
		audit.disconnect(from);
		++left;
	});
	world.s.on(Msg::LevelEntity, [&](PeerId from, Reader& r) {
		LevelEntityHead head;
		LevelReportBody body;
		uint32_t round = 0;
		if (head.read(r) && head.op == LevelEntityHead::Report && body.read(r) && srv::read_audit_round(r, round) && round)
		{
			audit.reply(round, from, body.buckets, log);
			++replies;
		}
	});
	world.cfg.mode = SessionMode::Server;
	REQUIRE(world.host());
	const auto join_bridge = [&](t::Node& node, uint8_t token) {
		node.cfg.hello_role = kHelloRoleMapServer;
		node.cfg.hello_token.fill(token);
		bridges.issue_bridge(1, node.cfg.hello_token);
		return node.connect(port) && t::pump_until({&world.s, &node.s}, 5000, [&] { return node.welcomed; });
	};
	uint32_t heard_round = 0;
	const auto receive_request = [&](PeerId from, Reader& r) {
		LevelResyncMsg request;
		REQUIRE(from == kHostPeer && request.read(r) && request.mask == kFull);
		REQUIRE(srv::read_audit_round(r, heard_round));
	};
	first.s.on(Msg::LevelResync, receive_request);
	replacement.s.on(Msg::LevelResync, receive_request);
	const auto challenge = [&] {
		const uint32_t round = audit.begin(bridges.bridges(), log);
		LevelResyncMsg request;
		request.mask = kFull;
		Writer w;
		request.write(w);
		srv::write_audit_round(w, round);
		world.s.send(kA, Lane::Reliable, Msg::LevelResync, w);
		return round;
	};
	REQUIRE(join_bridge(first, 17));
	const uint32_t old = challenge();
	REQUIRE(t::pump_until({&world.s, &first.s}, 5000, [&] { return heard_round == old; }));
	// The old connection leaves without replying. A new transport can acquire the same peer ID.
	first.s.shutdown("audit test replacement");
	REQUIRE(t::pump_until({&world.s}, 5000, [&] { return left == 1; }));
	REQUIRE(join_bridge(replacement, 18));
	REQUIRE(replacement.s.self() == kA);
	const auto report = [&](uint32_t round) {
		LevelEntityHead head;
		head.op = LevelEntityHead::Report;
		LevelReportBody body;
		body.buckets = kFull;
		Writer w;
		head.write(w);
		REQUIRE(body.write(w));
		srv::write_audit_round(w, round);
		replacement.s.send(kHostPeer, Lane::Reliable, Msg::LevelEntity, w);
	};
	report(old);
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return replies == 1; }));
	CHECK_EQ(log.lines.back(), "[coop] levels audit refused round=1 peer=257 mask=ffffffff total=1");
	const uint32_t current = challenge();
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return heard_round == current; }));
	report(heard_round);
	REQUIRE(t::pump_until({&world.s, &replacement.s}, 5000, [&] { return replies == 2; }));
	CHECK_EQ(log.lines.back(), "[coop] levels audit ack round=2 peer=257 mask=ffffffff");
}

TEST(levels_audit_round_xfer_hooks)
{
	const auto path = std::filesystem::path(__FILE__).parent_path().parent_path()
	    / "engine/src/xrGame/coop/coop_levels_xfer.cpp";
	std::ifstream in(path, std::ios::binary);
	REQUIRE(in.is_open());
	std::ostringstream source;
	source << in.rdbuf();
	// Skip comments and literals so only code supplies braces and calls.
	const std::regex comments_and_literals(R"cpp(//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])')cpp");
	const std::string code = std::regex_replace(source.str(), comments_and_literals, " ");

	const auto reset = function_body(code, "xfer_reset");
	CHECK(reset.find("g.manual_audit.clear()") != std::string_view::npos);

	const auto disconnect = function_body(code, "xfer_host_disconnect");
	CHECK(appears_before(disconnect, "g.manual_audit.disconnect(peer)", "if (!g.keeper.connected(peer))"));

	const auto audit = function_body(code, "xfer_audit_now");
	CHECK(appears_before(audit, "g.manual_audit.begin(", "send_resync(bridge, xfer::kAllBuckets, round)"));

	const auto resync = function_body(code, "client_on_resync");
	CHECK(appears_before(resync, "srv::read_audit_round(r, round)", "srv::write_audit_round(w, round)"));

	const auto report = function_body(code, "host_on_report");
	CHECK(appears_before(report, "g.manual_audit.reply(round, from, m.buckets", "g.keeper.audit("));
}
