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
| `[inventory:transport-belt=100]`, `[inv:…]` | the player's character carries at least N of that item (all qualities) |

- **Retry a segment by loading a save**: game time follows the save's ticks, and every split
  made after the moment the save was taken is undone automatically, so the segment can be
  split again (setting *rewind*, on by default).
- **Continue from any save**: when a save is loaded (or LiveSplit attaches to an already
  loaded map), the script finds the last segment whose `research` / `build` / `rocket` tag is
  already satisfied and skips every segment up to it — including untagged ones in between —
  starting the timer if needed (setting *catchup*, on by default). Segments are *skipped*, not
  split, so no fake times end up in your golds. Inventory tags are ignored for this, since
  items get used up.

Tags can also be kept out of the segment names: put them in `<splits>.steps.txt` next to the
`.lss` as a `split:` line under the segment (see the step panel below):

```
> Рельсы ×2 крафта
split: build:locomotive
```

A tag in the segment name wins over the steps file. The file is re-read when saved.

Segments without a tag are split manually. Names are internal prototype names
(`railway`, `rocket-silo`, `advanced-oil-processing`, `locomotive`, `oil-refinery`, `biolab`, …),
as shown in the game's tooltips with *Show internal names* or on the wiki. When a map is
loaded, tags naming an unknown technology, entity or item are reported in the log
(`[Factorio] unknown … name`, visible in DebugView).

Tips for tags that work well with catch-up: use a technology or build count that is only
reached at the *end* of the segment. A tag that can become true early (e.g. a cheap research
done long before its segment) makes catch-up skip too far. Build counts are lifetime totals
across all surfaces, so count the entities from earlier segments too.

## How it works

The script only **reads** the game's memory — it does not modify the game, uses no mods
and does not disable achievements.

No memory addresses are hard-coded. On first attach the script loads `factorio.pdb`
(debug symbols shipped with the game next to `factorio.exe`) through Windows' `dbghelp.dll`,
resolves the addresses and structure offsets it needs by name, and caches them in
`%LOCALAPPDATA%\LiveSplit.Factorio\`. After a game update it re-resolves them automatically,
so it keeps working as long as the relevant structures keep their names.

Memory path used: `global → scenario → map → ticksPlayed`, the player force's technologies,
`rocketsLaunched`, the force's entity build statistics, and the first player's character
main inventory (`players[0] → physicalController → character → inventory`).

## Install

1. Save `Factorio.asl` anywhere.
2. In LiveSplit: *Edit Layout → + → Control → Scriptable Auto Splitter*, set *Script Path* to the file.
3. *Compare Against → Game Time* (right-click LiveSplit), so the timer shows game time.
4. Add tags to your segment names — see [`examples/example-tags.lss`](examples/example-tags.lss).

## Step panel with icons (optional)

`component/` contains **Factorio Step**, a LiveSplit layout component that shows what the
current segment needs, with the game's icons and live counters:
items in the inventory (`165/50`), entities built over the run (`6/30`) and research (`✓`).
Done entries turn green.

- Build and install (close LiveSplit first): `component\build.ps1 -Install`
  (uses the .NET Framework compiler that ships with Windows; finds a winget or
  Program Files LiveSplit install, or pass `-LiveSplit <folder>`).
- *Edit Layout → + → Information → Factorio Step*, below the splits. Keep the
  Scriptable Auto Splitter with `Factorio.asl` in the same layout: the script publishes the
  counters, the panel only draws them.
- The list for each segment comes from `<splits>.steps.txt` next to the `.lss`
  (see [`examples/factorio-space-age-rsng-achievements.steps.txt`](examples/factorio-space-age-rsng-achievements.steps.txt)):

```
# "> text" = the segment whose name starts with this text
> Крафт: 50 лент
transport-belt=50 inserter=40 small-electric-pole=50 electric-mining-drill=25
build:steam-engine=30 research:railway rocket=1
note: optional line of text
split: build:locomotive
```

  The `split:` line is shown too. Without an entry, the panel shows the tags of the segment name. The file is re-read when saved.
- Icons are read from the game's `data` folder (found from the running game, or set it in
  the component settings).

## Is this allowed?

The script only reads memory of a game running on your own computer: no injection, no
writes, no mods, and no game files or PDB data are redistributed here. Asked on the
official forum, a Factorio developer replied that, while not a legally binding answer,
Wube doesn't mind what people do with the game on their computers as long as it isn't
illegal or gets them in legal trouble — see
[the forum thread](https://forums.factorio.com/viewtopic.php?t=136884).

## Limitations

- Windows, 64-bit Factorio with `factorio.pdb` present (Steam and standalone builds ship it).
- Victory (the end screen) is not detected yet — split the final segment manually.
- Multiplayer is untested; the script follows the force named `player`.
- Achievement unlocks are not used as triggers: the game does not keep a per-map "unlocked" flag
  for most of them. Use the underlying event instead (e.g. `[build:locomotive]` for
  *Getting on track like a pro*).

## License

MIT — see [LICENSE](LICENSE).
