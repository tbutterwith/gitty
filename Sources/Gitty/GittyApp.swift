import AppKit
import SwiftUI

final class GittyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct GittyApp: App {
    @NSApplicationDelegateAdaptor(GittyAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = GittyViewModel()

    var body: some Scene {
        MenuBarExtra {
            GittyMenu(viewModel: viewModel)
                .frame(width: 390, height: 460)
        } label: {
            Image(systemName: viewModel.menuBarSymbol)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            GittySettingsView()
        }
    }
}

private struct GittyMenu: View {
    @ObservedObject var viewModel: GittyViewModel

    private var attention: [PullRequest] {
        viewModel.pullRequests.filter { $0.needsAttention && !viewModel.isAcknowledged($0) }
    }
    private var authored: [PullRequest] {
        viewModel.pullRequests.filter { $0.isAuthoredByViewer && (!$0.needsAttention || viewModel.isAcknowledged($0)) }
    }
    private var reviewRequests: [PullRequest] {
        viewModel.pullRequests.filter {
            $0.isReviewRequested && !$0.isAuthoredByViewer && (!$0.needsAttention || viewModel.isAcknowledged($0))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            VStack(spacing: 0) {
                HStack {
                    if let lastRefreshed = viewModel.lastRefreshed {
                        Text("Last updated \(lastRefreshed, format: .dateTime.hour().minute())")
                    } else {
                        Text("Last updated —")
                    }
                    Spacer()
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRefreshing)
                    .accessibilityLabel("Refresh pull requests")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 3)

                SettingsLink {
                    MenuActionLabel("Preferences…")
                }
                .buttonStyle(.plain)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    MenuActionLabel("Quit Gitty")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.bottom, 2)
        }
        .task { viewModel.start() }
    }

    @ViewBuilder private var content: some View {
        if let error = viewModel.errorMessage {
            VStack(spacing: 12) {
                ContentUnavailableView("GitHub unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                if viewModel.needsGhInstallation {
                    Link("Install GitHub CLI", destination: URL(string: "https://cli.github.com/")!)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        } else if viewModel.isRefreshing && viewModel.pullRequests.isEmpty {
            ProgressView("Checking your pull requests…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.pullRequests.isEmpty {
            ContentUnavailableView("No open pull requests", systemImage: "checkmark.circle", description: Text("You are all caught up."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !attention.isEmpty {
                        PullRequestSection(
                            title: "Needs attention", pullRequests: attention, openPullRequest: openPullRequest,
                            isAcknowledged: viewModel.isAcknowledged, toggleAcknowledgement: viewModel.toggleAcknowledgement
                        )
                    }
                    if !authored.isEmpty {
                        PullRequestSection(
                            title: "Your pull requests", pullRequests: authored, openPullRequest: openPullRequest,
                            isAcknowledged: viewModel.isAcknowledged, toggleAcknowledgement: viewModel.toggleAcknowledgement
                        )
                    }
                    if !reviewRequests.isEmpty {
                        PullRequestSection(
                            title: "Review requests", pullRequests: reviewRequests, openPullRequest: openPullRequest,
                            isAcknowledged: viewModel.isAcknowledged, toggleAcknowledgement: viewModel.toggleAcknowledgement
                        )
                    }
                }
                .padding(.top, 7)
            }
        }
    }

    private func openPullRequest(_ pullRequest: PullRequest) {
        NSWorkspace.shared.open(pullRequest.url)
        guard !NSEvent.modifierFlags.contains(.command) else { return }
        NSApp.keyWindow?.orderOut(nil)
    }
}

private struct MenuActionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct PullRequestSection: View {
    let title: String
    let pullRequests: [PullRequest]
    let openPullRequest: (PullRequest) -> Void
    var isAcknowledged: ((PullRequest) -> Bool)?
    var toggleAcknowledgement: ((PullRequest) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 3)
            ForEach(pullRequests) { pullRequest in
                PullRequestMenuItem(
                    pullRequest: pullRequest,
                    openPullRequest: openPullRequest,
                    isAcknowledged: isAcknowledged?(pullRequest) ?? false,
                    toggleAcknowledgement: toggleAcknowledgement
                )
            }
        }
    }
}

private struct PullRequestMenuItem: View {
    let pullRequest: PullRequest
    let openPullRequest: (PullRequest) -> Void
    let isAcknowledged: Bool
    let toggleAcknowledgement: ((PullRequest) -> Void)?
    @State private var isHovered = false

    private var canAcknowledge: Bool {
        pullRequest.needsAttention && toggleAcknowledgement != nil
    }

    var body: some View {
        ZStack {
            Button { openPullRequest(pullRequest) } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: pullRequest.ciState.symbol)
                    .foregroundStyle(pullRequest.ciState == .failing ? .red : pullRequest.ciState == .passing ? .green : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(pullRequest.repository) #\(pullRequest.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pullRequest.title)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if isHovered, canAcknowledge, let toggleAcknowledgement {
                            Button {
                                toggleAcknowledgement(pullRequest)
                            } label: {
                                Image(systemName: isAcknowledged ? "checkmark.circle.fill" : "checkmark.circle")
                                    .foregroundStyle(isAcknowledged ? .secondary : .primary)
                                    .frame(width: 18, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isAcknowledged ? "Mark as unacknowledged" : "Acknowledge")
                            .accessibilityLabel(isAcknowledged ? "Mark \(pullRequest.title) as unacknowledged" : "Acknowledge \(pullRequest.title)")
                        } else {
                            if pullRequest.isDraft { Text("Draft") }
                            Text(pullRequest.ciState.label)
                            Text("·")
                            Text(pullRequest.reviewState.label)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .allowsHitTesting(canAcknowledge && isHovered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct GittySettingsView: View {
    var body: some View {
        Form {
            Section("GitHub CLI") {
                Text("Gitty uses your existing gh CLI session. If GitHub is unavailable, run gh auth login in Terminal and refresh Gitty.")
            }
            Section("Refresh") {
                Text("Gitty refreshes on launch and every five minutes.")
            }
            Section("Notifications") {
                Text("Gitty alerts you to new CI failures, review requests, and review feedback after its first successful refresh.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding()
    }
}
