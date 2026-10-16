import Combine
import Foundation

/// Device-local installation state. Recording never initiates a model download.
@MainActor
final class MeetingWhisperModelController: ObservableObject {
    static let shared = MeetingWhisperModelController()

    @Published private(set) var isInstalled = false
    @Published private(set) var isInstalling = false
    @Published private(set) var isDeleting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?

    private let store: MeetingWhisperModelStore
    private var installTask: Task<Void, Never>?

    init(store: MeetingWhisperModelStore? = nil) {
        self.store = store ?? .shared
    }

    func refresh() async {
        isInstalled = await store.isInstalled()
    }

    func install() {
        guard installTask == nil, !isDeleting else { return }
        isInstalling = true
        progress = 0
        errorMessage = nil
        installTask = Task { [store] in
            do {
                try await store.install { value in
                    Task { @MainActor in self.progress = value }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isInstalled = await store.isInstalled()
            isInstalling = false
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    func delete() async {
        guard !isInstalling, !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await store.delete()
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalled = await store.isInstalled()
    }
}
