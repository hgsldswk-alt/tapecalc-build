enum ShareRules {
    static let maxRows = 12

    static func prefersImage(rows: Int, height: Double) -> Bool {
        rows <= maxRows && height <= 790
    }
}
