import CoreLocation
import Foundation

// Placeholder content for the redesigned screens. Swap these for real services
// (search, recorded routes, volunteers, chat) when the backend is ready.

enum PlaceCategory: String, CaseIterable, Hashable, Sendable {
    case restaurants
    case labeledPlaces
    case parks
    case publicTransit

    var displayName: String {
        switch self {
        case .restaurants: "Restaurants"
        case .labeledPlaces: "Labeled Places"
        case .parks: "Parks"
        case .publicTransit: "Public Transit"
        }
    }
}

struct SamplePlace: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var address: String
    var category: PlaceCategory
    var rating: Double
    var reviewCount: Int
    var recordedRouteCount: Int
    var isSaved: Bool
    var isRecent: Bool
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct SampleRouteStep: Hashable, Sendable {
    var text: String
    var details: [String] = []
}

struct SampleRoute: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var minutes: Int
    var isRecorded: Bool
    var steps: [SampleRouteStep]
}

enum RoutePlanMode: Hashable, Sendable {
    case recorded
    case new
}

struct TripPlan: Hashable, Sendable {
    var place: SamplePlace
    var route: SampleRoute?
    /// Recording a new route while walking it.
    var isRecording: Bool
    /// The starting point picked in search; nil for My Location. A live trip still starts
    /// where the user is, and says so.
    var origin: SamplePlace? = nil
}

struct Volunteer: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var availableUntil: String
    var isOnline: Bool
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    var text: String
    var isFromMe: Bool

    init(id: UUID = UUID(), text: String, isFromMe: Bool) {
        self.id = id
        self.text = text
        self.isFromMe = isFromMe
    }
}

struct TripAnnouncement: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Obstacles and hazards; shown red.
        case warning
        /// Directions and descriptions; shown cyan.
        case info
    }

    let id: UUID
    var text: String
    var kind: Kind

    init(id: UUID = UUID(), text: String, kind: Kind) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

/// Voice commands that the Info sheet lists. The first three can be tried on the trip screen.
enum VoiceCommandHint: String, CaseIterable, Identifiable, Sendable {
    case repeatWarning
    case describeSurroundings
    case describeLocation
    case pauseTrip
    case callHelp

    var id: Self { self }

    var phrase: String {
        switch self {
        case .repeatWarning: "Repeat warning"
        case .describeSurroundings: "Describe surroundings"
        case .describeLocation: "Describe location"
        case .pauseTrip: "Pause trip"
        case .callHelp: "Call help"
        }
    }

    var summary: String {
        switch self {
        case .repeatWarning: "Says the last obstacle warning again."
        case .describeSurroundings: "Lists what the camera sees around you."
        case .describeLocation: "Tells you the street you're on and what's nearby."
        case .pauseTrip: "Pauses directions until you continue."
        case .callHelp: "Starts a video call with an available volunteer."
        }
    }

    /// What the trip screen shows when the command is tried.
    var sampleResponse: TripAnnouncement? {
        switch self {
        case .repeatWarning: TripAnnouncement(text: SampleContent.pillarWarning, kind: .warning)
        case .describeSurroundings: TripAnnouncement(text: "Lamp post; Open area; Concrete floor; 10 floor building", kind: .info)
        case .describeLocation: TripAnnouncement(text: "Longman Road, next to restaurant Koko Bar, convenient store", kind: .info)
        case .pauseTrip, .callHelp: nil
        }
    }
}

enum SampleContent {
    static let campusLatitude = 33.7756
    static let campusLongitude = -84.3963

    static let pillarWarning = "Stop and move left; pillar in front"

    static let places: [SamplePlace] = [
        SamplePlace(id: "north-ave", name: "North Avenue Dining Hall", address: "120 North Ave NW, Atlanta, GA 30313",
                    category: .restaurants, rating: 4.0, reviewCount: 19, recordedRouteCount: 1,
                    isSaved: true, isRecent: false, latitude: 33.7712, longitude: -84.3916),
        SamplePlace(id: "eastside", name: "Eastside Garden Café", address: "455 Spring St NW, Atlanta, GA 30308",
                    category: .restaurants, rating: 4.5, reviewCount: 45, recordedRouteCount: 0,
                    isSaved: true, isRecent: false, latitude: 33.7745, longitude: -84.3890),
        SamplePlace(id: "brittain", name: "Brittain Dining Hall", address: "355 Ferst Dr NW, Atlanta, GA 30332",
                    category: .restaurants, rating: 4.0, reviewCount: 31, recordedRouteCount: 2,
                    isSaved: true, isRecent: false, latitude: 33.7727, longitude: -84.3912),
        SamplePlace(id: "culc", name: "Clough Undergraduate Learning Commons", address: "266 4th St NW, Atlanta, GA 30313",
                    category: .labeledPlaces, rating: 4.0, reviewCount: 19, recordedRouteCount: 1,
                    isSaved: false, isRecent: false, latitude: 33.7749, longitude: -84.3964),
        SamplePlace(id: "culc-152", name: "CULC Room 152", address: "266 4th St NW, Room 152, Atlanta, GA 30313",
                    category: .labeledPlaces, rating: 4.5, reviewCount: 45, recordedRouteCount: 1,
                    isSaved: false, isRecent: false, latitude: 33.7748, longitude: -84.3962),
        SamplePlace(id: "kaldis", name: "Kaldi's Café", address: "266 4th St NW, Atlanta, GA 30313",
                    category: .restaurants, rating: 4.5, reviewCount: 45, recordedRouteCount: 0,
                    isSaved: false, isRecent: false, latitude: 33.7750, longitude: -84.3966),
        SamplePlace(id: "maple", name: "Maple Street Dining", address: "88 Maple St NW, Atlanta, GA 30313",
                    category: .restaurants, rating: 4.0, reviewCount: 42, recordedRouteCount: 0,
                    isSaved: false, isRecent: true, latitude: 33.7790, longitude: -84.3990),
        SamplePlace(id: "maple-west", name: "Maple Street Dining West", address: "102 Maple St NW, Atlanta, GA 30313",
                    category: .restaurants, rating: 4.0, reviewCount: 42, recordedRouteCount: 0,
                    isSaved: false, isRecent: true, latitude: 33.7792, longitude: -84.4001),
        SamplePlace(id: "sunset", name: "Sunset Grill", address: "730 Peachtree St NE, Atlanta, GA 30308",
                    category: .restaurants, rating: 4.5, reviewCount: 88, recordedRouteCount: 0,
                    isSaved: false, isRecent: true, latitude: 33.7760, longitude: -84.3850),
        SamplePlace(id: "tech-green", name: "Tech Green", address: "Tech Green, Atlanta, GA 30332",
                    category: .parks, rating: 4.5, reviewCount: 120, recordedRouteCount: 0,
                    isSaved: false, isRecent: true, latitude: 33.7743, longitude: -84.3975),
        SamplePlace(id: "na-station", name: "North Avenue Station", address: "713 W Peachtree St NE, Atlanta, GA 30308",
                    category: .publicTransit, rating: 3.5, reviewCount: 64, recordedRouteCount: 1,
                    isSaved: false, isRecent: false, latitude: 33.7716, longitude: -84.3870),
    ]

    static var savedPlaces: [SamplePlace] { places.filter(\.isSaved) }
    static var recentPlaces: [SamplePlace] { places.filter(\.isRecent) }

    /// Places whose name or address contains `query`, optionally limited to one category.
    static func search(_ query: String, category: PlaceCategory?) -> [SamplePlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || category != nil else { return [] }
        return places.filter { place in
            let matchesQuery = trimmed.isEmpty
                || place.name.localizedStandardContains(trimmed)
                || place.address.localizedStandardContains(trimmed)
                || initials(of: place.name).localizedStandardContains(trimmed)
            let matchesCategory = category.map { place.category == $0 } ?? true
            return matchesQuery && matchesCategory
        }
    }

    /// "Clough Undergraduate Learning Commons" → "CULC", so short names find the building.
    private static func initials(of name: String) -> String {
        String(name.split(separator: " ").compactMap(\.first))
    }

    static let walkSteps: [SampleRouteStep] = [
        SampleRouteStep(text: "Walk out the house"),
        SampleRouteStep(text: "Turn left once got out the building"),
        SampleRouteStep(text: "Walk 50 ft", details: ["Walk past 1 crossroad"]),
        SampleRouteStep(text: "Wait for the bus", details: ["Use camera to identify bus route number"]),
        SampleRouteStep(text: "Go on bus", details: ["Get down at North Ave"]),
    ]

    static func routes(to place: SamplePlace, mode: RoutePlanMode) -> [SampleRoute] {
        switch mode {
        case .recorded:
            return (0..<max(place.recordedRouteCount, 1)).map { index in
                SampleRoute(
                    id: "\(place.id)-recorded-\(index)",
                    title: index == 0 ? "Route with more stairs" : "Route with fewer crossings",
                    minutes: 16 + index * 4,
                    isRecorded: true,
                    steps: walkSteps
                )
            }
        case .new:
            return [
                SampleRoute(id: "\(place.id)-fastest", title: "Fastest Route", minutes: 16, isRecorded: false, steps: walkSteps),
                SampleRoute(id: "\(place.id)-accessible", title: "Step-Free Route", minutes: 20, isRecorded: false, steps: walkSteps),
                SampleRoute(id: "\(place.id)-longer", title: "Longer Route", minutes: 24, isRecorded: false, steps: walkSteps),
            ]
        }
    }

    static let activeVolunteers: [Volunteer] = [
        Volunteer(id: "shruthi", name: "Shruthi", availableUntil: "Until 4 PM", isOnline: true),
        Volunteer(id: "anaika", name: "Anaika", availableUntil: "Until 4 PM", isOnline: true),
    ]

    static let savedVolunteers: [Volunteer] = activeVolunteers

    static let recentVolunteers: [Volunteer] = [
        Volunteer(id: "catherine", name: "Catherine", availableUntil: "Until 4 PM", isOnline: true),
        Volunteer(id: "mahati", name: "Mahati", availableUntil: "Until 4 PM", isOnline: true),
    ]

    static func conversation(with volunteer: Volunteer) -> [ChatMessage] {
        [ChatMessage(text: "Hi! Will you be available at around 5:30 PM tomorrow to help me see my road?", isFromMe: true)]
    }

    static let initialAnnouncements: [TripAnnouncement] = [
        TripAnnouncement(text: "Walk straight for 10 min; turn left", kind: .info),
        TripAnnouncement(text: pillarWarning, kind: .warning),
    ]

    /// A short walk across campus for the map view.
    static let sampleRouteLine: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 33.7790, longitude: -84.3925),
        CLLocationCoordinate2D(latitude: 33.7765, longitude: -84.3922),
        CLLocationCoordinate2D(latitude: 33.7740, longitude: -84.3918),
        CLLocationCoordinate2D(latitude: 33.7727, longitude: -84.3912),
    ]
}
