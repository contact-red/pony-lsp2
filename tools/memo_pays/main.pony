use "collections"
use per = "collections/persistent"
use "pony_bench"

actor \nodoc\ Main is BenchmarkList
  """
  Whether memoizing a subtype decision pays, for a batch checker.

  `FINDINGS.md`'s "The fork" says it does not: "For a batch compiler the
  memoization is a cost with no return: at least 17% of the check phase goes
  to lookups, and it does not improve parallelism. A parallel pass pipeline
  over the same immutable AST, memoizing nothing, would plausibly be faster
  than this -- untested, and cheap to test." `CHECKER_BRIEF.md` moved this
  project onto that side of the fork.

  The claim reduces to arithmetic. A query asked `R` times per distinct key
  costs `R*L + C` memoized and `R*C` not, where `L` is a lookup and `C` a
  recompute. Memoizing pays exactly when

      L < C * (R - 1) / R

  so for a high hit ratio, when a lookup is cheaper than the work it saves.
  `FINDINGS.md` measures `R` at 24 for `is_subtype` (281,352 calls, 11,552
  runs) and at 1 for `lower_type` (22,154 on 22,154), where no memo can ever
  pay.

  What is unmeasured is `L` and `C` in Pony, so that is what this measures,
  and the answer is a crossover rather than a verdict: the recompute cost
  above which a memo starts paying.

  ponyq's numbers do not settle it, because `FINDINGS.md` attributes its 17%
  to positional node identity -- `ast_of` at 1,082,246 calls and 243,357
  interned `NodeRef`s -- and says an item tree addressed by name "removes all
  three costs at once". `pony_bind` already addresses declarations by name
  path and `SEMANTIC_DESIGN.md` proposes content-addressed types, so neither
  interning cost is present here.
  """
  new create(env: Env) =>
    PonyBench(env, this)

  fun tag benchmarks(bench: PonyBench) =>
    bench(_Harness)

    // C: what one decision costs, by how much of the type it walks.
    bench(_Decide(2, true))
    bench(_Decide(4, true))
    bench(_Decide(8, true))
    bench(_Decide(4, false))

    // The shortcut that answers without deciding or looking up.
    bench(_DigestEqual)

    // L: what consulting a memo costs, keyed on a digest pair.
    bench(_LookupFlat)
    bench(_LookupPersistent)

primitive \nodoc\ _Shape
  fun corpus(): USize => 4096
  fun stride(): USize => 1021

class \nodoc\ val _Ty
  """
  A type in the shape `hir.rs` gives one, carrying `eph` -- which
  `tools/type_hash`'s benchmark shape omits, so that `String iso` and
  `String iso^` would fold to one digest.
  """
  let kind: U8
  let def: U32
  let cap: U8
  let eph: U8
  let args: Array[_Ty] val
  let digest_a: U64
  let digest_b: U64

  new val create(
    kind': U8,
    def': U32,
    cap': U8,
    eph': U8,
    args': Array[_Ty] val)
  =>
    kind = kind'
    def = def'
    cap = cap'
    eph = eph'
    args = args'
    var a = _Mix(_Mix(_Mix(_Mix(14695981039346656037, kind'.u64()),
      def'.u64()), cap'.u64()), eph'.u64())
    var b = _Mix(_Mix(_Mix(_Mix(1099511628211, eph'.u64()), cap'.u64()),
      def'.u64()), kind'.u64())
    for arg in args'.values() do
      a = _Mix(a, arg.digest_a)
      b = _Mix(b, arg.digest_b)
    end
    digest_a = a
    digest_b = b

primitive \nodoc\ _Mix
  fun apply(h: U64, v: U64): U64 =>
    var out = h
    var rest = v
    var i: USize = 0
    while i < 8 do
      out = (out xor (rest and 0xff)) * 1099511628211
      rest = rest >> 8
      i = i + 1
    end
    out

primitive \nodoc\ _Subtype
  """
  A structural decision of the shape `is_subtype` has: compare the heads,
  check the capability, and recurse on the arguments.

  Not Pony's subtype relation -- it is the walk that matters here, and its
  cost is what `C` is. `subtype.rs` is 1,950 lines and does more per node
  than this, so this is a floor on `C` rather than an estimate of it.
  """
  fun apply(a: _Ty, b: _Ty): Bool =>
    if a.kind != b.kind then
      return false
    end
    if a.def != b.def then
      return false
    end
    if (a.cap != b.cap) and (a.cap != 5) and (b.cap != 5) then
      return false
    end
    if a.eph != b.eph then
      return false
    end
    if a.args.size() != b.args.size() then
      return false
    end
    var i: USize = 0
    while i < a.args.size() do
      try
        if not apply(a.args(i)?, b.args(i)?) then
          return false
        end
      else
        return false
      end
      i = i + 1
    end
    true

primitive \nodoc\ _Corpus
  """
  Pairs to decide, built to a given depth.

  When `equal` the two sides are structurally equal, so the walk runs to the
  leaves -- the expensive case, and the one that actually reaches a
  conclusion. When not, they differ in a leaf capability, so the walk still
  descends the whole way and fails at the bottom rather than exiting at the
  first node. `tools/type_hash`'s `_EqStructural` measured the early exit and
  the review caught it; this measures both ends deliberately.
  """
  fun apply(depth: USize, equal: Bool): Array[(_Ty, _Ty)] val =>
    recover val
      let out = Array[(_Ty, _Ty)](_Shape.corpus())
      var n: USize = 0
      while n < _Shape.corpus() do
        out.push((_build(depth, n, false), _build(depth, n, not equal)))
        n = n + 1
      end
      out
    end

  fun _build(depth: USize, seed: USize, perturb: Bool): _Ty =>
    if depth == 0 then
      let cap = if perturb then U8(3) else U8(2) end
      _Ty(0, (seed % 64).u32(), cap, (seed % 2).u8(),
        recover val Array[_Ty] end)
    else
      _Ty(1, (seed % 32).u32(), 2, 0,
        recover val
          [as _Ty: _build(depth - 1, seed, perturb)
                   _build(depth - 1, seed + 1, perturb) ]
        end)
    end

class \nodoc\ iso _Harness is MicroBenchmark
  """
  The stride and the two reads every row below pays. Subtract it.
  """
  var _pairs: Array[(_Ty, _Ty)] val
  var _i: USize = 0

  new iso create() =>
    _pairs = recover val Array[(_Ty, _Ty)] end

  fun name(): String => "harness/one read"

  fun ref before() =>
    _pairs = _Corpus(4, true)

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _pairs.size()
    (let a, let b) = _pairs(_i)?
    DoNotOptimise[_Ty](a)
    DoNotOptimise[_Ty](b)
    DoNotOptimise.observe()

class \nodoc\ iso _Decide is MicroBenchmark
  """
  `C`: one decision, recomputed.
  """
  let _depth: USize
  let _equal: Bool
  var _pairs: Array[(_Ty, _Ty)] val
  var _i: USize = 0

  new iso create(depth: USize, equal: Bool) =>
    _depth = depth
    _equal = equal
    _pairs = recover val Array[(_Ty, _Ty)] end

  fun name(): String =>
    "recompute/depth " + _depth.string() +
      (if _equal then " equal" else " differing" end)

  fun ref before() =>
    _pairs = _Corpus(_depth, _equal)

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _pairs.size()
    (let a, let b) = _pairs(_i)?
    DoNotOptimise[Bool](_Subtype(a, b))
    DoNotOptimise.observe()

class \nodoc\ iso _DigestEqual is MicroBenchmark
  """
  Answering without deciding and without looking up: two types with the same
  digest are the same type. `FINDINGS.md` reports the equivalent shortcut in
  ponyq removing 39,580 calls and 0.06s.
  """
  var _pairs: Array[(_Ty, _Ty)] val
  var _i: USize = 0

  new iso create() =>
    _pairs = recover val Array[(_Ty, _Ty)] end

  fun name(): String => "shortcut/digest equal"

  fun ref before() =>
    _pairs = _Corpus(4, true)

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _pairs.size()
    (let a, let b) = _pairs(_i)?
    DoNotOptimise[Bool](
      (a.digest_a == b.digest_a) and (a.digest_b == b.digest_b))
    DoNotOptimise.observe()

class \nodoc\ iso _LookupFlat is MicroBenchmark
  """
  `L`: a hit in a flat `val` map keyed on the pair's digests.
  """
  var _pairs: Array[(_Ty, _Ty)] val
  var _memo: Map[U64, Bool] val
  var _i: USize = 0

  new iso create() =>
    _pairs = recover val Array[(_Ty, _Ty)] end
    _memo = recover val Map[U64, Bool] end

  fun name(): String => "lookup/flat map"

  fun ref before() =>
    _pairs = _Corpus(4, true)
    let pairs = _pairs
    _memo =
      recover val
        let m = Map[U64, Bool](pairs.size())
        for (a, b) in pairs.values() do
          m(a.digest_a xor (b.digest_b * 31)) = true
        end
        m
      end

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _pairs.size()
    (let a, let b) = _pairs(_i)?
    DoNotOptimise[Bool](_memo(a.digest_a xor (b.digest_b * 31))?)
    DoNotOptimise.observe()

class \nodoc\ iso _LookupPersistent is MicroBenchmark
  """
  The same hit against the persistent map `DESIGN.md` chose, which it chose
  for an incremental publish a batch checker never performs.
  """
  var _pairs: Array[(_Ty, _Ty)] val
  var _memo: per.Map[U64, Bool] = per.Map[U64, Bool]
  var _i: USize = 0

  new iso create() =>
    _pairs = recover val Array[(_Ty, _Ty)] end

  fun name(): String => "lookup/persistent map"

  fun ref before() =>
    _pairs = _Corpus(4, true)
    var m = per.Map[U64, Bool]
    for (a, b) in _pairs.values() do
      m = m.update(a.digest_a xor (b.digest_b * 31), true)
    end
    _memo = m

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _pairs.size()
    (let a, let b) = _pairs(_i)?
    DoNotOptimise[Bool](_memo(a.digest_a xor (b.digest_b * 31))?)
    DoNotOptimise.observe()
