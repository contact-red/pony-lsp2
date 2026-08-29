use "collections"
use "pony_test"
use "../upstream/tools/lib/ponylang/pony_query"

primitive \nodoc\ _QueryTests is TestList
  fun tag tests(test: PonyTest) =>
    test(_TestFirstDemandRuns)
    test(_TestNoEditNoRuns)
    test(_TestOnlyTheAffectedPathRuns)
    test(_TestBackdatingStopsPropagation)
    test(_TestUnreadDependenciesAreDropped)
    test(_TestAnInputIsNeverRun)

class \nodoc\ _Sheet is QueryRunner
  """
  A small query graph to exercise the engine.

  Input cells hold a number. A `sum` cell adds the cells it names. A `choose`
  cell reads a condition and then reads one of two branches, which is how the
  test gets a query whose dependencies differ between runs.

  Every recomputation appends to `log`, so a test asserts on what ran rather
  than on what the engine says about itself.
  """
  embed _engine: Engine = _engine.create()
  embed _log: Array[QueryId] = _log.create()
  embed _input: Map[QueryId, I64] = _input.create()
  embed _sum: Map[QueryId, Array[QueryId] val] = _sum.create()
  embed _choose: Map[QueryId, Array[QueryId] val] = _choose.create()
  embed _value: Map[QueryId, I64] = _value.create()

  fun revision(): Revision =>
    _engine.revision()

  fun ref forget() =>
    """
    Start counting runs again from here.
    """
    _log.clear()

  fun logged(): USize =>
    _log.size()

  fun ran(query: QueryId): USize =>
    """
    How many times `query` has been recomputed since the last `forget`.
    """
    var n: USize = 0
    for logged' in _log.values() do
      if logged' == query then n = n + 1 end
    end
    n

  fun ref input(initial: I64): QueryId =>
    let query = _engine.add()
    _input(query) = initial
    _engine.set_input(query)
    query

  fun ref set(query: QueryId, updated: I64) =>
    _input(query) = updated
    _engine.set_input(query)

  fun ref sum(operands: Array[QueryId] val): QueryId =>
    let query = _engine.add()
    _sum(query) = operands
    query

  fun ref choose(condition: QueryId, when_set: QueryId, otherwise: QueryId)
    : QueryId
  =>
    let query = _engine.add()
    _choose(query) = [condition; when_set; otherwise]
    query

  fun ref get(query: QueryId): I64 =>
    _engine.demand(query, this)
    try
      _input(query)?
    else
      try _value(query)? else 0 end
    end

  fun ref run(query: QueryId): Bool =>
    _log.push(query)
    let computed =
      try
        var total: I64 = 0
        for operand in _sum(query)?.values() do
          total = total + get(operand)
        end
        total
      else
        try
          let operands = _choose(query)?
          if get(operands(0)?) != 0 then
            get(operands(1)?)
          else
            get(operands(2)?)
          end
        else
          // An input, which the engine must never ask to be recomputed.
          return false
        end
      end
    let previously = try _value(query)? else None end
    _value(query) = computed
    match previously
    | let was: I64 => computed != was
    else
      true
    end

class \nodoc\ iso _TestFirstDemandRuns is UnitTest
  fun name(): String => "query/a first demand runs the query"

  fun apply(h: TestHelper) =>
    let sheet = _Sheet
    let a = sheet.input(1)
    let b = sheet.input(2)
    let left = sheet.sum([a])
    let right = sheet.sum([b])
    let total = sheet.sum([left; right])

    h.assert_eq[I64](3, sheet.get(total))
    h.assert_eq[USize](1, sheet.ran(left))
    h.assert_eq[USize](1, sheet.ran(right))
    h.assert_eq[USize](1, sheet.ran(total))

class \nodoc\ iso _TestNoEditNoRuns is UnitTest
  fun name(): String => "query/no edit costs no runs"

  fun apply(h: TestHelper) =>
    """
    `FINDINGS.md` measures this as 0 queries out of 20937. It is the property
    the whole engine exists for, so it is the first one to break if the
    verified-at bookkeeping is wrong.
    """
    let sheet = _Sheet
    let a = sheet.input(1)
    let total = sheet.sum([sheet.sum([a])])
    sheet.get(total)

    sheet.forget()
    h.assert_eq[I64](1, sheet.get(total))
    h.assert_eq[USize](0, sheet.logged(), "something re-ran")

class \nodoc\ iso _TestOnlyTheAffectedPathRuns is UnitTest
  fun name(): String => "query/an edit runs only what depends on it"

  fun apply(h: TestHelper) =>
    let sheet = _Sheet
    let a = sheet.input(1)
    let b = sheet.input(2)
    let left = sheet.sum([a])
    let right = sheet.sum([b])
    let total = sheet.sum([left; right])
    sheet.get(total)

    sheet.forget()
    sheet.set(a, 10)
    h.assert_eq[I64](12, sheet.get(total))
    h.assert_eq[USize](1, sheet.ran(left))
    h.assert_eq[USize](1, sheet.ran(total))
    h.assert_eq[USize](
      0,
      sheet.ran(right),
      "a query that reads nothing affected re-ran")

class \nodoc\ iso _TestBackdatingStopsPropagation is UnitTest
  fun name(): String => "query/backdating stops propagation"

  fun apply(h: TestHelper) =>
    """
    Two edits that cancel. The sum re-runs, because an input it reads did
    change; what it produces is what it produced before, so nothing that
    reads the sum re-runs.

    This is the cheapest large win in `FINDINGS.md` and it is invisible in
    the result -- the only evidence it happened is what did not run.
    """
    let sheet = _Sheet
    let a = sheet.input(1)
    let b = sheet.input(2)
    let inner = sheet.sum([a; b])
    let outer = sheet.sum([inner])
    h.assert_eq[I64](3, sheet.get(outer))

    sheet.forget()
    sheet.set(a, 5)
    sheet.set(b, -2)
    h.assert_eq[I64](3, sheet.get(outer))
    h.assert_eq[USize](1, sheet.ran(inner), "the sum should have re-run")
    h.assert_eq[USize](
      0,
      sheet.ran(outer),
      "an unchanged result propagated anyway")

class \nodoc\ iso _TestUnreadDependenciesAreDropped is UnitTest
  fun name(): String => "query/an unread dependency is dropped"

  fun apply(h: TestHelper) =>
    """
    Dependencies are what a query read on its last run, not what it might
    read. A branch that was not taken is not a dependency, so editing it
    must not re-run anything.
    """
    let sheet = _Sheet
    let condition = sheet.input(1)
    let taken = sheet.input(10)
    let untaken = sheet.input(20)
    let picked = sheet.choose(condition, taken, untaken)
    h.assert_eq[I64](10, sheet.get(picked))

    sheet.forget()
    sheet.set(untaken, 99)
    h.assert_eq[I64](10, sheet.get(picked))
    h.assert_eq[USize](
      0,
      sheet.ran(picked),
      "a branch that was not read was treated as a dependency")

    // And once the condition sends it the other way, the branch it now reads
    // is the one that matters.
    sheet.forget()
    sheet.set(condition, 0)
    h.assert_eq[I64](99, sheet.get(picked))
    h.assert_eq[USize](1, sheet.ran(picked))

    sheet.forget()
    sheet.set(taken, 11)
    h.assert_eq[I64](99, sheet.get(picked))
    h.assert_eq[USize](
      0,
      sheet.ran(picked),
      "the branch it stopped reading is still a dependency")

class \nodoc\ iso _TestAnInputIsNeverRun is UnitTest
  fun name(): String => "query/an input is never recomputed"

  fun apply(h: TestHelper) =>
    let sheet = _Sheet
    let a = sheet.input(1)
    let derived = sheet.sum([a])
    sheet.get(derived)
    sheet.set(a, 2)
    sheet.get(derived)

    h.assert_eq[USize](0, sheet.ran(a), "the engine recomputed an input")
    // Three: the engine starts at 1, giving the input its first value is an
    // edit, and so is changing it. Registering a query is not.
    h.assert_eq[Revision](3, sheet.revision(), "one revision per edit")
