//! ghostgrid's settings and session on disk.
//!
//! Each window keeps its own state in its web view and sends it here after
//! every change; this writes `session.json` shortly after (so a crash loses
//! little) and once more on quit.

use std::sync::Mutex;
use std::time::Duration;

use ghostgrid_core::session::{Session, Window};
use ghostgrid_core::settings::Settings;

use crate::paths;

pub struct Store {
    settings: Mutex<Settings>,
    /// Windows in the order they opened, by label.
    windows: Mutex<Vec<(String, Window)>>,
    dirty: Mutex<bool>,
    /// What the last run left: restored into the first windows.
    pub previous: Mutex<Option<Session>>,
}

impl Store {
    pub fn load() -> Store {
        let settings = std::fs::read_to_string(paths::settings_file()).map(|t| Settings::load(&t)).unwrap_or_default();
        let previous = std::fs::read_to_string(paths::session_file()).ok().and_then(|text| Session::decode(&text));
        Store { settings: Mutex::new(settings), windows: Mutex::new(Vec::new()), dirty: Mutex::new(false), previous: Mutex::new(previous) }
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }

    pub fn set_settings(&self, settings: Settings) -> Settings {
        let text = settings.to_json();
        let normalized = Settings::load(&text);
        *self.settings.lock().unwrap() = normalized.clone();
        if let Err(e) = paths::write_atomic(&paths::settings_file(), normalized.to_json().as_bytes()) {
            eprintln!("ghostgrid: could not save settings: {e}");
        }
        normalized
    }

    pub fn update_window(&self, label: &str, window: Window) {
        let mut windows = self.windows.lock().unwrap();
        match windows.iter_mut().find(|(l, _)| l == label) {
            Some(entry) => entry.1 = window,
            None => windows.push((label.to_string(), window)),
        }
        *self.dirty.lock().unwrap() = true;
    }

    /// A window closed by the user: it leaves the session.
    pub fn remove_window(&self, label: &str) {
        self.windows.lock().unwrap().retain(|(l, _)| l != label);
        *self.dirty.lock().unwrap() = true;
    }

    pub fn session(&self) -> Session {
        Session::new(self.windows.lock().unwrap().iter().map(|(_, w)| w.clone()).collect())
    }

    pub fn save(&self) {
        *self.dirty.lock().unwrap() = false;
        let session = self.session();
        if let Err(e) = paths::write_atomic(&paths::session_file(), session.encode().as_bytes()) {
            eprintln!("ghostgrid: could not save the session: {e}");
        }
    }

    /// Saves shortly after changes, at most twice a second.
    pub fn autosave(store: &'static Store) {
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(500));
            if *store.dirty.lock().unwrap() {
                store.save();
            }
        });
    }
}
