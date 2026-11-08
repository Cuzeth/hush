// TEMPORARY CONTRACT STUBS — delete at merge
//
// Placeholder implementations of the view-model contract the UI branch codes
// against. The real implementations live in PlayerViewModel.swift on the
// state branch; this file only exists so the views branch compiles alone.

import Foundation

extension PlayerViewModel {
    func handleUserAssetRelinked(assetID: String) {}

    func handleUserAssetDeleted(assetID: String) {}

    func handlePresetRenamed(id: UUID, newName: String) {}

    var isCurrentPresetModified: Bool { false }
}
