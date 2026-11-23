// Executes the engine's own CLevel::cl_Process_Event (Level.cpp), CInventoryBox::OnEvent (InventoryBox.cpp),
// CAI_Trader::OnEvent (ai/trader/ai_trader.cpp) and CInventoryItem::net_Destroy (inventory_item.cpp), cut out by
// tests/tools/test_container_reject.py into container_reject.inc, over the real pure header
// engine/src/xrCoop/coop_container_rules.h (O1-container; crash reports of builds 56-57).
//
// A co-op client applies the decider's moves and destroys through its local server, and some children of an online
// container have no game object there (a spawn dropped while the level was not ready, an entity already gone). A box or a
// trader then heard "taken out" of an item it does not hold: the box erased end() of its id list (release build: memmove of
// -2 bytes, access violation; RL-QHQ3-2TUG), the trader read a null item (RL-WKWE-CPCY). The engine around the four
// functions (objects, packets, inventories, the UI, the actor's callback) are stubs that record what they were asked; the
// id list is a vector whose erase(end()) stops the run with exit code 3 instead of corrupting memory.
// One scenario per run: container_reject.exe <scenario>.
#include <algorithm>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "coop_container_rules.h"

#define MASTER_GOLD // a release build: the stock "! ERROR" lines of cl_Process_Event are not compiled
#define VERIFY(expr) \
	do               \
	{                \
	} while (0)
#define FALSE 0
#define TRUE 1

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using BOOL = int;

namespace
{
int g_failures = 0;
void check(bool ok, const char* what)
{
	if (!ok)
	{
		std::fprintf(stderr, "FAIL: %s\n", what);
		++g_failures;
	}
}

int g_on_destroy = 0;      // Game().OnDestroy
int g_box_callbacks = 0;   // the actor's eInvBoxItemTake callback
int g_sent = 0;            // u_EventSend
int g_foreign_drops = 0;   // CInventory::DropItem of an item another inventory holds
bool g_last_shell = false; // the dont_create_shell of the last detach
} // namespace

std::vector<std::string> g_log;
void Msg(const char* format, ...)
{
	char line[1024];
	va_list args;
	va_start(args, format);
	std::vsnprintf(line, sizeof line, format, args);
	va_end(args);
	g_log.push_back(line);
}

// The engine's xr_vector, with erase(end()) caught: in a release build it memmoves -2 bytes (the b56 crash).
template <class T> struct xr_vector : std::vector<T>
{
	using base = std::vector<T>;
	using iterator = typename base::iterator;
	iterator erase(iterator it)
	{
		if (it == this->end())
		{
			std::fprintf(stderr, "FAIL: erase(end()) of a list that does not hold the id\n");
			std::exit(3);
		}
		return base::erase(it);
	}
};

template <class T, class U> T smart_cast(U* p)
{
	return p ? dynamic_cast<T>(p) : nullptr;
}

enum : u16
{
	GE_OWNERSHIP_TAKE = 1,
	GE_OWNERSHIP_REJECT,
	GE_TRADE_BUY,
	GE_TRADE_SELL,
	GE_TRANSFER_AMMO,
	GE_DESTROY,
	GE_DESTROY_REJECT,
};

struct NET_Packet
{
	std::vector<u8> B;
	u32 r_pos = 0;
	void w_u16(u16 v)
	{
		B.push_back(u8(v & 0xff));
		B.push_back(u8(v >> 8));
	}
	void w_u8(u8 v) { B.push_back(v); }
	void r_u16(u16& v)
	{
		v = u16(B[r_pos] | (B[r_pos + 1] << 8));
		r_pos += 2;
	}
	u16 r_u16()
	{
		u16 v;
		r_u16(v);
		return v;
	}
	u8 r_u8() { return B[r_pos++]; }
	bool r_eof() const { return r_pos >= B.size(); }
	u32 r_tell() const { return r_pos; }
	void r_seek(u32 pos) { r_pos = pos; }
};

struct shared_str
{
	std::string s;
	const char* c_str() const { return s.c_str(); }
};

class CInventoryOwner;

class CObject
{
public:
	virtual ~CObject() = default;
	u16 m_id = 0;
	CObject* m_parent = nullptr;
	bool m_tmp_pre_destroy = false;
	bool m_visible = true, m_enabled = true;
	shared_str m_name{"object"};
	u16 ID() const { return m_id; }
	const shared_str& cName() const { return m_name; }
	const shared_str& cNameSect() const { return m_name; }
	CObject* H_Parent() { return m_parent; }
	CObject* H_SetParent(CObject* parent, bool just_before_destroy = false)
	{
		CObject* old = m_parent;
		m_parent = parent;
		g_last_shell = just_before_destroy;
		return old;
	}
	void setVisible(BOOL v) { m_visible = v != 0; }
	void setEnabled(BOOL v) { m_enabled = v != 0; }
	void SetTmpPreDestroy(bool b) { m_tmp_pre_destroy = b; }
	virtual CInventoryOwner* cast_inventory_owner() { return nullptr; }
};

class CGameObject : public CObject
{
public:
	std::vector<u16> heard; // the events this object's OnEvent got
	virtual void OnEvent(NET_Packet& P, u16 type)
	{
		(void)P;
		heard.push_back(type);
	}
	void* lua_game_object() { return this; }
	static void u_EventGen(NET_Packet& P, u32 type, u32 dest)
	{
		P.w_u16(u16(type));
		P.w_u16(u16(dest));
	}
	static void u_EventSend(NET_Packet&) { ++g_sent; }
};

enum EItemPlaceType
{
	eItemPlaceUndefined,
	eItemPlaceSlot,
	eItemPlaceBelt,
	eItemPlaceRuck
};

class CInventory;
class CInventoryItem
{
public:
	virtual ~CInventoryItem() = default;
	CInventory* m_pInventory = nullptr;
	EItemPlaceType m_place = eItemPlaceUndefined;
	u16 m_slot = 0;
	CGameObject* m_object = nullptr;
	EItemPlaceType CurrPlace() const { return m_place; }
	u16 CurrSlot() const { return m_slot; }
	CGameObject& object() const { return *m_object; }
	float Weight() const { return 2.f; }
	void net_Destroy();
};
using PIItem = CInventoryItem*;
using TIItemContainer = xr_vector<PIItem>;

class CInventory
{
public:
	TIItemContainer m_all, m_ruck, m_belt;
	std::vector<PIItem> m_slots = std::vector<PIItem>(14, nullptr);
	float m_fTotalWeight = -1.f;
	int m_invalidated = 0;
	int m_drops = 0;
	bool m_drop_before_destroy = false, m_drop_no_shell = false;
	u16 LastSlot() const { return 13; }
	PIItem ItemFromSlot(u16 slot) const { return m_slots[slot]; }
	float CalcTotalWeight()
	{
		float weight = 0.f;
		for (PIItem item : m_all)
			weight += item->Weight();
		m_fTotalWeight = weight;
		return weight;
	}
	void InvalidateState() { ++m_invalidated; }
	bool CanTakeItem(CInventoryItem* item) const { return item != nullptr; }
	void Take(CGameObject*, bool, bool) {}
	// Stock CInventory::DropItem in short: out of this inventory's lists, the item forgets its inventory, comes off its holder.
	// An item of another inventory is counted: stock wipes that inventory's pointer and detaches it from its real holder.
	bool DropItem(CGameObject* obj, bool just_before_destroy, bool dont_create_shell)
	{
		CInventoryItem* item = smart_cast<CInventoryItem*>(obj);
		++m_drops;
		m_drop_before_destroy = just_before_destroy;
		m_drop_no_shell = dont_create_shell;
		if (item->m_pInventory != this)
			++g_foreign_drops;
		for (TIItemContainer* list : {&m_all, &m_ruck, &m_belt})
		{
			auto it = std::find(list->begin(), list->end(), item);
			if (it != list->end())
				list->erase(it);
		}
		item->m_pInventory = nullptr;
		obj->H_SetParent(nullptr, dont_create_shell);
		return true;
	}
};

class CInventoryOwner
{
public:
	virtual ~CInventoryOwner() = default;
	CInventory* m_inventory = nullptr;
	CInventory& inventory() { return *m_inventory; }
	void OnEvent(NET_Packet&, u16) {}
};

// ---- the UI and the actor's callback the box path reaches
enum EMenuMode
{
	mmUndefined,
	mmDeadBodySearch
};
class CInventoryBox;
struct CUIActorMenu
{
	EMenuMode GetMenuMode() const { return mmUndefined; }
	CInventoryBox* GetInvBox() const { return nullptr; }
};
struct CUIGameCustom
{
	CUIActorMenu menu;
	CUIActorMenu& GetActorMenu() { return menu; }
	void OnInventoryAction(CInventoryItem*, u16) {}
};
CUIGameCustom* CurrentGameUI()
{
	return nullptr;
}
namespace GameObject
{
enum ECallbackType
{
	eInvBoxItemTake
};
}
struct ActorCallback
{
	void operator()(void*, void*) const { ++g_box_callbacks; }
};
struct CActor
{
	ActorCallback callback(GameObject::ECallbackType) { return ActorCallback{}; }
};
CActor g_actor;
CActor* Actor()
{
	return &g_actor;
}

namespace coop
{
namespace trade
{
inline bool trader_local_logic()
{
	return false; // a client: its trader mirrors the decider and never rejects by itself
}
} // namespace trade
} // namespace coop

class CInventoryBox : public CGameObject
{
	typedef CGameObject inherited;

public:
	xr_vector<u16> m_items;
	bool m_in_use = false;
	void OnEvent(NET_Packet& P, u16 type) override;
};

class CAI_Trader : public CGameObject, public CInventoryOwner
{
	typedef CGameObject inherited;

public:
	void OnEvent(NET_Packet& P, u16 type) override;
	CInventoryOwner* cast_inventory_owner() override { return this; }
};

class CStalker : public CGameObject, public CInventoryOwner
{
public:
	CInventoryOwner* cast_inventory_owner() override { return this; }
};

class CItem : public CGameObject, public CInventoryItem
{
public:
	CItem() { m_object = this; }
};

struct CObjectList
{
	std::vector<CObject*> objects;
	CObject* net_Find(u16 id) const
	{
		for (CObject* o : objects)
			if (o->ID() == id)
				return o;
		return nullptr;
	}
	u32 o_count() { return u32(objects.size()); }
	CObject* o_get_by_iterator(u32 i) { return objects[i]; }
};
struct IGame_Level
{
	CObjectList Objects;
};
class CLevel : public IGame_Level
{
public:
	void cl_Process_Event(u16 dest, u16 type, NET_Packet& P);
};
CLevel g_level;
IGame_Level* g_pGameLevel = &g_level;
CLevel& Level()
{
	return g_level;
}
struct GameStub
{
	void OnDestroy(CGameObject*) { ++g_on_destroy; }
};
GameStub g_game;
GameStub& Game()
{
	return g_game;
}

#include "container_reject.inc"

// ---- the world of one scenario
namespace
{
constexpr u16 kActor = 0, kItem = 400, kOther = 401, kBox = 500, kTrader = 600, kHolder = 700;

bool plain_line(const char* tag)
{
	if (g_log.size() != 1)
		return false;
	const std::string& line = g_log.front();
	return line.rfind(tag, 0) == 0 && line.find('!') == std::string::npos;
}

bool has(const xr_vector<PIItem>& list, PIItem item)
{
	return std::find(list.begin(), list.end(), item) != list.end();
}

NET_Packet item_packet(u16 id, int flag = -1)
{
	NET_Packet P;
	P.w_u16(id);
	if (flag >= 0)
		P.w_u8(u8(flag));
	return P;
}

// ---- CLevel::cl_Process_Event, GE_DESTROY_REJECT
void level_reject_no_child()
{
	CGameObject holder;
	holder.m_id = kHolder;
	g_level.Objects.objects = {&holder};
	NET_Packet P = item_packet(kItem);
	g_level.cl_Process_Event(kHolder, GE_DESTROY_REJECT, P);
	check(holder.heard.empty(), "the holder hears nothing of a child that is no game object here");
	check(g_on_destroy == 0, "nothing is destroyed");
	check(plain_line("[coop] "), "one plain log line names it");
}

void level_reject_child()
{
	CGameObject holder, child;
	holder.m_id = kHolder;
	child.m_id = kItem;
	g_level.Objects.objects = {&holder, &child};
	NET_Packet P = item_packet(kItem);
	g_level.cl_Process_Event(kHolder, GE_DESTROY_REJECT, P);
	check(holder.heard.size() == 1 && holder.heard[0] == GE_OWNERSHIP_REJECT, "the holder hears taken out");
	check(child.heard.size() == 1 && child.heard[0] == GE_DESTROY, "then the child its destroy");
	check(g_on_destroy == 1, "the game hears the destroy");
	check(g_log.empty(), "no log line");
}

void level_other_event()
{
	CGameObject holder;
	holder.m_id = kHolder;
	g_level.Objects.objects = {&holder};
	NET_Packet P = item_packet(kItem);
	g_level.cl_Process_Event(kHolder, GE_OWNERSHIP_TAKE, P);
	check(holder.heard.size() == 1 && holder.heard[0] == GE_OWNERSHIP_TAKE, "other events go to the object as before");
	check(g_log.empty(), "no log line");
}

// ---- CInventoryBox::OnEvent
struct BoxWorld
{
	CInventoryBox box;
	CStalker actor;
	CItem item;
	BoxWorld()
	{
		box.m_id = kBox;
		actor.m_id = kActor;
		item.m_id = kItem;
		g_level.Objects.objects = {&actor, &box, &item};
	}
};

void box_reject_unlisted()
{
	BoxWorld w; // RL-QHQ3-2TUG: the take never reached the box, the item lies free
	w.box.m_items.push_back(kOther);
	w.box.m_in_use = true;
	NET_Packet P = item_packet(kItem);
	w.box.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.box.m_items.size() == 1 && w.box.m_items[0] == kOther, "the list keeps what it had");
	check(w.item.m_parent == nullptr, "the item stays free");
	check(g_box_callbacks == 0, "no take callback for an item the box did not hold");
	check(plain_line("[coop] box "), "one plain log line");
}

void box_reject_missing()
{
	BoxWorld w;
	g_level.Objects.objects = {&w.actor, &w.box}; // the item is no game object here
	w.box.m_items.push_back(kOther);
	NET_Packet P = item_packet(kItem);
	w.box.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.box.m_items.size() == 1 && w.box.m_items[0] == kOther, "the list keeps what it had");
	check(plain_line("[coop] box "), "one plain log line");
}

void box_reject_stale()
{
	BoxWorld w;
	g_level.Objects.objects = {&w.actor, &w.box}; // listed, but its game object is gone
	w.box.m_items = {};
	w.box.m_items.push_back(kItem);
	w.box.m_items.push_back(kOther);
	w.box.m_in_use = true;
	NET_Packet P = item_packet(kItem);
	w.box.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.box.m_items.size() == 1 && w.box.m_items[0] == kOther, "the stale id goes");
	check(g_box_callbacks == 0, "no take callback without a game object");
	check(plain_line("[coop] box "), "one plain log line");
}

void box_reject_held(u16 type, int flag, bool shell)
{
	BoxWorld w;
	w.box.m_items.push_back(kItem);
	w.item.m_parent = &w.box;
	w.box.m_in_use = true;
	NET_Packet P = item_packet(kItem, flag);
	w.box.OnEvent(P, type);
	check(w.box.m_items.empty(), "the id goes");
	check(w.item.m_parent == nullptr, "the item comes off the box");
	check(g_last_shell == shell, "with the stock shell decision");
	check(g_box_callbacks == 1, "the take callback of an open box");
	check(g_log.empty(), "the stock path says nothing");
}

void box_reject_held_elsewhere()
{
	BoxWorld w;
	w.box.m_items.push_back(kItem);
	w.item.m_parent = &w.actor; // the box lists it, the actor holds it
	w.box.m_in_use = true;
	NET_Packet P = item_packet(kItem);
	w.box.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.box.m_items.empty(), "the box's id goes");
	check(w.item.m_parent == &w.actor, "the actor keeps its item");
	check(g_box_callbacks == 0, "no take callback");
	check(plain_line("[coop] box "), "one plain log line");
}

void box_take()
{
	BoxWorld w;
	NET_Packet P = item_packet(kItem);
	w.box.OnEvent(P, GE_OWNERSHIP_TAKE);
	check(w.box.m_items.size() == 1 && w.box.m_items[0] == kItem, "the box lists it");
	check(w.item.m_parent == &w.box && !w.item.m_visible && !w.item.m_enabled, "and holds it hidden");
	check(g_log.empty(), "no log line");
}

// ---- CAI_Trader::OnEvent
struct TraderWorld
{
	CAI_Trader trader;
	CStalker actor;
	CItem item;
	CInventory trader_inv, actor_inv;
	TraderWorld()
	{
		trader.m_id = kTrader;
		actor.m_id = kActor;
		item.m_id = kItem;
		trader.m_inventory = &trader_inv;
		actor.m_inventory = &actor_inv;
		g_level.Objects.objects = {&actor, &trader, &item};
	}
	void give(CInventory& inv, CObject& holder)
	{
		inv.m_all.push_back(&item);
		inv.m_ruck.push_back(&item);
		item.m_pInventory = &inv;
		item.m_place = eItemPlaceRuck;
		item.m_parent = &holder;
	}
};

void trader_reject_missing()
{
	TraderWorld w; // RL-WKWE-CPCY, at net_Stop
	g_level.Objects.objects = {&w.actor, &w.trader};
	NET_Packet P = item_packet(kItem, 1);
	w.trader.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.trader_inv.m_drops == 0, "nothing to drop");
	check(plain_line("[coop] trader "), "one plain log line");
}

void trader_reject_foreign()
{
	TraderWorld w;
	w.give(w.actor_inv, w.actor);
	NET_Packet P = item_packet(kItem);
	w.trader.OnEvent(P, GE_OWNERSHIP_REJECT);
	check(w.trader_inv.m_drops == 0 && g_foreign_drops == 0, "the trader drops no item of another inventory");
	check(has(w.actor_inv.m_all, &w.item) && w.item.m_pInventory == &w.actor_inv, "the actor keeps it listed");
	check(w.item.m_parent == &w.actor, "and held");
	check(!w.item.m_tmp_pre_destroy, "the item is not touched");
	check(plain_line("[coop] trader "), "one plain log line");
}

void trader_reject_own(u16 type, int flag, bool before_destroy)
{
	TraderWorld w;
	w.give(w.trader_inv, w.trader);
	NET_Packet P = item_packet(kItem, flag);
	w.trader.OnEvent(P, type);
	check(w.trader_inv.m_drops == 1 && g_foreign_drops == 0, "the trader drops its own item once");
	check(w.trader_inv.m_drop_before_destroy == before_destroy, "with the packet's flag");
	check(w.trader_inv.m_drop_no_shell == (type == GE_TRADE_SELL || before_destroy), "and the stock shell decision");
	check(w.item.m_tmp_pre_destroy == before_destroy, "SetTmpPreDestroy as stock");
	check(w.item.m_parent == nullptr && !has(w.trader_inv.m_all, &w.item), "out and off");
	check(g_log.empty(), "the stock path says nothing");
}

// ---- CInventoryItem::net_Destroy
struct DestroyWorld
{
	CStalker owner;
	CItem item, other;
	CInventory inv;
	DestroyWorld()
	{
		owner.m_id = kActor;
		item.m_id = kItem;
		other.m_id = kOther;
		owner.m_inventory = &inv;
		g_level.Objects.objects = {&owner, &item, &other};
		inv.m_all.push_back(&other);
		inv.m_ruck.push_back(&other);
		other.m_pInventory = &inv;
		other.m_place = eItemPlaceRuck;
		item.m_pInventory = &inv;
		inv.m_all.push_back(&item);
	}
};

void item_destroy_listed(EItemPlaceType place)
{
	DestroyWorld w;
	w.item.m_place = place;
	(place == eItemPlaceRuck ? w.inv.m_ruck : w.inv.m_belt).push_back(&w.item);
	w.item.net_Destroy();
	check(!has(w.inv.m_all, &w.item) && !has(w.inv.m_ruck, &w.item) && !has(w.inv.m_belt, &w.item), "out of the lists");
	check(has(w.inv.m_all, &w.other) && has(w.inv.m_ruck, &w.other), "the other item stays");
	check(w.inv.m_fTotalWeight == 2.f && w.inv.m_invalidated == 1, "weight counted again, the state invalidated");
	check(w.item.m_pInventory == nullptr, "the item forgets the inventory");
	check(plain_line("[coop] item "), "one plain log line");
}

void item_destroy_slot()
{
	DestroyWorld w;
	w.item.m_place = eItemPlaceSlot;
	w.item.m_slot = 3;
	w.inv.m_slots[3] = &w.item;
	w.item.net_Destroy();
	check(!has(w.inv.m_all, &w.item), "out of the inventory's list");
	check(w.inv.ItemFromSlot(3) == &w.item, "the slot only the inventory's own code clears");
	check(w.item.m_pInventory == &w.inv, "the item keeps naming the inventory its slot belongs to");
	check(plain_line("[coop] item ") && g_log.front().find("slot") != std::string::npos, "one plain log line names the slot");
}

void item_destroy_owner_gone()
{
	DestroyWorld w;
	g_level.Objects.objects = {&w.item, &w.other}; // the owner went first: its inventory is not read
	w.item.m_place = eItemPlaceRuck;
	w.inv.m_ruck.push_back(&w.item);
	w.item.net_Destroy();
	check(has(w.inv.m_all, &w.item) && has(w.inv.m_ruck, &w.item), "nothing changes in a holder that is gone");
	check(w.inv.m_invalidated == 0 && w.item.m_pInventory == &w.inv, "stock");
	check(g_log.empty(), "no log line");
}

void item_destroy_let_go()
{
	DestroyWorld w;
	w.inv.m_all.erase(std::find(w.inv.m_all.begin(), w.inv.m_all.end(), &w.item)); // its holder let it go already
	w.item.m_place = eItemPlaceRuck;
	w.item.net_Destroy();
	check(w.inv.m_invalidated == 0 && w.item.m_pInventory == &w.inv, "stock: nothing to take out");
	check(g_log.empty(), "no log line");
}

void item_destroy_no_inventory()
{
	DestroyWorld w;
	w.inv.m_all.erase(std::find(w.inv.m_all.begin(), w.inv.m_all.end(), &w.item));
	w.item.m_pInventory = nullptr;
	w.item.net_Destroy();
	check(w.inv.m_invalidated == 0 && g_log.empty(), "an item without an inventory: stock");
}
} // namespace

int main(int argc, char** argv)
{
	if (argc != 2)
	{
		std::fprintf(stderr, "usage: container_reject <scenario>\n");
		return 2;
	}
	const std::string s = argv[1];
	if (s == "level-reject-no-child")
		level_reject_no_child();
	else if (s == "level-reject-child")
		level_reject_child();
	else if (s == "level-other-event")
		level_other_event();
	else if (s == "box-reject-unlisted")
		box_reject_unlisted();
	else if (s == "box-reject-missing")
		box_reject_missing();
	else if (s == "box-reject-stale")
		box_reject_stale();
	else if (s == "box-reject-held")
		box_reject_held(GE_OWNERSHIP_REJECT, 1, true);
	else if (s == "box-reject-held-keep-shell")
		box_reject_held(GE_OWNERSHIP_REJECT, 0, false);
	else if (s == "box-sell-held")
		box_reject_held(GE_TRADE_SELL, -1, true);
	else if (s == "box-reject-held-elsewhere")
		box_reject_held_elsewhere();
	else if (s == "box-take")
		box_take();
	else if (s == "trader-reject-missing")
		trader_reject_missing();
	else if (s == "trader-reject-foreign")
		trader_reject_foreign();
	else if (s == "trader-reject-own")
		trader_reject_own(GE_OWNERSHIP_REJECT, 1, true);
	else if (s == "trader-sell-own")
		trader_reject_own(GE_TRADE_SELL, -1, false);
	else if (s == "item-destroy-ruck")
		item_destroy_listed(eItemPlaceRuck);
	else if (s == "item-destroy-belt")
		item_destroy_listed(eItemPlaceBelt);
	else if (s == "item-destroy-slot")
		item_destroy_slot();
	else if (s == "item-destroy-owner-gone")
		item_destroy_owner_gone();
	else if (s == "item-destroy-let-go")
		item_destroy_let_go();
	else if (s == "item-destroy-no-inventory")
		item_destroy_no_inventory();
	else
	{
		std::fprintf(stderr, "unknown scenario %s\n", s.c_str());
		return 2;
	}
	for (const std::string& line : g_log)
		std::printf("log: %s\n", line.c_str());
	return g_failures ? 1 : 0;
}
