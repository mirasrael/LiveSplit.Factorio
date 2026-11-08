# LiveSplit auto splitter for Factorio 2.x

A [LiveSplit](https://livesplit.org/) auto splitter (`.asl`) for Factorio 2.x, including Space Age.

- **Game time** from the map's played ticks — the same clock the game uses for timed
  achievements (*There is no spoon*, *Getting on track like a pro*, …). Pausing the game pauses the timer.
- **Auto start** when a new map starts (optional auto reset).
- **Auto split** on tags you put in your segment names:

| Tag | Splits when |
|---|---|
| `[research:railway]` | the technology is researched |
| `[build:locomotive]` | at least one entity of that type has been built |
| `[build:lab=40]` | at least 40 have been built |
| `[rocket]`, `[rocket=3]` | the player force has launched 1 (or N) rockets |

Segments without a tag are split manually. Names are internal prototype names
(`railway`, `rocket-silo`, `advanced-oil-processing`, `locomotive`, `oil-refinery`, `biolab`, …),
as shown in the game's tooltips with *Show internal names* or on the wiki.

## How it works

The script only **reads** the game's memory — it does not modify the game, uses no mods
and does not disable achievements.

No memory addresses are hard-coded. On first attach the script loads `factorio.pdb`
(debug symbols shipped with the game next to `factorio.exe`) through Windows' `dbghelp.dll`,
resolves the addresses and structure offsets it needs by name, and caches them in
`%LOCALAPPDATA%\LiveSplit.Factorio\`. After a game update it re-resolves them automatically,
so it keeps working as long as the relevant structures keep their names.

Memory path used: `global → scenario → map → ticksPlayed`, the player force's technologies,
`rocketsLaunched`, and the force's entity build statistics.

## Install

1. Save `Factorio.asl` anywhere.
2. In LiveSplit: *Edit Layout → + → Control → Scriptable Auto Splitter*, set *Script Path* to the file.
3. *Compare Against → Game Time* (right-click LiveSplit), so the timer shows game time.
4. Add tags to your segment names — see [`examples/example-tags.lss`](examples/example-tags.lss).

## Limitations

- Windows, 64-bit Factorio with `factorio.pdb` present (Steam and standalone builds ship it).
- Victory (the end screen) is not detected yet — split the final segment manually.
- Multiplayer is untested; the script follows the force named `player`.
- Achievement unlocks are not used as triggers: the game does not keep a per-map "unlocked" flag
  for most of them. Use the underlying event instead (e.g. `[build:locomotive]` for
  *Getting on track like a pro*).

## License

MIT — see [LICENSE](LICENSE).
