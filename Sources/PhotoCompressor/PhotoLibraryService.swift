import AppKit
import Photos
import UniformTypeIdentifiers
import CompressionCore

extension PhotosService {
    static func photoProtectionReason(_ asset: PHAsset, resources: [PHAssetResource]? = nil) -> String? {
        let resources = resources ?? PHAssetResource.assetResources(for: asset)
        if asset.sourceType.contains(.typeCloudShared) { return "Shared Album photos cannot be replaced with their sharing history." }
        if asset.mediaSubtypes.contains(.spatialMedia) { return "Spatial photos are protected." }
        if asset.mediaSubtypes.contains(.photoHDR) || asset.mediaSubtypes.contains(.photoDepthEffect) { return "HDR/Portrait photos are protected to retain gain maps and depth data." }
        if asset.burstIdentifier != nil { return "Burst photos are protected to retain their grouping." }
        if resources.contains(where: { $0.type == .adjustmentData || $0.type == .alternatePhoto }) { return "Edited photos and RAW+JPEG pairs are protected." }
        guard let photo = resources.first(where: { $0.type == .photo }),
              [UTType.jpeg.identifier, UTType.heic.identifier].contains(photo.uniformTypeIdentifier) else {
            return "This version supports ordinary JPEG/HEIC photos. RAW, PNG, animated, and other formats are protected."
        }
        if asset.mediaSubtypes.contains(.photoLive), resources.filter({ $0.type == .pairedVideo }).count != 1 { return "The Live Photo's original motion resource is unavailable." }
        return nil
    }

    static func archiveMotion(_ asset: PHAsset, to destination: URL) async throws {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo }) else { throw MediaError.invalid("The Live Photo's motion resource is missing.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    static func livePhoto(photo: URL, motion: URL) async throws -> PHLivePhoto {
        let request = PhotoPreviewRequest<PHLivePhoto>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard request.attach(continuation) else { return }
                let id = PHLivePhoto.request(withResourceFileURLs: [photo, motion], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { livePhoto, info in
                    if (info[PHLivePhotoInfoCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())); return }
                    if let error = info[PHLivePhotoInfoErrorKey] as? Error { request.finish(.failure(error)); return }
                    if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                    if let livePhoto { request.finish(.success(livePhoto)) }
                    else { request.finish(.failure(info[PHLivePhotoInfoErrorKey] as? Error ?? MediaError.invalid("Live Photo pairing validation failed. The original and its motion are retained."))) }
                }
                request.setCancellation { PHLivePhoto.cancelRequest(withRequestID: id) }
            }
        }, onCancel: { request.cancel() })
    }

    static func livePhotoPreview(_ asset: PHAsset, progress: @escaping @Sendable (Double) -> Void) async throws -> PHLivePhoto {
        let request = PhotoPreviewRequest<PHLivePhoto>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard request.attach(continuation) else { return }
                let options = PHLivePhotoRequestOptions()
                options.version = .current; options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
                options.progressHandler = { value, _, _, _ in progress(value) }
                let id = PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 2000, height: 2000), contentMode: .aspectFit, options: options) { livePhoto, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())); return }
                    if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)); return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if let livePhoto { request.finish(.success(livePhoto)) }
                    else { request.finish(.failure(info?[PHImageErrorKey] as? Error ?? MediaError.invalid("Photos could not load motion for this Live Photo. Retry or open it in Photos."))) }
                }
                request.setCancellation { PHImageManager.default().cancelImageRequest(id) }
            }
        }, onCancel: { request.cancel() })
    }

    static func photoPreview(_ asset: PHAsset) async throws -> NSImage {
        let request = PhotoPreviewRequest<NSImage>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard request.attach(continuation) else { return }
                let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                let id = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2000, height: 2000), contentMode: .aspectFit, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())); return }
                    if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)); return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if let image { request.finish(.success(image)) }
                    else { request.finish(.failure(info?[PHImageErrorKey] as? Error ?? MediaError.invalid("Photos could not load this photo preview."))) }
                }
                request.setCancellation { PHImageManager.default().cancelImageRequest(id) }
            }
        }, onCancel: { request.cancel() })
    }
}
