// Anomaly Coop unit tests: what a client gets of the host's creatures, and how (xrCoop/coop_relay_rules.h; parity audits
// 2026-10-31: H3, M5, W2, W3, W8, F6, F7).
#include "test_util.h"

#include "coop_relay_rules.h"

#include <cmath>

using namespace coop::relay;
using coop::Reader;
using coop::Writer;

TEST(relay_bolt_round_trip)
{
	BoltMsg in;
	in.id = "thunderbolts_rain";
	in.period = 12.5f;
	in.duration = 0.75f;
	in.seed = 0xA1B2C3D4u;
	Writer w(32);
	write_bolt(w, in);
	Reader r(w.ptr(), w.size());
	BoltMsg out;
	CHECK(read_bolt(r, out));
	CHECK(out.id == in.id);
	CHECK(out.period == in.period);
	CHECK(out.duration == in.duration);
	CHECK(out.seed == in.seed);
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(relay_bolt_refuses_what_could_not_be_a_bolt)
{
	BoltMsg out;
	{
		Writer w(8);
		w.str("x"); // no numbers
		Reader r(w.ptr(), w.size());
		CHECK(!read_bolt(r, out));
	}
	{
		BoltMsg in; // no collection: the engine would look it up and find nothing
		Writer w(32);
		write_bolt(w, in);
		Reader r(w.ptr(), w.size());
		CHECK(!read_bolt(r, out));
	}
	{
		BoltMsg in;
		in.id = "a";
		in.period = std::nanf("");
		Writer w(32);
		write_bolt(w, in);
		Reader r(w.ptr(), w.size());
		CHECK(!read_bolt(r, out));
	}
	{
		BoltMsg in;
		in.id = "a";
		in.duration = -1.f; // a negative life time never ends
		Writer w(32);
		write_bolt(w, in);
		Reader r(w.ptr(), w.size());
		CHECK(!read_bolt(r, out));
	}
}

TEST(relay_bucket_starts_full_and_refills_by_the_clock)
{
	Bucket b;
	CHECK(b.take(1000, 10.f, 2.f));
	CHECK(b.take(1000, 10.f, 2.f));
	CHECK(!b.take(1000, 10.f, 2.f));
	CHECK(!b.take(1050, 10.f, 2.f)); // half a token
	CHECK(b.take(1100, 10.f, 2.f));
	CHECK(b.take(100000, 10.f, 2.f));
	CHECK(b.take(100000, 10.f, 2.f)); // a long pause gives the burst, no more
	CHECK(!b.take(100000, 10.f, 2.f));
}

TEST(relay_line_distance_measures_the_segment_of_the_shot)
{
	const Vec from{0.f, 0.f, 0.f}, dir{0.f, 0.f, 1.f};
	CHECK(line_distance(from, dir, 100.f, Vec{5.f, 0.f, 50.f}) == 5.f);
	CHECK(line_distance(from, dir, 100.f, Vec{0.f, 0.f, -7.f}) == 7.f); // behind the muzzle
	CHECK(line_distance(from, dir, 100.f, Vec{0.f, 3.f, 104.f}) == 5.f); // past the bullet's end
}

TEST(relay_a_shot_near_the_client_brings_its_bullets)
{
	ShotBudget b;
	const ShotPlan p = b.plan(1000, 100.f, 100.f, 1, false);
	CHECK(p.send);
	CHECK(p.bullets);
	CHECK(!p.firm);
}

TEST(relay_a_far_muzzle_shows_bullets_only_when_it_fires_at_the_client)
{
	ShotBudget b;
	CHECK(!b.plan(1000, 300.f, 100.f, 1, false).bullets);
	const ShotPlan at_him = b.plan(1000, 300.f, 10.f, 1, false);
	CHECK(at_him.send);
	CHECK(at_him.bullets);
}

TEST(relay_nothing_past_the_shot_range)
{
	ShotBudget b;
	const ShotPlan p = b.plan(1000, kNpcShotRange + 1.f, 0.f, 1, true);
	CHECK(!p.send);
	CHECK(!p.bullets);
	CHECK(!p.firm);
}

TEST(relay_bullets_are_limited_shots_are_not)
{
	ShotBudget b;
	uint32_t with_bullets = 0;
	for (int i = 0; i < 200; ++i)
	{
		const ShotPlan p = b.plan(1000, 50.f, 50.f, 1, false);
		CHECK(p.send); // the sound of a near fight never thins
		with_bullets += p.bullets ? 1 : 0;
	}
	CHECK_EQ(with_bullets, uint32_t(kBulletsBurst));
	CHECK(b.plan(2000, 50.f, 50.f, 1, false).bullets); // and the bucket fills again
}

TEST(relay_a_burst_of_pellets_costs_each_pellet)
{
	ShotBudget b;
	CHECK(b.plan(1000, 50.f, 50.f, uint32_t(kBulletsBurst), false).bullets);
	CHECK(!b.plan(1000, 50.f, 50.f, 1, false).bullets);
}

TEST(relay_a_far_fight_thins_to_its_rate)
{
	ShotBudget b;
	uint32_t sent = 0;
	for (int i = 0; i < 100; ++i)
		sent += b.plan(1000, 400.f, 400.f, 1, false).send ? 1 : 0;
	CHECK_EQ(sent, uint32_t(kFarShotsBurst));
}

TEST(relay_budgets_are_per_client)
{
	ShotBudget a, b;
	for (int i = 0; i < 200; ++i)
		a.plan(1000, 50.f, 50.f, 1, false);
	CHECK(!a.plan(1000, 50.f, 50.f, 1, false).bullets);
	CHECK(b.plan(1000, 50.f, 50.f, 1, false).bullets);
}

TEST(relay_only_a_shot_that_opens_a_burst_goes_firm_and_only_a_few)
{
	ShotBudget b;
	CHECK(!b.plan(1000, 50.f, 50.f, 1, false).firm);
	uint32_t firm = 0;
	for (int i = 0; i < 50; ++i)
		firm += b.plan(1000, 50.f, 50.f, 1, true).firm ? 1 : 0;
	CHECK_EQ(firm, uint32_t(kFirmBurst));
}

TEST(relay_opens_burst_goes_by_the_shooters_gap)
{
	uint64_t last = 0;
	CHECK(opens_burst(1000, last));
	CHECK(!opens_burst(1100, last));
	CHECK(!opens_burst(1400, last));
	CHECK(opens_burst(1400 + kBurstGapMs, last));
}

TEST(relay_long_voices_and_last_sounds_matter)
{
	CHECK(!sound_matters(0.4f, false));
	CHECK(sound_matters(kLongSoundSec, false));
	CHECK(sound_matters(0.2f, true));
}

TEST(relay_weapon_sounds_have_stable_indices_both_ways)
{
	size_t n = 0;
	const char* const* names = weapon_sounds(n);
	CHECK(n > 0 && n < size_t(kNoWeaponSound));
	for (size_t i = 0; i < n; ++i)
	{
		CHECK_EQ(size_t(weapon_sound_index(names[i])), i);
		CHECK(!std::strcmp(weapon_sound_alias(uint8_t(i)), names[i]));
	}
	CHECK(weapon_sound_alias(uint8_t(n)) == nullptr);
	CHECK(weapon_sound_alias(kNoWeaponSound) == nullptr);
}

TEST(relay_weapon_sounds_leave_out_what_a_puppet_plays_itself)
{
	CHECK(weapon_sound_index("sndShow") == kNoWeaponSound);
	CHECK(weapon_sound_index("sndHide") == kNoWeaponSound);
	CHECK(weapon_sound_index("sndShotG") == kNoWeaponSound); // the launcher has its own kind
	CHECK(weapon_sound_index(nullptr) == kNoWeaponSound);
	CHECK(weapon_sound_index("sndReload") != kNoWeaponSound);
	CHECK(weapon_sound_index("sndClickMisfire") != kNoWeaponSound);
}

TEST(relay_heli_health_byte_round_trips_within_a_step)
{
	CHECK_EQ(int(heli_health_byte(1.f)), 255);
	CHECK_EQ(int(heli_health_byte(0.f)), 0);
	CHECK_EQ(int(heli_health_byte(-3.f)), 0);
	CHECK_EQ(int(heli_health_byte(7.f)), 255);
	CHECK(std::fabs(heli_health(heli_health_byte(0.5f)) - 0.5f) < 0.01f);
}

TEST(relay_a_heli_barrel_outlasts_one_lost_report)
{
	CHECK(kHeliTrackMs > 2 * kHeliStateMs);
	CHECK(HeliAiming != HeliEngine && HeliAiming != HeliLight && HeliAiming != HeliSmoke && HeliAiming != HeliDead);
	HeliReport r;
	CHECK(r.due(1000, HeliEngine, 200));
	CHECK(!r.due(1100, HeliEngine, 200));
	CHECK(r.due(1200, HeliEngine | HeliAiming, 200)); // it took a target: at once, not at the next second
}

TEST(relay_heli_state_goes_out_on_change_and_every_second)
{
	HeliReport r;
	CHECK(r.due(1000, HeliEngine, 255));
	CHECK(!r.due(1100, HeliEngine, 255));
	CHECK(r.due(1200, HeliEngine | HeliSmoke, 255)); // news at once
	CHECK(r.due(1300, HeliEngine | HeliSmoke, 200));
	CHECK(!r.due(1300 + kHeliStateMs - 1, HeliEngine | HeliSmoke, 200));
	CHECK(r.due(1300 + kHeliStateMs, HeliEngine | HeliSmoke, 200)); // a client that joined, a lost packet
}

TEST(relay_lamp_book_keeps_the_last_word)
{
	LampBook b;
	CHECK(b.note(7, 0));
	CHECK(!b.note(7, 0));
	CHECK(b.note(7, LampOn));
	CHECK_EQ(b.size(), size_t(1));
	CHECK_EQ(int(b.lamps().at(7)), int(LampOn));
	b.clear();
	CHECK_EQ(b.size(), size_t(0));
}

TEST(relay_the_end_of_a_flicker_is_news_only_against_an_older_word)
{
	LampBook b;
	CHECK(!b.note(7, LampOn, true)); // every machine lit it by itself
	CHECK_EQ(b.size(), size_t(0));
	CHECK(b.note(7, 0));
	CHECK(b.note(7, LampOn, true)); // the host had it off and the flicker's end lit it: the clients hold it off otherwise
	CHECK(!b.note(7, LampOn, true));
}

TEST(relay_lamp_message_round_trips)
{
	const LampEntry in[] = {{7, LampOn}, {65000, LampDead}, {9, 0}};
	Writer w(16);
	write_lamps(w, in, 3);
	Reader r(w.ptr(), w.size());
	std::vector<LampEntry> out;
	CHECK(read_lamps(r, out));
	CHECK_EQ(out.size(), size_t(3));
	CHECK_EQ(int(out[1].id), 65000);
	CHECK_EQ(int(out[1].state), int(LampDead));
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(relay_lamp_message_refuses_what_is_not_a_lamp_list)
{
	std::vector<LampEntry> out;
	{
		Writer w(8);
		w.varu(1);
		w.u16(7); // no state
		Reader r(w.ptr(), w.size());
		CHECK(!read_lamps(r, out));
	}
	{
		Writer w(8);
		w.varu(1);
		w.u16(7);
		w.u8(0x80); // unknown bit
		Reader r(w.ptr(), w.size());
		CHECK(!read_lamps(r, out));
		CHECK(out.empty());
	}
	{
		Writer w(8);
		w.varu(kMaxLampsPerMsg + 1);
		Reader r(w.ptr(), w.size());
		CHECK(!read_lamps(r, out));
	}
}
