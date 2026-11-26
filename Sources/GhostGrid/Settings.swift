import AppKit
import GhostGridCore
import SwiftUI

/// ghostgrid's own settings (Ghostty's config still owns how terminals
/// look). Stored in the app's defaults, domain com.brettbergin.ghostgrid.
@MainActor
final class GhostGridSettings: ObservableObject {
    static let shared = GhostGridSettings()
    /// Posted after any change, so open grids can re-lay themselves out.
    static let didChange = Notification.Name("GhostGridSettingsDidChange")

    private let defaults = UserDefaults.standard

    /// Cmd+T starts the last used shell (true) or always shows the menu.
    @Published var newPaneUsesLastShell: Bool {
        didSet { save(newPaneUsesLastShell, "newPaneUsesLastShell") }
    }

    /// After picking zsh on Cmd+Shift+T, offer the app menu.
    @Published var offerAppsAfterZsh: Bool {
        didSet { save(offerAppsAfterZsh, "offerAppsAfterZsh") }
    }

    /// The shell picked last in a pane's menu (nil: none yet).
    @Published var lastShell: String? {
        didSet { save(lastShell, "lastShell") }
    }

    /// Space between panes, in points.
    @Published var gap: Double {
        didSet { save(gap, "paneGap") }
    }

    @Published var animation: AnimationStyle {
        didSet { save(animation.rawValue, "animationStyle") }
    }

    /// The apps offered after choosing zsh (Settings > zsh app launcher),
    /// pre-filled with LaunchCatalog.defaults.
    @Published var launcherEntries: [LauncherEntry] {
        didSet { save(LaunchCatalog.encode(launcherEntries), "launcherEntries") }
    }

    /// The arrangement new windows start with.
    @Published var defaultLayout: GhostGridCore.GridLayout.Mode {
        didSet { save(defaultLayout.rawValue, "defaultLayout") }
    }

    /// A header on each pane: shell, folder, git branch.
    @Published var showPaneHeaders: Bool {
        didSet { save(showPaneHeaders, "showPaneHeaders") }
    }

    /// Badges for a bell or a long command finishing in a pane you were
    /// not looking at.
    @Published var showActivityBadges: Bool {
        didSet { save(showActivityBadges, "showActivityBadges") }
    }

    private init() {
        newPaneUsesLastShell = defaults.object(forKey: "newPaneUsesLastShell") as? Bool ?? true
        offerAppsAfterZsh = defaults.object(forKey: "offerAppsAfterZsh") as? Bool ?? true
        lastShell = defaults.string(forKey: "lastShell")
        gap = PaneGap.clamped(defaults.object(forKey: "paneGap") as? Double)
        animation = AnimationStyle(stored: defaults.string(forKey: "animationStyle"))
        showPaneHeaders = defaults.object(forKey: "showPaneHeaders") as? Bool ?? true
        defaultLayout = GhostGridCore.GridLayout.Mode(stored: defaults.string(forKey: "defaultLayout"))
        launcherEntries = LaunchCatalog.decode(defaults.data(forKey: "launcherEntries"))
        showActivityBadges = defaults.object(forKey: "showActivityBadges") as? Bool ?? true
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// The ghostgrid > Settings... window (Cmd+,).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "ghostgrid Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 720))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// What the Settings window shows. Ghostty-owned options (font, theme,
/// shaders, ...) stay in the Ghostty config; this links to it.
struct SettingsView: View {
    @ObservedObject private var settings = GhostGridSettings.shared

    var body: some View {
        Form {
            Section("New panes") {
                Picker("Cmd+T opens", selection: $settings.newPaneUsesLastShell) {
                    Text("Your last shell").tag(true)
                    Text("The shell menu").tag(false)
                }
                LabeledContent("Last shell") {
                    HStack {
                        Text(settings.lastShell ?? "none yet")
                            .foregroundStyle(.secondary)
                        Button("Forget") { settings.lastShell = nil }
                            .disabled(settings.lastShell == nil)
                    }
                }
                Toggle("Offer apps after choosing zsh (Cmd+Shift+T)", isOn: $settings.offerAppsAfterZsh)
            }

            LauncherSettingsSection(settings: settings)

            Section {
                Toggle("Show pane headers (shell, folder, git branch)", isOn: $settings.showPaneHeaders)
                Toggle("Activity badges", isOn: $settings.showActivityBadges)
            } header: {
                Text("Panes")
            } footer: {
                Text("Badges mark panes you are not looking at: a bell, or a command that ran \(Int(PaneActivity.minimumSeconds))s or more (green when it succeeded, red with the exit code when it failed). Focusing the pane clears it.")
                    .foregroundStyle(.secondary)
            }

            Section("Grid") {
                LabeledContent("Gap between panes") {
                    HStack {
                        Slider(value: $settings.gap, in: PaneGap.range, step: 2)
                            .frame(width: 180)
                        Text("\(Int(settings.gap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("New windows use", selection: $settings.defaultLayout) {
                    ForEach(GhostGridCore.GridLayout.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Animations", selection: $settings.animation) {
                    ForEach(AnimationStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LabeledContent("Config file") {
                    Text(GhosttyConfigLocation.path ?? "none (Ghostty defaults)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Restore windows") {
                    Text(SessionRestoreDescription.text)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("libghostty") {
                    Text(LibghosttyBuild.summary)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Ghostty Config") {
                        NSApp.sendAction(#selector(AppDelegate.openConfiguration(_:)), to: nil, from: nil)
                    }
                    Button("Reload") {
                        NSApp.sendAction(#selector(AppDelegate.reloadConfiguration(_:)), to: nil, from: nil)
                    }
                }
            } header: {
                Text("Ghostty")
            } footer: {
                Text("Fonts, theme, cursor, shaders and keybinds come from your Ghostty config.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A fixed starting size: the form scrolls, since the launcher list
        // can make it taller than the screen.
        .frame(minWidth: 540, idealWidth: 560, minHeight: 420, idealHeight: 720)
    }
}

/// Where ghostgrid reads the Ghostty config from (GHOSTGRID_CONFIG wins).
enum GhosttyConfigLocation {
    static var path: String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["GHOSTGRID_CONFIG"] {
            return override
        }
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty")
        for name in ["config.ghostty", "config"] {
            let path = base.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }
}

/// Session restore follows Ghostty's window-save-state.
@MainActor
enum SessionRestoreDescription {
    static var text: String {
        let value = GhosttyOptions.shared.values.string("window-save-state") ?? "default"
        let restores = SessionPolicy.shouldRestore(
            windowSaveState: value,
            systemKeepsWindows: UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows"),
        )
        return "\(restores ? "yes" : "no") (window-save-state = \(value))"
    }
}

/// Which libghostty this build links (Package.swift sets the flag when it
/// uses the local build from Scripts/build-libghostty.sh).
enum LibghosttyBuild {
    static var summary: String {
        #if GHOSTGRID_LOCAL_LIBGHOSTTY
            "local build, custom shaders on"
        #else
            "published build, custom shaders off (make libghostty)"
        #endif
    }
}

/// Settings > zsh app launcher: the apps the launcher offers after choosing
/// zsh on Cmd+Shift+T. Each row is a name, the command typed at the prompt,
/// and a description; keys 1-9 follow the order here.
struct LauncherSettingsSection: View {
    @ObservedObject var settings: GhostGridSettings

    var body: some View {
        Section {
            if settings.launcherEntries.isEmpty {
                Text("No apps: choosing zsh opens a plain shell.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(settings.launcherEntries.enumerated()), id: \.element.id) { index, _ in
                LauncherRow(
                    hotkey: index < LaunchCatalog.maximumEntries ? "\(index + 1)" : "-",
                    entry: $settings.launcherEntries[index],
                    canMoveUp: index > 0,
                    canMoveDown: index < settings.launcherEntries.count - 1,
                    move: { offset in move(index, by: offset) },
                    remove: { settings.launcherEntries.remove(at: index) },
                )
            }
            HStack {
                Button("Add App") {
                    settings.launcherEntries.append(LauncherEntry(name: "", command: ""))
                }
                .disabled(settings.launcherEntries.count >= LaunchCatalog.maximumEntries)
                Spacer()
                Button("Reset to Defaults") {
                    settings.launcherEntries = LaunchCatalog.defaults
                }
                .disabled(settings.launcherEntries.map(\.command) == LaunchCatalog.defaults.map(\.command)
                    && settings.launcherEntries.map(\.name) == LaunchCatalog.defaults.map(\.name))
            }
        } header: {
            Text("zsh app launcher")
        } footer: {
            Text("Offered after choosing zsh with Cmd+Shift+T (when the toggle above is on). The command is typed at the zsh prompt, so aliases and functions work; quitting the app leaves you in zsh. Up to \(LaunchCatalog.maximumEntries) apps, keys 1-\(LaunchCatalog.maximumEntries) in this order.")
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard settings.launcherEntries.indices.contains(target) else { return }
        settings.launcherEntries.swapAt(index, target)
    }
}

private struct LauncherRow: View {
    let hotkey: String
    @Binding var entry: LauncherEntry
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(hotkey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Name", text: $entry.name)
                        .frame(width: 110)
                    TextField("Command (typed at the prompt)", text: $entry.command)
                        .font(.system(.body, design: .monospaced))
                }
                TextField("Description", text: $entry.summary)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            VStack(spacing: 2) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}
