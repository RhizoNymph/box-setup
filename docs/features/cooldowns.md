# Feature: cooldowns

## Scope

`scripts/cooldowns.sh` configures a minimum release age ("cooldown") — the
time a package version must have been published before the resolver will
install it — for every package manager on the machine that supports the
concept natively, at the **user/global** level, in the config location each
OS expects. Default window is 3 days (`--days N` / `COOLDOWN_DAYS` to
override).

### Non-scope

- Project-level configuration (project files override these settings; the
  script prints a reminder).
- Third-party plugins (e.g. `cargo-cooldown`); only native settings.
- Managers whose cooldown is project-only, flag-only, or whose user-level
  form is unverified: RubyGems `gem` (`--cooldown DAYS` flag), pdm
  (`strategy.exclude-newer`), pixi (`[workspace] exclude-newer`), conda,
  pipx (`PIPX_COOLDOWN` env var), pipenv (`Pipfile`). The script prints an
  `info` line for the installed ones instead of writing anything.
- Exclusion/allowlist configuration (`minimumReleaseAgeExclude`,
  `min-release-age-exclude`, `npmPreapprovedPackages`,
  `exclude-newer-package`, etc.).

## Control flow

1. Parse `--days` (positive integer; also `COOLDOWN_DAYS` env). Derive
   minutes and seconds — each manager uses different units.
2. Detect OS via `uname -s`: `Darwin` → macos, `MINGW*/MSYS*/CYGWIN*` →
   windows (Git Bash, where `$HOME` = `%USERPROFILE%`), else linux (WSL
   intentionally counts as linux).
3. For each manager, in order (npm, pnpm, yarn, bun, deno, uv, pip, poetry,
   cargo, bundler, composer, hex, mise): detect on `PATH` (`skip` if absent),
   read version tolerantly (`tool_ver`; a broken shim warns instead of
   aborting), check the minimum supported version, then write config.
   External config commands (`npm config set`, `pnpm config set`,
   `pip config`, `poetry config`, `bundle config`, `composer config`,
   `mix hex.config`, `mise settings set`) that fail produce a `warn` and the
   script continues.
4. `note_unconfigured` prints `info` lines for installed managers the script
   deliberately does not configure.
5. Exit 0 with a warning count; per-line statuses are `ok`/`warn`/`skip`/`info`.

## Per-manager matrix (verified 2026-11)

| Tool     | Min version | Setting (units)                        | Written to                                              | Method |
|----------|-------------|----------------------------------------|---------------------------------------------------------|--------|
| npm      | 11.10.0     | `min-release-age` (days)               | `~/.npmrc`                                              | `npm config set --location=user` |
| pnpm     | 10.16       | `minimumReleaseAge` (minutes; kebab-case `minimum-release-age` on 10.x) | global `config.yaml` (`$XDG_CONFIG_HOME/pnpm`, Linux `~/.config/pnpm`, macOS `~/Library/Preferences/pnpm`, Windows `~/AppData/Local/pnpm/config`) | `pnpm config set --global`, with a PATH-augmented retry (see below) |
| yarn     | Berry 4.10  | `npmMinimalAgeGate` (minutes)          | `~/.yarnrc.yml`                                         | direct file edit (corepack may resolve to Classic outside a project, so `yarn config set --home` is unreliable) |
| bun      | 1.3.0       | `[install] minimumReleaseAge` (seconds)| `~/.bunfig.toml` (or existing `$XDG_CONFIG_HOME/.bunfig.toml`) | direct TOML edit |
| deno     | 2.8 (24h default since 2.9) | honors `min-release-age` (whole days) from `.npmrc` for npm deps | `~/.npmrc` | ensures the npmrc key exists when npm didn't set it; jsr deps need `minimumDependencyAge` in `deno.json` (no user-level deno config exists) |
| uv       | 0.9.17      | `exclude-newer` (`"N days"` relative)  | `${XDG_CONFIG_HOME:-~/.config}/uv/uv.toml`; Windows `%APPDATA%\uv\uv.toml` | direct TOML edit |
| pip      | 26.1        | `uploaded-prior-to` (`PnD` duration)   | pip user config, `[global]` section (`pip config debug` shows the path) | `pip config --user set global.uploaded-prior-to` |
| poetry   | 2.4.0       | `solver.min-release-age` (integer days)| poetry global `config.toml`                             | `poetry config` |
| cargo    | 1.100 (stable); nightly 1.98–1.99 via `[unstable] min-publish-age` | `[registry] global-min-publish-age = "N days"` | `${CARGO_HOME:-~/.cargo}/config.toml` | direct TOML edit |
| bundler  | 4.0.13      | `cooldown` (days)                      | Bundler global config                                   | `bundle config set --global` |
| composer | recent 2.x  | `policy.cooldown.period` (`"N days"`)  | Composer global config                                  | `composer config --global` |
| hex      | (present in 2.7) | `cooldown` (`"Nd"`)               | `${HEX_HOME:-~/.hex}`                                   | `mix hex.config` (stdin closed so a missing Hex can't prompt) |
| mise     | (24h default) | `minimum_release_age` (`"Nd"`)       | `~/.config/mise/config.toml`                            | `mise settings set` |

Defaults that already apply without this script: pnpm ≥ 11 (1440 minutes),
Deno ≥ 2.9 (24h), mise (24h), recent Yarn Berry. The script sets the chosen
window explicitly, which can narrow a longer built-in default.

Manager-specific caveats printed at runtime:

- pnpm: an explicitly set `minimumReleaseAge` is strict by default in
  current pnpm (install fails instead of falling back to an older version).
- uv: the relative `exclude-newer` cutoff is resolved to an absolute
  timestamp inside `uv.lock` and only advances on re-resolution.
- pip: the user config is shared by every pip on the machine, and pip 26.0
  rejects the `PnD` form; older venv pips need upgrading.
- cargo: `cargo install` ignores the minimum publish age. Because one
  `config.toml` serves all rustup toolchains, the script warns when the
  default is nightly but the `stable` toolchain is older than 1.100.

## Key internals

- `set_toml_key file section key value` — idempotent section-aware TOML
  upsert in awk (`""` section = top level). Replaces the key inside the
  target section only; creates file/section as needed. Values must be
  pre-formatted TOML (strings pre-quoted).
- `del_toml_key file section key` — removes a key from one section; used to
  drop the obsolete `[unstable] min-publish-age` opt-in once cargo ≥ 1.100.
- `set_flat_key file key sep value` — idempotent upsert for flat formats:
  npmrc (`=`) and top-level yarnrc YAML (`: `). Implemented in awk (not
  sed/grep, whose `\t` is a literal `t` on BSD/macOS); replaces the first
  match, drops later duplicates, and appends correctly to files without a
  trailing newline.
- `replace_file tmp file` — all helpers write results back with
  `cat > file` instead of `mv`, so symlinked dotfiles (stow, chezmoi,
  home-manager) remain symlinks and file permissions are preserved.
- `tmpfile` — `mktemp` with an explicit template (bare `mktemp` needs
  macOS ≥ 10.11).
- `mac_stub cmd` — true for Apple's `/usr/bin` developer-tool stubs when the
  Command Line Tools are absent; running them would pop up an install
  dialog, so pip treats them as not installed.
- `tool_ver` and `rustup run` get stdin from `/dev/null` so prompting shims
  (corepack's download prompt) fail fast instead of hanging;
  `rustup run stable` only runs when a stable toolchain is already installed
  (otherwise rustup may auto-install one).
- `ver_ge have need` — pure-bash 3-component version compare (avoids
  `sort -V`, which older macOS lacks).
- `tool_ver cmd` — first line of `cmd --version`, empty string on failure.
- pnpm retry: `pnpm config set --global` refuses to run when pnpm's global
  bin dir is not on `PATH` (typical when pnpm was installed via npm/corepack
  under nvm and `pnpm setup` never ran). The script parses the offending
  directory out of pnpm's error message (falling back to the per-OS default
  `PNPM_HOME` location) and retries once with it prepended to `PATH` for
  that single invocation; nothing is persisted to the user's shell config.

## Invariants and constraints

- Idempotent: re-running (with any `--days`) rewrites values in place; never
  duplicates keys; preserves unrelated content in shared files.
- Never aborts because one manager fails; per-manager failures degrade to
  `warn`.
- Only touches user-level config; never project files.
- Portable across Linux (GNU or busybox userland) and macOS (BSD userland,
  Apple's bash 3.2): no bash ≥ 4 features, no GNU-only flags.
- Honors relocated configs: `XDG_CONFIG_HOME`, `CARGO_HOME`,
  `NPM_CONFIG_USERCONFIG`; other tools locate their own files through their
  config commands. `NO_COLOR` disables colored output.
- On Windows the script assumes a bash environment (Git Bash/MSYS2/Cygwin)
  where home-dotfile paths coincide with what the native tools read; only uv
  needs the `%APPDATA%` special case (pip/poetry/composer/bundler resolve
  their own paths through their config commands).
