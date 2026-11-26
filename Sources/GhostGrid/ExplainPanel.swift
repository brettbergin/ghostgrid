import AppKit
import GhostGridCore
import SwiftUI

/// Asks the local model (LM Studio's OpenAI-style server by default) why a
/// command failed, streaming the answer as it comes.
@MainActor
enum LocalModel {
    struct Failure: Error { var message: String }

    /// Calls `update` with the answer so far, then `finish` with nil, or
    /// with what went wrong. Cancel the task to stop.
    static func explain(
        _ failure: FailedCommand,
        update: @escaping @MainActor (Explanation) -> Void,
        finish: @escaping @MainActor (String?) -> Void,
    ) -> Task<Void, Never> {
        let settings = GhostGridSettings.shared
        let endpoint = settings.modelEndpoint.trimmingCharacters(in: .whitespaces)
        let configuredModel = settings.modelName.trimmingCharacters(in: .whitespaces)
        return Task {
            do {
                guard let base = URL(string: endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint) else {
                    throw Failure(message: "the model endpoint \"\(endpoint)\" is not a URL")
                }
                let model = configuredModel.isEmpty ? try await firstModel(at: base) : configuredModel
                var request = URLRequest(url: base.appendingPathComponent("chat/completions"), timeoutInterval: 120)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try ChatStream.requestBody(model: model, messages: ExplainPrompt.messages(for: failure))
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw Failure(message: "the model server answered HTTP \(http.statusCode)")
                }
                var text = ""
                for try await line in bytes.lines {
                    switch ChatStream.event(line) {
                    case let .content(piece):
                        text += piece
                        update(Explanation.parse(text))
                    case .done:
                        finish(nil)
                        return
                    case let .failure(message):
                        throw Failure(message: message)
                    case .ignore:
                        break
                    }
                }
                finish(nil)
            } catch is CancellationError {
                return
            } catch let failure as Failure {
                finish(failure.message)
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                finish("could not reach the model at \(endpoint) (\(error.localizedDescription))")
            }
        }
    }

    /// The first chat model the server has (embedding models skipped).
    private static func firstModel(at base: URL) async throws -> String {
        struct Models: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("models"))
        guard let models = try? JSONDecoder().decode(Models.self, from: data),
              let model = models.data.first(where: { !$0.id.localizedCaseInsensitiveContains("embed") })
        else { throw Failure(message: "the model server has no chat model loaded") }
        return model.id
    }
}

/// What the explain panel shows.
@MainActor
final class ExplainModel: ObservableObject {
    enum Status: Equatable { case working, done, failed(String) }

    let blockID: Int
    let command: String
    let exitCode: Int
    @Published var explanation = Explanation(why: "", fix: nil)
    @Published var status = Status.working
    @Published var isFocused = false

    init(blockID: Int, command: String, exitCode: Int) {
        self.blockID = blockID
        self.command = command
        self.exitCode = exitCode
    }
}

/// The panel at the bottom of a pane after a command fails: why it failed
/// and a fix. It does not take the keyboard by itself, so typing goes on in
/// the shell and a reflexive Return never runs a suggested command. Once
/// focused (Pane > Explain Last Failure, or a click): Return runs the fix,
/// Escape dismisses, any other key dismisses and goes to the shell.
@MainActor
final class ExplainPanelView: NSView {
    let model: ExplainModel
    var onRun: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// A key that is not the panel's, for the terminal.
    var onForward: ((NSEvent) -> Void)?
    private let content: NSHostingView<ExplainContent>

    init(model: ExplainModel) {
        self.model = model
        content = NSHostingView(rootView: ExplainContent(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var fittingHeight: CGFloat { content.fittingSize.height }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        model.isFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        model.isFocused = false
        return true
    }

    override func mouseDown(with _: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if model.status == .done, let fix = model.explanation.fix { onRun?(fix) } else { NSSound.beep() }
        case 53: // Escape
            onDismiss?()
        default:
            onDismiss?()
            onForward?(event)
        }
    }
}

struct ExplainContent: View {
    @ObservedObject var model: ExplainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Why it failed").font(.system(size: 12, weight: .semibold))
                Text("\(model.command)  ·  exit \(model.exitCode)")
                    .font(Font(Palette.mono(11)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.status == .working { ProgressView().controlSize(.small) }
            }
            switch model.status {
            case let .failed(message):
                Text("Could not explain it: \(message). Start LM Studio's local server, or set the endpoint and model in Settings > Explain failures.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Palette.failure))
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text(model.explanation.why.isEmpty ? "Asking the local model..." : model.explanation.why)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let fix = model.explanation.fix {
                    Text(fix)
                        .font(Font(Palette.mono(12)))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
                } else if model.status == .done {
                    Text("No command fix suggested.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .foregroundStyle(Color(nsColor: Palette.text))
        .background(Color(nsColor: Palette.card).opacity(0.97))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: model.isFocused ? Palette.focus : Palette.idle), lineWidth: model.isFocused ? 2 : 1))
    }

    private var hint: String {
        if model.isFocused {
            return model.explanation.fix == nil ? "esc  dismiss" : "return  run the fix     esc  dismiss     any other key  back to the shell"
        }
        return "Cmd+Shift+E  to act on it     (keys keep going to the shell)"
    }
}
