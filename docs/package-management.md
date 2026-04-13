# Package management with Pixi

mobin uses [Pixi](https://pixi.sh) as its package manager and task runner.

## Why Pixi?

Mojo packages are distributed through Conda channels (`conda.modular.com`). Pixi is a fast, cross-platform package manager built on the Conda ecosystem with several properties that make it the right fit for Mojo projects:

- **Conda-native.** Pixi resolves packages from Conda channels directly, so Mojo libraries installed via `pixi install` are immediately available to the compiler. No shims, no separate toolchain step.
- **Lockfile.** `pixi.lock` pins every transitive dependency (Mojo compiler version, C libraries like openssl/zlib, and Mojo packages) to exact builds. Two developers running `pixi install` get byte-identical environments.
- **Git dependencies.** Mojo libraries that aren't published to a channel yet can be pulled straight from a Git repo:

  ```toml
  flare = { git = "https://github.com/ehsanmok/flare.git", branch = "main" }
  ```

  Pixi clones, builds, and caches the Mojo package automatically.
- **Task runner.** `pixi run <task>` replaces Makefiles. Tasks can set working directories, chain dependencies, and override per-platform:

  ```toml
  [tasks]
  tests = { cmd = "mojo $MOJO_FLAGS tests/test_db.mojo", cwd = "backend" }
  build = { cmd = "mojo build $MOJO_FLAGS main.mojo -o mobin-backend", cwd = "backend" }

  [target.linux-64.tasks]
  build = { cmd = "mojo build $MOJO_FLAGS main.mojo -o mobin-backend -Xlinker -ldl", cwd = "backend" }
  ```

- **Multi-platform.** A single `pixi.toml` declares `platforms = ["linux-64", "osx-arm64", "linux-aarch64"]`. The lockfile contains resolved packages for all three, so CI (Linux) and local dev (macOS) share the same manifest.
- **Environments.** Dev-only tools (compilers, linters) live in a `dev` feature that production builds don't pull in:

  ```toml
  [feature.dev.dependencies]
  gxx        = ">=13"
  pre-commit = ">=4.2.0,<5"

  [environments]
  default = { features = ["dev"], solve-group = "default" }
  ```

- **Fast.** Pixi uses a Rust-based SAT solver. A cold `pixi install` for mobin (Mojo compiler + 8 libraries + system deps) completes in under 30 seconds. Warm installs are near-instant.
- **CI integration.** The official [setup-pixi](https://github.com/prefix-dev/setup-pixi) GitHub Action installs Pixi and resolves dependencies in one step:

  ```yaml
  - uses: prefix-dev/setup-pixi@v0.8.8
  - run: pixi run tests
  ```

## Pinning the Mojo version

mobin pins the Mojo compiler to an exact nightly build to avoid MLIR bytecode incompatibilities between the compiler and prebuilt Mojo packages:

```toml
mojo = "==0.26.3.0.dev2026041305"
```

All upstream dependencies (flare, json, sqlite, morph, uuid, tempo, pprint, envo) are pinned to the same version. When upgrading Mojo, update all repos in lockstep: change the pin, run `pixi update && pixi run tests` in each, push, and verify CI passes before updating mobin.

## Common workflows

| Task | Command |
|------|---------|
| Install everything | `pixi install` |
| Update all deps | `pixi update` |
| Update one dep | `pixi update <pkg>` |
| Add a dependency | Add to `[dependencies]` in `pixi.toml`, then `pixi install` |
| Clean and rebuild | `pixi clean && pixi install` |
| Run a task | `pixi run <task>` (e.g. `pixi run tests`, `pixi run build`) |
| List environments | `pixi info` |

## Dependency graph

mobin pulls in 8 Mojo libraries, all from Git:

```
mobin
├── flare     HTTP + WebSocket server framework
│   └── json  simdjson-based JSON parser (transitive)
├── sqlite    SQLite3 FFI bindings
├── morph     Struct-to-JSON serialisation
├── uuid      UUID v4 generation
├── tempo     Date/time utilities
├── pprint    Pretty-printing (dev/debug)
└── envo      Environment variable helpers
```

System dependencies (`openssl`, `zlib`, `ca-certificates`) are resolved from `conda-forge` and linked automatically.
