# Changelog

All notable changes to this project will be documented in this file.

This is a hard fork of [Endoze/valheim-mod-manager](https://github.com/Endoze/valheim-mod-manager), aimed at Valheim dedicated servers running in the [community Docker image](https://github.com/community-valheim-tools/valheim-server-docker). The upstream history lives in that repository and in this one's git log; versioning starts fresh here. See [Why this fork](README.md#why-this-fork) for the reasoning.

## [0.2.0] - 2026-10-16

### Added

- `vsmm sync` and `vsmm import` now report what changed, with mod versions and config files under separate headings (`+` added, `~` changed, `-` removed), or say that nothing changed.
- `.vsmm_config_digests.json`, a record of the config files the last applied profile carried. Config changes are judged against it, not against the files on disk, because the server rewrites some of its own.

### Changed

- `scripts/vsmm-update-and-restart.sh` also restarts the server when the profile's config files change, not only when mod versions do. It lists what changed and says why it is restarting. It deliberately does not hash the live config directory: a mod that regenerates a key on every boot would restart the server on every run.
- The first run after upgrading restarts the server once if the profile carries config files, since no digests have been recorded yet.

## [0.1.0] - 2026-09-29

### Added

- `vsmm sync`: follows a [Gale profile sync](https://github.com/Kesomannen/gale-sync) id (`[gale_sync] profile_id`), installing what the profile names and uninstalling what it no longer lists.
- Version pinning: `import` and `sync` install each mod at the version its list names, and `update mods` keeps it there. `track_latest = true` ignores listed versions instead.
- `.vsmm_state.json`, a sidecar recording where each mod came from and which version it is pinned to.
- `scripts/vsmm-update-and-restart.sh`, a hook for the image's update schedule. It syncs, updates, copies the result into the live install, and restarts the game server only when mods changed. If Gale is unreachable it keeps the installed mods.
- Hexium as a second mod source alongside Thunderstore.

### Changed

- Renamed to `valheim-server-mod-manager`, with the binary `vsmm`, the config file `vsmm_config.toml`, and the data directory `~/.config/vsmm`.
- Imports and `sync` are now authoritative by default: they uninstall what the source no longer lists. `--additive` replaces the old opt-in `--prune`. Pruning against an empty modlist is refused.
- Releases are a single static amd64 Linux binary with a shell installer.

### Removed

- `launch` and the Steam/Proton support around it.
- Named profiles and the `--profile` / `--no-profile` flags. There is one target, `game_dir`.
- `migrate`, and the deprecated `mod_list` and `install_dir` config keys.
- Windows and macOS builds.
