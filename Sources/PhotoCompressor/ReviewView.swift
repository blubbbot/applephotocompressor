import SwiftUI
import AVKit
import CompressionCore

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var playback = ReviewPlayback()
    @State private var showAll = false
    @State private var previewRevision = 0
    @AppStorage("reviewSidebarVisible") private var sidebarVisible = true
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.10, green: 0.43, blue: 0.34)

    private var records: [OperationRecord] { showAll ? model.filteredReviewRecords : model.filteredReviewRecords.filter(\.needsReview) }
    private var focused: OperationRecord? { records.first { $0.id == model.reviewFocusedID } }
    private var focusedIndex: Int? { records.firstIndex { $0.id == model.reviewFocusedID } }
    private var showsSidebar: Bool { sidebarVisible && !model.reviewPreviewExpanded }

    var body: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar.frame(width: 320)
                    Divider()
                }
                if let record = focused {
                    comparison(record).id(record.id)
                } else {
                    ContentUnavailableView {
                        Label(records.isEmpty && !model.reviewRecords.isEmpty ? "No matching copies" : model.awaitingReview.isEmpty ? "Ready when you are" : "Choose a copy to review", systemImage: "rectangle.split.2x1")
                    } description: {
                        Text("Compare the archived original and compressed file side by side, then accept or revert. Nothing opens automatically after compression.")
                    } actions: {
                        if model.reviewSharingFilter != .all {
                            Button("Show all libraries") { model.reviewSharingFilter = .all }
                        }
                        if model.mediaMode == .photos && model.reviewPhotoTypeFilter != .all {
                            Button("Show all photo types") { model.reviewPhotoTypeFilter = .all }
                        }
                        if !showAll && !model.filteredReviewRecords.isEmpty {
                            Button("Show reviewed copies") { showAll = true }
                        }
                        Button("Back to Library") { model.section = .library }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if model.reviewSharingFilter == .needsSharing { showAll = true }
            if let id = model.reviewFocusedID, model.reviewRecords.contains(where: { $0.id == id && !$0.needsReview }) { showAll = true }
            chooseValidFocus()
        }
        .onChange(of: records.map(\.id)) { _, _ in chooseValidFocus() }
        .onChange(of: model.reviewSharingFilter) { _, filter in
            if filter == .needsSharing { showAll = true }
        }
        .onChange(of: model.reviewFocusedID) { _, id in
            if let id, !records.contains(where: { $0.id == id }), model.reviewRecords.contains(where: { $0.id == id }) { showAll = true }
        }
        .task(id: "\(focused?.id.uuidString ?? "none")-\(previewRevision)") {
            model.refreshSharing(force: true)
            if let record = focused, !record.kind.isPhoto { await playback.load(record) }
            else { playback.stop() }
        }
        .onDisappear { playback.stop() }
        .onReceive(ticker) { _ in if focused?.kind.isPhoto != true { playback.synchronize() } }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 14) {
            Button {
                if model.reviewPreviewExpanded { model.reviewPreviewExpanded = false; sidebarVisible = true }
                else { sidebarVisible.toggle() }
            } label: {
                Label(showsSidebar ? "Hide list" : "Show list", systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(showsSidebar ? "Hide the video list" : "Show the video list")
            .labelStyle(.iconOnly)
            HStack(spacing: 10) {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(focusedIndex == nil || focusedIndex == 0)
                    .accessibilityLabel("Previous review video").help("Previous video")
                Text(focusedIndex.map { "\($0 + 1) of \(records.count)" } ?? "\(records.count) videos")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(focusedIndex == nil || focusedIndex == records.count - 1)
                    .accessibilityLabel("Next review video").help("Next video")
            }
            if !showsSidebar {
                Menu {
                    reviewFilter
                    sharingFilter
                    if model.mediaMode == .photos { photoTypeFilter }
                } label: { Text(model.reviewSharingFilter == .all ? (showAll ? "All copies" : "To review") : model.reviewSharingFilter.title) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Spacer(minLength: 12)
            if model.reviewPreviewExpanded, let record = focused {
                if record.isPhotosOperation { SharedLibraryToolbarHint(record: record).environmentObject(model) }
                DiskSpaceIndicator().environmentObject(model)
                reviewActions(record, compact: true)
            }
            Button {
                model.reviewPreviewExpanded.toggle()
            } label: {
                Label(model.reviewPreviewExpanded ? "Restore layout" : "Expand previews",
                      systemImage: model.reviewPreviewExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.disabled(focused == nil && !model.reviewPreviewExpanded)
                .labelStyle(.iconOnly)
                .help(model.reviewPreviewExpanded ? "Restore the list and review details" : "Use the window for the comparison; hide the list and longer details")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var reviewFilter: some View {
        Picker("Review list", selection: $showAll) {
            Text("To review (\(model.filteredReviewRecords.filter(\.needsReview).count))").tag(false)
            Text("All (\(model.filteredReviewRecords.count))").tag(true)
        }
    }

    private var sharingFilter: some View {
        Picker("Original library", selection: $model.reviewSharingFilter) {
            ForEach(ReviewSharingFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).controlSize(.small)
            .help("Uses the original's saved library status. Needs re-sharing includes shared originals whose current copy is Personal or Unknown, including accepted copies.")
    }

    private var photoTypeFilter: some View {
        Picker("Photo type", selection: $model.reviewPhotoTypeFilter) {
            ForEach(PhotoTypeFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).controlSize(.small)
            .help("Filter by the original photo type, including Live Photos converted to stills.")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Compressed \(model.mediaMode.rawValue.lowercased())").font(.headline)
                reviewFilter.pickerStyle(.segmented).labelsHidden()
                sharingFilter
                if model.mediaMode == .photos { photoTypeFilter }
                if model.reviewSharingFilter == .needsSharing {
                    Text("Shared originals whose Photos replacement is Personal or Unknown. Includes accepted copies.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(14)
            Divider()
            if records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(accent)
                    Text(model.reviewRecords.isEmpty ? "Compressed copies appear here after a batch." : model.filteredReviewRecords.isEmpty ? "No copies match this library filter." : "All matching copies reviewed.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.filteredReviewRecords.isEmpty && !showAll { Button("Show reviewed copies") { showAll = true } }
                    if model.reviewSharingFilter != .all { Button("Show all libraries") { model.reviewSharingFilter = .all } }
                    if model.mediaMode == .photos && model.reviewPhotoTypeFilter != .all {
                        Button("Show all photo types") { model.reviewPhotoTypeFilter = .all }
                    }
                    if !model.reviewRecords.isEmpty && (!model.sharing.enabled || model.sharing.library == nil) {
                        Button("Set up sharing detection…") { model.chooseSharingLibrary() }.disabled(model.isBusy)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.reviewFocusedID) {
                    ForEach(records) { record in
                        VideoSidebarRow(title: record.sourceName, detail: sizeSummary(record),
                                        status: reviewState(record), savings: savingsSummary(record), statusColor: record.error != nil || model.needsSharing(record) ? .orange : .secondary,
                                        sharing: record.isPhotosOperation && (model.sharing.enabled || record.sourceSharedLibrary != nil) ? model.sourceSharing(record) : nil,
                                        sharingPrefix: "Original: ") {
                            ReviewThumbnail(url: URL(fileURLWithPath: record.outputPath), isPhoto: record.kind.isPhoto)
                        }.tag(record.id)
                    }
                }.listStyle(.sidebar)
            }
        }.frame(maxHeight: .infinity).background(.bar)
    }

    private func navigate(_ offset: Int) {
        guard let index = focusedIndex, records.indices.contains(index + offset) else { return }
        model.reviewFocusedID = records[index + offset].id
    }

    private func sizeSummary(_ record: OperationRecord) -> String {
        guard let before = record.originalBytes, let after = record.outputBytes else { return "File sizes unavailable" }
        return "\(DisplayFormat.bytes(before)) → \(DisplayFormat.bytes(after))"
    }

    private func savingsSummary(_ record: OperationRecord) -> String? {
        guard let before = record.originalBytes, let after = record.outputBytes, before > after else { return nil }
        return "\(DisplayFormat.bytes(before - after)) smaller · \(Int((Double(before - after) / Double(before) * 100).rounded()))%"
    }

    private func comparison(_ record: OperationRecord) -> some View {
        GeometryReader { viewport in
            let padding: CGFloat = model.reviewPreviewExpanded ? 16 : 24
            let paneWidth = max(1, (viewport.size.width - padding * 2 - 16) / 2)
            let reserved: CGFloat = record.kind == .photo ? 150 : 220
            let previewHeight = model.reviewPreviewExpanded ? max(140, viewport.size.height - reserved) : paneWidth * 10 / 16
            ScrollView {
            VStack(alignment: .leading, spacing: model.reviewPreviewExpanded ? 12 : 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.sourceName).font(model.reviewPreviewExpanded ? .headline : .title2.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle).help(record.sourceName).textSelection(.enabled)
                        if !model.reviewPreviewExpanded {
                            Text("\(record.startedAt.formatted()) · \(reviewState(record))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.backupPath), URL(fileURLWithPath: record.outputPath)]) } label: {
                        Label("Archive in Finder", systemImage: "folder")
                    }
                }
                if record.isPhotosOperation && !model.reviewPreviewExpanded {
                    SharedLibraryNotice(replacementID: record.reviewPhotosID,
                                        compact: model.reviewPreviewExpanded, restoredOriginal: record.stage == .reverted, record: record).environmentObject(model)
                }
                if !model.reviewPreviewExpanded {
                    Text(record.kind.isPhoto ? "Both previews use the archived image resources. Live Photo motion controls appear below the images." : "Both previews use the local archived files. Play, seek, and step through the same moment together.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if record.kind.isPhoto {
                    PhotoComparison(record: record, height: previewHeight)
                } else {
                  HStack(alignment: .top, spacing: 16) {
                    previewPane(title: "Original", player: playback.original, facts: playback.originalFacts, bytes: record.originalBytes, error: playback.originalError, height: previewHeight)
                    previewPane(title: "Compressed", player: playback.compressed, facts: playback.compressedFacts, bytes: record.outputBytes, error: playback.compressedError, height: previewHeight)
                }
                comparisonControls
                }
                if !record.kind.isPhoto, let error = playback.playbackError {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                }
                if !record.kind.isPhoto, !playback.loading, playback.originalError != nil || playback.compressedError != nil || playback.playbackError != nil {
                    Button("Retry archived previews") { previewRevision += 1 }
                }
                if let error = record.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if !model.reviewPreviewExpanded { reviewDetails(record) }
            }.padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(width: viewport.size.width, height: viewport.size.height)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func reviewDetails(_ record: OperationRecord) -> some View {
        if let before = record.originalBytes, let after = record.outputBytes, before > 0 {
            Label("\(DisplayFormat.bytes(before - after)) smaller · \(Int((Double(before - after) / Double(before) * 100).rounded()))% file-size reduction", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.headline).foregroundStyle(accent)
        }
        if record.kind.isPhoto {
            Text("Lossy HEIC photo · quality \(Int((record.photoSettings?.quality ?? 0.8) * 100))% · \(record.photoSettings?.resolution.rawValue ?? "Original") resolution")
                .font(.headline)
            Text("The image was re-encoded, so detail can change even at original resolution. Supported library metadata is restored and checked. HDR/depth/RAW and edited photos are protected rather than flattened.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let facts = playback.originalFacts ?? record.sourceFacts {
            let video = LibraryVideo(id: record.sourceID, name: record.sourceName, asset: nil, fileURL: URL(fileURLWithPath: record.backupPath), facts: facts,
                                     date: record.startedAt, unsupportedReason: nil, factsAreMeasured: true)
            CompressionImpactView(video: video, settings: record.settings, reviewingFinishedCopy: true)
        }
        Divider()
        reviewActions(record)
        if record.isPhotosOperation {
            HStack {
                if record.stage != .originalDeleted && record.stage != .reverting || record.restoredOriginalID != nil {
                    Button("Show original in Photos") { model.showInPhotos(id: record.restoredOriginalID ?? record.sourceID) }
                }
                if let id = record.replacementID, record.stage != .reverted {
                    Button("Show compressed copy in Photos") { model.showInPhotos(id: id) }
                }
            }.controlSize(.small).disabled(!model.connected || model.isBusy)
        }
        Text("Both local archives are retained. Photos deletions require macOS confirmation; Recently Deleted is never emptied by this app.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func previewPane(title: String, player: AVPlayer?, facts: VideoFacts?, bytes: Int64?, error: String?, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text(bytes.map(DisplayFormat.bytes) ?? "Size unknown").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black)
                if let player { NativeVideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 12)) }
                else if playback.loading { ProgressView().tint(.white) }
                else { Text(error ?? "Preview unavailable").font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).padding(20) }
            }.frame(height: height)
            if let facts {
                Text("\(facts.width) × \(facts.height) · \(facts.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps\(facts.isHDR ? " · HDR" : "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
    }

    private var comparisonControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { playback.step(-1) } label: { Image(systemName: "backward.frame.fill") }.accessibilityLabel("Previous comparison frame")
                Button { playback.togglePlayback() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 20) }
                    .accessibilityLabel(playback.playing ? "Pause both previews" : "Play both previews")
                Button { playback.step(1) } label: { Image(systemName: "forward.frame.fill") }.accessibilityLabel("Next comparison frame")
                Text(DisplayFormat.duration(playback.elapsed)).monospacedDigit()
                Slider(value: $playback.elapsed, in: 0...max(playback.duration, 0.01), onEditingChanged: playback.editPosition)
                    .accessibilityLabel("Comparison position")
                Text(DisplayFormat.duration(playback.duration)).monospacedDigit()
            }.buttonStyle(.borderless).font(.callout)
            HStack {
                Label("Linked playback", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                if playback.loading || playback.preparingPlayback {
                    ProgressView().controlSize(.mini)
                    Text(playback.loading ? "Preparing previews…" : "Seeking…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Listen to", selection: $playback.audio) { ForEach(ReviewAudio.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(width: 230).controlSize(.small)
            }
        }.disabled(!playback.canCompare)
    }

    @ViewBuilder private func reviewActions(_ record: OperationRecord, compact: Bool = false) -> some View {
        if record.stage == .reverted {
            Label("Reverted · the original is kept", systemImage: "arrow.uturn.backward.circle").foregroundStyle(accent)
        } else {
            if record.isPhotosOperation && !model.connected {
                HStack {
                    if !compact {
                        Text("Connect Photos to accept or revert this copy. Archived previews are available without connecting.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Button("Connect Photos") { model.connect() }.disabled(model.isBusy || model.isLoading || model.indexingSizes)
                }
            }
            HStack(spacing: 14) {
                Button(record.stage == .reverting ? "Retry revert…" : compact ? "Revert…" : "Revert compression…", role: .destructive) {
                    playback.stop(); model.requestRevert(record)
                }
                if !compact { Spacer() }
                if record.reviewDecision == .accepted {
                    Label("Accepted", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                } else if record.stage != .reverting {
                    Button(compact ? (record.isDeletionCandidate ? "Accept & delete…" : "Accept") : acceptTitle(record)) { playback.stop(); model.acceptReview(record.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(record.isPhotosOperation && record.stage != .originalDeleted && !record.isDeletionCandidate)
                }
            }.controlSize(compact ? .small : .large).disabled(model.isBusy || record.isPhotosOperation && !model.connected)
            if !compact {
                Text(record.stage == .reverting ? "Finish the interrupted revert to keep the original and remove the compressed Photos copy." : record.isPhotosOperation ? record.stage == .originalDeleted ? "The original has already been replaced in Photos. Accept marks this copy as reviewed; revert restores the archived original before removing the compressed copy." : "Accept keeps the smaller Photos copy and deletes its original after macOS confirmation. Revert keeps the original and removes only the compressed Photos copy." : "Local originals stay in place. Accept or revert records your decision; both archived files are retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func acceptTitle(_ record: OperationRecord) -> String {
        record.isPhotosOperation && record.stage != .originalDeleted ? "Accept & delete original…" : "Accept compressed version"
    }

    private func reviewState(_ record: OperationRecord) -> String {
        if record.stage == .reverting { return "Revert needs attention" }
        if model.needsSharing(record) {
            return record.stage == .originalDeleted ? "Replaced · check re-sharing" : record.stage == .reverted ? "Reverted · check re-sharing" : "Copy ready · check re-sharing"
        }
        if record.stage == .reverted { return "Reverted · original kept" }
        if record.reviewDecision == .accepted { return "Accepted" }
        if record.stage == .originalDeleted { return "Replaced · awaiting review" }
        if record.isDeletionCandidate { return "Ready to review · original kept" }
        if record.isPhotosOperation { return "Import needs attention · original kept" }
        return "Ready to review · local file"
    }

    private func chooseValidFocus() {
        if !records.contains(where: { $0.id == model.reviewFocusedID }) { model.reviewFocusedID = records.first?.id }
    }
}
