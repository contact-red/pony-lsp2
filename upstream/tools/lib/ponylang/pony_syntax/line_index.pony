primitive Utf8
  """
  Positions are byte offsets.
  """
  fun name(): String val => "utf-8"

primitive Utf16
  """
  Positions are UTF-16 code units. What the Language Server Protocol means
  by a character unless a server says otherwise.
  """
  fun name(): String val => "utf-16"

primitive Utf32
  """
  Positions are Unicode code points.
  """
  fun name(): String val => "utf-32"

type PositionEncoding is (Utf8 | Utf16 | Utf32)
  """
  How a position counts along a line.
  """

class val LineIndex
  """
  Maps between a byte offset and a zero-based line and character.

  The tree works in byte offsets, because that is what a width is. A client
  works in lines and characters, and in units it chooses. This is the only
  thing that knows about both, so it is the only thing that has to be told
  the encoding.

  That matters more than it looks. libponyc counts a token's column in
  bytes, and pony-lsp passes that straight through as an LSP character --
  which is defined as a UTF-16 code unit by default. On a line containing
  anything outside ASCII, every position it reports is wrong by the extra
  bytes. Hover lands in the wrong place, which is cosmetic; rename returns
  edit ranges the client applies verbatim, which is not.
  """
  let source: String val
  let encoding: PositionEncoding
  let _line_starts: Array[USize] val
    """
    The byte offset at which each line begins. Always starts with 0, so
    there is always at least one line, even in an empty source.
    """

  new val create(
    source': String val,
    encoding': PositionEncoding = Utf16)
  =>
    source = source'
    encoding = encoding'
    _line_starts =
      recover val
        let starts = Array[USize](16)
        starts.push(0)
        var i: USize = 0
        while i < source'.size() do
          try
            if source'(i)? == '\n' then
              starts.push(i + 1)
            end
          end
          i = i + 1
        end
        starts
      end

  fun line_count(): USize =>
    """
    How many lines the source has. A source with no newline has one line;
    a source ending in a newline has an empty line after it.
    """
    _line_starts.size()

  fun line_start(line: USize): USize =>
    """
    The byte offset at which `line` begins, clamped to the source.
    """
    try
      _line_starts(line)?
    else
      source.size()
    end

  fun line_end(line: USize): USize =>
    """
    The byte offset at which `line`'s content ends, before its terminator.

    A line's length excludes the newline that ends it, so a character
    position is never inside one. Clamping to the next line's start instead
    would let `offset(line, huge)` land on the newline, and the position
    that comes back for it names the next line.
    """
    if (line + 1) >= _line_starts.size() then
      return source.size()
    end
    var stop = line_start(line + 1)
    if stop > line_start(line) then
      stop = stop - 1
      try
        if (stop > line_start(line)) and (source(stop - 1)? == '\r') then
          stop = stop - 1
        end
      end
    end
    stop

  fun position(byte: USize): (USize, USize) =>
    """
    The zero-based line and character at byte offset `byte`.
    """
    let line = _line_of(byte)
    (line, _units(line_start(line), byte.min(source.size())))

  fun offset(line: USize, character: USize): USize =>
    """
    The byte offset of a zero-based line and character.

    A character past the end of its line gives the line's end, and a line
    past the end of the source gives the source's end, because a client may
    ask about a position that an edit has since removed.
    """
    let from = line_start(line)
    let limit = line_end(line)

    match encoding
    | Utf8 => (from + character).min(limit)
    else
      var i = from
      var seen: USize = 0
      while (i < limit) and (seen < character) do
        (let width, let bytes) = _step(i)
        seen = seen + width
        i = i + bytes
      end
      i.min(limit)
    end

  fun _line_of(byte: USize): USize =>
    """
    The line containing byte offset `byte`, by binary search.
    """
    var low: USize = 0
    var high = _line_starts.size()
    while (high - low) > 1 do
      let mid = low + ((high - low) / 2)
      if line_start(mid) <= byte then
        low = mid
      else
        high = mid
      end
    end
    low

  fun _units(from: USize, to: USize): USize =>
    """
    How many units of the chosen encoding lie between two byte offsets.
    """
    match encoding
    | Utf8 => to - from
    else
      var i = from
      var total: USize = 0
      while i < to do
        (let width, let bytes) = _step(i)
        total = total + width
        i = i + bytes
      end
      total
    end

  fun _step(i: USize): (USize, USize) =>
    """
    The unit width and byte length of the character at `i`.

    A byte that begins no valid encoding counts as one unit of one byte, so
    that a walk over invalid UTF-8 still terminates and still covers it.
    """
    try
      (let code, let bytes) = source.utf32(i.isize())?
      let width =
        match encoding
        | Utf16 => if code >= 0x10000 then USize(2) else USize(1) end
        else
          USize(1)
        end
      (width, bytes.usize().max(1))
    else
      (1, 1)
    end
