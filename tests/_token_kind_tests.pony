use "collections"
use "pony_test"
use "../upstream/tools/lib/ponylang/pony_syntax"

primitive \nodoc\ _TokenKindTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestKeywordsRoundTrip)
    test(_TestKeywordsRejectsNonKeywords)
    test(_TestSymbolsLongestFirst)
    test(_TestSymbolsAreDistinct)
    test(_TestNewlineForm)
    test(_TestKindNamesAreDistinct)
    test(_TestFixedTextIsNonEmpty)

class \nodoc\ iso _TestKeywordsRoundTrip is UnitTest
  fun name(): String => "token_kind/keywords round-trip"

  fun apply(h: TestHelper) =>
    """
    Every kind whose text is fixed and which `Keywords` recognises must map
    back to itself. This is what stops the two generated tables drifting.
    """
    var checked: USize = 0
    for kind in AllTokenKinds().values() do
      match kind.text()
      | let t: String val =>
        match Keywords(t)
        | let found: TokenKind =>
          h.assert_eq[String](kind.name(), found.name(),
            "Keywords(\"" + t + "\") gave " + found.name())
          checked = checked + 1
        end
      end
    end
    // ponyc's keyword table has 77 entries; fewer would mean the generator
    // silently dropped some.
    h.assert_eq[USize](77, checked, "wrong number of keywords recognised")

class \nodoc\ iso _TestKeywordsRejectsNonKeywords is UnitTest
  fun name(): String => "token_kind/keywords rejects non-keywords"

  fun apply(h: TestHelper) =>
    for s in ["".clone(); "nonsense"; "Use"; "use2"; "clas"; "("].values() do
      h.assert_is[(TokenKind | None)](None, Keywords(consume s))
    end

class \nodoc\ iso _TestSymbolsLongestFirst is UnitTest
  fun name(): String => "token_kind/symbols are longest first"

  fun apply(h: TestHelper) =>
    """
    A scanner takes the first entry that matches, so a shorter symbol must
    never precede a longer one -- otherwise `<` would shadow `<<~`.
    """
    var previous: USize = USize.max_value()
    for (text, _) in Symbols().values() do
      h.assert_true(text.size() <= previous,
        "\"" + text + "\" of length " + text.size().string() +
        " follows an entry of length " + previous.string())
      previous = text.size()
    end

class \nodoc\ iso _TestSymbolsAreDistinct is UnitTest
  fun name(): String => "token_kind/symbols are distinct"

  fun apply(h: TestHelper) =>
    """
    ponyc's table lists `(`, `[`, `-` and `-~` more than once and its scan
    reaches only the first. A duplicate here would be an entry that can
    never match.
    """
    let seen = Set[String]
    for (text, _) in Symbols().values() do
      h.assert_false(seen.contains(text), "duplicate symbol: " + text)
      seen.set(text)
    end

class \nodoc\ iso _TestNewlineForm is UnitTest
  fun name(): String => "token_kind/newline form"

  fun apply(h: TestHelper) =>
    // The four ponyc maps, and only when a newline precedes.
    h.assert_is[TokenKind](TkLparenNew, NewlineForm(TkLparen, true))
    h.assert_is[TokenKind](TkLsquareNew, NewlineForm(TkLsquare, true))
    h.assert_is[TokenKind](TkMinusNew, NewlineForm(TkMinus, true))
    h.assert_is[TokenKind](TkMinusTildeNew, NewlineForm(TkMinusTilde, true))

    h.assert_is[TokenKind](TkLparen, NewlineForm(TkLparen, false))
    h.assert_is[TokenKind](TkMinus, NewlineForm(TkMinus, false))

    // Everything else is unchanged either way.
    h.assert_is[TokenKind](TkPlus, NewlineForm(TkPlus, true))
    h.assert_is[TokenKind](TkId, NewlineForm(TkId, true))

class \nodoc\ iso _TestKindNamesAreDistinct is UnitTest
  fun name(): String => "token_kind/names are distinct"

  fun apply(h: TestHelper) =>
    """
    `name()` identifies a kind in diagnostics and in test failures, so two
    kinds sharing one would make a failure point at the wrong place.
    """
    let seen = Set[String]
    for kind in AllTokenKinds().values() do
      h.assert_false(seen.contains(kind.name()), "duplicate: " + kind.name())
      seen.set(kind.name())
    end
    h.assert_eq[USize](145, seen.size(), "wrong number of token kinds")

class \nodoc\ iso _TestFixedTextIsNonEmpty is UnitTest
  fun name(): String => "token_kind/fixed text is non-empty"

  fun apply(h: TestHelper) =>
    """
    A kind either fixes its text or it does not. An empty string would be a
    third state that the width of a token could not distinguish from the
    first.
    """
    for kind in AllTokenKinds().values() do
      match kind.text()
      | let t: String val =>
        h.assert_ne[USize](0, t.size(), kind.name() + " has empty text")
      end
    end
