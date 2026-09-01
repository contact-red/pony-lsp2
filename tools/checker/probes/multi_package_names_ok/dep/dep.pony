trait Greeter
  fun greeting(): String => "hi"

class Shared is Greeter
  new create() => None
