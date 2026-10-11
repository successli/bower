import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @AppStorage("miniPlayerPosition") private var miniPlayerPosition: MiniPlayerPosition = .top

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            ZStack {
                // Kept in the window while hidden so playback carries on
                // while browsing the grid.
                NowPlayingView()
                    .opacity(app.isPlayerVisible ? 1 : 0)
                    .allowsHitTesting(app.isPlayerVisible)
                    .accessibilityHidden(!app.isPlayerVisible)
                if !app.isPlayerVisible {
                    VideoGridView()
                        // safeAreaInset gives the bar its own space, so the
                        // grid scrolls clear of it instead of underneath.
                        .safeAreaInset(edge: miniPlayerPosition.edge, spacing: 0) {
                            if app.playback.current != nil {
                                MiniPlayerBar()
                                    .padding(.horizontal, 16)
                                    .padding(miniPlayerPosition == .top ? .top : .bottom, 12)
                                    .transition(.move(edge: miniPlayerPosition.moveEdge).combined(with: .opacity))
                            }
                        }
                }
            }
            .toolbar {
                if app.isPlayerVisible {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { app.hidePlayer() }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back to \(app.displayedTitle)")
                        .keyboardShortcut("[", modifiers: .command)
                    }
                }
                // One hand-drawn capsule so its contents can change between
                // grid and player mode without reshuffling toolbar items.
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 2) {
                        if !app.isPlayerVisible, app.playback.current != nil {
                            toolbarButton("Now Playing",
                                          systemImage: app.playback.player.isPlaying ? "waveform" : "play.rectangle",
                                          help: "Show Now Playing") {
                                withAnimation(.snappy(duration: 0.25)) { app.showPlayer() }
                            }
                        }
                        toolbarButton("Search", systemImage: "magnifyingglass", help: "Search Videos (⌘K)") {
                            app.activeSheet = .search
                        }
                        if app.isPlayerVisible {
                            toolbarButton("Video List", systemImage: "sidebar.trailing",
                                          help: app.showVideoList ? "Hide Video List" : "Show Video List") {
                                app.showVideoList.toggle()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // On the split view rather than the detail column, so the list is
        // always a full-height trailing column; on the detail column it came
        // back under a window-wide toolbar after being toggled.
        .inspector(isPresented: Binding(get: { app.isPlayerVisible && app.showVideoList },
                                        // Leaving the player dismisses the inspector too;
                                        // that must not count as the user hiding the list.
                                        set: { if app.isPlayerVisible { app.showVideoList = $0 } })) {
            VideoListView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
        }
        .navigationTitle(app.displayedTitle)
        .sheet(item: $app.activeSheet) { sheet in
            switch sheet {
            case .add: AddSourceSheet()
            case .cookie: CookieSheet()
            case .search: SearchSheet()
            }
        }
        .alert("Bower", isPresented: Binding(get: { app.alertMessage != nil }, set: { if !$0 { app.alertMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(app.alertMessage ?? "")
        }
        .alert(
            refreshFailureTitle,
            isPresented: Binding(get: { !app.library.isRefreshing && !app.library.failures.isEmpty },
                                 set: { if !$0 { app.library.failures = [] } })
        ) {
            Button("OK") {}
        } message: {
            Text(app.library.failures.prefix(6).map { "\($0.title): \($0.message)" }.joined(separator: "\n"))
        }
        .onChange(of: app.store.contentRevision) { app.libraryChanged() }
        .onChange(of: app.store.userRevision) { app.userDataChanged() }
        .onChange(of: activeState) { _, state in
            if state == .key { app.library.refreshIfStale() }
        }
        .task { app.library.refreshIfStale() }
        .background(WindowAccessor { window in
            window.level = alwaysOnTop ? .floating : .normal
        }.id(alwaysOnTop))
    }

    private func toolbarButton(_ title: String, systemImage: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 32)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(help)
    }

    private var refreshFailureTitle: String {
        let count = app.library.failures.count
        return "Couldn't update \(count) \(count == 1 ? "source" : "sources")"
    }
}

/// Where the mini player bar floats over the grid. A setting
/// (Settings ▸ Playback); the raw values persist in UserDefaults.
enum MiniPlayerPosition: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { self == .top ? "Top" : "Bottom" }
    var edge: VerticalEdge { self == .top ? .top : .bottom }
    var moveEdge: Edge { self == .top ? .top : .bottom }
}

/// The bar's scale. A setting too.
enum MiniPlayerSize: String, CaseIterable, Identifiable {
    case small, regular, large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Small"
        case .regular: "Regular"
        case .large: "Large"
        }
    }
    var scale: CGFloat {
        switch self {
        case .small: 0.85
        case .regular: 1
        case .large: 1.15
        }
    }
    var barHeight: CGFloat { 48 * scale }
    var thumbnailSize: CGSize { CGSize(width: 64 * scale, height: 36 * scale) }
    var controlSize: CGFloat { 32 * scale }
}

/// The floating bar for a video that keeps playing after leaving the
/// player. Thumbnail and title open the player; transport stays at hand.
private struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app
    @AppStorage("miniPlayerSize") private var size: MiniPlayerSize = .regular
    @AppStorage("miniPlayerPosition") private var position: MiniPlayerPosition = .top

    var body: some View {
        let playback = app.playback
        HStack(spacing: 8) {
            Button {
                app.showPlayer()
            } label: {
                HStack(spacing: 10) {
                    RemoteImage(url: playback.current?.thumbnail)
                        .frame(width: size.thumbnailSize.width, height: size.thumbnailSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.current?.title ?? "")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Now Playing")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: size.controlSize, height: size.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.player.isPlaying ? "Pause" : "Play")
            .help(playback.player.isPlaying ? "Pause" : "Play")

            Button {
                app.showPlayer()
            } label: {
                // Points toward the content the bar sits against.
                Image(systemName: position == .top ? "chevron.down" : "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: size.controlSize, height: size.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Now Playing")
            .help("Show Now Playing")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: size.barHeight)
        .frame(maxWidth: 560)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }

    private var progressText: String {
        let player = app.playback.player
        let elapsed = DurationText.format(seconds: Int(player.currentTime))
        return player.duration > 1
            ? "\(elapsed) / \(DurationText.format(seconds: Int(player.duration)))"
            : elapsed
    }
}

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
    }
}
