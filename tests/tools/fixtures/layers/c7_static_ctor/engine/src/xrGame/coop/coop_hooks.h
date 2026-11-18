#pragma once
namespace coop::hooks
{
using SkipFn = bool (*)(u16);
void set_skip(SkipFn fn);
}
