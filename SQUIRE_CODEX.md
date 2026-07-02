# Squire Codex

`squire-codex` is a maintained fork of OpenAI Codex with one narrow product
change: before an agent-chosen local command runs natively, Codex asks the local
Squire adapter whether that exact command has a valid proof-backed replay.

The model still sees the normal Codex tool surface and emits the same commands.
Squire does not add tools, change prompts, route models, suggest commands, skip
validation, or replay edits.

## User Experience

Install Squire and the matching `squire-codex` driver:

```sh
curl -fsSL https://raw.githubusercontent.com/reidgoodbar/squire/main/install.sh | bash
```

Squire does not own OpenAI login or model configuration. The installed
`squire-codex` binary uses the normal Codex home, so authenticate and configure
Codex the same way you already would.

Then start Codex through Squire:

```sh
squire-codex
```

This is the normal product path. `squire-codex` is the real Codex fork with the
Squire bridge at the execution boundary. When the bridge is enabled:

- replay hits return exact stdout, stderr, and exit code from Squire;
- replay misses run through Codex's normal native execution path;
- unsupported, mutating, validation, build, and test commands run natively;
- if Squire is unavailable, Codex continues natively.

This keeps Squire invisible to the model. The model does not call a new tool,
and users do not install global command shims.

## Fork Layout

Use these remotes:

```sh
git remote add upstream https://github.com/openai/codex.git
git remote set-url origin https://github.com/reidgoodbar/squire-codex.git
```

The Squire patch should stay isolated to a small set of files:

- the execution-boundary hooks in `codex-rs/core/src/exec.rs`
- the unified exec hook in `codex-rs/core/src/unified_exec/process_manager.rs`
- the repo-local bridge snapshot in `vendor/squire/`

Avoid spreading Squire-specific logic into upstream command parsing, sandbox,
or UI code unless the execution boundary moves upstream.

The fork must build as a standalone checkout on another machine. Do not point
`#[path]` modules at a sibling `squire` repository. Squire remains the source of
truth, but `vendor/squire/` is the release snapshot consumed by this fork.

## Keeping Up With Upstream

The `Squire Upstream Sync` workflow runs on a schedule and by manual dispatch.
It fetches `openai/codex`, attempts to merge `upstream/main` into this fork's
main branch on a sync branch, runs the focused Squire bridge checks, and opens
or updates a PR when the merge succeeds.

For local work, install the optional hook:

```sh
git config core.hooksPath .githooks
```

The hook checks whether the current branch contains the latest known
`upstream/main` and runs the focused Squire bridge tests before push. It uses
the locally fetched upstream ref; run `git fetch upstream main` when you want a
fresh check.

Restricted environments can point the hook at an existing Cargo cache with
`SQUIRE_CODEX_CARGO_HOME` and `SQUIRE_CODEX_CARGO_TARGET_DIR`.

## Focused Checks

```sh
cargo fmt --check -p codex-core
cargo test -p codex-core squire_bridge --lib
cargo build -p codex-cli --bin codex
```

These are not a replacement for upstream CI. They are the minimum checks for
the Squire bridge patch surface.
