use "collections"

class val EntityPath is (Hashable & Equatable[EntityPath])
  """
  A type declaration, named by its package and its own name.

  Survives any edit that neither renames nor deletes it, which is what lets
  it be handed to a client and handed back, and what lets an index built
  from it outlive an edit to a body.
  """
  let package: String val
  let entity: String val
  let _hash: USize

  new val create(package': String val, entity': String val) =>
    package = package'
    entity = entity'
    _hash = _PathHash(_PathHash(_PathHash.seed(), package'), entity')

  fun hash(): USize =>
    """
    Computed once here rather than on every lookup.

    `String.hash` re-hashes the whole string each call and `String.eq` is a
    comparison with no pointer fast path. A workspace query compares paths on
    the order of a hundred thousand times.
    """
    _hash

  fun eq(that: EntityPath box): Bool =>
    (_hash == that._hash)
      and (entity == that.entity)
      and (package == that.package)

  fun string(): String val =>
    package + "." + entity

class val MemberPath is (Hashable & Equatable[MemberPath])
  """
  A method or a field of an entity, named on the same terms.
  """
  let owner: EntityPath
  let member: String val
  let _hash: USize

  new val create(owner': EntityPath, member': String val) =>
    owner = owner'
    member = member'
    _hash = _PathHash(owner'.hash(), member')

  fun hash(): USize =>
    _hash

  fun eq(that: MemberPath box): Bool =>
    (_hash == that._hash)
      and (member == that.member)
      and (owner == that.owner)

  fun string(): String val =>
    owner.string() + "." + member

type ItemPath is (EntityPath | MemberPath)
  """
  What a declaration is called. An entity, or something an entity declares.
  """

primitive _PathHash
  """
  FNV-1a over the pieces of a path, folded left so that a member's hash can
  start from its owner's rather than re-walking it.
  """
  fun seed(): USize => 14695981039346656037

  fun apply(from: USize, text: String val): USize =>
    var h = from
    for byte in text.values() do
      h = (h xor byte.usize()) * 1099511628211
    end
    h
