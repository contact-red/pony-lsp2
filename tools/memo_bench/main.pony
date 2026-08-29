use "collections"
use per = "collections/persistent"
use "pony_bench"

actor \nodoc\ Main is BenchmarkList
  """
  The measurement question 2 of DESIGN.md says to take before committing to a
  memo store.

  Three candidates, and no Rust number decides between them because
  `FINDINGS.md` priced reads and never priced publish. In Pony publish is what
  decides it: a flat `val` map cannot be extended, so a new version means
  rebuilding it.

    A. one actor owns a `ref` table and every query is a behaviour call
    B. an actor owns the table and publishes flat `val` snapshots
    B'. the same, with a persistent map, which extends with sharing

  Publish is measured per batch rather than per insert, because an engine
  publishes a revision rather than an entry, and the flat map amortises its
  rebuild over whatever the batch holds.

  Candidate A is measured by `tools/actor_latency` and not here. `pony_bench`
  calls `pony_triggergc` before every async iteration, so an async benchmark
  at this granularity reports a garbage collection rather than a message.
  """
  new create(env: Env) =>
    PonyBench(env, this)

  fun tag benchmarks(bench: PonyBench) =>
    bench(_FlatPublish(1))
    bench(_FlatPublish(100))
    bench(_FlatPublish(1000))
    bench(_PersistentPublish(1))
    bench(_PersistentPublish(100))
    bench(_PersistentPublish(1000))
    bench(_FlatRebuild)
    bench(_PersistentBulkUpdate)
    bench(_PersistentConcat(1000))
    bench(_PersistentConcat(_Baseline.size()))
    bench(_FlatHit)
    bench(_PersistentHit)

primitive \nodoc\ _Baseline
  """
  The size the decision is about.

  20937 is `FINDINGS.md`'s memo entry count for a cold `collections` check.
  Keys and values are both `USize`, so what is measured is the map and not
  the payload: a real memo value is a pointer either way.
  """
  fun size(): USize => 20937

  fun stride(): USize =>
    """
    A prime step, so a read benchmark walks the table rather than sitting on
    one cache line.
    """
    7919

  fun flat(): Map[USize, USize] val =>
    recover val
      let m = Map[USize, USize](size())
      for i in Range(0, size()) do
        m(i) = i
      end
      m
    end

  fun persistent(): per.Map[USize, USize] =>
    var m = per.Map[USize, USize]
    for i in Range(0, size()) do
      m = m.update(i, i)
    end
    m

class \nodoc\ iso _FlatPublish is MicroBenchmark
  """
  Publishing a new version of a flat `val` map: clone the whole thing, add
  the batch, and let the result recover to `val`.
  """
  let _batch: USize
  var _base: Map[USize, USize] val

  new iso create(batch: USize) =>
    _batch = batch
    _base = recover val Map[USize, USize] end

  fun name(): String => "flat/publish " + _batch.string()

  fun ref before() =>
    _base = _Baseline.flat()

  fun ref apply() =>
    let base = _base
    let batch = _batch
    let n = _Baseline.size()
    let next: Map[USize, USize] val =
      recover val
        let m = base.clone()
        for i in Range(n, n + batch) do
          m(i) = i
        end
        m
      end
    DoNotOptimise[Map[USize, USize] val](next)
    DoNotOptimise.observe()

class \nodoc\ iso _PersistentPublish is MicroBenchmark
  """
  The same publish against a persistent map, which shares the parts of the
  tree the batch did not touch.
  """
  let _batch: USize
  var _base: per.Map[USize, USize]

  new iso create(batch: USize) =>
    _batch = batch
    _base = per.Map[USize, USize]

  fun name(): String => "persistent/publish " + _batch.string()

  fun ref before() =>
    _base = _Baseline.persistent()

  fun ref apply() =>
    var m = _base
    let n = _Baseline.size()
    for i in Range(n, n + _batch) do
      m = m.update(i, i)
    end
    DoNotOptimise[per.Map[USize, USize]](m)
    DoNotOptimise.observe()

class \nodoc\ iso _FlatRebuild is MicroBenchmark
  """
  Building a whole table from nothing, which is what a cold check publishes.
  The incremental numbers above say nothing about this case.
  """
  fun name(): String => "flat/rebuild all"

  fun ref apply() =>
    DoNotOptimise[Map[USize, USize] val](_Baseline.flat())
    DoNotOptimise.observe()

class \nodoc\ iso _PersistentBulkUpdate is MicroBenchmark
  """
  The same, one `update` at a time -- the shape the incremental publish uses,
  priced at cold-check size.
  """
  fun name(): String => "persistent/rebuild all by update"

  fun ref apply() =>
    DoNotOptimise[per.Map[USize, USize]](_Baseline.persistent())
    DoNotOptimise.observe()

class \nodoc\ iso _PersistentConcat is MicroBenchmark
  """
  Folding a batch in with one `concat` rather than one `update` each. If this
  is close to the flat rebuild, the persistent map serves both the
  incremental publish and the cold one and no second representation is
  needed.
  """
  let _batch: USize
  var _base: per.Map[USize, USize]
  var _entries: Array[(USize, USize)] val

  new iso create(batch: USize) =>
    _batch = batch
    _base = per.Map[USize, USize]
    _entries = recover val Array[(USize, USize)] end

  fun name(): String => "persistent/concat " + _batch.string()

  fun ref before() =>
    _base =
      if _batch == _Baseline.size() then
        per.Map[USize, USize]
      else
        _Baseline.persistent()
      end
    let n = if _batch == _Baseline.size() then 0 else _Baseline.size() end
    _entries =
      recover val
        let a = Array[(USize, USize)](_batch)
        for i in Range(n, n + _batch) do
          a.push((i, i))
        end
        a
      end

  fun ref apply() =>
    DoNotOptimise[per.Map[USize, USize]](_base.concat(_entries.values()))
    DoNotOptimise.observe()

class \nodoc\ iso _FlatHit is MicroBenchmark
  """
  A hit against a flat `val` snapshot: no lock and no store, which is the
  thing `ponyq` could not have.
  """
  var _base: Map[USize, USize] val
  var _key: USize = 0

  new iso create() =>
    _base = recover val Map[USize, USize] end

  fun name(): String => "flat/hit"

  fun ref before() =>
    _base = _Baseline.flat()

  fun ref apply() ? =>
    _key = (_key + _Baseline.stride()) % _Baseline.size()
    DoNotOptimise[USize](_base(_key)?)
    DoNotOptimise.observe()

class \nodoc\ iso _PersistentHit is MicroBenchmark
  """
  The same hit against a persistent map, which costs the pointer depth
  `FINDINGS.md` says survives any language.
  """
  var _base: per.Map[USize, USize]
  var _key: USize = 0

  new iso create() =>
    _base = per.Map[USize, USize]

  fun name(): String => "persistent/hit"

  fun ref before() =>
    _base = _Baseline.persistent()

  fun ref apply() ? =>
    _key = (_key + _Baseline.stride()) % _Baseline.size()
    DoNotOptimise[USize](_base(_key)?)
    DoNotOptimise.observe()
