import Foundation

/// The shell last picked in a pane's menu, kept across launches in the
/// app's defaults (com.brettbergin.ghostgrid, key lastShell).
/// Reset with: defaults delete com.brettbergin.ghostgrid lastShell
@MainActor
enum ShellMemory {
    private static let key = "lastShell"

    static var last: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
