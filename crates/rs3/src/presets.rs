//! Named gimbal positions you can store and recall.

use std::path::{Path, PathBuf};

use crate::{Error, Position, Result};

/// A remembered attitude.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preset {
    pub name: String,
    pub position: Position,
}

impl Preset {
    pub fn new(name: impl Into<String>, position: Position) -> Self {
        Self {
            name: name.into(),
            position,
        }
    }
}

/// An ordered collection of presets, persistable as a small text file.
///
/// Deliberately dependency-free: one `name,yaw,roll,pitch` record per line, so
/// the file stays diffable and hand-editable.
#[derive(Debug, Clone, Default)]
pub struct PresetStore {
    presets: Vec<Preset>,
}

impl PresetStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.presets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.presets.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Preset> {
        self.presets.iter()
    }

    pub fn get(&self, name: &str) -> Option<&Preset> {
        self.presets.iter().find(|p| p.name == name)
    }

    /// Add a preset, replacing any existing one with the same name.
    pub fn add(&mut self, preset: Preset) {
        match self.presets.iter_mut().find(|p| p.name == preset.name) {
            Some(slot) => *slot = preset,
            None => self.presets.push(preset),
        }
    }

    pub fn remove(&mut self, name: &str) -> Option<Preset> {
        let idx = self.presets.iter().position(|p| p.name == name)?;
        Some(self.presets.remove(idx))
    }

    pub fn clear(&mut self) {
        self.presets.clear();
    }

    /// Default location: `~/Library/Application Support/rs3-studio/presets.csv`.
    pub fn default_path() -> PathBuf {
        let base = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        base.join("Library/Application Support/rs3-studio/presets.csv")
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        if !path.exists() {
            return Ok(Self::new());
        }
        let text = std::fs::read_to_string(path)?;
        let mut store = Self::new();
        for (lineno, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let parts: Vec<&str> = line.split(',').collect();
            if parts.len() != 4 {
                return Err(Error::Presets(format!(
                    "{}:{}: expected 4 fields, got {}",
                    path.display(),
                    lineno + 1,
                    parts.len()
                )));
            }
            let num = |s: &str, what: &str| -> Result<i16> {
                s.trim().parse::<i16>().map_err(|e| {
                    Error::Presets(format!(
                        "{}:{}: bad {what}: {e}",
                        path.display(),
                        lineno + 1
                    ))
                })
            };
            store.add(Preset::new(
                parts[0].trim(),
                Position::new(num(parts[1], "yaw")?, num(parts[2], "roll")?, num(parts[3], "pitch")?),
            ));
        }
        Ok(store)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<()> {
        let path = path.as_ref();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut out = String::from("# name,yaw,roll,pitch (tenths of a degree)\n");
        for p in &self.presets {
            out.push_str(&format!(
                "{},{},{},{}\n",
                p.name, p.position.yaw, p.position.roll, p.position.pitch
            ));
        }
        std::fs::write(path, out)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_replaces_by_name() {
        let mut s = PresetStore::new();
        s.add(Preset::new("wide", Position::new(0, 0, 0)));
        s.add(Preset::new("wide", Position::new(900, 0, 0)));
        assert_eq!(s.len(), 1);
        assert_eq!(s.get("wide").unwrap().position.yaw, 900);
    }

    #[test]
    fn remove_and_clear() {
        let mut s = PresetStore::new();
        s.add(Preset::new("a", Position::default()));
        s.add(Preset::new("b", Position::default()));
        assert!(s.remove("a").is_some());
        assert!(s.remove("a").is_none());
        assert_eq!(s.len(), 1);
        s.clear();
        assert!(s.is_empty());
    }

    #[test]
    fn round_trips_through_a_file() {
        let dir = std::env::temp_dir().join(format!("rs3-presets-{}", std::process::id()));
        let path = dir.join("presets.csv");
        let mut s = PresetStore::new();
        s.add(Preset::new("home", Position::new(0, 0, 0)));
        s.add(Preset::new("left", Position::from_degrees(-90.0, 0.0, 0.0)));
        s.save(&path).unwrap();

        let loaded = PresetStore::load(&path).unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded.get("left").unwrap().position.yaw, -900);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_file_is_an_empty_store() {
        assert!(PresetStore::load("/nonexistent/presets.csv").unwrap().is_empty());
    }

    #[test]
    fn malformed_line_is_reported_with_location() {
        let dir = std::env::temp_dir().join(format!("rs3-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("p.csv");
        std::fs::write(&path, "ok,0,0,0\nbroken,1,2\n").unwrap();
        let err = PresetStore::load(&path).unwrap_err().to_string();
        assert!(err.contains(":2:"), "{err}");
        std::fs::remove_dir_all(&dir).ok();
    }
}
