# HoMM IV Remake for macOS

A native macOS reimplementation of *Heroes of Might and Magic IV* — Swift and Metal, no Wine.
The game's rules, formulas and screen layouts are read from the original files and from
`heroes4.exe` itself (reverse engineered), so that it plays like the original 1:1.

**No game data is included.** You need your own copy of the game (the GOG edition works); the
engine reads its `Data/*.h4r` archives and `maps/*.h4c` scenarios directly.

## Build and run

```bash
cd native
swift build -c release
./make_app.sh                                   # builds build/h4view.app
open build/h4view.app --args <path to>/Data/heroes4.h4r "<path to>/maps/Beyond the lake.h4c"
```

`swift test -c release -Xswiftc -enable-testing` runs the rule tests.

## What works

- **Adventure map** — terrain, transitions, roads and objects drawn from the game's own tiles,
  masks and sprites; random objects resolved as the game does; hero movement with the game's
  terrain costs, path arrows and day-count pointers; pickups, mines, dwellings, towns; the
  1024x768 adventure screen, minimap, hero and town lists; map scripts and scenario rules
  (teams, victory and loss conditions, timed / triggered / continuous events).
- **Towns** — the town screens with their buildings, animations and hover, building and
  recruiting with each map's allowed buildings.
- **Combat** — the battlefield, deployment and formations; turn order by speed and morale;
  damage, retaliation and every creature ability as `heroes4.exe` implements them; zones of
  control; walking and flying at each creature's own animation pace; hit, death and idle
  animations; the combat creature window; retreat and surrender.
- **Wandering monsters** — army size, escorts and splitting as the game generates them.

Still missing: spells and the spell book, sound and music, AI players, saving and loading.

## Layout

```
native/Sources/H4Engine   the engine: archives, sprites, maps, rules, combat, scripts
native/Sources/h4view     the macOS app: Metal renderer, screens, input
native/Tests              rule tests
tools/                    Python decoders for the game's formats (h4r, sprites, terrain, maps,
                          UI layers, fonts) -- each documents its format inside
```

## Tools

```bash
python3 tools/h4r.py list    Data/heroes4.h4r actor_sequence.   # list archive entries
python3 tools/h4r.py extract Data/heroes4.h4r out/              # unpack an archive
python3 tools/h4sprite.py out/.../some.h4d frames/              # sprite -> PNG frames
python3 tools/h4map.py Data/heroes4.h4r maps/X.h4c out/x        # map -> JSON + minimap
python3 tools/h4render.py Data/heroes4.h4r out/ maps/X.h4c x.png  # whole map -> PNG
python3 tools/h4layers.py layers.adventure.1024.h4d out/        # UI screen -> PNGs
```

---

## 中文说明

《魔法门之英雄无敌 IV》的 macOS 原生复刻版（Swift + Metal，不需要 Wine）。游戏规则、公式和界面布局
都直接从原版文件和逆向 `heroes4.exe` 得来，目标是与原版 1:1 一致。

**仓库不包含任何游戏资源。** 需要自备正版游戏（GOG 版即可），引擎直接读取其 `Data/*.h4r`
资源包和 `maps/*.h4c` 地图。构建与运行方法见上文。

已完成：冒险地图、城镇、战斗（全部生物技能、控制区、动画）、中立生物生成、地图脚本与胜负条件。
尚未完成：魔法系统、音乐音效、电脑玩家、存档读档。
