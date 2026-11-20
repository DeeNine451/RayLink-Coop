/* Ядро: нет проверок режима (docs/MODES.md)
 * RayLink: lua_setupvalue / debug.setupvalue must keep the GC invariant "no black object points to a white one".
 *
 * A Lua closure keeps a closed upvalue's value in a separate GCupval object, and the collector blackens a closed
 * upvalue as soon as it reaches it (lj_gc.c gc_mark: "Closed upvalues are never gray"), whatever the colour of the
 * closure. LuaJIT 2.0.4's lua_setupvalue put the write barrier on the closure (lj_api.c), so with a black upvalue and a
 * white closure a fresh object written into the upvalue stayed white, was swept, and the upvalue kept pointing into
 * freed memory. Build 57 (2026-11-20) crashed in gc_traverse_trace / lj_alloc_free / the VM on a map server, a co-op
 * client and in single player, after the mod's debug.setupvalue calls grew from 14 to 41.
 *
 * The test builds that exact state deterministically: a cycle in GCSpropagate, the closed upvalue black, its closure
 * white, then lua_setupvalue with a fresh table. It checks the invariant, finishes the cycle, churns the allocator and
 * reads the value back through the closure. Run by tools\test_luajit.cmd against the engine's own LuaJIT sources.
 */
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"
#include "lj_gc.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { checks++; if (!(cond)) { failures++; printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
	else printf("ok: %s\n", msg); } while (0)

static void make_black(GCobj *o) { o->gch.marked = (uint8_t)((o->gch.marked & (uint8_t)~LJ_GC_COLORS) | LJ_GC_BLACK); }
static void make_cur_white(global_State *g, GCobj *o)
{
	o->gch.marked = (uint8_t)((o->gch.marked & (uint8_t)~LJ_GC_COLORS) | curwhite(g));
}

/* Finishes the running cycle the way the game does, by steps (atomic, the white flip, the sweep): a full collection
 * started in the middle of propagate fast-forwards to the sweep without the flip and would hide a missing barrier. */
static void finish_cycle_by_steps(lua_State *L)
{
	global_State *g = G(L);
	int i;
	for (i = 0; i < 100000 && g->gc.state != GCSpause; i++)
		lua_gc(L, LUA_GCSTEP, 0);
}

/* Steps the collector from a finished cycle into GCSpropagate. */
static int enter_propagate(lua_State *L)
{
	global_State *g = G(L);
	int i;
	lua_gc(L, LUA_GCCOLLECT, 0);
	for (i = 0; i < 1000 && g->gc.state != GCSpropagate; i++)
		lua_gc(L, LUA_GCSTEP, 0);
	return g->gc.state == GCSpropagate;
}

/* Lua closure, closed upvalue: the barrier must reach the GCupval. */
static void test_lua_closure(void)
{
	lua_State *L = luaL_newstate();
	global_State *g;
	GCfunc *fn;
	GCupval *uv;
	TValue *v;
	int ok;
	const char *name;

	luaL_openlibs(L);
	ok = luaL_dostring(L,
		"local u = { tag = 'old' }\n"
		"return function() return u end\n") == 0;
	CHECK(ok && lua_isfunction(L, -1), "a closure with a closed upvalue is created");
	lua_setglobal(L, "f"); /* reachable: the cycle must keep it and everything it points to */
	lua_getglobal(L, "f");
	fn = funcV(L->top - 1);
	CHECK(isluafunc(fn) && fn->l.nupvalues == 1, "the closure is a Lua function with one upvalue");
	uv = &gcref(fn->l.uvptr[0])->uv;
	CHECK(uv->closed, "its upvalue is closed");

	g = G(L);
	CHECK(enter_propagate(L), "the collector is in the propagate phase");
	/* The state the collector reaches when another closure sharing this upvalue is traversed before this one. */
	make_black(obj2gco(uv));
	make_cur_white(g, obj2gco(fn));

	/* A fresh, white table, written through the API (debug.setupvalue calls lua_setupvalue). */
	lua_newtable(L);
	lua_pushstring(L, "new");
	lua_setfield(L, -2, "tag");
	name = lua_setupvalue(L, -2, 1);
	CHECK(name != NULL, "lua_setupvalue found the upvalue");

	v = uvval(uv);
	CHECK(!(isblack(obj2gco(uv)) && tviswhite(v)),
		"after lua_setupvalue a black upvalue does not hold a white object (write barrier on the GCupval)");

	/* What a missing barrier does: the cycle sweeps the table the upvalue still points to. */
	lua_pop(L, 1);
	finish_cycle_by_steps(L);
	ok = luaL_dostring(L,
		"for i = 1, 20000 do local t = { tag = 'junk', i } end\n"
		"collectgarbage('collect')\n"
		"local t = f()\n"
		"return type(t) == 'table' and t.tag or tostring(t)\n") == 0;
	CHECK(ok && lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "new") == 0,
		"after a full cycle the closure still returns the table it was given");
	lua_close(L);
}

/* C closure: the value lives in the closure itself; the barrier on the closure is right and must stay so. */
static int cfn(lua_State *L) { lua_pushvalue(L, lua_upvalueindex(1)); return 1; }
static void test_c_closure(void)
{
	lua_State *L = luaL_newstate();
	global_State *g;
	GCfunc *fn;
	int ok;

	luaL_openlibs(L);
	lua_newtable(L);
	lua_pushcclosure(L, cfn, 1);
	lua_setglobal(L, "c");
	lua_getglobal(L, "c");
	fn = funcV(L->top - 1);
	g = G(L);
	CHECK(enter_propagate(L), "C closure: the collector is in the propagate phase");
	make_black(obj2gco(fn));
	lua_newtable(L);
	lua_pushstring(L, "new");
	lua_setfield(L, -2, "tag");
	CHECK(lua_setupvalue(L, -2, 1) != NULL, "C closure: lua_setupvalue found the upvalue");
	CHECK(!(isblack(obj2gco(fn)) && tviswhite(&fn->c.upvalue[0])),
		"C closure: a black closure does not hold a white upvalue value");
	lua_pop(L, 1);
	finish_cycle_by_steps(L);
	ok = luaL_dostring(L,
		"for i = 1, 20000 do local t = { tag = 'junk', i } end\n"
		"collectgarbage('collect')\n"
		"local t = c()\n"
		"return type(t) == 'table' and t.tag or tostring(t)\n") == 0;
	CHECK(ok && lua_isstring(L, -1) && strcmp(lua_tostring(L, -1), "new") == 0,
		"C closure: after a full cycle the closure still returns the table it was given");
	lua_close(L);
	(void)g;
}

int main(void)
{
	test_lua_closure();
	test_c_closure();
	printf("%d check(s), %d failed\n", checks, failures);
	return failures ? 1 : 0;
}
