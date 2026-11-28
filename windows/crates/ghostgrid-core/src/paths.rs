//! Path text as Windows ghostgrid meets it: Windows paths (`C:\x`, `C:/x`,
//! `\\server\share\x`), WSL and MSYS paths (`/home/x`), and `file://` URLs
//! from shells. Everything here works on strings, lexically, so it can be
//! tested without a file system and behaves the same on any host.

/// Whether `c` separates path components (Windows accepts both).
pub fn is_separator(c: char) -> bool {
    c == '\\' || c == '/'
}

/// `C:` followed by a separator or nothing: a path on a drive.
pub fn is_drive_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() >= 2
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes.len() == 2 || bytes[2] == b'\\' || bytes[2] == b'/')
}

/// Whether `path` names the same place whatever folder it is read from:
/// a drive path, a UNC path, or one starting at a root (`\x`, and `/x` as
/// WSL and Git Bash write them). `~` is not absolute: it needs a home.
pub fn is_absolute(path: &str) -> bool {
    is_drive_path(path) || path.starts_with('\\') || path.starts_with('/')
}

/// The home folder for `~`: USERPROFILE, then HOME.
pub fn home_from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    ["USERPROFILE", "HOME"]
        .iter()
        .find_map(|key| env(key).filter(|v| !v.is_empty()))
}

/// `~`, `~\x` and `~/x` with the home folder put in; nil for anything
/// else (including `~user`, which Windows has no way to look up).
pub fn expand_home(path: &str, home: &str) -> Option<String> {
    if path == "~" {
        return Some(home.to_string());
    }
    let rest = path
        .strip_prefix("~\\")
        .or_else(|| path.strip_prefix("~/"))?;
    Some(join(home, rest))
}

/// The separator a path is written with: forward slashes for a path that
/// starts with one (WSL, Git Bash), backslashes otherwise.
fn separator_for(path: &str) -> char {
    let posix_root = path.starts_with('/') && !path.starts_with("//");
    let posix_relative = !is_absolute(path) && path.contains('/') && !path.contains('\\');
    if posix_root || posix_relative {
        '/'
    } else {
        '\\'
    }
}

/// `name` inside Windows folder `dir`, as written (no normalizing), so a
/// candidate path reads the way the user's PATH spells it.
pub fn in_folder(dir: &str, name: &str) -> String {
    if dir.ends_with(is_separator) {
        format!("{dir}{name}")
    } else {
        format!("{dir}\\{name}")
    }
}

/// `relative` inside `base`, with `.` and `..` resolved.
pub fn join(base: &str, relative: &str) -> String {
    if relative.is_empty() {
        return normalize(base);
    }
    let separator = separator_for(base);
    let mut text = base.to_string();
    if !text.ends_with(is_separator) {
        text.push(separator);
    }
    text.push_str(relative);
    normalize(&text)
}

/// The root a path starts with and what follows it.
fn split_root(path: &str) -> (String, &str, char) {
    if is_drive_path(path) {
        let drive = &path[..2];
        let rest = if path.len() > 2 { &path[3..] } else { "" };
        return (format!("{drive}\\"), rest, '\\');
    }
    let bytes = path.as_bytes();
    if bytes.len() >= 2 && is_separator(bytes[0] as char) && is_separator(bytes[1] as char) {
        // \\server\share is the root of a UNC path.
        let rest = &path[2..];
        let mut parts = rest.splitn(3, is_separator);
        let server = parts.next().unwrap_or("");
        let share = parts.next().unwrap_or("");
        let tail = parts.next().unwrap_or("");
        let mut root = format!("\\\\{server}");
        if !share.is_empty() {
            root.push('\\');
            root.push_str(share);
        }
        return (root, tail, '\\');
    }
    if let Some(rest) = path.strip_prefix('/') {
        return ("/".into(), rest, '/');
    }
    if let Some(rest) = path.strip_prefix('\\') {
        return ("\\".into(), rest, '\\');
    }
    (String::new(), path, separator_for(path))
}

/// `path` with `.` and `..` resolved and separators made uniform, without
/// touching the disk (a `..` never climbs above the root).
pub fn normalize(path: &str) -> String {
    let (root, rest, separator) = split_root(path);
    let mut parts: Vec<&str> = Vec::new();
    for part in rest.split(is_separator) {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else if root.is_empty() {
                    parts.push("..");
                }
            }
            part => parts.push(part),
        }
    }
    let body = parts.join(&separator.to_string());
    if root.starts_with("\\\\") && !body.is_empty() {
        format!("{root}\\{body}")
    } else if root.is_empty() && body.is_empty() {
        ".".into()
    } else {
        root + &body
    }
}

/// Decodes `%XX` escapes (as UTF-8); malformed escapes stay as written.
pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(value) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(value);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The folder a `file://host/path` URL names: a drive path
/// (`file://host/C:/Users/x`, `file:///C:/x`) becomes `C:\Users\x`; a
/// path without a drive (`/home/x`, from WSL) stays as it is. nil when it
/// is not a file URL.
pub fn file_url_to_path(url: &str) -> Option<String> {
    let scheme = url.get(..7)?;
    if !scheme.eq_ignore_ascii_case("file://") {
        return None;
    }
    let rest = &url[7..];
    let path = match rest.find('/') {
        Some(slash) => &rest[slash..],
        None => return None,
    };
    let path = percent_decode(path);
    let without_slash = &path[1..];
    if is_drive_path(without_slash) {
        let drive = without_slash.replace('/', "\\");
        return Some(if drive.len() == 2 {
            drive + "\\"
        } else {
            drive
        });
    }
    Some(path)
}

/// A Windows path as WSL sees it: `C:\Users\x` is `/mnt/c/Users/x`, a
/// path inside a distribution (`\\wsl$\Ubuntu\home`) is `/home`; anything
/// else keeps its text with forward slashes.
pub fn to_wsl_path(path: &str) -> String {
    if is_drive_path(path) {
        let drive = path[..1].to_ascii_lowercase();
        let rest = path[2..].replace('\\', "/");
        let rest = if rest.is_empty() { "/".into() } else { rest };
        return format!("/mnt/{drive}{rest}");
    }
    let forward = path.replace('\\', "/");
    for prefix in ["//wsl$/", "//wsl.localhost/"] {
        if forward.len() > prefix.len() && forward[..prefix.len()].eq_ignore_ascii_case(prefix) {
            let inside = &forward[prefix.len()..];
            return match inside.find('/') {
                Some(slash) => inside[slash..].to_string(),
                None => "/".into(),
            };
        }
    }
    forward
}

/// The Windows path for a WSL path under `/mnt/<drive>`, nil for one that
/// lives inside the distribution.
pub fn from_wsl_path(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/mnt/")?;
    let mut chars = rest.chars();
    let drive = chars.next().filter(|c| c.is_ascii_alphabetic())?;
    let tail = chars.as_str();
    if !(tail.is_empty() || tail.starts_with('/')) {
        return None;
    }
    let tail = tail.replace('/', "\\");
    let tail = if tail.is_empty() { "\\".into() } else { tail };
    Some(format!("{}:{tail}", drive.to_ascii_uppercase()))
}

/// Whether a folder can be a Windows process's working directory.
pub fn is_windows_folder(path: &str) -> bool {
    is_drive_path(path) || path.starts_with("\\\\") || path.starts_with("//")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_each_kind_of_path() {
        assert_eq!(normalize("C:/a/./b/../c"), "C:\\a\\c");
        assert_eq!(normalize("C:"), "C:\\");
        assert_eq!(
            normalize("\\\\server\\share\\x\\..\\y"),
            "\\\\server\\share\\y"
        );
        assert_eq!(normalize("/home/me/../you/"), "/home/you");
        assert_eq!(normalize("a/../../b"), "../b");
        assert_eq!(join("C:\\x\\", "..\\y"), "C:\\y");
        assert_eq!(join("/home/me", "src/a"), "/home/me/src/a");
    }

    #[test]
    fn decodes_percent_escapes() {
        assert_eq!(percent_decode("a%20b%zz%4"), "a b%zz%4");
        assert_eq!(percent_decode("caf%C3%A9"), "caf\u{e9}");
    }
}
