# Package management with Pixi

mobin uses [Pixi](https://pixi.sh) as its package manager and task runner, with the `pixi-build` preview enabled so that every custom Mojo dependency is built **from source** at install time. Nothing in mobin's dependency chain ships as a prebuilt `.mojopkg`.

## Why Pixi?

- **Conda-native compiler.** The Mojo compiler itself is a Conda package on `conda.modular.com/max-nightly`. Pixi resolves it directly — no shims, no separate toolchain bootstrap.
- **`pixi-build` preview.** mobin opts in via `preview = ["pixi-build"]` in `pixi.toml`. With pixi-build enabled, `git = ...` and `path = ...` dependencies are routed through [`rattler-build`](https://prefix-dev.github.io/rattler-build/), which clones (or symlinks, for path deps) the source repo and runs its `recipe.yaml` build to produce the package locally. There is **no central registry** for mobin's Mojo deps and **no `mojo package`** step in the workflow.
- **Lockfile.** `pixi.lock` pins every transitive dependency — the Mojo compiler version, every git commit hash that pixi-build resolved a tag to, and every system library (openssl, zlib, ca-certificates) — to exact builds. Two developers running `pixi install` get byte-identical environments.
- **Task runner.** `pixi run <task>` replaces Makefiles and per-platform overrides via `[target.linux-64.tasks]` / `[target.osx-arm64.tasks]` etc.
- **Fast.** Cold install (compiler + 8 from-source libraries + system deps) finishes in well under a minute on a warm pixi-build cache.

## How dependencies actually install

mobin's `[dependencies]` in `pixi.toml`:

```toml
mojo            = "==1.0.0b1"
flare           = { path = "../flare" }
json            = { git = "https://github.com/ehsanmok/json.git",   tag = "v0.1.6" }
morph           = { git = "https://github.com/ehsanmok/morph.git",  tag = "v0.1.2" }
sqlite          = { git = "https://github.com/ehsanmok/sqlite.git", tag = "v0.1.2" }
envo            = { git = "https://github.com/ehsanmok/envo.git",   tag = "v0.1.2" }
uuid            = { git = "https://github.com/ehsanmok/uuid.git",   tag = "v0.1.2" }
tempo           = { git = "https://github.com/ehsanmok/tempo.git",  tag = "v0.1.2" }
pprint          = { git = "https://github.com/ehsanmok/pprint.git", tag = "v0.1.2" }
openssl         = ">=3.6.1,<4"
ca-certificates = ">=2025.1.31"
zlib            = ">=1.3.1,<2"
```

For each git/path dependency, `pixi install`:

1. Clones (git) or symlinks (path) the source into `.pixi/build/work/<dep>-<hash>/`.
2. Reads the dep's `recipe.yaml` and runs `rattler-build` to compile the Mojo sources into the per-environment package layout under `.pixi/envs/default/lib/mojo/<dep>/`.
3. Links any system deps the recipe declares (`openssl`, `zlib`, ...) from `conda-forge`.

A tag pin (`tag = "v0.1.6"`) is therefore a **source pin**, not an artifact pin: pixi resolves the tag to a commit hash, locks that hash in `pixi.lock`, and rebuilds from source on every fresh install. Switching to `branch = "main"` is the same machinery aimed at a moving ref.

### Path deps (current `flare`)

`flare = { path = "../flare" }` is in place because flare `v0.7.0`'s `recipe.yaml` pins `mojo == 1.0.0b1.dev2026042717`, which the Conda solver cannot co-satisfy with `json/morph/sqlite/tempo/uuid/envo/pprint v0.1.2` (those pin the clean `==1.0.0b1`). Until flare publishes `v0.7.1` with a recipe whose `run: mojo == ...` matches the ecosystem, `path = "../flare"` keeps mobin building against a sibling worktree. Swap back to `git + tag` when v0.7.1 ships.

### FFI bridges

flare's reactor and gzip paths reach into shared libraries that the upstream `flare` repo builds via activation scripts (`flare/tls/ffi/build.sh`, `flare/http/ffi/build.sh`). When flare is consumed via pixi-build, only the `.mojopkg` portion of the build output lands in `$CONDA_PREFIX/lib/mojo/`; the freshly built `.so` files stay in the rattler-build work tree and never make it onto the dlopen search path. mobin's `scripts/build_flare_ffi.sh` (wired into `pixi.toml` as an `[activation].scripts` entry) finds the latest flare work tree, sources the upstream build scripts, and copies `libflare_tls.so`, `libflare_zlib.so`, and `libflare_fs.so` into `$CONDA_PREFIX/lib/` so the backend can dlopen them at runtime. Idempotent; only re-runs when the upstream source is newer than the installed copy.

## Mojo compiler pin

mobin pins the Mojo compiler exactly:

```toml
mojo = "==1.0.0b1"
```

Exact pinning avoids MLIR bytecode incompatibilities between the compiler and the from-source dep builds (each dep's `recipe.yaml` declares its own `run: mojo == ...` constraint that has to co-satisfy with this). When upgrading Mojo: update the pin, run `pixi install`, run `pixi run tests`, verify CI passes.

## Upgrading dependencies

To bump a library to a new tag:

1. Update the `tag = "..."` in `pixi.toml`.
2. `pixi install` — pixi-build clones the new tag, rattler-builds it from source, regenerates `pixi.lock`.
3. `pixi run tests` to verify compatibility.
4. Commit `pixi.toml` and `pixi.lock` together.

Tag-resolved git deps **always** rewrite `pixi.lock` (the resolved commit hash changes), even if the tag points at the same commit `main` was on yesterday. Always re-run `pixi install` after touching dependency specifiers.

## Common workflows

| Task                | Command |
|---------------------|---------|
| Install everything  | `pixi install` |
| Update all deps     | `pixi update` |
| Update one dep      | `pixi update <pkg>` |
| Add a dependency    | Edit `[dependencies]` in `pixi.toml`, then `pixi install` |
| Clean and rebuild   | `pixi clean && pixi install` |
| Run a task          | `pixi run <task>` (e.g. `pixi run tests`, `pixi run build`) |
| List environments   | `pixi info` |

## Dependency graph

mobin pulls 8 first-party Mojo libraries, all built from source via pixi-build:

```
mobin
├── flare   path=../flare   HTTP + WebSocket framework (Router, middleware,
│                            extractors, App[S], multi-worker reactor)
├── json    v0.1.6           simdjson-based JSON parser
├── morph   v0.1.2           reflection-driven JSON serde
├── sqlite  v0.1.2           SQLite3 FFI bindings + thin ORM
├── envo    v0.1.2           env-var loader
├── uuid    v0.1.2           UUID v4/v7 generation
├── tempo   v0.1.2           date/time utilities
└── pprint  v0.1.2           reflection-driven pretty-printing
```

System deps (`openssl`, `zlib`, `ca-certificates`) are resolved from `conda-forge` and linked automatically by each dep's recipe.

## Notes for developers

### `pixi.lock` and CI

`pixi.lock` must always be committed alongside `pixi.toml`. GitHub Actions with `setup-pixi` runs `pixi install --locked`, which fails if the lock file is stale. After any change to `pixi.toml`:

```bash
pixi install          # regenerates pixi.lock + rebuilds affected deps
pixi run tests        # verify nothing broke
git add pixi.toml pixi.lock
```

### Build cache

pixi-build caches every from-source build in `.pixi/build/`. Switching tags or branches reuses the cache when the resolved commit hash already has a build artifact. `pixi clean` wipes both the env and the build cache when something gets stuck.

### Transitive deps

Each library's `recipe.yaml` declares its own runtime deps (e.g. `flare` depends on `json`). pixi-build resolves the entire transitive graph automatically. You only declare a dep in mobin's `pixi.toml` if mobin imports it directly.
