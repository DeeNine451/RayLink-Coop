// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: vehicles for players, a player's machine (F5-VEH-3, docs/VEHICLES.md sections 5 and 7) - which keys of
// the stock car input are the decider's (read against CarInput.cpp and xr_level_controller.h), the VehicleInput stream (cadence,
// press counters, sequence, aim), the seat requests (one at a time, the answer timeout) and what a VehicleSeat means for the
// own actor (coop_vehicle_input_rules.h). One set of rules for both modes: the client code does not know who decides.
#include "test_util.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <string>

#include "coop_vehicle_input_rules.h"

namespace v = coop::vehicles;
namespace k = coop::vehicles::keys;

namespace
{
// anomaly-coop/<rel> (tests\ -> ..), without '\r'
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// The text without /* */ and // comments (string literals of the car input have none of the two).
std::string without_comments(const std::string& s)
{
	std::string out;
	for (size_t i = 0; i < s.size();)
	{
		if (s.compare(i, 2, "/*") == 0)
		{
			const size_t end = s.find("*/", i + 2);
			i = end == std::string::npos ? s.size() : end + 2;
			continue;
		}
		if (s.compare(i, 2, "//") == 0)
		{
			const size_t end = s.find('\n', i);
			i = end == std::string::npos ? s.size() : end;
			continue;
		}
		out += s[i++];
	}
	return out;
}

std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

// The cases of a function body: key name -> what the case does up to its first "break;" (stacked cases: "").
std::map<std::string, std::string> cases_of(const std::string& body)
{
	std::map<std::string, std::string> out;
	size_t at = 0;
	for (;;)
	{
		at = body.find("case ", at);
		if (at == std::string::npos)
			break;
		const size_t colon = body.find(':', at);
		if (colon == std::string::npos)
			break;
		std::string name = body.substr(at + 5, colon - at - 5);
		name.erase(std::remove_if(name.begin(), name.end(), [](char c) { return c == ' ' || c == '\t'; }), name.end());
		const size_t next = body.find("case ", colon);
		const size_t brk = body.find("break;", colon);
		size_t end = std::min(next, brk == std::string::npos ? std::string::npos : brk + 6);
		if (end == std::string::npos)
			end = body.size();
		out[name] += body.substr(colon + 1, end - colon - 1);
		at = colon;
	}
	return out;
}

// The values of enum EGameActions (an enum without explicit values up to kFORCEDWORD).
std::map<std::string, int> game_actions()
{
	std::map<std::string, int> out;
	std::string src = without_comments(project_file("engine/src/xrGame/xr_level_controller.h"));
	const size_t open = src.find('{', src.find("enum EGameActions"));
	const size_t close = src.find("};", open);
	if (open == std::string::npos || close == std::string::npos)
		return out;
	const std::string list = src.substr(open + 1, close - open - 1);
	int value = 0;
	size_t at = 0;
	while (at < list.size())
	{
		size_t comma = list.find(',', at);
		if (comma == std::string::npos)
			comma = list.size();
		std::string name = list.substr(at, comma - at);
		name.erase(std::remove_if(name.begin(), name.end(), [](char c) { return c == ' ' || c == '\t' || c == '\n'; }),
		    name.end());
		at = comma + 1;
		if (name.empty())
			continue;
		if (name.find('=') != std::string::npos)
			break; // kFORCEDWORD = u32(-1)
		out[name] = value++;
	}
	return out;
}

bool calls_something(const std::string& text)
{
	for (const char* call : {"Press", "Release", "Transmission", "Switch", "Action(", "OnCameraChange", "Move("})
		if (text.find(call) != std::string::npos)
			return true;
	return false;
}

std::vector<uint8_t> wire(const v::InputMsg& m)
{
	coop::Writer w;
	v::write(w, m);
	return w.data();
}

bool back(const std::vector<uint8_t>& b, v::InputMsg& out)
{
	coop::Reader r(b.data(), b.size());
	return v::read(r, out);
}

constexpr uint16_t kCar = 1234;
constexpr uint16_t kMe = 77;
} // namespace

// ---------------------------------------------------------------- the key table against the stock code

TEST(vehicle_input_key_values_are_the_engine_enum)
{
	const std::map<std::string, int> actions = game_actions();
	REQUIRE(actions.size() > 40);
	CHECK_EQ(actions.at("kLEFT"), 0);
	for (const v::KeyRule& r : v::kKeyRules)
	{
		const auto it = actions.find(r.name);
		REQUIRE(it != actions.end());
		CHECK_EQ(it->second, r.key);
	}
}

TEST(vehicle_input_press_table_is_the_stock_press_switch)
{
	const std::string src = without_comments(project_file("engine/src/xrGame/CarInput.cpp"));
	REQUIRE(src.size() > 3000);
	const std::string body = between(src, "void CCar::OnKeyboardPress(int cmd)", "\n}\n");
	REQUIRE(!body.empty());
	const std::map<std::string, std::string> cases = cases_of(body);
	REQUIRE(cases.size() >= 15);
	for (const auto& c : cases)
	{
		// every key the stock press switches name has a rule
		const v::KeyRule* rule = nullptr;
		for (const v::KeyRule& r : v::kKeyRules)
			if (c.first == r.name)
				rule = &r;
		REQUIRE(rule != nullptr);
		if (*rule->press)
			CHECK(c.second.find(rule->press) != std::string::npos);
		else
			CHECK(!calls_something(c.second));
		if (rule->needs_weapon)
			CHECK(c.second.find("HasWeapon()") != std::string::npos);
	}
	// every key of the decider is a case of the stock press switch, with the call its rule names
	for (const v::KeyRule& r : v::kKeyRules)
		if (r.use != v::KeyUse::Local)
		{
			const auto it = cases.find(r.name);
			REQUIRE(it != cases.end());
			CHECK(*r.press != 0);
		}
	// the camera stays: the three camera keys and the zoom are Local
	CHECK(v::key_use(k::kCAM_1) == v::KeyUse::Local);
	CHECK(v::key_use(k::kCAM_2) == v::KeyUse::Local);
	CHECK(v::key_use(k::kCAM_3) == v::KeyUse::Local);
	CHECK(v::key_use(k::kWPN_ZOOM) == v::KeyUse::Local);
	CHECK(v::key_use(k::kUSE) == v::KeyUse::Local);
}

TEST(vehicle_input_release_table_is_the_stock_release_switch)
{
	const std::string src = without_comments(project_file("engine/src/xrGame/CarInput.cpp"));
	const std::string body = between(src, "void CCar::OnKeyboardRelease(int cmd)", "\n}\n");
	REQUIRE(!body.empty());
	const std::map<std::string, std::string> cases = cases_of(body);
	REQUIRE(cases.size() >= 7);
	for (const auto& c : cases)
	{
		const v::KeyRule* rule = nullptr;
		for (const v::KeyRule& r : v::kKeyRules)
			if (c.first == r.name)
				rule = &r;
		REQUIRE(rule != nullptr);
		if (*rule->release)
			CHECK(c.second.find(rule->release) != std::string::npos);
		else
			CHECK(!calls_something(c.second));
	}
	for (const v::KeyRule& r : v::kKeyRules)
		if (*r.release && r.use != v::KeyUse::Local)
			CHECK(cases.count(r.name) == 1);
	// a counter and the weapon switch: the stock release calls nothing for them (no case)
	CHECK(cases.count("kDETECTOR") == 0);
	CHECK(cases.count("kTORCH") == 0);
	CHECK(cases.count("kWPN_FUNC") == 0);
}

TEST(vehicle_input_hold_keys_are_all_the_camera)
{
	const std::string src = without_comments(project_file("engine/src/xrGame/CarInput.cpp"));
	const std::string body = between(src, "void CCar::OnKeyboardHold(int cmd)", "\n}\n");
	REQUIRE(!body.empty());
	const std::map<std::string, std::string> cases = cases_of(body);
	REQUIRE(cases.size() >= 6); // kCAM_ZOOM_IN / OUT, kUP, kDOWN, kLEFT, kRIGHT: active_camera->Move (the comment block is out)
	for (const auto& c : cases)
	{
		const v::KeyRule* rule = nullptr;
		for (const v::KeyRule& r : v::kKeyRules)
			if (c.first == r.name)
				rule = &r;
		REQUIRE(rule != nullptr);
		CHECK(rule->use == v::KeyUse::Local);
	}
	CHECK(body.find("active_camera->Move(cmd)") != std::string::npos);
}

// ---------------------------------------------------------------- the driver's keys

TEST(vehicle_input_held_bits_follow_the_keys)
{
	v::InputSender s;
	// not driving: a decider's key is still not the copy's, but nothing is held
	CHECK(s.press(k::kFWD));
	CHECK_EQ(s.held(), uint16_t(0));
	CHECK(!s.press(k::kCAM_2));
	s.start(kCar, false);
	CHECK(s.press(k::kFWD));
	CHECK(s.press(k::kJUMP));
	CHECK(s.press(k::kL_STRAFE));
	CHECK_EQ(s.held(), uint16_t(v::kHeldForward | v::kHeldBrake | v::kHeldLeft));
	CHECK(s.release(k::kFWD));
	CHECK_EQ(s.held(), uint16_t(v::kHeldBrake | v::kHeldLeft));
	// a gear: a press is a press; its release only clears the bit (the stock release does nothing)
	CHECK(s.press(k::kACCEL));
	CHECK((s.held() & v::kHeldTransUp) != 0);
	CHECK(s.release(k::kACCEL));
	CHECK((s.held() & v::kHeldTransUp) == 0);
	CHECK(s.press(k::kCROUCH));
	CHECK((s.held() & v::kHeldTransDown) != 0);
	// camera keys and the use key stay on this machine, keys the car ignores too
	for (int key : {k::kCAM_1, k::kCAM_2, k::kCAM_3, k::kWPN_ZOOM, k::kCAM_ZOOM_IN, k::kLEFT, k::kUP, k::kUSE, 7, 22, 999})
	{
		CHECK(!s.press(key));
		CHECK(!s.release(key));
	}
	CHECK_EQ(s.held(), uint16_t(v::kHeldBrake | v::kHeldLeft | v::kHeldTransDown));
	s.stop();
	CHECK(!s.driving());
	CHECK_EQ(s.held(), uint16_t(0));
}

TEST(vehicle_input_weapon_keys_only_with_a_weapon)
{
	v::InputSender s;
	s.start(kCar, false);
	CHECK(s.press(k::kWPN_FIRE)); // the decider's key, never the copy's
	CHECK(s.press(k::kWPN_FUNC));
	CHECK_EQ(s.held(), uint16_t(0)); // `if (HasWeapon())`: nothing
	s.set_aim(1.f, 0.2f);
	CHECK(!s.take(0).has_aim());

	s.start(kCar, true);
	CHECK(s.press(k::kWPN_FUNC));
	CHECK((s.held() & v::kHeldWeapon) != 0); // Action(eWpnActivate, !IsActive())
	CHECK(s.release(k::kWPN_FUNC));
	CHECK((s.held() & v::kHeldWeapon) != 0); // the release does nothing
	CHECK(s.press(k::kWPN_FUNC));
	CHECK((s.held() & v::kHeldWeapon) == 0);
	CHECK(s.press(k::kWPN_FIRE));
	CHECK((s.held() & v::kHeldFire) != 0);
	CHECK(s.release(k::kWPN_FIRE));
	CHECK((s.held() & v::kHeldFire) == 0);
}

TEST(vehicle_input_edges_count_presses)
{
	v::InputSender s;
	s.start(kCar, false);
	CHECK(s.press(k::kDETECTOR));
	CHECK(s.release(k::kDETECTOR));
	CHECK(s.press(k::kDETECTOR));
	CHECK_EQ(v::edge_count(s.edges(), v::Edge::Engine), uint8_t(2));
	for (int i = 0; i < 5; ++i)
		CHECK(s.press(k::kTORCH));
	CHECK_EQ(v::edge_count(s.edges(), v::Edge::Lights), uint8_t(1)); // mod 4
	CHECK_EQ(v::edge_count(s.edges(), v::Edge::Horn), uint8_t(0)); // no stock key
	CHECK_EQ(s.held(), uint16_t(0)); // a counter is no held key
	// the counters start again at each granted
	s.start(kCar, false);
	CHECK_EQ(s.edges(), uint8_t(0));
}

// ---------------------------------------------------------------- the stream

TEST(vehicle_input_cadence_first_change_repeat)
{
	v::InputSender s;
	CHECK(!s.due(0));
	s.start(kCar, false);
	CHECK(s.due(1000)); // the first one at once
	v::InputMsg m = s.take(1000);
	CHECK_EQ(m.seq, uint8_t(1));
	CHECK_EQ(m.car, kCar);
	CHECK(!s.due(1001));
	CHECK(!s.due(1000 + v::kInputRepeatMs - 1));
	CHECK(s.due(1000 + v::kInputRepeatMs)); // every 200 ms with nothing held: the decider's input never goes stale
	m = s.take(1200);
	CHECK_EQ(m.seq, uint8_t(2));
	// a change waits for kInputMinIntervalMs after the last message
	s.press(k::kFWD);
	CHECK(!s.due(1210));
	CHECK(!s.due(1200 + v::kInputMinIntervalMs - 1));
	CHECK(s.due(1200 + v::kInputMinIntervalMs));
	m = s.take(1233);
	CHECK_EQ(m.held, v::kHeldForward);
	CHECK(!s.due(1300)); // held, unchanged: the repeat
	CHECK(s.due(1233 + v::kInputRepeatMs));
	m = s.take(1433);
	CHECK_EQ(m.held, v::kHeldForward);
	s.release(k::kFWD);
	CHECK(s.due(1500));
	CHECK_EQ(s.take(1500).held, uint16_t(0));
	// a press and its release between two messages: a held key is a state, a counter is not lost
	s.press(k::kJUMP);
	s.release(k::kJUMP);
	s.press(k::kDETECTOR);
	CHECK(s.due(1540));
	m = s.take(1540);
	CHECK_EQ(m.held, uint16_t(0));
	CHECK_EQ(v::edge_count(m.edges, v::Edge::Engine), uint8_t(1));
	s.stop();
	CHECK(!s.due(5000));
}

TEST(vehicle_input_a_quiet_driver_never_goes_stale)
{
	// 60 frames a second for 5 s, nothing pressed: the decider's InputTrack never brakes him
	v::InputSender s;
	v::InputTrack track;
	s.start(kCar, false);
	track.start(kCar, 0);
	uint32_t longest = 0, last = 0;
	bool sent = false;
	for (uint32_t t = 0; t < 5000; t += 16)
	{
		if (s.due(t))
		{
			const v::InputMsg m = s.take(t);
			v::InputMsg got;
			REQUIRE(back(wire(m), got));
			CHECK(track.accept(got, t).applied());
			if (sent)
				longest = std::max(longest, t - last);
			last = t;
			sent = true;
		}
		CHECK(!track.tick(t).stale);
	}
	CHECK(longest <= v::kInputRepeatMs + 16);
	CHECK(longest < v::kInputStaleMs);
}

TEST(vehicle_input_seq_wraps_and_the_decider_takes_each)
{
	v::InputSender s;
	v::InputTrack track;
	s.start(kCar, false);
	track.start(kCar, 0);
	uint32_t t = 0;
	for (int i = 1; i <= 600; ++i)
	{
		t += v::kInputRepeatMs;
		REQUIRE(s.due(t));
		const v::InputMsg m = s.take(t);
		CHECK_EQ(m.seq, uint8_t(i & 0xff));
		v::InputMsg got;
		REQUIRE(back(wire(m), got));
		CHECK(track.accept(got, t).applied());
	}
	// a repeat of the same message is old on the decider
	v::InputMsg got;
	REQUIRE(back(wire(s.take(t + 300)), got));
	CHECK(track.accept(got, t + 300).applied());
	CHECK(track.accept(got, t + 301).drop == v::InputDrop::Old);
}

TEST(vehicle_input_presses_reach_the_decider_as_toggles)
{
	v::InputSender s;
	v::InputTrack track;
	s.start(kCar, false);
	track.start(kCar, 0);
	v::InputMsg got;
	REQUIRE(back(wire(s.take(0)), got));
	CHECK(track.accept(got, 0).applied());
	s.press(k::kDETECTOR); // engine on
	s.press(k::kTORCH);
	s.press(k::kTORCH); // lights on and off
	s.press(k::kFWD);
	REQUIRE(s.due(40));
	REQUIRE(back(wire(s.take(40)), got));
	v::InputStep step = track.accept(got, 40);
	REQUIRE(step.applied());
	CHECK_EQ(step.engine_toggles, uint8_t(1));
	CHECK_EQ(step.lights_toggles, uint8_t(2));
	CHECK_EQ(step.before, uint16_t(0));
	CHECK_EQ(step.held, v::kHeldForward);
	// a lost message: the next one still carries the presses
	s.press(k::kDETECTOR);
	(void)s.take(80); // lost
	REQUIRE(s.due(280));
	REQUIRE(back(wire(s.take(280)), got));
	step = track.accept(got, 280);
	REQUIRE(step.applied());
	CHECK_EQ(step.engine_toggles, uint8_t(1));
	CHECK_EQ(step.lights_toggles, uint8_t(0));
}

TEST(vehicle_input_aim_angles_packing)
{
	const double step = 3.14159265358979323846 / 32768.0;
	v::InputSender s;
	s.start(kCar, true);
	CHECK(!s.take(0).has_aim()); // no aim yet: the stock weapon keeps its own direction
	s.set_aim(1.f, 0.3f);
	CHECK(s.due(v::kInputMinIntervalMs));
	const v::InputMsg m = s.take(v::kInputMinIntervalMs);
	REQUIRE(m.has_aim());
	const std::vector<uint8_t> b = wire(m);
	CHECK_EQ(b.size(), size_t(10));
	v::InputMsg got;
	REQUIRE(back(b, got));
	CHECK(std::fabs(v::angle_from_wire(got.aim_yaw) - 1.0) <= step);
	CHECK(std::fabs(v::angle_from_wire(got.aim_pitch) - 0.3) <= step);
	// a heading past pi wraps; the pitch is clamped to +-90 degrees; NaN is 0
	s.set_aim(4.f, 3.f);
	const v::InputMsg w = s.take(200);
	CHECK(std::fabs(v::angle_from_wire(w.aim_yaw) - (4.0 - 2.0 * 3.14159265358979323846)) <= step);
	CHECK_EQ(w.aim_pitch, v::kMaxPitchWire);
	s.set_aim(std::numeric_limits<float>::quiet_NaN(), -std::numeric_limits<float>::infinity());
	const v::InputMsg n = s.take(400);
	CHECK_EQ(n.aim_yaw, int16_t(0));
	CHECK_EQ(n.aim_pitch, int16_t(0));
	REQUIRE(back(wire(n), got));
	// the same aim again is no change
	CHECK(!s.due(500));
	// without a weapon the layout is the short one
	v::InputSender plain;
	plain.start(kCar, false);
	plain.set_aim(1.f, 0.3f);
	CHECK_EQ(wire(plain.take(0)).size(), size_t(6));
}

TEST(vehicle_input_console_drive_overrides_then_returns)
{
	v::InputSender s;
	s.start(kCar, false);
	(void)s.take(0);
	s.press(k::kJUMP);
	s.force(uint16_t(v::kHeldForward | v::kHeldFire | v::kHeldWeapon | 0x8000), 100, 500);
	CHECK_EQ(s.held_at(100), v::kHeldForward); // no weapon: no fire, no switch; no layout flag
	CHECK(s.due(100));
	CHECK_EQ(s.take(100).held, v::kHeldForward);
	CHECK_EQ(s.held_at(599), v::kHeldForward);
	CHECK_EQ(s.held_at(600), v::kHeldBrake); // the real keys again
	CHECK(s.due(600));
	CHECK_EQ(s.take(600).held, v::kHeldBrake);
}

// ---------------------------------------------------------------- requests

TEST(vehicle_input_one_request_at_a_time_and_the_timeout)
{
	v::RequestTrack q;
	CHECK(q.may_send(0));
	q.sent(v::ReqOp::Enter, kCar, 1000);
	CHECK(q.pending());
	CHECK(!q.may_send(1500)); // waits for the answer
	CHECK(!q.timed_out(1000 + v::kAnswerTimeoutMs - 1));
	CHECK(q.timed_out(1000 + v::kAnswerTimeoutMs)); // the HUD says so, the request is forgotten
	CHECK(!q.timed_out(1000 + v::kAnswerTimeoutMs + 1)); // once
	CHECK(!q.pending());
	CHECK(q.may_send(1000 + v::kAnswerTimeoutMs));
	// an answer: the next request no sooner than kRequestMinIntervalMs after the last one sent
	q.sent(v::ReqOp::Enter, kCar, 10000);
	CHECK(!q.answer(v::SeatMsg::refused(999, v::kAnySeat, kMe, v::Refusal::Full), kMe)); // not its car
	CHECK(q.answer(v::SeatMsg::refused(kCar, v::kAnySeat, kMe, v::Refusal::SeatTaken), kMe));
	CHECK(!q.pending());
	CHECK(!q.may_send(10000 + v::kRequestMinIntervalMs - 1));
	CHECK(q.may_send(10000 + v::kRequestMinIntervalMs));
	q.reset();
	CHECK(q.may_send(0));
}

TEST(vehicle_input_requests_answered_by_my_character)
{
	const float exit_pos[3] = {1.f, 2.f, 3.f};
	v::RequestTrack q;
	q.sent(v::ReqOp::Enter, kCar, 0);
	CHECK(!q.answer(v::SeatMsg::granted(kCar, 0, 12), kMe)); // somebody else took the seat: still mine to wait for
	CHECK(q.pending());
	CHECK(q.answer(v::SeatMsg::granted(kCar, 0, kMe), kMe));
	q.sent(v::ReqOp::Exit, kCar, 300);
	CHECK(!q.answer(v::SeatMsg::released(kCar, 1, 12, v::Release::Exit, exit_pos), kMe));
	CHECK(q.answer(v::SeatMsg::released(kCar, 0, kMe, v::Release::Exit, exit_pos), kMe));
	// a refused with no character of mine here (Server: not on the level yet) still answers it
	q.sent(v::ReqOp::Enter, kCar, 600);
	CHECK(q.answer(v::SeatMsg::refused(kCar, v::kAnySeat, v::kNoCharacter, v::Refusal::NoCharacter), kMe));
	// before my character is known nothing but a refused answers
	q.sent(v::ReqOp::Enter, kCar, 900);
	CHECK(!q.answer(v::SeatMsg::granted(kCar, 0, v::kNoCharacter), v::kNoCharacter));
}

TEST(vehicle_input_seat_steps_of_my_actor)
{
	const float exit_pos[3] = {1.f, 2.f, 3.f};
	const v::Seated none{};
	const v::Seated driving{kCar, 0, kMe};
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 0, kMe), kMe, none) == v::SeatStep::Attach);
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 0, kMe), kMe, driving) == v::SeatStep::None); // said again
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 1, kMe), kMe, none) == v::SeatStep::Ride);
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 1, kMe), kMe, driving) == v::SeatStep::Ride); // a switch to a passenger seat
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 0, 12), kMe, driving) == v::SeatStep::Lost);
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 1, 12), kMe, driving) == v::SeatStep::None);
	CHECK(v::seat_step(v::SeatMsg::granted(999, 0, 12), kMe, driving) == v::SeatStep::None);
	CHECK(v::seat_step(v::SeatMsg::released(kCar, 0, kMe, v::Release::CarDestroyed, exit_pos), kMe, driving) ==
	      v::SeatStep::Leave);
	CHECK(v::seat_step(v::SeatMsg::released(kCar, 0, kMe, v::Release::Exit, exit_pos), kMe, none) == v::SeatStep::Leave);
	CHECK(v::seat_step(v::SeatMsg::released(kCar, 0, 12, v::Release::Exit, exit_pos), kMe, none) == v::SeatStep::None);
	CHECK(v::seat_step(v::SeatMsg::refused(kCar, v::kAnySeat, kMe, v::Refusal::Locked), kMe, none) == v::SeatStep::Refused);
	// before my character is known nothing is mine
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 0, v::kNoCharacter), v::kNoCharacter, none) == v::SeatStep::None);
}

// ---------------------------------------------------------------- the client's hooks against the stock (rv_F5-VEH-3 blockers)

// Blocker 1: the stock press of kR_STRAFE / kL_STRAFE turns the Owner's hands (steer_Vehicle(1) / (-1)), the release back (0). On a
// player's copy client_key returns before the stock switch, so it turns them itself: the copy's owner is this machine's actor.
TEST(vehicle_input_steering_keys_turn_the_drivers_hands_as_the_stock)
{
	const std::string stock = without_comments(project_file("engine/src/xrGame/CarInput.cpp"));
	std::map<std::string, std::string> press = cases_of(between(stock, "void CCar::OnKeyboardPress(int cmd)", "\n}\n"));
	std::map<std::string, std::string> release = cases_of(between(stock, "void CCar::OnKeyboardRelease(int cmd)", "\n}\n"));
	CHECK(press["kR_STRAFE"].find("steer_Vehicle(1)") != std::string::npos);
	CHECK(press["kL_STRAFE"].find("steer_Vehicle(-1)") != std::string::npos);
	CHECK(release["kR_STRAFE"].find("steer_Vehicle(0)") != std::string::npos);
	CHECK(release["kL_STRAFE"].find("steer_Vehicle(0)") != std::string::npos);
	// both steering keys go to the decider (else the stock switch would turn the hands itself)
	CHECK(v::key_use(k::kR_STRAFE) != v::KeyUse::Local);
	CHECK(v::key_use(k::kL_STRAFE) != v::KeyUse::Local);

	const std::string client = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp"));
	const std::string key = between(client, "bool client_key(CCar* car, int key, bool pressed)", "\n}\n");
	REQUIRE(!key.empty());
	const size_t took = key.find("const bool took = pressed ? g_input.press(key) : g_input.release(key);");
	const size_t which = key.find("if (key == kL_STRAFE || key == kR_STRAFE)");
	const size_t owner = key.find("a->Holder() == smart_cast<CHolderCustom*>(car)");
	// release 0, right +1, left -1: the stock's numbers above
	const size_t steer = key.find("a->steer_Vehicle(!pressed ? 0.f : (key == kR_STRAFE ? 1.f : -1.f));");
	CHECK(took != std::string::npos);
	CHECK(which != std::string::npos && took < which);
	CHECK(owner != std::string::npos && which < owner);
	CHECK(steer != std::string::npos && owner < steer);
	CHECK(key.find("return took;") != std::string::npos);
}

// Blocker 2: a "released" for me followed in the same frame by a "granted" of my seat to another player (a driver swap): until
// step_leave runs g_mine still holds the car, so the grant reads as Lost. It must not throw away the decider's exit point and reason.
TEST(vehicle_input_a_grant_after_my_release_keeps_the_deciders_exit)
{
	const float exit_pos[3] = {1.f, 2.f, 3.f};
	const v::Seated driving{kCar, 0, kMe};
	CHECK(v::seat_step(v::SeatMsg::released(kCar, 0, kMe, v::Release::Exit, exit_pos), kMe, driving) == v::SeatStep::Leave);
	// g_mine still names the car until step_leave: the other's grant is classified Lost
	CHECK(v::seat_step(v::SeatMsg::granted(kCar, 0, 12), kMe, driving) == v::SeatStep::Lost);

	const std::string client = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp"));
	const std::string lost = between(client, "case SeatStep::Lost:", "default:");
	REQUIRE(!lost.empty());
	const size_t guard = lost.find("if (g_mine.leave_due)");
	const size_t keep = lost.find("break;");
	const size_t wipe = lost.find("g_mine.has_exit = false;");
	CHECK(guard != std::string::npos);
	CHECK(keep != std::string::npos && guard < keep);
	CHECK(wipe != std::string::npos && keep < wipe);
	if (guard != std::string::npos && keep != std::string::npos && guard < keep)
		CHECK(lost.substr(guard, keep - guard).find(';') == std::string::npos); // the guard does nothing but leave the case
}
