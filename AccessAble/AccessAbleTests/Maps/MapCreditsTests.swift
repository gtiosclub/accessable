import Foundation
import Testing
@testable import AccessAble

struct MapCreditsTests {
    @Test
    func openStreetMapCreditCarriesTheCopyrightLinkAndLicence() throws {
        let credit = try #require(MapCredits.all.first { $0.id == "openstreetmap" })
        #expect(credit.text.contains("© OpenStreetMap contributors"))
        #expect(credit.text.contains("Open Database License"))
        #expect(credit.url.absoluteString == "https://www.openstreetmap.org/copyright")
    }

    @Test
    func stadiaCreditLinksToStadiaMaps() throws {
        let credit = try #require(MapCredits.all.first { $0.id == "stadia" })
        #expect(credit.text.contains("Stadia Maps"))
        #expect(credit.url.host() == "stadiamaps.com")
    }

    @Test
    func everyLinkSaysItOpensInSafari() {
        for credit in MapCredits.all {
            #expect(credit.linkAccessibilityLabel.hasSuffix("opens in Safari"))
            #expect(credit.url.scheme == "https")
        }
    }
}
