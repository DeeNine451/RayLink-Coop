# RayLink Coop — rules for agents (Codex reads this file; Claude reads CLAUDE.md with the same rules)

## Every mode is worked out separately (owner's decision, 2026-11-18)

The game has two modes that players switch on, and a transitional one:

- **Co-op**: the host plays, everybody is on one map. The host process has the player's map loaded and decides.
- **Server**: a world server process (a console) plus map servers. The world server decides and has no map of the player;
  the map server of the player's level reports the facts (`levels::body_facts`).
- **Hybrid** (transitional): the host plays and leads its own map, other maps are led by hidden map servers. Both paths at once.

For any feature, behaviour change or bug:

1. Before code, write down for each mode: who decides, what data it has, who reports what it lacks.
2. Keep the mode-specific part in its own function or file; shared pure logic lives in `engine/src/xrCoop/*_rules.h`.
3. Each mode gets its own test or stand scenario.
4. Report per mode on separate lines: done and checked / done, not checked / not done / not needed. Never leave a mode
   unsupported silently.

## Ownership

- Touch only the files your task names. You are not alone in this code base: never revert changes you did not make.
- No git index/HEAD writes, no vault notes, no nested agents.
- Never read, write or run anything under `E:\RayLinkGames\GAMMA\game`, `E:\Programs\RayLink` or `%APPDATA%\RayLink`.
  Copies for reading: `temp/review/corpus/`, `temp/stock_scripts/scripts/`; stand configs: `E:\RayLinkGames\GAMMA\game-dev\gamedata\`.
- Do not build the engine (the lead does, through `temp/build_guarded_fast.ps1`).
- Say "works" or "matches" only after a test or a command showed it; otherwise say "not checked".
