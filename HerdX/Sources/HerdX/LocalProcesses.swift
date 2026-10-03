import Darwin
import Foundation

/// What is actually running under a pane's shell.
///
/// `pane.process_info` answers a narrower question than it looks: herdr builds
/// it from `foreground_job`, which is the one process group the tty is handing
/// keystrokes to. A shell with `npm run dev &` behind it reports the shell,
/// alone and idle, because a background job has a process group of its own and
/// is not the foreground one.
///
/// That mattered because hibernation reads it as proof a pane is doing
/// nothing, and closing the workspace ends every process in the pane's session
/// — the dev server included, with nothing in the record that could bring it
/// back. The foreground reading is still the right one for *revival*, which
/// asks whether a pane is a shell sitting at a prompt; it is the wrong one for
/// deciding what may be killed.
///
/// Asked of this Mac rather than of herdr because herdr has no method that
/// answers it: `PaneProcessInfo` carries a `tty`, which would do, but it is
/// optional and not populated here. Hibernation is local-only anyway — the
/// refusal when the pane is somewhere else is in `hibernateFocusedWorkspace`.
enum LocalProcesses {
    struct Entry: Equatable {
        let pid: Int32
        let ppid: Int32
        let name: String
    }

    /// Every process on this Mac, as parent and child, from one `sysctl`.
    ///
    /// One call rather than one per pane: a workspace has a handful of panes
    /// and the table is a few hundred rows, so walking it twice is cheaper
    /// than asking the kernel twice.
    static func table() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Room to spare: processes can appear between the sizing call and the
        // reading one, and a short buffer fails the second call outright.
        var procs = [kinfo_proc](
            repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            let comm = proc.kp_proc.p_comm
            let name = withUnsafeBytes(of: comm) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
                    ?? ""
            }
            return Entry(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, name: name)
        }
    }

    /// What is running under `shell` that the foreground job does not account
    /// for — a background job, something suspended, anything left behind.
    ///
    /// Descendants rather than children: `npm run dev &` is a child, but the
    /// server it spawns is a grandchild and killing the pane takes both.
    ///
    /// Pure, and takes the table, so the rule can be tested against a process
    /// tree written down in a test rather than whatever this Mac is running.
    static func unaccounted(
        under shell: Int32, foreground: Set<Int32>, in table: [Entry]
    ) -> [String] {
        var children: [Int32: [Entry]] = [:]
        for entry in table { children[entry.ppid, default: []].append(entry) }

        var found: [String] = []
        var queue = children[shell] ?? []
        // A pid cannot be its own ancestor, but a table read while processes
        // come and go can disagree with itself; `seen` keeps that from
        // becoming a loop.
        var seen: Set<Int32> = [shell]
        while let next = queue.popLast() {
            guard seen.insert(next.pid).inserted else { continue }
            if !foreground.contains(next.pid) { found.append(next.name) }
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        return found
    }
}
