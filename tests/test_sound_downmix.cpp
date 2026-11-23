// Anomaly Coop unit tests: a stereo source played as a positional sound, sm_Mono3D (TZ R59, section 6.14;
// xrSound/SoundRender_downmix.h). OpenAL positions only mono buffers, so the sound target mixes each stereo block down to mono
// as it streams: the mean of L and R. The emitter keeps counting in the source's stereo bytes, so the mixed sound must last
// exactly as long as the source, end on time and never drift between channels. Without the flag every sound plays as in stock.
#include "test_util.h"

#include "../engine/src/xrSound/SoundRender_downmix.h"

#include <cstring>

using namespace sound_downmix;

namespace
{
void put(std::vector<uint8_t>& v, size_t at, int16_t s)
{
	const uint16_t u = uint16_t(s);
	v[at] = uint8_t(u & 0xff);
	v[at + 1] = uint8_t(u >> 8);
}

int16_t get(const std::vector<uint8_t>& v, size_t at)
{
	return int16_t(uint16_t(v[at]) | uint16_t(uint16_t(v[at + 1]) << 8));
}

struct Frame
{
	int16_t l, r;
};

// Interleaved 16-bit little-endian stereo PCM, as ov_read hands it to the cache (word 2, little endian).
std::vector<uint8_t> stereo(std::initializer_list<Frame> frames)
{
	std::vector<uint8_t> v(frames.size() * kStereoFrameBytes);
	size_t at = 0;
	for (const Frame& f : frames)
	{
		put(v, at, f.l);
		put(v, at + 2, f.r);
		at += kStereoFrameBytes;
	}
	return v;
}
} // namespace

TEST(sound_downmix_mean_of_both_channels)
{
	CHECK_EQ(mix(100, 200), int16_t(150));
	CHECK_EQ(mix(-100, -300), int16_t(-200));
	CHECK_EQ(mix(1000, -1000), int16_t(0));
	CHECK_EQ(mix(0, 0), int16_t(0));
	CHECK_EQ(mix(1234, 1234), int16_t(1234)); // dual mono stays at its level
	CHECK_EQ(mix(-7, -7), int16_t(-7));
	CHECK_EQ(mix(500, 0), int16_t(250)); // one-sided: half
	// an odd sum is truncated toward zero, the same on both signs (no drift of the DC level)
	CHECK_EQ(mix(1, 2), int16_t(1));
	CHECK_EQ(mix(-1, -2), int16_t(-1));
	CHECK_EQ(mix(3, 0), int16_t(1));
	CHECK_EQ(mix(-3, 0), int16_t(-1));
	CHECK_EQ(mix(1, 0), int16_t(0));
	CHECK_EQ(mix(-1, 0), int16_t(0));
}

TEST(sound_downmix_extremes_stay_in_range)
{
	CHECK_EQ(mix(32767, 32767), int16_t(32767));
	CHECK_EQ(mix(-32768, -32768), int16_t(-32768));
	CHECK_EQ(mix(32767, -32768), int16_t(0)); // -1 / 2
	CHECK_EQ(mix(-32768, 32767), int16_t(0));
	CHECK_EQ(mix(32767, 32766), int16_t(32766));
	CHECK_EQ(mix(-32768, -32767), int16_t(-32767));
	CHECK_EQ(mix(32767, 0), int16_t(16383));
	CHECK_EQ(mix(-32768, 0), int16_t(-16384));

	// every pair of a coarse grid, against the exact mean in wider arithmetic: within one LSB of it, never outside 16 bit
	for (int32_t l = -32768; l <= 32767; l += 257)
		for (int32_t r = -32768; r <= 32767; r += 263)
		{
			const int32_t m = mix(int16_t(l), int16_t(r));
			const double exact = (double(l) + double(r)) / 2.0;
			if (!(m >= -32768 && m <= 32767 && m - exact < 1.0 && exact - m < 1.0))
			{
				t::report_failure(__FILE__, __LINE__, "mix(" + std::to_string(l) + ", " + std::to_string(r) + ") = " + std::to_string(m));
				return;
			}
		}
}

TEST(sound_downmix_block_little_endian)
{
	const std::vector<uint8_t> in = stereo({{100, 200}, {-32768, -32768}, {32767, 32767}, {0x1234, 0x0102}, {-2, 4}});
	std::vector<uint8_t> out(in.size(), 0xCD);
	CHECK_EQ(stereo_to_mono_s16le(in.data(), uint32_t(in.size()), out.data()), uint32_t(5 * kMonoFrameBytes));
	CHECK_EQ(get(out, 0), int16_t(150));
	CHECK_EQ(get(out, 2), int16_t(-32768));
	CHECK_EQ(get(out, 4), int16_t(32767));
	CHECK_EQ(get(out, 6), int16_t((0x1234 + 0x0102) / 2));
	CHECK_EQ(get(out, 8), int16_t(1));
	// the low byte goes first (AL_FORMAT_MONO16 on x86, ov_read with bigendianp 0)
	CHECK_EQ(out[6], uint8_t(((0x1234 + 0x0102) / 2) & 0xff));
	CHECK_EQ(out[7], uint8_t(((0x1234 + 0x0102) / 2) >> 8));
	// nothing past the mono bytes is written
	for (size_t i = 5 * kMonoFrameBytes; i < out.size(); ++i)
		CHECK_EQ(out[i], uint8_t(0xCD));
}

TEST(sound_downmix_odd_length_takes_whole_frames)
{
	std::vector<uint8_t> in = stereo({{10, 20}, {30, 40}, {50, 60}});
	in.push_back(0x7f); // a partial frame: L of a fourth frame, half of it
	in.push_back(0x7f);
	in.push_back(0x7f);
	std::vector<uint8_t> out(16, 0xCD);
	CHECK_EQ(stereo_to_mono_s16le(in.data(), uint32_t(in.size()), out.data()), uint32_t(3 * kMonoFrameBytes));
	CHECK_EQ(get(out, 0), int16_t(15));
	CHECK_EQ(get(out, 2), int16_t(35));
	CHECK_EQ(get(out, 4), int16_t(55));
	CHECK_EQ(out[6], uint8_t(0xCD)); // the partial frame makes no sample

	// less than one frame: nothing
	for (uint32_t n = 0; n < kStereoFrameBytes; ++n)
		CHECK_EQ(stereo_to_mono_s16le(in.data(), n, out.data()), uint32_t(0));
}

TEST(sound_downmix_in_place)
{
	std::vector<uint8_t> buf = stereo({{2, 4}, {-6, -8}, {32767, 32767}, {-32768, 0}});
	CHECK_EQ(stereo_to_mono_s16le(buf.data(), uint32_t(buf.size()), buf.data()), uint32_t(4 * kMonoFrameBytes));
	CHECK_EQ(get(buf, 0), int16_t(3));
	CHECK_EQ(get(buf, 2), int16_t(-7));
	CHECK_EQ(get(buf, 4), int16_t(32767));
	CHECK_EQ(get(buf, 6), int16_t(-16384));
}

TEST(sound_downmix_block_plan_whole_frames)
{
	// the engine's buffers: stereo = 2 x mono (g_target_temp_data_16 / g_target_temp_data), 400 ms of a 44.1 kHz stereo source
	Block b = plan_block(141120, 70560);
	CHECK_EQ(b.source_bytes, uint32_t(141120));
	CHECK_EQ(b.mono_bytes, uint32_t(70560));

	// buffers sized for another source (a mono 22.05 kHz one started last): still whole frames, mono = half
	b = plan_block(35280, 17640);
	CHECK_EQ(b.source_bytes, uint32_t(35280));
	CHECK_EQ(b.mono_bytes, uint32_t(17640));

	// a capacity that is not a whole number of frames: rounded down, so the emitter's cursor stays on a frame and L stays L
	b = plan_block(35282, 17641);
	CHECK_EQ(b.source_bytes, uint32_t(35280));
	CHECK_EQ(b.mono_bytes, uint32_t(17640));
	b = plan_block(4 * 1001 + 3, 2 * 1000 + 1);
	CHECK_EQ(b.source_bytes, uint32_t(4 * 1000)); // the mono buffer holds 1000 samples only: 1000 of the 1001 frames
	CHECK_EQ(b.mono_bytes, uint32_t(2 * 1000));

	b = plan_block(3, 100);
	CHECK_EQ(b.source_bytes, uint32_t(0));
	CHECK_EQ(b.mono_bytes, uint32_t(0));
	b = plan_block(400, 1);
	CHECK_EQ(b.source_bytes, uint32_t(0));
	CHECK_EQ(b.mono_bytes, uint32_t(0));

	for (uint32_t s = 0; s < 64; ++s)
		for (uint32_t m = 0; m < 40; ++m)
		{
			b = plan_block(s, m);
			if (b.source_bytes % kStereoFrameBytes || b.mono_bytes * 2 != b.source_bytes || b.source_bytes > s ||
			    b.mono_bytes > m || (b.source_bytes + kStereoFrameBytes <= s && b.mono_bytes + kMonoFrameBytes <= m))
				t::report_failure(__FILE__, __LINE__, "plan_block(" + std::to_string(s) + ", " + std::to_string(m) + ")");
		}
}

TEST(sound_downmix_same_duration_as_the_source)
{
	// a block of mono samples lasts exactly as long as the stereo bytes it was made from (same rate, one sample per frame)
	for (uint32_t rate : {11025u, 22050u, 32000u, 44100u, 48000u})
	{
		const Block b = plan_block(2 * (400 * rate * 2 / 1000), 400 * rate * 2 / 1000);
		CHECK(b.source_bytes > 0);
		CHECK_EQ(seconds_of(b.mono_bytes, rate, 1), seconds_of(b.source_bytes, rate, 2));
	}
	CHECK_EQ(seconds_of(176400, 44100, 2), 1.0);
	CHECK_EQ(seconds_of(88200, 44100, 1), 1.0);
	CHECK_EQ(seconds_of(100, 0, 2), 0.0);
	CHECK_EQ(seconds_of(100, 44100, 0), 0.0);
}

TEST(sound_downmix_stream_ends_on_time)
{
	// The emitter's stPlaying fill_block, as in SoundRender_Emitter_streamer.cpp: the target asks for source bytes, the emitter
	// gives what is left and zeroes the rest, and its cursor moves by the bytes asked. A stereo file of 1.25 s plus one frame
	// at 22.05 kHz (frame-aligned, dwBytesTotal = pcm_total * nBlockAlign), every frame non-zero.
	const uint32_t rate = 22050;
	const uint32_t frames = rate + rate / 4 + 1;
	const uint32_t total = frames * kStereoFrameBytes;
	std::vector<uint8_t> source(total);
	for (uint32_t f = 0; f < frames; ++f)
	{
		put(source, size_t(f) * 4, int16_t(1 + f % 1000));
		put(source, size_t(f) * 4 + 2, int16_t(3 + f % 1000));
	}

	// buffers of the size the target gets for this source: 400 ms mono-equivalent (g_target_temp_data = 400 ms * rate * 4)
	const uint32_t mono_capacity = 400 * rate * 4 / 1000;
	const uint32_t stereo_capacity = 2 * mono_capacity;
	std::vector<uint8_t> block(stereo_capacity), mono(mono_capacity);
	std::vector<uint8_t> played; // what OpenAL gets, mono
	uint32_t cursor = 0;
	int blocks = 0;
	while (cursor < total && blocks < 100)
	{
		const Block b = plan_block(stereo_capacity, mono_capacity);
		REQUIRE(b.source_bytes > 0);
		const uint32_t data = cursor >= total ? 0 : (total - cursor < b.source_bytes ? total - cursor : b.source_bytes);
		std::memcpy(block.data(), source.data() + cursor, data);
		std::memset(block.data() + data, 0, b.source_bytes - data);
		cursor += b.source_bytes;
		CHECK_EQ(cursor % kStereoFrameBytes, uint32_t(0)); // never between L and R
		CHECK_EQ(stereo_to_mono_s16le(block.data(), b.source_bytes, mono.data()), b.mono_bytes);
		played.insert(played.end(), mono.begin(), mono.begin() + b.mono_bytes);
		++blocks;
	}
	REQUIRE(cursor >= total);
	CHECK_EQ(played.size() * 2, size_t(cursor)); // one mono sample per stereo frame consumed

	// the sound ends where the source ends: the last non-zero sample is the last frame of the file, then silence
	size_t last = 0;
	for (size_t i = 0; i < played.size() / 2; ++i)
		if (get(played, i * 2) != 0)
			last = i;
	CHECK_EQ(last, size_t(frames - 1));
	CHECK_EQ(seconds_of(uint64_t(last + 1) * kMonoFrameBytes, rate, 1), seconds_of(total, rate, 2));
	// the samples are the means, in order
	CHECK_EQ(get(played, 0), int16_t(2));
	CHECK_EQ(get(played, 2 * 999), int16_t(1001));
	CHECK_EQ(get(played, 2 * 1000), int16_t(2));
	CHECK_EQ(get(played, size_t(frames - 1) * 2), int16_t(mix(int16_t(1 + (frames - 1) % 1000), int16_t(3 + (frames - 1) % 1000))));

	// the emitter's time cursor (calc_cursor in SoundRender_Emitter_FSM.cpp: samples * 2 bytes * nChannels of the source) at
	// any moment points at the same frame the mono stream plays at that moment
	for (double sec : {0.0, 0.1, 0.5, 1.0, 1.2})
	{
		const uint32_t sample = uint32_t(sec * rate);
		const uint32_t source_cursor = sample * 2 * 2;
		CHECK_EQ(source_cursor / kStereoFrameBytes, sample);
		CHECK_EQ(get(played, size_t(sample) * 2), mix(get(source, source_cursor), get(source, source_cursor + 2)));
	}
}

TEST(sound_downmix_only_on_request)
{
	// stock: sm_2D, or any stereo source, plays flat; a mono source plays positional. Without sm_Mono3D nothing changes.
	for (uint32_t channels : {1u, 2u, 6u})
		for (bool flat_asked : {false, true})
		{
			CHECK(!starts_downmixed(flat_asked, false, channels));
			CHECK_EQ(plays_flat(flat_asked, channels, false), flat_asked || channels == 2);
		}

	// sm_Mono3D on a stereo source: mixed down, stays positional
	CHECK(starts_downmixed(false, true, 2));
	CHECK(!plays_flat(false, 2, true));
	// on a mono source it changes nothing: no mixing, positional as before
	CHECK(!starts_downmixed(false, true, 1));
	CHECK(!plays_flat(false, 1, false));
	// only stereo is mixed: other layouts keep their stock path
	CHECK(!starts_downmixed(false, true, 6));
	// sm_2D wins: flat stock stereo, no mixing
	CHECK(!starts_downmixed(true, true, 2));
	CHECK(plays_flat(true, 2, false));

	// a replay of a running emitter keeps the mode it started with (OpenAL keeps one format per queue): a mixed one stays
	// positional unless sm_2D is asked, then it is flat mono
	CHECK(!plays_flat(false, 2, true));
	CHECK(plays_flat(true, 2, true));
}
