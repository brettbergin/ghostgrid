//! Contract for what a Ctrl-clicked link opens (LinkPolicyTests): only
//! web, mail and file links; a bare path only when it exists, relative to
//! the pane's folder.

use ghostgrid_core::links::{self, Link};

const HOME: &str = "C:\\Users\\me";
const CWD: &str = "C:\\Users\\me\\code";

fn open_in(raw: &str, cwd: Option<&str>, existing: &[&str]) -> Option<Link> {
    links::resolve(raw, cwd, HOME, &|path| existing.contains(&path))
}

fn open(raw: &str, existing: &[&str]) -> Option<Link> {
    open_in(raw, Some(CWD), existing)
}

fn file(path: &str) -> Option<Link> {
    Some(Link::File(path.into()))
}

#[test]
fn web_mail_and_file_links_open() {
    assert_eq!(
        open("https://ghostty.org/docs", &[]),
        Some(Link::Url("https://ghostty.org/docs".into()))
    );
    assert_eq!(
        open("http://localhost:3000", &[]),
        Some(Link::Url("http://localhost:3000".into()))
    );
    assert_eq!(
        open("mailto:me@example.com", &[]),
        Some(Link::Url("mailto:me@example.com".into()))
    );
    assert_eq!(
        open("HTTPS://EXAMPLE.COM", &[]),
        Some(Link::Url("HTTPS://EXAMPLE.COM".into()))
    );
    assert_eq!(
        open("file:///C:/tmp/x%20y.txt", &[]),
        file("C:\\tmp\\x y.txt")
    );
    assert_eq!(
        open("  https://x.dev\n", &[]),
        Some(Link::Url("https://x.dev".into())),
        "surrounding space is trimmed"
    );
}

#[test]
fn other_schemes_are_refused() {
    for raw in [
        "javascript:alert(1)",
        "vscode://file/etc/passwd",
        "x-apple.systempreferences:com.apple.preference",
        "ms-settings:display",
        "search-ms:query=x",
    ] {
        assert_eq!(open(raw, &[raw]), None, "{raw}");
    }
}

#[test]
fn bare_paths_open_only_when_they_exist() {
    assert_eq!(
        open("C:\\Windows\\hosts", &["C:\\Windows\\hosts"]),
        file("C:\\Windows\\hosts")
    );
    assert_eq!(open("C:\\nope", &[]), None);
    assert_eq!(
        open("C:/tmp/a.txt", &["C:\\tmp\\a.txt"]),
        file("C:\\tmp\\a.txt"),
        "a drive letter is not a scheme"
    );
    assert_eq!(
        open("\\\\server\\share\\f.txt", &["\\\\server\\share\\f.txt"]),
        file("\\\\server\\share\\f.txt")
    );
    assert_eq!(open("", &[]), None);
}

#[test]
fn relative_and_home_paths_resolve() {
    assert_eq!(
        open("README.md", &["C:\\Users\\me\\code\\README.md"]),
        file("C:\\Users\\me\\code\\README.md")
    );
    assert_eq!(
        open("..\\notes.txt", &["C:\\Users\\me\\notes.txt"]),
        file("C:\\Users\\me\\notes.txt")
    );
    assert_eq!(
        open("../notes.txt", &["C:\\Users\\me\\notes.txt"]),
        file("C:\\Users\\me\\notes.txt")
    );
    assert_eq!(
        open(".\\a\\.\\b\\..\\c", &["C:\\Users\\me\\code\\a\\c"]),
        file("C:\\Users\\me\\code\\a\\c")
    );
    assert_eq!(
        open("~\\x", &["C:\\Users\\me\\x"]),
        file("C:\\Users\\me\\x")
    );
    assert_eq!(open("~/x", &["C:\\Users\\me\\x"]), file("C:\\Users\\me\\x"));
    assert_eq!(open("~", &["C:\\Users\\me"]), file("C:\\Users\\me"));
    assert_eq!(open_in("README.md", None, &[]), None);
    assert_eq!(
        open("C:\\a\\..\\..\\b", &["C:\\b"]),
        file("C:\\b"),
        "nothing above the root"
    );
}

#[test]
fn folders_inside_wsl_resolve_with_forward_slashes() {
    assert_eq!(
        open_in(
            "src/main.rs",
            Some("/home/me/app"),
            &["/home/me/app/src/main.rs"]
        ),
        file("/home/me/app/src/main.rs")
    );
}
