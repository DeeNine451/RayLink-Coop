"""Execute CTextureDescrMngr (engine/src/Layers/xrRender/TextureDescrManager.{h,cpp}) on real threads (package O4-thm).

Reports #128, #63, #801: Load() starts the threads 'X-Ray THM Loader 1' ($game_textures$) and 'X-Ray THM Loader 2'
($level$); both wrote into one pair of xr_map without a lock, and nothing waited for them while the main thread already
created shaders that read the maps. The class is cut out of the header and the whole .cpp (its #include lines dropped)
is compiled with fixtures/texture_descr_slice.cpp over small stand-ins for xrCore, the file system and thread_spawn.
Every game process with a renderer loads THMs at startup, whatever its role (Core: a stock file).

  COOP_TEST_OUT=<dir>     the work folder is <dir>/texture_descr_slice (default: temp/texture_descr_slice)
  COOP_THM_CPP=<file>     cut the .cpp out of this copy instead (mutation checks); COOP_THM_H=<file> the same for the header;
  COOP_THM_MERGE_H=<file> compile against this copy of texture_descr_merge.h
"""
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition

RENDER = ROOT / "engine/src/Layers/xrRender"
SCENARIOS = ["merged", "waits", "reload", "unload-early", "destroy-early", "double-load", "many-readers", "ends-first",
             "level-ends-first", "random"]


def _work():
    out = os.environ.get("COOP_TEST_OUT")
    return (Path(out) if out else ROOT / "temp") / "texture_descr_slice"


def _body(cpp):
    lines = cpp.read_text(encoding="utf-8-sig").splitlines()
    kept = [line for line in lines if not line.lstrip().startswith(("#include", "#pragma hdrstop"))]
    return "\n".join(kept) + "\n"


@pytest.fixture(scope="module")
def thm_runner():
    work = _work()
    work.mkdir(parents=True, exist_ok=True)
    header = Path(os.environ.get("COOP_THM_H") or RENDER / "TextureDescrManager.h")
    cpp = Path(os.environ.get("COOP_THM_CPP") or RENDER / "TextureDescrManager.cpp")
    (work / "thm_class.inc").write_text(definition(header, "class CTextureDescrMngr") + ";\n", encoding="utf-8")
    (work / "thm_body.inc").write_text(_body(cpp), encoding="utf-8")
    merge_copy = work / "texture_descr_merge.h"  # found before the real one (/I work comes first)
    if os.environ.get("COOP_THM_MERGE_H"):
        shutil.copyfile(os.environ["COOP_THM_MERGE_H"], merge_copy)
    elif merge_copy.exists():
        merge_copy.unlink()
    fixture = Path(__file__).parent / "fixtures/texture_descr_slice.cpp"
    runner = work / "texture_descr_slice.exe"
    if runner.exists():
        runner.unlink()
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /W3 /wd4091 /I"{work}" /I"{RENDER}" "{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=300)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_texture_descr_lookups_see_the_merged_thm_maps(thm_runner, scenario):
    run = subprocess.run([str(thm_runner), scenario], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, f"{scenario} exited {run.returncode:#x}\n{run.stdout}\n{run.stderr}"
