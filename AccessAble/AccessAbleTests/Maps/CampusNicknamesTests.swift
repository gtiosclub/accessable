import Foundation
import Testing
@testable import AccessAble

struct CampusNicknamesTests {
    @Test
    func bundledDictionaryLoadsFortyOrMoreGeorgiaTechPlaces() throws {
        let dictionary = CampusNicknameDictionary.bundled
        #expect(dictionary.places.count >= 40)

        for place in dictionary.places {
            #expect(!place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!place.nicknames.isEmpty)
            #expect((33.76...33.80).contains(place.coordinate.latitude))
            #expect((-84.42 ... -84.37).contains(place.coordinate.longitude))
        }
    }

    @Test(arguments: [
        ("culc", "Clough Undergraduate Learning Commons"),
        ("CRC", "Campus Recreation Center"),
        ("nav", "North Avenue Dining Hall"),
        ("clough", "Clough Undergraduate Learning Commons"),
        ("student center", "John Lewis Student Center"),
        ("john lewis student center", "John Lewis Student Center"),
        ("mccamish", "McCamish Pavilion"),
        ("tech green", "Tech Green"),
        ("skiles", "Skiles Classroom Building"),
        ("klaus", "Klaus Advanced Computing Building"),
        ("howey", "Howey Physics Building"),
        ("west village", "West Village Dining Commons"),
        ("north ave dining", "North Avenue Dining Hall"),
        ("brittain", "Brittain Dining Hall"),
        ("tech tower", "Tech Tower"),
        ("kessler campanile", "Kessler Campanile"),
    ])
    func shorthandQueriesBringUpExpectedPlaceFirst(query: String, expectedName: String) throws {
        let matches = CampusNicknameDictionary.bundled.matches(for: query)
        let first = try #require(matches.first)
        #expect(first.name == expectedName)
    }

    @Test(arguments: [
        ("c.u.l.c.", "Clough Undergraduate Learning Commons"),
        ("  CULC!  ", "Clough Undergraduate Learning Commons"),
        ("C.R.C.?", "Campus Recreation Center"),
        ("NaV...", "North Avenue Dining Hall"),
        ("north ave. dining!", "North Avenue Dining Hall"),
        ("d.m. smith", "D. M. Smith Building"),
        ("dm smith", "D. M. Smith Building"),
        ("es&t", "Ford Environmental Science and Technology Building"),
        ("est", "Ford Environmental Science and Technology Building"),
        ("okeefe", "O'Keefe Building"),
        ("O’Keefe", "O'Keefe Building"),
        ("tech-tower", "Tech Tower"),
        ("bunger henry", "Bunger-Henry Building"),
    ])
    func matchingIgnoresCaseAndPunctuation(query: String, expectedName: String) throws {
        let matches = CampusNicknameDictionary.bundled.matches(for: query)
        let first = try #require(matches.first)
        #expect(first.name == expectedName)
    }

    @Test
    func prefixAndShortAcronymMatchingAvoidFalsePositives() throws {
        let dictionary = CampusNicknameDictionary.bundled

        #expect(dictionary.matches(for: "west vil").first?.name == "West Village Dining Commons")
        #expect(dictionary.matches(for: "klau").first?.name == "Klaus Advanced Computing Building")

        let icMatches = dictionary.matches(for: "ic")
        #expect(icMatches.first?.name == "Instructional Center")
        #expect(!icMatches.contains { $0.name == "Pettit Microelectronics Research Center" })
        #expect(dictionary.matches(for: "   ").isEmpty)
    }

    @Test
    func mergePlacesDictionaryMatchesFirstAndRemovesMapKitDuplicates() {
        let dictionary = CampusNicknameDictionary.bundled
        let matches = dictionary.matches(for: "culc")

        let mapKitResults = [
            SearchSuggestion(title: "Clough Undergraduate Learning Commons", subtitle: "266 4th St NW, Atlanta, GA"),
            SearchSuggestion(title: "G. Wayne Clough Undergraduate Learning Commons", subtitle: "Atlanta, GA"),
            SearchSuggestion(title: "Clough Undergraduate Learning Commons (CULC)", subtitle: "Georgia Tech"),
            SearchSuggestion(title: "C.U.L.C.", subtitle: "Atlanta, GA"),
            SearchSuggestion(title: "CULC Room 152", subtitle: "266 4th St NW, Atlanta, GA"),
            SearchSuggestion(title: "Kaldi's Coffee", subtitle: "266 4th St NW, Atlanta, GA"),
            SearchSuggestion(title: "Kaldi's Coffee", subtitle: "266 4th St NW, Atlanta, GA"),
        ]

        let merged = dictionary.merge(matches: matches, mapKitResults: mapKitResults)

        #expect(merged.map(\.title) == [
            "Clough Undergraduate Learning Commons",
            "CULC Room 152",
            "Kaldi's Coffee",
        ])
    }

    @Test
    func deduplicateRemovesCampusPrefixedAndAliasDuplicates() {
        let dictionary = CampusNicknameDictionary.bundled
        let studentCenter = dictionary.matches(for: "student center")
        let mccamish = dictionary.matches(for: "mccamish")

        let studentMapKit = [
            SearchSuggestion(title: "Georgia Tech Student Center", subtitle: "Atlanta, GA"),
            SearchSuggestion(title: "Wenn Student Center", subtitle: "Ferst Dr NW"),
            SearchSuggestion(title: "John Lewis Student Center - Georgia Tech", subtitle: "Atlanta, GA"),
            SearchSuggestion(title: "Student Center Parking Deck", subtitle: "351 Ferst Dr NW"),
        ]
        #expect(
            dictionary.deduplicate(studentMapKit, against: studentCenter).map(\.title)
                == ["Student Center Parking Deck"]
        )

        let mccamishMapKit = [
            SearchSuggestion(title: "Alexander Memorial Coliseum", subtitle: "965 Fowler St NW"),
            SearchSuggestion(title: "McCamish Pavilion Lot", subtitle: "Atlanta, GA"),
        ]
        #expect(
            dictionary.deduplicate(mccamishMapKit, against: mccamish).map(\.title)
                == ["McCamish Pavilion Lot"]
        )
    }

    @Test
    func deduplicateRemovesResultsWithinFiftyMetresOfAMatch() throws {
        let dictionary = CampusNicknameDictionary.bundled
        let crc = try #require(dictionary.matches(for: "crc").first)
        let near = GeoCoordinate(latitude: crc.coordinate.latitude + 0.0003, longitude: crc.coordinate.longitude)
        let far = GeoCoordinate(latitude: crc.coordinate.latitude + 0.0006, longitude: crc.coordinate.longitude)
        #expect(GeoMath.distance(from: crc.coordinate, to: near) < 50)
        #expect(GeoMath.distance(from: crc.coordinate, to: far) > 50)

        let mapKit = [
            SearchSuggestion(title: "GT Rec Aquatic Center", subtitle: "Ferst Dr NW", coordinate: near),
            SearchSuggestion(title: "Fitten Hall", subtitle: "Ferst Dr NW", coordinate: far),
        ]
        #expect(dictionary.deduplicate(mapKit, against: [crc]).map(\.title) == ["Fitten Hall"])
    }

    @Test
    func malformedFileGivesAnEmptyDictionary() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "campus-nicknames-\(UUID()).json")
        try Data("{ \"places\": [ { \"name\": ".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(CampusNicknameDictionary.load(from: url).places.isEmpty)
        #expect(CampusNicknameDictionary.load(from: nil).places.isEmpty)
    }
}

@MainActor
struct DestinationAutocompleterNicknameTests {
    @Test
    func checksDictionaryBeforeMapKitShowsMatchesFirstAndRemovesDuplicates() async throws {
        let fakeMapKit = FakeMapKitAutocompleter()
        let autocompleter = DestinationAutocompleter(dictionary: .bundled, mapKit: fakeMapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "culc")

        // Dictionary match arrives immediately before MapKit responds.
        let initial = try #require(await iterator.next())
        #expect(try initial.get().map(\.title) == ["Clough Undergraduate Learning Commons"])
        #expect(fakeMapKit.recordedFragments == ["culc"])

        // When MapKit returns duplicates and an extra room result, duplicates are stripped.
        fakeMapKit.onResults?([
            SearchSuggestion(title: "Clough Undergraduate Learning Commons", subtitle: "Atlanta, GA"),
            SearchSuggestion(title: "CULC", subtitle: "Georgia Tech"),
            SearchSuggestion(title: "CULC Room 152", subtitle: "266 4th St NW"),
        ])

        let merged = try #require(await iterator.next())
        #expect(try merged.get().map(\.title) == [
            "Clough Undergraduate Learning Commons",
            "CULC Room 152",
        ])
    }

    @Test
    func resolvesDictionaryMatchesDirectlyWithoutCallingMapKitResolve() async throws {
        let fakeMapKit = FakeMapKitAutocompleter()
        let autocompleter = DestinationAutocompleter(dictionary: .bundled, mapKit: fakeMapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "CRC")

        let firstResult = try #require(await iterator.next())
        let crcSuggestion = try #require(try firstResult.get().first)
        #expect(crcSuggestion.title == "Campus Recreation Center")

        let destination = try await autocompleter.resolve(crcSuggestion)
        #expect(destination.name == "Campus Recreation Center")
        #expect(abs(destination.coordinate.latitude - 33.775662) < 0.0001)
        #expect(abs(destination.coordinate.longitude - (-84.404041)) < 0.0001)
        #expect(fakeMapKit.resolvedSuggestions.isEmpty)

        // Non-dictionary MapKit suggestions still resolve via MapKit.
        let extra = SearchSuggestion(title: "CULC Room 152", subtitle: "266 4th St NW")
        fakeMapKit.onResults?([extra])
        _ = await iterator.next()
        let extraDestination = try await autocompleter.resolve(extra)
        #expect(extraDestination.name == "CULC Room 152")
        #expect(fakeMapKit.resolvedSuggestions == [extra])
    }

    @Test
    func preservesDictionaryMatchesWhenMapKitFailsAndClearsOnEmptyQuery() async throws {
        let fakeMapKit = FakeMapKitAutocompleter()
        let autocompleter = DestinationAutocompleter(dictionary: .bundled, mapKit: fakeMapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "nav")

        let initial = try #require(await iterator.next())
        #expect(try initial.get().first?.title == "North Avenue Dining Hall")

        fakeMapKit.onError?(.suggestionsUnavailable)
        let afterError = try #require(await iterator.next())
        #expect(try afterError.get().first?.title == "North Avenue Dining Hall")

        autocompleter.update(query: "   ")
        let cleared = try #require(await iterator.next())
        #expect(try cleared.get().isEmpty)
        #expect(fakeMapKit.cancelCount == 1)

        // When no dictionary match exists, MapKit errors still surface.
        autocompleter.update(query: "nonexistent campus place")
        fakeMapKit.onError?(.suggestionsUnavailable)
        let unavailable = try #require(await iterator.next())
        if case .failure(.suggestionsUnavailable) = unavailable {
            // Expected
        } else {
            Issue.record("Expected .failure(.suggestionsUnavailable), got \(unavailable)")
        }
    }

    @Test
    func searchStillWorksWhenTheDictionaryIsMalformed() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "campus-nicknames-\(UUID()).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fakeMapKit = FakeMapKitAutocompleter()
        let autocompleter = DestinationAutocompleter(dictionary: .load(from: url), mapKit: fakeMapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "culc")
        #expect(fakeMapKit.recordedFragments == ["culc"])
        fakeMapKit.onResults?([SearchSuggestion(title: "Clough Commons", subtitle: "266 4th St NW")])

        let results = try #require(await iterator.next())
        #expect(try results.get().map(\.title) == ["Clough Commons"])
    }

    @Test
    func dropsAMapKitResultOnceItsCoordinateIsWithinFiftyMetresOfAMatch() async throws {
        let fakeMapKit = FakeMapKitAutocompleter()
        let autocompleter = DestinationAutocompleter(dictionary: .bundled, mapKit: fakeMapKit)
        let crc = try #require(CampusNicknameDictionary.bundled.matches(for: "crc").first)
        let aquatic = SearchSuggestion(title: "GT Rec Aquatic Center", subtitle: "Ferst Dr NW")
        fakeMapKit.coordinates[aquatic.id] = GeoCoordinate(
            latitude: crc.coordinate.latitude + 0.0003, longitude: crc.coordinate.longitude
        )

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "crc")
        _ = await iterator.next()
        fakeMapKit.onResults?([aquatic])

        let merged = try #require(await iterator.next())
        #expect(try merged.get().map(\.title) == ["Campus Recreation Center", "GT Rec Aquatic Center"])
        let located = try #require(await iterator.next())
        #expect(try located.get().map(\.title) == ["Campus Recreation Center"])
    }
}

@MainActor
private final class FakeMapKitAutocompleter: MapKitAutocompleting {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?
    private(set) var recordedFragments: [String] = []
    private(set) var resolvedSuggestions: [SearchSuggestion] = []
    private(set) var cancelCount = 0
    var coordinates: [SearchSuggestion.ID: GeoCoordinate] = [:]

    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate? {
        coordinates[suggestion.id]
    }

    func update(fragment: String) {
        recordedFragments.append(fragment)
    }

    func cancel() {
        cancelCount += 1
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        resolvedSuggestions.append(suggestion)
        return Destination(
            name: suggestion.title,
            coordinate: GeoCoordinate(latitude: 33.774220, longitude: -84.396299),
            address: suggestion.subtitle
        )
    }
}
