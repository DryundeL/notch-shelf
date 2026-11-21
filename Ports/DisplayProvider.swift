import Foundation

/// One provider per process: its owner creates and stops it, consumers only subscribe.
@MainActor
protocol DisplayProvider: AnyObject {
    var snapshots: [DisplaySnapshot] { get }
    /// Every subscriber receives each change. Keep the token and pass it to `removeObserver` on teardown.
    func addObserver(_ handler: @escaping ([DisplaySnapshot]) -> Void) -> UUID
    func removeObserver(_ token: UUID)
    func refresh()
    func stop()
}
