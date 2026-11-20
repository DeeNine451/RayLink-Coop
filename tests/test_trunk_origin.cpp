// Anomaly Coop unit tests: where a spawn the trunk passes on comes from (build 57, protocol 33, step S3 of
// docs/plans/2026-11-18-two-modes.md, unit A-S3P; TZ 6.3: "the psy phantoms of a bloodsucker are unseen" in the server mode).
//
// The cause (coop_entities.cpp client_on_spawn, written there since build 51): a psy phantom (phantom_manager spawn_dynamic_phantom:
// level.spawn_item with no level vertex and no game vertex) is in no level registry, so no switch manager ever brings it online; a
// player's machine brings it online at its EntitySpawn only when the sender's online flag speaks of the level he stands on
// (xrCoop/coop_mirror.h placement: flag_of_this_level). In the co-op the sender is the host and he is on that level. In the server
// mode a player on a map server's level got the spawn twice, both from kHostPeer: the map server's (up the trunk in a Tunnel, its
// flag is about his level) and the world server's own copy (online 0: its copy is offline there). Neither told him whose flag it
// was, so the phantom stayed on the vote, unseen.
//
// The fix, server side: the world server passes a map server's EntitySpawn on to a player of that level with its online byte 2,
// "online at the authority of the level you stand on" (mark_spawn_of_your_level, coop_trunk.cpp), and it sends that level's players
// no copy of its own of what that map server spawned (coop_entities.cpp host_spawn_from_leader: EchoOf on the deferred spawn). A
// co-op host never writes 2: the co-op path reads 0 and 1 as before.
#include "test_util.h"
#include "srv/coop_levels_wire.h"
#include "coop_mirror.h"
#include "coop_protocol.h"

#include <cstddef>
#include <cstdint>
#include <vector>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
constexpr uint16_t kNoVertex = 0xFFFF;

// A carried packet as Session::tunnel_up packs it: the message's type, then its layout. EntitySpawn is write_spawn's
// (coop_entities.cpp): u16 id, u16 parent, u8 online, the placement (3 floats, 3 floats, u32 node, u16 game vertex), the spawn
// and the update packets (u16 size, bytes), the clone's initial state (empty here).
std::vector<uint8_t> packet_of(Msg type, uint16_t id, uint16_t parent, uint8_t online, uint16_t graph = kNoVertex)
{
	Writer w;
	w.u16(uint16_t(type));
	w.u16(id);
	w.u16(parent);
	w.u8(online);
	const float pos[3] = {12.f, -3.f, 400.f};
	const float ang[3] = {0.f, 1.5f, 0.f};
	w.vec3(pos);
	w.vec3(ang);
	w.u32(0xFFFFFFFFu);
	w.u16(graph);
	w.u16(2);
	w.u8(0xAB);
	w.u8(0xCD);
	w.u16(1);
	w.u8(0xEF);
	w.u8(0);
	return w.data();
}

// What a player's machine reads of the online byte (coop_entities.cpp client_on_spawn).
struct Word
{
	bool online = false;
	bool of_my_level = false;
};

Word read_word(const std::vector<uint8_t>& packet)
{
	Reader r(packet.data() + 2, packet.size() - 2);
	r.u16();
	r.u16();
	const uint8_t word = r.u8();
	Word out;
	out.online = word != 0;
	out.of_my_level = word == kSpawnOnlineAtYourLevel;
	return out;
}

// A free psy phantom on a player's machine: no holder, no game vertex here, switches alone. `host_on_my_level`: the sender is a
// co-op host on this level (false in the server mode: the world server stands on no level of LevelMap).
mirror::Placement place_free_phantom(const Word& w, bool host_on_my_level)
{
	return mirror::placement(false, w.online, false, false, false, w.of_my_level || host_on_my_level, true);
}
} // namespace

TEST(trunk_origin_spawn_of_his_level_is_marked)
{
	std::vector<uint8_t> p = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1);
	const std::vector<uint8_t> before = p;
	CHECK_EQ(int(kSpawnOnlineAtYourLevel), 2);
	CHECK_EQ(kSpawnOnlineByte, size_t(6));
	CHECK(mark_spawn_of_your_level(p));
	REQUIRE(p.size() == before.size());
	for (size_t i = 0; i < p.size(); ++i)
		CHECK_EQ(int(p[i]), int(i == kSpawnOnlineByte ? kSpawnOnlineAtYourLevel : before[i])); // the online byte alone
	CHECK(mark_spawn_of_your_level(p)); // marking twice changes nothing more
	CHECK_EQ(int(p[kSpawnOnlineByte]), int(kSpawnOnlineAtYourLevel));
}

TEST(trunk_origin_offline_spawn_stays_offline)
{
	std::vector<uint8_t> p = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 0);
	const std::vector<uint8_t> before = p;
	CHECK(!mark_spawn_of_your_level(p));
	CHECK(p == before);
}

TEST(trunk_origin_other_messages_and_cut_spawns_untouched)
{
	// EntitySwitch has its online byte elsewhere (u16 id, u8 online): never touched
	for (const Msg type : {Msg::EntitySwitch, Msg::EntityDestroy, Msg::EntitySnapshot, Msg::StateDump, Msg::PlayerState})
	{
		std::vector<uint8_t> p = packet_of(type, 2101, 0xFFFF, 1);
		const std::vector<uint8_t> before = p;
		CHECK(!mark_spawn_of_your_level(p));
		CHECK(p == before);
	}
	// an EntitySpawn cut before its online byte: nothing to mark, nothing written past its end
	const std::vector<uint8_t> whole = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1);
	for (size_t n = 0; n <= kSpawnOnlineByte; ++n)
	{
		std::vector<uint8_t> p(whole.begin(), whole.begin() + std::ptrdiff_t(n));
		const std::vector<uint8_t> before = p;
		CHECK(!mark_spawn_of_your_level(p));
		CHECK(p == before);
	}
	std::vector<uint8_t> just = std::vector<uint8_t>(whole.begin(), whole.begin() + std::ptrdiff_t(kSpawnOnlineByte + 1));
	CHECK(mark_spawn_of_your_level(just)); // the byte is there: marked (the reader refuses the rest of a cut spawn)
	CHECK_EQ(int(just.back()), int(kSpawnOnlineAtYourLevel));
}

TEST(trunk_origin_marked_spawn_goes_through_a_tunnel_and_reads_online)
{
	TunnelMsg m;
	m.peer = 3;
	m.packet = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1);
	CHECK(mark_spawn_of_your_level(m.packet));
	Writer w;
	REQUIRE(m.write(w));
	Reader r(w.data().data(), w.data().size());
	TunnelMsg back;
	REQUIRE(back.read(r));
	CHECK(back.type() == Msg::EntitySpawn);
	CHECK(back.packet == m.packet);
	// the reader of build 57 and older (Reader::boolean) takes 2 for online, as it took 1
	Reader old(back.packet.data() + 2 + 4, back.packet.size() - 6);
	CHECK(old.boolean());
	const Word word = read_word(back.packet);
	CHECK(word.online);
	CHECK(word.of_my_level);
}

TEST(trunk_origin_a_phantom_of_his_map_server_comes_online_at_once)
{
	// server mode, after the fix: the one spawn he gets is his map server's, marked
	std::vector<uint8_t> his = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1);
	CHECK(mark_spawn_of_your_level(his));
	CHECK(place_free_phantom(read_word(his), false) == mirror::Placement::OnlineNow);
	// server mode before the fix (protocol 32): the same spawn unmarked stayed on the vote, unseen
	CHECK(place_free_phantom(read_word(packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1)), false) == mirror::Placement::SwitchVote);
	// and the world server's own copy (its copy is offline there): offline; it no longer goes to the players of that level
	CHECK(place_free_phantom(read_word(packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 0)), false) == mirror::Placement::Offline);
	// a player on another level gets the world server's copy alone: offline, as before
	std::vector<uint8_t> world = packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 0);
	CHECK(!mark_spawn_of_your_level(world));
	CHECK(place_free_phantom(read_word(world), false) == mirror::Placement::Offline);
}

TEST(trunk_origin_the_coop_path_is_as_before)
{
	// a co-op host writes 0 or 1 and stands on the client's level: online at once, as since build 51
	const Word on = read_word(packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 1));
	CHECK(on.online && !on.of_my_level);
	CHECK(place_free_phantom(on, true) == mirror::Placement::OnlineNow);
	const Word off = read_word(packet_of(Msg::EntitySpawn, 2101, 0xFFFF, 0));
	CHECK(!off.online && !off.of_my_level);
	CHECK(place_free_phantom(off, true) == mirror::Placement::Offline);
	// a squad never comes online by itself (issue 1293), marked or not
	std::vector<uint8_t> squad = packet_of(Msg::EntitySpawn, 2200, 0xFFFF, 1);
	CHECK(mark_spawn_of_your_level(squad));
	const Word w = read_word(squad);
	CHECK(mirror::placement(false, w.online, false, false, false, w.of_my_level, false) == mirror::Placement::SwitchVote);
	// an object with a game vertex is in this level's registry: the switch manager takes it, marked or not
	CHECK(mirror::placement(false, w.online, false, false, true, w.of_my_level, true) == mirror::Placement::SwitchVote);
}
