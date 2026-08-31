use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive RenderDiag
  """
  One located diagnostic in ponyc's shape: the location line with 1-based
  line and byte column, the source line as written, and a caret under the
  column. Takes the file's `LineIndex` so a run of diagnostics over one
  file indexes the source once rather than once per diagnostic.
  """
  fun apply(
    diag: CheckDiagnostic,
    index: LineIndex val,
    info_index: (LineIndex val | None) = None)
    : String val
  =>
    recover val
      let out = String
      _render(out, diag, index, "")
      match diag.info
      | let info: CheckDiagnostic =>
        out.push('\n')
        out.append("    Info:\n")
        let idx =
          match info_index
          | let i: LineIndex val => i
          | None => index
          end
        _render(out, info, idx, "    ")
      end
      out
    end

  fun _render(
    out: String ref,
    diag: CheckDiagnostic,
    index: LineIndex val,
    indent: String val)
  =>
    (let line, let character) = index.position(diag.offset)
    out.append(indent)
    out.append(diag.file)
    out.push(':')
    out.append((line + 1).string())
    out.push(':')
    out.append((character + 1).string())
    out.append(": ")
    out.append(diag.message)
    out.push('\n')
    let line_text: String val = index.source.substring(
      index.line_start(line).isize(), index.line_end(line).isize())
    out.append(indent)
    out.append(line_text)
    out.push('\n')
    out.append(indent)
    // The pad copies the source line's tabs, as ponyc does, so the
    // caret lands under the column whatever the tab width.
    var i: USize = 0
    while i < character do
      out.push(if (try line_text(i)? else ' ' end) == '\t' then '\t'
      else ' ' end)
      i = i + 1
    end
    out.push('^')
