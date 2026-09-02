class K
actor Main
  new create(env: Env) =>
    let o = object is K end
    let g = {(): U32 => let apply = U32(1); apply }
    None
