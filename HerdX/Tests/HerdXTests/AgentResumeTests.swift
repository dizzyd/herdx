import XCTest

@testable import HerdX

/// The resume flags are herdr's, and there is no server to read them from —
/// `agent_resume::plan` is Rust-internal and nothing on the wire exposes it. So
/// this reads the vendored source instead. If it fails, herdr is right and
/// `AgentResume` is wrong.
final class AgentResumeTests: XCTestCase {
    /// herdr's own table, as text.
    private func vendoredPlan() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HerdXTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HerdX
            .deletingLastPathComponent()  // repo root
        let source = root.appendingPathComponent("vendor/herdr/src/agent_resume.rs")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// Each match arm of `plan`, keyed by the agent it is for.
    private func arms() throws -> [String: String] {
        let text = try vendoredPlan()
        // Only the body of `plan`, so the tests further down the file — which
        // quote the same flags — cannot make a missing arm look present.
        guard let start = text.range(of: "pub fn plan("),
            let end = text.range(of: "pub fn dedupe_key(")
        else {
            XCTFail("the shape of agent_resume.rs changed; this test needs rewriting")
            return [:]
        }
        let body = String(text[start.lowerBound..<end.lowerBound])

        var found: [String: String] = [:]
        let pattern = try NSRegularExpression(pattern: #"\("herdr:[a-z_]+",\s*"([a-z]+)""#)
        let matches = pattern.matches(
            in: body, range: NSRange(body.startIndex..., in: body))
        for (index, match) in matches.enumerated() {
            guard let agentRange = Range(match.range(at: 1), in: body) else { continue }
            let agent = String(body[agentRange])
            let armStart = Range(match.range, in: body)!.lowerBound
            let armEnd =
                index + 1 < matches.count
                ? Range(matches[index + 1].range, in: body)!.lowerBound : body.endIndex
            found[agent, default: ""] += String(body[armStart..<armEnd])
        }
        return found
    }

    func testEveryAgentWeResumeIsOneHerdrCanResume() throws {
        let herdrs = Set(try arms().keys)
        XCTAssertFalse(herdrs.isEmpty, "no arms parsed out of agent_resume.rs")

        let ours = AgentResume.supported
        XCTAssertTrue(
            ours.subtracting(herdrs).isEmpty,
            "we would start \(ours.subtracting(herdrs).sorted()) with arguments herdr no longer "
                + "recognises")
    }

    func testTheFlagsMatchTheOnesHerdrWouldUse() throws {
        for (agent, arm) in try arms() {
            guard AgentResume.supported.contains(agent) else { continue }
            guard let args = AgentResume.arguments(agent: agent, kind: "id", value: "SESSION")
            else {
                return XCTFail("\(agent) is listed as supported but produced no arguments")
            }
            // The flag, without the value: what herdr's arm spells literally.
            let flag = args[0].split(separator: "=").first.map(String.init) ?? args[0]
            // Two spellings in the source: a separated flag is its own string,
            // a joined one is the head of a format string.
            XCTAssertTrue(
                arm.contains("\"\(flag)\"") || arm.contains("\"\(flag)="),
                "we resume \(agent) with \(flag), which is not what herdr's own arm uses:\n\(arm)")
        }
    }

    func testWeCoverEverythingHerdrCanResume() throws {
        let herdrs = Set(try arms().keys)
        XCTAssertTrue(
            herdrs.subtracting(AgentResume.supported).isEmpty,
            "herdr grew \(herdrs.subtracting(AgentResume.supported).sorted()); those workspaces "
                + "would hibernate and come back as bare shells")
    }

    // MARK: - The shapes that are not just a flag and a value

    func testCodexResumesWithASubcommand() {
        XCTAssertEqual(
            AgentResume.arguments(agent: "codex", kind: "id", value: "abc"), ["resume", "abc"])
    }

    func testCopilotJoinsTheValueWithAnEquals() {
        XCTAssertEqual(
            AgentResume.arguments(agent: "copilot", kind: "id", value: "abc"), ["--resume=abc"])
    }

    func testLettaSplitsADefaultConversationFromItsAgent() {
        XCTAssertEqual(
            AgentResume.arguments(agent: "letta", kind: "id", value: "default:agent-7"),
            ["--conversation", "default", "--agent", "agent-7"])
        XCTAssertEqual(
            AgentResume.arguments(agent: "letta", kind: "id", value: "conv-3"),
            ["--conversation", "conv-3"])
        XCTAssertNil(
            AgentResume.arguments(agent: "letta", kind: "id", value: "default:"),
            "a default conversation with no agent names nothing")
    }

    func testOnlyPiAndOmpTakeAPath() {
        XCTAssertNotNil(AgentResume.arguments(agent: "pi", kind: "path", value: "/s/1.json"))
        XCTAssertNotNil(AgentResume.arguments(agent: "omp", kind: "path", value: "/s/1.json"))
        XCTAssertNil(
            AgentResume.arguments(agent: "claude", kind: "path", value: "/s/1.json"),
            "herdr's own arm for claude matches an id and nothing else")
    }

    func testAnUnknownAgentIsLeftAlone() {
        XCTAssertNil(AgentResume.arguments(agent: "somethingnew", kind: "id", value: "abc"))
        XCTAssertNil(AgentResume.arguments(agent: "claude", kind: "id", value: ""))
    }

    // MARK: - The line that is submitted

    func testTheLineClearsTheScreenBeforeTheAgentStarts() {
        // The shell echoes what it is given, and these agents draw inline
        // rather than on the alternate screen — so without the clear the pane
        // keeps "claude --resume <id>" above the agent for as long as it runs.
        XCTAssertEqual(
            AgentResume.commandLine(agent: "claude", kind: "id", value: "abc"),
            "clear && 'claude' '--resume' 'abc'")
    }

    func testCursorIsLaunchedByItsBinaryRatherThanItsLabel() {
        XCTAssertEqual(
            AgentResume.commandLine(agent: "cursor", kind: "id", value: "abc"),
            "clear && 'cursor-agent' '--resume' 'abc'")
    }

    func testEveryArgumentIsQuoted() {
        // A session ref can be a path, and a path can contain anything.
        let line = AgentResume.commandLine(
            agent: "pi", kind: "path", value: "/s/it's here/one two.json")
        XCTAssertEqual(line, #"clear && 'pi' '--session' '/s/it'\''s here/one two.json'"#)
    }

    func testAnAgentWithNoResumeFormHasNoLine() {
        XCTAssertNil(AgentResume.commandLine(agent: "somethingnew", kind: "id", value: "abc"))
    }

    func testTheExecutablesAreTheOnesHerdrWouldRun() throws {
        // The binary names live in detect/mod.rs rather than in the plan, so
        // they get their own reading of the vendored source.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("vendor/herdr/src/detect/mod.rs"),
            encoding: .utf8)
        guard let start = source.range(of: "pub fn interactive_agent_executable("),
            let end = source.range(of: "pub fn parse_agent_label(")
        else {
            return XCTFail("detect/mod.rs changed shape; this test needs rewriting")
        }
        let table = String(source[start.lowerBound..<end.lowerBound])

        for agent in AgentResume.supported {
            let executable = AgentResume.executable(for: agent)
            XCTAssertTrue(
                table.contains("\"\(executable)\""),
                "we would run \(executable) for \(agent), which herdr's own table does not name")
        }
        XCTAssertTrue(
            table.contains("\"cursor-agent\""),
            "cursor is the one whose binary is not its label; if that changed, so must we")
    }
}
