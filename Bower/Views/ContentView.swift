import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

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
                }
            }
            .toolbar {
                if app.isPlayerVisible {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            app.leavePlayer()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .help("Back to \(app.displayedTitle)")
                        .keyboardShortcut("[", modifiers: .command)
                    }
                } else if app.playback.current != nil {
                    // The bar sits in the toolbar — the top of the window —
                    // where it can never push the grid around.
                    ToolbarItem(placement: .principal) {
                        MiniPlayerBar()
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
        }
        // On the split view rather than the detail column, so the list is
        // always a full-height trailing column; on the detail column it came
        // back under a window-wide toolbar after being toggled.
        .inspector(isPresented: Binding(get: { app.isVideoListOpen },
                                        // Only the user closing the panel lands in the
                                        // setter; the closes that follow the player out
                                        // must not count as hiding the list for next time.
                                        set: {
                                            app.isVideoListOpen = $0
                                            if app.isPlayerVisible { app.showVideoList = $0 }
                                        })) {
            VideoListView()
                .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
                .background(InspectorHeaderAnchor())
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .automatic) {
                        toolbarControls
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
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

    // One persistent group stays at the trailing edge as the inspector toggles.
    // The mini player bar replaces the old Now Playing entry point.
    private var toolbarControls: some View {
        HStack(spacing: 2) {
            toolbarButton("Search", systemImage: "magnifyingglass", help: "Search Videos (⌘K)") {
                app.activeSheet = .search
            }
            if app.isPlayerVisible {
                toolbarButton("Video List", systemImage: "sidebar.trailing",
                              help: app.showVideoList ? "Hide Video List" : "Show Video List") {
                    app.toggleVideoList()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
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

/// The bar's scale in the toolbar. A setting (Settings ▸ Playback); the
/// raw values persist in UserDefaults.
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
    var barHeight: CGFloat { 36 * scale }
    var thumbnailSize: CGSize { CGSize(width: 48 * scale, height: 27 * scale) }
    var controlSize: CGFloat { 26 * scale }
}

/// The toolbar bar for a video that keeps playing after leaving the
/// player. It sits at the top of the window, clear of the grid; the
/// thumbnail and title open the player, transport stays at hand.
private struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app
    @AppStorage("miniPlayerSize") private var size: MiniPlayerSize = .regular

    var body: some View {
        let playback = app.playback
        HStack(spacing: 8) {
            Button {
                app.openPlayer()
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
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: size.controlSize, height: size.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.player.isPlaying ? "Pause" : "Play")
            .help(playback.player.isPlaying ? "Pause" : "Play")

            Button {
                app.openPlayer()
            } label: {
                // Points down at the grid the bar sits above.
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
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
        .frame(maxWidth: 480)
        .glassEffect(.regular.interactive(), in: .capsule)
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
