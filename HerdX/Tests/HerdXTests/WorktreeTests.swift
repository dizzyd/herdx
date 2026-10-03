import XCTest

@testable import HerdX

/// Does HerdX name a worktree the way herdr does?
///
/// The create sheet promises a path before anything exists to look at, so
/// these are herdr's own test vectors, copied from `worktree.rs`. A rule that
/// drifts upstream fails here rather than quietly drawing a path herdr would
/// not use — which nobody would notice until they went looking for a directory
/// that is not there.
final class WorktreeNamingTests: XCTestCase {
    func testPathSlugMatchesHerdrsVectors() {
        XCTAssertEqual(Worktrees.pathSlug("worktree/brave-river"), "worktree-brave-river")
        XCTAssertEqual(
            Worktrees.pathSlug("issue/137 Worktree Spaces"), "issue-137-worktree-spaces")
        XCTAssertEqual(Worktrees.pathSlug("///"), "worktree")
    }

    func testPathSlugCollapsesRunsAndTrimsEnds() {
        XCTAssertEqual(Worktrees.pathSlug("--a//b--"), "a-b")
        XCTAssertEqual(Worktrees.pathSlug(""), "worktree")
    }

    /// A branch with non-ASCII in it is a branch git accepts, and the folder
    /// name still has to be one.
    func testPathSlugKeepsOnlyASCIIAlphanumerics() {
        // Precomposed: one scalar, not an ASCII one, so it goes.
        XCTAssertEqual(Worktrees.pathSlug("caf\u{e9}"), "caf")
        XCTAssertEqual(Worktrees.pathSlug("\u{4e2d}\u{6587}"), "worktree")
    }

    /// The same text decomposed is a different slug, and herdr's answer is the
    /// one that matters — it is the one that names the directory.
    ///
    /// `"cafe" + U+0301` is four `Character`s and five scalars. Iterating
    /// `Character`s loses the `e` along with the accent it carries, giving
    /// `caf` where herdr gives `cafe`, so the preview promised a path the
    /// server would not create.
    func testPathSlugIteratesScalarsLikeHerdr() {
        XCTAssertEqual(Worktrees.pathSlug("cafe\u{301}"), "cafe")
        // The accent alone is still a separator, not a character.
        XCTAssertEqual(Worktrees.pathSlug("a\u{301}b"), "a-b")
        // An emoji is one Character and several scalars; none is ASCII.
        XCTAssertEqual(Worktrees.pathSlug("x\u{1F600}y"), "x-y")
    }

    /// Lowercasing is ASCII's, not Unicode's, because herdr's is.
    func testPathSlugLowercasesOnlyASCII() {
        XCTAssertEqual(Worktrees.pathSlug("ABC-123"), "abc-123")
        // Turkish dotless I lowercases to a non-ASCII letter under Unicode
        // rules; herdr never gets that far, since it is not ASCII to begin
        // with.
        XCTAssertEqual(Worktrees.pathSlug("I\u{131}I"), "i-i")
    }

    func testGeneratedBranchMatchesHerdrsVectors() {
        XCTAssertEqual(Worktrees.generatedBranch(seed: 0), "worktree/brave-river-0000")
        XCTAssertEqual(Worktrees.generatedBranch(seed: 9), "worktree/calm-cloud-0009")
    }

    /// The suggestion is only useful if it is a branch name, and a slug of it
    /// is only a directory name if it survives the trip.
    func testTheSuggestedBranchIsAlwaysUsable() {
        for offset in [0.0, 1.5, 86_400.0, 1_790_000_000.0] {
            let branch = Worktrees.branchSuggestion(now: Date(timeIntervalSince1970: offset))
            XCTAssertTrue(branch.hasPrefix("worktree/"), "\(branch) left herdr's namespace")
            XCTAssertNotEqual(Worktrees.pathSlug(branch), "worktree", "\(branch) slugged to nothing")
        }
    }

    /// The path is the endpoint's, and the endpoint may not be a Mac. These
    /// three are herdr's own cases.
    func testCheckoutPathFollowsTheEndpointsSeparator() {
        XCTAssertEqual(
            Worktrees.checkoutPath(root: "/worktrees/", repo: "repo", branch: "feature/a"),
            "/worktrees/repo/feature-a")
        XCTAssertEqual(
            Worktrees.checkoutPath(root: #"C:\worktrees\"#, repo: "repo", branch: "feature/a"),
            #"C:\worktrees\repo\feature-a"#)
        XCTAssertEqual(
            Worktrees.checkoutPath(root: #"\\server\share"#, repo: "repo", branch: "feature/a"),
            #"\\server\share\repo\feature-a"#)
    }

    /// A posix root with a backslash in a directory name is still posix. The
    /// leading slash decides, which is why herdr tests it first.
    func testAPosixRootIsNotMistakenForWindows() {
        XCTAssertEqual(
            Worktrees.checkoutPath(root: #"/odd\dir"#, repo: "repo", branch: "b"),
            #"/odd\dir/repo/b"#)
    }

    func testOnlyTheChosenSeparatorIsTrimmed() {
        // Several trailing slashes are one separator's worth, and a trailing
        // backslash on a posix root is part of the directory's name.
        XCTAssertEqual(
            Worktrees.checkoutPath(root: "/a///", repo: "r", branch: "b"), "/a/r/b")
        XCTAssertEqual(
            Worktrees.checkoutPath(root: #"/a\"#, repo: "r", branch: "b"), #"/a\/r/b"#)
    }
}

/// Which worktree actions apply to the workspace you are in.
///
/// herdr refuses two of the three from inside a linked checkout and the third
/// from outside one. Getting this backwards would send someone to remove the
/// repo they work in, so the rule is tested rather than trusted to read right.
final class WorktreeGuardTests: XCTestCase {
    private func workspace(linked: Bool?) -> Snapshot.Workspace {
        let worktree = linked.map {
            #"{"key":"k","label":"repo","is_linked_worktree":\#($0)}"#
        }
        let json = """
            {"workspace_id":"w1","number":1,"label":"repo","focused":true,
             "agent_status":"idle"\(worktree.map { ",\"worktree\":\($0)" } ?? "")}
            """
        // Decoded rather than constructed, so the field names these guards
        // depend on are the ones herdr actually sends.
        return try! JSONDecoder().decode(Snapshot.Workspace.self, from: Data(json.utf8))
    }

    func testNewAndOpenAreRefusedInsideALinkedCheckout() {
        let linked = workspace(linked: true)
        for action in [Keymap.Action.newWorktree, .openWorktree] {
            let refusal = Worktrees.refusal(for: action, workspace: linked)
            XCTAssertEqual(
                refusal, "New and open worktree actions start from the repo parent workspace.",
                "\(action) was allowed from inside a worktree")
        }
    }

    func testNewAndOpenAreAllowedFromTheRepoItself() {
        for workspace in [workspace(linked: false), workspace(linked: nil)] {
            XCTAssertNil(Worktrees.refusal(for: .newWorktree, workspace: workspace))
            XCTAssertNil(Worktrees.refusal(for: .openWorktree, workspace: workspace))
        }
    }

    /// A workspace carrying a `worktree` is not thereby a worktree: the repo's
    /// own checkout carries one too, with `is_linked_worktree` false.
    func testRemoveNeedsALinkedCheckoutAndNotMerelyARepo() {
        XCTAssertNil(Worktrees.refusal(for: .removeWorktree, workspace: workspace(linked: true)))
        for workspace in [workspace(linked: false), workspace(linked: nil)] {
            XCTAssertEqual(
                Worktrees.refusal(for: .removeWorktree, workspace: workspace),
                "This workspace is not a Herdr-managed worktree checkout.")
        }
    }

    func testNoFocusedWorkspaceIsItsOwnAnswer() {
        XCTAssertEqual(
            Worktrees.refusal(for: .newWorktree, workspace: nil), "no workspace is focused")
    }

    func testTheForcePathIsOnlyTakenForTheFailuresThatAskForIt() {
        XCTAssertTrue(
            Worktrees.needsForce(Reply.Failure(code: "dirty_worktree_requires_force", message: nil)))
        XCTAssertTrue(
            Worktrees.needsForce(
                Reply.Failure(
                    code: "worktree_remove_failed",
                    message: "fatal: '/w/x' is not a working tree")))
        // A removal that failed for a reason forcing will not fix must be
        // reported, not re-asked: offering to force a permissions problem
        // teaches someone that the second button never works.
        XCTAssertFalse(
            Worktrees.needsForce(
                Reply.Failure(code: "worktree_remove_failed", message: "permission denied")))
        XCTAssertFalse(Worktrees.needsForce(Reply.Failure(code: "not_found", message: nil)))
        XCTAssertFalse(Worktrees.needsForce(Reply.Failure(code: nil, message: nil)))
    }
}

/// Does a flow still know which machine it is about?
///
/// A worktree flow is several requests with a person's decisions between them,
/// and nothing stops the window moving to another machine in the gaps. These
/// are the only thing standing between "Force Remove" answered late and a
/// deleted checkout on a machine the question never mentioned — workspace ids
/// are only unique within a server, so A's id means something on B.
final class WorktreeTargetTests: XCTestCase {
    private let sessionToken = UUID()
    private lazy var target = Worktrees.Target(
        session: sessionToken, endpoint: 2, bootID: "boot-A", label: "Alemetry")

    func testAFlowOnItsOwnMachineMayAct() {
        XCTAssertNil(
            Worktrees.drift(
                from: target, session: sessionToken, activeEndpoint: 2, bootID: "boot-A"))
    }

    /// The force-removal case: confirmed for A, answered after the window
    /// moved to B. B is where the request would go, so it must not be sent.
    func testAFlowIsAbandonedOnceAnotherMachineIsInFront() {
        XCTAssertEqual(
            Worktrees.drift(
                from: target, session: sessionToken, activeEndpoint: 3, bootID: "boot-B"),
            "Alemetry is no longer in front of you")
    }

    /// Switching away and back is not a free pass if the server restarted in
    /// between: the ids the flow holds describe a session that is gone, and a
    /// workspace id can have been reissued to something else.
    func testASameEndpointWithANewBootIsADifferentMachine() {
        XCTAssertEqual(
            Worktrees.drift(
                from: target, session: sessionToken, activeEndpoint: 2, bootID: "boot-A2"),
            "Alemetry is no longer in front of you")
    }

    /// A machine that has dropped has no boot id, which is not a licence to
    /// send to whatever is there instead.
    func testAnEndpointWithNoBootIdIsNotActedOn() {
        XCTAssertNotNil(
            Worktrees.drift(
                from: target, session: sessionToken, activeEndpoint: 2, bootID: nil))
    }

    /// `reattach` builds a new session with its own endpoints; index 2 on the
    /// new one need not be the machine index 2 was.
    /// `reattach` builds a new session with its own endpoints; index 2 on the
    /// new one need not be the machine index 2 was.
    ///
    /// Compared by token rather than by holding the session, which is not a
    /// detail: a flow that kept its session would keep it alive through the
    /// reply it is waiting on, and a reply that never comes would keep its
    /// sockets, ssh children and reconnect threads alive for good.
    func testARebuiltSessionStopsTheFlowEvenOnAMatchingIndex() {
        XCTAssertEqual(
            Worktrees.drift(
                from: target, session: UUID(), activeEndpoint: 2, bootID: "boot-A"),
            "the connection was rebuilt")
    }

    /// And no session at all is not a licence to carry on.
    func testNoSessionStopsTheFlow() {
        XCTAssertEqual(
            Worktrees.drift(from: target, session: nil, activeEndpoint: 2, bootID: "boot-A"),
            "the connection was rebuilt")
    }
}

/// What goes on the wire, since a request herdr rejects does nothing and says
/// nothing.
final class WorktreeRequestTests: XCTestCase {
    private func params(_ command: Command) throws -> [String: Any] {
        let json = try XCTUnwrap(command.requestJSON(id: "1"))
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(body["params"] as? [String: Any])
    }

    private func method(_ command: Command) throws -> String {
        let json = try XCTUnwrap(command.requestJSON(id: "1"))
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(body["method"] as? String)
    }

    func testTheMethodNamesAreHerdrs() throws {
        XCTAssertEqual(try method(.worktreeList(workspace: "w1")), "worktree.list")
        XCTAssertEqual(
            try method(.worktreeCreate(workspace: "w1", branch: "b")), "worktree.create")
        XCTAssertEqual(try method(.worktreeOpen(workspace: "w1", path: "/p")), "worktree.open")
        XCTAssertEqual(
            try method(.worktreeRemove(workspace: "w1", force: false)), "worktree.remove")
    }

    /// `base` is what the branch is cut from, and herdr's own client says HEAD
    /// rather than leaving it out.
    func testCreateCutsFromHeadAndDoesNotAskForFocus() throws {
        let params = try params(.worktreeCreate(workspace: "w1", branch: "feature/x"))
        XCTAssertEqual(params["workspace_id"] as? String, "w1")
        XCTAssertEqual(params["branch"] as? String, "feature/x")
        XCTAssertEqual(params["base"] as? String, "HEAD")
        // Deliberate: the reply names the tab, and focusing it is a second
        // request. Asking here would focus nothing and look like a no-op.
        XCTAssertNil(params["focus"])
    }

    /// Unlike create: opening an existing checkout is asking to be in it.
    func testOpenAsksForFocus() throws {
        let params = try params(.worktreeOpen(workspace: "w1", path: "/w/x"))
        XCTAssertEqual(params["path"] as? String, "/w/x")
        XCTAssertEqual(params["focus"] as? Bool, true)
    }

    /// herdr's `WorktreeRemoveParams.workspace_id` is required, and `force`
    /// has to be sent both ways round for the two-stage confirm to mean
    /// anything.
    func testRemoveCarriesTheWorkspaceAndTheForceFlag() throws {
        let gentle = try params(.worktreeRemove(workspace: "w1", force: false))
        XCTAssertEqual(gentle["workspace_id"] as? String, "w1")
        XCTAssertEqual(gentle["force"] as? Bool, false)
        let forced = try params(.worktreeRemove(workspace: "w1", force: true))
        XCTAssertEqual(forced["force"] as? Bool, true)
    }

    /// The three the menu carries are flows, not payloads. One built as a
    /// request would go out with an empty method, which herdr drops in
    /// silence.
    func testTheMenusWorktreeCommandsAreNotRequests() {
        for command in [Command.newWorktree, .openWorktree, .removeWorktree] {
            XCTAssertFalse(command.hasRequest, "\(command) claims a method")
            XCTAssertNil(command.requestJSON(id: "1"))
        }
    }

    /// Tags address menu items, so a collision silently fires the wrong one.
    func testEveryCommandTagIsStillUnique() {
        let commands: [Command] = [
            .newTab, .closeTab, .nextTab, .previousTab, .splitRight, .splitDown, .focusLeft,
            .focusDown, .focusUp, .focusRight, .closePane, .zoomPane, .newWorkspace,
            .focusPane(""), .focusTab(""), .focusWorkspace(""), .copyMode, .closeTabWithID(""),
            .help, .settings, .detach, .toggleSidebar, .reloadConfig, .closeWorkspace(""),
            .swapLeft, .swapDown, .swapUp, .swapRight, .editScrollback(""), .renameTab("", ""),
            .renamePane("", ""), .renameWorkspace("", ""), .resizePane(""), .closePaneWithID(""),
            .newLocalWorkspace, .paneList, .paneProcessInfo(""), .layoutExport(""),
            .hibernateWorkspace, .createWorkspace(cwd: "", label: ""),
            .paneSendText(pane: "", text: ""), .paneGet(""), .zoomPaneWithID(""),
            .newWorktree, .openWorktree, .removeWorktree, .worktreeList(workspace: ""),
            .worktreeCreate(workspace: "", branch: ""), .worktreeOpen(workspace: "", path: ""),
            .worktreeRemove(workspace: "", force: false),
        ]
        let tags = commands.map(\.tag)
        XCTAssertEqual(Set(tags).count, tags.count, "two commands share a tag")
    }
}

/// The replies these flows read, which carry what the next step needs.
final class WorktreeReplyTests: XCTestCase {
    private let list = """
        {"id":"1","result":{
          "source":{"repo_key":"k","repo_name":"herdx","repo_root":"/src/herdx",
                    "source_checkout_path":"/src/herdx"},
          "worktrees":[
            {"path":"/src/herdx","is_bare":false,"is_detached":false,"is_prunable":false,
             "is_linked_worktree":false,"label":"herdx","branch":"main"},
            {"path":"/wt/herdx/feature-a","is_bare":false,"is_detached":false,
             "is_prunable":false,"is_linked_worktree":true,"label":"feature-a",
             "branch":"feature/a","open_workspace_id":"w7"},
            {"path":"/wt/herdx/gone","is_bare":false,"is_detached":true,"is_prunable":true,
             "is_linked_worktree":true,"label":"gone"},
            {"path":"/src/herdx.git","is_bare":true,"is_detached":false,"is_prunable":false,
             "is_linked_worktree":false,"label":"bare"}
          ]}}
        """

    func testTheListDecodesWhatThePickerShows() throws {
        let result = try XCTUnwrap(
            try? Reply.decode(Reply.WorktreeList.self, from: list).get())
        XCTAssertEqual(result.source.repoName, "herdx")
        XCTAssertEqual(result.worktrees.count, 4)
        XCTAssertEqual(result.worktrees[1].openWorkspaceID, "w7")
    }

    /// A bare repo has no working tree to open and a prunable one is a
    /// checkout whose directory has gone. herdr's own picker drops both, and
    /// offering either is offering something that cannot work.
    func testBareAndPrunableCheckoutsAreNotOffered() throws {
        let result = try XCTUnwrap(
            try? Reply.decode(Reply.WorktreeList.self, from: list).get())
        XCTAssertEqual(result.openable.map(\.path), ["/src/herdx", "/wt/herdx/feature-a"])
    }

    /// The branch is what anyone is looking for; the label is the fallback for
    /// a detached checkout that has no branch to name.
    func testAnEntryIsTitledByItsBranchThenItsLabel() throws {
        let result = try XCTUnwrap(
            try? Reply.decode(Reply.WorktreeList.self, from: list).get())
        XCTAssertEqual(result.worktrees[1].title, "feature/a")
        XCTAssertEqual(result.worktrees[2].title, "gone")
    }

    /// The whole reason create does not ask for focus.
    func testCreatedCarriesTheTabToFocus() throws {
        let body = """
            {"id":"1","result":{
              "workspace":{"workspace_id":"w9"},
              "tab":{"tab_id":"w9:t1"},
              "root_pane":{"pane_id":"w9:p1"},
              "worktree":{"path":"/wt/herdx/feature-b","branch":"feature/b",
                          "is_bare":false,"is_detached":false,"is_prunable":false,
                          "is_linked_worktree":true,"label":"feature-b"}}}
            """
        let created = try XCTUnwrap(
            try? Reply.decode(Reply.WorktreeCreated.self, from: body).get())
        XCTAssertEqual(created.tab.tabID, "w9:t1")
        XCTAssertEqual(created.worktree.branch, "feature/b")
    }

    /// Where the create sheet's path preview comes from.
    func testTheSnapshotCarriesTheWorktreeDirectory() throws {
        let body = """
            {"boot_id":"b","revision":1,"worktree_directory":"/Users/me/worktrees",
             "workspaces":[],"tabs":[],"panes":[],"agents":[]}
            """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(body.utf8))
        XCTAssertEqual(snapshot.worktreeDirectory, "/Users/me/worktrees")
    }

    /// A server too old to publish it still has to decode, with the sheet
    /// simply not promising a path.
    func testASnapshotWithoutOneStillDecodes() throws {
        let body = """
            {"boot_id":"b","revision":1,"workspaces":[],"tabs":[],"panes":[],"agents":[]}
            """
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(body.utf8))
        XCTAssertNil(snapshot.worktreeDirectory)
    }
}
