// Fixture for test_story_worldstate.py. The packet readers and receivers come from coop_worldstate.cpp.
#include "coop_relay_rules.h"
#include "support/fake_mode.h"

#include <cstdio>
#include <string_view>

using u64 = uint64_t;
using u32 = uint32_t;
using s64 = int64_t;
template<class T> using xr_set = std::set<T>;
template<class K, class V> using xr_map = std::map<K, V>;

bool _valid(float value) { return std::isfinite(value); }
void Msg(const char*, ...) {}

namespace coop
{
namespace
{
t::FakeMode* current_mode = nullptr;
}

Mode& mode() { return *current_mode; }

namespace worldstate
{
namespace
{
constexpr u64 kArrival = 773;

struct Manager
{
	bool running;
	bool active() const { return running; }
	u64 now_ms() const { return kArrival; }
};
Manager manager{};
const Manager& mgr() { return manager; }

struct RawWeather {}; // The host's fingerprint is unused by these receivers.
// WORLDSTATE_TYPES
State g;

struct ThunderboltEffect
{
	unsigned calls = 0;
	relay::BoltMsg last;
	bool CoopBolt(const char* id, float period, float duration, u32 seed)
	{
		++calls;
		last = {id, period, duration, seed};
		return true;
	}
};
struct CEnvironment
{
	bool CurrentEnv = true;
	ThunderboltEffect* eff_Thunderbolt;
};
struct GamePersistent
{
	CEnvironment env;
	CEnvironment& Environment() { return env; }
};
GamePersistent* g_pGamePersistent = nullptr;

// WORLDSTATE_HANDLERS

constexpr u64 kHostClock = 1103;

bool time_sync(PeerId sender, bool accept)
{
	Writer packet;
	packet.u64(12345678);
	packet.f32(5.f);
	packet.u64(kHostClock);
	packet.u8(1);
	Reader input(packet.data().data(), packet.data().size());
	client_on_time_sync(sender, input);
	if (!accept)
		return input.remaining() == packet.data().size() && !g.have_time && !g.time_pending && g.rx_time_at == 0;
	return input.ok() && input.remaining() == 0 && g.have_time && g.time_pending && g.rx_time_at == kArrival &&
	    g.rx_time.game_time == 12345678 && g.rx_time.factor == 5.f && g.rx_time.host_clock == kHostClock && g.rx_time.paused;
}

bool weather_sync(PeerId sender, bool accept)
{
	Writer packet;
	packet.str("storm");
	packet.str("");
	packet.f32(0.f);
	packet.str("storm");
	packet.str("15:00:00");
	packet.f32(54000.f);
	packet.str("storm");
	packet.str("16:00:00");
	packet.f32(57600.f);
	packet.f32(0.5f);
	packet.u64(kHostClock);
	Reader input(packet.data().data(), packet.data().size());
	client_on_weather_sync(sender, input);
	if (!accept)
		return input.remaining() == packet.data().size() && !g.have_weather && !g.weather_pending && g.rx_weather_at == 0;
	return input.ok() && input.remaining() == 0 && g.have_weather && g.weather_pending && g.rx_weather_at == kArrival &&
	    g.rx_weather.cycle == "storm" && g.rx_weather.env[0].id == "15:00:00" &&
	    g.rx_weather.env[1].exec_time == 57600.f && g.rx_weather.blend == 0.5f && g.rx_weather.host_clock == kHostClock;
}

bool thunderbolt(PeerId sender, bool accept)
{
	ThunderboltEffect effect;
	GamePersistent game{{true, &effect}};
	g_pGamePersistent = &game;
	Writer packet;
	packet.str("storm_bolt");
	packet.f32(3.f);
	packet.f32(0.25f);
	packet.u32(0xcafe);
	Reader input(packet.data().data(), packet.data().size());
	client_on_thunderbolt(sender, input);
	g_pGamePersistent = nullptr;
	if (!accept)
		return input.remaining() == packet.data().size() && effect.calls == 0;
	return input.ok() && input.remaining() == 0 && effect.calls == 1 && effect.last.id == "storm_bolt" &&
	    effect.last.period == 3.f && effect.last.duration == 0.25f && effect.last.seed == 0xcafe;
}

unsigned passed = 0;
unsigned failed = 0;

void check_receivers(const char* process, bool active, bool accepts_host)
{
	t::FakeMode fake(t::mode_case(process));
	current_mode = &fake;
	manager.running = active;
	const struct Receiver
	{
		const char* name;
		bool (*check)(PeerId, bool);
	} receivers[] = {{"TimeSync", time_sync}, {"WeatherSync", weather_sync}, {"Thunderbolt", thunderbolt}};
	for (const Receiver& receiver : receivers)
	{
		for (PeerId sender : {kHostPeer, PeerId{17}})
		{
			g = {};
			const bool accept = sender == kHostPeer && accepts_host;
			if (receiver.check(sender, accept))
				++passed;
			else
			{
				++failed;
				std::printf("FAIL %s %s sender %u (expected %s)\n", process, receiver.name, unsigned(sender),
				    accept ? "acceptance" : "rejection");
			}
		}
	}
	current_mode = nullptr;
}
} // namespace
} // namespace worldstate
} // namespace coop

int main()
{
	using namespace coop::worldstate;
	// Independent expectations for reception from the world authority, not the fake's mode answers.
	constexpr bool coop_host = false, coop_client = true, world_server = false, map_server = true,
	               server_client = true, none = false;
#define CHECK_PROCESS(role) check_receivers(#role, std::string_view(#role) != "none", role);
	MODE_CASES(CHECK_PROCESS)
#undef CHECK_PROCESS
	std::printf("%u passed, %u failed\n", passed, failed);
	return failed ? 1 : 0;
}
