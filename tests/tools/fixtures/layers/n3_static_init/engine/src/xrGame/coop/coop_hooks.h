// core
#pragma once
namespace coop::hooks
{
using SkipFn = bool (*)(unsigned);
void set_skip(SkipFn fn);
bool skip(unsigned id);
} // namespace coop::hooks
