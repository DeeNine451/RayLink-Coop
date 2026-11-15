"""Writes the DLTX files of the Brain Scorcher pilot (coop_scorcher.script) beside the stock logic files. LF endings."""
import pathlib
import re

ROOT = pathlib.Path(r"D:\Projects\ForEverything\anomaly-coop")
STOCK = ROOT / "temp" / "stock_configs" / "configs" / "scripts"
OUT = ROOT / "gamedata" / "configs" / "scripts"
F = "bar_deactivate_radar_done"
HEAD = (";; Anomaly Coop - the Brain Scorcher for two sides (gamedata\\scripts\\coop_scorcher.script), DLTX beside the stock %s.\n"
        ";; Outside a co-op world with split levels the first branch of every changed line is the stock outcome (and a missing\n"
        ";; coop_* condition is skipped by xr_logic, which lands on that first branch too).\n\n")


def sections(text):
    out, cur = {}, None
    for line in text.splitlines():
        line = line.split(";", 1)[0].strip()
        m = re.match(r"^\[([^\]]+)\]", line)
        if m:
            cur = m.group(1)
            out[cur] = {}
        elif cur and "=" in line:
            k, v = line.split("=", 1)
            out[cur][k.strip()] = v.strip()
    return out


def write(rel, body):
    stock = STOCK / rel
    assert stock.exists(), rel
    p = OUT / pathlib.Path(rel).parent / ("mod_" + pathlib.Path(rel).stem + "_coop_scorcher.ltx")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((HEAD % pathlib.Path(rel).name + body).encode("ascii"))
    print("wrote", p.relative_to(ROOT))


def psy(rel, dead):
    s = sections((STOCK / rel).read_text("cp1251"))
    body = ""
    n = 0
    for name, kv in s.items():
        if name.startswith("sr_psy_antenna@") and kv.get("on_info2") == "{+%s} %s" % (F, dead):
            n += 1
            body += ("![%s]\non_info2 = {+%s !coop_split_mode} %s, {+%s} sr_idle@coop_scorcher_off\n"
                     "on_info3 = {!coop_actor_monolith}, sr_idle@coop_monolith\n\n") % (name, F, dead, F)
    assert n == 3, (rel, n)
    body += "[sr_idle@coop_scorcher_off]\non_info = {-%s} sr_psy_antenna@no_helmet\n\n" % F
    body += ("[sr_idle@coop_monolith]\non_info = {!coop_actor_monolith} sr_psy_antenna@no_helmet\n"
             "on_info2 = {+%s !coop_split_mode} %s, {+%s} sr_idle@coop_scorcher_off\n") % (F, dead, F)
    if dead == "sr_idle@nil":
        body += "\n![sr_idle@nil]\non_info = {-%s !coop_split_mode}, {-%s} sr_psy_antenna@no_helmet\n" % (F, F)
    write(rel, body)


for rel in ["radar/rad_psy_zone_1.ltx", "radar/rad_psy_zone_2.ltx", "radar/rad_psy_zone_3.ltx", "radar/rad_psy_zone_8.ltx",
            "pripyat/pri_psy_zone_1.ltx", "stancia_1/aes1_psy_zone_1.ltx", "stancia_2/aes2_psy_zone_1.ltx"]:
    psy(rel, "nil")
psy("bunker/bun_psi_radiotion_75.ltx", "sr_idle@nil")

for i in range(1, 5):
    rel = "radar/rad_antenna_particle_0%d.ltx" % i
    s = sections((STOCK / rel).read_text("cp1251"))
    assert "sr_idle@nil" in s and "sr_idle@check_switch" in s, rel
    write(rel, "![sr_idle@nil]\non_info = {-%s !coop_split_mode}, {-%s} sr_idle@check_switch\n" % (F, F))

for rel in ["radar/rad_sound_drone.ltx", "radar/rad_sound_thunder.ltx"]:
    s = sections((STOCK / rel).read_text("cp1251"))
    assert s["sr_idle@off"]["on_game_timer2"] == "100 | nil", rel
    write(rel, "![sr_idle@off]\non_game_timer2 = 100 | {!coop_split_mode} nil, sr_idle@coop_scorcher_off\n\n"
               "[sr_idle@coop_scorcher_off]\non_info = {-%s} sr_idle@on\n" % F)

for suffix in ["", "_0000", "_0001", "_0002", "_0003", "_0004"]:
    rel = "bunker/bun_space_restrictor_sound1%s.ltx" % suffix
    s = sections((STOCK / rel).read_text("cp1251"))
    assert s["sr_idle@off"]["on_signal"].replace(" ", "") == "sound_end|sr_idle@nil", rel
    write(rel, "![sr_idle@nil]\non_info = {-%s !coop_split_mode}, {-%s} sr_idle@on\n" % (F, F))

write("bunker/bunker_primary_switcher.ltx",
      "![ph_button@rad_on]\n"
      "on_press = {!coop_split_mode} ph_button@rad_off %%+%s%%, {=coop_scorcher_can_off} ph_button@rad_off %%+%s =coop_scorcher_flipped(off)%%, %%=coop_scorcher_refused%%\n\n"
      "![ph_button@rad_off]\n"
      "on_press = {!coop_split_mode}, {=coop_scorcher_can_on} ph_button@rad_on %%-%s =coop_scorcher_flipped(on)%%, %%=coop_scorcher_refused%%\n"
      % (F, F, F))
