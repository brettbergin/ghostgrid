#if os(macOS)
    import Darwin
    import Foundation
    import Testing
    @testable import GhostGridCore

    /// End to end against the built ghostgrid-sessiond: a shell keeps
    /// running when its pane disconnects, a reattach replays its output and
    /// takes input again, and terminating it ends it for good.
    @Suite(.serialized)
    struct SessionDaemonTests {
        /// A blocking test client: one socket, one decoder.
        final class Client {
            let fd: Int32
            var decoder = SessionFrameDecoder()

            init?(socket path: String) {
                fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8CString)
                withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0 else {
                    Darwin.close(fd)
                    return nil
                }
            }

            func send(_ message: SessionMessage) {
                let data = message.encoded()
                _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            }

            /// Messages until `done` says stop, or `timeout` seconds pass.
            func receive(timeout: Double = 5, until done: ([SessionMessage]) -> Bool) -> [SessionMessage] {
                var messages: [SessionMessage] = []
                let deadline = Date().addingTimeInterval(timeout)
                var buffer = [UInt8](repeating: 0, count: 65536)
                while !done(messages), Date() < deadline {
                    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 100) > 0 else { continue }
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    messages += decoder.append(Data(buffer[0..<count]))
                }
                return messages
            }

            deinit { Darwin.close(fd) }
        }

        static func output(_ messages: [SessionMessage]) -> String {
            messages.map { message -> String in
                switch message {
                case let .output(data), let .attached(_, data): String(decoding: data, as: UTF8.self)
                default: ""
                }
            }.joined()
        }

        /// The built helper: next to the test bundle, else in this
        /// package's .build/debug.
        static var helper: String? {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let candidates = Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
                .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("ghostgrid-sessiond").path }
                + [root.appendingPathComponent(".build/debug/ghostgrid-sessiond").path]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        @Test func aShellOutlivesItsPaneAndComesBackWithItsOutput() throws {
            let helper = try #require(Self.helper, "ghostgrid-sessiond was not built next to the tests")
            // Short path: sockaddr_un holds about 100 bytes.
            let socket = "/tmp/gg-test-\(getpid()).sock"
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: helper)
            daemon.arguments = ["--socket", socket]
            daemon.standardError = FileHandle.nullDevice
            try daemon.run()
            defer {
                daemon.terminate()
                unlink(socket)
            }
            var first: Client?
            for _ in 0..<50 where first == nil {
                usleep(50000)
                first = Client(socket: socket)
            }
            let pane = try #require(first, "sessiond did not start listening")

            // Start a shell that prints a marker, then echoes what it reads.
            pane.send(.hello(version: SessionMessage.protocolVersion))
            pane.send(.create(SessionLaunch(
                id: "t1", executable: "/bin/sh", arguments: ["sh", "-c", "echo ready-marker; exec cat"],
                environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm"], workingDirectory: "/tmp",
            )))
            let started = pane.receive { Self.output($0).contains("ready-marker") }
            #expect(started.contains(.welcome(version: SessionMessage.protocolVersion)))
            #expect(Self.output(started).contains("ready-marker"))

            // The pane goes away (ghostgrid quit): the shell keeps running.
            first = nil
            usleep(300_000)

            // A new ghostgrid reattaches and gets the earlier output back.
            let again = try #require(Client(socket: socket))
            again.send(.hello(version: SessionMessage.protocolVersion))
            again.send(.attach(id: "t1"))
            let attached = again.receive { $0.contains { if case .attached = $0 { true } else { false } } }
            let replay = attached.compactMap { if case let .attached(id, data) = $0 { (id, data) } else { nil } }.first
            #expect(replay?.0 == "t1")
            #expect(replay.map { String(decoding: $0.1, as: UTF8.self) }?.contains("ready-marker") == true)
            #expect(replay?.1.starts(with: Data("\u{1B}c".utf8)) == true, "replays start with a reset")

            // It still takes input.
            again.send(.input(Data("ping-marker\n".utf8)))
            #expect(Self.output(again.receive { Self.output($0).contains("ping-marker") }).contains("ping-marker"))

            // Terminating ends it, and it cannot be reattached.
            again.send(.terminate)
            let ended = again.receive { $0.contains { if case .exited = $0 { true } else { false } } }
            #expect(ended.contains { if case .exited = $0 { true } else { false } })
            let late = try #require(Client(socket: socket))
            late.send(.hello(version: SessionMessage.protocolVersion))
            late.send(.attach(id: "t1"))
            #expect(late.receive { $0.contains(.failure("no such session")) }.contains(.failure("no such session")))
        }

        @Test func aWrongProtocolVersionIsRefused() throws {
            let helper = try #require(Self.helper)
            let socket = "/tmp/gg-test-v-\(getpid()).sock"
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: helper)
            daemon.arguments = ["--socket", socket]
            daemon.standardError = FileHandle.nullDevice
            try daemon.run()
            defer {
                daemon.terminate()
                unlink(socket)
            }
            var client: Client?
            for _ in 0..<50 where client == nil {
                usleep(50000)
                client = Client(socket: socket)
            }
            let pane = try #require(client)
            pane.send(.hello(version: 999))
            #expect(pane.receive { $0.contains(.failure("protocol version mismatch")) }.contains(.failure("protocol version mismatch")))
        }
    }
#endif
