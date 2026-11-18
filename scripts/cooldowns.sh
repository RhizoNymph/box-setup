#!/usr/bin/env bash
#
# cooldowns.sh — configure a minimum release age ("cooldown") for every
# installed package manager that supports it natively, at the user/global
# level, in the location each OS expects.
#
# Supported natively:
#   npm      >= 11.10.0  min-release-age (days)             ~/.npmrc
#   pnpm     >= 10.16    minimumReleaseAge (minutes)        pnpm global config.yaml
#   yarn     >= 4.10     npmMinimalAgeGate (minutes)        ~/.yarnrc.yml
#   bun      >= 1.3.0    [install] minimumReleaseAge (s)    ~/.bunfig.toml
#   deno     >= 2.8      honors min-release-age in .npmrc   ~/.npmrc
#   uv       >= 0.9.17   exclude-newer ("N days")           ~/.config/uv/uv.toml
#                                                           (%APPDATA%\uv on Windows)
#   pip      >= 26.1     uploaded-prior-to (PnD)            pip user config
#   poetry   >= 2.4.0    solver.min-release-age (days)      poetry global config
#   cargo    >= 1.100    [registry] global-min-publish-age  ~/.cargo/config.toml
#                        (nightly 1.98-1.99: also [unstable] min-publish-age)
#   bundler  >= 4.0.13   cooldown (days)                    bundle global config
#   composer             policy.cooldown.period ("N days")  composer global config
#   hex                  cooldown ("Nd")                    ~/.hex (mix hex.config)
#   mise                 minimum_release_age ("Nd")         ~/.config/mise/config.toml
#
# Usage: cooldowns.sh [--days N]   (default 3; env COOLDOWN_DAYS also honored)

set -euo pipefail

# ---------------------------------------------------------------- arguments

AGE_DAYS="${COOLDOWN_DAYS:-3}"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --days) AGE_DAYS="${2:?--days requires a value}"; shift 2 ;;
    --days=*) AGE_DAYS="${1#--days=}"; shift ;;
    -h|--help) usage ;;
    *) printf 'error: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
  esac
done

case "$AGE_DAYS" in
  ''|*[!0-9]*) printf 'error: --days must be a positive integer, got %q\n' "$AGE_DAYS" >&2; exit 2 ;;
esac

AGE_MINUTES=$((AGE_DAYS * 1440))
AGE_SECONDS=$((AGE_DAYS * 86400))

# ---------------------------------------------------------------- environment

case "$(uname -s)" in
  Darwin) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=linux ;;
esac

# On Windows this script runs under Git Bash / MSYS2 / Cygwin, where $HOME
# maps to %USERPROFILE%; tools that keep dotfiles in the home directory
# (npm, yarn, bun, cargo) therefore resolve to the same file the native
# tool reads. Only uv uses a different per-OS base directory.
if [ "$OS" = windows ]; then
  UV_TOML="${APPDATA:?APPDATA not set}/uv/uv.toml"
else
  UV_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv.toml"
fi
CARGO_CONFIG="${CARGO_HOME:-$HOME/.cargo}/config.toml"
BUNFIG="$HOME/.bunfig.toml"
[ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/.bunfig.toml" ] && BUNFIG="$XDG_CONFIG_HOME/.bunfig.toml"
# npm (and deno, which reads the same file) honor a relocated user npmrc.
NPMRC="${NPM_CONFIG_USERCONFIG:-${npm_config_userconfig:-$HOME/.npmrc}}"
YARNRC="$HOME/.yarnrc.yml"

# ---------------------------------------------------------------- helpers

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m' C_WARN=$'\033[33m' C_SKIP=$'\033[2m' C_OFF=$'\033[0m'
else
  C_OK='' C_WARN='' C_SKIP='' C_OFF=''
fi

WARNINGS=0
ok()   { printf '%s  ok%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%swarn%s  %s\n' "$C_WARN" "$C_OFF" "$*"; WARNINGS=$((WARNINGS + 1)); }
skip() { printf '%sskip%s  %s\n' "$C_SKIP" "$C_OFF" "$*"; }
info() { printf 'info  %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# macOS ships /usr/bin stubs (pip3, python3, ...) that pop up an "install
# Command Line Tools" dialog when run without the CLT. Treat those as absent.
mac_stub() {
  [ "$OS" = macos ] && [ "$(command -v "$1")" = "/usr/bin/$1" ] && ! xcode-select -p >/dev/null 2>&1
}

# First line of `<cmd> --version`; empty (not fatal) when the tool errors,
# e.g. a rustup shim with no default toolchain configured. stdin is closed
# so shims that prompt (corepack's "download yarn?") fail instead of hanging.
tool_ver() { { "$1" --version </dev/null 2>/dev/null || true; } | head -n1; }

# Portable temp file (bare `mktemp` needs macOS >= 10.11).
tmpfile() { mktemp "${TMPDIR:-/tmp}/cooldowns.XXXXXX"; }

# replace_file <tmp> <file>: write contents in place rather than mv, so a
# symlinked dotfile (stow, chezmoi, home-manager...) stays a symlink and
# the file keeps its permissions.
replace_file() { cat "$1" > "$2" && rm -f "$1"; }

# ver_ge <have> <need>: succeeds when dotted version <have> >= <need>
ver_ge() {
  local a b i x y
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x%%[!0-9]*}"; y="${y%%[!0-9]*}"
    if [ "${x:-0}" -gt "${y:-0}" ]; then return 0; fi
    if [ "${x:-0}" -lt "${y:-0}" ]; then return 1; fi
  done
  return 0
}

# set_toml_key <file> <section> <key> <value>
# Idempotently sets key = value inside [section] ("" for top level),
# creating the file or section as needed. <value> must be pre-formatted
# TOML (numbers bare, strings quoted).
set_toml_key() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  tmp="$(tmpfile)"
  awk -v section="$section" -v key="$key" -v value="$value" '
    function emit() { print key " = " value; done = 1 }
    BEGIN { cur = "" }
    /^[ \t]*\[/ {
      if (!done && cur == section) emit()
      cur = $0
      gsub(/^[ \t]*\[|\][ \t]*$/, "", cur)
    }
    {
      if (!done && cur == section && $0 ~ "^[ \t]*" key "[ \t]*=") { emit(); next }
      print
    }
    END {
      if (!done) {
        if (section != "" && cur != section) {
          if (NR > 0) print ""
          print "[" section "]"
        }
        emit()
      }
    }
  ' "$file" > "$tmp"
  replace_file "$tmp" "$file"
}

# del_toml_key <file> <section> <key>
# Removes key from [section] if present; leaves everything else (including
# a now-empty section header) untouched.
del_toml_key() {
  local file="$1" section="$2" key="$3" tmp
  [ -f "$file" ] || return 0
  grep -q "$key" "$file" || return 0
  tmp="$(tmpfile)"
  awk -v section="$section" -v key="$key" '
    BEGIN { cur = "" }
    /^[ \t]*\[/ { cur = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", cur) }
    cur == section && $0 ~ "^[ \t]*" key "[ \t]*=" { next }
    { print }
  ' "$file" > "$tmp"
  replace_file "$tmp" "$file"
}

# set_flat_key <file> <key> <sep> <value>
# Idempotently sets a top-level "key<sep>value" line (npmrc "=", yaml ": "):
# the first match is replaced, later duplicates dropped, otherwise the line
# is appended. Done in awk (where "\t" is a real tab on every platform; BSD
# sed/grep read it as a literal "t") and safe on files lacking a final newline.
set_flat_key() {
  local file="$1" key="$2" sep="$3" value="$4" tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  tmp="$(tmpfile)"
  awk -v key="$key" -v line="$key$sep$value" '
    $0 ~ "^[ \t]*" key "[ \t]*[:=]" { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "$file" > "$tmp"
  replace_file "$tmp" "$file"
}

# ---------------------------------------------------------------- managers

setup_npm() {
  have npm || { skip "npm: not installed"; return 0; }
  local v; v="$(tool_ver npm)"
  [ -n "$v" ] || { warn "npm: installed but 'npm --version' failed"; return 0; }
  if ver_ge "$v" 11.10.0; then
    if npm config set min-release-age "$AGE_DAYS" --location=user; then
      ok "npm $v: min-release-age=$AGE_DAYS days -> $NPMRC"
    else
      warn "npm $v: 'npm config set min-release-age' failed; set it manually in $NPMRC"
    fi
  else
    warn "npm $v: min-release-age needs npm >= 11.10.0; upgrade npm"
  fi
}

note_pnpm_strict() {
  info "pnpm: an explicitly set minimumReleaseAge is strict by default in current pnpm (install fails rather than falling back to an older version); see pnpm's dependency-resolution settings to relax it"
}

setup_pnpm() {
  have pnpm || { skip "pnpm: not installed"; return 0; }
  local v key; v="$(tool_ver pnpm)"
  [ -n "$v" ] || { warn "pnpm: installed but 'pnpm --version' failed"; return 0; }
  if ver_ge "$v" 11.0.0; then
    key=minimumReleaseAge
  elif ver_ge "$v" 10.16.0; then
    key=minimum-release-age
  else
    warn "pnpm $v: cooldown needs pnpm >= 10.16; upgrade pnpm"
    return 0
  fi
  local err
  if err="$(pnpm config set --global "$key" "$AGE_MINUTES" 2>&1)"; then
    ok "pnpm $v: $key=$AGE_MINUTES minutes (pnpm global config)"
    note_pnpm_strict
    return 0
  fi
  # pnpm refuses global writes when its global bin dir is not on PATH —
  # common when pnpm came from npm/corepack under nvm and `pnpm setup`
  # never ran. Retry with the directory pnpm itself names (or the per-OS
  # default) prepended to PATH for just this invocation.
  local dir
  dir="$(printf '%s\n' "$err" | sed -n 's/.*global bin directory "\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "$dir" ]; then
    case "$OS" in
      macos)   dir="${PNPM_HOME:-$HOME/Library/pnpm}" ;;
      windows) dir="${PNPM_HOME:-${LOCALAPPDATA:-$HOME/AppData/Local}/pnpm}" ;;
      *)       dir="${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}/bin" ;;
    esac
  fi
  if PATH="$dir:$PATH" pnpm config set --global "$key" "$AGE_MINUTES" 2>/dev/null; then
    ok "pnpm $v: $key=$AGE_MINUTES minutes (pnpm global config)"
    note_pnpm_strict
  else
    printf '%s\n' "$err" >&2
    warn "pnpm $v: 'pnpm config set --global $key' failed; run 'pnpm setup', then re-run this script"
  fi
}

setup_yarn() {
  if ! have yarn; then skip "yarn: not installed"; return 0; fi
  local v; v="$(tool_ver yarn)"
  [ -n "$v" ] || { warn "yarn: installed but 'yarn --version' failed"; return 0; }
  # Written directly rather than via `yarn config set --home`: outside a
  # project directory corepack may hand us Yarn Classic, which can't write
  # Berry config. Berry >= 4.10 reads ~/.yarnrc.yml; Classic ignores it.
  set_flat_key "$YARNRC" npmMinimalAgeGate ": " "$AGE_MINUTES"
  if ver_ge "$v" 4.10.0; then
    ok "yarn $v: npmMinimalAgeGate=$AGE_MINUTES minutes -> $YARNRC"
  else
    warn "yarn $v has no cooldown support (needs Berry >= 4.10); wrote $YARNRC anyway for when you upgrade"
  fi
}

setup_bun() {
  have bun || { skip "bun: not installed"; return 0; }
  local v; v="$(tool_ver bun)"
  [ -n "$v" ] || { warn "bun: installed but 'bun --version' failed"; return 0; }
  set_toml_key "$BUNFIG" install minimumReleaseAge "$AGE_SECONDS"
  if ver_ge "$v" 1.3.0; then
    ok "bun $v: [install] minimumReleaseAge=$AGE_SECONDS seconds -> $BUNFIG"
  else
    warn "bun $v ignores minimumReleaseAge (needs >= 1.3.0); wrote $BUNFIG anyway for when you upgrade"
  fi
}

setup_deno() {
  have deno || { skip "deno: not installed"; return 0; }
  local v; v="$(tool_ver deno)"; v="${v#deno }"; v="${v%% *}"
  [ -n "$v" ] || { warn "deno: installed but 'deno --version' failed"; return 0; }
  if ! ver_ge "$v" 2.8.0; then
    warn "deno $v: reading min-release-age from .npmrc needs deno >= 2.8; upgrade deno (or set minimumDependencyAge per project in deno.json)"
    return 0
  fi
  # Deno honors min-release-age from .npmrc for npm dependencies; make sure
  # it is present even when npm itself is absent or too old to have set it.
  if ! have npm || ! ver_ge "$(tool_ver npm)" 11.10.0; then
    set_flat_key "$NPMRC" min-release-age "=" "$AGE_DAYS"
  fi
  if ver_ge "$v" 2.9.0; then
    ok "deno $v: 24h cooldown built in by default; min-release-age=$AGE_DAYS days in $NPMRC covers npm deps"
  else
    ok "deno $v: min-release-age=$AGE_DAYS days in $NPMRC covers npm deps; jsr deps need minimumDependencyAge in deno.json (24h default from 2.9)"
  fi
  info "deno: an explicit minimumDependencyAge in a project's deno.json overrides this; deno has no user-level config file"
}

setup_uv() {
  have uv || { skip "uv: not installed"; return 0; }
  local v; v="$(tool_ver uv)"; v="${v#uv }"; v="${v%% *}"
  [ -n "$v" ] || { warn "uv: installed but 'uv --version' failed"; return 0; }
  if ver_ge "$v" 0.9.17; then
    set_toml_key "$UV_TOML" "" exclude-newer "\"$AGE_DAYS days\""
    ok "uv $v: exclude-newer=\"$AGE_DAYS days\" -> $UV_TOML"
    info "uv: the resolved cutoff timestamp is pinned into uv.lock; it advances on the next re-resolution, not with wall-clock time"
  else
    warn "uv $v: relative exclude-newer durations need uv >= 0.9.17; upgrade uv"
  fi
}

setup_pip() {
  local pip="" c
  for c in pip pip3; do
    if have "$c" && ! mac_stub "$c"; then pip="$c"; break; fi
  done
  [ -n "$pip" ] || { skip "pip: not installed"; return 0; }
  local v; v="$(tool_ver "$pip")"; v="${v#pip }"; v="${v%% *}"
  [ -n "$v" ] || { warn "pip: installed but '$pip --version' failed"; return 0; }
  if ! ver_ge "$v" 26.1.0; then
    warn "pip $v: a rolling cooldown (--uploaded-prior-to P${AGE_DAYS}D) needs pip >= 26.1; not configured. Prefer uv for Python installs."
    return 0
  fi
  # [global] so it also covers download/wheel/lock/list, not just install.
  if "$pip" config --user set global.uploaded-prior-to "P${AGE_DAYS}D" >/dev/null; then
    ok "pip $v: uploaded-prior-to=P${AGE_DAYS}D (pip user config)"
    info "pip: the shared user config is also read by older pips in other venvs; pip 26.0 rejects the P${AGE_DAYS}D form, so upgrade pip in those venvs"
  else
    warn "pip $v: 'pip config --user set global.uploaded-prior-to' failed; set it manually"
  fi
}

setup_poetry() {
  have poetry || { skip "poetry: not installed"; return 0; }
  local v; v="$(tool_ver poetry)"; v="${v##*version }"; v="${v%)}"
  [ -n "$v" ] || { warn "poetry: installed but 'poetry --version' failed"; return 0; }
  if ! ver_ge "$v" 2.4.0; then
    warn "poetry $v: solver.min-release-age needs poetry >= 2.4.0; upgrade poetry"
    return 0
  fi
  if poetry config solver.min-release-age "$AGE_DAYS"; then
    ok "poetry $v: solver.min-release-age=$AGE_DAYS days (poetry global config.toml)"
  else
    warn "poetry $v: 'poetry config solver.min-release-age' failed; set it manually"
  fi
}

setup_cargo() {
  have cargo || { skip "cargo: not installed"; return 0; }
  local line v; line="$(tool_ver cargo)"
  [ -n "$line" ] || { warn "cargo: installed but 'cargo --version' failed (no default rustup toolchain?)"; return 0; }
  v="${line#cargo }"; v="${v%% *}"; v="${v%%-*}"
  # The [registry] key is read by every toolchain >= 1.100 (stable since
  # 1.100) and by 1.98-1.99 nightly with -Zmin-publish-age; older cargo
  # ignores it, so it is always safe to write.
  set_toml_key "$CARGO_CONFIG" registry global-min-publish-age "\"$AGE_DAYS days\""
  if ver_ge "$v" 1.100.0; then
    # The unstable opt-in this script used to write is obsolete once stable.
    del_toml_key "$CARGO_CONFIG" unstable min-publish-age
    ok "cargo $v: [registry] global-min-publish-age=\"$AGE_DAYS days\" -> $CARGO_CONFIG"
  elif [[ "$line" == *nightly* ]] && ver_ge "$v" 1.98.0; then
    set_toml_key "$CARGO_CONFIG" unstable min-publish-age true
    ok "cargo $v (nightly): global-min-publish-age=\"$AGE_DAYS days\" via [unstable] min-publish-age -> $CARGO_CONFIG"
  else
    warn "cargo $v: min-publish-age needs cargo >= 1.100 (rustup update stable); wrote $CARGO_CONFIG anyway for when you upgrade"
  fi
  # The config file is shared by all toolchains; flag an outdated stable one.
  # Only when a stable toolchain is installed: `rustup run` may otherwise
  # try to download one.
  if have rustup && [[ "$line" == *nightly* ]] && rustup toolchain list 2>/dev/null | grep -q '^stable'; then
    local sv; sv="$({ rustup run stable cargo --version </dev/null 2>/dev/null || true; } | head -n1)"
    sv="${sv#cargo }"; sv="${sv%% *}"
    if [ -n "$sv" ] && ! ver_ge "$sv" 1.100.0; then
      warn "cargo: your stable toolchain ($sv) ignores the cooldown; run 'rustup update stable'"
    fi
  fi
  info "cargo: 'cargo install' ignores the minimum publish age; pin versions there (cargo install foo@1.2.3)"
}

setup_bundler() {
  have bundle || { skip "bundler: not installed"; return 0; }
  local v; v="$(tool_ver bundle)"; v="${v##* }"
  [ -n "$v" ] || { warn "bundler: installed but 'bundle --version' failed"; return 0; }
  if ! bundle config set --global cooldown "$AGE_DAYS" >/dev/null; then
    warn "bundler $v: 'bundle config set --global cooldown' failed; set BUNDLE_COOLDOWN=$AGE_DAYS instead"
  elif ver_ge "$v" 4.0.13; then
    ok "bundler $v: cooldown=$AGE_DAYS days (bundle global config)"
  else
    warn "bundler $v ignores cooldown (needs >= 4.0.13); wrote it anyway for when you upgrade"
  fi
}

setup_composer() {
  have composer || { skip "composer: not installed"; return 0; }
  if composer config --global policy.cooldown.period "$AGE_DAYS days" >/dev/null 2>&1; then
    ok "composer: policy.cooldown.period=\"$AGE_DAYS days\" (composer global config)"
  else
    warn "composer: 'composer config --global policy.cooldown.period' failed (cooldown needs a recent composer 2.x; try 'composer self-update')"
  fi
}

setup_hex() {
  have mix || { skip "hex: mix not installed"; return 0; }
  # </dev/null: without Hex, mix would prompt to install it.
  if mix hex.config cooldown "${AGE_DAYS}d" </dev/null >/dev/null 2>&1; then
    ok "hex: cooldown=${AGE_DAYS}d (${HEX_HOME:-~/.hex})"
  else
    warn "hex: 'mix hex.config cooldown' failed (is Hex installed and recent? try 'mix local.hex')"
  fi
}

setup_mise() {
  have mise || { skip "mise: not installed"; return 0; }
  local v; v="$(tool_ver mise)"; v="${v%% *}"
  if mise settings set minimum_release_age "${AGE_DAYS}d" >/dev/null 2>&1; then
    ok "mise $v: minimum_release_age=${AGE_DAYS}d (mise global config)"
  else
    warn "mise $v: 'mise settings set minimum_release_age' failed (needs a mise with minimum_release_age; try 'mise self-update')"
  fi
}

note_unconfigured() {
  have gem && info "gem: RubyGems only takes a --cooldown DAYS flag per command (no persisted setting configured here); Bundler's setting covers bundle installs"
  have pdm && info "pdm: strategy.exclude-newer exists but its user-level form isn't configured here; set it per project"
  have pixi && info "pixi: exclude-newer is project-level only ([workspace] in pixi.toml)"
  have conda && info "conda: not configured here; check your conda for an exclude_newer setting in ~/.condarc"
  have pipx && info "pipx: set PIPX_COOLDOWN=$AGE_DAYS in your shell profile (pipx >= 1.17)"
  return 0
}

# ---------------------------------------------------------------- main

printf 'Configuring package-manager cooldowns: %s days (%s minutes / %s seconds) on %s\n\n' \
  "$AGE_DAYS" "$AGE_MINUTES" "$AGE_SECONDS" "$OS"

setup_npm
setup_pnpm
setup_yarn
setup_bun
setup_deno
setup_uv
setup_pip
setup_poetry
setup_cargo
setup_bundler
setup_composer
setup_hex
setup_mise
note_unconfigured

printf '\nDone.'
if [ "$WARNINGS" -gt 0 ]; then
  printf ' %d warning(s) above.' "$WARNINGS"
fi
printf ' Project-level config (.npmrc, pnpm-workspace.yaml, .yarnrc.yml, bunfig.toml, deno.json, pyproject.toml, .cargo/config.toml, composer.json, mise.toml) overrides these user-level settings.\n'
