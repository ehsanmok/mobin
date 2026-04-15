# Package management with Pixi

mobin uses [Pixi](https://pixi.sh) as its package manager and task runner.

## Why Pixi?

Mojo packages are distributed through Conda channels (`conda.modular.com`). Pixi is a fast, cross-platform package manager built on the Conda ecosystem with several properties that make it the right fit for Mojo projects:

- **Conda-native.** Pixi resolves packages from Conda channels directly, so Mojo libraries installed via `pixi install` are immediately available to the compiler. No shims, no separate toolchain step.
- **Lockfile.** `pixi.lock` pins every transitive dependency (Mojo compiler version, C libraries like openssl/zlib, and Mojo packages) to exact builds. Two developers running `pixi install` get byte-identical environments.
- **Git dependencies.** Mojo libraries that aren't published to a channel yet can be pulled straight from a Git repo. Use `tag` for stable, released versions:

  ```toml
  flare = { git = "https://github.com/ehsanmok/flare.git", tag = "v0.1.0" }
  ```

  Or `branch` for bleeding-edge development:

  ```toml
  flare = { git = "https://github.com/ehsanmok/flare.git", branch = "main" }
  ```

  Pixi clones, builds, and caches the Mojo package automatically. Tags are preferred for production because they point to a fixed commit that has passed CI, while branches can shift at any time.
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

## Version strategy

### Mojo compiler pin

mobin pins the Mojo compiler to an exact nightly build to guarantee reproducible builds:

```toml
mojo = "==0.26.3.0.dev2026041305"
```

This avoids MLIR bytecode incompatibilities between the compiler and prebuilt Mojo packages. When upgrading Mojo, update the pin, run `pixi install && pixi run tests`, and verify CI passes.

### Library version strategy

All upstream Mojo libraries (flare, json, sqlite, morph, uuid, tempo, pprint, envo) are released with Git tags (e.g. `v0.1.0`). mobin depends on these tags for stability:

```toml
flare  = { git = "https://github.com/ehsanmok/flare.git",  tag = "v0.1.0" }
json   = { git = "https://github.com/ehsanmok/json.git",   tag = "v0.1.0" }
sqlite = { git = "https://github.com/ehsanmok/sqlite.git", tag = "v0.1.0" }
```

Each library's tagged release has a pinned Mojo version in its own `pixi.toml` and has passed CI on both Linux and macOS. After a release, the library's `main` branch unpins Mojo to `<1.0` so it tracks the latest nightly. This means:

- **`tag = "v0.1.0"`**: frozen commit, pinned Mojo, CI-verified. Use this for production.
- **`branch = "main"`**: latest code, latest Mojo nightly, may break. Use this for development.

### Upgrading libraries

To bump to a new library release (e.g. `v0.2.0`):

1. Update the `tag` in `pixi.toml` for each dependency.
2. Run `pixi install` to regenerate `pixi.lock`.
3. Run `pixi run tests` to verify compatibility.
4. Commit both `pixi.toml` and `pixi.lock`.

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

mobin pulls in 8 Mojo libraries, all from Git (pinned to `v0.1.0` release tags):

```
mobin
├── flare   v0.1.0  HTTP + WebSocket server framework
│   └── json        simdjson-based JSON parser (transitive dep of flare)
├── json    v0.1.0  simdjson-based JSON parser (direct dep for API handlers)
├── sqlite  v0.1.0  SQLite3 FFI bindings + ORM
├── morph   v0.1.0  Struct-to-JSON serialisation
├── uuid    v0.1.0  UUID v4/v7 generation
├── tempo   v0.1.0  Date/time utilities
├── pprint  v0.1.0  Reflection-driven pretty-printing (dev/debug)
└── envo    v0.1.0  Environment variable loader
```

System dependencies (`openssl`, `zlib`, `ca-certificates`) are resolved from `conda-forge` and linked automatically.

## Nuances for developers

### pixi.lock and CI

`pixi.lock` must always be committed alongside `pixi.toml`. GitHub Actions with `setup-pixi@v0.8.8` runs `pixi install --locked` by default, which fails if the lock file is stale. After any change to `pixi.toml`:

```bash
pixi install          # regenerates pixi.lock
pixi run tests        # verify nothing broke
git add pixi.toml pixi.lock
```

### Tag vs branch resolution

When you switch a dependency from `branch = "main"` to `tag = "v0.1.0"`, pixi resolves a different commit hash. This always changes `pixi.lock`, even if the tagged commit was the same as the previous HEAD of `main`. Always run `pixi install` after changing dependency specifiers.

### Transitive dependencies

Some libraries have their own build-time dependencies declared in `recipe.yaml` (e.g. `flare` depends on `json`, `json` depends on `simdjson`). Pixi resolves the entire transitive graph automatically. You don't need to declare transitive deps in mobin's `pixi.toml` unless you import them directly.

### The `--no-verify` flag

When committing changes that only touch `pixi.toml` / `pixi.lock`, you may need `--no-verify` to skip pre-commit hooks that try to format Mojo code (which would fail if the Mojo environment isn't set up in the hook runner).
