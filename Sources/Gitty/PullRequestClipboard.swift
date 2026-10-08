import AppKit

@discardableResult
func copyPullRequestLink(_ pullRequest: PullRequest, to pasteboard: NSPasteboard = .general) -> Bool {
    let item = pullRequestPasteboardItem(pullRequest)

    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
}

func pullRequestPasteboardItem(_ pullRequest: PullRequest) -> NSPasteboardItem {
    let url = pullRequest.url.absoluteString
    let html = #"<a href="\#(htmlEscaped(url))">\#(htmlEscaped(pullRequest.title))</a>"#
    let item = NSPasteboardItem()

    item.setString("\(pullRequest.title) \(url)", forType: .string)
    item.setData(Data(html.utf8), forType: .html)
    return item
}

private func htmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}
