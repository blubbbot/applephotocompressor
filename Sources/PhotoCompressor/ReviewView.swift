import SwiftUI
import AVKit
import CompressionCore

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var playback = ReviewPlayback()
    @State private var showAll = false
    @State private var previewRevision = 0
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.10, green: 0.43, blue: 0.34)

    private var records: [OperationRecord] { showAll ? model.reviewRecords : model.awaitingReview }
    private var focused: OperationRecord? { records.first { $0.id == model.reviewFocusedID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Review compressed videos").font(.title3.weight(.semibold))
                Picker("Review list", selection: $showAll) {
                    Text("To review (\(model.awaitingReview.count))").tag(false)
                    Text("All (\(model.reviewRecords.count))").tag(true)
                }.pickerStyle(.segmented)
                if records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(accent)
                        Text(model.reviewRecords.isEmpty ? "Compressed copies appear here after a batch." : "All copies reviewed.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if !model.reviewRecords.isEmpty { Button("Show reviewed copies") { showAll = true } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $model.reviewFocusedID) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.sourceName).font(.callout.weight(.medium)).lineLimit(2)
                                Text(reviewState(record)).font(.caption).foregroundStyle(record.error == nil ? Color.secondary : .orange)
                                if let before = record.originalBytes, let after = record.outputBytes {
                                    Text("\(DisplayFormat.bytes(before)) → \(DisplayFormat.bytes(after))").font(.caption.monospacedDigit()).foregroundStyle(accent)
                                }
                            }.padding(.vertical, 7).tag(record.id)
                        }
                    }.listStyle(.sidebar)
                }
            }.padding(18).frame(width: 290).frame(maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            Divider()
            if let record = focused {
                comparison(record).id(record.id)
            } else {
                ContentUnavailableView {
                    Label(model.awaitingReview.isEmpty ? "Ready when you are" : "Choose a copy to review", systemImage: "rectangle.split.2x1")
                } description: {
                    Text("Compare the archived original and compressed file side by side, then accept or revert. Nothing opens automatically after compression.")
                } actions: {
                    Button("Back to Library") { model.section = .library }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let id = model.reviewFocusedID, model.reviewRecords.contains(where: { $0.id == id && !$0.needsReview }) { showAll = true }
            chooseValidFocus()
        }
        .onChange(of: records.map(\.id)) { _, _ in chooseValidFocus() }
        .onChange(of: model.reviewFocusedID) { _, id in
            if let id, !records.contains(where: { $0.id == id }), model.reviewRecords.contains(where: { $0.id == id }) { showAll = true }
        }
        .task(id: "\(focused?.id.uuidString ?? "none")-\(previewRevision)") {
            if let record = focused { await playback.load(record) }
            else { playback.stop() }
        }
        .onDisappear { playback.stop() }
        .onReceive(ticker) { _ in playback.synchronize() }
    }

    private func comparison(_ record: OperationRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.sourceName).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text("\(record.startedAt.formatted()) · \(reviewState(record))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.backupPath), URL(fileURLWithPath: record.outputPath)]) } label: {
                        Label("Archive in Finder", systemImage: "folder")
                    }
                }
                Text("Both previews use the local archived files. Play, seek, and step through the same moment together.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 16) {
                    previewPane(title: "Original", player: playback.original, facts: playback.originalFacts, bytes: record.originalBytes, error: playback.originalError)
                    previewPane(title: "Compressed", player: playback.compressed, facts: playback.compressedFacts, bytes: record.outputBytes, error: playback.compressedError)
                }
                comparisonControls
                if !playback.loading, playback.originalError != nil || playback.compressedError != nil {
                    Button("Retry archived previews") { previewRevision += 1 }
                }
                if let before = record.originalBytes, let after = record.outputBytes, before > 0 {
                    Label("\(DisplayFormat.bytes(before - after)) smaller · \(Int((Double(before - after) / Double(before) * 100).rounded()))% file-size reduction", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.headline).foregroundStyle(accent)
                }
                if let facts = playback.originalFacts ?? record.sourceFacts {
                    let video = LibraryVideo(id: record.sourceID, name: record.sourceName, asset: nil, fileURL: URL(fileURLWithPath: record.backupPath), facts: facts,
                                             date: record.startedAt, unsupportedReason: nil, factsAreMeasured: true)
                    CompressionImpactView(video: video, settings: record.settings, reviewingFinishedCopy: true)
                }
                if let error = record.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
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
            }.padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewPane(title: String, player: AVPlayer?, facts: VideoFacts?, bytes: Int64?, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline); Spacer(); Text(bytes.map(DisplayFormat.bytes) ?? "Size unknown").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black)
                if let player { NativeVideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 12)) }
                else if playback.loading { ProgressView().tint(.white) }
                else { Text(error ?? "Preview unavailable").font(.caption).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).padding(20) }
            }.aspectRatio(16 / 10, contentMode: .fit)
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
                Spacer()
                Picker("Listen to", selection: $playback.audio) { ForEach(ReviewAudio.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(width: 230).controlSize(.small)
            }
        }.disabled(!playback.canCompare)
    }

    @ViewBuilder private func reviewActions(_ record: OperationRecord) -> some View {
        if record.stage == .reverted {
            Label("Reverted · the original is kept", systemImage: "arrow.uturn.backward.circle").foregroundStyle(accent)
        } else {
            if record.isPhotosOperation && !model.connected {
                HStack {
                    Text("Connect Photos to accept or revert this copy. Archived previews are available without connecting.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Connect Photos") { model.connect() }.disabled(model.isBusy || model.isLoading || model.indexingSizes)
                }
            }
            HStack(spacing: 14) {
                Button(record.stage == .reverting ? "Retry revert…" : "Revert compression…", role: .destructive) {
                    playback.stop(); model.requestRevert(record)
                }
                Spacer()
                if record.reviewDecision == .accepted {
                    Label("Accepted", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                } else if record.stage != .reverting {
                    Button(acceptTitle(record)) { playback.stop(); model.acceptReview(record.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(record.isPhotosOperation && record.stage != .originalDeleted && !record.isDeletionCandidate)
                }
            }.controlSize(.large).disabled(model.isBusy || record.isPhotosOperation && !model.connected)
            Text(record.stage == .reverting ? "Finish the interrupted revert to keep the original and remove the compressed Photos copy." : record.isPhotosOperation ? record.stage == .originalDeleted ? "The original has already been replaced in Photos. Accept marks this copy as reviewed; revert restores the archived original before removing the compressed copy." : "Accept keeps the smaller Photos copy and deletes its original after macOS confirmation. Revert keeps the original and removes only the compressed Photos copy." : "Local originals stay in place. Accept or revert records your decision; both archived files are retained.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func acceptTitle(_ record: OperationRecord) -> String {
        record.isPhotosOperation && record.stage != .originalDeleted ? "Accept & delete original…" : "Accept compressed version"
    }

    private func reviewState(_ record: OperationRecord) -> String {
        if record.stage == .reverting { return "Revert needs attention" }
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
