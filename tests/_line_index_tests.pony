use "pony_test"
use "../upstream/tools/lib/ponylang/pony_syntax"

primitive \nodoc\ _LineIndexTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestEmptySourceHasOneLine)
    test(_TestLinesAndCharacters)
    test(_TestRoundTripsEveryOffset)
    test(_TestUtf16CountsCodeUnits)
    test(_TestUtf16CountsSurrogatePairsAsTwo)
    test(_TestEncodingsDisagreeAsExpected)
    test(_TestOutOfRangeIsClamped)

class \nodoc\ iso _TestEmptySourceHasOneLine is UnitTest
  fun name(): String => "line_index/an empty source has one line"

  fun apply(h: TestHelper) =>
    let index = LineIndex("")
    h.assert_eq[USize](1, index.line_count())
    (let line, let character) = index.position(0)
    h.assert_eq[USize](0, line)
    h.assert_eq[USize](0, character)

class \nodoc\ iso _TestLinesAndCharacters is UnitTest
  fun name(): String => "line_index/lines and characters"

  fun apply(h: TestHelper) =>
    //          0123 4567 8
    let index = LineIndex("ab\ncd\n")
    h.assert_eq[USize](3, index.line_count(),
      "a trailing newline leaves an empty last line")

    _At(h, index, 0, 0, 0)
    _At(h, index, 1, 0, 1)
    _At(h, index, 2, 0, 2)
    _At(h, index, 3, 1, 0)
    _At(h, index, 5, 1, 2)
    _At(h, index, 6, 2, 0)

class \nodoc\ iso _TestRoundTripsEveryOffset is UnitTest
  fun name(): String => "line_index/round trips every offset"

  fun apply(h: TestHelper) =>
    """
    Every byte offset that begins a character must survive being turned
    into a position and back.
    """
    let sources: Array[String val] = [
      ""
      "one line"
      "a\nb\nc"
      "\n\n\n"
      "café naïve\nsecond line\n"
      "\U01F600 emoji first\nthen ascii\n"
    ]
    for src in sources.values() do
      let index = LineIndex(src)
      var byte: USize = 0
      while byte <= src.size() do
        (let line, let character) = index.position(byte)
        let back = index.offset(line, character)
        h.assert_eq[USize](byte, back,
          "offset " + byte.string() + " in: " + src)
        // Advance past the whole character, not one byte, or the walk
        // asks about a position inside an encoding.
        byte = byte + _CharBytes(src, byte)
      end
    end

class \nodoc\ iso _TestUtf16CountsCodeUnits is UnitTest
  fun name(): String => "line_index/utf-16 counts code units"

  fun apply(h: TestHelper) =>
    """
    The bug this exists to prevent. `é` is two bytes and one UTF-16 code
    unit, so a byte column and an LSP character diverge from that point on.
    """
    let src = "let x = \"café\" + y"
    let index = LineIndex(src)
    let quote = src.size() - 5

    (let line, let character) = index.position(quote)
    h.assert_eq[USize](0, line)
    h.assert_ne[USize](quote, character,
      "a byte offset and a UTF-16 character must differ after a non-ASCII " +
      "character, or this test proves nothing")
    h.assert_eq[USize](quote - 1, character,
      "one two-byte character means one unit fewer")

class \nodoc\ iso _TestUtf16CountsSurrogatePairsAsTwo is UnitTest
  fun name(): String => "line_index/utf-16 counts a surrogate pair as two"

  fun apply(h: TestHelper) =>
    """
    An emoji is four bytes, one code point, and two UTF-16 code units.
    """
    let src = "\U01F600x"
    let index = LineIndex(src)
    (_, let character) = index.position(4)
    h.assert_eq[USize](2, character)

class \nodoc\ iso _TestEncodingsDisagreeAsExpected is UnitTest
  fun name(): String => "line_index/the three encodings disagree"

  fun apply(h: TestHelper) =>
    """
    Four bytes, two UTF-16 units, one code point -- for the same character.
    A server that does not say which it means is guessing on the client's
    behalf.
    """
    let src = "\U01F600x"
    (_, let bytes) = LineIndex(src, Utf8).position(4)
    (_, let units) = LineIndex(src, Utf16).position(4)
    (_, let points) = LineIndex(src, Utf32).position(4)
    h.assert_eq[USize](4, bytes)
    h.assert_eq[USize](2, units)
    h.assert_eq[USize](1, points)

class \nodoc\ iso _TestOutOfRangeIsClamped is UnitTest
  fun name(): String => "line_index/out of range is clamped"

  fun apply(h: TestHelper) =>
    """
    A client may ask about a position an edit has already removed, so
    neither direction may fail.
    """
    let src = "ab\ncd\n"
    let index = LineIndex(src)
    h.assert_eq[USize](src.size(), index.offset(99, 0))
    h.assert_eq[USize](2, index.offset(0, 99),
      "clamped to the line's content, not to its newline")
    h.assert_eq[USize](6, LineIndex("ab\r\ncd\r\n").offset(1, 99),
      "a CRLF terminator is not part of the line either")
    (let line, _) = index.position(9999)
    h.assert_eq[USize](2, line)

primitive \nodoc\ _At
  fun apply(
    h: TestHelper,
    index: LineIndex,
    byte: USize,
    line: USize,
    character: USize)
  =>
    (let l, let c) = index.position(byte)
    h.assert_eq[USize](line, l, "line at byte " + byte.string())
    h.assert_eq[USize](character, c, "character at byte " + byte.string())
    h.assert_eq[USize](byte, index.offset(line, character),
      "offset back from " + line.string() + ":" + character.string())

primitive \nodoc\ _CharBytes
  fun apply(src: String val, at: USize): USize =>
    try
      (_, let bytes) = src.utf32(at.isize())?
      bytes.usize().max(1)
    else
      1
    end
