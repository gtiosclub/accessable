import Foundation
import Testing
@testable import AccessAble

struct MapCreditsTests {
    @Test
    func openStreetMapCreditCarriesTheCopyrightLinkAndLicence() throws {
        let credit = try #require(MapCredits.all.first { $0.id == "openstreetmap" })
        #expect(credit.text.contains("© OpenStreetMap contributors"))
        #expect(credit.text.contains("Open Database License"))
        #expect(credit.url.host() == "www.openstreetmap.org")
        #expect(credit.url.path() == "/copyright")
    }

    @Test
    func stadiaCreditNamesValhallaAndLinksToStadiaMaps() throws {
        let credit = try #require(MapCredits.all.first { $0.id == "stadia" })
        #expect(credit.text.contains("Stadia Maps"))
        #expect(credit.text.contains("Valhalla"))
        #expect(credit.url.host() == "stadiamaps.com")
    }

    @Test
    func everyCreditHasReadableTextAndASecureLink() {
        #expect(Set(MapCredits.all.map(\.id)).count == MapCredits.all.count)
        for credit in MapCredits.all {
            #expect(credit.url.scheme == "https")
            #expect(credit.url.host() != nil)
            #expect(!credit.heading.isEmpty && !credit.text.isEmpty && !credit.linkTitle.isEmpty)
        }
    }
}
