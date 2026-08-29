use "../pony_analysis"

class val BoundItem is Equatable[BoundItem]
  """
  One declaration, as the workspace index holds it: what it is called, what
  it is, and which file declares it.

  No span. A span here would make every value in the index change whenever
  anything earlier in its file did, which is the invalidation flaw the
  package docstring describes. Spans come from the one document that has
  them, after a name has resolved.
  """
  let path: ItemPath
  let kind: DeclarationKind
  let file: String val

  new val create(
    path': ItemPath,
    kind': DeclarationKind,
    file': String val)
  =>
    path = path'
    kind = kind'
    file = file'

  fun name(): String val =>
    """
    The identifier this was declared under, unqualified.
    """
    match \exhaustive\ path
    | let entity: EntityPath => entity.entity
    | let member: MemberPath => member.member
    end

  fun is_entity(): Bool =>
    match path
    | let _: EntityPath => true
    else
      false
    end

  fun eq(that: BoundItem box): Bool =>
    (kind is that.kind) and (file == that.file) and
      match (path, that.path)
      | (let a: EntityPath, let b: EntityPath) => a == b
      | (let a: MemberPath, let b: MemberPath) => a == b
      else
        false
      end

class val Import is Equatable[Import]
  """
  A `use` in a file: the package it names and the name it binds it to.

  `alias` is empty for an unaliased `use`, which puts the package's types
  into scope under their own names rather than behind a qualifier.
  """
  let package: String val
  let alias: String val

  new val create(package': String val, alias': String val = "") =>
    package = package'
    alias = alias'

  fun eq(that: Import box): Bool =>
    (package == that.package) and (alias == that.alias)
