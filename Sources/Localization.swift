import Foundation

// Literal keys keep interpolation values (device names/errors) out of the catalog.
struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var key: String
    var arguments: [String]
    init(stringLiteral value: String) { key = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
}
func L(_ text: LocalizedText, bundle: Bundle = .main) -> String {
    let english = bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    let fallback = english?.localizedString(forKey: text.key, value: text.key, table: nil) ?? text.key
    let template = bundle.localizedString(forKey: text.key, value: fallback, table: nil)
    let pieces = template.components(separatedBy: "%@")
    guard pieces.count == text.arguments.count + 1 else { return template }
    return zip(text.arguments, pieces.dropFirst()).reduce(pieces[0]) { $0 + $1.0 + $1.1 }
}
func volumePercent(_ value: Double) -> String {
    // Both supported UI languages use decimal digits; honor localized percent placement.
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    formatter.numberStyle = .percent; formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value / 100)) ?? "\(Int(value.rounded()))%"
}
