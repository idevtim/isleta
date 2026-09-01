import Foundation

/// Finding one file among thirty, by name.
///
/// Pure and free of everything, like `ShelfContents` beside it: what counts as a match is the part
/// that is easy to get subtly wrong and impossible to check by looking at a running island, and it
/// wants to be exercised against a list of names with no files, no island and no typing.
///
/// ## Three rules, each of which is a decision
///
/// **The name, and never the path.** A path match is the obvious extra — "show me everything in
/// Downloads" — and it produces matches with no visible reason: the tile shows a file name, so a
/// shelf that answers `down` with a file called `receipt.pdf` reads as broken rather than as
/// clever. It would also put the shape of someone's home directory into a search they can see the
/// results of but not the reason for. If searching by folder is ever wanted, the tile has to say
/// which folder first.
///
/// **Substring, not fuzzy.** A subsequence matcher ("dcm" finds `document.md`) is what an editor's
/// file switcher does, over hundreds of files, with the matched characters highlighted so the
/// answer explains itself. Over thirty tiles 50pt wide, with no room to highlight anything, it
/// mostly produces matches the user cannot account for. Substring is the rule a person can predict
/// without being taught it.
///
/// **Every token, in any order.** `report pdf` finds `Q3 report.pdf` and `report-final.pdf` and
/// nothing else. Typing more can only ever narrow, which is the property that makes a search field
/// feel like it is working: a query that suddenly matched *more* as it grew would read as a fault.
public enum ShelfSearch {

    /// The tokens a query actually asks for. Empty for a query that is only whitespace, which is
    /// not a search — it is a field the user has clicked into and not typed in yet.
    public static func tokens(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether a query narrows anything at all. False for empty and for whitespace, and it is the
    /// same question `filter` asks — stated once so the header and the list cannot disagree about
    /// whether a search is running.
    public static func isActive(_ query: String) -> Bool {
        !tokens(in: query).isEmpty
    }

    /// Whether one name answers a query.
    ///
    /// Case- and diacritic-insensitive: `resume` finds `Résumé.pdf`, which a user typing on a
    /// British keyboard cannot otherwise reach at all. Both flags together, because either alone
    /// leaves a name that is unreachable by any spelling a person would try.
    public static func matches(name: String, query: String) -> Bool {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            name.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The items a query leaves on screen, **in the shelf's own order**.
    ///
    /// Never sorted by relevance. The shelf's order is the user's — they put it there, and after
    /// 1.5.0 they can drag it there — so a search that reordered the tiles would be answering a
    /// question about *ranking* that nobody asked, and would leave the user hunting for the file
    /// that was third a moment ago. A filter hides; it does not rearrange.
    public static func filter(_ items: [ShelfItem], query: String) -> [ShelfItem] {
        guard isActive(query) else { return items }
        return items.filter { matches(name: $0.name, query: query) }
    }
}
