import Foundation
import Combine
import UserNotifications

enum NotificationEnvironment {
    static func supportsSystemNotifications(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }
}

protocol NotificationDelivering: Sendable {
    func requestAuthorization() async
    func deliver(_ changes: [ActionableChange]) async
}

struct SystemNotificationDeliverer: NotificationDelivering {
    func requestAuthorization() async {
        guard NotificationEnvironment.supportsSystemNotifications() else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func deliver(_ changes: [ActionableChange]) async {
        guard NotificationEnvironment.supportsSystemNotifications() else { return }
        for change in changes {
            let content = UNMutableNotificationContent()
            content.title = change.title
            content.body = change.body
            content.sound = .default
            content.userInfo = ["url": change.pullRequest.url.absoluteString]
            let request = UNNotificationRequest(identifier: "\(change.kind)-\(change.pullRequest.id)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

protocol SnapshotStoring: Sendable {
    func load() -> NotificationSnapshot?
    func save(_ snapshot: NotificationSnapshot)
}

protocol AttentionAcknowledgementStoring: Sendable {
    func load() -> [String: String]
    func save(_ acknowledgements: [String: String])
}

protocol OrganizationFilterStoring: Sendable {
    func load() -> [String]
    func save(_ organizations: [String])
}

final class UserDefaultsAttentionAcknowledgementStore: AttentionAcknowledgementStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "attentionAcknowledgements"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func save(_ acknowledgements: [String: String]) {
        defaults.set(acknowledgements, forKey: key)
    }
}

final class UserDefaultsOrganizationFilterStore: OrganizationFilterStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "organizationFilters"
    private let legacyKey = "repositoryFilters"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String] {
        if let organizations = defaults.stringArray(forKey: key) {
            return organizations
        }

        let migratedOrganizations = Set((defaults.stringArray(forKey: legacyKey) ?? []).map(repositoryOwner)).sorted()
        guard !migratedOrganizations.isEmpty else { return [] }
        save(migratedOrganizations)
        defaults.removeObject(forKey: legacyKey)
        return migratedOrganizations
    }

    func save(_ organizations: [String]) {
        defaults.set(organizations, forKey: key)
    }
}

final class UserDefaultsSnapshotStore: SnapshotStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "notificationSnapshot"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> NotificationSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(NotificationSnapshot.self, from: data)
    }

    func save(_ snapshot: NotificationSnapshot) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: key)
    }
}

@MainActor
final class GittyViewModel: ObservableObject {
    @Published private(set) var pullRequests: [PullRequest] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsGhInstallation = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var attentionAcknowledgements: [String: String]
    @Published private(set) var hiddenOrganizations: [String]

    private let github: any GitHubFetching
    private let notifications: any NotificationDelivering
    private let snapshots: any SnapshotStoring
    private let acknowledgements: any AttentionAcknowledgementStoring
    private let organizationFilters: any OrganizationFilterStoring
    private var fetchedPullRequests: [PullRequest] = []
    private var refreshTask: Task<Void, Never>?

    init(
        github: any GitHubFetching = GhClient(),
        notifications: any NotificationDelivering = SystemNotificationDeliverer(),
        snapshots: any SnapshotStoring = UserDefaultsSnapshotStore(),
        acknowledgements: any AttentionAcknowledgementStoring = UserDefaultsAttentionAcknowledgementStore(),
        organizationFilters: any OrganizationFilterStoring = UserDefaultsOrganizationFilterStore()
    ) {
        self.github = github
        self.notifications = notifications
        self.snapshots = snapshots
        self.acknowledgements = acknowledgements
        self.organizationFilters = organizationFilters
        self.attentionAcknowledgements = acknowledgements.load()
        self.hiddenOrganizations = organizationFilters.load()
    }

    deinit { refreshTask?.cancel() }

    var menuBarSymbol: String {
        if isRefreshing { return "arrow.triangle.2.circlepath" }
        if errorMessage != nil { return "exclamationmark.triangle.fill" }
        if pullRequests.contains(where: { $0.needsAttention && !isAcknowledged($0) }) { return "bell.badge.fill" }
        return "arrow.triangle.pull"
    }

    func isAcknowledged(_ pullRequest: PullRequest) -> Bool {
        attentionAcknowledgements[pullRequest.id] == pullRequest.attentionFingerprint
    }

    func toggleAcknowledgement(_ pullRequest: PullRequest) {
        guard pullRequest.needsAttention else { return }
        if isAcknowledged(pullRequest) {
            attentionAcknowledgements.removeValue(forKey: pullRequest.id)
        } else {
            attentionAcknowledgements[pullRequest.id] = pullRequest.attentionFingerprint
        }
        acknowledgements.save(attentionAcknowledgements)
    }

    var availableOrganizations: [String] {
        Set(fetchedPullRequests.map { repositoryOwner($0.repository) }).sorted()
    }

    func hideOrganization(_ organization: String) {
        let normalized = normalizedOrganization(organization)
        guard !normalized.isEmpty, !hiddenOrganizations.contains(normalized) else { return }
        hiddenOrganizations.append(normalized)
        persistOrganizationFilters()
    }

    func showOrganization(_ organization: String) {
        hiddenOrganizations.removeAll { $0 == organization }
        persistOrganizationFilters()
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await github.validateAuthentication()
            let latest = try await github.fetchPullRequests()
            fetchedPullRequests = latest
            let visiblePullRequests = filteredPullRequests(latest, excluding: hiddenOrganizations)
            let currentSnapshot = NotificationSnapshot(pullRequests: visiblePullRequests)
            if let previousSnapshot = snapshots.load() {
                let changes = actionableChanges(from: previousSnapshot, to: visiblePullRequests)
                if !changes.isEmpty { await notifications.deliver(changes) }
            } else {
                await notifications.requestAuthorization()
            }
            snapshots.save(currentSnapshot)
            pullRequests = visiblePullRequests
            lastRefreshed = .now
            errorMessage = nil
            needsGhInstallation = false
        } catch {
            errorMessage = error.localizedDescription
            needsGhInstallation = (error as? GhError) == .executableUnavailable
        }
    }

    private func persistOrganizationFilters() {
        organizationFilters.save(hiddenOrganizations)
        pullRequests = filteredPullRequests(fetchedPullRequests, excluding: hiddenOrganizations)
    }
}
