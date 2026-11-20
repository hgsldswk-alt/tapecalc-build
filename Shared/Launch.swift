import Foundation

enum Launch {
    static let freePeriod = false
    #if DEBUG
    static let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    #else
    static let testing = false
    #endif

    static func has(_ flag: String) -> Bool {
        testing && ProcessInfo.processInfo.arguments.contains(flag)
    }

    static var isFree: Bool { freePeriod && !has("-paywall") && !has("-expired") }
}
