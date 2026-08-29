primitive _SourceInput
primitive _FilesInput
primitive _FactsQuery
primitive _DeclarationsQuery
primitive _ImportsQuery
primitive _IndexQuery

type _QueryKind is
  ( _SourceInput
  | _FilesInput
  | _FactsQuery
  | _DeclarationsQuery
  | _ImportsQuery
  | _IndexQuery
  )
  """
  What kind of question one query id names.

  A union rather than a trait, so that `Binder.run` can match exhaustively
  and a new kind is a compile error until it is handled.
  """

class val _Job
  """
  What one query id stands for: a kind of question and what it is about.

  The engine knows a query only by its id, so this is how a recomputation
  finds its way back to the file or package it concerns.
  """
  let kind: _QueryKind
  let key: String val

  new val create(kind': _QueryKind, key': String val) =>
    kind = kind'
    key = key'
