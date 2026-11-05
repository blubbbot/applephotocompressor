import SwiftUI
import AVKit
import CompressionCore

private let accent = Color(red: 0.10, green: 0.43, blue: 0.34)
private let surface = Color(nsColor: .controlBackgroundColor)

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.section == .review {
                ReviewView().environmentObject(model)
            } else if model.videos.isEmpty && !model.isLoading {
                if model.connected { emptyLibrary } else { welcome }
            }
            else {
                HStack(spacing: 0) {
                    library.frame(width: 320).frame(maxHeight: .infinity)
                    Divider()
                    detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    settings.frame(width: 300).frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.section != .review || !model.reviewPreviewExpanded || model.isBusy {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $model.showHistory) { HistoryView().environmentObject(model) }
        .alert(item: $model.notice) { notice in Alert(title: Text("Photo Compressor"), message: Text(notice.text), dismissButton: .default(Text("OK"))) }
        .confirmationDialog("Download original for inspection?", isPresented: Binding(get: { model.inspectionPrompt != nil }, set: { if !$0 { model.inspectionPrompt = nil } }), titleVisibility: .visible, presenting: model.inspectionPrompt) { prompt in
            Button("Download and inspect") { model.confirmInspection(prompt) }
            Button("Cancel", role: .cancel) { model.inspectionPrompt = nil }
        } message: { prompt in Text(prompt.message) }
        .confirmationDialog("Revert compression?", isPresented: Binding(get: { model.reviewPrompt != nil }, set: { if !$0 { model.reviewPrompt = nil } }), titleVisibility: .visible, presenting: model.reviewPrompt) { prompt in
            Button(prompt.isPhotosOperation ? "Keep original & remove compressed Photos copy" : "Revert compression", role: .destructive) { model.confirmRevert(prompt) }
            Button("Cancel", role: .cancel) { model.reviewPrompt = nil }
        } message: { prompt in Text(prompt.message) }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            model.refreshArchiveSpace()
            if !model.isBusy { model.refreshSharing() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = AppIcon.image {
                Image(nsImage: icon).resizable().frame(width: 36, height: 36)
            } else {
                Image(systemName: "rectangle.stack.badge.minus").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo Compressor").font(.system(size: 17, weight: .semibold))
                Text(model.demo ? "Sample library · example estimates" : model.connected ? "Apple Photos · compression stays on your Mac" : "Smaller videos. More room in iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Media", selection: Binding(get: { model.mediaMode }, set: { model.switchMediaMode($0) })) {
                ForEach(MediaMode.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 105)
                .disabled(model.isBusy)
            Picker("Workspace", selection: $model.section) {
                Text("Library").tag(AppSection.library)
                Text(model.awaitingReview.isEmpty ? "Review" : "Review (\(model.awaitingReview.count))").tag(AppSection.review)
            }.pickerStyle(.segmented).frame(width: 220)
            if model.indexingSizes { ProgressView().controlSize(.small); Text("Reading file sizes…").font(.caption).foregroundStyle(.secondary) }
            Button { model.showHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Menu {
                Button("Connect Photos Library…") { model.connect() }
                Button(model.mediaMode == .photos ? "Open Photo Files…" : "Open Video Files…") { model.openFiles() }
                Button("Explore Sample Library") { model.loadDemo() }
            } label: { Label(model.connected ? "Refresh library" : "Open library", systemImage: model.connected ? "arrow.clockwise" : "photo.on.rectangle") }
            .fixedSize()
            .disabled(model.isBusy || model.isLoading || model.indexingSizes)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "photo.stack").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(accent)
            Text(model.mediaMode == .photos ? "Smaller photos. Keep the moment." : "Keep the moments. Make some room.").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(model.mediaMode == .photos ? "Compress ordinary JPEG/HEIC photos and supported Live Photos.\nKeep motion by default, or explicitly convert to stills. Originals are archived." : "Find large videos, preview the difference, and replace them with smaller copies.\nYou choose the quality. Originals are archived before deletion.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 12) {
                Button("Connect Photos Library") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button(model.mediaMode == .photos ? "Open Photo Files…" : "Open Video Files…") { model.openFiles() }.controlSize(.large)
            }
            Button("Explore a sample library") { model.loadDemo() }.buttonStyle(.link).padding(.top, 4)
            HStack(spacing: 32) {
                Label("Local processing", systemImage: "lock.shield")
                Label("Capture dates & albums", systemImage: "calendar")
                Label("Recoverable local archive", systemImage: "externaldrive")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 24)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No \(model.mediaMode.rawValue.lowercased()) in this Photos library", systemImage: model.mediaMode == .photos ? "photo.stack" : "film.stack")
        } description: {
            Text("Your Photos library is connected. Import a \(model.mediaMode == .photos ? "photo" : "video") in Photos, then refresh to begin.")
        } actions: {
            Button("Refresh library") { model.connect() }
                .disabled(model.isBusy || model.isLoading || model.indexingSizes)
            Button("Open Video Files…") { model.openFiles() }.disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your \(model.mediaMode.rawValue.lowercased())").font(.title3.weight(.semibold))
                    Text("\(model.visible.count)").font(.caption.monospacedDigit()).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $model.sort) { ForEach(VideoSort.allCases.filter { model.mediaMode == .videos || $0 != .longest }) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Picker("Minimum original size", selection: $model.minimumSize) {
                            Text("Any size").tag(Int64(0))
                            if model.mediaMode == .photos {
                                Text("Over 2 MB").tag(Int64(2_000_000)); Text("Over 5 MB").tag(Int64(5_000_000)); Text("Over 10 MB").tag(Int64(10_000_000))
                            } else {
                                Text("Over 100 MB").tag(Int64(100_000_000)); Text("Over 500 MB").tag(Int64(500_000_000)); Text("Over 1 GB").tag(Int64(1_000_000_000))
                            }
                        }
                        Toggle("Hide unsupported videos", isOn: $model.hideUnsupported)
                        Toggle("Hide processed videos", isOn: $model.hideProcessed)
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .menuStyle(.borderlessButton).frame(width: 25)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(model.mediaMode.rawValue.lowercased())", text: $model.search).textFieldStyle(.plain)
                }.padding(9).background(surface, in: RoundedRectangle(cornerRadius: 8))
                if model.mediaMode == .photos {
                    Picker("Photo type", selection: $model.photoTypeFilter) {
                        ForEach(PhotoTypeFilter.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).controlSize(.small)
                        .help("Uses Photos' Live Photo and panorama metadata; no original download is needed.")
                }
                if model.connected {
                    Picker("Library", selection: $model.librarySharingFilter) {
                        ForEach(LibrarySharingFilter.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).controlSize(.small)
                        .help("Filter by current advisory Shared / Personal / Unknown database labels.")
                    if model.librarySharingFilter != .all && (!model.sharing.enabled || model.sharing.library == nil) {
                        Button("Set up sharing detection…") { model.chooseSharingLibrary() }
                            .buttonStyle(.link).font(.caption).disabled(model.isBusy)
                    }
                }
                if model.slowMotionCount > 0 {
                    Button {
                        model.hideUnsupported.toggle()
                    } label: {
                        Label("\(model.slowMotionCount) Slo-mo protected · \(model.hideUnsupported ? "Show" : "Hide")", systemImage: "lock.fill")
                    }.buttonStyle(.link).font(.caption)
                }
                HStack {
                    Button("Select recommended") { model.selectRecommended() }.buttonStyle(.link)
                    Spacer()
                    Menu("Select") {
                        Button("All visible") { model.selected.formUnion(model.visible.filter { $0.unsupportedReason == nil }.map(\.id)) }
                        Button("None") { model.selected.removeAll() }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption).disabled(model.isBusy || model.isUpdatingList)
                HStack {
                    Text(model.listOrderPending ? "Updated estimates · sorting delayed" : "Sort updates after browsing pauses")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.updateListOrderNow() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Apply updated order now")
                        .disabled(!model.listOrderPending)
                }.frame(height: 16)
            }.padding(14)
            Divider()
            if model.isLoading || (model.isUpdatingList && model.visible.isEmpty) {
                VStack(spacing: 12) { ProgressView(); Text(model.activity).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "film").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("No matching \(model.mediaMode.rawValue.lowercased())").font(.title2.weight(.semibold))
                    Text("Change the filters or show processed videos.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !model.search.isEmpty || model.minimumSize > 0 {
                        Button("Clear search and size filters") { model.clearSearchAndSizeFilters() }
                    }
                    if model.librarySharingFilter != .all {
                        Button("Show all libraries") { model.librarySharingFilter = .all }
                    }
                    if model.mediaMode == .photos && model.photoTypeFilter != .all {
                        Button("Show all photo types") { model.photoTypeFilter = .all }
                    }
                    if model.hideProcessed, !model.processedIDs.isEmpty {
                        Button("Show processed videos") { model.hideProcessed = false }
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding<String?>(get: { model.focusedID }, set: { id in
                    if let video = model.videos.first(where: { $0.id == id }) { model.focus(video) }
                })) {
                    ForEach(model.visible) { video in
                        VideoRow(video: video).environmentObject(model).tag(video.id)
                    }
                }.listStyle(.sidebar)
            }
        }.background(.bar)
    }

    private var detail: some View {
        ScrollView {
            if let video = model.focused, video.kind.isPhoto {
                PhotoDetailView(photo: video).environmentObject(model)
            } else if let video = model.focused {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Preview").font(.headline)
                        Spacer()
                        if let id = model.photosID(for: video, compressed: model.previewCompressed) {
                            Button { model.showInPhotos(id: id) } label: { Label("Show in Photos", systemImage: "photo.on.rectangle") }
                                .buttonStyle(.borderless).help("Reveal this video in the Photos app")
                        }
                        if model.output(for: video.id) != nil {
                            Picker("Version", selection: Binding(get: { model.previewCompressed }, set: { model.switchPreview(compressed: $0) })) { Text("Original").tag(false); Text("Compressed").tag(true) }
                                .pickerStyle(.segmented).frame(width: 210)
                                .help("Switch versions at the same playback position")
                        }
                    }
                    VideoInspectionView(video: video).environmentObject(model)
                    if video.unsupportedReason == nil {
                        Label(compressionImpact(video).summary, systemImage: "slider.horizontal.3")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.black)
                        if let player = model.player { NativeVideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 14)) }
                        else if model.previewLoading { VStack(spacing: 12) { ProgressView().tint(.white); Text("Loading from Photos…").font(.caption).foregroundStyle(.white.opacity(0.8)) } }
                        else if video.isDemo {
                            SampleArtwork(seed: abs(video.id.hashValue % 6)).clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack { Spacer(); Label("Sample artwork · connect your library for playback", systemImage: "play.rectangle").font(.caption).padding(10).background(.ultraThinMaterial, in: Capsule()).padding(18) }
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "play.slash").font(.largeTitle)
                                Text(model.previewError ?? "Select a video to load its preview.").font(.caption).multilineTextAlignment(.center)
                                Button("Retry preview") { model.loadPreview() }
                            }.foregroundStyle(.white.opacity(0.8)).padding(24)
                        }
                    }.aspectRatio(16 / 10, contentMode: .fit)
                    if let player = model.player { PlaybackControls(player: player).id(ObjectIdentifier(player)) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(video.name).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Text(video.date.formatted(date: .abbreviated, time: .omitted))
                            Text("·"); Text(DisplayFormat.duration(video.facts.duration))
                            Text("·"); Text("\(video.facts.width) × \(video.facts.height)")
                            if video.hasInspectedFacts {
                                Text("·"); Text("\(video.facts.frameRate.formatted(.number.precision(.fractionLength(0...2)))) fps")
                            }
                            if video.facts.isHDR { Text("HDR").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4)) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    if video.unsupportedReason == nil {
                        estimateCard(video)
                        compressionImpact(video)
                        VStack(alignment: .leading, spacing: 9) {
                            Label("Dates, location, favorites, regular albums, titles & captions", systemImage: "checkmark.shield").foregroundStyle(accent)
                            Text("Library fields are restored and checked before an original can be deleted. People tags and editable history do not transfer.").foregroundStyle(.secondary)
                        }.font(.caption).lineSpacing(3)
                    }
                    if let status = model.statuses[video.id] {
                        Label(status.text, systemImage: status.failed ? "exclamationmark.circle" : "checkmark.circle").font(.callout).foregroundStyle(status.failed ? .orange : accent)
                    }
                    if model.pending.contains(where: { $0.sourceID == video.id }) {
                        Button { model.openReview(model.outputRecord(for: video.id)) } label: {
                            Label("Review this compressed copy", systemImage: "rectangle.split.2x1").frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.bordered).disabled(model.isBusy || !model.connected)
                        Text("Compare both versions side by side, then accept or revert in the Review tab.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.toggle(video) } label: {
                        Label(video.unsupportedReason != nil ? "Protected from compression" : model.selected.contains(video.id) ? "Selected for compression" : "Select for compression", systemImage: video.unsupportedReason != nil ? "lock.fill" : model.selected.contains(video.id) ? "checkmark.circle.fill" : "plus.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered).disabled(model.isBusy || video.unsupportedReason != nil)
                }.padding(24)
                    .contextMenu { VideoContextMenu(video: video).environmentObject(model) }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(accent)
                    Text("Take a closer look").font(.title2.weight(.medium))
                    Text("Select a video to preview it and see its estimated savings.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(40).frame(maxWidth: .infinity, minHeight: 480)
            }
        }.background(surface.opacity(0.6))
    }

    private func reviewedVideo(_ video: LibraryVideo) -> LibraryVideo {
        guard let facts = model.outputRecord(for: video.id)?.sourceFacts else { return video }
        var reviewed = video
        reviewed.facts = facts; reviewed.factsAreMeasured = true
        return reviewed
    }

    private func compressionImpact(_ video: LibraryVideo) -> CompressionImpactView {
        let record = model.outputRecord(for: video.id)
        return CompressionImpactView(video: reviewedVideo(video), settings: record?.settings ?? model.settings,
            reviewingFinishedCopy: record != nil)
    }

    private func estimateCard(_ video: LibraryVideo) -> some View {
        let record = model.outputRecord(for: video.id)
        let reviewed = reviewedVideo(video)
        let plan = CompressionPlan(facts: reviewed.facts, settings: record?.settings ?? model.settings)
        let originalBytes = record?.originalBytes ?? video.facts.bytes
        let actualBytes = record?.outputBytes
        let copyBytes = actualBytes ?? plan.estimatedBytes
        return VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) { Text("ORIGINAL").font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Text(originalBytes.map(DisplayFormat.bytes) ?? "Size pending").font(.system(size: 23, weight: .medium, design: .rounded)) }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 22)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) { Text(actualBytes == nil ? "ESTIMATED COPY" : "FINISHED COPY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Text((actualBytes == nil ? "~" : "") + DisplayFormat.bytes(copyBytes)).font(.system(size: 23, weight: .medium, design: .rounded)).foregroundStyle(accent) }
            }
            Divider()
            HStack {
                Text("\(plan.width) × \(plan.height) · up to \(plan.frameRate, specifier: "%.0f") fps · HEVC").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let original = originalBytes, original > 0 {
                    let change = Double(original - copyBytes) / Double(original) * 100
                    Text((actualBytes == nil ? "~" : "") + String(format: "%.0f", abs(change)) + (change >= 0 ? "% smaller" : "% larger"))
                        .font(.caption.weight(.semibold)).foregroundStyle(change >= 0 ? accent : .orange)
                }
            }
            if actualBytes != nil {
                Text("Measured file size and saved encoding settings. Controls on the right apply to your next compression.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.13)))
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                if model.mediaMode == .photos {
                    PhotoSettingsView().environmentObject(model)
                } else {
                    VStack(alignment: .leading, spacing: 5) { Text("Compression").font(.title3.weight(.semibold)); Text("Your settings, for every selected video.").font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 14) {
                        settingLabel("Maximum resolution", symbol: "arrow.down.right.and.arrow.up.left")
                        Picker("Resolution", selection: $model.settings.resolution) { ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                        settingLabel("Maximum frame rate", symbol: "film")
                        Picker("Frame rate", selection: $model.settings.frameRate) { ForEach(FrameRate.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                        Text("Smaller sources keep their resolution and frame rate.").font(.caption2).foregroundStyle(.secondary)
                        Text("Original frame rate is the default. Choose a lower cap only when you want to remove frames. Slo-mo videos stay protected.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        settingLabel("Picture quality", symbol: "slider.horizontal.3")
                        Picker("Quality", selection: $model.settings.quality) { ForEach(Quality.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().disabled(model.settings.useCustomBitrate)
                        Text(model.settings.pictureQualityExplanation).font(.caption2).foregroundStyle(.secondary)
                        Text("HEVC encoding is lossy, including with Original resolution and frame rate.").font(.caption2).foregroundStyle(.secondary)
                        Toggle("Set video bitrate manually", isOn: $model.settings.useCustomBitrate).font(.caption)
                        if model.settings.useCustomBitrate {
                            HStack { Slider(value: $model.settings.bitrateMbps, in: 0.5...30, step: 0.5); Text("\(model.settings.bitrateMbps, specifier: "%.1f") Mbps").font(.caption.monospacedDigit()).frame(width: 65) }
                        }
                        HStack { Text("Minimum actual savings").font(.caption); Spacer(); Text("\(Int(model.settings.minimumSavings * 100))%").font(.caption.monospacedDigit()) }
                        Slider(value: $model.settings.minimumSavings, in: 0.05...0.7, step: 0.05)
                        Text("Skip a replacement if the finished file saves less than this.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    settingLabel("After compression", symbol: "checkmark.circle")
                    Toggle("Replace originals in Photos", isOn: $model.replaceOriginals).toggleStyle(.switch).font(.callout).disabled(!model.connected && !model.demo)
                    Text(model.replaceOriginals && (model.connected || model.demo) ? "Validated copies are imported first. macOS then asks once to delete the successfully replaced originals. The Review tab still lets you compare or revert them." : "Keep both versions until you decide in the Review tab. Compare side by side, then accept and delete the original or revert the compressed copy.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    if model.connected {
                        SharedLibraryNotice(compact: true).environmentObject(model)
                        SharedLibraryDetectionSettings().environmentObject(model)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    settingLabel("Original archive", symbol: "externaldrive")
                    Text("Full originals and compressed files stay here, independently of iCloud.").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Image(systemName: "folder").foregroundStyle(accent)
                        Text(model.backupDirectory.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.caption).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 8))
                    HStack { Button("Choose folder…") { model.chooseArchive() }; Spacer(); Button { NSWorkspace.shared.open(model.backupDirectory) } label: { Image(systemName: "arrow.up.forward.square") }.help("Open archive in Finder") }
                    if let space = model.archiveSpace {
                        if let available = space.availableBytes {
                            Text("\(DisplayFormat.bytes(available)) available\(space.volumeName.map { " on " + $0 } ?? "")")
                                .font(.caption.weight(.medium))
                        } else if let error = space.error {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("Checking archive disk space…").font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.selected.isEmpty {
                        Text("Selection needs \(model.unknownSelectedSizes > 0 ? "at least " : "~")\(DisplayFormat.bytes(model.estimatedArchiveBytes)) including working space.")
                            .font(.caption).foregroundStyle(model.archiveMayBeTooSmall ? Color.orange : .secondary)
                        if model.unknownSelectedSizes > 0 {
                            Text("Some original sizes are unknown; the estimate can increase after inspection.").font(.caption2).foregroundStyle(.secondary)
                        }
                        if model.archiveMayBeTooSmall {
                            Label("This selection may exceed the available archive space.", systemImage: "externaldrive.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("An external disk works well for a large library. Downloads and backups need free disk space.").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(20).disabled(model.isBusy)
        }
    }

    private func settingLabel(_ title: String, symbol: String) -> some View { Label(title, systemImage: symbol).font(.callout.weight(.medium)) }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.mediaMode == .photos && model.photoSettings.convertLiveToStill,
               !model.isBusy, model.selectedVideos.contains(where: { $0.kind == .livePhoto }) {
                Label("Selected Live Photo copies will be still images: motion and sound will be removed.", systemImage: "livephoto.slash")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            if model.isReviewing { ProgressView().controlSize(.small) }
            else if model.isBusy { ProgressView(value: model.overallProgress).tint(accent) }
            if let summary = model.batchSummary, !model.isBusy {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title).font(.headline)
                        Text(summary.details).font(.caption).foregroundStyle(.secondary)
                        Text("\(DisplayFormat.bytes(summary.savedBytes)) less space in the completed copies").font(.caption).foregroundStyle(accent)
                    }
                    Spacer()
                    Button("Open Review") { model.openReview() }
                    Button { model.batchSummary = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss batch summary")
                }.padding(12).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.section == .review {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isBusy ? model.activity : "\(model.awaitingReview.count) copies awaiting review").font(.callout.weight(.semibold))
                        Text("Your decisions are saved. Return here whenever you are ready.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DiskSpaceIndicator().environmentObject(model)
                    if model.isBusy && !model.isReviewing { Button("Stop safely") { model.stop() } }
                    Button("Back to Library") { model.section = .library }
                }
            } else {
              HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isBusy ? model.activity : "\(model.selected.count) \(model.mediaMode.rawValue.lowercased()) selected").font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.isBusy ? "Originals stay archived. Stopping never deletes an unfinished original." : model.unknownSelectedSizes > 0 ? "\(model.unknownSelectedSizes) original sizes pending · measured during download" : "\(DisplayFormat.bytes(model.selectedOriginalBytes)) → ~\(DisplayFormat.bytes(model.selectedEstimatedBytes)) estimated")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                DiskSpaceIndicator().environmentObject(model)
                if !model.selected.isEmpty && !model.isBusy {
                    VStack(alignment: .trailing, spacing: 3) { Text("~" + DisplayFormat.bytes(model.selectedSavings)).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(accent); Text(model.connected || model.demo ? "potential iCloud savings" : "estimated file savings").font(.caption2).foregroundStyle(.secondary) }
                }
                if model.isBusy && !model.isReviewing { Button("Stop safely") { model.stop() }.controlSize(.large) }
                else if model.isReviewing { Text("Updating Photos…").foregroundStyle(.secondary) }
                else {
                    Button {
                        if model.demo { model.connect() } else { model.startBatch() }
                    } label: {
                        Label(model.demo ? "Connect Photos to begin" : model.connected && model.replaceOriginals ? "Compress & replace \(model.selected.count)" : "Compress \(model.selected.count) copies", systemImage: "arrow.down.right.and.arrow.up.left")
                            .padding(.horizontal, 9).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled((model.selected.isEmpty && !model.demo) || model.isLoading || model.indexingSizes || model.isInspecting || model.journal == nil)
                        .help(model.isInspecting ? "Wait for inspection to finish or cancel it before starting compression" : "Compress the selected videos")
                }
            }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(surface)
    }
}

// AVKit's SwiftUI VideoPlayer overlay aborts during generic superclass metadata
// initialization on the tested macOS 15 runtime with the current SDK. The native
// macOS view provides the same playback controls without that overlay.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.setAccessibilityIdentifier("native-video-player")
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// Keep transport controls in the layout: AVPlayerView's overlay was not
// consistently visible for PhotoKit preview items on the tested macOS runtime.
private struct PlaybackControls: View {
    let player: AVPlayer
    @State private var elapsed = 0.0
    @State private var duration = 0.0
    @State private var playing = false
    @State private var seeking = false
    @State private var muted = false
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if player.rate > 0 { player.pause() }
                else {
                    if duration > 0 && elapsed >= duration - 0.05 { player.seek(to: .zero) }
                    player.play()
                }
                synchronize()
            } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 18) }
            .accessibilityLabel(playing ? "Pause preview" : "Play preview")
            .help(playing ? "Pause preview" : "Play preview")
            Text(DisplayFormat.duration(elapsed)).monospacedDigit().frame(minWidth: 34)
            Slider(value: $elapsed, in: 0...max(duration, 0.01), onEditingChanged: { editing in
                seeking = editing
                if !editing { player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            })
            .accessibilityLabel("Preview position")
            .disabled(duration <= 0)
            Text(DisplayFormat.duration(duration)).monospacedDigit().frame(minWidth: 34)
            Button {
                player.isMuted.toggle(); muted = player.isMuted
            } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18) }
            .accessibilityLabel(muted ? "Unmute preview" : "Mute preview")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .onAppear { synchronize(); muted = player.isMuted }
        .onReceive(ticker) { _ in synchronize() }
    }

    private func synchronize() {
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        if !seeking {
            let current = player.currentTime().seconds
            elapsed = current.isFinite ? min(max(current, 0), duration) : 0
        }
        playing = player.rate > 0
    }
}

private struct VideoRow: View {
    @EnvironmentObject var model: AppModel
    let video: LibraryVideo
    var body: some View {
        HStack(spacing: 8) {
            Toggle("Select \(video.name) for compression", isOn: Binding(get: { model.selected.contains(video.id) }, set: { _ in model.toggle(video) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(model.isBusy || video.unsupportedReason != nil)
            VideoSidebarRow(title: video.name,
                            detail: "\(video.facts.bytes.map(DisplayFormat.bytes) ?? "Size pending") · " + (video.kind.isPhoto ? (video.kind == .livePhoto ? "Live Photo" : video.isPanorama ? "Panorama" : "Photo") : DisplayFormat.duration(video.facts.duration)) + (video.facts.isHDR ? " · HDR" : ""),
                            status: statusText, savings: savingsText, statusColor: statusColor,
                            progress: model.statuses[video.id]?.fraction,
                            sharing: video.asset != nil && model.sharing.enabled ? model.sharing.observation(for: video.id) : nil) {
                VideoThumbnail(video: video)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .contextMenu { VideoContextMenu(video: video).environmentObject(model) }
    }

    private var statusText: String {
        if let status = model.statuses[video.id] { return status.text }
        if video.unsupportedReason != nil { return video.isSlowMotion ? "Slo-mo · protected" : "Original protected" }
        if savingsText != nil { return "" }
        return "~\(DisplayFormat.bytes(model.estimatedBytes(video))) output"
    }

    private var savingsText: String? {
        guard video.unsupportedReason == nil else { return nil }
        if let record = model.outputRecord(for: video.id), let before = record.originalBytes, let after = record.outputBytes, before > after {
            return "\(DisplayFormat.bytes(before - after)) smaller · \(Int((Double(before - after) / Double(before) * 100).rounded()))%"
        }
        guard let savings = model.estimatedSavings(video), savings > 0 else { return nil }
        let percent = video.facts.bytes.flatMap { $0 > 0 ? Int((Double(savings) / Double($0) * 100).rounded()) : nil }
        return "Save ~\(DisplayFormat.bytes(savings))" + (percent.map { " · ~\($0)%" } ?? "")
    }

    private var statusColor: Color {
        if let status = model.statuses[video.id] { return status.failed ? .orange : .secondary }
        return video.unsupportedReason != nil ? .orange : .secondary
    }
}

private struct VideoContextMenu: View {
    @EnvironmentObject var model: AppModel
    let video: LibraryVideo

    var body: some View {
        if let id = model.photosID(for: video) {
            Button { model.showInPhotos(id: id) } label: { Label("Show in Photos", systemImage: "photo.on.rectangle") }
        }
        if let copyID = model.photosID(for: video, compressed: true), copyID != model.photosID(for: video) {
            Button("Show compressed copy in Photos") { model.showInPhotos(id: copyID) }
        }
        if let url = video.fileURL {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        Divider()
        if let record = model.outputRecord(for: video.id), record.hasReviewableCopy {
            Button("Review side by side") { model.openReview(record) }
        }
        Button(video.kind.isPhoto ? "Preview photo" : "Preview video") { model.focus(video) }
        if !video.kind.isPhoto, video.asset != nil, !video.hasInspectedFacts, video.unsupportedReason == nil {
            Button("Inspect original…") { model.requestInspection(video) }
                .disabled(model.isBusy || model.inspections[video.id]?.isWorking == true)
        }
        Button(model.selected.contains(video.id) ? "Deselect for compression" : "Select for compression") { model.toggle(video) }
            .disabled(model.isBusy || video.unsupportedReason != nil)
    }
}

private struct VideoThumbnail: View {
    let video: LibraryVideo
    @State private var image: NSImage?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else if video.isDemo { SampleArtwork(seed: abs(video.id.hashValue % 6)) }
            else { Rectangle().fill(Color.gray.opacity(0.15)); Image(systemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if !video.kind.isPhoto { Text(DisplayFormat.duration(video.facts.duration)).font(.system(size: 9, weight: .medium)).foregroundStyle(.white).padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3)).padding(4) }
        }
        .task(id: video.id) {
            if let asset = video.asset { image = await PhotosService.thumbnail(asset, size: CGSize(width: 200, height: 150)) }
            else if let url = video.fileURL {
                if video.kind.isPhoto {
                    image = await Task.detached { PhotoPreviewRenderer.render(url, maximum: 200) }.value
                    return
                }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 200, height: 150)
                if let result = try? await generator.image(at: CMTime(seconds: min(2, video.facts.duration / 2), preferredTimescale: 600)) { image = NSImage(cgImage: result.image, size: .zero) }
            }
        }
    }
}

private struct SampleArtwork: View {
    let seed: Int
    private var palettes: [[Color]] { [[Color(red: 0.55, green: 0.73, blue: 0.77), Color(red: 0.16, green: 0.36, blue: 0.39)], [.orange.opacity(0.7), .brown], [.purple.opacity(0.4), .indigo], [.green.opacity(0.4), .teal], [.gray.opacity(0.3), .blue.opacity(0.7)], [.mint.opacity(0.5), .green.opacity(0.8)]] }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: palettes[seed % palettes.count], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.4)).frame(width: proxy.size.width * 0.15).offset(x: proxy.size.width * 0.25, y: -proxy.size.height * 0.18)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height * 0.7))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.35, y: proxy.size.height * 0.3))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.7, y: proxy.size.height * 0.8))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height * 0.5))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height)); path.addLine(to: CGPoint(x: 0, y: proxy.size.height)); path.closeSubpath()
                }.fill(.black.opacity(0.16))
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedDeletionIDs = Set<UUID>()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Compression history").font(.title2.weight(.semibold)); Text("Every original, smaller copy, and replacement is recorded here.").foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            if !model.pending.isEmpty {
                SharedLibraryNotice().environmentObject(model)
                HStack {
                    Label("\(model.pending.count) verified copies have originals in Photos.", systemImage: "checkmark.shield")
                    Spacer()
                    Menu("Select") {
                        Button("All ready originals") { selectedDeletionIDs = Set(model.pending.map(\.id)) }
                        Button("None") { selectedDeletionIDs.removeAll() }
                    }.fixedSize()
                    Button("Delete \(selectedDeletionIDs.intersection(Set(model.pending.map(\.id))).count) originals…") { model.deletePending(selectedDeletionIDs) }
                        .disabled(model.isBusy || !model.connected || selectedDeletionIDs.intersection(Set(model.pending.map(\.id))).isEmpty)
                }
                    .padding(12).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.history.isEmpty { ContentUnavailableView("No operations yet", systemImage: "clock", description: Text("Completed and interrupted operations appear here.")) }
            else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.history) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    if record.isDeletionCandidate {
                                        Toggle("Select original", isOn: Binding(get: { selectedDeletionIDs.contains(record.id) }, set: { if $0 { selectedDeletionIDs.insert(record.id) } else { selectedDeletionIDs.remove(record.id) } }))
                                            .toggleStyle(.checkbox).labelsHidden().disabled(model.isBusy)
                                    }
                                    Text(record.sourceName).font(.headline); Spacer(); Text(stageName(record.stage)).font(.caption.weight(.medium)).foregroundStyle(record.stage == .failed ? .orange : accent)
                                }
                                HStack { Text(record.startedAt.formatted()); Spacer(); if let before = record.originalBytes, let after = record.outputBytes { Text("\(DisplayFormat.bytes(before)) → \(DisplayFormat.bytes(after))") } }.font(.caption).foregroundStyle(.secondary)
                                if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                                HStack {
                                    if record.hasReviewableCopy { Button("Review side by side") { model.openReview(record); dismiss() } }
                                    Button("Show archived files") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.backupPath)]) }
                                    if FileManager.default.fileExists(atPath: record.outputPath) { Button("Open compressed copy") { NSWorkspace.shared.open(URL(fileURLWithPath: record.outputPath)) } }
                                    if let id = record.replacementID, record.stage != .reverted { Button("Show copy in Photos") { model.showInPhotos(id: id) } }
                                    Spacer()
                                }.controlSize(.small)
                            }.padding(15).background(surface, in: RoundedRectangle(cornerRadius: 10))
                                .contextMenu {
                                    if let id = record.replacementID, record.stage != .reverted {
                                        Button("Show compressed copy in Photos") { model.showInPhotos(id: id) }
                                    }
                                    if record.isPhotosOperation, record.stage != .originalDeleted && record.stage != .reverting || record.restoredOriginalID != nil {
                                        Button("Show original in Photos") { model.showInPhotos(id: record.restoredOriginalID ?? record.sourceID) }
                                    }
                                    Button("Show archived files") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.backupPath)]) }
                                }
                        }
                    }
                }
            }
            Text("Local archives are never removed automatically. Keep them until Photos has finished syncing and you have checked the smaller copies on your other devices.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 900, height: 610).tint(accent)
            .onAppear { selectedDeletionIDs = Set(model.pending.map(\.id)) }
    }
    private func stageName(_ stage: OperationStage) -> String {
        switch stage {
        case .preparing: return "Preparation interrupted"
        case .archived: return "Archived · encoding interrupted"
        case .encoded: return "Encoded · import not completed"
        case .imported: return "Imported · metadata needs review"
        case .readyToDelete: return "Ready · original retained"
        case .originalDeleted: return "Replaced in Photos"
        case .keptOriginal: return "Original retained"
        case .failed: return "Stopped or failed · original retained"
        case .reverting: return "Revert interrupted · original protected"
        case .reverted: return "Reverted · original kept"
        }
    }
}
