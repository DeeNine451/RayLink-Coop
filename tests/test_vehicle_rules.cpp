// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: vehicles for players (F5-VEH-1, docs/VEHICLES.md) - the four messages, the seat table, the verdicts
// and the input rules of coop_vehicle_rules.h. One set of rules for both modes: the decider is the co-op host or the map server
// of the player's level, the rules do not know which.
#include "test_util.h"

#include <cmath>
#include <cstring>
#include <limits>

#include "coop_vehicle_rules.h"

namespace v = coop::vehicles;

namespace
{
template <class M>
std::vector<uint8_t> bytes_of(const M& m)
{
	coop::Writer w;
	v::write(w, m);
	return w.data();
}

template <class M>
bool read_bytes(const std::vector<uint8_t>& b, M& out)
{
	coop::Reader r(b.data(), b.size());
	return v::read(r, out);
}

// Every proper prefix of a valid message is refused.
template <class M>
bool every_prefix_refused(const std::vector<uint8_t>& full)
{
	for (size_t n = 0; n < full.size(); ++n)
	{
		std::vector<uint8_t> cut(full.begin(), full.begin() + n);
		M out;
		if (read_bytes(cut, out))
			return false;
	}
	return true;
}

v::EnterFacts good_enter()
{
	v::EnterFacts f;
	f.car_known = true;
	f.supported = true;
	f.car_destroyed = false;
	f.enter_locked = false;
	f.alive = true;
	f.wounded = false;
	f.carrying = false;
	f.seated = false;
	f.seats = 2;
	f.seat = v::kAnySeat;
	f.seat_free = true;
	f.distance = 2.5f;
	f.since_last_ms = 10000;
	return f;
}

v::InputMsg input(uint16_t car, uint8_t seq, uint16_t held, uint8_t edges = 0)
{
	v::InputMsg m;
	m.car = car;
	m.seq = seq;
	m.held = held;
	m.edges = edges;
	return m;
}
} // namespace

// ---------------------------------------------------------------- VehicleReq

TEST(vehicle_req_round_trip)
{
	const v::ReqMsg cases[] = {
		{v::ReqOp::Enter, 1234, v::kAnySeat},
		{v::ReqOp::Enter, 7, 0},
		{v::ReqOp::Enter, 7, v::kMaxSeats - 1},
		{v::ReqOp::Exit, 65000, v::kAnySeat},
		{v::ReqOp::SwitchSeat, 42, 3},
	};
	for (const v::ReqMsg& m : cases)
	{
		const std::vector<uint8_t> b = bytes_of(m);
		CHECK_EQ(b.size(), size_t(4));
		v::ReqMsg out;
		REQUIRE(read_bytes(b, out));
		CHECK(out.op == m.op);
		CHECK_EQ(out.car, m.car);
		CHECK_EQ(out.seat, m.seat);
		CHECK(every_prefix_refused<v::ReqMsg>(b));
	}
}

TEST(vehicle_req_refuses_bad_ops_and_seats)
{
	auto refused = [](v::ReqMsg m) {
		v::ReqMsg out;
		return !read_bytes(bytes_of(m), out);
	};
	// ops outside the enum
	for (uint8_t op : {uint8_t(0), uint8_t(4), uint8_t(200), uint8_t(255)})
		CHECK(refused({v::ReqOp(op), 10, v::kAnySeat}));
	// enter: a seat no car has; kAnySeat is fine
	CHECK(refused({v::ReqOp::Enter, 10, v::kMaxSeats}));
	CHECK(refused({v::ReqOp::Enter, 10, v::kNoSeat}));
	CHECK(!refused({v::ReqOp::Enter, 10, v::kAnySeat}));
	// exit names no seat: the decider knows where he sits
	CHECK(refused({v::ReqOp::Exit, 10, 0}));
	// switch needs a real seat
	CHECK(refused({v::ReqOp::SwitchSeat, 10, v::kAnySeat}));
	CHECK(refused({v::ReqOp::SwitchSeat, 10, v::kMaxSeats}));
	CHECK(!refused({v::ReqOp::SwitchSeat, 10, 1}));
	// no car
	CHECK(refused({v::ReqOp::Enter, v::kNoCar, v::kAnySeat}));

	// a byte too many: another layout
	std::vector<uint8_t> b = bytes_of(v::ReqMsg{v::ReqOp::Enter, 10, 0});
	b.push_back(0);
	v::ReqMsg out;
	CHECK(!read_bytes(b, out));
}

// ---------------------------------------------------------------- VehicleSeat

TEST(vehicle_seat_round_trip)
{
	const v::SeatMsg granted = v::SeatMsg::granted(300, 0, 4711);
	std::vector<uint8_t> b = bytes_of(granted);
	CHECK_EQ(b.size(), size_t(7));
	v::SeatMsg out;
	REQUIRE(read_bytes(b, out));
	CHECK(out.op == v::SeatOp::Granted);
	CHECK_EQ(out.car, uint16_t(300));
	CHECK_EQ(out.seat, uint8_t(0));
	CHECK_EQ(out.character, uint16_t(4711));
	CHECK_EQ(out.reason, uint8_t(0));
	CHECK(every_prefix_refused<v::SeatMsg>(b));

	const float exit_pos[3] = {-1234.5f, 17.25f, 4321.125f};
	const v::SeatMsg released = v::SeatMsg::released(300, 1, 4711, v::Release::Death, exit_pos);
	b = bytes_of(released);
	CHECK_EQ(b.size(), size_t(19));
	REQUIRE(read_bytes(b, out));
	CHECK(out.op == v::SeatOp::Released);
	CHECK(out.release() == v::Release::Death);
	CHECK_EQ(out.seat, uint8_t(1));
	CHECK_EQ(out.exit[0], exit_pos[0]);
	CHECK_EQ(out.exit[1], exit_pos[1]);
	CHECK_EQ(out.exit[2], exit_pos[2]);
	CHECK(every_prefix_refused<v::SeatMsg>(b));

	// a refusal goes to the asker only; it may name the seat he asked (kAnySeat too) and nobody when he has no character here
	const v::SeatMsg refused = v::SeatMsg::refused(300, v::kAnySeat, v::kNoCharacter, v::Refusal::NoCharacter);
	b = bytes_of(refused);
	CHECK_EQ(b.size(), size_t(7));
	REQUIRE(read_bytes(b, out));
	CHECK(out.op == v::SeatOp::Refused);
	CHECK(out.refusal() == v::Refusal::NoCharacter);
	CHECK_EQ(out.seat, v::kAnySeat);
	CHECK_EQ(out.character, v::kNoCharacter);
}

TEST(vehicle_seat_refuses_bad)
{
	auto refused = [](const v::SeatMsg& m) {
		v::SeatMsg out;
		return !read_bytes(bytes_of(m), out);
	};
	const float at[3] = {1.f, 2.f, 3.f};

	v::SeatMsg m = v::SeatMsg::granted(10, 0, 5);
	m.op = v::SeatOp(0);
	CHECK(refused(m));
	m.op = v::SeatOp(4);
	CHECK(refused(m));

	// granted: a real seat, a character, no reason
	CHECK(refused(v::SeatMsg::granted(10, v::kMaxSeats, 5)));
	CHECK(refused(v::SeatMsg::granted(10, v::kAnySeat, 5)));
	CHECK(refused(v::SeatMsg::granted(10, 0, v::kNoCharacter)));
	m = v::SeatMsg::granted(10, 0, 5);
	m.reason = 1;
	CHECK(refused(m));
	CHECK(refused(v::SeatMsg::granted(v::kNoCar, 0, 5)));

	// released: a release reason, a character, a sane exit position
	CHECK(!refused(v::SeatMsg::released(10, 0, 5, v::Release::Exit, at)));
	CHECK(refused(v::SeatMsg::released(10, v::kMaxSeats, 5, v::Release::Exit, at)));
	CHECK(refused(v::SeatMsg::released(10, 0, v::kNoCharacter, v::Release::Exit, at)));
	m = v::SeatMsg::released(10, 0, 5, v::Release::Exit, at);
	m.reason = 0;
	CHECK(refused(m));
	m.reason = uint8_t(v::Release::Last) + 1;
	CHECK(refused(m));
	const float nan_pos[3] = {std::numeric_limits<float>::quiet_NaN(), 0.f, 0.f};
	CHECK(refused(v::SeatMsg::released(10, 0, 5, v::Release::Exit, nan_pos)));
	const float inf_pos[3] = {0.f, std::numeric_limits<float>::infinity(), 0.f};
	CHECK(refused(v::SeatMsg::released(10, 0, 5, v::Release::Exit, inf_pos)));
	const float far_pos[3] = {0.f, 0.f, v::kMaxCoord * 2.f};
	CHECK(refused(v::SeatMsg::released(10, 0, 5, v::Release::Exit, far_pos)));

	// refused: a refusal reason, never None
	m = v::SeatMsg::refused(10, 0, 5, v::Refusal::SeatTaken);
	CHECK(!refused(m));
	m.reason = 0;
	CHECK(refused(m));
	m.reason = uint8_t(v::Refusal::Last) + 1;
	CHECK(refused(m));
	CHECK(refused(v::SeatMsg::refused(10, v::kMaxSeats, 5, v::Refusal::NoSuchSeat)));

	// a byte too many
	std::vector<uint8_t> b = bytes_of(v::SeatMsg::granted(10, 0, 5));
	b.push_back(0);
	v::SeatMsg out;
	CHECK(!read_bytes(b, out));
	// the released layout cut after the header (the exit position missing)
	b = bytes_of(v::SeatMsg::released(10, 0, 5, v::Release::Exit, at));
	b.resize(7);
	CHECK(!read_bytes(b, out));
}

// ---------------------------------------------------------------- VehicleInput

TEST(vehicle_input_round_trip)
{
	v::InputMsg m = input(900, 17, v::kHeldForward | v::kHeldLeft | v::kHeldBrake);
	m.edges = v::bump_edge(v::bump_edge(0, v::Edge::Engine), v::Edge::Lights);
	std::vector<uint8_t> b = bytes_of(m);
	CHECK_EQ(b.size(), size_t(6));
	v::InputMsg out;
	REQUIRE(read_bytes(b, out));
	CHECK_EQ(out.car, uint16_t(900));
	CHECK_EQ(out.seq, uint8_t(17));
	CHECK_EQ(out.held, uint16_t(v::kHeldForward | v::kHeldLeft | v::kHeldBrake));
	CHECK_EQ(out.edges, m.edges);
	CHECK(!out.has_aim());
	CHECK(every_prefix_refused<v::InputMsg>(b));

	// the car's weapon: fire held, the weapon switched on, the aim follows
	m = input(901, 255, v::kHeldFire | v::kHeldWeapon | v::kHeldTransUp);
	m.set_aim(1.25f, -0.5f);
	b = bytes_of(m);
	CHECK_EQ(b.size(), size_t(10));
	REQUIRE(read_bytes(b, out));
	CHECK(out.has_aim());
	CHECK_EQ(out.aim_yaw, m.aim_yaw);
	CHECK_EQ(out.aim_pitch, m.aim_pitch);
	CHECK(std::fabs(v::angle_from_wire(out.aim_yaw) - 1.25f) < 1e-3f);
	CHECK(std::fabs(v::angle_from_wire(out.aim_pitch) + 0.5f) < 1e-3f);
	CHECK(every_prefix_refused<v::InputMsg>(b));
}

TEST(vehicle_input_refuses_bad)
{
	auto refused = [](const v::InputMsg& m) {
		v::InputMsg out;
		return !read_bytes(bytes_of(m), out);
	};
	CHECK(refused(input(v::kNoCar, 1, 0)));
	// bits nobody defined
	for (int bit = 9; bit < 15; ++bit)
		CHECK(refused(input(5, 1, uint16_t(1u << bit))));
	CHECK(!refused(input(5, 1, v::kHeldKeys | v::kHeldWeapon)));
	// edge bits above the three counters
	CHECK(refused(input(5, 1, 0, 0x40)));
	CHECK(refused(input(5, 1, 0, 0x80)));
	CHECK(!refused(input(5, 1, 0, v::kEdgesUsed)));
	// a pitch beyond straight up or down
	v::InputMsg m = input(5, 1, v::kHeldWeapon);
	m.set_aim(0.f, 0.f);
	m.aim_pitch = int16_t(v::kMaxPitchWire + 1);
	CHECK(refused(m));
	m.aim_pitch = int16_t(-v::kMaxPitchWire - 1);
	CHECK(refused(m));
	m.aim_pitch = int16_t(v::kMaxPitchWire);
	CHECK(!refused(m));
	// the aim flag says two angles follow: without them the message is cut
	std::vector<uint8_t> b = bytes_of(m);
	b.resize(6);
	v::InputMsg out;
	CHECK(!read_bytes(b, out));
	// a byte too many
	b = bytes_of(input(5, 1, 0));
	b.push_back(0);
	CHECK(!read_bytes(b, out));
}

TEST(vehicle_aim_angles)
{
	CHECK_EQ(v::angle_to_wire(0.f), int16_t(0));
	const float pi = 3.14159265358979f;
	for (float a : {0.1f, -0.1f, 1.f, -1.f, 2.5f, -2.5f, 3.1f, -3.1f})
		CHECK(std::fabs(v::angle_from_wire(v::angle_to_wire(a)) - a) < 1e-3f);
	// a heading is wrapped into [-pi, pi)
	CHECK(std::fabs(v::angle_from_wire(v::angle_to_wire(2.f * pi + 0.5f)) - 0.5f) < 1e-3f);
	CHECK(std::fabs(v::angle_from_wire(v::angle_to_wire(-2.f * pi - 0.5f)) + 0.5f) < 1e-3f);
	// a pitch is clamped to straight up / down
	v::InputMsg m;
	m.set_aim(0.f, 3.f);
	CHECK_EQ(m.aim_pitch, int16_t(v::kMaxPitchWire));
	m.set_aim(0.f, -3.f);
	CHECK_EQ(m.aim_pitch, int16_t(-v::kMaxPitchWire));
	CHECK(m.has_aim());
	// garbage never reaches the wire as NaN
	CHECK_EQ(v::angle_to_wire(std::numeric_limits<float>::quiet_NaN()), int16_t(0));
}

TEST(vehicle_edge_counters)
{
	uint8_t e = 0;
	CHECK_EQ(v::edge_count(e, v::Edge::Engine), uint8_t(0));
	e = v::bump_edge(e, v::Edge::Engine);
	e = v::bump_edge(e, v::Edge::Horn);
	e = v::bump_edge(e, v::Edge::Horn);
	CHECK_EQ(v::edge_count(e, v::Edge::Engine), uint8_t(1));
	CHECK_EQ(v::edge_count(e, v::Edge::Lights), uint8_t(0));
	CHECK_EQ(v::edge_count(e, v::Edge::Horn), uint8_t(2));
	// a counter is mod 4: the fourth press wraps it, the delta still counts one
	uint8_t w = 0;
	for (int i = 0; i < 3; ++i)
		w = v::bump_edge(w, v::Edge::Lights);
	const uint8_t before = w;
	w = v::bump_edge(w, v::Edge::Lights);
	CHECK_EQ(v::edge_count(w, v::Edge::Lights), uint8_t(0));
	CHECK_EQ(v::edge_delta(w, before, v::Edge::Lights), uint8_t(1));
	CHECK_EQ(v::edge_delta(w, before, v::Edge::Engine), uint8_t(0));
	CHECK_EQ(w & ~v::kEdgesUsed, 0);
}

// ---------------------------------------------------------------- VehicleState

TEST(vehicle_state_round_trip)
{
	v::StateMsg m;
	m.car = 512;
	m.flags = v::kStateEngine | v::kStateLights;
	m.rpm = 200;
	m.gear = -1;
	m.health = 128;
	m.fuel = 255;
	m.damage = v::kMaxDamageStage;
	std::vector<uint8_t> b = bytes_of(m);
	CHECK_EQ(b.size(), size_t(8));
	v::StateMsg out;
	REQUIRE(read_bytes(b, out));
	CHECK_EQ(out.car, m.car);
	CHECK_EQ(out.flags, m.flags);
	CHECK_EQ(out.rpm, m.rpm);
	CHECK_EQ(out.gear, int8_t(-1));
	CHECK_EQ(out.health, m.health);
	CHECK_EQ(out.fuel, m.fuel);
	CHECK_EQ(out.damage, m.damage);
	CHECK(every_prefix_refused<v::StateMsg>(b));

	m.gear = v::kMaxGear;
	m.flags = v::kStateFlagsAll;
	REQUIRE(read_bytes(bytes_of(m), out));
	CHECK_EQ(out.gear, v::kMaxGear);
	CHECK_EQ(out.flags, v::kStateFlagsAll);
}

TEST(vehicle_state_refuses_bad)
{
	auto refused = [](const v::StateMsg& m) {
		v::StateMsg out;
		return !read_bytes(bytes_of(m), out);
	};
	v::StateMsg m;
	m.car = 5;
	CHECK(!refused(m));
	v::StateMsg bad = m;
	bad.car = v::kNoCar;
	CHECK(refused(bad));
	bad = m;
	bad.flags = uint8_t(v::kStateFlagsAll + 1);
	CHECK(refused(bad));
	bad = m;
	bad.gear = int8_t(-2);
	CHECK(refused(bad));
	bad = m;
	bad.gear = int8_t(v::kMaxGear + 1);
	CHECK(refused(bad));
	bad = m;
	bad.damage = uint8_t(v::kMaxDamageStage + 1);
	CHECK(refused(bad));
	std::vector<uint8_t> b = bytes_of(m);
	b.push_back(0);
	v::StateMsg out;
	CHECK(!read_bytes(b, out));
}

// ---------------------------------------------------------------- the seat table

TEST(vehicle_seats_two_players_one_seat)
{
	v::SeatTable t;
	const uint16_t car = 100, a = 1, b = 2, c = 3;
	const v::TakeResult first = t.take(car, 2, v::kDriverSeat, a);
	CHECK(first.reason == v::Refusal::None);
	CHECK_EQ(first.seat, v::kDriverSeat);
	const v::TakeResult second = t.take(car, 2, v::kDriverSeat, b);
	CHECK(second.reason == v::Refusal::SeatTaken);
	CHECK_EQ(second.seat, v::kNoSeat);
	CHECK_EQ(t.at(car, v::kDriverSeat), a);
	CHECK_EQ(t.driver_of(car), a);
	// any seat: the driver's is taken, the next free one
	const v::TakeResult any = t.take(car, 2, v::kAnySeat, b);
	CHECK(any.reason == v::Refusal::None);
	CHECK_EQ(any.seat, uint8_t(1));
	// nothing left
	const v::TakeResult full = t.take(car, 2, v::kAnySeat, c);
	CHECK(full.reason == v::Refusal::Full);
	CHECK_EQ(t.seated(), size_t(2));
	const std::vector<v::Seated> s = t.sitters(car);
	REQUIRE(s.size() == 2);
	CHECK_EQ(s[0].seat, uint8_t(0));
	CHECK_EQ(s[0].character, a);
	CHECK_EQ(s[1].seat, uint8_t(1));
	CHECK_EQ(s[1].character, b);
}

TEST(vehicle_seats_any_prefers_the_driver)
{
	v::SeatTable t;
	const v::TakeResult r = t.take(7, 4, v::kAnySeat, 11);
	CHECK(r.reason == v::Refusal::None);
	CHECK_EQ(r.seat, v::kDriverSeat);
	CHECK_EQ(t.pick(7, 4, v::kAnySeat), uint8_t(1));
	CHECK_EQ(t.pick(7, 4, 0), v::kNoSeat);
	CHECK_EQ(t.pick(7, 4, 3), uint8_t(3));
	CHECK_EQ(t.pick(8, 4, v::kAnySeat), v::kDriverSeat); // another car: all free
}

TEST(vehicle_seats_one_seat_car_refuses_seat_1)
{
	v::SeatTable t;
	CHECK(t.take(50, 1, 1, 9).reason == v::Refusal::NoSuchSeat);
	CHECK(t.take(50, 0, 0, 9).reason == v::Refusal::NoSuchSeat); // a car with no seats at all
	CHECK(t.take(50, v::kMaxSeats + 1, 0, 9).reason == v::Refusal::NoSuchSeat);
	CHECK_EQ(t.seated(), size_t(0));
	CHECK(t.take(50, 1, 0, 9).reason == v::Refusal::None);
	CHECK(t.take(50, 1, v::kAnySeat, 10).reason == v::Refusal::Full);

	// the verdict says the same from the facts
	v::EnterFacts f = good_enter();
	f.seats = 1;
	f.seat = 1;
	CHECK(v::enter(f) == v::Refusal::NoSuchSeat);
	f.seat = 0;
	CHECK(v::enter(f) == v::Refusal::None);
}

TEST(vehicle_seats_character_sits_once)
{
	v::SeatTable t;
	CHECK(t.take(1, 2, 0, 5).reason == v::Refusal::None);
	CHECK(t.take(2, 2, 0, 5).reason == v::Refusal::AlreadySeated);
	CHECK(t.take(1, 2, 1, 5).reason == v::Refusal::AlreadySeated);
	CHECK(t.take(1, 2, 1, v::kNoCharacter).reason == v::Refusal::NoCharacter);
	CHECK(t.take(v::kNoCar, 2, 1, 6).reason == v::Refusal::NoCar);
	const v::Seated where = t.seat_of(5);
	CHECK_EQ(where.car, uint16_t(1));
	CHECK_EQ(where.seat, uint8_t(0));
	CHECK_EQ(t.seat_of(6).car, v::kNoCar);
}

TEST(vehicle_seats_release_all_on_death)
{
	v::SeatTable t;
	const uint16_t a = 21, b = 22;
	REQUIRE(t.take(300, 3, 0, a).reason == v::Refusal::None);
	REQUIRE(t.take(300, 3, 2, b).reason == v::Refusal::None);
	const std::vector<v::Seated> gone = t.release_all(a);
	REQUIRE(gone.size() == 1);
	CHECK_EQ(gone[0].car, uint16_t(300));
	CHECK_EQ(gone[0].seat, uint8_t(0));
	CHECK_EQ(gone[0].character, a);
	CHECK_EQ(t.seat_of(a).car, v::kNoCar);
	CHECK_EQ(t.driver_of(300), v::kNoCharacter);
	CHECK_EQ(t.at(300, 2), b); // the passenger keeps his seat
	CHECK(t.release_all(a).empty()); // twice: nothing
	// the seat is free again
	CHECK(t.take(300, 3, 0, b + 1).reason == v::Refusal::None);
	CHECK(t.release_all(b).size() == 1);
	CHECK(t.release_all(b + 1).size() == 1);
	CHECK_EQ(t.seated(), size_t(0));
	CHECK_EQ(t.cars(), size_t(0)); // an empty car leaves the table
}

TEST(vehicle_seats_release_car)
{
	v::SeatTable t;
	REQUIRE(t.take(77, 3, 0, 1).reason == v::Refusal::None);
	REQUIRE(t.take(77, 3, 1, 2).reason == v::Refusal::None);
	REQUIRE(t.take(78, 1, 0, 3).reason == v::Refusal::None);
	const std::vector<v::Seated> gone = t.release_car(77);
	CHECK_EQ(gone.size(), size_t(2));
	CHECK_EQ(t.seat_of(1).car, v::kNoCar);
	CHECK_EQ(t.seat_of(2).car, v::kNoCar);
	CHECK_EQ(t.seat_of(3).car, uint16_t(78));
	CHECK(t.release_car(77).empty());
	CHECK_EQ(t.free_seat(78, 0), uint16_t(3));
	CHECK_EQ(t.free_seat(78, 0), v::kNoCharacter);
	CHECK_EQ(t.seated(), size_t(0));
}

TEST(vehicle_seats_switch)
{
	v::SeatTable t;
	REQUIRE(t.take(9, 3, 0, 1).reason == v::Refusal::None);
	REQUIRE(t.take(9, 3, 2, 2).reason == v::Refusal::None);
	CHECK(t.switch_seat(1, 1).reason == v::Refusal::None);
	CHECK_EQ(t.seat_of(1).seat, uint8_t(1));
	CHECK_EQ(t.driver_of(9), v::kNoCharacter);
	CHECK(t.switch_seat(1, 2).reason == v::Refusal::SeatTaken);
	CHECK(t.switch_seat(1, 3).reason == v::Refusal::NoSuchSeat);
	CHECK(t.switch_seat(1, 1).reason == v::Refusal::AlreadySeated); // where he sits now
	CHECK(t.switch_seat(5, 0).reason == v::Refusal::NotSeated);
	CHECK_EQ(t.seat_of(1).seat, uint8_t(1));
}

TEST(vehicle_seats_mirror_apply)
{
	// A player's machine keeps the same table from the VehicleSeat messages; it never refuses them.
	v::SeatTable t;
	t.apply(v::SeatMsg::granted(40, 0, 7));
	CHECK_EQ(t.driver_of(40), uint16_t(7));
	// a granted of a seated character moves him (a switch of seat is one granted)
	t.apply(v::SeatMsg::granted(40, 1, 7));
	CHECK_EQ(t.driver_of(40), v::kNoCharacter);
	CHECK_EQ(t.at(40, 1), uint16_t(7));
	const float at[3] = {0.f, 0.f, 0.f};
	// a release of somebody else's seat changes nothing
	t.apply(v::SeatMsg::released(40, 1, 8, v::Release::Exit, at));
	CHECK_EQ(t.at(40, 1), uint16_t(7));
	t.apply(v::SeatMsg::refused(40, 0, 9, v::Refusal::SeatTaken));
	CHECK_EQ(t.seated(), size_t(1));
	t.apply(v::SeatMsg::released(40, 1, 7, v::Release::Exit, at));
	CHECK_EQ(t.seated(), size_t(0));
}

// ---------------------------------------------------------------- verdicts

TEST(vehicle_enter_verdicts)
{
	CHECK(v::enter(good_enter()) == v::Refusal::None);

	struct Case
	{
		void (*spoil)(v::EnterFacts&);
		v::Refusal want;
	};
	const Case cases[] = {
		{[](v::EnterFacts& f) { f.car_known = false; }, v::Refusal::NoCar},
		{[](v::EnterFacts& f) { f.supported = false; }, v::Refusal::Unsupported},
		{[](v::EnterFacts& f) { f.car_destroyed = true; }, v::Refusal::Destroyed},
		{[](v::EnterFacts& f) { f.alive = false; }, v::Refusal::Dead},
		{[](v::EnterFacts& f) { f.wounded = true; }, v::Refusal::Wounded},
		{[](v::EnterFacts& f) { f.seated = true; }, v::Refusal::AlreadySeated},
		{[](v::EnterFacts& f) { f.carrying = true; }, v::Refusal::Carrying},
		{[](v::EnterFacts& f) { f.enter_locked = true; }, v::Refusal::Locked},
		{[](v::EnterFacts& f) { f.seat = 0; f.seat_free = false; }, v::Refusal::SeatTaken},
		{[](v::EnterFacts& f) { f.seat_free = false; }, v::Refusal::Full},
		{[](v::EnterFacts& f) { f.seat = 2; }, v::Refusal::NoSuchSeat},
		{[](v::EnterFacts& f) { f.distance = v::kEnterMaxDistance + 0.5f; }, v::Refusal::TooFar},
		{[](v::EnterFacts& f) { f.distance = std::numeric_limits<float>::quiet_NaN(); }, v::Refusal::TooFar},
		{[](v::EnterFacts& f) { f.since_last_ms = v::kRequestMinIntervalMs - 1; }, v::Refusal::TooSoon},
	};
	for (const Case& c : cases)
	{
		v::EnterFacts f = good_enter();
		c.spoil(f);
		CHECK_EQ(v::enter(f), c.want);
	}
	// exactly at the limits: allowed
	v::EnterFacts edge = good_enter();
	edge.distance = v::kEnterMaxDistance;
	edge.since_last_ms = v::kRequestMinIntervalMs;
	CHECK(v::enter(edge) == v::Refusal::None);
}

TEST(vehicle_enter_rules_before_trust)
{
	// A trust refusal ships in "log" (coop_trust): the request then goes through. So a rule refusal must win over it, or a
	// wounded player standing too far would be let in by a log build.
	v::EnterFacts f = good_enter();
	f.wounded = true;
	f.distance = v::kEnterMaxDistance * 3.f;
	f.since_last_ms = 0;
	CHECK(v::enter(f) == v::Refusal::Wounded);
	f.wounded = false;
	f.enter_locked = true;
	CHECK(v::enter(f) == v::Refusal::Locked);

	CHECK(v::is_trust(v::Refusal::TooFar));
	CHECK(v::is_trust(v::Refusal::TooSoon));
	for (uint8_t r = 0; r <= uint8_t(v::Refusal::Last); ++r)
	{
		const v::Refusal reason = v::Refusal(r);
		if (reason != v::Refusal::TooFar && reason != v::Refusal::TooSoon)
			CHECK(!v::is_trust(reason));
	}
}

TEST(vehicle_exit_verdicts)
{
	v::ExitFacts f;
	f.seated = true;
	f.exit_locked = false;
	f.since_last_ms = 5000;
	CHECK(v::exit(f) == v::Refusal::None);
	v::ExitFacts g = f;
	g.seated = false;
	CHECK(v::exit(g) == v::Refusal::NotSeated);
	g = f;
	g.exit_locked = true;
	CHECK(v::exit(g) == v::Refusal::ExitLocked);
	g = f;
	g.since_last_ms = 0;
	CHECK(v::exit(g) == v::Refusal::TooSoon);
	g.exit_locked = true; // the rule first
	CHECK(v::exit(g) == v::Refusal::ExitLocked);
}

TEST(vehicle_switch_verdicts)
{
	v::SwitchFacts f;
	f.seated = true;
	f.alive = true;
	f.wounded = false;
	f.seats = 3;
	f.from = 0;
	f.seat = 2;
	f.seat_free = true;
	f.since_last_ms = 5000;
	CHECK(v::switch_to(f) == v::Refusal::None);
	v::SwitchFacts g = f;
	g.seated = false;
	CHECK(v::switch_to(g) == v::Refusal::NotSeated);
	g = f;
	g.alive = false;
	CHECK(v::switch_to(g) == v::Refusal::Dead);
	g = f;
	g.wounded = true;
	CHECK(v::switch_to(g) == v::Refusal::Wounded);
	g = f;
	g.seat = 3;
	CHECK(v::switch_to(g) == v::Refusal::NoSuchSeat);
	g = f;
	g.seat_free = false;
	CHECK(v::switch_to(g) == v::Refusal::SeatTaken);
	g = f;
	g.seat = 0;
	CHECK(v::switch_to(g) == v::Refusal::AlreadySeated);
	g = f;
	g.since_last_ms = 1;
	CHECK(v::switch_to(g) == v::Refusal::TooSoon);
}

// ---------------------------------------------------------------- input rules

TEST(vehicle_input_sequence_wrap)
{
	CHECK(v::seq_newer(1, 0));
	CHECK(v::seq_newer(0, 255)); // wraps
	CHECK(v::seq_newer(3, 250));
	CHECK(!v::seq_newer(250, 250)); // a duplicate
	CHECK(!v::seq_newer(200, 250)); // older
	CHECK(!v::seq_newer(128, 0)); // half the ring away: not newer (ambiguous, dropped)
	CHECK(v::seq_newer(127, 0));

	v::InputTrack t;
	t.start(55, 1000);
	CHECK(t.accept(input(55, 1, v::kHeldForward), 1010).applied());
	CHECK(t.accept(input(55, 2, v::kHeldForward), 1020).applied());
	const v::InputStep dup = t.accept(input(55, 2, 0), 1030);
	CHECK(dup.drop == v::InputDrop::Old);
	CHECK_EQ(t.held(), v::kHeldForward); // the duplicate changed nothing
	const v::InputStep old = t.accept(input(55, 1, 0), 1040);
	CHECK(old.drop == v::InputDrop::Old);
	// across the wrap
	for (int s = 3; s <= 255; ++s)
		REQUIRE(t.accept(input(55, uint8_t(s), v::kHeldForward), uint32_t(1040 + s)).applied());
	CHECK(t.accept(input(55, 0, v::kHeldBack), 1300).applied());
	CHECK_EQ(t.held(), v::kHeldBack);
	// another car's input is not his
	CHECK(t.accept(input(56, 1, 0), 1310).drop == v::InputDrop::WrongCar);
	// before start nothing is driven
	v::InputTrack idle;
	CHECK(idle.accept(input(55, 1, v::kHeldForward), 10).drop == v::InputDrop::NotDriving);
	CHECK(!idle.tick(100000).applied());
}

TEST(vehicle_input_step_says_what_changed)
{
	v::InputTrack t;
	t.start(3, 0);
	v::InputStep s = t.accept(input(3, 1, v::kHeldForward | v::kHeldRight), 10);
	REQUIRE(s.applied());
	CHECK_EQ(s.before, uint16_t(0));
	CHECK_EQ(s.held, uint16_t(v::kHeldForward | v::kHeldRight));
	s = t.accept(input(3, 2, v::kHeldBack), 20);
	REQUIRE(s.applied());
	CHECK_EQ(s.before, uint16_t(v::kHeldForward | v::kHeldRight));
	CHECK_EQ(s.held, v::kHeldBack);
	// the aim flag is a layout bit, never a held key
	v::InputMsg m = input(3, 3, v::kHeldWeapon | v::kHeldFire);
	m.set_aim(0.5f, 0.1f);
	s = t.accept(m, 30);
	REQUIRE(s.applied());
	CHECK_EQ(s.held, uint16_t(v::kHeldWeapon | v::kHeldFire));
	CHECK(s.aim);
	CHECK_EQ(s.aim_yaw, m.aim_yaw);
	CHECK_EQ(s.aim_pitch, m.aim_pitch);
}

TEST(vehicle_input_stale_releases_and_brakes)
{
	v::InputTrack t;
	t.start(12, 1000);
	REQUIRE(t.accept(input(12, 1, v::kHeldForward | v::kHeldLeft | v::kHeldFire), 1100).applied());
	CHECK(!t.tick(1100 + v::kInputStaleMs - 1).applied());
	const v::InputStep stale = t.tick(1100 + v::kInputStaleMs);
	REQUIRE(stale.applied());
	CHECK(stale.stale);
	CHECK_EQ(stale.before, uint16_t(v::kHeldForward | v::kHeldLeft | v::kHeldFire));
	CHECK_EQ(stale.held, v::kHeldBrake); // every key released, the hand brake pressed
	CHECK_EQ(t.held(), v::kHeldBrake);
	CHECK(t.is_stale());
	// once: the next ticks change nothing
	CHECK(!t.tick(1100 + v::kInputStaleMs * 4).applied());
	// fresh input after the gap is taken whatever its seq (the driver's counter ran on while it was lost)
	const v::InputStep back = t.accept(input(12, 1, v::kHeldForward), 5000);
	REQUIRE(back.applied());
	CHECK(back.resync);
	CHECK_EQ(back.before, v::kHeldBrake);
	CHECK_EQ(back.held, v::kHeldForward);
	CHECK(!t.is_stale());
	// and normal ordering again
	CHECK(t.accept(input(12, 1, 0), 5010).drop == v::InputDrop::Old);
}

TEST(vehicle_input_stale_after_start_without_input)
{
	// A driver who never sends: the car is held by the hand brake half a second after the grant.
	v::InputTrack t;
	t.start(4, 0);
	CHECK(!t.tick(v::kInputStaleMs - 1).applied());
	const v::InputStep s = t.tick(v::kInputStaleMs);
	REQUIRE(s.applied());
	CHECK_EQ(s.before, uint16_t(0));
	CHECK_EQ(s.held, v::kHeldBrake);
}

TEST(vehicle_input_stale_keeps_the_weapon_switch)
{
	// kWPN_FUNC is a switch (CarInput.cpp: Action(eWpnActivate, !IsActive()) on press, nothing on release), not a held key.
	v::InputTrack t;
	t.start(4, 0);
	REQUIRE(t.accept(input(4, 1, v::kHeldWeapon | v::kHeldFire | v::kHeldBack), 10).applied());
	const v::InputStep s = t.tick(10 + v::kInputStaleMs);
	REQUIRE(s.applied());
	CHECK_EQ(s.held, uint16_t(v::kHeldBrake | v::kHeldWeapon));
}

TEST(vehicle_input_edges_applied_once)
{
	v::InputTrack t;
	t.start(8, 0);
	uint8_t edges = 0;
	edges = v::bump_edge(edges, v::Edge::Engine);
	v::InputStep s = t.accept(input(8, 1, 0, edges), 10);
	REQUIRE(s.applied());
	CHECK_EQ(s.engine_toggles, uint8_t(1));
	CHECK_EQ(s.lights_toggles, uint8_t(0));
	// the same counters again (the next repeat of the driver): nothing more
	s = t.accept(input(8, 2, 0, edges), 20);
	REQUIRE(s.applied());
	CHECK_EQ(s.engine_toggles, uint8_t(0));
	// a lost message does not lose a press: the counters carry it
	edges = v::bump_edge(edges, v::Edge::Lights); // sent as seq 3, lost
	edges = v::bump_edge(edges, v::Edge::Lights); // seq 4 arrives
	edges = v::bump_edge(edges, v::Edge::Horn);
	s = t.accept(input(8, 4, 0, edges), 40);
	REQUIRE(s.applied());
	CHECK_EQ(s.lights_toggles, uint8_t(2));
	CHECK_EQ(s.horns, uint8_t(1));
	CHECK_EQ(s.engine_toggles, uint8_t(0));
	// an old message never replays one
	s = t.accept(input(8, 3, 0, v::bump_edge(0, v::Edge::Engine)), 50);
	CHECK(s.drop == v::InputDrop::Old);
	CHECK_EQ(s.engine_toggles, uint8_t(0));
	// a new seating starts the counters from zero (the client starts them at the grant)
	t.start(8, 100);
	s = t.accept(input(8, 1, 0, v::bump_edge(0, v::Edge::Engine)), 110);
	REQUIRE(s.applied());
	CHECK_EQ(s.engine_toggles, uint8_t(1));
}

TEST(vehicle_input_rate_cap)
{
	v::RateGate g;
	uint32_t admitted = 0;
	for (uint32_t i = 0; i < v::kInputBurst + 5; ++i)
		if (g.admit(1000))
			++admitted;
	CHECK_EQ(admitted, v::kInputBurst); // a burst, then the cap
	CHECK(!g.admit(1000));
	// one message's worth of time later: one more
	const uint32_t one = (1000 + v::kInputRatePerSec - 1) / v::kInputRatePerSec;
	CHECK(g.admit(1000 + one));
	CHECK(!g.admit(1000 + one));
	// a steady sender at the client's own cap is never refused
	v::RateGate steady;
	bool all = true;
	for (uint32_t t = 0; t < 10000; t += v::kInputMinIntervalMs)
		all = steady.admit(t) && all;
	CHECK(all);
	// after a long pause the bucket is full again, no more
	uint32_t after_pause = 0;
	for (uint32_t i = 0; i < v::kInputBurst * 3; ++i)
		if (g.admit(600000))
			++after_pause;
	CHECK_EQ(after_pause, v::kInputBurst);
}

// ---------------------------------------------------------------- names and constants

TEST(vehicle_names)
{
	for (uint8_t r = 0; r <= uint8_t(v::Refusal::Last); ++r)
	{
		const char* n = v::refusal_name(v::Refusal(r));
		CHECK(n && *n && std::strcmp(n, "?") != 0);
	}
	for (uint8_t r = 1; r <= uint8_t(v::Release::Last); ++r)
	{
		const char* n = v::release_name(v::Release(r));
		CHECK(n && *n && std::strcmp(n, "?") != 0);
	}
	CHECK_EQ(std::string(v::refusal_name(v::Refusal(200))), std::string("?"));
	CHECK_EQ(std::string(v::release_name(v::Release(0))), std::string("?"));
	CHECK_EQ(std::string(v::op_name(v::ReqOp::SwitchSeat)), std::string("switch_seat"));
	CHECK_EQ(std::string(v::op_name(v::SeatOp::Released)), std::string("released"));
	// the coop_trust check names (mod_system_coop_trust.ltx keys): stable, one per trust refusal
	CHECK_EQ(std::string(v::trust_name(v::Refusal::TooFar)), std::string("veh_enter_distance"));
	CHECK_EQ(std::string(v::trust_name(v::Refusal::TooSoon)), std::string("veh_request_rate"));
	CHECK_EQ(std::string(v::kTrustInputRate), std::string("veh_input_rate"));
	CHECK(v::trust_name(v::Refusal::Wounded) == nullptr);
}

// The client repeats input faster than the decider calls it stale, its own cap stays under the decider's, and the seat
// markers never collide with a seat.
static_assert(v::kInputRepeatMs * 2 <= v::kInputStaleMs, "two repeats fit before stale");
static_assert(1000 / v::kInputMinIntervalMs <= v::kInputRatePerSec, "the client's cap is under the decider's");
static_assert(v::kMaxSeats <= v::kNoSeat && v::kNoSeat < v::kAnySeat, "kNoSeat / kAnySeat are no seats");
static_assert(v::kMaxPitchWire == 16384, "pi / 2 on the i16 scale");
