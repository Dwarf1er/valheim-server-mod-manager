//! Tracks which config files a profile asked for, so a re-import can say what
//! the *profile* changed rather than what happened to differ on disk.
//!
//! The server rewrites config files of its own accord (some mods regenerate a
//! key on every boot), so comparing the profile against the live files would
//! report a change on every run. Comparing it against the profile as it was
//! last applied only reports an actual edit to the profile.
//!
//! The record is `.vsmm_config_digests.json` beside `mods.yml`: a
//! `path -> digest` map, one entry per line and sorted, so a plain `diff` of two
//! copies (as `scripts/vsmm-update-and-restart.sh` does) names the files that
//! changed. Missing or unreadable reads as empty, which fails toward reporting
//! everything as changed.

use crate::error::AppResult;
use crate::target::Target;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use thunderstore_engine::profile::portability;

/// Target-relative config path -> hex digest of its content.
pub type Digests = BTreeMap<String, String>;

pub fn digest_file(target: &Target) -> PathBuf {
  target.dir.join(".vsmm_config_digests.json")
}

pub fn read(target: &Target) -> Digests {
  std::fs::read_to_string(digest_file(target))
    .ok()
    .and_then(|contents| serde_json::from_str(&contents).ok())
    .unwrap_or_default()
}

pub fn write(target: &Target, digests: &Digests) -> AppResult<()> {
  std::fs::write(digest_file(target), serde_json::to_string_pretty(digests)?)?;

  Ok(())
}

/// The digest of every config file `zip_bytes` carries. Extracts into a scratch
/// directory to learn which entries there are, so it applies the engine's own
/// key filtering rather than a second copy of it.
pub fn of_profile(zip_bytes: &[u8]) -> AppResult<Digests> {
  let scratch = tempfile::tempdir()?;
  let mut digests = Digests::new();

  for rel in portability::extract_configs_in(scratch.path(), zip_bytes)? {
    digests.insert(key(&rel), hex(&std::fs::read(scratch.path().join(&rel))?));
  }

  Ok(digests)
}

fn key(rel: &Path) -> String {
  rel.to_string_lossy().replace('\\', "/")
}

fn hex(bytes: &[u8]) -> String {
  Sha256::digest(bytes)
    .iter()
    .map(|byte| format!("{byte:02x}"))
    .collect()
}

/// How a profile's config files differ from the last applied set.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ConfigChanges {
  pub added: Vec<String>,
  pub changed: Vec<String>,
  pub removed: Vec<String>,
}

impl ConfigChanges {
  pub fn between(applied: &Digests, profile: &Digests) -> Self {
    let mut changes = Self::default();

    for (path, digest) in profile {
      match applied.get(path) {
        None => changes.added.push(path.clone()),
        Some(old) if old != digest => changes.changed.push(path.clone()),
        Some(_) => {}
      }
    }

    changes.removed = applied
      .keys()
      .filter(|path| !profile.contains_key(*path))
      .cloned()
      .collect();

    changes
  }

  pub fn is_empty(&self) -> bool {
    self.added.is_empty() && self.changed.is_empty() && self.removed.is_empty()
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  fn digests(entries: &[(&str, &str)]) -> Digests {
    entries
      .iter()
      .map(|(path, digest)| (path.to_string(), digest.to_string()))
      .collect()
  }

  #[test]
  fn changes_name_added_changed_and_removed_files() {
    let applied = digests(&[("a.cfg", "1"), ("b.cfg", "1"), ("gone.cfg", "1")]);
    let profile = digests(&[("a.cfg", "1"), ("b.cfg", "2"), ("new.cfg", "1")]);

    assert_eq!(
      ConfigChanges::between(&applied, &profile),
      ConfigChanges {
        added: vec!["new.cfg".into()],
        changed: vec!["b.cfg".into()],
        removed: vec!["gone.cfg".into()],
      }
    );
  }

  #[test]
  fn identical_sets_have_no_changes() {
    let same = digests(&[("a.cfg", "1")]);

    assert!(ConfigChanges::between(&same, &same).is_empty());
  }

  #[test]
  fn the_record_round_trips_and_a_missing_one_reads_empty() {
    let fixture = crate::test_support::Fixture::new();
    let target = fixture.target();

    assert!(read(&target).is_empty());

    let recorded = digests(&[("BepInEx/config/a.cfg", "abc")]);

    write(&target, &recorded).unwrap();

    assert_eq!(read(&target), recorded);
  }
}
