// Anomaly Coop unit tests: script files of zero bytes (TZ R74, section 6.16; xrServerEntities/script_file_rules.h).
// GAMMA removes a script by shipping an empty file over it, and axr_main skips such files. Stable 60 fell at the world
// start when a script asked for a module by name and the module's file was empty: the namespace header was copied into a
// buffer one byte short of its terminator (strncpy_s, invalid parameter). An empty file is no module, like a missing one,
// and the buffer of a loaded script always holds the header, the body and the terminator.
#include "test_util.h"

#include "../engine/src/xrServerEntities/script_file_rules.h"

#include <cstring>
#include <string>

using namespace script_file_rules;

TEST(script_file_empty_is_no_module)
{
	CHECK(!is_module(0));
}

TEST(script_file_with_bytes_is_module)
{
	CHECK(is_module(1));
	CHECK(is_module(74022));
}

TEST(script_buffer_holds_header_and_terminator_for_empty_body)
{
	// the crash of Stable 60: header of n chars, body of 0 bytes, a buffer of n bytes
	const std::string header = "local this = {}\nthis._G = _G\n";
	const size_t size = buffer_size(header.size(), 0);
	CHECK(size >= header.size() + 1);
	std::string buf(size, '\x7f');
	CHECK(strncpy_s(&buf[0], size, header.c_str(), header.size()) == 0);
	CHECK(buf.compare(0, header.size(), header) == 0);
}

TEST(script_buffer_is_header_body_and_terminator)
{
	CHECK_EQ(buffer_size(10, 0), size_t(11));
	CHECK_EQ(buffer_size(10, 5), size_t(16));
	CHECK_EQ(buffer_size(0, 0), size_t(1));
}
