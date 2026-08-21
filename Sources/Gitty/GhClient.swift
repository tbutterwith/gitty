import Foundation

struct CommandOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum GhError: LocalizedError, Equatable {
    case executableUnavailable
    case notAuthenticated(String)
    case commandFailed(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable: "Gitty could not find the gh CLI. Install it from cli.github.com."
        case .notAuthenticated(let detail): "GitHub CLI needs authentication. Run gh auth login in Terminal.\(detail.isEmpty ? "" : " \(detail)")"
        case .commandFailed(let detail): "The gh CLI could not refresh pull requests. \(detail)"
        case .malformedResponse: "Gitty received an unexpected response from the gh CLI."
        }
    }
}

protocol CommandRunning: Sendable {
    func run(arguments: [String]) async throws -> CommandOutput
}

struct GhExecutableResolver: Sendable {
    private let inheritedPath: String?
    private let isExecutable: @Sendable (String) -> Bool

    init(
        inheritedPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.inheritedPath = inheritedPath
        self.isExecutable = isExecutable
    }

    func resolve() -> URL? {
        let standardLocations = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        let inheritedLocations = (inheritedPath ?? "").split(separator: ":").map { "\($0)/gh" }
        return (standardLocations + inheritedLocations).first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}

struct GhProcessRunner: CommandRunning {
    private let executableResolver: GhExecutableResolver

    init(executableResolver: GhExecutableResolver = GhExecutableResolver()) {
        self.executableResolver = executableResolver
    }

    func run(arguments: [String]) async throws -> CommandOutput {
        guard let executableURL = executableResolver.resolve() else {
            throw GhError.executableUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { completed in
                continuation.resume(returning: CommandOutput(
                    stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
                    stderr: stderr.fileHandleForReading.readDataToEndOfFile(),
                    exitCode: completed.terminationStatus
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GhError.executableUnavailable)
            }
        }
    }
}

protocol GitHubFetching: Sendable {
    func validateAuthentication() async throws
    func fetchPullRequests() async throws -> [PullRequest]
}

struct GhClient: GitHubFetching {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = GhProcessRunner()) {
        self.runner = runner
    }

    func validateAuthentication() async throws {
        let result = try await runner.run(arguments: ["auth", "status", "--hostname", "github.com"])
        guard result.exitCode == 0 else {
            if result.exitCode == 127 || result.stderrString.localizedCaseInsensitiveContains("no such file") {
                throw GhError.executableUnavailable
            }
            throw GhError.notAuthenticated(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func fetchPullRequests() async throws -> [PullRequest] {
        let authored = try await fetchSearch(query: "is:pr is:open author:@me")
        let reviewRequested = try await fetchSearch(query: "is:pr is:open review-requested:@me")
        var payloads: [String: RawPullRequest] = [:]
        var authoredIDs = Set<String>()
        var reviewRequestedIDs = Set<String>()

        for pullRequest in authored.pullRequests {
            payloads[pullRequest.id] = pullRequest
            authoredIDs.insert(pullRequest.id)
        }
        for pullRequest in reviewRequested.pullRequests {
            payloads[pullRequest.id] = pullRequest
            reviewRequestedIDs.insert(pullRequest.id)
        }
        let viewerLogin = authored.viewerLogin.isEmpty ? reviewRequested.viewerLogin : authored.viewerLogin
        return try payloads.values.map {
            try $0.pullRequest(
                viewerLogin: viewerLogin,
                isAuthoredByViewer: authoredIDs.contains($0.id),
                isReviewRequested: reviewRequestedIDs.contains($0.id)
            )
        }.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
        }
    }

    private func fetchSearch(query: String) async throws -> (viewerLogin: String, pullRequests: [RawPullRequest]) {
        var cursor: String?
        var viewerLogin = ""
        var pullRequests: [RawPullRequest] = []
        repeat {
            let result = try await runner.run(arguments: graphqlArguments(query: query, cursor: cursor))
            guard result.exitCode == 0 else {
                throw GhError.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let page: SingleSearchResponse
            do {
                page = try JSONDecoder().decode(SingleSearchResponse.self, from: result.stdout)
            } catch {
                throw GhError.malformedResponse(error.localizedDescription)
            }
            viewerLogin = page.data.viewer.login
            pullRequests.append(contentsOf: page.data.search.nodes)
            cursor = page.data.search.pageInfo.hasNextPage ? page.data.search.pageInfo.endCursor : nil
        } while cursor != nil
        return (viewerLogin, pullRequests)
    }

    private func graphqlArguments(query: String, cursor: String?) -> [String] {
        [
            "api", "graphql",
            "-f", "query=\(Self.query)",
            "-f", "searchQuery=\(query)",
            "-F", "cursor=\(cursor ?? "null")"
        ]
    }

    // Keep nested connections comfortably below GitHub GraphQL's 500,000-node limit.
    // PR search itself is paginated, while reviews/threads focus on the most recent feedback.
    static let query = """
    query($searchQuery: String!, $cursor: String) {
      viewer { login }
      search(query: $searchQuery, type: ISSUE, first: 50, after: $cursor) {
        nodes { ...PullRequestFields }
        pageInfo { hasNextPage endCursor }
      }
    }
    fragment PullRequestFields on PullRequest {
      id number title url isDraft reviewDecision
      repository { nameWithOwner }
      statusCheckRollup { state contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { id name status conclusion }
        ... on StatusContext { id context state }
      }}}
      reviews(last: 50) { nodes { id state submittedAt author { login } } }
      reviewThreads(first: 50) { nodes { isResolved comments(last: 20) { nodes { id author { login } } } } }
    }
    """
}

private struct SingleSearchResponse: Decodable {
    let data: SearchData
}

private struct SearchData: Decodable {
    let viewer: Viewer
    let search: SearchConnection
}

private struct Viewer: Decodable { let login: String }

private struct SearchConnection: Decodable {
    let nodes: [RawPullRequest]
    let pageInfo: PageInfo
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct RawPullRequest: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let reviewDecision: String?
    let repository: Repository
    let statusCheckRollup: StatusCheckRollup?
    let reviews: Reviews
    let reviewThreads: ReviewThreads

    func pullRequest(viewerLogin: String, isAuthoredByViewer: Bool, isReviewRequested: Bool) throws -> PullRequest {
        guard let url = URL(string: url) else { throw GhError.malformedResponse("Invalid pull request URL") }
        let failedChecks = Set((statusCheckRollup?.contexts.nodes ?? []).compactMap { context -> String? in
            let conclusion = context.conclusion ?? context.state
            let failed = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion)
            return failed ? context.id : nil
        })
        let ciState: CIState
        if statusCheckRollup == nil { ciState = .none }
        else if !failedChecks.isEmpty || statusCheckRollup?.state == "FAILURE" || statusCheckRollup?.state == "ERROR" { ciState = .failing }
        else if statusCheckRollup?.state == "SUCCESS" { ciState = .passing }
        else { ciState = .pending }

        let reviewFeedback = reviews.nodes.filter {
            $0.author?.login != viewerLogin && ["CHANGES_REQUESTED", "COMMENTED"].contains($0.state)
        }.map { "review:\($0.id)" }
        let threadFeedback = reviewThreads.nodes.filter { !$0.isResolved }.flatMap(\.comments.nodes).filter {
            $0.author?.login != viewerLogin
        }.map { "comment:\($0.id)" }
        let feedbackIDs = Set(reviewFeedback + threadFeedback)
        let reviewState: ReviewState
        if isReviewRequested { reviewState = .reviewRequested }
        else if reviewDecision == "CHANGES_REQUESTED" { reviewState = .changesRequested }
        else if !feedbackIDs.isEmpty { reviewState = .feedback }
        else if reviewDecision == "APPROVED" { reviewState = .approved }
        else { reviewState = .waiting }

        return PullRequest(
            id: id, number: number, title: title, url: url, repository: repository.nameWithOwner,
            isDraft: isDraft, isAuthoredByViewer: isAuthoredByViewer, isReviewRequested: isReviewRequested,
            ciState: ciState, failedCheckIDs: failedChecks, feedbackIDs: feedbackIDs, reviewState: reviewState
        )
    }
}

private struct Repository: Decodable { let nameWithOwner: String }
private struct StatusCheckRollup: Decodable { let state: String?; let contexts: CheckContexts }
private struct CheckContexts: Decodable { let nodes: [CheckContext] }
private struct CheckContext: Decodable { let id: String; let name: String?; let context: String?; let status: String?; let conclusion: String?; let state: String? }
private struct Reviews: Decodable { let nodes: [Review] }
private struct Review: Decodable { let id: String; let state: String; let submittedAt: String?; let author: User? }
private struct ReviewThreads: Decodable { let nodes: [ReviewThread] }
private struct ReviewThread: Decodable { let isResolved: Bool; let comments: Comments }
private struct Comments: Decodable { let nodes: [ReviewComment] }
private struct ReviewComment: Decodable { let id: String; let author: User? }
private struct User: Decodable { let login: String }
