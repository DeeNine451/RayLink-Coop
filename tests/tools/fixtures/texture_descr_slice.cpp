// Executed slice of engine/src/Layers/xrRender/TextureDescrManager.{h,cpp} (package O4-thm; reports #128, #63, #801).
// tests/tools/test_texture_descr_slice.py writes thm_class.inc (class CTextureDescrMngr cut out of the header) and
// thm_body.inc (the whole .cpp without its #include lines). This file gives them small stand-ins for xrCore, the file
// system and thread_spawn, so the real Load / LoadTHM / lookups / UnLoad / destructor run on real threads against a
// scripted "disk" whose folders can be held closed (a loader that opens a THM there waits until the test opens it).
//
// Usage: texture_descr_slice.exe <scenario>; exit 0 = pass, 3 = a check failed (the line says which).
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// ---- xrCore stand-ins ---------------------------------------------------------------------------------------------
typedef const char* LPCSTR;
typedef char* LPSTR;
typedef int BOOL;
typedef unsigned char u8;
typedef unsigned int u32;
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif
#define stricmp _stricmp
typedef char string_path[520];

#define PROF_EVENT(...)
#define PROF_THREAD(...)

static void fail(const char* what)
{
	std::printf("FAIL: %s\n", what);
	std::fflush(stdout);
	std::_Exit(3); // also ends loader threads a broken build left waiting on a closed folder
}

#define R_ASSERT(e)                     \
	do                                  \
	{                                   \
		if (!(e))                       \
			fail("R_ASSERT(" #e ")");   \
	} while (0)
#define EXPECT(c, what)                       \
	do                                        \
	{                                         \
		if (!(c))                             \
			fail(what "  [" #c "]");          \
	} while (0)

static std::mutex g_log_lock;
static std::vector<std::string> g_log;

static void Msg(const char* fmt, ...)
{
	char buf[1024];
	va_list a;
	va_start(a, fmt);
	vsnprintf(buf, sizeof buf, fmt, a);
	va_end(a);
	std::printf("%s\n", buf);
	std::lock_guard<std::mutex> g(g_log_lock);
	g_log.emplace_back(buf);
}

static size_t log_lines_with(const char* needle)
{
	std::lock_guard<std::mutex> g(g_log_lock);
	size_t n = 0;
	for (const std::string& l : g_log)
		n += l.find(needle) != std::string::npos;
	return n;
}

class CTimer
{
	std::chrono::steady_clock::time_point m_start = std::chrono::steady_clock::now();

public:
	void Start() { m_start = std::chrono::steady_clock::now(); }
	u32 GetElapsed_ms() const
	{
		return u32(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - m_start).count());
	}
};

static void Sleep(u32 ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

class shared_str
{
	std::string m_s;

public:
	shared_str() = default;
	shared_str(const char* s) : m_s(s ? s : "") {}
	const char* c_str() const { return m_s.c_str(); }
	const char* operator*() const { return m_s.c_str(); }
	u32 size() const { return u32(m_s.size()); }
	bool operator<(const shared_str& o) const { return m_s < o.m_s; }
	bool operator==(const shared_str& o) const { return m_s == o.m_s; }
};

template <class K, class V>
using xr_map = std::map<K, V>;
#define DEFINE_MAP(K, T, N, I) \
	typedef xr_map<K, T> N;    \
	typedef N::iterator I;

static std::atomic<int> g_live{0}; // objects made by xr_new and not yet freed by xr_delete

template <class T, class... A>
T* xr_new(A&&... a)
{
	++g_live;
	return new T(std::forward<A>(a)...);
}

template <class T>
void xr_delete(T*& p)
{
	if (p)
	{
		--g_live;
		delete p;
		p = nullptr;
	}
}

template <size_t N>
void xr_strcpy(char (&d)[N], const char* s)
{
	strncpy_s(d, s, _TRUNCATE);
}

static LPSTR strext(LPSTR s) { return strrchr(s, '.'); }

struct Flags32
{
	u32 flags = 0;
	BOOL is(u32 m) const { return m == (flags & m); }
	BOOL is_any(u32 m) const { return BOOL(!!(flags & m)); }
};

struct R_constant
{
};

class R_constant_setup
{
public:
	virtual void setup(R_constant* C) = 0;
	virtual ~R_constant_setup() {}
};

static struct
{
	void set_c(R_constant*, float, float, float, float) {}
} RCache;

// ---- the scripted disk --------------------------------------------------------------------------------------------
#define THM_CHUNK_TYPE 0x0813

struct Rec
{
	int type = 0; // STextureParams::ETType
	u32 flags = 0;
	std::string detail;
	float detail_scale = 1;
	u32 material = 0;
	float weight = 0;
	int bump_mode = 1; // tbmNone
	std::string bump;
};

struct Folder
{
	std::map<std::string, Rec> files; // name without ".thm"
	bool open = true;                 // false: a loader that opens a THM here waits
};

static std::mutex g_disk_lock;
static std::condition_variable g_disk_cv;
static std::map<std::string, Folder> g_disk; // "$game_textures$", "$level$"
static std::atomic<int> g_opens{0};
static std::atomic<int> g_open_delay_ms{0};

static void hold(const char* root, bool closed)
{
	{
		std::lock_guard<std::mutex> g(g_disk_lock);
		g_disk[root].open = !closed;
	}
	g_disk_cv.notify_all();
}

struct FS_File
{
	std::string name;
	bool operator<(const FS_File& o) const { return name < o.name; }
};
typedef std::set<FS_File> FS_FileSet;
enum
{
	FS_ListFiles = 1
};

struct IReader
{
	Rec rec;
	bool find_chunk(u32 id) const { return id == THM_CHUNK_TYPE; }
	u32 r_u32() { return 0; }
};

static struct CLocatorAPI
{
	void file_list(FS_FileSet& out, LPCSTR initial, u32, LPCSTR)
	{
		std::lock_guard<std::mutex> g(g_disk_lock);
		for (const auto& f : g_disk[initial].files)
			out.insert(FS_File{f.first + ".thm"});
	}

	void update_path(string_path& dst, LPCSTR initial, LPCSTR name) { snprintf(dst, sizeof dst, "%s|%s", initial, name); }

	IReader* r_open(LPCSTR path)
	{
		const std::string p(path);
		const size_t bar = p.find('|');
		const std::string root = p.substr(0, bar);
		std::string name = p.substr(bar + 1);
		name.resize(name.size() - 4); // ".thm"
		IReader* r = nullptr;
		{
			std::unique_lock<std::mutex> lk(g_disk_lock);
			g_disk_cv.wait(lk, [&] { return g_disk[root].open; });
			r = new IReader{g_disk[root].files.at(name)};
			++g_opens;
		}
		if (const int d = g_open_delay_ms.load())
			Sleep(u32(d));
		return r;
	}

	void r_close(IReader*& r)
	{
		delete r;
		r = nullptr;
	}
} FS;

struct STextureParams
{
	enum ETType
	{
		ttImage = 0,
		ttCubeMap,
		ttBumpMap,
		ttNormalMap,
		ttTerrain,
	};
	enum ETBumpMode
	{
		tbmResereved = 0,
		tbmNone,
		tbmUse,
		tbmUseParallax,
	};
	enum
	{
		flDiffuseDetail = (1 << 23),
		flBumpDetail = (1 << 26),
	};

	Flags32 flags;
	shared_str detail_name;
	float detail_scale = 1;
	ETType type = ttImage;
	u32 material = 0;
	float material_weight = 0;
	ETBumpMode bump_mode = tbmNone;
	shared_str bump_name;

	void Clear() { *this = STextureParams(); }
	void Load(IReader& F)
	{
		type = ETType(F.rec.type);
		flags.flags = F.rec.flags;
		detail_name = F.rec.detail.c_str();
		detail_scale = F.rec.detail_scale;
		material = F.rec.material;
		material_weight = F.rec.weight;
		bump_mode = ETBumpMode(F.rec.bump_mode);
		bump_name = F.rec.bump.c_str();
	}
};

// ---- thread_spawn: a detached std::thread, counted -----------------------------------------------------------------
// A thread named in g_end_first runs to its end before thread_spawn returns: _beginthread may do that, and the $level$
// loader reads few or no THMs at startup (scenario "ends-first").
typedef void thread_t(void*);
static std::atomic<int> g_threads{0};
static std::mutex g_names_lock;
static std::vector<std::string> g_thread_names;
static std::set<std::string> g_end_first;

static void thread_spawn(thread_t* entry, const char* name, unsigned, void* args)
{
	bool end_first = false;
	{
		std::lock_guard<std::mutex> g(g_names_lock);
		g_thread_names.emplace_back(name);
		end_first = g_end_first.count(name) != 0;
	}
	++g_threads;
	std::thread t([entry, args] {
		entry(args);
		--g_threads;
	});
	if (end_first)
		t.join();
	else
		t.detach();
}

static void end_first(std::set<std::string> names)
{
	std::lock_guard<std::mutex> g(g_names_lock);
	g_end_first = std::move(names);
}

// Runs fn on a helper thread and fails if it has not returned within ms: a hang becomes a failure with a reason
// (fail() ends the process, the stuck thread with it).
template <class F>
static void within(int ms, const char* what, F&& fn)
{
	std::mutex lock;
	std::condition_variable cv;
	bool done = false;
	std::thread t([&] {
		fn();
		{
			std::lock_guard<std::mutex> g(lock);
			done = true;
		}
		cv.notify_all();
	});
	{
		std::unique_lock<std::mutex> u(lock);
		if (!cv.wait_for(u, std::chrono::milliseconds(ms), [&] { return done; }))
			fail(what);
	}
	t.join();
}

static bool threads_gone(int ms)
{
	for (int i = 0; i < ms; ++i)
	{
		if (g_threads.load() == 0)
			return true;
		Sleep(1);
	}
	return g_threads.load() == 0;
}

// ---- the engine code ------------------------------------------------------------------------------------------------
#if __has_include("texture_descr_merge.h")
#include "texture_descr_merge.h"
#endif

class cl_dt_scaler;
struct TH_LoadTHM;
// public only so the "random" scenario can run the real LoadTHM sequentially as its oracle
#define private public
#include "thm_class.inc"
#undef private
#include "thm_body.inc"

// ---- scenarios ------------------------------------------------------------------------------------------------------
namespace
{
using TP = STextureParams;

Rec rec(int type, u32 flags, const char* detail, float scale, u32 material, float weight, int bump_mode, const char* bump)
{
	Rec r;
	r.type = type;
	r.flags = flags;
	r.detail = detail;
	r.detail_scale = scale;
	r.material = material;
	r.weight = weight;
	r.bump_mode = bump_mode;
	r.bump = bump;
	return r;
}

void standard_disk()
{
	std::lock_guard<std::mutex> g(g_disk_lock);
	g_disk.clear();
	auto& game = g_disk["$game_textures$"].files;
	game["a"] = rec(TP::ttImage, TP::flDiffuseDetail | TP::flBumpDetail, "det_a", 2, 1, 0.5f, TP::tbmUse, "a_bump");
	game["b"] = rec(TP::ttImage, TP::flDiffuseDetail, "det_b", 3, 2, 0.25f, TP::tbmUse, "b_game");
	game["c"] = rec(TP::ttTerrain, 0, "", 1, 5, 0.75f, TP::tbmUseParallax, "c_bump");
	game["e"] = rec(TP::ttNormalMap, 0, "", 1, 0, 0, TP::tbmNone, "");
	game["f"] = rec(TP::ttImage, TP::flBumpDetail, "", 4, 1, 0, TP::tbmUse, "f_bump"); // a detail flag without a name
	game["x"] = rec(TP::ttCubeMap, 0, "", 1, 0, 0, TP::tbmUse, "x_game");            // not a texture LoadTHM keeps
	auto& level = g_disk["$level$"].files;
	level["a"] = rec(TP::ttImage, TP::flBumpDetail, "det_a_lvl", 7, 0, 0.125f, TP::tbmNone, "");
	level["b"] = rec(TP::ttImage, 0, "", 1, 3, 0.5f, TP::tbmUse, "b_level");
	level["d"] = rec(TP::ttImage, TP::flDiffuseDetail, "det_d", 5, 0, 0, TP::tbmUse, "d_bump");
	level["x"] = rec(TP::ttImage, 0, "", 1, 0, 0, TP::tbmUse, "x_level");
}

std::string bump(const CTextureDescrMngr& m, const char* t) { return m.GetBumpName(t).c_str(); }

struct Detail
{
	BOOL found = FALSE;
	std::string name;
	R_constant_setup* cs = nullptr;
	float scale() const { return cs ? static_cast<cl_dt_scaler*>(cs)->scale : -1.f; }
};

Detail detail(const CTextureDescrMngr& m, const char* t)
{
	Detail d;
	LPCSTR res = nullptr;
	d.found = m.GetDetailTexture(t, res, d.cs);
	if (d.found)
		d.name = res;
	return d;
}

bool usage_is(const CTextureDescrMngr& m, const char* t, BOOL diffuse, BOOL bmp)
{
	BOOL d = 7, b = 7; // left alone when the texture has no detail
	m.GetTextureUsage(t, d, b);
	return d == diffuse && b == bmp;
}

bool near(float a, float b) { return a - b < 1e-5f && b - a < 1e-5f; }

// What LoadTHM($game_textures$) then LoadTHM($level$) into one pair of maps leaves (the order before the loaders were
// threads; TextureDescrManager.cpp LoadTHM: m_spec always rewritten, m_assoc and the scale only by a THM with a detail).
void check_standard(const CTextureDescrMngr& m)
{
	EXPECT(bump(m, "a") == "", "a: the level THM (no bump) replaces the game spec");
	EXPECT(bump(m, "b") == "b_level", "b: the level bump wins over the game bump");
	EXPECT(bump(m, "c") == "c_bump", "c: a game-only texture is kept");
	EXPECT(bump(m, "d") == "d_bump", "d: a level-only texture is kept");
	EXPECT(bump(m, "f") == "f_bump", "f: kept");
	EXPECT(bump(m, "x") == "x_level", "x: the level image is kept, the game cube map never was");
	EXPECT(bump(m, "zz") == "", "an unknown texture has no bump");
	EXPECT(m.UseSteepParallax("c") == TRUE, "c: parallax");
	EXPECT(m.UseSteepParallax("b") == FALSE, "b: no parallax");
	EXPECT(near(m.GetMaterial("a"), 0.125f), "a: level material 0 + weight");
	EXPECT(near(m.GetMaterial("b"), 3.5f), "b: level material 3 + weight");
	EXPECT(near(m.GetMaterial("c"), 5.f), "c: material >= 4 takes no weight");
	EXPECT(near(m.GetMaterial("e"), 0.f), "e: kept, material 0");
	EXPECT(near(m.GetMaterial("zz"), 1.f), "an unknown texture has material 1");

	const Detail a = detail(m, "a");
	EXPECT(a.found && a.name == "det_a_lvl" && near(a.scale(), 7.f), "a: the level detail and scale win");
	EXPECT(usage_is(m, "a", FALSE, TRUE), "a: level usage (bump detail only)");
	const Detail b = detail(m, "b");
	EXPECT(b.found && b.name == "det_b" && near(b.scale(), 3.f), "b: no level detail, the game detail stays");
	EXPECT(usage_is(m, "b", TRUE, FALSE), "b: game usage stays");
	const Detail d = detail(m, "d");
	EXPECT(d.found && d.name == "det_d" && near(d.scale(), 5.f), "d: level detail");
	EXPECT(!detail(m, "c").found && usage_is(m, "c", 7, 7), "c: no detail");
	EXPECT(!detail(m, "f").found, "f: a detail flag without a name is no detail");
	EXPECT(!detail(m, "x").found && !detail(m, "zz").found, "x, zz: no detail");
}

void check_threads_named()
{
	std::lock_guard<std::mutex> g(g_names_lock);
	EXPECT(g_thread_names.size() >= 2, "two loader threads");
	EXPECT(g_thread_names[0] == "X-Ray THM Loader 1" && g_thread_names[1] == "X-Ray THM Loader 2",
	       "the stock thread names, game textures first");
}

// A lookup right after Load (the device is still being created): it must see the merged maps, never a partial one.
void merged()
{
	standard_disk();
	g_open_delay_ms = 15; // every THM takes 15 ms: the loaders are far from done when Load returns
	auto* m = new CTextureDescrMngr();
	m->Load();
	check_standard(*m);
	EXPECT(g_opens.load() == 10, "every THM was read before the lookup answered");
	check_threads_named();
	EXPECT(log_lines_with("THM") == 1, "one merge line");
	EXPECT(threads_gone(2000), "the loader threads end");
	m->UnLoad();
	delete m;
	EXPECT(g_live.load() == 0, "UnLoad and the destructor free everything the loaders made");
}

// The first lookup waits while a loader still reads, then answers from the merged maps.
void waits()
{
	standard_disk();
	hold("$game_textures$", true);
	CTextureDescrMngr m;
	m.Load();
	std::atomic<bool> done{false};
	std::string got;
	std::thread reader([&] {
		got = bump(m, "b");
		done = true;
	});
	Sleep(200);
	EXPECT(!done.load(), "a lookup returned while the $game_textures$ loader was still reading");
	hold("$game_textures$", false);
	reader.join();
	EXPECT(got == "b_level", "the waiting lookup sees the merged maps (level over game)");
	EXPECT(g_opens.load() == 10, "both loaders finished before the merge");
	check_standard(m);
	EXPECT(threads_gone(2000), "the loader threads end");
	m.UnLoad();
}

// UnLoad / Load (device reset, OnAssetsChanged): a scaler keeps its address (shaders hold it) and takes the new scale.
void reload()
{
	standard_disk();
	auto* m = new CTextureDescrMngr();
	m->Load();
	check_standard(*m);
	const Detail before = detail(*m, "a");
	{
		std::lock_guard<std::mutex> g(g_disk_lock);
		g_disk["$level$"].files["a"].detail_scale = 11;
		g_disk["$game_textures$"].files["b"].flags = 0; // b loses its detail
	}
	m->UnLoad();
	m->Load();
	const Detail after = detail(*m, "a");
	EXPECT(after.found && after.cs == before.cs, "a: the same scaler object after the reload");
	EXPECT(near(after.scale(), 11.f), "a: the reloaded scale");
	EXPECT(!detail(*m, "b").found, "b: no detail after the reload");
	EXPECT(bump(*m, "b") == "b_level", "b: still the level bump");
	EXPECT(threads_gone(2000), "the loader threads end");
	m->UnLoad();
	delete m;
	EXPECT(g_live.load() == 0, "nothing leaks across a reload");
}

// UnLoad while a loader still reads: it waits, and nothing is written into the maps after it returns.
void unload_early()
{
	standard_disk();
	hold("$game_textures$", true);
	CTextureDescrMngr m;
	m.Load();
	std::atomic<bool> done{false};
	std::thread unloader([&] {
		m.UnLoad();
		done = true;
	});
	Sleep(200);
	EXPECT(!done.load(), "UnLoad returned while a loader still reads");
	hold("$game_textures$", false);
	unloader.join();
	EXPECT(threads_gone(2000), "the loader threads end");
	EXPECT(bump(m, "b") == "" && !detail(m, "d").found, "nothing is left in the maps after UnLoad");
}

// The manager is destroyed while a loader still reads: the destructor waits for it.
void destroy_early()
{
	standard_disk();
	hold("$game_textures$", true);
	auto* m = new CTextureDescrMngr();
	m->Load();
	std::atomic<bool> done{false};
	std::thread killer([&] {
		delete m;
		done = true;
	});
	Sleep(200);
	EXPECT(!done.load(), "the destructor returned while a loader still reads");
	hold("$game_textures$", false);
	killer.join();
	EXPECT(threads_gone(2000), "the loader threads end");
}

// Load again before the first Load's loaders end: the first load finishes first, as two LoadTHM rounds in a row would.
void double_load()
{
	standard_disk();
	hold("$game_textures$", true);
	auto* m = new CTextureDescrMngr();
	m->Load();
	std::atomic<bool> done{false};
	std::thread second([&] {
		m->Load();
		done = true;
	});
	Sleep(200);
	EXPECT(!done.load(), "a second Load started while the first one's loaders still read");
	hold("$game_textures$", false);
	second.join();
	check_standard(*m);
	EXPECT(log_lines_with("THM") == 2, "two merges");
	EXPECT(threads_gone(2000), "the loader threads end");
	m->UnLoad();
	delete m;
	EXPECT(g_live.load() == 0, "the second round frees what it replaces");
}

// Several threads (xr_parallel_foreach texture loads) look up at once while loading: one merge, all see it.
void many_readers()
{
	standard_disk();
	hold("$game_textures$", true);
	CTextureDescrMngr m;
	m.Load();
	std::atomic<int> wrong{0};
	std::vector<std::thread> readers;
	for (int i = 0; i < 10; ++i)
		readers.emplace_back([&, i] {
			bool ok = true;
			switch (i % 5)
			{
			case 0: ok = bump(m, "b") == "b_level"; break;
			case 1: ok = near(detail(m, "a").scale(), 7.f); break;
			case 2: ok = m.UseSteepParallax("c") == TRUE; break;
			case 3: ok = usage_is(m, "b", TRUE, FALSE); break;
			default: ok = near(m.GetMaterial("b"), 3.5f); break;
			}
			if (!ok)
				++wrong;
		});
	Sleep(100);
	hold("$game_textures$", false);
	for (std::thread& t : readers)
		t.join();
	EXPECT(wrong.load() == 0, "every reader saw the merged maps");
	EXPECT(log_lines_with("THM") == 1, "one merge for all readers");
	EXPECT(threads_gone(2000), "the loader threads end");
	m.UnLoad();
}

// A loader ends before thread_spawn returns. Load must arm the gate before the spawns: a job_done that comes first is
// lost, and the first lookup then waits forever (the startup hang of reports #128 / #63). Fixed order, no timing luck.
// Here both loaders end inside thread_spawn.
void ends_first()
{
	standard_disk();
	end_first({"X-Ray THM Loader 1", "X-Ray THM Loader 2"});
	auto* m = new CTextureDescrMngr();
	within(5000, "Load or the first lookup hung after both loaders ended inside thread_spawn", [&] {
		m->Load();
		check_standard(*m);
	});
	EXPECT(threads_gone(2000), "the loader threads end");
	m->UnLoad();
	delete m;
	EXPECT(g_live.load() == 0, "nothing leaks");
}

// The same with only the $level$ loader (an empty folder, as at startup) ending inside thread_spawn, while the
// $game_textures$ loader still reads.
void level_ends_first()
{
	standard_disk();
	{
		std::lock_guard<std::mutex> g(g_disk_lock);
		g_disk["$level$"].files.clear();
	}
	end_first({"X-Ray THM Loader 2"});
	hold("$game_textures$", true);
	auto* m = new CTextureDescrMngr();
	within(5000, "Load hung while the $game_textures$ loader still read", [&] { m->Load(); });
	hold("$game_textures$", false);
	within(5000, "the first lookup hung after the empty $level$ loader ended inside thread_spawn", [&] {
		EXPECT(bump(*m, "b") == "b_game", "b: the game bump (the $level$ folder is empty)");
		const Detail a = detail(*m, "a");
		EXPECT(a.found && a.name == "det_a" && near(a.scale(), 2.f), "a: the game detail and scale");
		EXPECT(bump(*m, "x") == "" && !detail(*m, "d").found, "x, d: nothing from the empty $level$ folder");
	});
	EXPECT(g_opens.load() == 6, "every $game_textures$ THM was read");
	EXPECT(log_lines_with("THM") == 1, "one merge");
	EXPECT(threads_gone(2000), "the loader threads end");
	m->UnLoad();
	delete m;
	EXPECT(g_live.load() == 0, "nothing leaks");
}

// ---- random disks against the real LoadTHM run in the old sequential order ------------------------------------------
u32 g_seed = 1;
u32 rnd(u32 n)
{
	g_seed ^= g_seed << 13;
	g_seed ^= g_seed >> 17;
	g_seed ^= g_seed << 5;
	return g_seed % n;
}

const char* const k_details[] = {"", "dA", "dB"};
const char* const k_bumps[] = {"", "bA", "bB", "bC"};
const u32 k_flags[] = {0, TP::flDiffuseDetail, TP::flBumpDetail, TP::flDiffuseDetail | TP::flBumpDetail, 1u << 3};

void random_disk()
{
	std::lock_guard<std::mutex> g(g_disk_lock);
	g_disk.clear();
	for (const char* root : {"$game_textures$", "$level$"})
	{
		auto& files = g_disk[root].files;
		for (int i = 0; i < 40; ++i)
		{
			if (rnd(10) < 4)
				continue;
			char name[8];
			snprintf(name, sizeof name, "t%02d", i);
			files[name] = rec(int(rnd(5)), k_flags[rnd(5)], k_details[rnd(3)], float(1 + rnd(9)), rnd(6),
			                  float(rnd(8)) / 8.f, int(rnd(4)), k_bumps[rnd(4)]);
		}
	}
}

// The oracle: one manager filled by LoadTHM($game_textures$) then LoadTHM($level$) on this thread, as before the
// loaders were threads. Its scalers stay over a reload exactly as UnLoad leaves them.
void fill_sequential(CTextureDescrMngr& ref)
{
	CTextureDescrMngr::LoadTHM("$game_textures$", ref.m_texture_details, ref.m_detail_scalers);
	CTextureDescrMngr::LoadTHM("$level$", ref.m_texture_details, ref.m_detail_scalers);
}

void compare(const CTextureDescrMngr& m, const CTextureDescrMngr& ref, int round)
{
	for (int i = 0; i < 42; ++i)
	{
		char name[8];
		snprintf(name, sizeof name, "t%02d", i);
		char what[160];
		snprintf(what, sizeof what, "round %d, texture %s", round, name);
		if (bump(m, name) != bump(ref, name))
			fail((std::string("bump differs: ") + what).c_str());
		if (m.UseSteepParallax(name) != ref.UseSteepParallax(name))
			fail((std::string("parallax differs: ") + what).c_str());
		if (!near(m.GetMaterial(name), ref.GetMaterial(name)))
			fail((std::string("material differs: ") + what).c_str());
		BOOL d1 = 7, b1 = 7, d2 = 7, b2 = 7;
		m.GetTextureUsage(name, d1, b1);
		ref.GetTextureUsage(name, d2, b2);
		if (d1 != d2 || b1 != b2)
			fail((std::string("usage differs: ") + what).c_str());
		const Detail x = detail(m, name), y = detail(ref, name);
		if (x.found != y.found || x.name != y.name || !near(x.scale(), y.scale()))
			fail((std::string("detail differs: ") + what).c_str());
	}
}

void random_rounds()
{
	for (int round = 0; round < 150; ++round)
	{
		g_seed = 0x9E3779B9u ^ u32(round * 2654435761u);
		random_disk();
		auto* m = new CTextureDescrMngr();
		auto* ref = new CTextureDescrMngr();
		m->Load();
		fill_sequential(*ref);
		compare(*m, *ref, round);
		// reload over a changed disk: the old scalers stay in both, as UnLoad leaves them
		random_disk();
		m->UnLoad();
		ref->UnLoad();
		m->Load();
		fill_sequential(*ref);
		compare(*m, *ref, round);
		m->UnLoad();
		ref->UnLoad();
		delete m;
		delete ref;
		EXPECT(threads_gone(2000), "the loader threads end");
		EXPECT(g_live.load() == 0, "nothing leaks");
	}
}
} // namespace

int main(int argc, char** argv)
{
	if (argc < 2)
		fail("usage: texture_descr_slice <scenario>");
	const std::string s = argv[1];
	if (s == "merged")
		merged();
	else if (s == "waits")
		waits();
	else if (s == "reload")
		reload();
	else if (s == "unload-early")
		unload_early();
	else if (s == "destroy-early")
		destroy_early();
	else if (s == "double-load")
		double_load();
	else if (s == "many-readers")
		many_readers();
	else if (s == "ends-first")
		ends_first();
	else if (s == "level-ends-first")
		level_ends_first();
	else if (s == "random")
		random_rounds();
	else
		fail("unknown scenario");
	std::printf("PASS %s\n", s.c_str());
	return 0;
}
