primitive _Normalise
  """
  A path with its `.` and `..` segments applied.

  `use ".."` names the package one directory up, and the index is keyed by
  directory, so the two have to be brought into the same form before they
  can be compared.
  """
  fun apply(path: String val): String val =>
    let parts = Array[String val]
    let absolute = path.compare_sub("/", 1) is Equal

    for segment in path.split("/").values() do
      if (segment == "") or (segment == ".") then
        continue
      elseif segment == ".." then
        try parts.pop()? end
      else
        parts.push(consume segment)
      end
    end

    var out = recover iso String end
    for part in parts.values() do
      if absolute or (out.size() > 0) then
        out.push('/')
      end
      out.append(part)
    end
    consume out
