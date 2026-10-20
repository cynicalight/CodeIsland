import Foundation
import Darwin
import CodeIslandCore

/// Resolve a terminal-owned Codex process against the current tmux server.
/// A daemon's inherited TMUX_PANE is not a per-session location.
enum CodexTmuxRouting {
    struct Pane {
        let id: String
        let pid: pid_t
        var title: String = ""
        var cwd: String = ""
        var command: String = ""
    }

    /// Read-only probe, also used by the integration tests. Never switches a pane.
    static func probe(session: SessionSnapshot, tmuxPath: String) -> SessionSnapshot? {
        let env = session.tmuxEnv.map { ["TMUX": $0] }
        guard let data = ProcessRunner.run(path: tmuxPath,
            args: ["list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{pane_title}\t#{pane_current_path}\t#{pane_current_command}"],
            env: env, timeout: 2), let output = String(data: data, encoding: .utf8) else { return nil }
        let panes = output.split(separator: "\n").compactMap { line -> Pane? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let pid = pid_t(fields[1]) else { return nil }
            return Pane(id: String(fields[0]), pid: pid, title: String(fields[2]),
                        cwd: String(fields[3]), command: String(fields[4]))
        }
        return resolve(session: session, panes: panes, parentOf: { pid in
            processInfo(pid).map { pid_t($0.pbi_ppid) }
        }, startTime: { pid in
            processInfo(pid).map { Date(timeIntervalSince1970: TimeInterval($0.pbi_start_tvsec)) }
        })
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func resolve(
        session: SessionSnapshot,
        panes: [Pane],
        parentOf: (pid_t) -> pid_t?,
        startTime: (pid_t) -> Date?
    ) -> SessionSnapshot? {
        guard let pid = session.cliPid, pid > 1,
              let actualStart = startTime(pid) else { return nil }
        if let expectedStart = session.cliStartTime,
           abs(actualStart.timeIntervalSince(expectedStart)) >= 1 { return nil }

        var current = pid
        var visited = Set<pid_t>()
        while current > 1, visited.count < 64, visited.insert(current).inserted {
            let matches = panes.filter { $0.pid == current }
            if matches.count == 1 {
                var resolved = session
                resolved.tmuxPane = matches[0].id
                return resolved
            }
            guard matches.isEmpty, let parent = parentOf(current) else { break }
            current = parent
        }

        // Shared app-server hooks carry the daemon's environment, not the TUI's.
        // Codex TUI publishes its current thread title in the pane title. This is
        // a constrained fallback, not a session-ID mapping: reject all ambiguity.
        guard let title = session.sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, let cwd = session.cwd, !cwd.isEmpty else { return nil }
        let path = (cwd as NSString).standardizingPath
        let expected = "\(title) | \((path as NSString).lastPathComponent)"
        let matches = panes.filter {
            $0.command == "codex" && ($0.cwd as NSString).standardizingPath == path
                && normalizedTitle($0.title) == expected
        }
        guard matches.count == 1 else { return nil }
        var resolved = session
        resolved.tmuxPane = matches[0].id
        return resolved
    }
    static func normalizedTitle(_ value: String) -> String {
        // TUI's working indicator is one braille spinner followed by a space.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) else { return trimmed }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
