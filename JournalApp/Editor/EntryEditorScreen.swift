import JournalCore
import JournalUI
import PhotosUI
import SwiftUI

/// The entry editor, pushed onto the current tab's stack so back-swipe works.
struct EntryEditorScreen: View {
    let entryID: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.usesSerifBody) private var usesSerifBody
    @Environment(\.entryTextSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @State private var model: EntryEditorModel?

    var body: some View {
        Group {
            if let model, model.entry != nil {
                EntryEditorContent(model: model)
            } else if model != nil {
                ContentUnavailableView("This entry was deleted", systemImage: "trash")
            } else {
                Color.clear
            }
        }
        // Fill under the keyboard too, so its rounded top corners show the page color, not white.
        .background { JournalColors.background.ignoresSafeArea() }
        .onAppear {
            if model == nil {
                model = EntryEditorModel(entryID: entryID, app: app, fonts: EntryFonts(size: textSize.points * textScale, serif: usesSerifBody))
            }
        }
        .onDisappear { model?.viewDidDisappear() }
    }
}

private enum EditorField: Hashable { case title, body }

private enum EditorSheet: String, Identifiable {
    case tags, rating, location, date, info
    var id: String { rawValue }
}

struct EntryEditorContent: View {
    @Bindable var model: EntryEditorModel

    @Environment(AppModel.self) private var app
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.usesSerifBody) private var usesSerifBody
    @Environment(\.entryTextSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: EditorField?
    @State private var isGridRaised = true
    @State private var gridHeight: CGFloat = 0
    @State private var keyboardLift: CGFloat = 0
    @State private var unshrunkBottom: CGFloat = 0
    @State private var sheet: EditorSheet?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isShowingPhotoPicker = false
    @State private var isShowingCamera = false
    @State private var isConfirmingDelete = false
    @State private var viewerStart: MediaReference?
    @State private var isShowingAllPhotos = false
    @State private var allPhotosViewerStart: MediaReference?
    @State private var comingSoon: LocalizedStringResource?
    @State private var permissionMessage: LocalizedStringResource?

    /// Body and heading fonts at the chosen Text Size, scaled with Dynamic Type.
    private var fonts: EntryFonts {
        EntryFonts(size: textSize.points * textScale, serif: usesSerifBody)
    }

    private var entry: Entry? { model.entry }

    // The body is split into parts so the type checker finishes in reasonable time.
    var body: some View {
        withPresentations
            // While the page animates away (back swipe or back button), ignore taps so one
            // landing on the text can't bring up the keyboard on the way out.
            .allowsHitTesting(!app.router.isLeavingEntry)
            .onChange(of: app.router.isLeavingEntry) { _, isLeaving in
                if isLeaving { focus = nil }
            }
            .alert("Coming in the next update", isPresented: Binding(get: { comingSoon != nil }, set: { if !$0 { comingSoon = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                if let comingSoon { Text(comingSoon) }
            }
            .alert("Permission needed", isPresented: Binding(get: { permissionMessage != nil }, set: { if !$0 { permissionMessage = nil } })) {
                Button("Open Settings") { openAppSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let permissionMessage { Text(permissionMessage) }
            }
            .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var withPresentations: some View {
        withChrome
            .photosPicker(isPresented: $isShowingPhotoPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                // The collage is hidden while typing, so close the keyboard to show what was added.
                focus = nil
                Task { await model.importPicked(items) }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { data in
                    focus = nil
                    Task { await model.importCameraPhoto(data) }
                }
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $viewerStart) { start in
                MediaViewer(items: collageItems, startAt: start.id)
            }
            .sheet(isPresented: $isShowingAllPhotos) { allPhotosSheet }
            .sheet(item: $sheet) { sheet in sheetContent(sheet) }
            .confirmationDialog("Delete this entry?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Entry", role: .destructive) { model.delete() }
            } message: {
                Text("Its photos and videos are deleted too.")
            }
            .confirmationDialog(
                "Use the photo's location?",
                isPresented: Binding(get: { model.photoLocationOffer != nil }, set: { if !$0 { model.photoLocationOffer = nil } }),
                titleVisibility: .visible,
                presenting: model.photoLocationOffer
            ) { offer in
                Button("Use Photo Location") { Task { await model.usePhotoLocation(offer) } }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("This photo has a location. You can add it to the entry.")
            }
    }

    private var withChrome: some View {
        editorColumn
            .safeAreaInset(edge: .bottom) {
                if focus == nil {
                    // Keeps the text clear of the action grid, which floats in the overlay below.
                    Color.clear.frame(height: gridHeight)
                } else {
                    keyboardBar
                        .background { bottomBacking }
                        // Fade in just after the grid starts dropping, so the two never overlap. Leave at
                        // once: fading out, it drifted down over the grid as the keyboard closed.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)),
                            removal: .identity
                        ))
                }
            }
            // The grid lives in its own layer pinned to the screen bottom so it can slide on its own
            // schedule. The keyboard covers it as it rises and uncovers it as it goes.
            .overlay(alignment: .bottom) {
                EditorActionGrid(perform: perform)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    // The text editor scrolls under the grid, so back it with the page color (fading in
                    // just above) or long text shows through the translucent tiles.
                    .background { bottomBacking }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gridHeight = $0 }
                    // Push back down by however much the keyboard has shortened the screen, so the
                    // grid stays at the bottom (and drops away) instead of riding up with the keyboard.
                    .offset(y: keyboardLift + (isGridRaised || reduceMotion ? 0 : gridHeight + 80))
                    .opacity(isGridRaised ? 1 : 0)
                    .allowsHitTesting(isGridRaised)
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                if focus == nil && keyboardLift == 0 { unshrunkBottom = bottom }
                keyboardLift = max(0, unshrunkBottom - bottom)
            }
            .onChange(of: focus == nil) { _, isUnfocused in
                // DECISION: iOS raises the keyboard the moment a field is tapped, so the buttons can't
                // leave before it without delaying focus. They vanish instantly instead, and come
                // back up only after the keyboard has gone (0.25 s).
                if isUnfocused {
                    withAnimation((reduceMotion ? Animation.easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25)).delay(0.25)) {
                        isGridRaised = true
                    }
                } else {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { isGridRaised = false }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                model.fontContext = fontContext
                model.fonts = fonts
                if entry?.isEmptyContent == true && !app.unfocusedNewEntries.contains(model.routeEntryID) { focus = .title }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: entry?.rating)
            .sensoryFeedback(.impact(weight: .light), trigger: entry?.liveTags.count)
    }

    /// Photos and videos, the cover first and the rest in the entry's order.
    private var collageItems: [MediaReference] {
        let visual = model.media.filter { $0.kind.isVisual }
        guard let coverID = entry?.coverAttachment?.id, let cover = visual.first(where: { $0.id == coverID }) else { return visual }
        return [cover] + visual.filter { $0.id != coverID }
    }

    /// Moves a photo to a position counted among the photos only (the All Photos grid's order).
    private func movePhoto(_ item: MediaReference, toPhotoIndex index: Int) {
        let visual = model.media.filter { $0.kind.isVisual }
        guard visual.indices.contains(index), let target = model.media.firstIndex(of: visual[index]) else { return }
        model.move(item, to: target)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            // DECISION: the collage sits above the title and folds away while you type. Making it
            // scroll with the text would mean taking over TextEditor's own scrolling, which stops
            // it keeping the cursor in view.
            if !collageItems.isEmpty && focus == nil {
                PhotoCollage(
                    items: collageItems,
                    onOpen: { viewerStart = $0 },
                    onShowAll: { isShowingAllPhotos = true },
                    onSetCover: { model.setCover($0) },
                    onRemove: { model.remove($0) }
                )
                // About 40% of the screen, capped on tall phones.
                .containerRelativeFrame(.vertical) { height, _ in min(height * 0.4, 360) }
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            TextField("Title", text: $model.title)
                .font(.title2.bold())
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .body }
                .padding(.horizontal)
                .padding(.top, 8)

            TextEditor(text: $model.text, selection: $model.selection)
                .font(fonts.body)
                .focused($focus, equals: .body)
                .scrollContentBackground(.hidden)
                // Its text otherwise draws past its frame, up into the title as it scrolls.
                .clipped()
                .padding(.horizontal, 11)
                .overlay(alignment: .topLeading) {
                    if model.text.characters.isEmpty {
                        Text("Start writing…")
                            .font(fonts.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: model.text) { old, _ in
                    _ = RichTextFormatting.continueListIfNeeded(oldText: old, in: &model.text, selection: &model.selection)
                }

            chipsRow
            // Photos and videos are in the collage; other attachments (audio, files) stay here.
            let otherMedia = model.media.filter { !$0.kind.isVisual }
            if !otherMedia.isEmpty {
                MediaStrip(
                    items: otherMedia,
                    coverID: entry?.coverAttachment?.id,
                    onOpen: { viewerStart = $0 },
                    onMove: { model.move($0, to: $1) },
                    onSetCover: { model.setCover($0) },
                    onRemove: { model.remove($0) }
                )
                .padding(.vertical, 8)
            }
            if model.isImporting {
                ProgressView("Adding media…")
                    .padding(.vertical, 6)
            }
        }
    }

    private var allPhotosSheet: some View {
        NavigationStack {
            AllPhotosGrid(
                items: model.media.filter { $0.kind.isVisual },
                coverID: entry?.coverAttachment?.id,
                onOpen: { allPhotosViewerStart = $0 },
                onMove: { movePhoto($0, toPhotoIndex: $1) },
                onSetCover: { model.setCover($0) },
                onRemove: { model.remove($0) }
            )
            .navigationTitle("All Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { isShowingAllPhotos = false }
                }
            }
            .fullScreenCover(item: $allPhotosViewerStart) { start in
                MediaViewer(items: model.media.filter { $0.kind.isVisual }, startAt: start.id)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                sheet = .date
            } label: {
                if let entry {
                    Text(entry.entryDate.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().year(.twoDigits), in: entry.timeZone))
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityHint(Text("Changes the entry's date and time"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { model.toggleFavorite() } label: {
                    Label(entry?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: entry?.isFavorite == true ? "heart.slash" : "heart")
                }
                Button { model.duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                ShareLink(item: model.shareText) { Label("Share Entry", systemImage: "square.and.arrow.up") }
                if model.media.contains(where: { $0.kind.isVisual }) {
                    Menu {
                        ForEach(model.media.filter { $0.kind.isVisual }.enumerated().map { $0 }, id: \.element.id) { index, item in
                            Button { model.setCover(item) } label: {
                                Label("Photo \(index + 1)", systemImage: item.id == entry?.coverAttachment?.id ? "checkmark" : "photo")
                            }
                        }
                    } label: {
                        Label("Set Cover Photo", systemImage: "star")
                    }
                }
                Button { sheet = .info } label: { Label("Entry Info", systemImage: "info.circle") }
                Divider()
                Button(role: .destructive) { isConfirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Keyboard bar

    /// The page color behind the bottom controls, fading in just above them, so text scrolled
    /// under them doesn't show through.
    private var bottomBacking: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [JournalColors.background.opacity(0), JournalColors.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
            JournalColors.background
        }
        .padding(.top, -16)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    // DECISION: drawn in the view rather than as a .keyboard toolbar, because the system
    // puts an opaque strip behind keyboard toolbars that doesn't match the page. This bar
    // floats over the writing area and rides on top of the keyboard via the safe area.
    private var keyboardBar: some View {
        GlassEffectContainer {
            HStack {
                if focus == .body {
                    // Bold, italic and underline stay one tap away; the rest live in one menu
                    // so the bar fits on the narrowest iPhone.
                    HStack(spacing: 4) {
                        ForEach([RichTextStyle.bold, .italic, .underline]) { style in
                            styleButton(style)
                        }
                        Menu {
                            ForEach([RichTextStyle.strikethrough, .heading]) { style in
                                Button { toggle(style) } label: {
                                    Label { Text(style.label) } icon: { Image(systemName: style.symbolName) }
                                }
                            }
                            Divider()
                            Button { RichTextFormatting.insertListItem(.bullet, in: &model.text, selection: &model.selection) } label: {
                                Label("Bulleted List", systemImage: "list.bullet")
                            }
                            Button { RichTextFormatting.insertListItem(.numbered, in: &model.text, selection: &model.selection) } label: {
                                Label("Numbered List", systemImage: "list.number")
                            }
                        } label: {
                            barIcon("More Formatting", systemImage: "textformat")
                        }
                    }
                    .padding(.horizontal, 6)
                    .glassEffect(.regular.interactive())
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Menu {
                        ForEach(EditorAction.allCases) { action in
                            Button { perform(action) } label: { Label { Text(action.title) } icon: { Image(systemName: action.symbolName) } }
                        }
                    } label: {
                        barIcon("Add", systemImage: "plus.circle")
                    }
                    Button { focus = nil } label: {
                        barIcon("Done", systemImage: "keyboard.chevron.compact.down")
                    }
                }
                .padding(.horizontal, 6)
                .glassEffect(.regular.interactive())
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private func barIcon(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }

    private func styleButton(_ style: RichTextStyle) -> some View {
        Button { toggle(style) } label: {
            Label { Text(style.label) } icon: { Image(systemName: style.symbolName) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RichTextFormatting.isActive(style, in: model.text, selection: model.selection, context: fontContext, fonts: fonts) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private func toggle(_ style: RichTextStyle) {
        RichTextFormatting.toggle(style, in: &model.text, selection: &model.selection, context: fontContext, fonts: fonts)
    }

    // MARK: Chips

    @ViewBuilder
    private var chipsRow: some View {
        if let entry, !entry.liveTags.isEmpty || entry.rating != nil || entry.placeName != nil || entry.hasLocation {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(entry.liveTags) { tag in
                        Button { sheet = .tags } label: { TagChip(tag) }
                    }
                    if let rating = entry.rating {
                        Button { sheet = .rating } label: {
                            RatingStars(rating)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.18), in: .capsule)
                        }
                    }
                    if entry.hasLocation {
                        Button { sheet = .location } label: {
                            InfoChip(Text(entry.placeName ?? String(localized: "Location")), systemImage: "mappin.and.ellipse")
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
            .padding(.top, 8)
        }
    }

    // MARK: Actions

    private func perform(_ action: EditorAction) {
        switch action {
        case .photo:
            isShowingPhotoPicker = true
        case .camera:
            Task {
                guard CameraPicker.isAvailable else {
                    model.errorMessage = String(localized: "This device has no camera available.")
                    return
                }
                if await CameraPicker.requestAccess() {
                    isShowingCamera = true
                } else {
                    permissionMessage = "Camera access is off for this app. Turn it on in Settings to take photos for your entries."
                }
            }
        case .tags:
            sheet = .tags
        case .rating:
            sheet = .rating
        case .audio:
            comingSoon = "Voice memos arrive in the next update."
        case .file:
            comingSoon = "File attachments arrive in the next update."
        case .location:
            sheet = .location
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: EditorSheet) -> some View {
        if let entry {
            switch sheet {
            case .tags:
                TagPickerSheet(selected: entry.liveTags) { model.setTags($0) }
            case .rating:
                RatingSheet(rating: Binding(get: { entry.rating }, set: { model.setRating($0) }))
            case .location:
                LocationPickerSheet(
                    current: entry.hasLocation ? entry.placeName ?? String(localized: "Location") : nil,
                    onPick: { model.setLocation(latitude: $0, longitude: $1, placeName: $2) },
                    onRemove: { model.clearLocation() },
                    onDenied: { permissionMessage = "Location access is off for this app. Turn it on in Settings to tag where you wrote." }
                )
            case .date:
                EntryDateSheet(date: entry.entryDate, timeZone: entry.timeZone) { model.setDate($0) }
            case .info:
                EntryInfoSheet(entry: entry)
            }
        }
    }
}

#Preview {
    NavigationStack {
        EntryEditorScreen(entryID: PreviewSupport.firstEntryID)
    }
    .environment(PreviewSupport.model)
    .preferredColorScheme(.dark)
}
