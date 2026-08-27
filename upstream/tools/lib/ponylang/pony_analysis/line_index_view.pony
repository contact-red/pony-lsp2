interface val LineIndexView
  """
  What a `Span` needs from a line index. Structural, so that this package
  does not depend on the one that provides it.
  """
  fun position(byte: USize): (USize, USize)
    """
    The zero-based line and character at a byte offset.
    """
