import XCTest
@testable import Gitty

final class GittyTests: XCTestCase {
    func testActionableChangesOnlyContainNewEvents() {
        let old = makePullRequest(id: "1", failed: [], feedback: [], reviewRequested: false)
        let previous = NotificationSnapshot(pullRequests: [old])
        let changed = makePullRequest(id: "1", failed: ["check-1"], feedback: ["review-2"], reviewRequested: true)

        let changes = actionableChanges(from: previous, to: [changed])

        XCTAssertEqual(changes.map(\.kind), [.ciFailure, .reviewRequest, .feedback])
        XCTAssertEqual(changes.map(\.pullRequest.id), ["1", "1", "1"])
    }

    func testExistingEventsDoNotNotifyAgain() {
        let pullRequest = makePullRequest(id: "1", failed: ["check-1"], feedback: ["review-2"], reviewRequested: true)
        let previous = NotificationSnapshot(pullRequests: [pullRequest])

        XCTAssertTrue(actionableChanges(from: previous, to: [pullRequest]).isEmpty)
    }

    func testNewPullRequestsProduceANotificationAfterTheInitialSnapshot() {
        let existing = makePullRequest(id: "existing", failed: [], feedback: [], reviewRequested: false)
        let new = makePullRequest(id: "new", failed: [], feedback: [], reviewRequested: false)
        let previous = NotificationSnapshot(pullRequests: [existing])

        let changes = actionableChanges(from: previous, to: [existing, new])

        XCTAssertEqual(changes.map(\.kind), [.newPullRequest])
        XCTAssertEqual(changes.first?.pullRequest.id, "new")
    }

    func testLegacySnapshotsDoNotAnnounceEveryExistingPullRequestAsNew() throws {
        let legacySnapshot = try JSONDecoder().decode(
            NotificationSnapshot.self,
            from: Data(#"{"failedCheckIDs":[],"reviewRequestIDs":[],"feedbackIDs":[]}"#.utf8)
        )
        let pullRequest = makePullRequest(id: "existing", failed: [], feedback: [], reviewRequested: false)

        XCTAssertNil(legacySnapshot.observedPullRequestIDs)
        XCTAssertTrue(actionableChanges(from: legacySnapshot, to: [pullRequest]).isEmpty)
    }

    func testSnapshotTracksOnlyAuthorFailuresAndFeedback() {
        let authored = makePullRequest(id: "authored", failed: ["check"], feedback: ["feedback"], reviewRequested: false)
        let reviewRequest = makePullRequest(id: "review", authored: false, failed: ["other-check"], feedback: ["other-feedback"], reviewRequested: true)

        let snapshot = NotificationSnapshot(pullRequests: [authored, reviewRequest])

        XCTAssertEqual(snapshot.failedCheckIDs, ["check"])
        XCTAssertEqual(snapshot.feedbackIDs, ["feedback"])
        XCTAssertEqual(snapshot.reviewRequestIDs, ["review"])
    }

    func testAttentionFingerprintChangesForNewActionableWork() {
        let initial = makePullRequest(id: "1", failed: ["check-1"], feedback: [], reviewRequested: false)
        let later = makePullRequest(id: "1", failed: ["check-1", "check-2"], feedback: ["review-1"], reviewRequested: false)

        XCTAssertNotEqual(initial.attentionFingerprint, later.attentionFingerprint)
    }

    func testOrganizationFiltersExcludeAllRepositoriesForAnOwner() {
        let personal = makePullRequest(id: "personal", repository: "tbutterwith/dot-journal", failed: [], feedback: [], reviewRequested: false)
        let enterprise = makePullRequest(id: "enterprise", repository: "veedstudio/app", failed: [], feedback: [], reviewRequested: false)
        let otherPersonal = makePullRequest(id: "other-personal", repository: "tbutterwith/gitty", failed: [], feedback: [], reviewRequested: false)

        XCTAssertEqual(
            filteredPullRequests([personal, enterprise, otherPersonal], excluding: ["tbutterwith"]).map(\.id),
            ["enterprise"]
        )
    }

    func testOrganizationFiltersAreCaseInsensitive() {
        let pullRequest = makePullRequest(id: "1", repository: "VeedStudio/App", failed: [], feedback: [], reviewRequested: false)

        XCTAssertTrue(filteredPullRequests([pullRequest], excluding: ["veedstudio"]).isEmpty)
    }

    func testGhClientDecodesAndMergesTheTwoQueries() async throws {
        let runner = StubRunner(outputs: [
            output(json: Self.authoredResponse),
            output(json: Self.reviewRequestResponse)
        ])
        let pullRequests = try await GhClient(runner: runner).fetchPullRequests()

        XCTAssertEqual(pullRequests.count, 2)
        XCTAssertEqual(pullRequests.first(where: { $0.id == "PR_authored" })?.ciState, .failing)
        XCTAssertEqual(pullRequests.first(where: { $0.id == "PR_authored" })?.reviewState, .changesRequested)
        XCTAssertTrue(pullRequests.first(where: { $0.id == "PR_review" })?.isReviewRequested == true)
    }

    func testGhClientReportsInvalidAuthentication() async {
        let runner = StubRunner(outputs: [CommandOutput(stdout: Data(), stderr: Data("token invalid".utf8), exitCode: 1)])
        do {
            try await GhClient(runner: runner).validateAuthentication()
            XCTFail("Expected authentication failure")
        } catch let error as GhError {
            XCTAssertEqual(error, .notAuthenticated("token invalid"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGhClientReportsMissingExecutable() async {
        let runner = StubRunner(outputs: [CommandOutput(stdout: Data(), stderr: Data("env: gh: No such file or directory".utf8), exitCode: 127)])
        do {
            try await GhClient(runner: runner).validateAuthentication()
            XCTFail("Expected executable failure")
        } catch let error as GhError {
            XCTAssertEqual(error, .executableUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolverFindsHomebrewGhWithAGuiLikePath() {
        let resolver = GhExecutableResolver(
            inheritedPath: "/usr/bin:/bin",
            isExecutable: { $0 == "/opt/homebrew/bin/gh" }
        )

        XCTAssertEqual(resolver.resolve(), URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
    }

    func testGraphQLQueryKeepsNestedConnectionsUnderTheNodeLimit() {
        XCTAssertTrue(GhClient.query.contains("search(query: $searchQuery, type: ISSUE, first: 50"))
        XCTAssertTrue(GhClient.query.contains("reviews(last: 50)"))
        XCTAssertTrue(GhClient.query.contains("reviewThreads(first: 50)"))
        XCTAssertTrue(GhClient.query.contains("comments(last: 20)"))
        XCTAssertFalse(GhClient.query.contains("comments(first: 100)"))
    }

    func testNotificationsAreDisabledForSwiftRunButEnabledForAnAppBundle() {
        XCTAssertFalse(NotificationEnvironment.supportsSystemNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/Gitty/.build/arm64-apple-macosx/debug/")
        ))
        XCTAssertTrue(NotificationEnvironment.supportsSystemNotifications(
            bundleURL: URL(fileURLWithPath: "/Applications/Gitty.app")
        ))
    }

    func testRefreshRequestsNotificationAuthorizationWhenASnapshotAlreadyExists() async {
        let old = makePullRequest(id: "1", failed: [], feedback: [], reviewRequested: false)
        let failed = makePullRequest(id: "1", failed: ["check-1"], feedback: [], reviewRequested: false)
        let notifications = RecordingNotificationDeliverer()
        let viewModel = await MainActor.run {
            GittyViewModel(
                github: StaticGitHub(pullRequests: [failed]),
                notifications: notifications,
                snapshots: StaticSnapshotStore(snapshot: NotificationSnapshot(pullRequests: [old])),
                acknowledgements: EmptyAcknowledgementStore(),
                organizationFilters: EmptyOrganizationFilterStore()
            )
        }

        await viewModel.refresh()

        let authorizationRequests = await notifications.authorizationRequestCount()
        let deliveredChanges = await notifications.deliveredChanges()
        XCTAssertEqual(authorizationRequests, 1)
        XCTAssertEqual(deliveredChanges.map(\.kind), [.ciFailure])
    }

    private func makePullRequest(
        id: String,
        authored: Bool = true,
        repository: String = "org/repo",
        failed: Set<String>,
        feedback: Set<String>,
        reviewRequested: Bool
    ) -> PullRequest {
        PullRequest(
            id: id, number: 1, title: "Test", url: URL(string: "https://github.com/org/repo/pull/1")!, repository: repository,
            isDraft: false, isAuthoredByViewer: authored, isReviewRequested: reviewRequested,
            ciState: failed.isEmpty ? .passing : .failing, failedCheckIDs: failed, feedbackIDs: feedback,
            reviewState: reviewRequested ? .reviewRequested : .waiting
        )
    }

    private func output(json: String) -> CommandOutput {
        CommandOutput(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
    }

    private static let authoredResponse = #"""
    {"data":{"viewer":{"login":"tom"},"search":{"nodes":[{"id":"PR_authored","number":1,"title":"Fix CI","url":"https://github.com/acme/gitty/pull/1","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","repository":{"nameWithOwner":"acme/gitty"},"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"id":"check-1","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}},"reviews":{"nodes":[{"id":"review-1","state":"CHANGES_REQUESTED","submittedAt":"2026-08-21T00:00:00Z","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
    """#

    private static let reviewRequestResponse = #"""
    {"data":{"viewer":{"login":"tom"},"search":{"nodes":[{"id":"PR_review","number":2,"title":"Please review","url":"https://github.com/acme/gitty/pull/2","isDraft":false,"reviewDecision":null,"repository":{"nameWithOwner":"acme/gitty"},"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
    """#
}

private actor StubRunner: CommandRunning {
    private var outputs: [CommandOutput]

    init(outputs: [CommandOutput]) { self.outputs = outputs }

    func run(arguments: [String]) async throws -> CommandOutput {
        guard !outputs.isEmpty else { throw GhError.commandFailed("No stubbed response") }
        return outputs.removeFirst()
    }
}

private struct StaticGitHub: GitHubFetching {
    let pullRequests: [PullRequest]

    func validateAuthentication() async throws {}
    func fetchPullRequests() async throws -> [PullRequest] { pullRequests }
}

private actor RecordingNotificationDeliverer: NotificationDelivering {
    private var authorizationRequests = 0
    private var changes: [ActionableChange] = []

    func requestAuthorization() async { authorizationRequests += 1 }
    func deliver(_ changes: [ActionableChange]) async { self.changes = changes }
    func authorizationRequestCount() -> Int { authorizationRequests }
    func deliveredChanges() -> [ActionableChange] { changes }
}

private struct StaticSnapshotStore: SnapshotStoring {
    let snapshot: NotificationSnapshot

    func load() -> NotificationSnapshot? { snapshot }
    func save(_ snapshot: NotificationSnapshot) {}
}

private struct EmptyAcknowledgementStore: AttentionAcknowledgementStoring {
    func load() -> [String: String] { [:] }
    func save(_ acknowledgements: [String: String]) {}
}

private struct EmptyOrganizationFilterStore: OrganizationFilterStoring {
    func load() -> [String] { [] }
    func save(_ organizations: [String]) {}
}
