class Engine
  """
  Revisions, dependencies and backdating for one set of queries.

  Mutable and unshared by design. The engine is the working state of whichever
  actor owns it; what gets published to readers is the caller's table of
  results, not this.

  `_entries` holds `changed_at`, `verified_at` and `deps` per query, indexed
  by its id. An array of tuples stores them inline, so the whole graph is one
  allocation rather than one per query. A `verified_at` of 0 means never
  computed, which no real revision can be because the engine starts at 1.
  """
  var _revision: Revision = 1
  embed _entries: Array[(Revision, Revision, Array[QueryId] val)] =
    _entries.create()
  embed _frames: Array[_Frame] = _frames.create()

  fun revision(): Revision =>
    """
    The current version of the input state.
    """
    _revision

  fun size(): USize =>
    """
    How many queries the engine knows about.
    """
    _entries.size()

  fun ref add(): QueryId =>
    """
    Register a query and name it.

    Nothing is computed. The first `demand` for the returned id will run it.
    """
    let query = _entries.size()
    _entries.push((0, 0, recover val Array[QueryId] end))
    query

  fun ref set_input(query: QueryId) =>
    """
    Record that `query` is an input whose value has just changed.

    This is the only thing that advances the revision. An input is never
    recomputed, so a `QueryRunner` is never asked about one.
    """
    _revision = _revision + 1
    _write(query, _revision, _revision, _deps(query))

  fun ref demand(query: QueryId, runner: QueryRunner ref) =>
    """
    Ensure `query`'s result is current, recomputing whatever has to be, and
    record that the query being computed now depends on it.

    Both halves, because they are the same event: asking for a result while
    computing another one *is* the dependency edge. An engine that made the
    caller record it separately would lose edges whenever the caller forgot.

    Call this before reading the result out of your own table.
    """
    _record_read(query)
    _bring_current(query, 0, runner)

  fun ref _bring_current(
    query: QueryId,
    since: Revision,
    runner: QueryRunner ref)
    : Bool
  =>
    """
    Bring `query` up to the current revision, and say whether its result
    changed after `since`.

    This is the whole of incrementality. A query verified at an older
    revision is still good unless something it read has changed since then,
    so the walk descends into dependencies and only recomputes where one
    actually did.

    The descent is recursive, and so is bounded by the stack rather than by
    anything the engine controls. Nothing measured yet says how deep a real
    dependency chain gets.
    """
    if _verified_at(query) == 0 then
      _run(query, runner)
      return _changed_at(query) > since
    end

    if _verified_at(query) == _revision then
      return _changed_at(query) > since
    end

    let verified = _verified_at(query)
    var stale = false
    for dependency in _deps(query).values() do
      if _bring_current(dependency, verified, runner) then
        stale = true
        break
      end
    end

    if stale then
      _run(query, runner)
    else
      // Nothing it read has moved, so the memoized result stands and only
      // the mark saying when that was last checked moves forward.
      _write(query, _changed_at(query), _revision, _deps(query))
    end
    _changed_at(query) > since

  fun ref _run(query: QueryId, runner: QueryRunner ref) =>
    """
    Recompute `query`, recording what it reads while it does.
    """
    _frames.push(_Frame)
    let changed = runner.run(query)
    let frame =
      try
        _frames.pop()?
      else
        _Unreachable()
        _Frame
      end
    let deps: Array[QueryId] val = frame.reads = recover iso Array[QueryId] end

    // Backdating: the query ran, but if it produced what it produced before
    // then nothing that depends on it needs to.
    let changed_at = if changed then _revision else _changed_at(query) end
    _write(query, changed_at, _revision, deps)

  fun ref _record_read(query: QueryId) =>
    if _frames.size() > 0 then
      try
        _frames(_frames.size() - 1)?.reads.push(query)
      else
        _Unreachable()
      end
    end
    // Outside any computation there is nothing to record: this is the
    // language server asking a question rather than a query reading one.

  fun _changed_at(query: QueryId): Revision =>
    try _entries(query)?._1 else _Unreachable(); 0 end

  fun _verified_at(query: QueryId): Revision =>
    try _entries(query)?._2 else _Unreachable(); 0 end

  fun _deps(query: QueryId): Array[QueryId] val =>
    try
      _entries(query)?._3
    else
      _Unreachable()
      recover val Array[QueryId] end
    end

  fun ref _write(
    query: QueryId,
    changed_at: Revision,
    verified_at: Revision,
    deps: Array[QueryId] val)
  =>
    try
      _entries(query)? = (changed_at, verified_at, deps)
    else
      _Unreachable()
    end

class _Frame
  """
  A query being computed, and what it has read so far.
  """
  var reads: Array[QueryId] iso = recover iso Array[QueryId] end
