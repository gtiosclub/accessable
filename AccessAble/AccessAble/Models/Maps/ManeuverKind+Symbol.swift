/// SF Symbol for a maneuver, shared by the map marker and the Live Activity so both show the same turn.
extension ManeuverKind {
    var symbolName: String {
        switch self {
        case .depart: "figure.walk.departure"
        case .straight: "arrow.up"
        case .turnLeft, .slightLeft: "arrow.turn.up.left"
        case .turnRight, .slightRight: "arrow.turn.up.right"
        case .uTurn: "arrow.uturn.up"
        case .cross: "figure.walk"
        case .arrive: "mappin.and.ellipse"
        case .stairs, .escalator: "figure.stairs"
        case .elevator: "arrow.up.arrow.down"
        case .enterBuilding: "door.left.hand.open"
        case .exitBuilding: "door.right.hand.open"
        }
    }
}
