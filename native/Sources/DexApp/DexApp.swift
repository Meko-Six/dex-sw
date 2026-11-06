import SwiftUI
import DexAudio
import DexConsole
import UniformTypeIdentifiers

@main
struct DexNativeApp: App {
    @StateObject private var library: NativeLibrary
    @StateObject private var mixer: NativeMixer
    @StateObject private var console: ConsoleModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let library = NativeLibrary()
        let mixer = NativeMixer(library: library)
        _library = StateObject(wrappedValue: library)
        _mixer = StateObject(wrappedValue: mixer)
        _console = StateObject(wrappedValue: ConsoleModel(mixer: mixer, library: library))
    }
    var body: some Scene {
        WindowGroup {
            RootView(model: console)
                .preferredColorScheme(.dark)
                .onAppear { mixer.start() }
                .task {
                    await library.open()
                    await library.readMissingTags()
                }
                .modifier(LibrarySceneObserver(phase: scenePhase, library: library, mixer: mixer, console: console))
        }
    }
}

/// The console, and the system's file picker for ADD FILES and ADD FOLDER.
struct RootView: View {
    @ObservedObject var model: ConsoleModel

    var body: some View {
        FittedConsole(state: model.state, actions: model.actions, clock: model.clock)
            .frame(minWidth: 760, minHeight: 560)
            .fileImporter(isPresented: picking, allowedContentTypes: model.pick == .folder ? [.folder] : [.audio],
                          allowsMultipleSelection: model.pick != .folder) { result in
                model.picking = nil
                guard case .success(let urls) = result else { return }
                if model.pick == .folder { urls.first.map(model.importFolder) } else { Task { await model.library.importFiles(urls) } }
            }
    }

    private var picking: Binding<Bool> {
        Binding(get: { model.picking != nil }, set: { if !$0 { model.picking = nil } })
    }
}

private struct LibrarySceneObserver: ViewModifier {
    let phase: ScenePhase
    let library: NativeLibrary
    let mixer: NativeMixer
    let console: ConsoleModel
    func body(content: Content) -> some View {
        if #available(macOS 14, iOS 17, *) {
            content.onChange(of: phase) { _, value in flush(value) }
        } else {
            content.onChange(of: phase) { value in flush(value) }
        }
    }
    private func flush(_ value: ScenePhase) {
        console.setActive(value == .active)
        if value != .active { mixer.logDiagnostics() }
        if value == .active { mixer.sceneBecameActive() }
        else { Task { await library.flush() } }
    }
}
