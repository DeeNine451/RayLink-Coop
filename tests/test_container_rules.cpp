// Anomaly Coop unit tests: a container that hears "taken out" of an item it does not hold (O1-container; crash reports of
// builds 56-57: RL-QHQ3-2TUG, RL-NHT6-8SZ3, RL-29NA-4ZS6 CInventoryBox::OnEvent, RL-WKWE-CPCY CAI_Trader::OnEvent; plausible
// #1710-1712, a destroyed item left in its holder's backpack).
//
// The rule (engine/src/xrCoop/coop_container_rules.h) and its wiring in four stock engine functions:
//   - CLevel::cl_Process_Event (Level.cpp), GE_DESTROY_REJECT: the holder hears GE_OWNERSHIP_REJECT only when the child is a
//     game object here (stock told it even when the child was not found);
//   - CInventoryBox::OnEvent (InventoryBox.cpp), GE_OWNERSHIP_REJECT / GE_TRADE_SELL: erase only an id the box lists (stock
//     erased end() in a release build: memmove of -2 bytes, access violation), detach only its own child;
//   - CAI_Trader::OnEvent (ai/trader/ai_trader.cpp), the same events: DropItem only of a found item its inventory lists (stock
//     read a null item);
//   - CInventoryItem::net_Destroy (inventory_item.cpp): an item that goes away while a live holder's inventory still lists it
//     is taken out of the lists (stock only VERIFYed it in a debug build).
// The engine files cannot be linked into this exe: the wiring is checked on their source (comments dropped, white space
// folded), as tests/test_move_admission_wiring.cpp does; tests/tools/test_container_reject.py executes the four functions.
// COOP_ENGINE_SRC=<dir> reads the engine sources from that copy of engine/src instead (mutation checks).
//
// Both modes run this code unchanged (the Core never asks the mode): a co-op client and a player's client of a map server
// apply the decider's moves through their local server; the co-op host, the map server and the world server keep the game
// objects of an online container's children, where the rule changes nothing.
#include "test_util.h"

#include "coop_container_rules.h"

#include <cstdlib>
#include <fstream>
#include <regex>
#include <string>

namespace
{
namespace c = coop::container;

std::string engine_source(const char* relative)
{
	std::string root;
	if (const char* other = std::getenv("COOP_ENGINE_SRC"))
		root = other;
	else
	{
		const std::string here = __FILE__;
		const size_t slash = here.find_last_of("/\\");
		root = (slash == std::string::npos ? std::string(".") : here.substr(0, slash) + "/..") + "/engine/src";
	}
	const std::string path = root + "/" + relative;
	std::ifstream in(path, std::ios::binary);
	if (!in.good())
		t::report_failure(__FILE__, __LINE__, "cannot read " + path);
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

// One top-level function (it closes at the start of a line), comments dropped, white space folded. Empty when absent.
std::string function_of(const std::string& source, const char* signature)
{
	const size_t start = source.find(signature);
	if (start == std::string::npos)
		return std::string();
	const size_t end = source.find("\n}", start);
	if (end == std::string::npos)
		return std::string();
	std::string body = std::regex_replace(source.substr(start, end + 2 - start), std::regex(R"(//[^\n]*)"), "");
	return std::regex_replace(body, std::regex(R"(\s+)"), " ");
}

void expect_has(const std::string& code, const char* what, const char* fragment)
{
	if (code.find(fragment) == std::string::npos)
		t::report_failure(__FILE__, __LINE__, std::string(what) + ": missing \"" + fragment + "\"");
}

void expect_not(const std::string& code, const char* what, const char* fragment)
{
	if (code.find(fragment) != std::string::npos)
		t::report_failure(__FILE__, __LINE__, std::string(what) + ": must not have \"" + fragment + "\"");
}

size_t count_of(const std::string& code, const char* fragment)
{
	size_t n = 0;
	for (size_t at = code.find(fragment); at != std::string::npos; at = code.find(fragment, at + 1))
		++n;
	return n;
}

bool same(const c::BoxStep& s, bool unlist, bool detach, bool note)
{
	return s.unlist == unlist && s.detach == detach && s.note == note;
}

bool same(const c::Leftover& l, bool unlist, bool forget, bool note)
{
	return l.unlist == unlist && l.forget == forget && l.note == note;
}
} // namespace

// ---- the rule

// A holder drops (DropItem: out of the lists and off the holder together) only an item that is a game object here and
// that it lists. A trader reached a null item (b57) or would drop another holder's item.
TEST(container_rules_reject_applies_only_to_a_listed_game_object)
{
	CHECK(c::reject_applies(true, true));
	CHECK(!c::reject_applies(true, false)); // the item is someone else's (or nobody's): nothing of ours to undo
	CHECK(!c::reject_applies(false, true)); // no game object: DropItem would read a null item
	CHECK(!c::reject_applies(false, false)); // RL-WKWE-CPCY
}

// A box keeps ids (m_items) and attaches game objects (H_Parent) separately: it erases only an id it lists and detaches only
// its own child. Any other combination is one plain log line.
TEST(container_rules_box_reject_erases_only_a_listed_id_and_detaches_only_its_child)
{
	// child found, listed, held by the box: the stock path, nothing to say
	CHECK(same(c::box_reject(true, true, true), true, true, false));
	// child found, not listed, not held: b56 RL-QHQ3-2TUG (the take never reached the box): nothing to do
	CHECK(same(c::box_reject(true, false, false), false, false, true));
	// child found, listed, held by someone else: the id goes, the other holder keeps its child
	CHECK(same(c::box_reject(true, true, false), true, false, true));
	// child found, not listed, held by the box: it comes off, the list had nothing to erase
	CHECK(same(c::box_reject(true, false, true), false, true, true));
	// no game object, listed: the stale id goes (AddAvailableItems would hand the UI a null item)
	CHECK(same(c::box_reject(false, true, false), true, false, true));
	// no game object, not listed: nothing at all
	CHECK(same(c::box_reject(false, false, false), false, false, true));
	// "held" without a game object cannot be true; the rule still never detaches nothing
	CHECK(!c::box_reject(false, true, true).detach);
	CHECK(!c::box_reject(false, false, true).detach);
}

// An item that goes away while the inventory it names still lists it: taken out only when that inventory's owner is still
// in the level (else its memory is gone and is never read). A slot only the inventory's own code clears: the item leaves
// the lists but keeps naming the inventory the slot belongs to.
TEST(container_rules_leftover_on_destroy_takes_out_only_from_a_live_holder)
{
	CHECK(same(c::leftover_on_destroy(true, true, false), true, true, true));   // backpack or belt: out, forgotten, logged
	CHECK(same(c::leftover_on_destroy(true, true, true), true, false, true));   // a slot: out of the lists, the slot stays
	CHECK(same(c::leftover_on_destroy(true, false, false), false, false, false)); // the holder let it go: stock
	CHECK(same(c::leftover_on_destroy(false, true, false), false, false, false)); // the holder went first: never read
	CHECK(same(c::leftover_on_destroy(false, false, false), false, false, false));
	CHECK(same(c::leftover_on_destroy(false, true, true), false, false, false));
}

// ---- the wiring (stock engine files, CRLF, read as text)

TEST(container_wiring_level_tells_the_holder_only_of_a_found_child)
{
	const std::string code = function_of(engine_source("xrGame/Level.cpp"), "void CLevel::cl_Process_Event(");
	REQUIRE(!code.empty());
	const char* what = "CLevel::cl_Process_Event";
	expect_has(code, what,
	    "if (ok) { GO->OnEvent(P, GE_OWNERSHIP_REJECT); Game().OnDestroy(GD); GD->OnEvent(P, GE_DESTROY); } else Msg(\"[coop] ");
	CHECK_EQ(count_of(code, "GO->OnEvent(P, GE_OWNERSHIP_REJECT);"), size_t(1));
	expect_not(code, what, "} GO->OnEvent(P, GE_OWNERSHIP_REJECT); if (ok)");
	expect_not(code, what, "Msg(\"[coop] !");
	// the rest of the stock function stays: the other events go to the object as before
	expect_has(code, what, "if (type == GE_DESTROY) { Game().OnDestroy(GO); } GO->OnEvent(P, type);");
}

TEST(container_wiring_box_reject_erases_and_detaches_by_the_rule)
{
	const std::string code = function_of(engine_source("xrGame/InventoryBox.cpp"), "void CInventoryBox::OnEvent(");
	REQUIRE(!code.empty());
	const char* what = "CInventoryBox::OnEvent";
	expect_has(code, what,
	    "it = std::find(m_items.begin(), m_items.end(), id); const coop::container::BoxStep step = "
	    "coop::container::box_reject(itm != nullptr, it != m_items.end(), itm && itm->H_Parent() == this); "
	    "if (step.unlist) m_items.erase(it);");
	expect_has(code, what, "if (step.note) Msg(\"[coop] box ");
	expect_has(code, what,
	    "if (!step.detach) break; itm->H_SetParent(NULL, dont_create_shell); if (m_in_use) {");
	expect_not(code, what, "VERIFY(it!=m_items.end()); m_items.erase(it);");
	CHECK_EQ(count_of(code, "m_items.erase("), size_t(1));
	expect_not(code, what, "Msg(\"[coop] box !");
	// the packet is read as before: the flag after the id, then the shell decision
	expect_has(code, what,
	    "bool just_before_destroy = !P.r_eof() && P.r_u8(); bool dont_create_shell = (type == GE_TRADE_SELL) || "
	    "just_before_destroy;");
	// the take path is stock
	expect_has(code, what, "m_items.push_back(id); itm->H_SetParent(this); itm->setVisible(FALSE); itm->setEnabled(FALSE);");
}

TEST(container_wiring_trader_drops_only_a_listed_game_object)
{
	const std::string code = function_of(engine_source("xrGame/ai/trader/ai_trader.cpp"), "void CAI_Trader::OnEvent(");
	REQUIRE(!code.empty());
	const char* what = "CAI_Trader::OnEvent";
	const char* guard =
	    "CInventoryItem* item = Obj ? smart_cast<CInventoryItem*>(Obj) : nullptr; "
	    "if (!coop::container::reject_applies(Obj != nullptr, item && item->m_pInventory == &inventory())) { Msg(\"[coop] trader ";
	const char* drop =
	    "break; } Obj->SetTmpPreDestroy(just_before_destroy); "
	    "inventory().DropItem(smart_cast<CGameObject*>(Obj), just_before_destroy, dont_create_shell);";
	expect_has(code, what, guard);
	expect_has(code, what, drop);
	const size_t read = code.find("bool dont_create_shell = (type == GE_TRADE_SELL) || just_before_destroy;");
	CHECK(read != std::string::npos);
	CHECK(read < code.find(guard));
	CHECK(code.find(guard) < code.find(drop));
	CHECK_EQ(count_of(code, "Obj->SetTmpPreDestroy("), size_t(1));
	CHECK_EQ(count_of(code, "inventory().DropItem("), size_t(1));
	expect_not(code, what, "Msg(\"[coop] trader !");
}

TEST(container_wiring_item_destroy_takes_out_its_leftover)
{
	const std::string code = function_of(engine_source("xrGame/inventory_item.cpp"), "void CInventoryItem::net_Destroy()");
	REQUIRE(!code.empty());
	const char* what = "CInventoryItem::net_Destroy";
	// the inventory is read only when its owner is still a registered object (pointer compare, no read of the owner)
	expect_has(code, what,
	    "CInventoryOwner* owner = g_pGameLevel->Objects.o_get_by_iterator(i)->cast_inventory_owner(); "
	    "if (owner && &owner->inventory() == m_pInventory) inv = m_pInventory;");
	expect_has(code, what, "coop::container::leftover_on_destroy(inv != nullptr, listed, in_slot)");
	expect_has(code, what, "if (left.unlist) {");
	expect_has(code, what, "list->erase(it);");
	expect_has(code, what, "inv->CalcTotalWeight(); inv->InvalidateState();");
	expect_has(code, what, "if (left.note) Msg(\"[coop] item ");
	expect_has(code, what, "if (left.forget) m_pInventory = NULL;");
	expect_not(code, what, "VERIFY(std::find(m_pInventory->m_all");
	expect_not(code, what, "DropItem(");
	expect_not(code, what, "Msg(\"[coop] item !");
}
