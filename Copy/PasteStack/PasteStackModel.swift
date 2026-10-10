import AppKit
import CopyCore
import Foundation
import Observation

/// Backs the Paste Stack palette (`PasteStackController`/`PasteStackView`): owns the
/// pure `PasteStackQueue` plus whether the palette is currently active, and resolves
/// queued uuids to `ClipItem`s/representations via the store.
@MainActor
@Observable
final class PasteStackModel {
    var queue = PasteStackQueue()

    /// Whether the palette should be on screen. This is the single source of truth for
    /// palette visibility: every code path that wants to show or hide the palette does
    /// it by setting this property, never by calling the controller directly.
    /// `AppCoordinator` wires `onActiveChange` to `PasteStackController.syncVisibility(to:)`,
    /// so the `didSet` below is the one place that decision fans out from.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            onActiveChange?(isActive)
        }
    }

    let store: ItemStore

    /// Mirrors `SettingsStore.hideSecrets`: row titles mask secrets.
    var hideSecrets = true

    /// Bumped after an in-place edit so `PasteStackView` re-renders (the queue's uuids
    /// don't change on an edit, so nothing else would trigger a refresh).
    var revision = 0

    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?

    init(store: ItemStore) {
        self.store = store
    }

    /// CRUD "create": adds the most recent captured item that isn't already queued.
    func addMostRecent() {
        guard let latest = (try? store.recentItems(limit: 30))?
            .first(where: { !queue.itemUUIDs.contains($0.uuid) }) else { return }
        queue.enqueue(latest.uuid)
    }

    /// CRUD "update": saves edited rich text from the `EditItemSheet` opened by the row's
    /// pencil, mirroring `ShelfViewModel.commitEdit`. Writes both a `public.rtf`
    /// representation and canonical plain text (RTF encoding happens here, the app layer;
    /// CopyCore stays Foundation-only and takes pre-encoded `Data`). Editing the shared
    /// `ClipItem` updates it everywhere (history too), the expected behavior for the same
    /// item; the `revision` bump re-renders the palette since the queue's uuids don't change.
    func commitEdit(_ attributed: NSAttributedString, for item: ClipItem) {
        guard let id = item.id else { return }
        let plainText = attributed.string
        guard let rtfData = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [:]
        ) else {
            NSLog("Copy: failed to RTF-encode edited paste-stack item")
            return
        }
        do {
            try store.replaceContent(itemID: id, rtfData: rtfData, plainText: plainText)
            revision += 1
        } catch {
            NSLog("Copy: failed to save edited paste-stack item: \(error)")
        }
    }

    /// Resolves queued uuids to `ClipItem`s, preserving queue order. This is a PURE
    /// read: a uuid that no longer resolves to a stored item (deleted or pruned since
    /// being queued) is simply omitted from the returned array, and `queue` itself is
    /// never mutated here. SwiftUI calls this from view bodies (`PasteStackView`
    /// resolves it once per body evaluation) — mutating observed state (`queue`) while
    /// a body is evaluating is undefined behavior, so stale-uuid cleanup happens only
    /// at explicit event points via `reconcile()`, never as a side effect of reading.
    func items() -> [ClipItem] {
        queue.itemUUIDs.compactMap { try? store.item(uuid: $0) }
    }

    /// Drops any queued uuid that no longer resolves to a stored item. Call this at
    /// explicit event points — never from `items()` — such as `PasteStackController`
    /// showing the palette, so the queue doesn't accumulate orphaned uuids forever.
    func reconcile() {
        for uuid in queue.itemUUIDs where (try? store.item(uuid: uuid)) == nil {
            queue.remove(uuid)
        }
    }

    /// Enqueues `item`, activating the palette if it wasn't already.
    func enqueue(_ item: ClipItem) {
        queue.enqueue(item.uuid)
        if !isActive { isActive = true }
    }

    /// Advances the queue and resolves representations for the next item, skipping
    /// (and retrying) any uuid whose item or representations have gone missing since
    /// being queued. Returns `nil` once the queue is exhausted. Unlike `items()`, this
    /// runs from an explicit event handler (the paste engine, in Task 7), not from a
    /// SwiftUI body — `queue.advance()`'s mutation is safe here.
    func advanceAndResolve() -> [CapturedRepresentation]? {
        while let uuid = queue.advance() {
            guard let id = (try? store.item(uuid: uuid))?.id,
                  let reps = try? store.representations(forItemID: id),
                  !reps.isEmpty else {
                continue
            }
            return reps
        }
        return nil
    }
}
