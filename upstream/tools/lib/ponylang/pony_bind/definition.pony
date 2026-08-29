use "../pony_analysis"

type Definition is (BoundItem | Binding)
  """
  What a name at a position turns out to refer to.

  A `Binding` is bound inside the document the question was asked about --
  a local, a parameter, a field, a type parameter -- and carries its own
  span, because the document that has it also has where it is.

  A `BoundItem` is declared somewhere else and carries no span, for the
  reason the package docstring gives. Turning one into a position means
  asking its own file, which `Binder.declared_at` does.
  """
