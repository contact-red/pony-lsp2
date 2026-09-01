actor Main
  new create(env: Env) =>
    let f = {(n: U8): U8 => if n == 0 then 0 else this.apply(n - 1) end}
    let y = U8(2)
    let g = {()(y): U8 => this.y}
    env.out.print((f(3) + g()).string())
