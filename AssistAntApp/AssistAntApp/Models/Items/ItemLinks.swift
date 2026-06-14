import Foundation

/// Resolves the openable external links for a set of items — the
/// todo/reminder/explore `externalURL`s, parsed to URLs, missing/invalid
/// dropped, de-duplicated in first-seen order. Pure (Foundation only) so it is
/// unit-testable; the actual open (NSWorkspace) happens at the call sites (the
/// cluster button + the `a l` chords), which already use AppKit.
enum ItemLinks {
    static func urls(for items: [Item]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for item in items {
            guard let raw = item.actionableExternalURL,
                  let url = URL(string: raw),
                  url.scheme != nil,                 // a real absolute URL
                  seen.insert(raw).inserted else { continue }
            out.append(url)
        }
        return out
    }
}
