import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ActiveSheet: String, Identifiable {
    case add, cookie, search
    var id: String { rawValue }
}

@Observable
final class AppModel {
    let store: LibraryStore
    let playback: PlaybackModel
    let library: LibraryService

    var selection: LibrarySelection? = .latest {
        didSet {
            guard selection != oldValue else { return }
            reloadDisplayed()
            hidePlayer()
            filter = ""
        }
    }

    /// Narrows the visible list (grid and video list alike).
    var filter = "" {
        didSet { if filter != oldValue { applyFilter() } }
    }

    private(set) var filteredVideos: [Video] = []

    /// Lowercased title + source per displayed video, built on first use of
    /// the filter so typing doesn't redo it for every video on each key.
    @ObservationIgnored private var haystacks: [String]?

    /// The main area shows either the selected list as a grid of videos or,
    /// once a video is picked, the player with an optional video list.
    var isPlayerVisible = false

    private(set) var displayedVideos: [Video] = []

    var showVideoList: Bool = UserDefaults.standard.object(forKey: "showVideoList") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVideoList, forKey: "showVideoList") }
    }

    /// Whether the trailing video list panel is on screen right now. Kept
    /// apart from `showVideoList` (the lasting preference) so the panel can
    /// close after the player has faded out: closing alongside it drags the
    /// video sideways mid-fade.
    var isVideoListOpen = false

    var activeSheet: ActiveSheet?
    var alertMessage: String?

    init() {
        let store = LibraryStore()
        self.store = store
        playback = PlaybackModel(store: store)
        library = LibraryService(store: store)
        // Every link the player surfaces goes through one router.
        playback.player.onOpenLink = { [weak self] url in self?.openLink(url) }
        reloadDisplayed()
        Task { await CookieStore.shared.syncToWebKit(clearExisting: false) }
    }

    var displayedTitle: String {
        selection.map { store.title(for: $0) } ?? "Bower"
    }

    func reloadDisplayed() {
        displayedVideos = selection.map { store.videos(for: $0) } ?? []
        haystacks = nil
        applyFilter()
    }

    private func applyFilter() {
        let terms = filter.lowercased().split(separator: " ")
        guard !terms.isEmpty else {
            filteredVideos = displayedVideos
            return
        }
        let haystacks = haystacks ?? displayedVideos.map { "\($0.title) \($0.sourceTitle ?? "")".lowercased() }
        self.haystacks = haystacks
        filteredVideos = zip(displayedVideos, haystacks).compactMap { video, haystack in
            terms.allSatisfy { haystack.contains($0) } ? video : nil
        }
    }

    /// Sources' videos changed underneath: rebuild what is shown and the queue.
    func libraryChanged() {
        reloadDisplayed()
        if let selection, store.isMissing(selection) {
            self.selection = .latest
            return
        }
        if let context = playback.queueContext {
            let list = context == selection ? displayedVideos : store.videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    /// Bookmarks or history changed: only those two lists depend on them.
    func userDataChanged() {
        let dependent: Set<LibrarySelection> = [.bookmarks, .history]
        if let selection, dependent.contains(selection) { reloadDisplayed() }
        if let context = playback.queueContext, dependent.contains(context) {
            let list = context == selection ? displayedVideos : store.videos(for: context)
            playback.libraryChanged(list, context: context)
        }
    }

    func play(_ video: Video) {
        guard let selection else { return }
        playback.play(video, from: displayedVideos, context: selection)
        presentPlayer()
    }

    /// Plays the visible list from the top (or from a random video when
    /// shuffling), skipping hidden videos.
    func playAll() {
        let playable = displayedVideos.filter { !store.isSkipped($0.id) }
        guard let first = playback.shuffle ? playable.randomElement() : playable.first else { return }
        play(first)
    }

    func showPlayer() {
        guard playback.current != nil else { return }
        if let context = playback.queueContext, context != selection {
            selection = context
        }
        presentPlayer()
    }

    /// Shows the player and the video list panel the way the user left it.
    func enterPlayer() {
        isVideoListOpen = showVideoList
        isPlayerVisible = true
    }

    /// Leaves the player page, pausing first when the user set that
    /// (Settings ▸ Playback). The one door for sidebar changes and the
    /// animated `leavePlayer` alike. Read live so Settings edits apply at
    /// once.
    ///
    /// - Parameter closeListAfterFade: `leavePlayer` passes true; the
    ///   video list then closes only once the video has faded out.
    func hidePlayer(closeListAfterFade: Bool = false) {
        if UserDefaults.standard.object(forKey: "pauseWhenLeavingPlayer") as? Bool ?? true {
            playback.player.pause()
        }
        isPlayerVisible = false
        if !closeListAfterFade { isVideoListOpen = false }
    }

    /// The animated door out (Back button): the video fades out where it
    /// is, then the video list swings shut. Both at once and the closing
    /// panel drags the video sideways mid-fade.
    func leavePlayer() {
        withAnimation(.smooth(duration: 0.25)) {
            hidePlayer(closeListAfterFade: true)
        } completion: {
            withAnimation(.smooth(duration: 0.25)) { self.closeVideoList() }
        }
    }

    /// The animated door in (mini player bar): the video list makes room
    /// first, then the video fades in already at its final position. With
    /// "Resume when returning" on (Settings ▸ Playback), a paused video
    /// starts playing again as it comes back into view.
    func openPlayer() {
        guard playback.current != nil else { return }
        withAnimation(.smooth(duration: 0.25)) {
            isVideoListOpen = showVideoList
        } completion: {
            withAnimation(.smooth(duration: 0.25)) {
                if UserDefaults.standard.object(forKey: "resumeWhenReturningToPlayer") as? Bool ?? true,
                   !self.playback.player.isPlaying {
                    self.playback.player.play()
                }
                self.enterPlayer()
            }
        }
    }

    /// Closes the panel after the player has faded; skipped if the player
    /// came back in the meantime (the bar clicked mid-fade).
    private func closeVideoList() {
        guard !isPlayerVisible else { return }
        isVideoListOpen = false
    }

    /// The toolbar toggle: the lasting preference and the panel together.
    func toggleVideoList() {
        showVideoList.toggle()
        if isPlayerVisible { isVideoListOpen = showVideoList }
    }

    /// Shows `selection` with one of its videos cued, as when picking a
    /// search result.
    func reveal(_ videoID: String, in selection: LibrarySelection) {
        self.selection = selection
        if let video = displayedVideos.first(where: { $0.id == videoID }) {
            playback.play(video, from: displayedVideos, context: selection, autoplay: false)
            presentPlayer()
        }
    }

    // MARK: Link routing

    /// Bumped on every routed link, so a slow metadata fetch for an earlier
    /// click can't decide what plays after a newer one.
    @ObservationIgnored private var linkRequest = 0

    /// Where a clicked link goes: YouTube video links play in the app,
    /// everything else (channels, playlists, other sites) opens in the browser.
    func openLink(_ url: URL) {
        linkRequest += 1
        let request = linkRequest
        guard let link = YouTubeURL.videoLink(url) else {
            NSWorkspace.shared.open(url)
            return
        }

        // The video already playing: bring it into view (and jump to the
        // link's time, if any) rather than loading it again.
        if playback.current?.id == link.id {
            showPlayer()
            if let start = link.start { playback.seek(to: start) }
            return
        }

        // A video in the list being shown plays from there, keeping its queue.
        if let selection, let video = displayedVideos.first(where: { $0.id == link.id }) {
            playback.play(video, from: displayedVideos, context: selection, startAt: link.start)
            presentPlayer()
            return
        }

        // Not in the library (a video from an unsubscribed channel, say):
        // ask YouTube what it is, then play it on its own. Only this click's
        // request may act, and only if nothing else started playing since.
        let context = selection ?? .latest
        let preceding = playback.current?.id
        Task {
            do {
                let details = try await InnerTubeClient.shared.video(id: link.id)
                guard request == linkRequest, playback.current?.id == preceding else { return }
                playback.play(details.video, from: [details.video], context: context, startAt: link.start)
                presentPlayer()
            } catch {
                guard request == linkRequest, playback.current?.id == preceding else { return }
                alertMessage = "Couldn't open that video: \(error.localizedDescription)"
            }
        }
    }

    /// Enters the player from the grid or a link: the video list starts
    /// closed (upstream behavior). Returning via the mini player bar
    /// (`openPlayer`) restores the panel instead.
    private func presentPlayer() {
        if !isPlayerVisible { showVideoList = false }
        enterPlayer()
    }

    func deleteSource(_ ref: SourceRef) {
        store.remove(ref)
    }

    // MARK: Import / export

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [OPML.contentType]
        panel.nameFieldStringValue = "bower-export.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportOPML().write(to: url, options: .atomic)
        } catch {
            alertMessage = "Couldn't export the library: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [OPML.contentType, .xml, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try store.importData(Data(contentsOf: url))
            // OPML carries no videos, so fetch them for what was just added.
            library.refresh(added)
            alertMessage = added.count == 1 ? "Imported 1 playlist or channel." : "Imported \(added.count) playlists and channels."
        } catch {
            alertMessage = "That file isn't an OPML file or a Bower export."
        }
    }

    func flush() {
        playback.flush()
        store.flush()
    }
}

extension LibraryStore {
    func isMissing(_ selection: LibrarySelection) -> Bool {
        switch selection {
        case .latest, .bookmarks, .history: false
        case .folder(let id): folder(id) == nil
        case .playlist, .channel: selection.sourceRef.map { source($0) == nil } ?? true
        }
    }
}
