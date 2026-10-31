@MainActor
protocol DisplayProvider: AnyObject {
    var snapshots: [DisplaySnapshot] { get }
    var onChange: (([DisplaySnapshot]) -> Void)? { get set }
    func refresh()
    func stop()
}
