import JournalCore
import JournalUI
import PhotosUI
import SwiftUI

/// The entry editor, pushed onto the current tab's stack so back-swipe works.
struct EntryEditorScreen: View {
    let entryID: UUID

    @Environment(AppModel.self) private var app
    @Environment(\.usesSerifBody) private var usesSerifBody
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
        .background(JournalColors.background)
        .onAppear {
            if model == nil {
                model = EntryEditorModel(entryID: entryID, app: app, baseFont: EntryEditorContent.bodyFont(serif: usesSerifBody))
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
    @FocusState private var focus: EditorField?
    @State private var sheet: EditorSheet?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isShowingPhotoPicker = false
    @State private var isShowingCamera = false
    @State private var isConfirmingDelete = false
    @State private var viewerStart: MediaReference?
    @State private var comingSoon: LocalizedStringResource?
    @State private var permissionMessage: LocalizedStringResource?

    static func bodyFont(serif: Bool) -> Font {
        serif ? .system(.body, design: .serif) : .body
    }

    private var entry: Entry? { model.entry }

    // The body is split into parts so the type checker finishes in reasonable time.
    var body: some View {
        withPresentations
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
                Task { await model.importPicked(items) }
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraPicker { data in Task { await model.importCameraPhoto(data) } }
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $viewerStart) { start in
                MediaViewer(items: model.media, startAt: start.id)
            }
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
                    EditorActionGrid(perform: perform)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    keyboardBar
                }
            }
            .animation(.snappy, value: focus == nil)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                model.fontContext = fontContext
                if entry?.isEmptyContent == true { focus = .title }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: entry?.rating)
            .sensoryFeedback(.impact(weight: .light), trigger: entry?.liveTags.count)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $model.title)
                .font(.title2.bold())
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .body }
                .padding(.horizontal)
                .padding(.top, 8)

            TextEditor(text: $model.text, selection: $model.selection)
                .font(Self.bodyFont(serif: usesSerifBody))
                .focused($focus, equals: .body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .overlay(alignment: .topLeading) {
                    if model.text.characters.isEmpty {
                        Text("Start writing…")
                            .font(Self.bodyFont(serif: usesSerifBody))
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
            if !model.media.isEmpty {
                MediaStrip(
                    items: model.media,
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
        .transition(.opacity)
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
        .foregroundStyle(RichTextFormatting.isActive(style, in: model.text, selection: model.selection, context: fontContext) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }

    private func toggle(_ style: RichTextStyle) {
        RichTextFormatting.toggle(style, in: &model.text, selection: &model.selection, context: fontContext, baseFont: Self.bodyFont(serif: usesSerifBody))
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
