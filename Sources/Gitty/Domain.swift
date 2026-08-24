import Foundation

enum CIState: String, Codable, Equatable, Sendable {
    case passing
    case pending
    case failing
    case none

    var label: String {
        switch self {
        case .passing: "Passing"
        case .pending: "Running"
        case .failing: "Failing"
        case .none: "No checks"
        }
    }

    var symbol: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .failing: "xmark.octagon.fill"
        case .none: "minus.circle"
        }
    }
}

enum ReviewState: String, Codable, Equatable, Sendable {
    case reviewRequested
    case changesRequested
    case feedback
    case approved
    case waiting

    var label: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .changesRequested: "Changes requested"
        case .feedback: "Feedback"
        case .approved: "Approved"
        case .waiting: "Waiting"
        }
    }
}

struct PullRequest: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    let isDraft: Bool
    let isAuthoredByViewer: Bool
    let isReviewRequested: Bool
    let ciState: CIState
    let failedCheckIDs: Set<String>
    let feedbackIDs: Set<String>
    let reviewState: ReviewState

    var needsAttention: Bool {
        ciState == .failing || reviewState == .reviewRequested || reviewState == .changesRequested || reviewState == .feedback
    }

    /// Changes whenever a new actionable state appears, so acknowledgements do not hide later work.
    var attentionFingerprint: String {
        var components = failedCheckIDs.sorted().map { "check:\($0)" }
        if isReviewRequested { components.append("review-requested") }
        if reviewState == .changesRequested { components.append("changes-requested") }
        components.append(contentsOf: feedbackIDs.sorted().map { "feedback:\($0)" })
        return components.joined(separator: "|")
    }
}

func filteredPullRequests(_ pullRequests: [PullRequest], excluding organizations: [String]) -> [PullRequest] {
    pullRequests.filter { pullRequest in
        !organizations.contains { repositoryOwner(pullRequest.repository) == normalizedOrganization($0) }
    }
}

func repositoryOwner(_ repository: String) -> String {
    repository
        .split(separator: "/", maxSplits: 1)
        .first
        .map(String.init)
        .map(normalizedOrganization) ?? ""
}

func normalizedOrganization(_ organization: String) -> String {
    organization.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

struct NotificationSnapshot: Codable, Equatable, Sendable {
    var failedCheckIDs: Set<String>
    var reviewRequestIDs: Set<String>
    var feedbackIDs: Set<String>

    init(pullRequests: [PullRequest]) {
        failedCheckIDs = Set(pullRequests.filter(\.isAuthoredByViewer).flatMap(\.failedCheckIDs))
        reviewRequestIDs = Set(pullRequests.filter(\.isReviewRequested).map(\.id))
        feedbackIDs = Set(pullRequests.filter(\.isAuthoredByViewer).flatMap(\.feedbackIDs))
    }
}

struct ActionableChange: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ciFailure
        case reviewRequest
        case feedback
    }

    let kind: Kind
    let pullRequest: PullRequest

    var title: String {
        switch kind {
        case .ciFailure: "CI failed"
        case .reviewRequest: "Review requested"
        case .feedback: "New PR feedback"
        }
    }

    var body: String { "\(pullRequest.repository) #\(pullRequest.number): \(pullRequest.title)" }
}

func actionableChanges(from previous: NotificationSnapshot, to current: [PullRequest]) -> [ActionableChange] {
    current.flatMap { pullRequest in
        var changes: [ActionableChange] = []
        if pullRequest.isAuthoredByViewer && !pullRequest.failedCheckIDs.subtracting(previous.failedCheckIDs).isEmpty {
            changes.append(ActionableChange(kind: .ciFailure, pullRequest: pullRequest))
        }
        if pullRequest.isReviewRequested && !previous.reviewRequestIDs.contains(pullRequest.id) {
            changes.append(ActionableChange(kind: .reviewRequest, pullRequest: pullRequest))
        }
        if pullRequest.isAuthoredByViewer && !pullRequest.feedbackIDs.subtracting(previous.feedbackIDs).isEmpty {
            changes.append(ActionableChange(kind: .feedback, pullRequest: pullRequest))
        }
        return changes
    }
}
