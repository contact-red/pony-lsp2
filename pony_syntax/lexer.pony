class TokenStream
  """
  A source and the tokens that cover it.

  Lossless: every byte of `source` lies in exactly one token, so
  concatenating each token's text reproduces the source. Whitespace and
  comments are tokens like any other.

  Error-tolerant: no input fails to produce a stream. Bytes that cannot be
  interpreted become `TkLexError` tokens and scanning continues.

  Tokens carry a width and not an offset, so an edit changes only the tokens
  it touches. A consumer that needs offsets accumulates them while walking;
  `values()` does this.
  """
  let source: String val
  embed _tokens: Array[(TokenKind, U32)] = Array[(TokenKind, U32)]

  new iso create(source': String val) =>
    source = source'
    _scan()

  fun size(): USize =>
    """
    The number of tokens, including the final `TkEof`.
    """
    _tokens.size()

  fun apply(i: USize): (TokenKind, U32) ? =>
    """
    The kind and width of token `i`.
    """
    _tokens(i)?

  fun values(): TokenIterator^ =>
    """
    Every token as `(kind, offset, width)`, with offsets accumulated as the
    walk proceeds.
    """
    TokenIterator._create(this)

  fun _byte(i: USize): U8 =>
    """
    The byte at `i`, or 0 past the end. Zero is not a byte any Pony source
    construct starts with, so callers may look ahead without bounds checks.
    """
    try source(i)? else 0 end

  fun tag _is_space(c: U8): Bool =>
    (c == ' ') or (c == '\t') or (c == '\r') or (c == '\n')

  fun tag _is_digit(c: U8): Bool =>
    (c >= '0') and (c <= '9')

  fun tag _is_ident_start(c: U8): Bool =>
    ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or (c == '_')

  fun tag _is_ident(c: U8): Bool =>
    _is_ident_start(c) or _is_digit(c) or (c == '\'')

  fun ref _push(kind: TokenKind, from: USize, to: USize) =>
    _tokens.push((kind, (to - from).u32()))

  fun ref _scan() =>
    """
    ponyc's `lexer_next` loop, with trivia emitted rather than skipped.

    `after_newline` is ponyc's `newline` flag: it decides whether `(`, `[`
    and `-` take their newline form, which is how Pony tells a call from a
    grouped expression across a line break. A nested comment clears it, so
    that a newline inside a comment does not reach symbol disambiguation.
    """
    let n = source.size()
    var i: USize = 0
    var after_newline = true

    while i < n do
      let c = _byte(i)

      if _is_space(c) then
        (let j, let saw_newline) = _space(i, n)
        _push(TkWhitespace, i, j)
        if saw_newline then after_newline = true end
        i = j
      elseif (c == '/') and (_byte(i + 1) == '/') then
        let j = _line_comment(i, n)
        _push(TkLineComment, i, j)
        i = j
      elseif (c == '/') and (_byte(i + 1) == '*') then
        let j = _nested_comment(i, n)
        _push(TkNestedComment, i, j)
        after_newline = false
        i = j
      else
        (let kind, let j) = _token(i, n, after_newline)
        _push(kind, i, j)
        after_newline = false
        i = j
      end
    end

    _push(TkEof, i, i)

  fun _space(from: USize, n: USize): (USize, Bool) =>
    """
    A maximal run of whitespace, and whether it contains a real newline.
    """
    var j = from
    var saw_newline = false
    while j < n do
      let c = _byte(j)
      if not _is_space(c) then break end
      if c == '\n' then saw_newline = true end
      j = j + 1
    end
    (j, saw_newline)

  fun _line_comment(from: USize, n: USize): USize =>
    """
    A `//` comment, up to but not including the newline that ends it. The
    newline is whitespace and belongs to the next token.
    """
    var j = from + 2
    while (j < n) and (_byte(j) != '\n') do
      j = j + 1
    end
    j

  fun _nested_comment(from: USize, n: USize): USize =>
    """
    A `/* */` comment, which may contain further `/* */` pairs. An
    unterminated one runs to the end of the source rather than failing.
    """
    var j = from + 2
    var depth: USize = 1
    while (j < n) and (depth > 0) do
      if (_byte(j) == '*') and (_byte(j + 1) == '/') then
        depth = depth - 1
        j = j + 2
      elseif (_byte(j) == '/') and (_byte(j + 1) == '*') then
        depth = depth + 1
        j = j + 2
      else
        j = j + 1
      end
    end
    j

  fun _token(from: USize, n: USize, after_newline: Bool)
    : (TokenKind, USize)
  =>
    """
    One non-trivia token: its kind, and where it ends.
    """
    let c = _byte(from)

    if c == '"' then
      _string(from, n)
    elseif c == '\'' then
      _character(from, n)
    elseif c == '#' then
      _hash(from, n)
    elseif _is_digit(c) then
      _number(from, n)
    elseif _is_ident_start(c) then
      _identifier(from, n)
    else
      _symbol(from, n, after_newline)
    end

  fun _identifier(from: USize, n: USize): (TokenKind, USize) =>
    """
    An identifier, or the keyword it spells. Pony allows a trailing prime,
    so `x'` and `x''` are identifiers.
    """
    var j = from
    while (j < n) and _is_ident(_byte(j)) do
      j = j + 1
    end
    let word = source.substring(from.isize(), j.isize())
    match Keywords(consume word)
    | let k: TokenKind => (k, j)
    else
      (TkId, j)
    end

  fun _hash(from: USize, n: USize): (TokenKind, USize) =>
    """
    A generic capability -- `#read`, `#send`, `#share`, `#alias`, `#any` --
    or a bare `#`, which is `TkConstant`.
    """
    var j = from + 1
    while (j < n) and _is_ident(_byte(j)) do
      j = j + 1
    end
    let word = source.substring(from.isize(), j.isize())
    match Keywords(consume word)
    | let k: TokenKind => (k, j)
    else
      (TkConstant, from + 1)
    end

  fun _symbol(from: USize, n: USize, after_newline: Bool)
    : (TokenKind, USize)
  =>
    """
    The longest symbol that matches here, in its newline form where it has
    one. A byte that starts no symbol is one `TkLexError`, so that scanning
    continues rather than stopping at the first bad character.
    """
    for (text, kind) in Symbols().values() do
      if source.at(text, from.isize()) then
        return (NewlineForm(kind, after_newline), from + text.size())
      end
    end
    (TkLexError, from + 1)

  fun _number(from: USize, n: USize): (TokenKind, USize) =>
    """
    An integer or a float. A `.` begins a fraction only when a digit
    follows it, so that `1.string()` is an integer, a dot and a method
    name rather than a malformed float.
    """
    var j = from
    var kind: TokenKind = TkInt

    if (_byte(from) == '0') and
      ((_byte(from + 1) == 'x') or (_byte(from + 1) == 'X'))
    then
      j = _hex_digits(from + 2, n)
      return (TkInt, j)
    end

    if (_byte(from) == '0') and
      ((_byte(from + 1) == 'b') or (_byte(from + 1) == 'B'))
    then
      j = _binary_digits(from + 2, n)
      return (TkInt, j)
    end

    j = _decimal_digits(from, n)

    if (_byte(j) == '.') and _is_digit(_byte(j + 1)) then
      kind = TkFloat
      j = _decimal_digits(j + 1, n)
    end

    if (_byte(j) == 'e') or (_byte(j) == 'E') then
      var k = j + 1
      if (_byte(k) == '+') or (_byte(k) == '-') then
        k = k + 1
      end
      if _is_digit(_byte(k)) then
        kind = TkFloat
        j = _decimal_digits(k, n)
      end
    end

    (kind, j)

  fun _decimal_digits(from: USize, n: USize): USize =>
    var j = from
    while (j < n) and (_is_digit(_byte(j)) or (_byte(j) == '_')) do
      j = j + 1
    end
    j

  fun _hex_digits(from: USize, n: USize): USize =>
    var j = from
    while j < n do
      let c = _byte(j)
      if _is_digit(c) or ((c >= 'a') and (c <= 'f')) or
        ((c >= 'A') and (c <= 'F')) or (c == '_')
      then
        j = j + 1
      else
        break
      end
    end
    j

  fun _binary_digits(from: USize, n: USize): USize =>
    var j = from
    while j < n do
      let c = _byte(j)
      if (c == '0') or (c == '1') or (c == '_') then
        j = j + 1
      else
        break
      end
    end
    j

  fun _string(from: USize, n: USize): (TokenKind, USize) =>
    """
    A string literal, either triple-quoted or single-quoted. An
    unterminated one is a `TkLexError` covering what remains, which is
    ponyc's verdict; it runs to the end of the source rather than failing.
    """
    if source.at("\"\"\"", from.isize()) then
      var j = from + 3
      while j < n do
        if source.at("\"\"\"", j.isize()) then
          j = j + 3
          // A run of more than three quotes closes at the last of them.
          while (j < n) and (_byte(j) == '"') do
            j = j + 1
          end
          return (TkString, j)
        end
        j = j + 1
      end
      return (TkLexError, n)
    end

    var j = from + 1
    while j < n do
      let c = _byte(j)
      if c == '\\' then
        j = j + 2
      elseif c == '"' then
        return (TkString, j + 1)
      else
        // A raw newline is allowed. ponyc's `string` scans to the closing
        // quote or to the end of the source and checks for nothing else,
        // and `files/_non_root_test.pony` relies on it.
        j = j + 1
      end
    end
    (TkLexError, n)

  fun _character(from: USize, n: USize): (TokenKind, USize) =>
    """
    A character literal, which ponyc lexes as an integer.
    """
    var j = from + 1
    while j < n do
      let c = _byte(j)
      if c == '\\' then
        j = j + 2
      elseif c == '\'' then
        return (TkInt, j + 1)
      else
        j = j + 1
      end
    end
    (TkLexError, n)

class TokenIterator is Iterator[(TokenKind, USize, USize)]
  """
  Walks a token stream, accumulating the offset that the tokens' widths
  imply.
  """
  let _stream: TokenStream box
  var _index: USize = 0
  var _offset: USize = 0

  new _create(stream: TokenStream box) =>
    _stream = stream

  fun has_next(): Bool =>
    _index < _stream.size()

  fun ref next(): (TokenKind, USize, USize) ? =>
    (let kind, let width) = _stream(_index)?
    let offset = _offset
    _index = _index + 1
    _offset = _offset + width.usize()
    (kind, offset, width.usize())
