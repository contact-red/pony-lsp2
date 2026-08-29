use "collections"
use "../pony_analysis"

primitive _Project
  """
  Turn what one document declares into what the index holds.

  The container index on a `Declaration` points at whatever encloses it,
  which is how a member finds its owner.

  What an `object` literal declares is dropped. Its methods are enclosed by
  a *method* rather than by an entity, because the literal itself has no
  name to be enclosed by -- and a name path through an anonymous type names
  nothing. Keeping them would put `Outer.apply` in the index for an `apply`
  that `Outer` does not have.
  """
  fun apply(
    package: String val,
    file: String val,
    declared: Array[Declaration] val)
    : Array[BoundItem] val
  =>
    recover val
      let out = Array[BoundItem](declared.size())

      // One slot per declaration, so a member can find what encloses it.
      // `None` marks one that is inside an `object` literal, which makes
      // everything nested further inside it unnameable too.
      let paths = Array[(ItemPath | None)](declared.size())

      for declaration in declared.values() do
        let path: (ItemPath | None) =
          match declaration.container
          | let owner: USize =>
            match try paths(owner)? else None end
            | let entity: EntityPath => MemberPath(entity, declaration.name)
            else
              None
            end
          else
            EntityPath(package, declaration.name)
          end

        paths.push(path)
        match path
        | let named: ItemPath =>
          out.push(BoundItem(named, declaration.kind, file))
        end
      end

      out
    end
