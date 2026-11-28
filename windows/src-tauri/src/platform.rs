//! The bits of Windows ghostgrid talks to directly: the clipboard, opening
//! links and files with their default app, and putting `gg` on PATH.

use std::ptr::null_mut;

use windows_sys::Win32::Foundation::{GlobalFree, HANDLE, HWND, LPARAM, WPARAM};
use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::Ole::CF_UNICODETEXT;
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_EXPAND_SZ,
};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{SendMessageTimeoutW, HWND_BROADCAST, SMTO_ABORTIFHUNG, SW_SHOWNORMAL, WM_SETTINGCHANGE};

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

/// The clipboard opens only when no other app holds it; try a few times.
fn open_clipboard() -> bool {
    for _ in 0..10 {
        // SAFETY: no owner window; closed by the caller.
        if unsafe { OpenClipboard(null_mut()) } != 0 {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    false
}

pub fn clipboard_write(text: &str) -> Result<(), String> {
    let data = wide(text);
    if !open_clipboard() {
        return Err("the clipboard is busy".into());
    }
    // SAFETY: the global block is filled while locked and handed to the
    // clipboard, which then owns it; on failure it is freed here.
    unsafe {
        EmptyClipboard();
        let bytes = data.len() * 2;
        let block = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if block.is_null() {
            CloseClipboard();
            return Err("out of memory".into());
        }
        let target = GlobalLock(block) as *mut u16;
        std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
        GlobalUnlock(block);
        if SetClipboardData(CF_UNICODETEXT as u32, block as HANDLE).is_null() {
            GlobalFree(block);
            CloseClipboard();
            return Err("could not set the clipboard".into());
        }
        CloseClipboard();
    }
    Ok(())
}

pub fn clipboard_read() -> Option<String> {
    if !open_clipboard() {
        return None;
    }
    // SAFETY: the clipboard's block is only read while locked.
    unsafe {
        let handle = GetClipboardData(CF_UNICODETEXT as u32);
        let text = if handle.is_null() {
            None
        } else {
            let source = GlobalLock(handle as _) as *const u16;
            if source.is_null() {
                None
            } else {
                let mut len = 0;
                while *source.add(len) != 0 {
                    len += 1;
                }
                let text = String::from_utf16_lossy(std::slice::from_raw_parts(source, len));
                GlobalUnlock(handle as _);
                Some(text)
            }
        };
        CloseClipboard();
        text
    }
}

/// Opens a URL or file with its default app (the shell's "open" verb).
pub fn shell_open(target: &str) -> Result<(), String> {
    let verb = wide("open");
    let file = wide(target);
    // SAFETY: NUL-terminated strings that outlive the call.
    let result = unsafe { ShellExecuteW(null_mut(), verb.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL) };
    if result as isize > 32 {
        Ok(())
    } else {
        Err(format!("could not open {target}"))
    }
}

/// Opens `path` in an editor: VS Code when it is installed (`code` on
/// PATH), else Notepad.
pub fn open_in_editor(path: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let code = std::process::Command::new("cmd").args(["/C", "code", path]).creation_flags(CREATE_NO_WINDOW).status();
    if code.map(|s| s.success()).unwrap_or(false) {
        return Ok(());
    }
    std::process::Command::new("notepad.exe").arg(path).spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn read_user_path() -> Option<String> {
    let key_name = wide("Environment");
    let value_name = wide("Path");
    let mut key: HKEY = null_mut();
    // SAFETY: registry calls with buffers sized from the first query.
    unsafe {
        if RegOpenKeyExW(HKEY_CURRENT_USER, key_name.as_ptr(), 0, KEY_READ, &mut key) != 0 {
            return None;
        }
        let mut size = 0u32;
        let mut kind = 0u32;
        let found = RegQueryValueExW(key, value_name.as_ptr(), null_mut(), &mut kind, null_mut(), &mut size) == 0;
        let text = if found && size > 0 {
            let mut buffer = vec![0u16; size as usize / 2 + 1];
            RegQueryValueExW(key, value_name.as_ptr(), null_mut(), &mut kind, buffer.as_mut_ptr().cast(), &mut size);
            let end = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
            Some(String::from_utf16_lossy(&buffer[..end]))
        } else {
            Some(String::new())
        };
        RegCloseKey(key);
        text
    }
}

/// Writes `gg.cmd` (which opens a pane in each folder it is given, or the
/// current one, starting ghostgrid if needed) into ghostgrid's bin folder
/// and adds that folder to the user's PATH. New terminals see it.
pub fn install_gg() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let bin = crate::paths::bin_dir();
    std::fs::create_dir_all(&bin).map_err(|e| e.to_string())?;
    let script = format!(
        "@echo off\r\nrem ghostgrid: a pane in each folder given (default: this one). Generated by ghostgrid.\r\nif \"%~1\"==\"\" (\r\n  start \"\" \"{exe}\" --open \"%CD%\"\r\n) else (\r\n  start \"\" \"{exe}\" --cwd \"%CD%\" --open %*\r\n)\r\n",
        exe = exe.display()
    );
    std::fs::write(bin.join("gg.cmd"), script).map_err(|e| e.to_string())?;

    let dir = bin.display().to_string();
    let current = read_user_path().unwrap_or_default();
    if !current.split(';').any(|p| p.trim_end_matches('\\').eq_ignore_ascii_case(dir.trim_end_matches('\\'))) {
        let updated = if current.is_empty() { dir.clone() } else { format!("{};{dir}", current.trim_end_matches(';')) };
        let key_name = wide("Environment");
        let value_name = wide("Path");
        let data = wide(&updated);
        let mut key: HKEY = null_mut();
        // SAFETY: registry write of a NUL-terminated wide string.
        unsafe {
            if RegOpenKeyExW(HKEY_CURRENT_USER, key_name.as_ptr(), 0, KEY_WRITE, &mut key) != 0 {
                return Err("could not open the user environment".into());
            }
            let status = RegSetValueExW(key, value_name.as_ptr(), 0, REG_EXPAND_SZ, data.as_ptr().cast(), (data.len() * 2) as u32);
            RegCloseKey(key);
            if status != 0 {
                return Err("could not update PATH".into());
            }
            let environment = wide("Environment");
            let mut result = 0usize;
            SendMessageTimeoutW(HWND_BROADCAST as HWND, WM_SETTINGCHANGE, 0 as WPARAM, environment.as_ptr() as LPARAM, SMTO_ABORTIFHUNG, 2000, &mut result);
        }
    }
    Ok(bin.join("gg.cmd").display().to_string())
}

/// The top-level window under a screen point, as a raw handle.
pub fn window_at(x: i32, y: i32) -> Option<isize> {
    use windows_sys::Win32::Foundation::POINT;
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetAncestor, WindowFromPoint, GA_ROOT};
    // SAFETY: plain queries.
    unsafe {
        let hwnd = WindowFromPoint(POINT { x, y });
        if hwnd.is_null() {
            return None;
        }
        Some(GetAncestor(hwnd, GA_ROOT) as isize)
    }
}

/// The Windows build number (CurrentBuildNumber), 0 when unreadable.
pub fn os_build() -> u32 {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let key = wide(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion");
    let value = wide("CurrentBuildNumber");
    let mut buffer = [0u16; 32];
    let mut size = (buffer.len() * 2) as u32;
    // SAFETY: fixed buffer, size in bytes.
    let status = unsafe {
        RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, null_mut(), buffer.as_mut_ptr().cast(), &mut size)
    };
    if status != 0 {
        return 0;
    }
    let end = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..end]).trim().parse().unwrap_or(0)
}
