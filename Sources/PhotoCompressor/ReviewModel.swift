import SwiftUI
import Photos
import CompressionCore

enum AppSection: String, CaseIterable {
    case library = "Library", review = "Review"
}

struct ReviewPrompt: Identifiable {
    let id: UUID
    let name: String
    let restoresOriginal: Bool
    let isPhotosOperation: Bool

    var message: String {
        if !isPhotosOperation {
            return "Keep the original of \(name) and mark this compression as reverted. Both archived files remain on disk."
        }
        let restoration = restoresOriginal ? "The full original will first be restored from its local archive, including supported Photos metadata. " : "The original stays in Photos. "
        return "\(restoration)The compressed Photos copy of \(name), including any later changes to that copy, will be removed after macOS asks you to confirm. Both local archives remain on disk."
    }
}

extension AppModel {
    func openReview(_ record: OperationRecord? = nil) {
        if let record {
            if !reviewSharingMatches(record, filter: reviewSharingFilter) { reviewSharingFilter = .all }
            reviewFocusedID = record.id
        }
        else if reviewFocusedID == nil { reviewFocusedID = awaitingReview.first?.id ?? reviewRecords.first?.id }
        section = .review
        showHistory = false
    }

    func requestRevert(_ record: OperationRecord) {
        guard !isBusy, record.hasReviewableCopy, record.stage != .reverted, !record.isPhotosOperation || connected else { return }
        reviewPrompt = ReviewPrompt(id: record.id, name: record.sourceName,
                                   restoresOriginal: record.stage == .originalDeleted || record.stage == .reverting,
                                   isPhotosOperation: record.isPhotosOperation)
    }

    func acceptReview(_ id: UUID) {
        guard !isBusy, let journal, let record = history.first(where: { $0.id == id }),
              record.needsReview, record.stage != .reverting,
              !record.isPhotosOperation || record.stage == .originalDeleted || record.isDeletionCandidate,
              !record.isPhotosOperation || connected else { return }
        isReviewing = true; isBusy = true
        activity = "Accepting \(record.sourceName)…"
        Task {
            defer { isBusy = false; isReviewing = false; refreshArchiveSpace() }
            do {
                let originalAlreadyRemoved = record.isPhotosOperation && PhotosService.fetch(record.sourceID) == nil
                if record.isPhotosOperation && record.stage != .originalDeleted && !originalAlreadyRemoved {
                    guard record.isDeletionCandidate else { throw MediaError.invalid("This copy has not passed every import and metadata check. Its original is retained. Revert the copy or inspect its History entry.") }
                    await deleteReady([record], markReviewed: true)
                } else {
                    try verifyReviewFiles(record)
                    if record.isPhotosOperation {
                        guard let replacementID = record.replacementID, PhotosService.fetch(replacementID) != nil else {
                            throw MediaError.invalid("The compressed Photos copy is missing. The archive is retained; reconnect the library and check this item before accepting it.")
                        }
                    }
                    var accepted = record; accepted.reviewDecision = .accepted; accepted.error = nil
                    if record.isPhotosOperation { accepted.stage = .originalDeleted }
                    try await journal.save(accepted)
                }
                await reloadHistory()
            } catch { notice = AppNotice(text: error.localizedDescription) }
            activity = "Review updated"
        }
    }

    func confirmRevert(_ prompt: ReviewPrompt) {
        reviewPrompt = nil
        guard !isBusy, let journal, let record = history.first(where: { $0.id == prompt.id }),
              record.hasReviewableCopy, record.stage != .reverted, !record.isPhotosOperation || connected else { return }
        isReviewing = true; isBusy = true
        activity = "Reverting \(record.sourceName)…"
        Task {
            defer { isBusy = false; isReviewing = false; refreshArchiveSpace() }
            var reverting = record
            do {
                try verifyReviewFiles(reverting)
                if reverting.isPhotosOperation {
                    reverting.stage = .reverting; reverting.reviewDecision = nil; reverting.error = nil
                    try await journal.save(reverting)
                    try await restoreAndRemoveCopy(&reverting)
                }
                reverting.stage = .reverted; reverting.reviewDecision = .reverted; reverting.error = nil
                try await journal.save(reverting)
                statuses[reverting.sourceID] = RowStatus(text: "Reverted · original kept")
                if let id = reverting.replacementID { videos.removeAll { $0.id == id }; selected.remove(id) }
                if let id = reverting.restoredOriginalID, let asset = PhotosService.fetch(id), !videos.contains(where: { $0.id == id }) {
                    videos.append(LibraryVideo(id: id, name: reverting.sourceName, asset: asset, fileURL: nil,
                                               facts: reverting.sourceFacts ?? VideoFacts(width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration, bytes: reverting.originalBytes),
                                               date: asset.creationDate ?? record.startedAt, unsupportedReason: PhotosService.protectionReason(for: asset),
                                               factsAreMeasured: reverting.sourceFacts != nil, kind: reverting.kind))
                }
                if focusedID == reverting.sourceID { player?.pause(); player = nil; focusedID = nil }
                activity = "Reverted · original kept; local archives retained"
            } catch {
                // A cancelled removal before any restoration can return to its
                // previous state, so the user can still choose Accept instead.
                if reverting.restoredOriginalID == nil {
                    reverting.stage = record.stage; reverting.reviewDecision = record.reviewDecision
                }
                let message = "Revert did not finish: \(error.localizedDescription)"
                reverting.error = message
                try? await journal.save(reverting)
                notice = AppNotice(text: "\(message) The app has not removed any archived files. If an original was restored, it stays in Photos. Retry from Review to finish without importing another original.")
                activity = "Revert paused · check Review"
            }
            await reloadHistory()
        }
    }

    private func verifyReviewFiles(_ record: OperationRecord) throws {
        guard record.completePhotoResources else { throw MediaError.invalid("The photo archive manifest is incomplete. No Photos item was removed.") }
        for (path, bytes) in record.archiveFiles {
            guard !path.isEmpty, let bytes, bytes > 0,
                  let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == bytes else {
                throw MediaError.invalid("An archived file is missing or changed. Reconnect its archive disk before continuing; no video has been deleted.")
            }
        }
    }

    private func restoreAndRemoveCopy(_ record: inout OperationRecord) async throws {
        guard let journal, let replacementID = record.replacementID, replacementID != record.sourceID,
              record.restoredOriginalID != replacementID else { throw MediaError.invalid("This operation has no distinct compressed Photos copy to revert.") }
        if let expected = record.replacementModifiedAt, let copy = PhotosService.fetch(replacementID), copy.modificationDate != expected {
            record.replacementModifiedAt = try await PhotosService.revalidateChangedReplacement(record, original: PhotosService.fetch(record.restoredOriginalID ?? record.sourceID))
            try await journal.save(record)
        }
        let replacement = PhotosService.fetch(replacementID)
        if let replacement {
            let resources = PHAssetResource.assetResources(for: replacement)
            guard resources.contains(where: { $0.type == (record.kind.isPhoto ? .photo : .video) && $0.originalFilename == URL(fileURLWithPath: record.outputPath).lastPathComponent }),
                  record.replacementModifiedAt == nil || replacement.modificationDate == record.replacementModifiedAt else {
                throw MediaError.invalid("The compressed Photos copy has changed since it was imported. Review its changes in Photos before deleting it manually; the app has kept both versions.")
            }
        }
        var original = PhotosService.fetch(record.restoredOriginalID ?? record.sourceID)
        if original == nil, !record.metadataVerified {
            throw MediaError.invalid("The original is no longer in Photos and this copy's library metadata was never verified. Restore the archived original manually; the app has kept the compressed copy.")
        }
        if original == nil, record.restoredOriginalID == nil {
            // Recover a Photos import that succeeded before its ID was journaled.
            if let recovered = try await PhotosService.restoredVideo(named: record.restorationFilename, photos: record.kind.isPhoto) {
                original = recovered; record.restoredOriginalID = recovered.localIdentifier
                try await journal.save(record)
            }
        }
        if original == nil {
            guard record.restoredOriginalID == nil, let replacement else {
                throw MediaError.invalid("The original or its restored copy is missing, and it cannot safely be recovered from the current Photos metadata.")
            }
            activity = "Restoring full original from its archive…"
            let albums = PhotosService.regularAlbums(containing: replacement)
            let id = try await PhotosService.importVideo(URL(fileURLWithPath: record.backupPath), original: replacement,
                                                       albums: albums, resourceFilename: record.restorationFilename,
                                                       pairedVideo: record.kind == .livePhoto ? record.pairedVideoPath.map { URL(fileURLWithPath: $0) } : nil)
            record.restoredOriginalID = id
            try await journal.save(record)
            original = PhotosService.fetch(id)
        }
        guard let original, original.localIdentifier != replacementID else { throw MediaError.invalid("The original could not be verified. The compressed copy is retained.") }
        if record.restoredOriginalID != nil {
            guard let replacement else {
                guard record.restoredOriginalVerified == true else { throw MediaError.invalid("The compressed copy is missing and restored metadata has not yet been verified. Check the restored original in Photos.") }
                return
            }
            let albums = PhotosService.regularAlbums(containing: replacement)
            try PhotosService.verifyImport(original.localIdentifier, original: replacement, albums: albums,
                                           expectedLive: record.kind.isPhoto ? record.kind == .livePhoto : nil)
            if record.restoredOriginalVerified != true {
                let metadata: LibraryTextMetadata
                if let saved = record.sourceTextMetadata { metadata = saved }
                else { metadata = try await PhotosScript.readMetadata(id: replacementID) }
                try await PhotosScript.restoreMetadata(metadata, id: original.localIdentifier)
                record.restoredOriginalVerified = true
                try await journal.save(record)
            }
            let expectedWidth = record.sourceFacts?.width
            let expectedHeight = record.sourceFacts?.height
            guard expectedWidth == nil || (original.pixelWidth == expectedWidth && original.pixelHeight == expectedHeight) else {
                throw MediaError.invalid("The restored video does not have the original dimensions. The compressed copy is retained.")
            }
        }
        guard let replacement else { return } // A previous deletion may have completed before the last journal save.
        guard let current = PhotosService.fetch(replacementID), current.modificationDate == replacement.modificationDate,
              PhotosService.fetch(original.localIdentifier) != nil else {
            throw MediaError.invalid("A Photos video changed during restoration. No compressed copy was deleted; review and retry.")
        }
        activity = "Confirm compressed-copy deletion in the macOS Photos dialog…"
        try await PhotosService.delete([current])
    }
}
