import SwiftUI

/// The crate, under the track windows and the CUE · PLAY · loop · crossfader
/// row: playlists on the left, the tracks beside them. Tap a row, then a
/// deck's album art to load it. Ports `Library` in `Sheets.tsx` and the
/// `.library` / `.lib-*` rules.
struct LibraryPane: View {
    let state: ConsoleState
    let actions: ConsoleActions
    @State private var ui: LibraryView
    @FocusState private var searching: Bool
    @Environment(\.consoleSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: ConsoleState, actions: ConsoleActions, start: LibraryView = LibraryView()) {
        self.state = state; self.actions = actions
        _ui = State(initialValue: start)
    }

    private var library: ConsoleState.Library { state.library }
    private var playlist: ConsoleState.Library.Playlist? { library.playlists.first { $0.id == ui.view } }
    /// The set open in place of a playlist: its tracks in the order played.
    private var openSet: ConsoleState.Library.SetEntry? { library.sets.first { $0.id == ui.view } }
    private var isCurrentSet: Bool { openSet != nil && openSet?.id == library.currentSet?.id }

    var body: some View {
        let rows = self.rows
        let total = playlist?.trackIDs.count ?? openSet?.plays.count ?? library.tracks.count
        VStack(alignment: .leading, spacing: 8) {
            head(total: total, shown: rows.count)
            HStack(alignment: .top, spacing: 11) {
                side.frame(width: 196).padding(.leading, 2)
                main(rows).padding(.trailing, 2)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x060606))
        .overlay(alignment: .top) { Color.black.frame(height: 1) }
        .onValueChange(of: state.libraryOpen) { open in
            if !open { searching = false; ui.listMenu = nil; ui.confirmDelete = false }
        }
        .onValueChange(of: library.justMade) { id in
            if let id { open(id); ui.renaming = id }
        }
        .onValueChange(of: library.playlists.map(\.id) + library.sets.map(\.id)) { ids in
            // NEW SET starts a set with a new id: THIS SET moves on to it.
            if ui.followingSet != nil { ui.followingSet = nil; ui.view = library.currentSet?.id; return }
            // A deleted playlist drops the view back to the whole library.
            guard let view = ui.view, !ids.contains(view) else { return }
            ui.view = nil
        }
    }

    // MARK: Rows

    /// A track row; in a set, each play is a row of its own, with when it was played.
    private struct Entry: Identifiable {
        let track: ConsoleState.Library.Track
        var at: String? = nil
        let id: String
    }

    private enum Row: Identifiable {
        case track(Entry)
        case pending(ConsoleState.Library.PendingImport)

        var id: String {
            switch self {
            case .track(let entry): entry.id
            case .pending(let pending): pending.id
            }
        }
    }

    /// `rows` in Sheets.tsx: the view's tracks, by key and search, then sorted.
    private var rows: [Entry] {
        let needle = ui.query.trimmingCharacters(in: .whitespaces).lowercased()
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let base: [Entry] = if let set = openSet {
            set.plays.enumerated().compactMap { index, play in
                byID[play.trackID].map { Entry(track: $0, at: play.time, id: "\(index)-\($0.id)") }
            }
        } else {
            (playlist.map { $0.trackIDs.compactMap { byID[$0] } }
                ?? library.tracks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending })
                .map { Entry(track: $0, id: $0.id) }
        }
        let keys = keyCodes
        let list = base.filter { entry in
            let track = entry.track
            if let keys, !keys.contains(track.camelot ?? "") { return false }
            if needle.isEmpty { return true }
            if Camelot.parse(needle.uppercased()) != nil { return track.camelot == needle.uppercased() }
            return "\(track.name) \(track.key ?? "") \(track.camelot ?? "") \(String(format: "%.1f", track.bpm))".lowercased().contains(needle)
        }
        guard let sort = ui.sort else { return list }
        return list.sorted { a, b in
            let order = sort.column.compare(a.track, b.track)
            if order != .orderedSame { return (order == .orderedAscending) == (sort.ascending) }
            return a.track.title.localizedCompare(b.track.title) == .orderedAscending
        }
    }

    private var keyCodes: [String]? {
        guard !ui.keyFilter.isEmpty else { return nil }
        return ui.compatible ? Camelot.compatible(ui.keyFilter) : [ui.keyFilter]
    }

    // MARK: Head

    private func head(total: Int, shown: Int) -> some View {
        let missingKeys = library.tracks.filter { $0.camelot == nil && !$0.keyChecked && !$0.missing }.count
        return HStack(spacing: 8) {
            Text((playlist?.name ?? openSet.map { isCurrentSet ? "This set" : $0.started } ?? "Library").uppercased())
                .font(Face.avenir(22, weight: .bold).font).tracking(3.96).lineLimit(1)
                .foregroundStyle(Palette.text).frame(height: 22)
            Text("\(total) \(total == 1 ? "track" : "tracks")" + (shown != total ? " · \(shown) shown" : "")
                 + (library.pendingImports.isEmpty ? "" : " · \(library.pendingImports.count) importing"))
                .font(Face.avenir(16, weight: .regular).font).foregroundStyle(Color(hex: 0xA0A0A6))
                .fixedSize().padding(.leading, 17)
            Spacer(minLength: 0).layoutPriority(-1)
            Group {
                if snapshot {
                    Text(ui.query.isEmpty ? "Search tracks, keys (4A), BPM" : ui.query)
                        .foregroundStyle(ui.query.isEmpty ? Color(hex: 0x757575) : Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $ui.query, prompt: Text("Search tracks, keys (4A), BPM").foregroundColor(Color(hex: 0x757575)))
                        .textFieldStyle(.plain).foregroundStyle(Palette.text)
                        .autocorrectionDisabled()
                        .focused($searching)
                }
            }
            .font(Face.avenir(16, weight: .regular).font).lineLimit(1)
            .padding(.horizontal, 13).frame(minWidth: 100, maxWidth: 300).frame(height: 36)
            .box(fill: Color(hex: 0x141416), border: Color(hex: 0x3A3A40), radius: 3)
            .padding(.trailing, 30)
            if let set = openSet {
                headerKey("Save as playlist", disabled: set.plays.isEmpty) {
                    if let id = actions.library.saveSet(set.id) { open(id) }
                }
                if isCurrentSet {
                    // NEW SET asks twice: the played marks clear.
                    SheetButton(title: ui.confirmNewSet ? "Tap again: new set" : "New set", style: ui.confirmNewSet ? .danger : .outline,
                                height: 36, face: .avenir(15, weight: .bold)) {
                        if !ui.confirmNewSet { ui.confirmNewSet = true; return }
                        ui.confirmNewSet = false
                        ui.followingSet = set.id
                        actions.library.newSet()
                    }
                }
            } else {
                if missingKeys > 0, library.findsKeys {
                    headerKey("Find keys (\(missingKeys))", disabled: library.busy, action: actions.library.findKeys)
                }
                headerKey("Add files", action: actions.library.addFiles)
                headerKey("Add folder", action: actions.library.addFolder)
            }
            SheetIconButton(kind: .info) { actions.setHelp(.library) }
            SheetIconButton(kind: .close) { actions.library.setOpen(false) }
        }
        .frame(height: 40)
    }

    private func headerKey(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        SheetButton(title: title, style: .outline, height: 36, disabled: disabled,
                    face: .avenir(15, weight: .bold), action: action)
    }

    // MARK: Playlists

    private var side: some View {
        VStack(alignment: .leading, spacing: 3) {
            sideLabel("COLLECTION")
            SideItem(icon: nil, badge: true, name: "All tracks", count: library.tracks.count, on: playlist == nil && openSet == nil) { open(nil) }
            if let current = library.currentSet {
                SideItem(icon: nil, iconColour: Palette.played, badge: true, name: "This set", count: current.plays.count, on: isCurrentSet) { open(current.id) }
            }
            let past = library.sets.dropLast().reversed()
            if !past.isEmpty {
                sideLabel("PAST SETS").padding(.top, 8)
                ForEach(Array(past)) { entry in
                    SideItem(icon: "◷", plain: true, name: entry.day, count: entry.plays.count, on: ui.view == entry.id) { open(entry.id) }
                        .accessibilityHint("Set started \(entry.started)")
                }
            }
            HStack {
                sideLabel("PLAYLISTS")
                Spacer(minLength: 0)
                ActionGlyph(glyph: "+", on: false) {
                    let id = actions.library.createPlaylist()
                    open(id)
                    ui.renaming = id
                }
            }
            .padding(.top, 8)
            if library.playlists.isEmpty {
                Para("No playlists yet. Tap + to make one.", .avenir(14, weight: .regular), lineHeight: 1.4).foregroundStyle(Palette.rowDim)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            ForEach(library.playlists) { entry in playlistRow(entry) }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxHeight: .infinity, alignment: .top)
        .box(fill: Color.black.opacity(0.25), border: Color(hex: 0x1F1F22), radius: 3)
        .zIndex(1)
    }

    private func sideLabel(_ text: String) -> some View {
        Label(text, .avenir(12, weight: .bold)).foregroundStyle(Color(hex: 0xA0A0A6)).frame(height: 12)
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
    }

    private func playlistRow(_ entry: ConsoleState.Library.Playlist) -> some View {
        let on = ui.view == entry.id, renaming = ui.renaming == entry.id
        let menuOpen = on && ui.listMenu == entry.id
        return SideItem(icon: "≡", name: entry.name, count: entry.trackIDs.count, on: on, renaming: renaming,
                        rename: { name in actions.library.renamePlaylist(entry.id, name); ui.renaming = nil }) {
            if !renaming { open(entry.id) }
        } accessory: {
            if on && !renaming {
                ActionGlyph(glyph: "⋯", on: menuOpen, size: 32) { setListMenu(menuOpen ? nil : entry.id) }
            }
        }
        .live(snapshot) { item in
            item.contextMenu {
                Button("Rename") { open(entry.id); ui.renaming = entry.id }
                Button("Delete playlist", role: .destructive) { actions.library.deletePlaylist(entry.id) }
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids where library.track(id) != nil { actions.library.addToPlaylist(entry.id, id) }
                return true
            }
        }
        // The menu hangs below the row, so it sits outside the row's context menu and drop target:
        // on iPad those only take touches inside the row, which left Rename and Delete dead.
        // Align it with the 32 pt key just before the playlist count.
        .overlay(alignment: .topTrailing) {
            if menuOpen {
                playlistMenu(entry).fixedSize(horizontal: false, vertical: true)
                    .offset(x: -40, y: 40)
            }
        }
        .zIndex(menuOpen ? 2 : 0)
    }

    /// Rename, or delete on the second tap; the tracks stay in the library.
    private func playlistMenu(_ entry: ConsoleState.Library.Playlist) -> some View {
        let count = entry.trackIDs.count
        return PopMenu(title: entry.name.uppercased(), width: 180) {
            MenuRow(icon: "✎", title: "Rename") { setListMenu(nil); ui.renaming = entry.id }
            MenuRow(icon: "✕", title: ui.confirmDelete ? "Tap again to delete" : "Delete playlist", danger: true, confirm: ui.confirmDelete) {
                if !ui.confirmDelete { ui.confirmDelete = true; return }
                setListMenu(nil)
                actions.library.deletePlaylist(entry.id)
            }
            if ui.confirmDelete {
                Para("Its \(count) \(count == 1 ? "track stays" : "tracks stay") in the library.", .avenir(13, weight: .regular), lineHeight: 1.35)
                    .foregroundStyle(Color(hex: 0x74747B))
                    .padding(EdgeInsets(top: 2, leading: 30, bottom: 6, trailing: 10))
            }
        }
    }

    private func setListMenu(_ id: String?) {
        ui.listMenu = id
        ui.confirmDelete = false
    }

    private func open(_ id: String?) {
        if id != ui.view { setListMenu(nil); ui.confirmNewSet = false }
        ui.view = id
        ui.sort = nil
    }

    // MARK: Tracks

    private func main(_ rows: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            filter
            columns
            list(rows)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filter: some View {
        HStack(spacing: 8) {
            if let keys = keyCodes {
                Text("Key")
                ForEach(keys, id: \.self) { code in
                    CamelotBadge(code: code, selected: code == ui.keyFilter).onTapGesture { pick(code) }
                }
                HStack(spacing: 0) {
                    segment("\(ui.keyFilter) only", on: !ui.compatible) { ui.compatible = false }
                    segment("+ compatible", on: ui.compatible) { ui.compatible = true }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 0.5).stroke(Color(hex: 0x2E2E32), lineWidth: 1))
                SheetButton(title: "Clear", style: .ghost, face: .avenir(16, tracking: 1.6, weight: .bold)) { ui.keyFilter = "" }
            } else {
                Text("All keys").padding(.top, 7)
            }
        }
        .font(Face.avenir(14, weight: .regular).font).foregroundStyle(Color(hex: 0xA0A0A6))
        .frame(height: 40, alignment: keyCodes == nil ? .top : .center)
    }

    private func segment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Face.avenir(14, weight: .regular).font).foregroundStyle(on ? Palette.text : Color(hex: 0xA0A0A6))
                .padding(.horizontal, 10).frame(minHeight: 28)
                .background(on ? Color(hex: 0x26262A) : .clear)
                .overlay(alignment: .bottom) { if on { Palette.led.frame(height: 2) } }
        }
        .buttonStyle(.plain)
    }

    /// TRACK spans art, mark and title. KEY sorts the combined key column by Camelot code.
    private var columns: some View {
        HStack(spacing: 0) {
            ForEach(SortColumn.allCases, id: \.self) { column in
                if column == .name {
                    sortKey(column)
                } else {
                    columnCell(column.width) { sortKey(column) }
                }
            }
            columnCell(Self.moreWidth) { Color.clear }
        }
        .frame(height: 26)
    }

    private var columnFace: Face { .avenir(14, weight: .bold) }

    private func sortKey(_ column: SortColumn) -> some View {
        let on = ui.sort?.column == column
        return Button { sort(by: column) } label: {
            HStack(spacing: 0) {
                Label(column == .time && openSet != nil ? "PLAYED" : column.title, columnFace).foregroundStyle(on ? Palette.rowText : Palette.rowDim)
                if on { Label(ui.sort!.ascending ? " ▲" : " ▼", columnFace).foregroundStyle(Palette.blue) }
            }
            .padding(.leading, column == .name ? 7 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column == .name ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ tracks: [Entry]) -> some View {
        let rows = library.pendingImports.map(Row.pending) + tracks.map(Row.track)
        return GeometryReader { geometry in
            ZStack(alignment: .top) {
                if snapshot {
                    // The rows as they lie, scrolled to the end if asked.
                    let content = CGFloat(rows.count) * Self.rowHeight
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            listRow(entry, index: index)
                        }
                    }
                    .offset(y: ui.scrolledToEnd ? min(0, geometry.size.height - content) : 0)
                    .frame(height: geometry.size.height, alignment: .top)
                    .clipped()
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                                    listRow(entry, index: index).id(entry.id)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onAppear { if ui.scrolledToEnd, let last = rows.last { reader.scrollTo(last.id, anchor: .bottom) } }
                        .onValueChange(of: library.pendingImports.last?.id) { id in
                            if id != nil, let first = library.pendingImports.first { reader.scrollTo(first.id, anchor: .top) }
                        }
                        .onValueChange(of: [ui.view ?? "", ui.query, ui.keyFilter, ui.sort.map { "\($0.column)\($0.ascending)" } ?? ""]) { _ in
                            if let first = rows.first { reader.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
                if rows.isEmpty {
                    Para(library.tracks.isEmpty ? "No tracks yet. Add files or a folder, or drop audio onto a deck."
                         : openSet != nil && ui.query.isEmpty && ui.keyFilter.isEmpty ? "Nothing played yet. A track joins the set after 30 seconds on the master."
                         : !ui.query.isEmpty || !ui.keyFilter.isEmpty ? "Nothing matches that search or key."
                         : "This playlist is empty. Drag tracks onto it, or use ⋯ on a track.", .avenir(16, weight: .regular), lineHeight: 1.3, centred: true)
                        .foregroundStyle(Color(hex: 0x74747B))
                        .padding(.horizontal, 10).padding(.top, 30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private static let rowHeight: CGFloat = 45
    private static let moreWidth: CGFloat = 51
    private static let metadataWidth = SortColumn.allCases.reduce(moreWidth) { $0 + $1.width }

    @ViewBuilder
    private func listRow(_ entry: Row, index: Int) -> some View {
        let odd = index % 2 == 0
        switch entry {
        case .track(let entry): row(entry, odd: odd)
        case .pending(let pending): pendingRow(pending, odd: odd)
        }
    }

    private func pendingRow(_ pending: ConsoleState.Library.PendingImport, odd: Bool) -> some View {
        rowBand(odd: odd) {
            HStack(spacing: 0) {
                RowArt(art: pending.art, url: nil).frame(width: 68, height: Self.rowHeight - 1).clipped()
                RowMark(decks: [], colour: Palette.rowDim, played: false).frame(width: 45)
                Text(pending.title).font(Face.avenir(22).font).foregroundStyle(Palette.rowText)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                columnCell(Self.metadataWidth) {
                    // The whole bar is the progress: blue fills from the left behind the centred label.
                    GeometryReader { geometry in
                        Color(hex: 0x2A2E2F).overlay(alignment: .leading) {
                            Palette.blue.frame(width: geometry.size.width * pending.fraction)
                                .animation(snapshot || reduceMotion ? nil : .easeOut(duration: 0.2), value: pending.fraction)
                        }
                    }
                    .frame(height: 28)
                    .overlay {
                        Label(pending.label.uppercased() + (pending.fraction > 0 ? " \(Int((pending.fraction * 100).rounded()))%" : ""),
                              .avenir(15, weight: .bold, tabular: true))
                            .foregroundStyle(Palette.rowText)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.horizontal, 12)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pending.title)
        .accessibilityValue("\(pending.label), \(pending.fraction.formatted(.percent.precision(.fractionLength(0))))")
    }

    private func rowBand<Content: View>(odd: Bool, selected: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        content().frame(height: Self.rowHeight - 1).padding(.bottom, 1)
            .background(selected ? Palette.blue : Color(hex: odd ? 0x1F2323 : 0x151917))
            .overlay(alignment: .bottom) { Color.black.opacity(0.14).frame(height: 1).allowsHitTesting(false) }
    }

    private func columnCell<Content: View>(_ width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width).frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { Color(hex: 0x414345).frame(width: 1).allowsHitTesting(false) }
    }

    /// `.lib-row`: alternating bands. A playing track's text turns green.
    private func row(_ entry: Entry, odd: Bool) -> some View {
        let track = entry.track
        let decks = state.decks.filter { $0.trackID == track.id }
        let playing = decks.contains(where: \.playing)
        let selected = library.selected == track.id
        let fg = selected ? Palette.rowText : track.missing ? Color(hex: 0x8E9194) : playing ? Palette.playing : Palette.rowText
        let dim = selected ? Palette.rowText : playing ? Palette.playing : Palette.rowDim
        let face = Face.avenir(22, weight: selected ? .demi : .medium)
        let number = Face.avenir(19, weight: .demi, tabular: true)
        return rowBand(odd: odd, selected: selected) {
            HStack(spacing: 0) {
                RowArt(art: track.art, url: track.coverURL).frame(width: 68, height: Self.rowHeight - 1).clipped()
                RowMark(decks: decks, colour: fg, played: library.played.contains(track.id)).frame(width: 45)
                HStack(spacing: 10) {
                    Text(track.title).font(face.font).foregroundStyle(fg).lineLimit(1).truncationMode(.tail)
                    if track.missing { Label("file missing", .avenir(16)).foregroundStyle(dim) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                columnCell(SortColumn.bpm.width) {
                    Label(String(format: "%.1f", track.bpm), .avenir(21, tabular: true)).foregroundStyle(fg)
                }
                columnCell(SortColumn.time.width) { Label(entry.at ?? clock(track.durationSec), number).foregroundStyle(dim) }
                columnCell(SortColumn.key.width) {
                    HStack(spacing: 0) {
                        CamelotBadge(code: track.camelot, selected: !ui.keyFilter.isEmpty && ui.keyFilter == track.camelot, large: true)
                            .onTapGesture { if let code = track.camelot { pick(code) } }
                            .frame(width: 62)
                        Label(keyShort(track.key), .avenir(18, weight: .demi)).foregroundStyle(dim).frame(maxWidth: .infinity)
                    }
                }
                columnCell(SortColumn.rating.width) {
                    Stars(rating: track.rating, size: 19, step: 21, unlit: selected ? Color.white.opacity(0.35) : Color(hex: 0x3B3F40)) {
                        actions.library.rate(track.id, $0)
                    }
                    .frame(height: Self.rowHeight - 1)
                }
                columnCell(Self.moreWidth) {
                    Button { actions.library.setMore(ConsoleState.More(track: track.id)) } label: {
                        HStack(spacing: 3) {
                            ForEach(0..<3) { _ in Circle().fill(fg).frame(width: 4, height: 4) }
                        }
                        .frame(width: Self.moreWidth, height: Self.rowHeight - 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Track details for \(track.title)")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.library.select(track.id) }
        .live(snapshot) { row in
            // A drag picks the row, so the deck it is held over can name it.
            row.draggable({ actions.library.select(track.id); return track.id }()) {
                Text(track.title).font(face.font).padding(8)
            }
        }
    }

    private func pick(_ code: String) { ui.keyFilter = ui.keyFilter == code ? "" : code }

    private func sort(by column: SortColumn) {
        if let sort = ui.sort, sort.column == column { ui.sort = (column, !sort.ascending) } else { ui.sort = (column, true) }
    }
}

/// The library's own view state: what Electron keeps in the component.
/// Snapshots start it in the mockup's playlist screens.
public struct LibraryView: Sendable {
    /// The open playlist, or nil for the whole library.
    public var view: String?
    public var query = ""
    var sort: (column: SortColumn, ascending: Bool)?
    public var keyFilter = ""
    public var compatible = true
    /// The playlist whose ⋯ menu is open, and whether its delete waits for a second tap.
    public var listMenu: String?
    public var confirmDelete = false
    public var renaming: String?
    /// NEW SET waits for a second tap.
    public var confirmNewSet = false
    /// NEW SET was pressed: THIS SET opens the new set once it exists.
    var followingSet: String?
    /// Start scrolled to the last row.
    public var scrolledToEnd = false
    public init(view: String? = nil, listMenu: String? = nil, confirmDelete: Bool = false, renaming: String? = nil,
                scrolledToEnd: Bool = false) {
        self.view = view; self.listMenu = listMenu; self.confirmDelete = confirmDelete; self.renaming = renaming
        self.scrolledToEnd = scrolledToEnd
    }
}

enum SortColumn: Int, CaseIterable {
    case name, bpm, time, key, rating

    var title: String { ["TRACK", "BPM", "TIME", "KEY", "RATING"][rawValue] }
    /// The title takes the remaining width after the other columns.
    var width: CGFloat { [0, 71, 64, 103, 116][rawValue] }

    func compare(_ a: ConsoleState.Library.Track, _ b: ConsoleState.Library.Track) -> ComparisonResult {
        func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        switch self {
        case .name: return order(a.title.lowercased(), b.title.lowercased())
        case .key: return order(Camelot.rank(a.camelot), Camelot.rank(b.camelot))
        case .bpm: return order(a.bpm, b.bpm)
        case .time: return order(a.durationSec.rounded(.down), b.durationSec.rounded(.down))
        // Most stars first.
        case .rating: return order(b.rating ?? 0, a.rating ?? 0)
        }
    }
}

/// "F minor" as the track list writes it: Fm.
func keyShort(_ key: String?) -> String {
    (key ?? "").replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: " minor", with: "m")
        .replacingOccurrences(of: " major", with: "")
}

/// `src/shared/camelot.ts`: parsing, sort rank and harmonic neighbours.
enum Camelot {
    static func parse(_ code: String) -> (number: Int, ring: Character)? {
        let code = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let ring = code.last, ring == "A" || ring == "B", let number = Int(code.dropLast()), (1...12).contains(number) else { return nil }
        return (number, ring)
    }
    /// 1A, 1B, 2A … 12B, then anything unknown.
    static func rank(_ code: String?) -> Int {
        guard let code, let key = parse(code) else { return 1000 }
        return key.number * 2 + (key.ring == "A" ? 0 : 1)
    }
    /// The key, one step either way round the wheel, and its relative.
    static func compatible(_ code: String) -> [String] {
        guard let key = parse(code) else { return [code] }
        let wrap = { (n: Int) in (n + 11) % 12 + 1 }
        let other: Character = key.ring == "A" ? "B" : "A"
        return ["\(key.number)\(key.ring)", "\(wrap(key.number - 1))\(key.ring)", "\(wrap(key.number + 1))\(key.ring)", "\(key.number)\(other)"]
    }
}

/// `.cam`: a Camelot key on its wheel colour.
struct CamelotBadge: View {
    let code: String?
    var selected = false
    /// `.lib-row .cam`: the track list's larger badge.
    var large = false

    var body: some View {
        let colour = camelotColour(code) ?? Color(hex: 0x74747B)
        Label(code ?? "—", .avenir(large ? 19 : 16, tracking: large ? 0.38 : 0.32, weight: .heavy)).foregroundStyle(Color(hex: 0x0B0913))
            .frame(height: large ? 19 : 16)
            .padding(.horizontal, large ? 5 : 9).frame(minWidth: large ? 47 : 44).frame(height: large ? 29 : 28)
            .background(RoundedRectangle(cornerRadius: 2).fill(colour))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 2).inset(by: 1).stroke(Color.white, lineWidth: 2)
                    RoundedRectangle(cornerRadius: 4).inset(by: -1).stroke(colour, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
    }
}

/// `.lib-side-item`: an entry in the playlist column.
private struct SideItem<Accessory: View>: View {
    /// A glyph, or nil for the music note.
    let icon: String?
    var iconColour = Color(hex: 0x74747B)
    /// A glyph item that is not a playlist: its count reads plain, like a past set's.
    var plain = false
    /// All tracks and This set: not playlists, but they carry the playlists' blue count badge.
    var badge = false
    let name: String
    let count: Int
    let on: Bool
    var renaming = false
    var rename: (String) -> Void = { _ in }
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let isPlaylist = icon != nil && !plain
        let blueCount = isPlaylist || badge
        HStack(spacing: 9) {
            Group {
                if let icon { Text(icon).font(Face.avenir(16, weight: .regular).font) } else { NoteIcon(height: 18) }
            }
            .foregroundStyle(iconColour).frame(width: 16)
            if renaming {
                RenameField(name: name, commit: rename)
            } else {
                Text(name).font(Face.avenir(16, weight: .regular).font).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            accessory
            if blueCount {
                Label(String(count), .avenir(16, weight: .bold, tabular: true)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 4).frame(minWidth: 30).frame(height: 27)
                    .background(Palette.blue)
            } else {
                Label(String(count), .avenir(14, weight: .bold)).foregroundStyle(Palette.rowDim).frame(height: 14)
            }
        }
        .foregroundStyle(on || isPlaylist ? Palette.text : Color(hex: 0xA0A0A6))
        .padding(.leading, 11).padding(.trailing, blueCount ? 1 : 9)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color(hex: 0x161617) : .clear))
        .overlay(alignment: .leading) { if on { Palette.blue.frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

extension SideItem where Accessory == EmptyView {
    init(icon: String?, iconColour: Color = Color(hex: 0x74747B), plain: Bool = false, badge: Bool = false, name: String, count: Int,
         on: Bool, action: @escaping () -> Void) {
        self.init(icon: icon, iconColour: iconColour, plain: plain, badge: badge, name: name, count: count, on: on, action: action) {
            EmptyView()
        }
    }
}

/// `.lib-side-input`: the playlist's name, editable; Return or leaving it saves.
private struct RenameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.consoleSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            Text(name).font(Face.avenir(16, weight: .regular).font).foregroundStyle(Palette.text).lineLimit(1)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).frame(height: 28)
                .box(fill: Color(hex: 0x141416), border: Palette.led, radius: 2)
                .overlay(RoundedRectangle(cornerRadius: 3).inset(by: -2).stroke(Color(.sRGB, red: 1, green: 138 / 255, blue: 0, opacity: 0.14), lineWidth: 2))
        } else {
            field
        }
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(Face.avenir(16, weight: .regular).font).foregroundStyle(Palette.text)
            .focused($focused)
            .onSubmit { commit(text) }
            .padding(.horizontal, 8).frame(height: 28)
            .box(fill: Color(hex: 0x141416), border: Palette.led, radius: 2)
            .overlay(RoundedRectangle(cornerRadius: 3).inset(by: -2).stroke(Color(.sRGB, red: 1, green: 138 / 255, blue: 0, opacity: 0.14), lineWidth: 2))
            .onAppear { text = name; focused = true }
            .onValueChange(of: focused) { focused in if !focused { commit(text) } }
#if os(macOS)
            .onExitCommand { commit(name) }
#endif
    }
}

/// `.lib-actions button`: a 34 pt glyph key.
private struct ActionGlyph: View {
    let glyph: String
    let on: Bool
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(glyph).font(.system(size: 20)).foregroundStyle(on ? Palette.text : Color(hex: 0xA0A0A6))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.white.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// `.lib-menu`: a small menu under its key.
private struct PopMenu<Content: View>: View {
    let title: String
    /// A fixed width wraps the menu's note; otherwise it grows with its rows.
    var width: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, .avenir(12, tracking: 0.96, weight: .bold)).foregroundStyle(Palette.silk).frame(height: 12)
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
            content
        }
        .padding(7)
        .frame(minWidth: width == nil ? 180 : nil, alignment: .leading)
        .frame(width: width)
        .box(fill: Color(hex: 0x1C1C1F), border: Color(hex: 0x3A3A40), radius: 3)
        .compositingGroup()
        .shadow(color: .black.opacity(0.6), radius: 18, y: 16)
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    var danger = false
    var confirm = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(icon).foregroundStyle(danger ? Palette.red : Palette.led).frame(width: 16)
                Text(title).foregroundStyle(confirm ? Color(hex: 0xFFD0C8) : danger ? Color(hex: 0xFF8A7A) : Color(hex: 0xA0A0A6))
            }
            .font(Face.avenir(16, weight: .regular).font)
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(confirm ? mix(0xE8402F, 0.18, 0x1C1C1F) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// `.lib-mark`: the note, or the decks holding the track, stacked if both.
private struct RowMark: View {
    let decks: [ConsoleState.Deck]
    let colour: Color
    /// Played in the current set: the note turns orange until NEW SET.
    let played: Bool

    var body: some View {
        if decks.isEmpty {
            NoteIcon(height: 25).foregroundStyle(played ? Palette.played : colour)
                .accessibilityLabel(played ? "Played in this set" : "")
        } else {
            VStack(spacing: 2) {
                ForEach(decks, id: \.id) { deck in DeckBadge(letter: deck.id, playing: deck.playing, stacked: decks.count > 1) }
            }
        }
    }
}

/// `.lib-deck`: white when loaded, a green arrow when playing.
private struct DeckBadge: View {
    let letter: String
    let playing: Bool
    let stacked: Bool

    var body: some View {
        let width: CGFloat = stacked ? 26 : playing ? 30 : 29
        let height: CGFloat = stacked ? 19 : 29
        Label(letter, .avenir(stacked ? 14 : 20, weight: .bold)).foregroundStyle(Color(hex: 0x0B0913))
            .frame(height: stacked ? 14 : 20)
            // The arrow's point takes its share of the width.
            .padding(.trailing, playing ? (stacked ? 4 : 5) : 0)
            .frame(width: width, height: height)
            .background { if playing { ArrowTag().fill(Palette.playing) } else { RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xF5F5F6)) } }
    }
}

/// `clip-path: polygon(0 0, 72% 0, 100% 50%, 72% 100%, 0 100%)`.
private struct ArrowTag: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: rect.origin)
            path.addLine(to: CGPoint(x: rect.width * 0.72, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
    }
}

/// `.lib-art`: the track's cover, full width and cropped to fit, or its placeholder.
struct RowArt: View {
    let art: ConsoleState.Art?
    let url: URL?
    @State private var cover: CGImage?

    var body: some View {
        ZStack {
            switch art {
            case .split(let first, let second)? where first == second: Color(hex: first)
            case .split(let first, let second)?:
                LinearGradient(stops: [.init(color: Color(hex: first), location: 0), .init(color: Color(hex: first), location: 0.55),
                                       .init(color: Color(hex: second), location: 0.55), .init(color: Color(hex: second), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case .cover(let picture)?:
                Image(decorative: picture.image, scale: 1).resizable().scaledToFill()
            case nil: Color(hex: 0x393F40)
            }
            if let cover { Image(decorative: cover, scale: 1).resizable().scaledToFill() }
        }
        .task(id: url) {
            if let url { cover = await RowCovers.shared.image(url) } else { cover = nil }
        }
    }
}

/// Row covers read from disk as their rows appear, so a big crate only holds
/// the ones it has shown recently.
actor RowCovers {
    static let shared = RowCovers()
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let cache: NSCache<NSURL, Box> = {
        let cache = NSCache<NSURL, Box>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    func image(_ url: URL) -> CGImage? {
        if let held = cache.object(forKey: url as NSURL) { return held.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        cache.setObject(Box(image), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// MORE, the track details: the user's drawing (`mockup/song.info.svg`, 636 × 400), placed at
/// the drawing's own coordinates. The title and exit across the top; the cover with re-analyse and
/// remove under it, icons only, each asking twice (the first tap fills its ring); a row each for
/// the artists, album, genre, BPM, key, length and stars; then the playlists as chips.
struct MoreSheet: View {
    let track: ConsoleState.Library.Track
    let more: ConsoleState.More
    let state: ConsoleState
    let actions: ConsoleActions
    @Environment(\.consoleSnapshot) private var snapshot

    /// The chips' grey, their fill, and the text's white.
    private static let grey = Color(hex: 0x75757C), fill = Color(hex: 0x151916), white = Color(hex: 0xF2F1F3)
    /// `.more-rows`: where the rows start, their width and each row's height.
    private static let rows = CGPoint(x: 185.85, y: 69.57), rowWidth: CGFloat = 434.31, rowHeight: CGFloat = 37.25
    /// Where the chips start: everything above is placed by hand.
    private static let chipsTop: CGFloat = 351.27

    private var library: ConsoleState.Library { state.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text(track.title).font(Face.avenir(23, weight: .demi).font).foregroundStyle(Self.white)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 583.9 - 12 - 28.72, height: 38, alignment: .leading)
                    .offset(x: 28.72, y: 12.75)
                ExitButton { actions.library.setMore(nil) }.offset(x: 583.9, y: 12.75)
                RowArt(art: track.art, url: track.coverURL).frame(width: 150, height: 150).clipped()
                    .offset(x: 16.24, y: 69.57)
                keys
                rowsView.offset(x: Self.rows.x, y: Self.rows.y)
            }
            .frame(width: 636, height: Self.chipsTop, alignment: .topLeading)
            playlists.padding(.leading, 183.31).padding(.trailing, 16).padding(.bottom, 21)
        }
        .frame(width: 636, alignment: .topLeading)
        .frame(minHeight: 400, alignment: .top)
        .box(fill: Color(hex: 0x040405), border: Color(hex: 0x231F20), radius: 3, width: 2)
        .compositingGroup()
        .shadow(color: .black.opacity(0.8), radius: 45, y: 34)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    // MARK: Re-analyse and remove

    @ViewBuilder private var keys: some View {
        if library.reanalyzes {
            RingKey(glyph: .reanalyse, colour: Color(hex: 0xD4E108), armed: more.reanalysing,
                    label: more.reanalysing ? "Tap again to re-analyse" : "Re-analyse") {
                if more.reanalysing {
                    actions.library.setMore(nil)
                    actions.library.reanalyze(track.id)
                } else {
                    actions.library.setMore(ConsoleState.More(track: track.id, reanalysing: true))
                }
            }
            .allowsHitTesting(!library.busy)
            .offset(x: 35.14, y: 247.72)
        }
        if library.removes {
            RingKey(glyph: .remove, colour: Color(hex: 0xEC1C24), armed: more.confirming,
                    label: more.confirming ? "Tap again to remove" : "Remove from library") {
                if more.confirming {
                    actions.library.setMore(nil)
                    actions.library.remove(track.id)
                } else {
                    actions.library.setMore(ConsoleState.More(track: track.id, confirming: true))
                }
            }
            .offset(x: 110.72, y: 247.72)
        }
    }

    // MARK: The rows

    private var rowsView: some View {
        VStack(spacing: 0) {
            row(0, .artist, height: 28) { value(joined(track.artist, track.remixer)) }
            row(1, .album, height: 26, faded: true) { value(track.album) }
            row(2, .genre, height: 25) { value(joined(track.genre, track.subgenre)) }
            row(3, .bpm, height: 23) { value(String(format: "%.1f", track.bpm)) }
            row(4, .key, height: 23, faded: true) {
                if let code = track.camelot {
                    HStack(spacing: 10) {
                        Label(code, .cond(21)).foregroundStyle(Color(hex: 0x0F0E14))
                            .padding(.horizontal, 5).frame(minWidth: 44.07).frame(height: 27.44)
                            .background(RoundedRectangle(cornerRadius: 2.3).fill(camelotColour(code) ?? Self.grey))
                            .padding(.leading, 1.45)
                        value(keyShort(track.key))
                    }
                }
            }
            row(5, .length, height: 26) { value(clock(track.durationSec)) }
            row(6, .rating, height: 26) {
                StarRow(rating: track.rating, step: 25, rate: { actions.library.rate(track.id, $0) }) { lit in
                    if lit {
                        StarShape().fill(Self.white).frame(width: 23, height: 21.9)
                    } else {
                        StarShape().stroke(Self.white, lineWidth: 1.2).frame(width: 23, height: 21.9)
                    }
                }
                .frame(height: Self.rowHeight)
                .padding(.leading, -2.75)
            }
        }
        .frame(width: Self.rowWidth)
    }

    private func joined(_ first: String, _ rest: String) -> String {
        first + (!first.isEmpty && !rest.isEmpty ? " • " : "") + rest
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Face.avenir(21).font).foregroundStyle(Self.white).lineLimit(1).truncationMode(.tail)
    }

    /// `.more-row`: the icon centred in a 53.34-wide cell, then the value; the rows alternate greys.
    private func row<Value: View>(_ index: Int, _ glyph: ConsoleGlyph, height: CGFloat, faded: Bool = false,
                                  @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 0) {
            glyph.fill(Palette.blue.opacity(faded ? 0.85 : 1))
                .frame(width: height * glyph.size.width / glyph.size.height, height: height)
                .frame(width: 53.34)
            value().padding(.leading, -1.45)
            Spacer(minLength: 0)
        }
        .frame(width: Self.rowWidth, height: Self.rowHeight)
        .background(index % 2 == 0 ? Color(hex: 0x202323) : Color(hex: 0x151916))
    }

    // MARK: Playlists

    /// `.more-lists`: as tall as its rows of chips, up to two (64 pt); more scroll.
    @ViewBuilder private var playlists: some View {
        let height = min(64, chipsHeight)
        if snapshot || chipsHeight <= 64 {
            chips.frame(height: height, alignment: .top)
        } else {
            ScrollView(.vertical, showsIndicators: false) { chips }.frame(height: height)
        }
    }

    /// The chips' rows, wrapped as `ChipFlow` wraps them in the 436.69 pt beside the cover.
    private var chipsHeight: CGFloat {
        let face = Face.cond(18.6, weight: .demi), room: CGFloat = 636 - 183.31 - 16
        var x: CGFloat = 0, rows = library.playlists.isEmpty ? 0 : 1
        for entry in library.playlists {
            let width = max(75.9, face.width(of: entry.name.uppercased()) + 17)
            if x > 0, x + width > room { x = 0; rows += 1 }
            x += width + 13.5
        }
        return CGFloat(rows) * 27.8 + CGFloat(max(0, rows - 1)) * 8
    }

    private var chips: some View {
        ChipFlow(spacing: 13.5) {
            ForEach(library.playlists) { entry in
                let member = entry.trackIDs.contains(track.id)
                Button {
                    if member { actions.library.removeFromPlaylist(entry.id, track.id) } else { actions.library.addToPlaylist(entry.id, track.id) }
                } label: {
                    Label(entry.name.uppercased(), .cond(18.6, weight: .demi))
                        .foregroundStyle(member ? Palette.blue : Self.grey)
                        .padding(.horizontal, 8.5).frame(minWidth: 75.9).frame(height: 27.8)
                        .box(fill: Self.fill, border: member ? Palette.blue : Self.grey, radius: 3, width: 1.6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// `.more-actions button`: a ring 39.8 across with its icon at 85%; armed, the ring fills
/// and the icon goes dark.
private struct RingKey: View {
    let glyph: ConsoleGlyph
    let colour: Color
    let armed: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph.fill(armed ? Color(hex: 0x040405) : colour.opacity(0.85))
                .frame(width: glyph.size.width, height: glyph.size.height)
                .frame(width: 39.8, height: 39.8)
                .background(Circle().fill(armed ? colour : .clear))
                .overlay(Circle().inset(by: 1.05).stroke(colour, lineWidth: 2.1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// `.more-lists`: buttons left to right, wrapping, `spacing` apart and 8 between rows.
private struct ChipFlow: SwiftUI.Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return CGSize(width: proposal.width ?? 0, height: arrange(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spots = arrange(subviews, width: bounds.width).spots
        for (subview, spot) in zip(subviews, spots) {
            subview.place(at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (spots: [CGPoint], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, spots: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + 8; row = 0 }
            spots.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
        }
        return (spots, y + row)
    }
}

/// `.lib-stars`: five stars. Tap one to rate; tap the top lit star again to clear.
struct Stars: View {
    let rating: Int?
    let size: CGFloat
    /// Each star's width, which is its tap target across.
    let step: CGFloat
    let unlit: Color
    let rate: (Int?) -> Void

    var body: some View {
        StarRow(rating: rating, step: step, rate: rate) { lit in
            Text("★").font(.system(size: size)).foregroundStyle(lit ? Palette.star : unlit)
        }
    }
}

/// Five tap targets `step` wide, each drawn by `star(lit)`, read out as one rating.
struct StarRow<Star: View>: View {
    let rating: Int?
    let step: CGFloat
    let rate: (Int?) -> Void
    @ViewBuilder let star: (Bool) -> Star

    var body: some View {
        let lit = rating ?? 0
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { index in
                Button { rate(index == lit ? nil : index) } label: {
                    star(index <= lit)
                        .frame(width: step).frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(lit == 0 ? "Not rated" : "\(lit) of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rate(min(5, lit + 1))
            case .decrement: rate(lit <= 1 ? nil : lit - 1)
            @unknown default: break
            }
        }
    }
}

/// `.more-stars polygon`: the drawing's five-pointed star, 23 across, filled when lit.
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The mockup's points: radii 12.1 and 4.83 about (12.1, 12.1), in a 23 × 21.9 box from x 0.6.
        let scale = min(rect.width / 23, rect.height / 21.9)
        var path = Path()
        for n in 0..<10 {
            let radius: CGFloat = n % 2 == 1 ? 4.83 : 12.1, angle = CGFloat.pi * CGFloat(n) / 5
            let point = CGPoint(x: rect.midX + (12.1 + radius * sin(angle) - 0.6 - 11.5) * scale,
                                y: rect.midY + (12.1 - radius * cos(angle) - 10.95) * scale)
            if n == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
