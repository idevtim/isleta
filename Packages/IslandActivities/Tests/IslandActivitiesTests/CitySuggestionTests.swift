import Foundation
import Testing

@testable import IslandActivities

@Suite("City suggestions")
struct CitySuggestionTests {

    @Test("the stored city is the pair, because the pair is what tells two Springfields apart")
    func searchTextKeepsTheRegion() {
        let london = CitySuggestion(name: "London", region: "England")
        #expect(london.searchText == "London, England")

        // A place whose name is unambiguous on earth gets no region from MapKit, and joining an
        // empty one would store a trailing comma and hand it to a geocoder.
        let unambiguous = CitySuggestion(name: "Reykjavík")
        #expect(unambiguous.searchText == "Reykjavík")
    }

    @Test("identity is the pair, so a redraw does not rebuild the list under the pointer")
    func identityIsStable() {
        let first = CitySuggestion(name: "Springfield", region: "MO, United States")
        let again = CitySuggestion(name: "Springfield", region: "MO, United States")
        let other = CitySuggestion(name: "Springfield", region: "IL, United States")
        #expect(first.id == again.id)
        #expect(first.id != other.id)
    }

    @Test("one letter is not a query")
    func minimumLength() {
        // One letter matches most of the earth, and the list it produces is noise the user has to
        // read past on the way to the second keystroke.
        #expect(!CityQuery.isSearchable("L"))
        #expect(CityQuery.isSearchable("Lo"))
    }

    @Test("a field cleared back to whitespace has been cleared")
    func whitespaceIsNotAQuery() {
        #expect(!CityQuery.isSearchable("   "))
        #expect(!CityQuery.isSearchable(""))
        #expect(!CityQuery.isSearchable(" \n"))
        #expect(CityQuery.normalized("  London  ") == "London")
        // Trimmed before it is measured, so " L " is one letter rather than three characters.
        #expect(!CityQuery.isSearchable(" L "))
    }
}
