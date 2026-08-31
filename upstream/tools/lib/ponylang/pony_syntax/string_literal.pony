primitive StringLiteralValue
  """
  The value of a string literal as written in source: quotes stripped,
  and for the ordinary quoted form, escapes decoded the way ponyc's
  lexer decodes them. A triple-quoted string takes no escapes.
  """
  fun apply(text: String val): String val =>
    if (text.size() >= 6) and
      (text.compare_sub("\"\"\"", 3) is Equal) and
      (text.compare_sub("\"\"\"", 3, (text.size() - 3).isize()) is Equal)
    then
      text.substring(3, text.size().isize() - 3)
    elseif (text.size() >= 2) and (text.compare_sub("\"", 1) is Equal) then
      _decode(text.substring(1, text.size().isize() - 1))
    else
      text
    end

  fun _decode(text: String val): String val =>
    if not text.contains("\\") then
      return text
    end
    let out = recover iso String(text.size()) end
    var i: USize = 0
    while i < text.size() do
      let c = try text(i)? else break end
      if (c != '\\') or ((i + 1) >= text.size()) then
        out.push(c)
        i = i + 1
        continue
      end
      let e = try text(i + 1)? else break end
      i = i + 2
      match e
      | 'a' => out.push(0x07)
      | 'b' => out.push(0x08)
      | 'e' => out.push(0x1B)
      | 'f' => out.push(0x0C)
      | 'n' => out.push('\n')
      | 'r' => out.push('\r')
      | 't' => out.push('\t')
      | 'v' => out.push(0x0B)
      | '\\' => out.push('\\')
      | '0' => out.push(0)
      | '\'' => out.push('\'')
      | '"' => out.push('"')
      | 'x' =>
        (let value, let used) = _hex(text, i, 2)
        out.push(value.u8())
        i = i + used
      | 'u' =>
        (let value, let used) = _hex(text, i, 4)
        out.push_utf32(value)
        i = i + used
      | 'U' =>
        (let value, let used) = _hex(text, i, 6)
        out.push_utf32(value)
        i = i + used
      else
        // Not an escape ponyc's lexer accepts; a parse diagnostic has
        // already been raised, so carry the text through as written.
        out.push(c)
        out.push(e)
      end
    end
    consume out

  fun _hex(text: String val, from: USize, digits: USize): (U32, USize) =>
    var value: U32 = 0
    var used: USize = 0
    while used < digits do
      let c = try text(from + used)? else break end
      let d: U32 =
        if (c >= '0') and (c <= '9') then (c - '0').u32()
        elseif (c >= 'a') and (c <= 'f') then ((c - 'a') + 10).u32()
        elseif (c >= 'A') and (c <= 'F') then ((c - 'A') + 10).u32()
        else break
        end
      value = (value * 16) + d
      used = used + 1
    end
    (value, used)

