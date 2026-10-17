#!/bin/sh
# Intended for POST_UPDATE_CHECK_HOOK on
# ghcr.io/community-valheim-tools/valheim-server. Runs vsmm's own update
# commands, then restarts the running server only if something actually
# changed: neither this image nor vsmm itself does that on its own, since
# vsmm's mods.yml has no notion of a running server process to signal.
#
# thunderstore-engine (vsmm's backing crate) always installs into
# "$VSMM_GAME_DIR/BepInEx/{plugins,config,patchers}" - a shape this image
# doesn't use anywhere on its own. Rather than write there directly (which
# would mean duplicating the image's own config->live sync, or getting wiped
# by it), this script symlinks those subfolders into the image's real,
# persistent BEPINEX_CONFIG_DIR, the same directory the image's docs already
# tell you to drop plugins into by hand and that its own bepinex-updater
# already knows how to sync into the live install on every boot and every
# update. See the README's "Adding vsmm to the official community Docker
# image" section for the full rationale.
#
# Config:
#   VSMM_CONFIG         path to vsmm's config file (default: /config/vsmm_config.toml)
#   VSMM_BIN            the vsmm binary (default: vsmm, resolved via PATH)
#   VSMM_GAME_DIR       must match `game_dir` in VSMM_CONFIG (default: /config/vsmm_game)
#   BEPINEX_CONFIG_DIR the image's persistent BepInEx directory (default: /config/bepinex)
#   BEPINEX_LIVE_DIR   the image's live BepInEx install (default: /opt/valheim/bepinex/BepInEx)
#   IMAGE_COMMON       the image's shared shell functions (default: /usr/local/etc/valheim/common)
#   VSMM_LIVE_MODLIST  where the mod list last given to the live server is kept
#                      (default: $VSMM_GAME_DIR/.live_modlist.json)
#   VSMM_LIVE_CONFIG_DIGESTS  where the config digests last given to the live server
#                      are kept (default: $VSMM_GAME_DIR/.live_config_digests.json)
set -eu

VSMM_CONFIG="${VSMM_CONFIG:-/config/vsmm_config.toml}"
VSMM_BIN="${VSMM_BIN:-vsmm}"
VSMM_GAME_DIR="${VSMM_GAME_DIR:-/config/vsmm_game}"
BEPINEX_CONFIG_DIR="${BEPINEX_CONFIG_DIR:-/config/bepinex}"
BEPINEX_LIVE_DIR="${BEPINEX_LIVE_DIR:-/opt/valheim/bepinex/BepInEx}"
IMAGE_COMMON="${IMAGE_COMMON:-/usr/local/etc/valheim/common}"
LIVE_MODLIST="${VSMM_LIVE_MODLIST:-$VSMM_GAME_DIR/.live_modlist.json}"
LIVE_CONFIG_DIGESTS="${VSMM_LIVE_CONFIG_DIGESTS:-$VSMM_GAME_DIR/.live_config_digests.json}"
# What the profile asked for, as vsmm last applied it. Deliberately not a hash
# of the live config files: the server rewrites some of those itself (a mod that
# regenerates a key on every boot would otherwise restart the server on every
# run).
PROFILE_CONFIG_DIGESTS="$VSMM_GAME_DIR/.vsmm_config_digests.json"

if ! command -v "$VSMM_BIN" >/dev/null 2>&1; then
  echo "vsmm-update-and-restart: '$VSMM_BIN' not found on PATH; is POST_BOOTSTRAP_HOOK installing it?" >&2
  exit 1
fi

# Idempotent - safe on every tick. ln -sfn replaces a stale/wrong symlink
# left over from an older BEPINEX_CONFIG_DIR/VSMM_GAME_DIR without complaint.
mkdir -p "$BEPINEX_CONFIG_DIR/plugins" "$BEPINEX_CONFIG_DIR/patchers" "$VSMM_GAME_DIR/BepInEx"
ln -sfn "$BEPINEX_CONFIG_DIR/plugins" "$VSMM_GAME_DIR/BepInEx/plugins"
ln -sfn "$BEPINEX_CONFIG_DIR/patchers" "$VSMM_GAME_DIR/BepInEx/patchers"
ln -sfn "$BEPINEX_CONFIG_DIR" "$VSMM_GAME_DIR/BepInEx/config"

# vsmm's own tracing output is written to stdout alongside command output (see
# src/logs.rs), and it's timestamped, so a raw capture of `list` would differ
# from the recorded mod list below even when nothing installed actually
# changed. The JSON payload is the only thing that starts
# a line with `[`, so trimming everything before that reliably isolates it
# regardless of the configured log_level.
list_json() {
  "$VSMM_BIN" --config "$VSMM_CONFIG" list --format json | sed -n '/^\[/,$p'
}

# `key<TAB>value` lines for `describe_changes`, from list_json output and from a
# config digests file (both pretty-printed with one field per line).
mod_lines() {
  awk -F'"' '/"full_name"/ { n = $4 } /"version"/ { v = $4 } /"enabled": false/ { d = " (disabled)" }
    /}/ { if (n != "") print n "\t" v d; n = ""; v = ""; d = "" }'
}
config_lines() {
  awk -F'"' 'NF >= 4 { print $2 "\t" $4 }'
}

# Prints what differs between two `key<TAB>value` files: + added, ~ changed,
# - removed. With show_values, a change reads "old -> new" (mod versions);
# without, just the key (config digests mean nothing to a reader).
describe_changes() {
  awk -F'\t' -v show="$3" '
    FILENAME == ARGV[1] { old[$1] = $2; next }
    { new[$1] = $2 }
    END {
      for (k in new) {
        if (!(k in old)) print "  + " k (show ? " " new[k] : "")
        else if (old[k] != new[k]) print "  ~ " k (show ? " " old[k] " -> " new[k] : "")
      }
      for (k in old) if (!(k in new)) print "  - " k (show ? " " old[k] : "")
    }' "$1" "$2" | sort -k2
}

"$VSMM_BIN" --config "$VSMM_CONFIG" update manifest

# The mod list the live server was last given (none, if it never was). Comparing
# against this, rather than against the list from the start of this run, also
# catches changes made outside the hook - a manual `vsmm sync` or `vsmm
# install` - which would otherwise never reach the live install.
synced=$(cat "$LIVE_MODLIST" 2>/dev/null || echo "[]")
synced_configs=$(cat "$LIVE_CONFIG_DIGESTS" 2>/dev/null || echo "{}")

# Reconciles against the configured [gale_sync] profile (installs what it
# names, uninstalls what it no longer does). A failure - unreachable
# gale-sync, or none configured - must not stop the server: fall through and
# keep running with whatever is already installed.
if ! "$VSMM_BIN" --config "$VSMM_CONFIG" sync; then
  echo "vsmm-update-and-restart: vsmm sync failed or is not configured; keeping installed mods" >&2
fi

"$VSMM_BIN" --config "$VSMM_CONFIG" update mods

after=$(list_json)
after_configs=$(cat "$PROFILE_CONFIG_DIGESTS" 2>/dev/null || echo "{}")

mods_changed=false
configs_changed=false
[ "$synced" = "$after" ] || mods_changed=true
[ "$synced_configs" = "$after_configs" ] || configs_changed=true

if [ "$mods_changed" = false ] && [ "$configs_changed" = false ]; then
  echo "vsmm-update-and-restart: no mod version or config file changes, leaving the server running"
  exit 0
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if [ "$mods_changed" = true ]; then
  echo "vsmm-update-and-restart: mod versions changed:"
  printf '%s\n' "$synced" | mod_lines > "$scratch/mods.old"
  printf '%s\n' "$after" | mod_lines > "$scratch/mods.new"
  describe_changes "$scratch/mods.old" "$scratch/mods.new" 1
fi

if [ "$configs_changed" = true ]; then
  echo "vsmm-update-and-restart: config files changed:"
  printf '%s\n' "$synced_configs" | config_lines > "$scratch/cfg.old"
  printf '%s\n' "$after_configs" | config_lines > "$scratch/cfg.new"
  describe_changes "$scratch/cfg.old" "$scratch/cfg.new" ""
fi

case "$mods_changed$configs_changed" in
  truetrue) what="mod versions and config files" ;;
  truefalse) what="mod versions" ;;
  *) what="config files" ;;
esac

# The image copies BEPINEX_CONFIG_DIR into the live install only at boot and
# during its own BepInEx updates, not when the server process restarts, so
# without this the restart below would come back up on the old mods: removed
# mods stay loaded and version changes never apply. Run the image's own sync
# (it also removes what a previous sync installed and is no longer in
# BEPINEX_CONFIG_DIR). It is bash, hence the explicit shell.
echo "vsmm-update-and-restart: syncing into the live install"
if ! bash -c '. "$1" && sync_bepinex_loadables "$2" "$3"' _ \
  "$IMAGE_COMMON" "$BEPINEX_CONFIG_DIR" "$BEPINEX_LIVE_DIR"; then
  echo "vsmm-update-and-restart: syncing into the live install failed; the restart may not pick up the changes" >&2
fi

echo "vsmm-update-and-restart: restarting valheim-server ($what changed)"
supervisorctl restart valheim-server

# Only recorded once the restart succeeded, so a failed one is retried next run.
printf '%s\n' "$after" > "$LIVE_MODLIST"
printf '%s\n' "$after_configs" > "$LIVE_CONFIG_DIGESTS"
