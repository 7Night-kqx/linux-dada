#!/usr/bin/env bash
# Shared helpers for the dada Debian CI scripts.
# Sourced, never executed directly.
set -euo pipefail

log()  { printf '\n=== %s\n' "$*"; }
info() { printf '  ok   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*" >&2; printf '::warning::%s\n' "$*"; }
# Emit a GitHub Actions annotation too: the job page only exposes the bare
# step exit code, so without ::error:: the real cause is invisible when the
# (blocked) Actions API cannot be used to fetch logs.
die()  {
    printf 'ERROR: %s\n' "$*" >&2
    printf '::error::%s\n' "$*"
    exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# assert_symbol <config-file> <SYMBOL> <expected>
# SYMBOL is a bare Kconfig name; .config lines carry the CONFIG_ prefix.
# expected: y | m | n | "quoted string" | plain string
assert_symbol() {
    local cfg=$1 sym=$2 want=$3 key="CONFIG_$2" got
    if [[ $want == n ]]; then
        if grep -q "^${key}=[ym]$" "$cfg"; then
            got=$(grep -m1 "^${key}=" "$cfg")
            die "$sym expected unset, got $got"
        fi
        info "$sym unset"
        return 0
    fi
    if grep -q "^${key}=" "$cfg"; then
        got=$(grep -m1 "^${key}=" "$cfg" | cut -d= -f2-)
    else
        die "$sym missing from $cfg (expected $want)"
    fi
    [[ $got == "$want" ]] || die "$sym expected '$want', got '$got'"
    info "$sym=$want"
}

# run config-assertions.txt against a .config
check_config_assertions() {
    local cfg=$1 list=$2 line sym want
    log "config assertions ($list)"
    while IFS= read -r line; do
        line=${line%%#*}
        # Trim whitespace WITHOUT xargs: xargs would strip the double quotes
        # from values like LOCALVERSION="" and INITRAMFS_SOURCE="".
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z $line ]] && continue
        sym=${line%%=*}
        want=${line#*=}
        assert_symbol "$cfg" "$sym" "$want"
    done < "$list"
    info "all config assertions passed"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
