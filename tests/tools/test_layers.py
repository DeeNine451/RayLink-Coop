"""tools/check_layers.py: the border of the three layers (docs/MODES.md section 5).

Fixture trees: tests/tools/fixtures/layers/clean is a tiny tree with one file of every layer and two allow-listed
lines (ceiling 2); every other folder there is an overlay copied on top of it that breaks one rule. The rv_* overlays
are the adversarial reviewer's trees of 2026-11-18 (temp/modes_review/trees: only the files that differ from his clean
tree), each a way to put a mode check into Ядро that got through the first version of the checker. The n*_ and b6_
overlays are the second review's attacks (temp/modes_review2/new_attacks.py: N2-N10, N12) that got through the second.
Run: python -m pytest tests\\tools\\test_layers.py -q
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import check_layers as check
from conftest import ROOT

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "layers"
SCRIPT = ROOT / "tools" / "check_layers.py"
LINE = re.compile(r"^(?P<path>[^\s:][^:]*):(?P<line>\d+): \[(?P<rule>L\d+C?)\] ")


def make(work: Path, *overlays: str) -> Path:
    root = work / "tree"
    shutil.copytree(FIXTURES / "clean", root)
    for name in overlays:
        shutil.copytree(FIXTURES / name, root, dirs_exist_ok=True)
    return root


def run(root: Path, capsys: pytest.CaptureFixture[str], *extra: str) -> tuple[int, str]:
    code = check.main(["--root", str(root), *extra])
    return code, capsys.readouterr().out


def violations(out: str) -> list[tuple[str, int, str]]:
    found = []
    for line in out.splitlines():
        m = LINE.match(line)
        if m:
            found.append((m.group("path"), int(m.group("line")), m.group("rule")))
    return found


def rules(out: str) -> set[str]:
    return {rule for _, _, rule in violations(out)}


# --- the clean tree ---------------------------------------------------------------------------------------------------

def test_clean_tree_passes(work, capsys):
    code, out = run(make(work), capsys)
    assert code == 0, out
    assert violations(out) == []
    assert re.search(r"^check_layers: OK \(\d+ files, ceiling 2, used 2\)$", out, re.M), out


def test_strings_and_comments_are_not_code(work, capsys):
    # coop_net.cpp and coop_items.script name predicates only inside a string and a comment
    code, out = run(make(work), capsys)
    assert code == 0, out
    assert "coop_net.cpp:1" not in out and "coop_items.script" not in out


# --- one fixture per rule ---------------------------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("overlay", "rule", "path", "line"),
    [
        ("l1_cpp", "L1", "engine/src/xrGame/coop/coop_items.cpp", 7),
        ("l1_lua", "L1", "gamedata/scripts/coop_items.script", 12),
        ("l2", "L2", "engine/src/xrGame/coop/coop_items.cpp", 7),
        ("l3_cpp", "L3", "engine/src/xrGame/coop/coop_items.cpp", 3),
        ("l3_srv_hostplay", "L3", "engine/src/xrGame/coop/coop_mapserver.cpp", 4),
        ("l3_lua", "L3", "gamedata/scripts/coop_items.script", 12),
        ("l3_lua", "L3", "gamedata/scripts/coop_items.script", 13),
        ("l4", "L4", "engine/src/xrCoop/coop_roles.h", 9),
        ("l4", "L4", "engine/src/xrCoop/coop_roles.h", 12),
        ("l5", "L5", "engine/src/xrGame/Level.cpp", 4),
        ("l6", "L6", "engine/src/xrGame/coop/coop_items.cpp", 3),
        ("l7", "L7", "gamedata/scripts/coop_big.script", 192),
        ("l8", "L8", "gamedata/scripts/coop_items.script", 12),
        ("l9", "L9", "gamedata/scripts/coop_levels.script", 19),
        ("l10", "L10", "tools/persisted_keys.txt", 2),
    ],
)
def test_each_rule_fails_with_its_id(work, capsys, overlay, rule, path, line):
    code, out = run(make(work, overlay), capsys)
    assert code == 1, out
    assert (path, line, rule) in violations(out), out
    assert re.search(r"^check_layers: FAIL \(\d+\)$", out, re.M), out


def test_registration_inside_when_srv_passes_and_outside_fails(work, capsys):
    code, out = run(make(work, "l9"), capsys)
    found = [v for v in violations(out) if v[2] == "L9"]
    assert found == [("gamedata/scripts/coop_levels.script", 19, "L9")], out  # line 21 is inside when_srv


def test_srv_file_may_name_the_predicates(work, capsys):
    # coop_mapserver.cpp / coop_levels_far.cpp (srv) and coop_levels.script (srv) are full of them in the clean tree
    code, out = run(make(work), capsys)
    assert code == 0, out


def test_l4_ignores_defaults_without_a_mode_word(work, capsys):
    code, out = run(make(work, "l4"), capsys)
    l4 = sorted(line for path, line, rule in violations(out) if rule == "L4")
    assert l4 == [9, 12], out  # `mirror = false`, `seats{4}`, `limit = 8`, `HostLike = 1` (enum) pass


# --- taint: a wrapper of a mode check is a mode check (critique H3) ---------------------------------------------------

def test_cpp_wrapper_from_another_file_and_its_wrapper_are_tainted(work, capsys):
    code, out = run(make(work, "taint_cpp"), capsys)
    assert code == 1, out
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_death.cpp")}
    assert (6, "L1") in found, out  # return levels::leads_here(); (leads_here returns is_map_server() || dedicated::on())
    assert (11, "L1") in found, out  # if (ghost()): ghost returns leads_here()
    assert "leads_here" in out


def test_lua_local_wrapper_alias_and_chain_are_tainted(work, capsys):
    code, out = run(make(work, "taint_lua"), capsys)
    assert code == 1, out
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_death.script")}
    assert (5, "L1") in found, out  # the predicate itself
    assert (8, "L1") in found, out  # local split = coop.levels.split
    assert (11, "L1") in found, out  # return authority(): judge is a wrapper of a wrapper
    assert (15, "L1") in found, out  # if judge() then
    assert (18, "L1") in found, out  # if split() then (alias)


# --- the adversarial review: every tree that got through is caught (temp/modes_review, 2026-11-18) ---------------------

X = "engine/src/xrGame/coop/coop_x.cpp"
XS = "gamedata/scripts/coop_x.script"


@pytest.mark.parametrize(("overlay", "expected"), [
    # missing predicates (item 8)
    ("rv_l1e_split_levels", {(X, 6, "L1")}),                     # if (g_coop_split_levels)
    ("rv_l1f_world_server", {(X, 6, "L1")}),                     # if (g_coop_world_server != 0)
    ("rv_l1g_story_together", {(X, 6, "L1"), (X, 6, "L6")}),    # g_coop_story_together: the word boundary after "_"
    ("rv_l2a_has_role", {(X, 6, "L1")}),                         # has_role(ProcessRole::WorldServer)
    ("rv_l1i_command_line", {(X, 6, "L1")}),                     # strstr(Core.Params, "-coop_mapserver")
    # using namespace and namespace aliases (item 8)
    ("rv_l1b_namespace_alias", {(X, 7, "L1")}),                  # namespace lv = coop::levels; lv::remote2()
    ("rv_l1c_using_namespace", {(X, 7, "L1")}),                  # using namespace coop::levels; remote2()
    ("rv_l1h_using_dedicated", {(X, 6, "L1")}),                  # using namespace coop::dedicated; on()
    ("rv_l3c_entry_using", {(X, 7, "L3")}),                      # using namespace coop::levels; frame()
    # macros (item 8)
    ("rv_l1j_macro", {(X, 4, "L1"), (X, 7, "L1")}),              # #define ASK(p) coop::mapserver::p##_map_server()
    ("rv_l1k_srv_macro", {(X, 7, "L1")}),                        # COOP_REMOTE() of a srv header Ядро includes
    # Lua (item 8)
    ("rv_luaa_table_alias", {(XS, 3, "L1")}),                    # local L = coop.levels; L.split()
    ("rv_luab_indexed_field", {(XS, 2, "L1")}),                  # coop.levels["split"]()
    ("rv_luad_g_index", {(XS, 2, "L3")}),                        # _G["coop_levels"].key()
    # L9 (item 9)
    ("rv_l9a_register_alias", {("gamedata/scripts/coop_srv_x.script", 1, "L9"),
                               ("gamedata/scripts/coop_srv_x.script", 3, "L9")}),
    ("rv_l9b_register_indexed", {("gamedata/scripts/coop_srv_x.script", 1, "L9"),
                                 ("gamedata/scripts/coop_srv_x.script", 2, "L9")}),
    ("rv_luaf_monkeypatch", {("gamedata/scripts/coop_srv_y.script", 1, "L9")}),
    # a new file of ours outside the two Ядро folders is core, not stock (item 10)
    ("rv_layc_new_file", {("engine/src/xrGame/ui/UIRayPanel.cpp", 1, "L1")}),
    # the dying list is frozen: a row that calls an Ядро file dying is ignored
    ("rv_layb_dying_row", {(X, 6, "L1")}),
    # server functions reached from Ядро without srv_entry.txt
    ("rv_l1a_long_srv_wrapper", {(X, 6, "L3")}),                 # a long srv wrapper: Ядро calls a srv function
    ("rv_l3b_declared_srv_function", {(X, 7, "L3")}),            # declared in Ядро instead of included
    ("rv_l3d_entry_pointer", {(X, 6, "L3")}),                    # &coop::levels::online_at_server
    ("rv_l3a_include_macro", {(X, 3, "L3")}),                    # #include HDR
    ("rv_l4b_default_in_cpp", {(X, 4, "L4")}),                   # a bool mode default in a .cpp
])
def test_review_hole_is_caught(work, capsys, overlay, expected):
    code, out = run(make(work, overlay), capsys)
    assert code == 1, out
    assert expected <= set(violations(out)), out


def test_more_cpp_predicates(work, capsys):
    code, out = run(make(work, "l1_more_predicates"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path == X}
    assert found == {(6, "L1"), (8, "L1"), (10, "L1"), (12, "L2"), (16, "L1"), (20, "L1")}, out
    # 14: has_role(ProcessRole::Player) is is_player (one meaning in both modes); 18: "-coop_connect" is no mode key


def test_more_lua_references(work, capsys):
    code, out = run(make(work, "lua_more"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path == XS}
    assert found == {(5, "L3"), (6, "L3"), (7, "L1"), (8, "L1"), (9, "L1")}, out  # 10: the facade coop_mode passes


def test_l9_registrations_and_patches_outside_when_srv(work, capsys):
    code, out = run(make(work, "l9_more"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L9")
    assert found == [4, 5, 6, 7, 8], out  # 9-11 its own tables, 14-16 inside coop_mode.when_srv


# --- the second review: server code that runs in the co-op process although nothing names a mode (2026-11-18) -------

POLICY_SRV = "engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp"


def test_srv_file_defining_a_member_of_a_core_class_is_l3(work, capsys):
    # B2 / N2: Ядро calls far_policy().keep_online(id) through an object; the body lives in a srv file
    code, out = run(make(work, "n2_member_of_core_class"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if path.startswith("engine/src/xrGame/coop/")}
    assert found == {(POLICY_SRV, 5, "L3")}, out  # coop_far_ledger.cpp defines its own Ledger (a homonym): not counted
    assert "FarPolicy" in out


def test_static_initializer_with_a_call_in_srv_is_l9c(work, capsys):
    # B3 / N3: `static const bool registered = (coop::hooks::set_skip(&far_skip), true);` runs in every process
    code, out = run(make(work, "n3_static_init"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_far_skip" in path}
    assert found == {("engine/src/xrGame/coop/srv/coop_far_skip.cpp", 9, "L9C")}, out
    # 10, 11: no call; 14: a class member; 18: a function-local static (runs when the function runs)
    assert code == 1


def test_core_extern_of_a_srv_global_is_l3(work, capsys):
    # B4 / N4: `extern bool g_far_world;` in Ядро, `bool g_far_world = false;` in a srv file
    code, out = run(make(work, "n4_extern"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_farread" in path or "srv_world" in path}
    assert found == {("engine/src/xrGame/coop/coop_farread.cpp", 2, "L3")}, out  # g_core_count is an Ядро global


def test_srv_script_patching_tables_not_its_own_is_l9(work, capsys):
    # B5 / N5 (sim_board, smart_terrain: stock scripts outside the repository) and N9 (db.coop_far_world)
    code, out = run(make(work, "n5_patch_foreign"), capsys)
    found = {(path.rsplit("/", 1)[-1], line) for path, line, rule in violations(out) if rule == "L9"}
    assert found == {("coop_srv_far_squads.script", 3), ("coop_srv_far_squads.script", 9),
                     ("coop_srv_world.script", 5)}, out  # a local table, its own global, inside when_srv: pass


def test_srv_script_calls_at_load_outside_when_srv_are_l9(work, capsys):
    # B6 / N6 (timers, per-frame calls), N7 (console), N8 (an Ядро setter), and a call at file level
    code, out = run(make(work, "n6_load_calls"), capsys)
    found = {(path.rsplit("/", 1)[-1], line) for path, line, rule in violations(out) if rule == "L9"}
    assert found == {("coop_srv_far_tick.script", 6), ("coop_srv_far_tick.script", 7), ("coop_srv_far_tick.script", 8),
                     ("coop_srv_far_console.script", 3), ("coop_srv_far_console.script", 4),
                     ("coop_srv_far_console.script", 5),
                     ("coop_srv_far_hud.script", 3), ("coop_srv_far_hud.script", 4),
                     ("coop_srv_far_file.script", 2)}, out  # file.script:3 calls only inside function bodies


def test_srv_script_pure_lookups_at_load_pass(work, capsys):
    # B6: rawget, string.*, math.*, tonumber, type, setmetatable, class, table.insert into a local, calls in bodies
    code, out = run(make(work, "b6_pure_lookups"), capsys)
    assert [v for v in violations(out) if "coop_srv_far_ok" in v[0]] == [], out
    assert code == 0, out


def test_core_cpp_naming_a_srv_script_in_a_string_is_l3(work, capsys):
    # B7 / N10: lua_getglobal(L, "coop_srv_far") (the precedent: coop_join.cpp `lua_getglobal(L, "coop_dedicated")`)
    code, out = run(make(work, "n10_cpp_string"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_farcall.cpp")}
    assert found == {(6, "L3"), (8, "L3")}, out  # 7: coop_items is an Ядро script


def test_stock_patch_scripts_are_scanned(work, capsys):
    # B9 / N12: engine/gamedata/scripts and gamedata_gamma/scripts are stock Lua: L3 for a srv script, L5 for a mode name
    code, out = run(make(work, "n12_stock_lua"), capsys)
    found = set(violations(out))
    assert {("engine/gamedata/scripts/axr_main.script", 3, "L3"), ("engine/gamedata/scripts/axr_main.script", 5, "L5"),
            ("gamedata_gamma/scripts/coop_menu_theme.script", 3, "L3")} <= found, out
    assert ("engine/gamedata/scripts/axr_main.script", 4, "L3") not in found, out  # coop_items is Ядро


def test_member_l4_in_a_cpp_counts_only_true(work, capsys):
    # the review's BaseSeen::here alarm: a false default on a data row of a .cpp is the safe value; headers keep the rule
    code, out = run(make(work, "l4_member_cpp"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L4" and path.endswith("coop_checkpoint_x.cpp"))
    assert found == [7, 10], out  # 6: here = false, 8: level_known{false}; 10: a parameter default stays


# --- the third review: what still ran in the co-op process (temp/modes_review3/review3.md, C1-C8) -----------------------

def l9_lines(out: str, name: str) -> list[int]:
    return sorted(line for path, line, rule in violations(out) if rule == "L9" and path.endswith(name))


def test_self_alias_of_a_foreign_table_is_not_own(work, capsys):
    # C1: `local db = db` made db "own", so `db.coop_far_world = true` in on_game_start passed
    code, out = run(make(work, "c1_self_alias"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_world_alias.script") == [7, 8], out  # 9, 10: its own table and a copy of it


def test_when_srv_given_the_result_of_a_call_is_l9(work, capsys):
    # C2: when_srv(hide_far_spots()) calls hide_far_spots at load; its body runs at load too
    code, out = run(make(work, "c2_when_srv_call"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_far_spots.script") == [3, 4, 8], out  # 9: a function, 10: an anonymous one
    assert "gets the result of a call" in out


def test_setmetatable_on_a_foreign_table_is_l9(work, capsys):
    # C3: setmetatable was a pure lookup; on db.storage it makes a shared table weak in every process
    code, out = run(make(work, "c3_setmetatable"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_memory.script") == [2, 7], out  # 3: a new table, 5: its own table
    assert "sets the metatable of db" in out


def test_function_assigned_to_on_game_start_and_its_callees_run_at_load(work, capsys):
    # C4: `on_game_start = start`; start calls arm(); both bodies run at load
    code, out = run(make(work, "c4_assigned_start"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_far_start.script") == [6, 9, 10], out  # 14: later() never runs at load


def test_core_script_naming_a_srv_script_in_a_plain_string_is_l3(work, capsys):
    # C6: a dispatch table of script names read through rawget(_G, name)
    code, out = run(make(work, "c6_dispatch_string"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_price_hooks.script")}
    assert found == {(2, "L3")}, out  # coop_items is Ядро
    assert "coop_srv_far_prices" in out


def test_static_object_with_a_constructor_in_srv_is_l9c(work, capsys):
    # C7: `static Registrar s_registrar;` runs Registrar() (which registers a hook) in every process
    code, out = run(make(work, "c7_static_ctor"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L9C" and path.endswith("coop_far_reg.cpp"))
    assert found == [12, 13], out  # 18: Plain has no constructor; 19: a pointer; 20: a declaration
    assert "the constructor Registrar()" in out


def test_static_member_of_a_core_class_defined_in_srv_is_l3(work, capsys):
    # C8: `u32 FarLimits::squads_per_player = 4;` in a srv file; Ядро reads FarLimits::squads_per_player
    code, out = run(make(work, "c8_static_member"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_far_limits" in path}
    assert found == {("engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp", 2, "L3")}, out
    assert "static member FarLimits::squads_per_player" in out


# --- false alarms of the review's replay (item 11) --------------------------------------------------------------------

def test_l4_counts_only_bool_defaults(work, capsys):
    code, out = run(make(work, "l4_bool_only"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L4" and path.endswith("coop_route_rules.h"))
    assert found == [10, 13], out  # 9: uint16_t level = kNoLevel and 12: uint32_t host_peer = 0 are data


def test_l5_flags_server_hooks_not_core_hooks(work, capsys):
    code, out = run(make(work, "l5_hooks"), capsys)
    l5 = {(path, line) for path, line, rule in violations(out) if rule == "L5"}
    assert l5 == {("engine/src/xrGame/alife_x.cpp", 4),        # an entry point, in a file without "coop"
                  ("engine/src/xrGame/alife_y.cpp", 5),        # a srv function with a neutral name
                  ("engine/src/xrGame/actor_hook.cpp", 6)}, out  # a mode predicate
    # actor_hook.cpp:5 calls coop::items::may_pick, an Ядро function: a stock edit is an Ядро change for the gate anyway


def test_void_function_does_not_taint(work, capsys):
    code, out = run(make(work, "taint_void"), capsys)
    found = sorted(line for path, line, rule in violations(out) if path.endswith("coop_players.cpp"))
    assert found == [6, 11, 17], out  # 16: equip_loading_frame() is a command, not a question


# --- the layer of a file ----------------------------------------------------------------------------------------------

def test_default_layer_of_new_files():
    layers = check.parse_layers((FIXTURES / "clean/tools/layers.txt").read_text(encoding="utf-8"), FIXTURES / "clean")
    assert layers.layer_of("engine/src/xrGame/Level.cpp") == "stock"              # in the stock list
    assert layers.layer_of("engine/src/xrGame/ui/UIRayPanel.cpp") == "core"       # a new file of ours: core
    assert layers.layer_of("engine/src/xrEngine/raylink_version.h") == "core"
    assert layers.layer_of("gamedata/scripts/coop_new_area.script") == "core"
    assert layers.layer_of("gamedata/scripts/coop_srv_new_area.script") == "srv"  # by its prefix
    assert layers.layer_of("gamedata/scripts/coop_hostplay_menu.script") == "hostplay"
    assert layers.layer_of("engine/src/xrCoop/coop_soft_move.h") == "dying"
    real = check.parse_layers((ROOT / "tools/layers.txt").read_text(encoding="utf-8"), ROOT)
    assert real.layer_of("engine/src/xrGame/ui/UIRayPanel.cpp") == "core"
    assert real.layer_of("engine/src/xrGame/Level.cpp") == "stock"
    assert real.layer_of("engine/src/xrGame/coop/srv/coop_srv_new.cpp") == "srv"
    assert real.layer_of("engine/src/xrGame/coop/coop_new.cpp") == "core"


def test_stock_rows_need_the_stock_list(work, capsys):
    root = make(work)
    layers = root / "tools" / "layers.txt"
    layers.write_text(layers.read_text(encoding="utf-8").replace("stock-list tools/stock_files.txt\n", ""),
                      encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 2 and "stock-list" in out, out
    root2 = make(work / "b")
    (root2 / "tools" / "stock_files.txt").unlink()
    code, out = run(root2, capsys)
    assert code == 2 and "stock_files.txt" in out, out


# --- the ceiling: today's lines may stay, the count only goes down ----------------------------------------------------

def allow_text(root: Path) -> str:
    return (root / "tools" / "layers_allow.txt").read_text(encoding="utf-8")


def add_line(path: Path, after: str, line: str) -> None:
    text = path.read_text(encoding="utf-8")
    assert after in text
    path.write_text(text.replace(after, after + "\n" + line, 1), encoding="utf-8", newline="\n")


def test_allowed_line_may_stay_and_one_more_fails(work, capsys):
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    add_line(net, "\tif (mgr().is_host()) send_all();", "\tif (mgr().is_host()) send_all();")
    code, out = run(root, capsys)
    assert code == 1, out
    assert ("engine/src/xrGame/coop/coop_net.cpp", 10, "L2") in violations(out), out
    assert "2 found, 1 allowed" in out


def test_one_fewer_passes_and_write_allow_lowers_the_ceiling(work, capsys):
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    net.write_text(net.read_text(encoding="utf-8").replace("\tif (mgr().is_host()) send_all();", "\tsend_all();"),
                   encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 0, out
    assert "stale" in out and "ceiling 2, used 1" in out
    code, out = run(root, capsys, "--write-allow")
    assert code == 0, out
    text = allow_text(root)
    assert text.startswith("# ceiling: 1\n"), text
    assert "coop_net.cpp" not in text
    code, out = run(root, capsys)
    assert code == 0 and "ceiling 1, used 1" in out, out


def test_entries_above_the_ceiling_fail(work, capsys):
    root = make(work, "l2")
    allow = root / "tools" / "layers_allow.txt"
    allow.write_text(allow_text(root) + "L2|engine/src/xrGame/coop/coop_items.cpp|if (mgr().is_client()) return false;|1\n",
                     encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 1, out
    assert "above its ceiling" in out


def test_write_allow_refuses_to_raise_the_ceiling_without_reset(work, capsys):
    root = make(work, "l2")
    before = allow_text(root)
    code, out = run(root, capsys, "--write-allow")
    assert code == 1, out
    assert "--reset-ceiling" in out
    assert allow_text(root) == before
    code, out = run(root, capsys, "--write-allow", "--reset-ceiling")
    assert code == 0, out
    assert allow_text(root).startswith("# ceiling: 3\n")


def test_write_allow_does_not_trade_a_dropped_line_for_a_new_one(work, capsys):
    # the review's ALLOW-b: drop the allowed L2 line, add a new mode check; the sum stays under the ceiling
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    net.write_text(net.read_text(encoding="utf-8").replace("\tif (mgr().is_host()) send_all();", "\tsend_all();"),
                   encoding="utf-8", newline="\n")
    items = root / "engine/src/xrGame/coop/coop_items.cpp"
    items.write_text(items.read_text(encoding="utf-8").replace(
        "\treturn owner == 0 || owner == me;", "\tif (coop::mapserver::is_map_server()) return false;\n"
        "\treturn owner == 0 || owner == me;"), encoding="utf-8", newline="\n")
    before = allow_text(root)
    code, out = run(root, capsys, "--write-allow")
    assert code == 1 and "new or grown" in out and "is_map_server" in out, out
    assert allow_text(root) == before
    code, out = run(root, capsys)
    assert code == 1, out


def test_write_allow_is_deterministic(work, capsys):
    root = make(work, "taint_cpp", "l5")
    run(root, capsys, "--write-allow", "--reset-ceiling")
    first = allow_text(root)
    run(root, capsys, "--write-allow", "--reset-ceiling")
    assert allow_text(root) == first
    entries = [l for l in first.splitlines() if l and not l.startswith("#")]
    assert entries == sorted(entries)
    assert int(first.splitlines()[0].split(":")[1]) == sum(int(e.rsplit("|", 1)[1]) for e in entries)


# --- a file moved between layers --------------------------------------------------------------------------------------

def test_srv_file_moved_into_core_fails(work, capsys):
    root = make(work)
    src = root / "engine/src/xrGame/coop/coop_mapserver.cpp"
    src.rename(src.with_name("coop_mapserver_moved.cpp"))  # no srv row matches the new name: core
    code, out = run(root, capsys)
    assert code == 1, out
    assert ("engine/src/xrGame/coop/coop_mapserver_moved.cpp", 6, "L1") in violations(out), out
    assert ("engine/src/xrGame/coop/coop_mapserver_moved.cpp", 13, "L1") in violations(out), out


def test_core_file_moved_into_srv_leaves_a_stale_entry_only(work, capsys):
    root = make(work)
    layers = root / "tools" / "layers.txt"
    layers.write_text(layers.read_text(encoding="utf-8") + "srv engine/src/xrGame/coop/coop_net.cpp\n",
                      encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 0, out
    assert "stale" in out


# --- inputs and the script ------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["layers.txt", "layers_allow.txt", "srv_entry.txt", "persisted_keys.txt"])
def test_missing_input_is_exit_2(work, capsys, name):
    root = make(work)
    (root / "tools" / name).unlink()
    code, out = run(root, capsys)
    assert code == 2, out
    assert name in out


def test_runs_isolated_as_a_script(work):
    root = make(work, "l1_cpp")
    done = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)], capture_output=True, text=True)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "engine/src/xrGame/coop/coop_items.cpp:7: [L1] " in done.stdout


# --- the real tree ----------------------------------------------------------------------------------------------------

@pytest.mark.skipif(not (ROOT / "engine" / "src" / "xrCoop").is_dir(), reason="engine sources are not checked out")
def test_real_tree_is_within_its_ceiling():
    done = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, cwd=ROOT)
    assert done.returncode == 0, done.stdout[-4000:] + done.stderr
    assert done.stdout.strip().splitlines()[-1].startswith("check_layers: OK")


def test_real_allow_list_is_sorted_and_well_formed():
    path = ROOT / "tools" / "layers_allow.txt"
    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines[0].startswith("# ceiling: ")
    entries = [l for l in lines if l and not l.startswith("#")]
    assert entries == sorted(entries)
    assert int(lines[0].split(":")[1]) >= sum(int(e.rsplit("|", 1)[1]) for e in entries)
