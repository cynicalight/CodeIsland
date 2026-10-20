import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class CodexTmuxRoutingTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1000)
    private let panes = [CodexTmuxRouting.Pane(id: "%7", pid: 70),
                         CodexTmuxRouting.Pane(id: "%14", pid: 140)]

    private func session(pid: pid_t) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = "codex"
        session.cliPid = pid
        session.cliStartTime = started
        session.tmuxPane = "%14"
        session.tmuxEnv = "/tmp/tmux-test/default,1,0"
        return session
    }

    func testSharedDaemonCannotClaimInheritedPaneForMultipleSessions() {
        for _ in 0..<3 {
            let result = CodexTmuxRouting.resolve(session: session(pid: 97662), panes: panes,
                parentOf: { [97662: 24422, 24422: 1][$0] }, startTime: { _ in self.started })
            XCTAssertNil(result)
        }
    }

    func testRealCLIUsesCurrentProcessTreeInsteadOfStalePane() {
        let result = CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { [700: 71, 71: 70, 70: 1][$0] }, startTime: { _ in self.started })
        XCTAssertEqual(result?.tmuxPane, "%7")
    }

    func testTwoCLIsInSameDirectoryResolveToDifferentPanes() {
        let parents: [pid_t: pid_t] = [700: 70, 1400: 140]
        for (pid, pane) in [(pid_t(700), "%7"), (pid_t(1400), "%14")] {
            var input = session(pid: pid)
            input.cwd = "/same/project"
            let result = CodexTmuxRouting.resolve(session: input, panes: panes,
                parentOf: { parents[$0] }, startTime: { _ in self.started })
            XCTAssertEqual(result?.tmuxPane, pane)
        }
    }

    func testClosedPaneAndReusedPIDAreRejected() {
        XCTAssertNil(CodexTmuxRouting.resolve(session: session(pid: 700), panes: [],
            parentOf: { _ in 70 }, startTime: { _ in self.started }))
        XCTAssertNil(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { _ in 70 }, startTime: { _ in self.started.addingTimeInterval(10) }))
    }

    func testMissingProcessAndAncestryCycleAreRejected() {
        var input = session(pid: 700)
        input.cliPid = nil
        XCTAssertNil(CodexTmuxRouting.resolve(session: input, panes: panes,
            parentOf: { _ in nil }, startTime: { _ in self.started }))
        XCTAssertNil(CodexTmuxRouting.resolve(session: session(pid: 700), panes: panes,
            parentOf: { _ in 700 }, startTime: { _ in self.started }))
    }
    func testSharedDaemonResolvesUniqueLiveTitleAndCwd() {
        var input = session(pid: 97662)
        input.sessionTitle = "Investigate routing"
        input.cwd = "/work/project"
        let live = CodexTmuxRouting.Pane(id: "%31", pid: 310,
            title: "⠼ Investigate routing | project", cwd: "/work/project", command: "codex")
        let result = CodexTmuxRouting.resolve(session: input, panes: panes + [live],
            parentOf: { _ in 1 }, startTime: { _ in self.started })
        XCTAssertEqual(result?.tmuxPane, "%31")
        XCTAssertNil(CodexTmuxRouting.resolve(session: input, panes: [live, live],
            parentOf: { _ in 1 }, startTime: { _ in self.started }))
        var exited = live
        exited.command = "zsh"
        XCTAssertNil(CodexTmuxRouting.resolve(session: input, panes: [exited],
            parentOf: { _ in 1 }, startTime: { _ in self.started }))
        var unrelated = live
        unrelated.cwd = "/other/project"
        XCTAssertNil(CodexTmuxRouting.resolve(session: input, panes: [unrelated],
            parentOf: { _ in 1 }, startTime: { _ in self.started }))
        unrelated = live
        unrelated.title = "Other thread | project"
        XCTAssertNil(CodexTmuxRouting.resolve(session: input, panes: [unrelated],
            parentOf: { _ in 1 }, startTime: { _ in self.started }))
    }

    func testProbeAgainstIsolatedTmuxServer() throws {
        let bin = "/opt/homebrew/bin/tmux"
        guard FileManager.default.isExecutableFile(atPath: bin) else { throw XCTSkip("tmux not installed") }
        let name = "codeisland-routing-" + UUID().uuidString
        // Dedicated server: never changes the user's sessions or active window.
        guard ProcessRunner.run(path: bin, args: ["-L", name, "-f", "/dev/null", "new-session", "-d", "-s", "routing", "sleep 30"], timeout: 3) != nil else {
            XCTFail("Could not start isolated tmux server")
            return
        }
        defer { _ = ProcessRunner.run(path: bin, args: ["-L", name, "kill-server"], timeout: 3) }
        let data = try XCTUnwrap(ProcessRunner.run(path: bin,
            args: ["-L", name, "display-message", "-p", "#{pane_pid}\t#{pane_id}\t#{socket_path}"], timeout: 3))
        let fields = try XCTUnwrap(String(data: data, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        XCTAssertEqual(fields.count, 3)
        guard fields.count == 3 else { return }
        var input = session(pid: try XCTUnwrap(pid_t(fields[0])))
        input.cliStartTime = nil
        input.tmuxEnv = "\(fields[2]),1,0"
        XCTAssertEqual(CodexTmuxRouting.probe(session: input, tmuxPath: bin)?.tmuxPane, String(fields[1]))
        input.cliPid = getpid() // The test runner is not a child of that pane.
        XCTAssertNil(CodexTmuxRouting.probe(session: input, tmuxPath: bin))
    }

    func testLiveSavedSessionsWhenRequested() throws {
        guard let fixture = ProcessInfo.processInfo.environment["CODEISLAND_TMUX_FIXTURE"] else {
            throw XCTSkip("Opt-in read-only check of locally saved sessions")
        }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixture))) as? [[String: Any]])
        for row in rows {
            var input = SessionSnapshot()
            input.source = "codex"
            input.cliPid = (row["cliPid"] as? Int).map { pid_t($0) }
            input.cliStartTime = (row["cliStartTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            input.tmuxEnv = row["tmuxEnv"] as? String
            input.tmuxPane = row["tmuxPane"] as? String
            input.sessionTitle = row["sessionTitle"] as? String
            input.cwd = row["cwd"] as? String
            let resolved = CodexTmuxRouting.probe(session: input, tmuxPath: "/opt/homebrew/bin/tmux")
            XCTAssertEqual(resolved?.tmuxPane, row["expectedPane"] as? String)
            print("Live route: \(row["sessionId"] ?? "") -> \(resolved?.tmuxPane ?? "unavailable")")
        }
    }

}
