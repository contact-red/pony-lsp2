trait T
  fun m(): U8 => 1
actor Main
  new create(env: Env) =>
    let o: T box = object box is T
      fun p(): U8 => this.m()
    end
    env.out.print(o.m().string())
