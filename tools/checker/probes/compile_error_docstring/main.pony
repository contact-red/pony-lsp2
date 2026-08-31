actor Main
  new create(env: Env) =>
    ifdef "foo" then
      "doc"
      compile_error "nope"
    end
