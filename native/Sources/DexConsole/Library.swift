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

    var body: some View {
        let rows = self.rows
        let total = playlist?.trackIDs.count ?? library.tracks.count
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
        .onValueChange(of: library.playlists.map(\.id)) { ids in
            // A deleted playlist drops the view back to the whole library.
            if let view = ui.view, !ids.contains(view) { ui.view = nil }
        }
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case track(ConsoleState.Library.Track)
        case pending(ConsoleState.Library.PendingImport)

        var id: String {
            switch self {
            case .track(let track): track.id
            case .pending(let pending): pending.id
            }
        }
    }

    /// `rows` in Sheets.tsx: the view's tracks, by key and search, then sorted.
    private var rows: [ConsoleState.Library.Track] {
        let needle = ui.query.trimmingCharacters(in: .whitespaces).lowercased()
        let byID = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let base = playlist.map { $0.trackIDs.compactMap { byID[$0] } }
            ?? library.tracks.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        let keys = keyCodes
        let list = base.filter { track in
            if let keys, !keys.contains(track.camelot ?? "") { return false }
            if needle.isEmpty { return true }
            if Camelot.parse(needle.uppercased()) != nil { return track.camelot == needle.uppercased() }
            return "\(track.name) \(track.key ?? "") \(track.camelot ?? "") \(String(format: "%.1f", track.bpm))".lowercased().contains(needle)
        }
        guard let sort = ui.sort else { return list }
        return list.sorted { a, b in
            let order = sort.column.compare(a, b)
            if order != .orderedSame { return (order == .orderedAscending) == (sort.ascending) }
            return a.title.localizedCompare(b.title) == .orderedAscending
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
            Text((playlist?.name ?? "Library").uppercased())
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
            if missingKeys > 0, library.findsKeys {
                headerKey("Find keys (\(missingKeys))", disabled: library.busy, action: actions.library.findKeys)
            }
            headerKey("Add files", action: actions.library.addFiles)
            headerKey("Add folder", action: actions.library.addFolder)
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
            SideItem(icon: nil, name: "All tracks", count: library.tracks.count, on: playlist == nil) { open(nil) }
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
        if id != ui.view { setListMenu(nil) }
        ui.view = id
        ui.sort = nil
    }

    // MARK: Tracks

    private func main(_ rows: [ConsoleState.Library.Track]) -> some View {
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
                Label(column.title, columnFace).foregroundStyle(on ? Palette.rowText : Palette.rowDim)
                if on { Label(ui.sort!.ascending ? " ▲" : " ▼", columnFace).foregroundStyle(Palette.blue) }
            }
            .padding(.leading, column == .name ? 7 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column == .name ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ tracks: [ConsoleState.Library.Track]) -> some View {
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
        case .track(let track): row(track, odd: odd)
        case .pending(let pending): pendingRow(pending, odd: odd)
        }
    }

    private func pendingRow(_ pending: ConsoleState.Library.PendingImport, odd: Bool) -> some View {
        rowBand(odd: odd) {
            HStack(spacing: 0) {
                RowArt(art: pending.art, url: nil).frame(width: 68, height: Self.rowHeight - 1).clipped()
                RowMark(decks: [], colour: Palette.rowDim).frame(width: 45)
                Text(pending.title).font(Face.avenir(22).font).foregroundStyle(Palette.rowText)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                columnCell(Self.metadataWidth) {
                    HStack(spacing: 12) {
                        Label(pending.label.uppercased(), .avenir(13, weight: .bold))
                            .foregroundStyle(Palette.rowDim).frame(width: 100, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(Color(hex: 0x5C6162))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Palette.blue).frame(width: geometry.size.width * pending.fraction)
                                        .animation(snapshot || reduceMotion ? nil : .easeOut(duration: 0.2), value: pending.fraction)
                                }
                        }
                        .frame(height: 4)
                    }
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
    private func row(_ track: ConsoleState.Library.Track, odd: Bool) -> some View {
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
                RowMark(decks: decks, colour: fg).frame(width: 45)
                HStack(spacing: 10) {
                    Text(track.title).font(face.font).foregroundStyle(fg).lineLimit(1).truncationMode(.tail)
                    if track.missing { Label("file missing", .avenir(16)).foregroundStyle(dim) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                columnCell(SortColumn.bpm.width) {
                    Label(String(format: "%.1f", track.bpm), .avenir(21, tabular: true)).foregroundStyle(fg)
                }
                columnCell(SortColumn.time.width) { Label(clock(track.durationSec), number).foregroundStyle(dim) }
                columnCell(SortColumn.key.width) {
                    HStack(spacing: 0) {
                        CamelotBadge(code: track.camelot, selected: !ui.keyFilter.isEmpty && ui.keyFilter == track.camelot, large: true)
                            .onTapGesture { if let code = track.camelot { pick(code) } }
                            .frame(width: 62)
                        Label(keyShort(track.key), .avenir(18, weight: .demi)).foregroundStyle(dim).frame(maxWidth: .infinity)
                    }
                }
                columnCell(SortColumn.grid.width) {
                    Label("\(Int((track.confidence * 100).rounded()))%" + (track.gridUncertain ? "?" : ""), number)
                        .foregroundStyle(track.gridUncertain ? Color(hex: 0xFFB455) : dim)
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
    /// Start scrolled to the last row.
    public var scrolledToEnd = false
    public init(view: String? = nil, listMenu: String? = nil, confirmDelete: Bool = false, renaming: String? = nil,
                scrolledToEnd: Bool = false) {
        self.view = view; self.listMenu = listMenu; self.confirmDelete = confirmDelete; self.renaming = renaming
        self.scrolledToEnd = scrolledToEnd
    }
}

enum SortColumn: Int, CaseIterable {
    case name, bpm, time, key, grid

    var title: String { ["TRACK", "BPM", "TIME", "KEY", "GRID"][rawValue] }
    /// The title takes the remaining width after the other columns.
    var width: CGFloat { [0, 71, 64, 103, 67][rawValue] }

    func compare(_ a: ConsoleState.Library.Track, _ b: ConsoleState.Library.Track) -> ComparisonResult {
        func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        switch self {
        case .name: return order(a.title.lowercased(), b.title.lowercased())
        case .key: return order(Camelot.rank(a.camelot), Camelot.rank(b.camelot))
        case .bpm: return order(a.bpm, b.bpm)
        case .time: return order(a.durationSec.rounded(.down), b.durationSec.rounded(.down))
        case .grid: return order((a.confidence * 100).rounded(), (b.confidence * 100).rounded())
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
    let name: String
    let count: Int
    let on: Bool
    var renaming = false
    var rename: (String) -> Void = { _ in }
    let action: () -> Void
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let isPlaylist = icon != nil
        HStack(spacing: 9) {
            Group {
                if let icon { Text(icon).font(Face.avenir(16, weight: .regular).font) } else { NoteIcon(height: 18) }
            }
            .foregroundStyle(Color(hex: 0x74747B)).frame(width: 16)
            if renaming {
                RenameField(name: name, commit: rename)
            } else {
                Text(name).font(Face.avenir(16, weight: .regular).font).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            accessory
            if isPlaylist {
                Label(String(count), .avenir(16, weight: .bold, tabular: true)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 4).frame(minWidth: 30).frame(height: 27)
                    .background(Palette.blue)
            } else {
                Label(String(count), .avenir(14, weight: .bold)).foregroundStyle(Palette.rowDim).frame(height: 14)
            }
        }
        .foregroundStyle(on || isPlaylist ? Palette.text : Color(hex: 0xA0A0A6))
        .padding(.leading, 11).padding(.trailing, isPlaylist ? 1 : 9)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color(hex: 0x161617) : .clear))
        .overlay(alignment: .leading) { if on { Palette.blue.frame(width: 4).clipShape(RoundedRectangle(cornerRadius: 2)) } }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

extension SideItem where Accessory == EmptyView {
    init(icon: String?, name: String, count: Int, on: Bool, action: @escaping () -> Void) {
        self.init(icon: icon, name: name, count: count, on: on, action: action) { EmptyView() }
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

    var body: some View {
        if decks.isEmpty {
            NoteIcon(height: 25).foregroundStyle(colour)
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

/// MORE: what the file's tags and the analysis know, its playlists, re-analyse
/// and remove. Removing asks twice, as deleting a playlist does.
struct MoreSheet: View {
    let track: ConsoleState.Library.Track
    let more: ConsoleState.More
    let state: ConsoleState
    let actions: ConsoleActions
    @Environment(\.consoleSnapshot) private var snapshot

    /// `.more-fields`: Album, Genre, BPM, Key, Length, Released.
    private static let columns: [CGFloat] = [306, 200, 111, 123, 107, 98]
    /// Its label-grey, and the keys' and playlist buttons' fill.
    private static let grey = Color(hex: 0x75757B), fill = Color(hex: 0x161917)

    private var library: ConsoleState.Library { state.library }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RowArt(art: track.art, url: track.coverURL).frame(width: 148, height: 148).clipped()
                .offset(x: 33, y: 23)
            keys.frame(width: 780, alignment: .trailing).offset(x: 198, y: 23)
            names.frame(width: 780, alignment: .leading).offset(x: 198, y: 80)
            fields.offset(x: 33, y: 192)
            playlists.frame(width: 945, alignment: .leading).offset(x: 33, y: 287)
        }
        .frame(width: 1000, height: 352, alignment: .topLeading)
        .box(fill: Color(hex: 0x030305), border: Palette.blue, radius: 4, width: 2)
        .compositingGroup()
        .shadow(color: .black.opacity(0.8), radius: 45, y: 34)
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var keys: some View {
        HStack(spacing: 20) {
            if library.removes {
                MoreKey(title: more.confirming ? "Tap again to remove" : "Remove from library", colour: Palette.red,
                        fill: more.confirming ? mix(0xE8402F, 0.22, 0x111113) : Self.fill) {
                    Text("X").font(Face.avenir(19, weight: .bold).font).fixedSize()
                } action: {
                    if more.confirming {
                        actions.library.setMore(nil)
                        actions.library.remove(track.id)
                    } else {
                        actions.library.setMore(ConsoleState.More(track: track.id, confirming: true))
                    }
                }
            }
            if library.reanalyzes {
                MoreKey(title: more.reanalysing ? "Tap again to re-analyse" : "Re-analyse", colour: Palette.outlineYellow,
                        fill: more.reanalysing ? mix(0xDBE22D, 0.22, 0x111113) : Self.fill, leading: 10, spacing: 7) {
                    Text("↻").font(.custom("HelveticaNeue", fixedSize: 28)).fixedSize().frame(width: 19, height: 16).offset(y: -2)
                } action: {
                    if more.reanalysing {
                        actions.library.setMore(nil)
                        actions.library.reanalyze(track.id)
                    } else {
                        actions.library.setMore(ConsoleState.More(track: track.id, reanalysing: true))
                    }
                }
                .allowsHitTesting(!library.busy)
            }
            SheetIconButton(kind: .close) { actions.library.setMore(nil) }
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Track").font(Face.avenir(17).font).foregroundStyle(Self.grey).frame(height: 20)
            Text(track.title).font(Face.avenir(25, weight: .demi).font).foregroundStyle(Palette.rowText)
                .lineLimit(1).truncationMode(.tail).frame(height: 34).padding(.top, 7)
            (Text("Artists: ").foregroundColor(Self.grey) + Text(joined(track.artist, track.remixer)).foregroundColor(Palette.rowText))
                .font(Face.avenir(17).font).lineLimit(1).truncationMode(.tail).frame(height: 20).padding(.top, 5)
        }
    }

    private func joined(_ first: String, _ rest: String) -> String {
        first + (!first.isEmpty && !rest.isEmpty ? " • " : "") + rest
    }

    private var fields: some View {
        HStack(spacing: 0) {
            field(0, "Album") { value(track.album) }
            field(1, "Genre") { value(joined(track.genre, track.subgenre)) }
            field(2, "BPM") { value(String(format: "%.1f", track.bpm)) }
            field(3, "Key") {
                if track.camelot != nil {
                    HStack(spacing: 7) {
                        Label(track.camelot ?? "", .cond(20)).foregroundStyle(Color(hex: 0x0B0913))
                            .frame(minWidth: 36).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 2).fill(camelotColour(track.camelot) ?? Self.grey))
                        value(keyShort(track.key))
                    }
                }
            }
            field(4, "Length") { value(clock(track.durationSec)) }
            field(5, "Released") { value(track.release).fixedSize() }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(Face.avenir(17).font).foregroundStyle(Palette.rowText).lineLimit(1).truncationMode(.tail)
    }

    /// `.more-field`: a label over its value, ruled off from the one before.
    private func field<Value: View>(_ index: Int, _ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Face.avenir(17).font).foregroundStyle(Self.grey).frame(height: 18)
            value().frame(height: 18)
        }
        .padding(.top, 1)
        .padding(.leading, index == 0 ? 0 : index == 1 ? 13 : 12)
        .padding(.trailing, index == 0 ? 12 : 0)
        .frame(width: Self.columns[index], height: 49, alignment: .topLeading)
        .overlay(alignment: .leading) { if index > 0 { Color(hex: 0x68686D).frame(width: 1) } }
    }

    private var playlists: some View {
        HStack(alignment: .top, spacing: 26) {
            Label("PLAYLISTS", .avenir(22, weight: .bold)).foregroundStyle(Self.grey).frame(height: 28)
            if snapshot {
                chips.frame(height: 64, alignment: .top)
            } else {
                ScrollView(.vertical, showsIndicators: false) { chips }.frame(height: 64, alignment: .top)
            }
        }
    }

    private var chips: some View {
        ChipFlow {
            ForEach(library.playlists) { entry in
                let member = entry.trackIDs.contains(track.id)
                Button {
                    if member { actions.library.removeFromPlaylist(entry.id, track.id) } else { actions.library.addToPlaylist(entry.id, track.id) }
                } label: {
                    Label(entry.name.uppercased(), .cond(19, tracking: 0.19, weight: .medium))
                        .foregroundStyle(member ? Palette.blue : Self.grey)
                        .padding(.horizontal, 10).frame(height: 28)
                        .box(fill: Self.fill, border: member ? Palette.blue : Self.grey, radius: 3, width: 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// `.more-actions .btn`: an outlined key, 36 high, with an optional glyph.
private struct MoreKey<Glyph: View>: View {
    let title: String
    let colour: Color
    let fill: Color
    var leading: CGFloat = 15
    var spacing: CGFloat = 6
    @ViewBuilder let glyph: Glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                glyph
                Label(title.uppercased(), .cond(18, tracking: 0.18, weight: .demi)).frame(height: 18)
            }
            .foregroundStyle(colour)
            .offset(y: -1)
            .padding(.leading, leading).padding(.trailing, 15)
            .frame(height: 36)
            .box(fill: fill, border: colour, radius: 4, width: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `.more-lists > div`: buttons left to right, wrapping, 12 apart and 8 between rows.
private struct ChipFlow: SwiftUI.Layout {
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
            x += size.width + 12
            row = max(row, size.height)
        }
        return (spots, y + row)
    }
}
