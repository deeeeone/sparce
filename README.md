# Sparce

A native macOS game launcher for Apple Silicon. It runs Windows games through Wine with Metal-backed graphics, and turns PS5 titles you own into Mac games using [AnyPS5](https://github.com/boykopovar/AnyPS5).

> Windows games aren't "native": Sparce translates Windows calls (Wine) and DirectX (D3DMetal / DXMT / DXVK) to macOS and Metal, and x86 code runs through Rosetta 2. Performance is usually good, but not identical to a real Mac port.

## Features

- **Wine engines, one click:** Game Porting Toolkit 3 (Apple's Wine + D3DMetal, built by [Gcenx](https://github.com/Gcenx/game-porting-toolkit)) or the latest [Wine Staging](https://github.com/Gcenx/macOS_Wine_builds). You can also add your own build, such as a CrossOver-based one.
- **Choose the graphics layer per game:**
  - **D3DMetal**: DX11/DX12 to Metal. Fastest for most modern games. Optional DirectX Raytracing.
  - **DXMT**: open-source DX10/11 to Metal.
  - **DXVK (macOS fork)**: DX9–11 to Vulkan to MoltenVK. Most compatible.
  - **WineD3D**: OpenGL fallback for very old games.
- **Performance settings:** MSync, Rosetta AVX reporting, Retina mode, Metal HUD, frame cap (DXVK), quiet logs, and custom environment variables.
- **Bottles:** separate Wine prefixes per engine, one-click Steam install, winecfg, run any .exe/.msi, force-quit.
- **PS5 Porter (AnyPS5):** converts a PS5 title folder into a macOS x86-64 Mach-O that runs under Rosetta (`relinker --macos --to-rosetta`). There's also a fallback that builds the Windows version and runs it in Wine. Sparce can clone and build the relinker for you.

## Install

Requires macOS 14+ on Apple Silicon.

```bash
git clone <this repo> && cd sparce
./scripts/bundle.sh          # needs Xcode or the Command Line Tools
open build/Sparce.app
```

Every push also builds `Sparce.zip` in GitHub Actions (Actions → latest run → Artifacts). The app is ad-hoc signed, so on first launch right-click it and choose **Open**.

## First run

1. **Components:** install Rosetta if asked, then download **Game Porting Toolkit 3**. Optionally download **DXVK**.
2. **Bottles:** create a bottle using that engine.
3. **Library:** add a game's `.exe`, or use **Install Steam** in the bottle. Press **Play**.

If a game crashes or renders badly, open its settings (slider icon) and try another translation layer: D3DMetal, then DXMT, then DXVK.

### D3DMetal

The Game Porting Toolkit engine is expected to include D3DMetal; Bottles and Components show a "D3DMetal" tag on engines where it's found. If yours doesn't have it, download *Game Porting Toolkit* from developer.apple.com, open the disk image, and import its `redist/lib` folder in **Components → D3DMetal**. Apple's licence doesn't allow Sparce to download it for you.

### DXMT

DXMT has no official releases yet. Download a build artifact from [3Shain/dxmt](https://github.com/3Shain/dxmt) (Actions tab), unzip it, and use **Components → DXMT → Import**. DXMT needs a CrossOver-based Wine (24+), which you add with **Add existing Wine build…**.

## PS5 Porter

You need:

| What | Where it comes from |
|---|---|
| `relinker` | **Build relinker from source** in the app (`brew install cmake ninja` first), or build it yourself with AnyPS5's `-DANYPS5_RELINKER_ONLY=ON` CMake option |
| Runtime libs (`libs/*.prx`) | AnyPS5 releases ship them **for Linux and Windows only**. The macOS target needs libs built for macOS (x86-64). |
| MoltenVK (macOS target) | The [LunarG Vulkan SDK](https://vulkan.lunarg.com/sdk/home#mac). Its libraries are universal, so they load under Rosetta. Homebrew's arm64-only MoltenVK won't. |
| A title folder | Dumped from **your own** console: `eboot.bin` (decrypted ELF) + `sce_module/` + resources |

Sparce never decrypts anything. If `eboot.bin` is a decrypted SELF, set the AnyPS5 source folder and Sparce runs AnyPS5's `tools/unwrap_self.py` on it.

Output goes to `~/Library/Application Support/Sparce/PS5/<title>/`:

```
game        (macOS)  or  app.exe (Windows target)
libs/*.prx
app0/       (copy of your title folder)
```

AnyPS5 also requires a GPU with Vulkan 1.1 and Zen 2 CPU features (AVX2, FMA, BMI…). On Apple Silicon both come from translation (MoltenVK and Rosetta's AVX support plus `--to-rosetta`), so compatibility depends on the title.

## Tips for a MacBook Air

- The Air has no fan and slows down once it's hot. Cap the frame rate (30 or 60) and lower the in-game resolution.
- Keep Retina mode off unless the game is light. It renders at up to 4× the pixels.
- macOS Game Mode turns on automatically when a game is fullscreen.
- Games with kernel anti-cheat (Valorant, Fortnite, many online shooters) won't run under any Wine-based launcher.

## Where things live

| | |
|---|---|
| Engines, bottles, components, PS5 ports | `~/Library/Application Support/Sparce/` |
| Game logs | `~/Library/Logs/Sparce/` |

## Licence

Sparce's own code is MIT. Wine is LGPL, DXVK is zlib, DXMT and AnyPS5 are GPL-2.0, and D3DMetal is under Apple's licence. Sparce downloads these separately and doesn't bundle them.
