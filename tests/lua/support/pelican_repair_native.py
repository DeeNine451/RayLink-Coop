"""Run the Lua repair outcomes through the production native ItemState methods."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[3]
work = ROOT / "temp/pelican_weapon_jam/native" / uuid.uuid4().hex[:8]
work.mkdir(parents=True)

# Reuse the existing extraction and registry fixture without changing its source.
spec = importlib.util.spec_from_file_location("ammo_extraction", ROOT / "tests/tools/test_client_ammo_reload.py")
extraction = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extraction)
source = (ROOT / "engine/src/xrGame/coop/coop_items.cpp").read_text(encoding="utf-8-sig")
# The ammo harness's production state, types and methods (one list there, kept in step with coop_items.cpp). Its CEatableItem
# keeps the engine's portions and their bound (eatable_item.h).
types = extraction.item_types(source)
methods = extraction.item_methods(source)
harness = (ROOT / "tests/tools/fixtures/client_ammo_reload.cpp").read_text(encoding="utf-8")
harness = harness[:harness.index("int main(")]
harness = harness.replace("// ITEM_TYPES", types).replace("// ENGINE_METHODS", methods)
case_source = Path(__file__).with_name("pelican_repair_native.cpp").read_text(encoding="utf-8")
fixture = work / "repair.cpp"
fixture.write_text(harness + case_source, encoding="utf-8")
runner = work / "repair.exe"
vcvars = Path(r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
include = ROOT / "engine/src/xrCoop"
wire = include / "coop_wire.cpp"
command = work / "compile.cmd"
command.write_text(
    f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
    f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{include}" "{fixture}" "{wire}" /Fe"{runner}"\n'
    'exit /b %ERRORLEVEL%\n', encoding="utf-8")
build = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work, capture_output=True, text=True, timeout=120)
if build.returncode:
    print(build.stdout + build.stderr)
    sys.exit(build.returncode)
sys.exit(subprocess.run([str(runner), str(Path(sys.argv[1]).resolve())], cwd=ROOT, timeout=30).returncode)
