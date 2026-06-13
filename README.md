# Project Name

> One-line description of your project.

---

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| [Odin](https://odin-lang.org/docs/install/) | Compiler | `C:\tools\odin` |
| [OLS](https://github.com/DanielGavin/ols) | Language server + formatter | `C:\tools\ols` |
| [RAD Debugger](https://github.com/EpicGamesExt/raddebugger/releases) | Debugger | `C:\tools\rad` |
| [GNU Make](https://gnuwin32.sourceforge.net/packages/make.htm) | Build runner | `C:\tools\make` (or via Chocolatey) |

All tools must be on `PATH`. Verify with:

```bat
odin version
ols --version
raddbg --help
make --version
```

VS Code extensions needed: **Odin Language** (`DanielGavin.ols`), **C/C++** (`ms-vscode.cpptools`), and optionally **Error Lens** (`usernamehw.errorlens`) for inline error display.

---

## Project Structure

```
project/
├── src/                  # Source code (the `src` collection)
│   └── main.odin
├── tests/                # Test packages (odin test)
├── libs/                 # Vendored third-party libs (git subtree)
├── bin/                  # Build output  [gitignored]
├── .raddbg/              # RAD Debugger state  [gitignored]
├── .vscode/
│   ├── tasks.json        # Build/run/debug tasks (Ctrl+Shift+B)
│   ├── launch.json       # In-editor cppvsdbg debugging (F5)
│   └── settings.json
├── Makefile
├── ols.json              # OLS language server config
├── odinfmt.json          # odinfmt formatter config
└── deps.txt              # Dependency manifest (committed)
```

---

## Quick Start

```bat
git clone <repo-url> my-project
cd my-project
make run
```

---

## Daily Workflow

### Building

```bat
make              # debug build    → bin/<project>_debug.exe  [DEFAULT]
make package      # release build  → bin/<project>.exe
make check        # type-check only, no output binary
```

### Running

```bat
make run          # build debug + run
make run-release  # build release + run
```

### Debugging with RAD Debugger

```bat
make debug         # build + open raddbg + auto-run
make debug-step    # build + open raddbg + pause at entry point
make debug-open    # build + open raddbg (don't run yet)
```

**Tip:** Add these to your VS Code `keybindings.json` for quick access (matches IntelliJ conventions):

```json
[
  {
    "key": "ctrl+f9",
    "command": "workbench.action.tasks.build"
  },
  {
    "key": "shift+f9",
    "command": "-editor.debug.action.toggleInlineBreakpoint"
  },
  {
    "key": "shift+f9",
    "command": "-workbench.action.debug.start"
  },
  {
    "key": "shift+f9",
    "command": "workbench.action.tasks.runTask",
    "args": "Debug: Open (raddbg)"
  },
  {
    "key": "shift+f10",
    "command": "-editor.action.showContextMenu"
  },
  {
    "key": "shift+f10",
    "command": "-workbench.action.tasks.reRunTask"
  },
  {
    "key": "shift+f10",
    "command": "workbench.action.tasks.runTask",
    "args": "Run"
  }
]
```

### In-Editor Debugging (lighter alternative to raddbg)

Press **F5** or use the **Run and Debug** panel. This uses `cppvsdbg` (the Visual Studio debugger) directly inside VS Code — useful for quick checks, but RAD Debugger is recommended for real debugging sessions.

### Testing

```bat
make test           # run all tests in tests/ with memory leak detection
make test-strict    # same, with full vet + warnings-as-errors
make test-debug     # debug tests in raddbg
```

Odin's built-in test runner detects memory leaks automatically via `Tracking_Allocator`. Output is per-test with pass/fail counts.

### Formatting

Formatting happens automatically **on save** in VS Code via OLS (configured in `odinfmt.json`). To format manually from the terminal:

```bat
make fmt            # format all .odin files in src/
make fmt-tests      # format all .odin files in tests/
```

---

## Make Targets Reference

| Target | Description |
|--------|-------------|
| `make` / `make build` | Debug build |
| `make package` | Release build (optimized) |
| `make check` | Type-check, no binary |
| `make check-strict` | Check with full vet + fatal warnings |
| `make run` | Debug build and run |
| `make run-release` | Release build and run |
| `make debug` | Open raddbg + auto-run |
| `make debug-step` | Open raddbg + pause at entry |
| `make debug-open` | Open raddbg, don't run yet |
| `make test` | Run all tests |
| `make test-strict` | Tests with full vet |
| `make test-debug` | Debug tests in raddbg |
| `make fmt` | Format src/ |
| `make fmt-tests` | Format tests/ |
| `make clean` | Delete bin/ |
| `make clean-all` | Delete bin/ and .raddbg/ |
| `make info` | Show current configuration |
| `make deps` | List all dependencies |
| `make get NAME=x URL=y BRANCH=z` | Add dependency via git subtree |
| `make update NAME=x` | Update one dependency |
| `make update-all` | Update all dependencies |
| `make remove NAME=x` | Remove a dependency |

### Flag Overrides

Any flag variable can be overridden on the command line:

```bat
make package RELEASE_FLAGS="-o:speed -no-bounds-check -disable-assert"
make build   VET_FLAGS="-vet -strict-style -warnings-as-errors"
make test    TEST_FLAGS="-define:ODIN_TEST_FANCY=false"
make build   EXTRA_FLAGS="-target:linux_amd64"
```

---

## Dependency Management

Dependencies are vendored via **git subtree** — they live in `libs/` and are committed to your repo. No submodules, no lock files, no package manager.

```bat
# Add a dependency
make get NAME=sokol URL=https://github.com/floooh/sokol-odin BRANCH=main

# Update one dependency
make update NAME=sokol

# Update all dependencies
make update-all

# Remove a dependency
make remove NAME=sokol
```

The `libs/` directory is registered as a collection named `libs` in both the compiler (`-collection:libs=./libs`) and OLS (`ols.json`), so imports work as:

```odin
import "libs/sokol"
```

### Vendor collection (batteries included)

The Odin compiler ships with a `vendor:` collection that already includes bindings for raylib, SDL2/3, OpenGL, Vulkan, Dear ImGui, stb, GLFW, miniaudio, Box2D, and more. Use these before adding external deps:

```odin
import rl "vendor:raylib"
```

---

## Configuration

### Switching to a library project

In the `Makefile`, change:

```makefile
PROJECT_TYPE := lib
```

In `lib` mode, `make build` runs `odin check` (no output binary). The `run`, `run-release`, and `debug*` targets are disabled.

### Disabling `-vet -strict-style`

The Makefile enables vet flags for all builds by default (community standard). To turn them off temporarily:

```bat
make build VET_FLAGS=
```

To disable permanently, edit the `VET_FLAGS` line in the Makefile.

### OLS notes

- `enable_semantic_tokens` is off by default for performance (it resolves all symbols on every keystroke).
- `enable_checker_only_saved` means OLS only runs `odin check` when you save a file, not on every change.
- OLS tracks the Odin compiler's **master branch**. If you update Odin, also rebuild OLS to avoid crashes from version mismatches.
