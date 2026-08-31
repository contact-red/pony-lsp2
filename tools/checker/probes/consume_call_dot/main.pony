class C
  fun boxit(): C => this
  fun f(): C =>
    consume boxit().boxit
