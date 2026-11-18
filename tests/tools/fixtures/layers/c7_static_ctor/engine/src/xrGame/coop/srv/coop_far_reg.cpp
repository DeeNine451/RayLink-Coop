#include "../coop_hooks.h"
namespace coop::srvfar
{
static bool far_skip(u16 id)
{
	return id == 0;
}
struct Registrar
{
	Registrar() { coop::hooks::set_skip(&far_skip); }
};
static Registrar s_registrar;
static Registrar s_second(1);
struct Plain
{
	int n = 0;
};
static Plain s_plain;
static Registrar* s_pointer = nullptr;
bool declared_only(u16 id);
}
