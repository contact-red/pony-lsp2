use "collections"
use "time"

actor \nodoc\ Main
  """
  What candidate A costs: a memo query as a behaviour call on the actor that
  owns the table.

  `pony_bench` cannot measure this. Its async runner calls `pony_triggergc`
  before every iteration, so an async benchmark at this granularity reports
  the cost of a garbage collection rather than of a message.

  Two numbers, because a language server wants both. Round-trip latency is
  what one query costs when the answer is needed before the next question can
  be asked. Pipelined throughput is what a batch costs when it is not.
  """
  new create(env: Env) =>
    _Latency(env, 200_000)

primitive \nodoc\ _Table
  fun size(): USize => 20937

  fun stride(): USize => 7919

  fun build(): Map[USize, USize] iso^ =>
    recover iso
      let m = Map[USize, USize](size())
      for i in Range(0, size()) do
        m(i) = i
      end
      m
    end

actor \nodoc\ _Owner
  """
  Candidate A: one actor owns a `ref` table and answers every query.
  """
  let _table: Map[USize, USize]

  new create(table: Map[USize, USize] iso) =>
    _table = consume table

  be get(key: USize, reply_to: _Latency) =>
    reply_to.answer(try _table(key)? else 0 end)

  be get_pipelined(key: USize, reply_to: _Latency) =>
    reply_to.counted(try _table(key)? else 0 end)

actor \nodoc\ _Latency
  let _env: Env
  let _rounds: USize
  let _owner: _Owner
  var _done: USize = 0
  var _key: USize = 0
  var _sink: USize = 0
  var _start: U64 = 0
  var _warming: Bool = true

  new create(env: Env, rounds: USize) =>
    _env = env
    _rounds = rounds
    _owner = _Owner(_Table.build())
    _start = Time.nanos()
    _step()

  fun ref _step() =>
    _key = (_key + _Table.stride()) % _Table.size()
    _owner.get(_key, this)

  be answer(value: USize) =>
    _sink = _sink + value
    _done = _done + 1
    if _done < _rounds then
      _step()
    elseif _warming then
      // The first pass warms the schedulers and the table's pages; the
      // second is the one reported.
      _warming = false
      _done = 0
      _start = Time.nanos()
      _step()
    else
      let elapsed = Time.nanos() - _start
      _report("round trip", elapsed)
      _done = 0
      _sink = 0
      _start = Time.nanos()
      var i: USize = 0
      while i < _rounds do
        _key = (_key + _Table.stride()) % _Table.size()
        _owner.get_pipelined(_key, this)
        i = i + 1
      end
    end

  be counted(value: USize) =>
    _sink = _sink + value
    _done = _done + 1
    if _done == _rounds then
      _report("pipelined", Time.nanos() - _start)
      _env.out.print("checksum " + _sink.string())
    end

  fun _report(what: String, elapsed: U64) =>
    let each = elapsed.f64() / _rounds.f64()
    _env.out.print(
      what + ": " + _rounds.string() + " queries in " +
      (elapsed / 1_000_000).string() + " ms, " +
      each.string() + " ns each")
