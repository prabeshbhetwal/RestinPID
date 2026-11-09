import AppKit

/// Keeps the panel's rows still while the pointer is over the panel, so a row can't move under a click.
///
/// Without it, the 3 s poll can open the Needs Attention group at the top (or show a busy app) the moment
/// someone clicks, and every row below slides down: the click lands on a different app. While held:
/// - rows keep their order and group; their badges, RAM and CPU still update in place
/// - an app that quits keeps its row, dimmed, until the hold ends (rows below don't slide up either)
/// - apps that newly need a row wait, and the footer counts them
/// The layout catches up when the pointer leaves the panel. Changes the person makes themselves
/// (typing a search, pinning, hiding) apply at once: those are expected.
struct LayoutHold {
    private(set) var isOn = false
    private var rows: [AppItem] = []
    private var attention: Set<pid_t> = []

    /// Snapshot of the rows as drawn right now.
    mutating func begin(_ visible: [AppItem], attention needsAttention: (AppItem) -> Bool) {
        isOn = true
        rows = visible
        attention = Set(visible.filter(needsAttention).map(\.id))
    }

    mutating func end() {
        isOn = false
        rows = []
        attention = []
    }

    /// The held rows, with fresh state for apps still listed and the last known row for apps that left.
    func rows(updatedFrom all: [AppItem]) -> [AppItem] {
        let fresh = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map { fresh[$0.id] ?? $0 }
    }

    func contains(_ id: pid_t) -> Bool { rows.contains { $0.id == id } }

    /// Group as drawn when the hold began, so an app that freezes doesn't jump into Needs Attention.
    func inAttentionGroup(_ id: pid_t) -> Bool { attention.contains(id) }
}

/// Click protection: a click within this long of the rows changing was aimed at the old layout, so it's
/// ignored. 0.5 s is the "recent input" window browsers use around layout shifts.
let clickGuardInterval: TimeInterval = 0.5
