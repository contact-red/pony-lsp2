use @fwrite[USize](
  ptr: Pointer[U8] tag, size: USize, count: USize, stream: Pointer[U8] tag)

primitive _Stderr
  """
  A synchronous write to stderr, used instead of `env.err` so a run
  with many diagnostics streams its output the way ponyc does, rather
  than queueing every rendered string in an actor mailbox.
  """
  fun print(text: String box) =>
    @fwrite(text.cpointer(), 1, text.size(), @pony_os_stderr())
    @fwrite("\n".cpointer(), 1, 1, @pony_os_stderr())
