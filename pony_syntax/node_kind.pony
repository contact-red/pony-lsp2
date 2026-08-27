// Node kinds: the interior elements of a syntax tree.
//
// Deliberately not generated from ponyc's `abstract` table. ponyc reuses one
// id for both the `class` keyword and the class definition node; this tree
// keeps them apart, so that an element's kind says on its own whether it is a
// leaf. The set is therefore a property of the grammar written here and grows
// as rules are ported, rather than being taken wholesale from elsewhere.

primitive NdError
  """
  Input that no rule could interpret. Its children are the tokens that were
  skipped to reach a point where parsing could continue, so an error costs
  the text it covers and nothing else.
  """
  fun name(): String val => "NdError"

primitive NdModule
  """
  A whole source file.
  """
  fun name(): String val => "NdModule"

primitive NdUse
  """
  A `use` command.
  """
  fun name(): String val => "NdUse"

primitive NdUseName
  """
  The `name =` that may precede a `use` specifier.
  """
  fun name(): String val => "NdUseName"

primitive NdItem
  """
  A top-level declaration, not yet broken down.

  A placeholder for the entity rules: it spans from an entity keyword to the
  start of the next top-level item. Folding and outline need the extent
  before they need the detail, and the entity rules replace this without
  disturbing anything above it.
  """
  fun name(): String val => "NdItem"

type NodeKind is
  ( NdError
  | NdModule
  | NdUse
  | NdUseName
  | NdItem
  )
  """
  Every kind of interior node. Grows as grammar rules are ported.
  """

type SyntaxKind is (TokenKind | NodeKind)
  """
  What an element of the tree is. A leaf carries a `TokenKind` and an
  interior element a `NodeKind`, so the two never need telling apart by
  anything but the kind itself.
  """
