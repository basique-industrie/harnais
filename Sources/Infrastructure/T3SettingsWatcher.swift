import Foundation

/// Calls `onChange` on the main queue when a T3 settings file changes, including atomic replaces
/// (watched through the parent directory) and in-place writes (watched on the file itself).
public final class T3SettingsWatcher: @unchecked Sendable {
    private let urls: [URL]
    private let queue = DispatchQueue(label: "harnais.t3-settings-watcher")
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fingerprints: [URL: Data] = [:]
    private var pending: DispatchWorkItem?

    public init(urls: [URL], onChange: @escaping @MainActor () -> Void) {
        self.urls = urls
        self.onChange = onChange
        queue.sync {
            for url in urls { fingerprints[url] = try? Data(contentsOf: url) }
            arm()
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    public func stop() {
        queue.sync {
            for source in sources { source.cancel() }
            sources = []
            pending?.cancel()
        }
    }

    private func arm() {
        for source in sources { source.cancel() }
        sources = []
        var watched: Set<String> = []
        for url in urls {
            for path in [url.deletingLastPathComponent().path, url.path] where watched.insert(path).inserted {
                watch(path)
            }
        }
    }

    private func watch(_ path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        sources.append(source)
        source.resume()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func check() {
        // An atomic replace leaves the old file descriptor on the unlinked file.
        arm()
        var changed = false
        for url in urls {
            let data = try? Data(contentsOf: url)
            if data != fingerprints[url] {
                fingerprints[url] = data
                changed = true
            }
        }
        guard changed else { return }
        let onChange = onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
    }
}
