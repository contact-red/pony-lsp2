use "./dep1"
use "./dep2"

actor Main
  new create(env: Env) =>
    let g = {()(apply = env): U32 => 1 }
    None
