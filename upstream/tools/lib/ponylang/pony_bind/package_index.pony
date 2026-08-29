use "collections"

class val PackageIndex is Equatable[PackageIndex]
  """
  Everything a package declares, in one comparable value.

  Comparable because the engine backdates on it: two indexes built from the
  same declarations are equal, so an edit that changed only a body does not
  propagate past here.
  """
  let items: Array[BoundItem] val
    """
    Every declaration the package makes, entities and members alike, in file
    order. What a workspace symbol search walks.
    """
  let _entities: Map[String, BoundItem] val

  new val create(items': Array[BoundItem] val) =>
    items = items'
    _entities =
      recover val
        let found = Map[String, BoundItem]
        for item in items'.values() do
          if item.is_entity() then
            // First wins. A package declaring one name twice is a program
            // ponyc rejects, and picking a winner beats having no answer
            // for a workspace the user is still typing into.
            if not found.contains(item.name()) then
              found(item.name()) = item
            end
          end
        end
        found
      end

  fun entity(name: String val): (BoundItem | None) =>
    """
    The type this package declares under `name`, if it declares one.
    """
    try _entities(name)? else None end

  fun size(): USize =>
    items.size()

  fun eq(that: PackageIndex box): Bool =>
    if items.size() != that.items.size() then
      return false
    end
    try
      var i: USize = 0
      while i < items.size() do
        if not (items(i)? == that.items(i)?) then
          return false
        end
        i = i + 1
      end
      true
    else
      false
    end
