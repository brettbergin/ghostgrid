import Foundation
import Testing
@testable import GhostGridCore

/// Contract for commands as blocks (PR 4): the pane's output stream, with
/// the shell integration's OSC 133 marks and ghostgrid's command-line
/// report (OSC 633;E), becomes a list of commands with their plain-text
/// output and exit status.
struct CommandBlockTests {
    let esc = "\u{1B}"
    func osc(_ body: String, st: Bool = false) -> String { "\(esc)]\(body)" + (st ? "\(esc)\\" : "\u{07}") }

    /// One prompt + command + output + finish, as zsh emits it.
    func run(_ command: String, output: String, code: Int) -> String {
        osc("133;A") + "~ ❯ " + osc("133;B") + command + "\r\n" + osc("633;E;" + CommandLineReport.escape(command))
            + osc("133;C") + output + osc("133;D;\(code)")
    }

    func parse(_ text: String, chunk: Int? = nil) -> [CommandBlock] {
        var parser = CommandBlockParser()
        let data = Data(text.utf8)
        if let chunk {
            var offset = 0
            while offset < data.count {
                parser.feed(data.subdata(in: offset..<min(offset + chunk, data.count)))
                offset += chunk
            }
        } else {
            parser.feed(data)
        }
        return parser.blocks
    }

    @Test func eachCommandBecomesABlock() {
        let blocks = parse(run("ls", output: "a\r\nb\r\n", code: 0) + run("false", output: "", code: 1))
        #expect(blocks.map(\.command) == ["ls", "false"])
        #expect(blocks.map(\.output) == ["a\nb\n", ""])
        #expect(blocks.map(\.exitCode) == [0, 1])
        #expect(blocks.map(\.isFinished) == [true, true])
    }

    @Test func aRunningCommandIsAnUnfinishedBlock() throws {
        let blocks = parse(osc("633;E;sleep 9") + osc("133;C") + "working")
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block.command == "sleep 9")
        #expect(block.output == "working")
        #expect(!block.isFinished && block.exitCode == nil)
    }

    @Test func colorsAndOtherEscapesAreStripped() {
        let output = "\(esc)[1;31mred\(esc)[0m \(esc)]8;;https://x\u{07}link\(esc)]8;;\u{07}\(esc)(B done\r\n"
        #expect(parse(run("x", output: output, code: 0)).first?.output == "red link done\n")
    }

    @Test func carriageReturnsOverwriteTheLineLikeAProgressBar() {
        #expect(parse(run("x", output: "10%\r50%\r100%\r\nok\r\n", code: 0)).first?.output == "100%\nok\n")
        #expect(parse(run("x", output: "abc\u{08}d\r\n", code: 0)).first?.output == "abd\n")
    }

    @Test func splitReadsAndUnicodeSurvive() {
        let text = run("echo héllo 🌍", output: "héllo 🌍\r\n", code: 0) + run("pwd", output: "/tmp\r\n", code: 0)
        for chunk in [1, 2, 3, 5, 7] {
            let blocks = parse(text, chunk: chunk)
            #expect(blocks.map(\.command) == ["echo héllo 🌍", "pwd"], "chunk \(chunk)")
            #expect(blocks.map(\.output) == ["héllo 🌍\n", "/tmp\n"], "chunk \(chunk)")
        }
    }

    @Test func oscWithStringTerminatorAndNoCommandReportWork() {
        // nushell emits its own marks, without a command-line report.
        let text = osc("133;A", st: true) + "> " + osc("133;B", st: true) + "ls\r\n" + osc("133;C", st: true) + "x\r\n"
            + osc("133;D;0", st: true)
        let blocks = parse(text)
        #expect(blocks.count == 1)
        #expect(blocks.first?.output == "x\n")
        #expect(blocks.first.map { $0.command == nil } == true)
    }

    @Test func commandLineEscapesRoundTrip() {
        for command in ["a;b", #"echo "x\y""#, "for i in 1 2\ndo echo $i\ndone", "tab\there", "\u{1B}[x"] {
            #expect(CommandLineReport.unescape(CommandLineReport.escape(command)) == command)
            #expect(!CommandLineReport.escape(command).contains(";"))
            #expect(!CommandLineReport.escape(command).contains("\n"))
        }
        let blocks = parse(run("for i in 1 2\ndo echo $i;\ndone", output: "1\r\n2\r\n", code: 0))
        #expect(blocks.first?.command == "for i in 1 2\ndo echo $i;\ndone")
    }

    @Test func historyAndOutputAreBounded() {
        var parser = CommandBlockParser(maximumBlocks: 3, maximumOutput: 10)
        for index in 0..<5 {
            parser.feed(Data(run("c\(index)", output: String(repeating: "x", count: 25) + "\r\n", code: 0).utf8))
        }
        #expect(parser.blocks.map(\.command) == ["c2", "c3", "c4"])
        let bounded = parser.blocks.map { $0.output.utf8.count <= 10 && $0.isTruncated }
        #expect(bounded == [true, true, true])
        #expect(parser.blocks.map(\.id) == [2, 3, 4], "ids keep counting")
    }

    @Test func aResetStartsOver() {
        var parser = CommandBlockParser()
        parser.feed(Data(run("ls", output: "a\r\n", code: 0).utf8))
        parser.reset()
        #expect(parser.blocks.isEmpty)
    }

    @Test func replayedBlocksHaveNoTiming() {
        var parser = CommandBlockParser()
        parser.feed(Data(run("ls", output: "a\r\n", code: 0).utf8), replayed: true)
        #expect(parser.blocks.map(\.duration) == [nil], "a replay's timing is not the command's")
        parser.feed(Data(run("pwd", output: "/\r\n", code: 0).utf8))
        #expect(parser.blocks.map { $0.duration != nil } == [false, true])
    }

    @Test func aBlockReadsAsCommandThenOutput() throws {
        let block = try #require(parse(run("ls -1", output: "a\r\nb\r\n", code: 2)).first)
        #expect(block.transcript(prompt: "$ ") == "$ ls -1\na\nb\n")
        #expect(block.summary == "exit 2")
    }
}
