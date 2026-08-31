use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive UsePackage
  """The scheme that names a Pony package: bare, or written `package:`."""
  fun allow_name(): Bool => true
  fun allow_guard(): Bool => false
primitive UseDirective
  """A link or C-shim directive: recorded, never resolved as a package."""
  fun allow_name(): Bool => false
  fun allow_guard(): Bool => true
primitive UseUnknown
  """
  A scheme with no package handler in ponyc's table: a name the table
  does not have, or `test:`, whose handler only ponyc's own tests
  install. An error there and here.
  """
  fun allow_name(): Bool => false
  fun allow_guard(): Bool => false

type UseScheme is (UsePackage | UseDirective | UseUnknown)
  """
  How a `use` locator's scheme classifies under ponyc's table.
  """

class val ScannedUse
  """
  One `use` as the loader consumes it: the locator with its scheme
  classified, whether it carried an alias or a guard, and where its parts
  are written, in byte offsets.
  """
  let scheme: UseScheme
  let scheme_text: String val
    """
    The scheme's table name, colon included — `package:` for a bare
    locator, as written for an unknown scheme.
    """
  let locator: String val
    """The locator with any scheme prefix removed."""
  let aliased: Bool
  let guarded: Bool
  let offset: USize
  let width: USize
  let locator_offset: USize
    """Where the locator string is written; the `use` itself when absent."""
  let locator_width: USize
  let alias_offset: USize
    """Where the alias is written; the `use` itself when there is none."""
  let alias_width: USize

  new val create(
    scheme': UseScheme,
    scheme_text': String val,
    locator': String val,
    aliased': Bool,
    guarded': Bool,
    offset': USize,
    width': USize,
    locator_offset': USize,
    locator_width': USize,
    alias_offset': USize,
    alias_width': USize)
  =>
    scheme = scheme'
    scheme_text = scheme_text'
    locator = locator'
    aliased = aliased'
    guarded = guarded'
    offset = offset'
    width = width'
    locator_offset = locator_offset'
    locator_width = locator_width'
    alias_offset = alias_offset'
    alias_width = alias_width'

primitive ScanUses
  """
  Project every non-FFI `use` out of a tree, with its scheme classified
  by ponyc's own table (`use.c`): `package:` is the default and the only
  one that names a Pony package; `lib:`, `path:`, `cincludedir:` and
  `cdefine:` are directives the loader records and skips; `test:` has no
  handler outside ponyc's own tests, so it classifies as unknown. Guard
  presence is kept because the package scheme forbids one, and that is a
  legality check the checker makes.
  """
  fun apply(tree: SyntaxTree val): Array[ScannedUse] val =>
    recover val
      let out = Array[ScannedUse]

      // State for the `use` the walk is inside. The locator is the first
      // string child before any guard: a bare-string guard is also a
      // direct `TkString` child of the `NdUse` node, so scanning past
      // `TkIf` would let the guard's flag name replace the locator.
      var pending = false
      var use_end: USize = 0
      var child_depth: USize = 0
      var use_at: USize = 0
      var use_width: USize = 0
      var aliased = false
      var alias_at: USize = 0
      var alias_width: USize = 0
      var guarded = false
      var ffi = false
      var have_locator = false
      var written: String val = ""
      var written_at: USize = 0
      var written_width: USize = 0

      for (element, depth, at, kind, width) in tree.walk() do
        if pending and (element >= use_end) then
          if not ffi then
            out.push(_scanned(written, aliased, guarded, use_at, use_width,
              written_at, written_width, alias_at, alias_width))
          end
          pending = false
        end
        if kind is NdUse then
          pending = true
          use_end = element + (try tree.subtree_size(element)? else 1 end)
          child_depth = depth + 1
          use_at = at
          use_width = width
          aliased = false
          guarded = false
          ffi = false
          have_locator = false
          written = ""
          written_at = at
          written_width = width
          alias_at = at
          alias_width = width
        elseif pending and (depth == child_depth) then
          match kind
          | NdUseFFI => ffi = true
          | NdUseName =>
            aliased = true
            alias_at = at
            alias_width = width
          | TkString =>
            if (not have_locator) and (not guarded) then
              have_locator = true
              written =
                StringLiteralValue(tree.source.substring(
                  at.isize(), (at + width).isize()))
              written_at = at
              written_width = width
            end
          | TkIf => guarded = true
          end
        end
      end
      if pending and (not ffi) then
        out.push(_scanned(written, aliased, guarded, use_at, use_width,
          written_at, written_width, alias_at, alias_width))
      end
      out
    end

  fun _scanned(
    written: String val,
    aliased: Bool,
    guarded: Bool,
    use_at: USize,
    use_width: USize,
    written_at: USize,
    written_width: USize,
    alias_at: USize,
    alias_width: USize)
    : ScannedUse
  =>
    (let scheme, let scheme_text, let locator) = _classify(written)
    ScannedUse(scheme, scheme_text, locator, aliased, guarded,
      use_at, use_width, written_at, written_width, alias_at,
      alias_width)

  fun _classify(written: String val)
    : (UseScheme, String val, String val)
  =>
    """
    ponyc's scheme table (`use.c`): the scheme class — which carries the
    row's alias and guard permissions — the scheme's table name, and the
    locator.
    """
    let colon =
      try
        written.find(":")?
      else
        return (UsePackage, "package:", written)
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
