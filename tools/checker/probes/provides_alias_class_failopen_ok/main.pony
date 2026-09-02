actor Main
  new create(env: Env) => None

class Helper3
  new create() => None
type CA is Helper3

class User is CA
