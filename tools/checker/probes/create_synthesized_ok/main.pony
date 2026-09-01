class Counter
  fun fresh(): Counter => create()
  fun again(): Counter => this.create()

primitive Flag
  fun same(other: Flag): Bool => eq(other)

actor Main
  new create(env: Env) =>
    let c = Counter.fresh()
    None
