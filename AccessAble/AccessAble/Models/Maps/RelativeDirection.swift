import Foundation

/// One of eight directions relative to where the user faces, for spoken guidance.
enum RelativeDirection: CaseIterable, Sendable {
    case ahead, slightlyRight, right, behindRight, behind, behindLeft, left, slightlyLeft

    /// Eight 45° sectors centred on 0°, 45°, 90° and so on. Each sector holds its anticlockwise edge, so ahead is
    /// -22.5 ..< 22.5, slightly right 22.5 ..< 67.5, and behind 157.5...180 with -180 ..< -157.5.
    init(_ bearing: RelativeBearing) {
        let sector = Int(((bearing.degrees + 22.5) / 45).rounded(.down))
        self = Self.allCases[(sector + 8) % 8]
    }

    /// Fits after "The path is" or a place's name: "ahead", "on your right", "behind you on your left".
    var phrase: String {
        switch self {
        case .ahead: "ahead"
        case .slightlyRight: "slightly right"
        case .right: "on your right"
        case .behindRight: "behind you on your right"
        case .behind: "behind you"
        case .behindLeft: "behind you on your left"
        case .left: "on your left"
        case .slightlyLeft: "slightly left"
        }
    }
}
