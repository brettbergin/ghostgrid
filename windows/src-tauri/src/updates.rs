//! In-app updates (Tauri's updater, the Windows counterpart of Sparkle):
//! checks the latest GitHub release's `latest-windows.json` once a day and
//! from the menu, and installs a signed update, relaunching after.
//!
//! An installed ghostgrid only takes updates signed with the key whose
//! public half is built in (GHOSTGRID_UPDATER_PUBKEY at build time; see
//! README, "Windows releases"). A build without it never checks.

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Runtime};

const PUBKEY: Option<&str> = option_env!("GHOSTGRID_UPDATER_PUBKEY");
const ENDPOINT: &str = "https://github.com/brettbergin/ghostgrid/releases/latest/download/latest-windows.json";
const DAY: f64 = 86_400.0;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub version: String,
    pub notes: Option<String>,
}

pub fn configured() -> bool {
    PUBKEY.is_some_and(|k| !k.trim().is_empty())
}

pub fn plugin<R: Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    match PUBKEY {
        Some(key) if !key.trim().is_empty() => builder.plugin(tauri_plugin_updater::Builder::new().pubkey(key).build()),
        _ => builder,
    }
}

async fn find(handle: &AppHandle) -> Result<Option<tauri_plugin_updater::Update>, String> {
    use tauri_plugin_updater::UpdaterExt;
    let url = ENDPOINT.parse().map_err(|e: url::ParseError| e.to_string())?;
    let updater = handle.updater_builder().endpoints(vec![url]).map_err(|e| e.to_string())?.build().map_err(|e| e.to_string())?;
    updater.check().await.map_err(|e| e.to_string())
}

pub async fn check(handle: &AppHandle) -> Result<Option<UpdateInfo>, String> {
    if !configured() {
        return Err("this build of ghostgrid has no update key, so it does not update itself".into());
    }
    let update = find(handle).await?;
    Ok(update.map(|u| UpdateInfo { version: u.version.clone(), notes: u.body.clone() }))
}

pub async fn install(handle: &AppHandle) -> Result<(), String> {
    let update = find(handle).await?.ok_or("ghostgrid is up to date")?;
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    handle.restart();
}

/// The daily check: on launch when the last one was a day ago or more,
/// telling every window when there is an update.
pub fn schedule(handle: &AppHandle) {
    if !configured() {
        return;
    }
    let handle = handle.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            let app = handle.state::<crate::App>();
            let mut settings = app.store.settings();
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
            if settings.check_for_updates && settings.last_update_check.is_none_or(|last| now - last >= DAY) {
                settings.last_update_check = Some(now);
                app.store.set_settings(settings);
                if let Ok(Some(update)) = check(&handle).await {
                    let _ = handle.emit("update-available", update);
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
        }
    });
}
