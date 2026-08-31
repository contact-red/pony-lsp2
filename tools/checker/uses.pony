use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive UsePackage
  """The scheme that names a Pony package: bare, or written `package:`."""
primitive UseDirective
  """A link or C-shim directive: recorded, never resolved as a package."""
primitive UseUnknown
  """A scheme ponyc's table does not have. An error there and here."""

type UseScheme is (UsePackage | UseDirective | UseUnknown)
  """
  How a `use` locator's scheme classifies under ponyc's table.
  """

class val ScannedUse
  """
  One `use` as the loader consumes it: the locator with its scheme
  classified, whether it carried an alias or a guard, and where it is
  written, in byte offsets.
  """
  let scheme: UseScheme
  let scheme_text: String val
    """The scheme as written, colon included; empty for a bare locator."""
  let locator: String val
    """The locator with any scheme prefix removed."""
  let aliased: Bool
  let guarded: Bool
  let offset: USize
  let width: USize

  new val create(
    scheme': UseScheme,
    scheme_text': String val,
    locator': String val,
    aliased': Bool,
    guarded': Bool,
    offset': USize,
    width': USize)
  =>
    scheme = scheme'
    scheme_text = scheme_text'
    locator = locator'
    aliased = aliased'
    guarded = guarded'
    offset = offset'
    width = width'

primitive ScanUses
  """
  Project every non-FFI `use` out of a tree, with its scheme classified by
  ponyc's own table (`use.c`): `package:` is the default and the only one
  that names a Pony package; `lib:`, `path:`, `cincludedir:` and `cdefine:`
  are directives the loader records and skips. Guard presence is kept
  because the package scheme forbids one, and that is a legality check the
  checker makes.
  """
  fun apply(tree: SyntaxTree val): Array[ScannedUse] val =>
    recover val
      let out = Array[ScannedUse]
      for (element, _, at, kind, width) in tree.walk() do
        if not (kind is NdUse) then
          continue
        end
        var aliased = false
        var guarded = false
        var ffi = false
        var written: String val = ""
        try
          for child in tree.children(element)? do
            match tree.kind(child)?
            | NdUseFFI => ffi = true
            | NdUseName => aliased = true
            | TkString => written = _Unquote(recover val tree.text(child)? end)
            | TkIf => guarded = true
            end
          end
        end
        if ffi or (written.size() == 0) then
          continue
        end
        (let scheme, let scheme_text, let locator) = _classify(written)
        out.push(
          ScannedUse(scheme, scheme_text, locator, aliased, guarded,
            at, width))
      end
      out
    end

  fun _classify(written: String val)
    : (UseScheme, String val, String val)
  =>
    let colon =
      try
        written.find(":")?
      else
        return (UsePackage, "", written)
      end
    let scheme_text: String val = written.substring(0, colon + 1)
    let rest: String val = written.substring(colon + 1)
    match scheme_text
    | "package:" => (UsePackage, scheme_text, rest)
    | "lib:" => (UseDirective, scheme_text, rest)
    | "path:" => (UseDirective, scheme_text, rest)
    | "cincludedir:" => (UseDirective, scheme_text, rest)
    | "cdefine:" => (UseDirective, scheme_text, rest)
    else
      (UseUnknown, scheme_text, rest)
    end

primitive _Unquote
  fun apply(text: String val): String val =>
    if (text.size() >= 2) and (text.compare_sub("\"", 1) is Equal) then
      text.substring(1, text.size().isize() - 1)
    else
      text
    end
