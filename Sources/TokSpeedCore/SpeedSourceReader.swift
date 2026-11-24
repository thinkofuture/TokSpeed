import Foundation

protocol SpeedSourceReader: AnyObject {
    var source: SourceMode { get }
    func poll(forceScan: Bool, now: Date)
    func snapshot(now: Date) -> SourceSnapshot
    func onceLines(now: Date) -> [String]
    var hasOnceData: Bool { get }
}
