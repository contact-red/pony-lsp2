class val UseDecl
  """
  A `use` in a document: the package it names, the name it binds it to, and
  where it is written.

  `alias` is empty for an unaliased `use`, which puts the package's types
  into scope under their own names rather than behind a qualifier. An FFI
  declaration is not one of these: it names a C function rather than a
  package, and nothing resolves a Pony name through it.
  """
  let package: String val
  let alias: String val
  let span: Span

  new val create(package': String val, alias': String val, span': Span) =>
    package = package'
    alias = alias'
    span = span'
