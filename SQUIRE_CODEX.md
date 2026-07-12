# Squire Codex

Squire Codex is a maintained OpenAI Codex fork with one integration: an
agent-chosen local command is offered to the versioned Squire runtime before
Codex starts its native process path.

## User Path

Install the matching Squire and Squire-Codex release:

```sh
curl -fsSL https://raw.githubusercontent.com/reidgoodbar/squire/main/install.sh | bash
```

Then run:

```sh
squire codex
```

The driver uses the normal Codex home, login, models, configuration, tools,
permissions, and sandbox. Squire does not add a tool or alter prompts.

On an exact Squire hit, the bridge returns stdout, stderr, and exit status in
Codex's native result type. On miss, unsupported command, incompatible ABI, or
unavailable runtime, control stays on the original Codex execution path.

## Patch Shape

The fork intentionally keeps Squire outside upstream command parsing and
sandbox implementation. Current integration points are:

- `codex-rs/core/src/exec.rs` for classic process execution;
- `codex-rs/core/src/tools/runtimes/shell.rs` before sandbox wrapping;
- `codex-rs/core/src/tasks/user_shell.rs` for typed user-shell commands;
- `codex-rs/core/src/unified_exec/process_manager.rs` for unified exec.

Those hooks delegate to `vendor/squire/`. The canonical source for vendored
files lives in the Squire repository and is copied with:

```sh
../squire/scripts/sync_squire_codex_bridge.sh .
```

The fork must remain a standalone checkout. It must never compile against a
sibling repository path.

## Runtime Boundary

The bridge sends cwd, argv, and the exact child environment to runtime ABI 1.
The runtime owns command policy and proof evaluation. Rust owns only:

- dynamic loading and ABI validation;
- copying hit bytes before releasing runtime memory;
- conversion into Codex output/event types;
- asynchronous, deduplicated preparation requests after eligible misses.

This keeps command coverage and correctness changes in Squire rather than in
the fork.

## Release Artifacts

Each platform archive contains:

- `squire-codex`;
- `codex-code-mode-host`;
- `libsquire_runtime` on supported host platforms;
- build metadata and license files.

The release workflow checks out the matching tagged Squire source and compiles
the runtime on the target's native runner. The installer verifies both release
archives before replacing any installed component.

The supported product hosts are macOS and Linux on `amd64` or `arm64`. The
release workflow does not publish a Windows archive until the runtime and
installer have a complete Windows implementation.

Developer builds from upstream `main` display Codex version `0.0.0` because
that is upstream's source-build sentinel. The artifact builder derives the
nearest merged upstream `rust-v*` tag and temporarily builds with a version
such as `0.143.0-alpha.10+squire.0.1.0`; it restores `Cargo.toml` and
`Cargo.lock` afterward. `SQUIRE_CODEX_CARGO_VERSION` can override that derived
version for a controlled release.

## Upstream Maintenance

The scheduled `Squire Upstream Sync` workflow fetches `openai/codex`, merges
`upstream/main` into a sync branch, runs focused bridge checks, and opens or
updates a PR against this fork's main branch. Merge conflicts are never hidden
by force-merging into the release branch.

For local work:

```sh
git remote add upstream https://github.com/openai/codex.git
git fetch upstream main
git config core.hooksPath .githooks
```

Keep upstream files close to their original form. If a common execution
boundary becomes available upstream, consolidate hooks rather than preserving
obsolete integration points.

## Verification

Repository policy requires `just` and nextest:

```sh
just fmt
just test -p codex-core squire_codex_bridge
cargo build -p codex-cli --bin codex
cargo build -p codex-code-mode-host --bin codex-code-mode-host
```

Squire's separate runtime fuzz and artifact install smoke cover proof exactness,
invalidation, ABI loading, and installed component discovery.
