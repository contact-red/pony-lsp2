type QueryId is USize
  """
  Names one query: one question at one set of arguments.

  Only `Engine.add` produces one, so every `QueryId` in circulation names a
  query the engine knows about. It is a bare `USize` and not a wrapper
  because there is one per memo entry -- tens of thousands of them -- and a
  wrapper would be a heap allocation each.
  """

type Revision is U64
  """
  A version of the whole input state. Every change to an input produces a new
  one, and nothing else does.
  """
