#if DEBUG
import Foundation
import Observation

/// Developer screen for checking what Core Location reports on a device.
@MainActor
@Observable
final class LocationDebugViewModel {
    /// One labelled reading, with its value written out for VoiceOver.
    struct Field: Equatable, Identifiable {
        let label: String
        let value: String
        let spokenValue: String

        var id: String { label }
    }

    private(set) var authorization: LocationAuthorization = .notDetermined
    private(set) var sampleCount = 0
    /// Newest first.
    private(set) var recentSamples: [LocationSample] = []

    /// `nil` when unknown.
    private(set) var heading: UserHeading?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var headingEstimator = HeadingEstimator()
    // staleness is judged against the newest reading of either kind, so the heading updates without a timer
    @ObservationIgnored private var newestReadingTime: Date?

    static let historyLimit = 20

    init(services: AppServices) {
        self.services = services
    }

    var latestSample: LocationSample? { recentSamples.first }

    var permissionField: Field {
        let value = switch authorization {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized(preciseAccuracy: true): "Allowed, precise"
        case .authorized(preciseAccuracy: false): "Allowed, approximate"
        }
        return Field(label: "Location access", value: value, spokenValue: value)
    }

    var countField: Field {
        Field(label: "Readings received", value: "\(sampleCount)", spokenValue: "\(sampleCount)")
    }

    var headingField: Field {
        guard let heading else { return Field(label: "Heading", value: "Unknown", spokenValue: "Unknown") }
        let degrees = Int(heading.degrees.rounded()) % 360
        let source = switch heading.source {
        case .ar: "AR geo-tracking"
        case .walkingDirection: "walking direction"
        case .compass: "compass"
        }
        return Field(label: "Heading", value: "\(degrees)° · \(source)", spokenValue: "\(degrees) degrees, \(source)")
    }

    func ageField(at now: Date) -> Field {
        guard let latestSample else { return Self.unavailable("Age") }
        let seconds = max(0, Int(now.timeIntervalSince(latestSample.timestamp)))
        return Field(label: "Age", value: "\(seconds) s", spokenValue: seconds == 1 ? "1 second" : "\(seconds) seconds")
    }

    static func fields(of sample: LocationSample) -> [Field] {
        let latitude = String(format: "%.6f", sample.coordinate.latitude)
        let longitude = String(format: "%.6f", sample.coordinate.longitude)
        let time = sample.timestamp.formatted(date: .omitted, time: .standard)
        return [
            Field(label: "Time", value: time, spokenValue: time),
            sourceField(sample.source),
            Field(label: "Coordinate", value: "\(latitude), \(longitude)",
                  spokenValue: "latitude \(latitude), longitude \(longitude)"),
            metres("Horizontal accuracy", sample.horizontalAccuracy),
            speedField(sample.speed),
            metresPerSecond("Speed accuracy", sample.speedAccuracy),
            degrees("Course", sample.course),
            degrees("Course accuracy", sample.courseAccuracy),
        ]
    }

    static func spokenSummary(of sample: LocationSample) -> String {
        fields(of: sample).map { "\($0.label), \($0.spokenValue)" }.joined(separator: ". ")
    }

    func start() async {
        await services.location.requestAuthorization()

        await withDiscardingTaskGroup { group in
            group.addTask { [services] in
                for await authorization in services.location.authorizationStates() {
                    await self.receive(authorization)
                }
            }
            group.addTask { [services] in
                for await sample in services.location.locationSamples() {
                    await self.receive(sample)
                }
            }
            group.addTask { [services] in
                for await sample in services.location.headingSamples() {
                    await self.receive(sample)
                }
            }
        }
    }

    private func receive(_ authorization: LocationAuthorization) { self.authorization = authorization }

    private func receive(_ sample: LocationSample) {
        sampleCount += 1
        recentSamples = Array(([sample] + recentSamples).prefix(Self.historyLimit))
        headingEstimator.update(with: sample)
        updateHeading(readingTime: sample.timestamp)
    }

    private func receive(_ sample: HeadingSample) {
        headingEstimator.update(with: sample)
        updateHeading(readingTime: sample.timestamp)
    }

    private func updateHeading(readingTime: Date) {
        let now = max(newestReadingTime ?? readingTime, readingTime)
        newestReadingTime = now
        heading = headingEstimator.heading(at: now)
    }

    private static func sourceField(_ source: LocationSource) -> Field {
        let value = switch source {
        case .gps: "GPS"
        case .ar: "AR geo-tracking"
        }
        return Field(label: "Source", value: value, spokenValue: value)
    }

    // "Unavailable" rather than 0 or blank, so a missing reading can't be mistaken for a real one
    private static func unavailable(_ label: String) -> Field {
        Field(label: label, value: "Unavailable", spokenValue: "Unavailable")
    }

    private static func metres(_ label: String, _ value: Double) -> Field {
        let number = String(format: "%.1f", value)
        return Field(label: label, value: "\(number) m", spokenValue: "\(number) metres")
    }

    private static func speedField(_ value: Double?) -> Field {
        guard let value else { return unavailable("Speed") }
        let metresPerSecond = String(format: "%.1f", value)
        let kilometresPerHour = String(format: "%.1f", value * 3.6)
        return Field(
            label: "Speed",
            value: "\(metresPerSecond) m/s (\(kilometresPerHour) km/h)",
            spokenValue: "\(metresPerSecond) metres per second, \(kilometresPerHour) kilometres per hour"
        )
    }

    private static func metresPerSecond(_ label: String, _ value: Double?) -> Field {
        guard let value else { return unavailable(label) }
        let number = String(format: "%.1f", value)
        return Field(label: label, value: "\(number) m/s", spokenValue: "\(number) metres per second")
    }

    private static func degrees(_ label: String, _ value: Double?) -> Field {
        guard let value else { return unavailable(label) }
        let number = String(format: "%.1f", value)
        return Field(label: label, value: "\(number)°", spokenValue: "\(number) degrees")
    }
}
#endif
