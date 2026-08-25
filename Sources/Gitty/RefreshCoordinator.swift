import Foundation
import Combine
import UserNotifications

func pullRequestURL(from notificationUserInfo: [AnyHashable: Any]) -> URL? {
    guard let urlString = notificationUserInfo["url"] as? String,
          let url = URL(string: urlString),
          url.scheme != nil,
          url.host != nil else { return nil }
    return url
}

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
    static let alertSoundFilename = "GittyChime.aiff"

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
            content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.alertSoundFilename))
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

protocol RefreshIntervalStoring: Sendable {
    func load() -> TimeInterval
    func save(_ interval: TimeInterval)
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

final class UserDefaultsRefreshIntervalStore: RefreshIntervalStoring, @unchecked Sendable {
    static let supportedIntervals: Set<TimeInterval> = [60, 300, 600]

    private let defaults: UserDefaults
    private let key = "refreshInterval"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> TimeInterval {
        let interval = defaults.double(forKey: key)
        return Self.supportedIntervals.contains(interval) ? interval : 300
    }

    func save(_ interval: TimeInterval) {
        defaults.set(interval, forKey: key)
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
    @Published private(set) var refreshInterval: TimeInterval

    private let github: any GitHubFetching
    private let notifications: any NotificationDelivering
    private let snapshots: any SnapshotStoring
    private let acknowledgements: any AttentionAcknowledgementStoring
    private let organizationFilters: any OrganizationFilterStoring
    private let refreshIntervals: any RefreshIntervalStoring
    private var fetchedPullRequests: [PullRequest] = []
    private var refreshTask: Task<Void, Never>?

    init(
        github: any GitHubFetching = GhClient(),
        notifications: any NotificationDelivering = SystemNotificationDeliverer(),
        snapshots: any SnapshotStoring = UserDefaultsSnapshotStore(),
        acknowledgements: any AttentionAcknowledgementStoring = UserDefaultsAttentionAcknowledgementStore(),
        organizationFilters: any OrganizationFilterStoring = UserDefaultsOrganizationFilterStore(),
        refreshIntervals: any RefreshIntervalStoring = UserDefaultsRefreshIntervalStore()
    ) {
        self.github = github
        self.notifications = notifications
        self.snapshots = snapshots
        self.acknowledgements = acknowledgements
        self.organizationFilters = organizationFilters
        self.refreshIntervals = refreshIntervals
        self.attentionAcknowledgements = acknowledgements.load()
        self.hiddenOrganizations = organizationFilters.load()
        self.refreshInterval = refreshIntervals.load()
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

    func setRefreshInterval(_ interval: TimeInterval) {
        guard UserDefaultsRefreshIntervalStore.supportedIntervals.contains(interval), interval != refreshInterval else { return }
        refreshInterval = interval
        refreshIntervals.save(interval)
        restartRefreshSchedule()
    }

    func start() {
        guard refreshTask == nil else { return }
        startRefreshSchedule()
    }

    private func startRefreshSchedule() {
        let interval = refreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
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
            await notifications.requestAuthorization()
            let currentSnapshot = NotificationSnapshot(pullRequests: visiblePullRequests)
            if let previousSnapshot = snapshots.load() {
                let changes = actionableChanges(from: previousSnapshot, to: visiblePullRequests)
                if !changes.isEmpty { await notifications.deliver(changes) }
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

    private func restartRefreshSchedule() {
        guard refreshTask != nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        startRefreshSchedule()
    }
}
