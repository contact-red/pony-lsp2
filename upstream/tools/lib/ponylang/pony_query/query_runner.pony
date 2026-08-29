interface QueryRunner
  """
  How the engine recomputes a query it cannot itself evaluate.

  The engine knows a query only by its `QueryId`; the caller knows what that
  id means. So revalidation calls back here whenever a memoized result has to
  be rebuilt.
  """
  fun ref run(query: QueryId): Bool
    """
    Recompute `query`, store the result wherever the caller keeps results,
    and return whether it *differs* from the result it replaced.

    Returning `false` is backdating, and it is the whole point: the query ran
    again, but everything that depends on it keeps its memo.

    Reads made during this call are recorded as `query`'s dependencies, so a
    result must be reached by asking the engine for what it needs rather than
    by reading a table behind the engine's back.
    """
