actor Main
  new create(env: Env) =>
    let o =
      object
        fun first(): U8 => 1
        fun second(): U8 => this.first() + firstish()
        fun firstish(): U8 => first()
      end
    env.out.print(o.second().string())
