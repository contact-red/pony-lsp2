use "collections"
use per = "collections/persistent"
use "pony_bench"

actor \nodoc\ Main is BenchmarkList
  """
  What content-addressed type identity costs.

  `DESIGN.md` question 2 lists four candidates for how the memo store is held
  and four measurements to take before choosing. It took the first two and
  chose a persistent map published from one actor. The fourth was never
  taken, and it is the one that decides how a *type* is identified rather
  than how a memo is stored:

    D. a type's id is a strong structural hash rather than a counter, so two
       workers derive the same id for the same type without communicating

  ponyq gets identity from a central mutable table: intern a type, get a
  counter. `FINDINGS.md` prices that at a shard lock per read and names it as
  the whole of its 6-7x parallel ceiling. D removes the table from the
  identity question entirely, which leaves one cost to price -- hashing every
  type as it is built -- and one risk to bound, which is collision.

  `DESIGN.md` claims the hash is "bottom-up, cacheable in the value, so O(1)
  amortised". That claim is what this measures.
  """
  new create(env: Env) =>
    PonyBench(env, this)

  fun tag benchmarks(bench: PonyBench) =>
    bench(_Harness)
    bench(_HashCached)
    bench(_HashFullWalk)
    bench(_InternLookup)
    bench(_EqHash)
    bench(_EqStructural)

primitive \nodoc\ _Shape
  """
  The corpus the benchmarks build over.

  Depth 4 and up to 3 type arguments is the shape ponyc's standard library
  actually reaches: `Array[Map[String, Array[U8] val] ref] iso` is depth 4,
  and `FINDINGS.md` reports 77 instantiations for `builtin` of which 41 are
  open, reached inside a generic's own signature.
  """
  fun leaves(): USize => 64
  fun corpus(): USize => 10000

  fun stride(): USize => 7919

class \nodoc\ val _Ty
  """
  A type, in the shape `hir.rs` gives one: a definition, a capability and
  type arguments, with unions, intersections and tuples as the same thing
  under a different kind.

  `digest` is the 128-bit structural hash, folded from the children's when
  the type is built. Two structurally equal types have the same digest
  wherever they were built, which is the property candidate D rests on.
  """
  let kind: U8
  let def: U32
  let cap: U8
  let args: Array[_Ty] val
  let digest_a: U64
  let digest_b: U64

  new val create(
    kind': U8,
    def': U32,
    cap': U8,
    args': Array[_Ty] val)
  =>
    kind = kind'
    def = def'
    cap = cap'
    args = args'
    (digest_a, digest_b) = _Digest.fold(kind', def', cap', args')

  fun structurally_eq(that: _Ty): Bool =>
    """
    Equality by walking both types, which is what identity costs without a
    digest to compare instead.
    """
    if (kind != that.kind) or (def != that.def) or (cap != that.cap) then
      return false
    end
    if args.size() != that.args.size() then
      return false
    end
    var i: USize = 0
    while i < args.size() do
      try
        if not args(i)?.structurally_eq(that.args(i)?) then
          return false
        end
      else
        return false
      end
      i = i + 1
    end
    true

primitive \nodoc\ _Digest
  """
  FNV-1a over the pieces of a type, in two lanes with different seeds, which
  is 128 bits of hash without a 128-bit multiply.

  `fold` reads each child's cached digest rather than walking into it, which
  is the amortisation the claim rests on. `walk` recomputes from the whole
  subtree and exists only to price what the cache buys.
  """
  fun seed_a(): U64 => 14695981039346656037
  fun seed_b(): U64 => 1099511628211

  fun mix(h: U64, v: U64): U64 =>
    var out = h
    var rest = v
    var i: USize = 0
    while i < 8 do
      out = (out xor (rest and 0xff)) * 1099511628211
      rest = rest >> 8
      i = i + 1
    end
    out

  fun fold(
    kind: U8,
    def: U32,
    cap: U8,
    args: Array[_Ty] val)
    : (U64, U64)
  =>
    var a = mix(mix(mix(seed_a(), kind.u64()), def.u64()), cap.u64())
    var b = mix(mix(mix(seed_b(), cap.u64()), def.u64()), kind.u64())
    for arg in args.values() do
      a = mix(a, arg.digest_a)
      b = mix(b, arg.digest_b)
    end
    (a, b)

  fun walk(t: _Ty): (U64, U64) =>
    var a = mix(mix(mix(seed_a(), t.kind.u64()), t.def.u64()), t.cap.u64())
    var b = mix(mix(mix(seed_b(), t.cap.u64()), t.def.u64()), t.kind.u64())
    for arg in t.args.values() do
      (let ca, let cb) = walk(arg)
      a = mix(a, ca)
      b = mix(b, cb)
    end
    (a, b)

primitive \nodoc\ _Corpus
  """
  A set of types four deep, built once so the benchmarks measure what they
  name rather than the construction of their inputs.
  """
  fun apply(): Array[_Ty] val =>
    recover val
      let leaves = Array[_Ty](_Shape.leaves())
      var i: USize = 0
      while i < _Shape.leaves() do
        leaves.push(_Ty(0, i.u32(), (i % 6).u8(), recover val Array[_Ty] end))
        i = i + 1
      end

      let built = Array[_Ty](_Shape.corpus())
      var n: USize = 0
      while n < _Shape.corpus() do
        // The modulus keeps both indices in range, so the else is dead.
        let spare = _Ty(0, 0, 0, recover val Array[_Ty] end)
        let a = try leaves(n % _Shape.leaves())? else spare end
        let b = try leaves((n * 7) % _Shape.leaves())? else spare end
        let inner =
          _Ty(1, (n % 32).u32(), (n % 6).u8(),
            recover val [as _Ty: a; b] end)
        let mid =
          _Ty(1, ((n / 32) % 32).u32(), ((n / 6) % 6).u8(),
            recover val [as _Ty: inner; a] end)
        built.push(
          _Ty(1, ((n / 64) % 32).u32(), ((n / 3) % 6).u8(),
            recover val [as _Ty: mid; b; inner] end))
        n = n + 1
      end
      built
    end

class \nodoc\ iso _Harness is MicroBenchmark
  """
  What every benchmark below pays before it does its own work: the stride and
  the two array reads. Subtract this to read the others.
  """
  var _corpus: Array[_Ty] val
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "harness/two reads"

  fun ref before() =>
    _corpus = _Corpus()

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    DoNotOptimise[_Ty](_corpus(_i)?)
    DoNotOptimise[_Ty](_corpus((_i + 1) % _corpus.size())?)
    DoNotOptimise.observe()

class \nodoc\ iso _HashCached is MicroBenchmark
  """
  Building one type over children that already carry their digests, which is
  every construction after the leaves. This is what candidate D costs per
  type.
  """
  var _corpus: Array[_Ty] val
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "hash/cached fold"

  fun ref before() =>
    _corpus = _Corpus()

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    let child = _corpus(_i)?
    let other = _corpus((_i + 1) % _corpus.size())?
    DoNotOptimise[_Ty](
      _Ty(1, 7, 3, recover val [as _Ty: child; other] end))
    DoNotOptimise.observe()

class \nodoc\ iso _HashFullWalk is MicroBenchmark
  """
  The same digest computed from the whole subtree instead of from the
  children's cached ones. The gap between this and the fold is what caching
  the hash in the value buys.
  """
  var _corpus: Array[_Ty] val
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "hash/full walk"

  fun ref before() =>
    _corpus = _Corpus()

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    // Observed a lane at a time: `DoNotOptimise` with a tuple type argument
    // segfaults ponyc 0.69.1 in LLVM's X86 instruction selection.
    (let a, let b) = _Digest.walk(_corpus(_i)?)
    DoNotOptimise[U64](a)
    DoNotOptimise[U64](b)
    DoNotOptimise.observe()

class \nodoc\ iso _InternLookup is MicroBenchmark
  """
  What a central table adds on top of the hash: look the digest up, and take
  the counter it holds.

  This is the cost candidate D removes, not the cost it pays. ponyq pays a
  shard lock here as well, which Pony's `val` snapshot does not -- so this
  measures the table lookup alone and still understates what D avoids.
  """
  var _corpus: Array[_Ty] val
  var _table: per.Map[U64, USize] = per.Map[U64, USize]
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "intern/table lookup"

  fun ref before() =>
    _corpus = _Corpus()
    var m = per.Map[U64, USize]
    var n: USize = 0
    while n < _corpus.size() do
      try
        m = m.update(_corpus(n)?.digest_a, n)
      end
      n = n + 1
    end
    _table = m

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    let t = _corpus(_i)?
    DoNotOptimise[USize](_table(t.digest_a)?)
    DoNotOptimise.observe()

class \nodoc\ iso _EqHash is MicroBenchmark
  """
  Deciding two types are the same by comparing 128 bits.
  """
  var _corpus: Array[_Ty] val
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "eq/digest"

  fun ref before() =>
    _corpus = _Corpus()

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    let a = _corpus(_i)?
    let b = _corpus((_i + 1) % _corpus.size())?
    DoNotOptimise[Bool](
      (a.digest_a == b.digest_a) and (a.digest_b == b.digest_b))
    DoNotOptimise.observe()

class \nodoc\ iso _EqStructural is MicroBenchmark
  """
  The same decision by walking both types, which is what it costs with no
  digest and no interning at all.
  """
  var _corpus: Array[_Ty] val
  var _i: USize = 0

  new iso create() =>
    _corpus = recover val Array[_Ty] end

  fun name(): String => "eq/structural walk"

  fun ref before() =>
    _corpus = _Corpus()

  fun ref apply() ? =>
    _i = (_i + _Shape.stride()) % _corpus.size()
    let a = _corpus(_i)?
    let b = _corpus((_i + 1) % _corpus.size())?
    DoNotOptimise[Bool](a.structurally_eq(b))
    DoNotOptimise.observe()
