use "collections"
use "../../upstream/tools/lib/ponylang/pony_analysis"
use "../../upstream/tools/lib/ponylang/pony_syntax"

class val _Declared
  """
  One declaration a reuse check can blame: its written name, where
  the name sits, and where its Info line points — the declaring
  keyword for entities, members and locals, the name itself for
  parameters.
  """
  let name: String val
  let name_offset: USize
  let info_offset: USize

  new val create(
    name': String val,
    name_offset': USize,
    info_offset': USize)
  =>
    name = name'
    name_offset = name_offset'
    info_offset = info_offset'

primitive _Fold
  """
  ponyc's case fold: a type-shaped name
  folds upper, a value-shaped one lower, so two names collide only
  when they sit on the same side and fold to the same string. ponyc's
  `is_name_type` looks past at most one leading underscore where this
  looks past them all; two names fold equal here only when their
  underscore prefixes are equal, so the checker misses a collision
  ponyc makes rather than reporting one ponyc does not.
  """
  fun apply(name: String val): String val =>
    if type_shaped(name) then name.upper() else name.lower() end

  fun type_shaped(name: String val): Bool =>
    """
    Whether the name sits on the type side of the fold: its first
    letter past any leading underscores is upper case.
    """
    var i: USize = 0
    while try name(i)? == '_' else false end do
      i = i + 1
    end
    match try name(i)? else ' ' end
    | let c: U8 if (c >= 'A') and (c <= 'Z') => true
    else
      false
    end

primitive CheckReuse
  """
  ponyc's `can't reuse name` rules — all but the duplicate-entity
  and duplicate-alias rules, which need the whole package or the
  resolver and live with the loader. Most are the scope pass; the
  ones a lambda's or object literal's desugar raises are the expr
  pass, and `apply` returns the two families separately. The rules:
  a duplicate written member in an entity or an object literal, a
  member named after a `use` alias, a member differing only by case
  from a member ponyc synthesizes, a type parameter named after a
  sibling, an enclosing entity's type parameter, or an earlier
  entity of the same package, and a local or parameter named after
  anything the scope chain already holds — an enclosing binding, a
  member of the enclosing entity, or a `use` alias. A lambda or object literal is
  its own scope island: ponyc rewrites it into an anonymous type
  whose chain reaches the module but not the enclosing method or
  entity, so its bindings collide only within the island, an object
  literal's own members stand in for entity members there, and `use`
  aliases collide from everywhere. Names collide case-folded per
  `_Fold`; `_` never collides; imported and builtin names are not in
  scope when this pass runs, so they never collide here.

  Each diagnostic carries ponyc's Info line at the previous use —
  except when the previous use is a `use` alias, where ponyc's Info
  has no source position and the checker emits none. ponyc's lambda
  and object-literal desugar runs its scope insert twice and so
  doubles each in-island report; the checker emits the block once,
  matching ponyc's first. ponyc also stops an entity's member walk at
  its first duplicate where the checker reports every one.
  """
  fun apply(
    file: FileData,
    entities: _PackageEntities val)
    : (Array[CheckDiagnostic] val, Array[CheckDiagnostic] val)
  =>
    """
    The reuse diagnostics for one file: its entities' members, its
    type parameters against the package's earlier entities, and its
    locals and parameters against their scope chains. Two families,
    on different ponyc rungs: a rule arising inside a lambda or an
    object literal comes from the desugar, ponyc's expr pass, after
    every name pass; everything else is the scope pass.
    """
    let scope_out = Array[CheckDiagnostic]
    let expr_out = Array[CheckDiagnostic]
    let tree = file.tree
    let at = file.facts.offsets()
    let islands = _Islands(tree, at)
    let aliases = _alias_folds(file)
    try
      for child in tree.children(0)? do
        if tree.kind(child)? is NdClassDef then
          _entity_rules(file, entities, aliases, child, scope_out)
        end
      end
    end
    for (element, _, _, kind, _) in tree.walk() do
      if kind is NdObject then
        _object_rules(file, element, aliases, expr_out)
      end
    end
    _all_type_params(file, entities, islands, scope_out, expr_out)
    _locals(file, islands, aliases, scope_out, expr_out)
    (_FreezeDiags(scope_out), _FreezeDiags(expr_out))

  fun _alias_folds(file: FileData): Set[String] val =>
    """
    The folded `use` aliases of the file, built once — every rule
    that checks the module scope's aliases looks here.
    """
    recover val
      let out = Set[String]
      for u in file.uses.values() do
        if u.scheme is UsePackage then
          match u.alias
          | let a: UseAlias => out.set(_Fold(a.name))
          end
        end
      end
      out
    end

  fun _entity_rules(
    file: FileData,
    entities: _PackageEntities val,
    aliases: Set[String] val,
    entity: USize,
    out: Array[CheckDiagnostic] ref)
  =>
    let tree = file.tree
    let at = file.facts.offsets()
    var keyword: SyntaxKind = TkTrait
    var keyword_offset: USize = 0
    var entity_name: String val = ""
    try
      for child in tree.children(entity)? do
        match tree.kind(child)?
        | TkClass | TkActor | TkPrimitive | TkStruct | TkTrait
        | TkInterface | TkType =>
          keyword = tree.kind(child)?
          keyword_offset = _offset(at, child)
        | TkId =>
          if entity_name.size() == 0 then
            entity_name = _txt(tree, at, child)
          end
        | NdMembers =>
          None
        end
      end
      _members(
        file, keyword, keyword_offset, entity_name, aliases,
        entity, out)
    end

  fun _object_rules(
    file: FileData,
    literal: USize,
    aliases: Set[String] val,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    An object literal's members take the entity rules with the
    literal's own blame sites: a duplicate written member as in an
    entity, and a member clashing with the `create` ponyc's desugar
    adds — added whatever the literal writes, its `expr_object` has
    no `has_member` guard, and built at the literal's member list, so
    the Error lands on the first member and the Info on the clashing
    one.
    """
    let tree = file.tree
    let at = file.facts.offsets()
    // ponyc's desugar builds the literal's class by prepending each
    // field and appending each method, with the synthesized `create`
    // last — so the class holds the fields reversed, then the
    // methods in written order, and each member clashes against
    // what was inserted before it.
    let fields = Array[_Declared]
    let methods = Array[_Declared]
    var first_kw: (USize | None) = None
    for (d, is_field, _) in
      _CollectMembers._list(tree, at, literal).values()
    do
      if first_kw is None then
        first_kw = d.info_offset
      end
      if is_field then
        fields.push(d)
      else
        methods.push(d)
      end
    end
    let seen = Map[String, _Declared]
    var create_reported = false
    let inserts = Array[_Declared](fields.size() + methods.size())
    var i = fields.size()
    while i > 0 do
      i = i - 1
      try inserts.push(fields(i)?) else _Unreachable() end
    end
    for d in methods.values() do
      inserts.push(d)
    end
    for d in inserts.values() do
      if _collide(file, seen, d, out) then
        continue
      end
      _alias_reuse(file, aliases, d, out)
      if (_Fold(d.name) == "create") and (not create_reported) then
        create_reported = true
        out.push(
          CheckDiagnostic(file.path,
            match first_kw
            | let f: USize => f
            | None => _Unreachable(); d.info_offset
            end,
            "can't reuse name 'create'"
            where info' = CheckDiagnostic(file.path,
              d.info_offset,
              _previous("create", d.name))))
      end
    end

  fun _members(
    file: FileData,
    keyword: SyntaxKind,
    keyword_offset: USize,
    entity_name: String val,
    aliases: Set[String] val,
    entity: USize,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    Duplicate written members, then the synthesized names: a
    synthesized member clashing with a written member differing only
    by case, or with a `use` alias, lands its error on the entity —
    the synthesized member's site.
    """
    let tree = file.tree
    let at = file.facts.offsets()
    let seen = Map[String, _Declared]
    let list = _CollectMembers._list(tree, at, entity)
    (let no_create, let no_override) =
      _CollectMembers._suppressions(list)
    for (d, _, _) in list.values() do
      if not _collide(file, seen, d, out) then
        _alias_reuse(file, aliases, d, out)
      end
    end
    for synth in
      _SynthesizedMembers(
        keyword, entity_name, no_create, no_override).values()
    do
      // A member exactly matching the synthesized name suppresses
      // the synthesis, so any fold match here differs by case.
      match try seen(_Fold(synth))? else None end
      | let prev: _Declared =>
        out.push(
          CheckDiagnostic(file.path, keyword_offset,
            "can't reuse name '" + synth + "'"
            where info' = CheckDiagnostic(file.path,
              prev.info_offset,
              _previous(synth, prev.name))))
      | None =>
        // A synthesized member's insert checks the module scope's
        // aliases too, blamed at the entity like its case clashes.
        if aliases.contains(_Fold(synth)) then
          out.push(
            CheckReuse.alias_clash(file.path, keyword_offset, synth))
        end
      end
    end

  fun _alias_reuse(
    file: FileData,
    aliases: Set[String] val,
    d: _Declared,
    out: Array[CheckDiagnostic] ref)
  =>
    """
    A member named after a `use` alias — the module scope a member's
    insert also checks. Reported without an Info line, like every
    alias reuse.
    """
    if aliases.contains(_Fold(d.name)) then
      out.push(CheckReuse.alias_clash(file.path, d.name_offset,
        d.name))
    end

  fun _collide(
    file: FileData,
    seen: Map[String, _Declared],
    d: _Declared,
    out: Array[CheckDiagnostic] ref)
    : Bool
  =>
    """
    Whether a previous declaration took the fold — the earlier
    declaration wins as the previous use, so an alias check only
    follows a miss here.
    """
    let fold = _Fold(d.name)
    match try seen(fold)? else None end
    | let prev: _Declared =>
      out.push(
        CheckDiagnostic(file.path, d.name_offset,
          "can't reuse name '" + d.name + "'"
          where info' = CheckDiagnostic(file.path, prev.info_offset,
            _previous(d.name, prev.name))))
      true
    | None =>
      seen(fold) = d
      false
    end

  fun _all_type_params(
    file: FileData,
    entities: _PackageEntities val,
    islands: _Islands val,
    scope_out: Array[CheckDiagnostic] ref,
    expr_out: Array[CheckDiagnostic] ref)
  =>
    """
    Every type-parameter list in the file — an entity's, a method's,
    a lambda's, an object-literal method's — against a sibling in its
    own list, a lexically enclosing list's parameter, or an entity
    the package's processing order already holds, checked innermost
    first as ponyc's scope walk finds them. ponyc scopes type
    parameters before its desugar, so a lambda's or a literal's see
    the whole lexical chain, unlike its values. A later entity of the
    same name is ponyc's name-pass shadowing rule, which this pass
    does not report.
    """
    let tree = file.tree
    let at = file.facts.offsets()
    // Parameters in lexical scope at the walk's position, each with
    // the depth of the node that declared it — visible through that
    // node's subtree.
    let stack = Array[(USize, String val, _Declared)]
    for (element, depth, at', kind, _) in tree.walk() do
      while
        try stack(stack.size() - 1)?._1 >= depth else false end
      do
        try stack.pop()? end
      end
      if kind is NdTypeParams then
        let out =
          match islands.innermost(at')
          | None => scope_out
          | let _: USize => expr_out
          end
        let seen = Map[String, _Declared]
        let sites = _param_sites(tree, at, element)
        for d in sites.values() do
          let fold = _Fold(d.name)
          let prev_declared =
            match try seen(fold)? else None end
            | let prev: _Declared => prev
            else
              seen(fold) = d
              try
                _on_stack(stack, fold)?
              else
                match entities.before(fold, file.path, d.name_offset)
                | let prev: _EntitySite =>
                  out.push(
                    CheckDiagnostic(file.path, d.name_offset,
                      "can't reuse name '" + d.name + "'"
                      where info' = CheckDiagnostic(prev.file,
                        prev.keyword_offset,
                        _previous(d.name, prev.name))))
                end
                continue
              end
            end
          out.push(
            CheckDiagnostic(file.path, d.name_offset,
              "can't reuse name '" + d.name + "'"
              where info' = CheckDiagnostic(file.path,
                prev_declared.info_offset,
                _previous(d.name, prev_declared.name))))
        end
        // ponyc's symtab keeps the first insert of a fold, so a
        // duplicated parameter never becomes the visible one.
        let pushed = Set[String]
        for d in sites.values() do
          let fold = _Fold(d.name)
          if not pushed.contains(fold) then
            pushed.set(fold)
            stack.push((depth - 1, fold, d))
          end
        end
      end
    end

  fun _on_stack(
    stack: Array[(USize, String val, _Declared)] box,
    fold: String val)
    : _Declared ?
  =>
    """The innermost enclosing parameter taking the fold."""
    var i = stack.size()
    while i > 0 do
      i = i - 1
      (let _, let held_fold, let d) = stack(i)?
      if held_fold == fold then
        return d
      end
    end
    error

  fun _param_sites(
    tree: SyntaxTree val,
    at: Array[USize] val,
    params: USize)
    : Array[_Declared]
  =>
    """
    Each type parameter's name site in one list. A type parameter has
    no declaring keyword, so its Info line points at the name itself.
    """
    let out = Array[_Declared]
    try
      for child in tree.children(params)? do
        if tree.kind(child)? is NdTypeParam then
          for part in tree.children(child)? do
            if tree.kind(part)? is TkId then
              let off = _offset(at, part)
              out.push(_Declared(_txt(tree, at, part), off, off))
              break
            end
          end
        end
      end
    end
    out

  fun _locals(
    file: FileData,
    islands: _Islands val,
    aliases: Set[String] val,
    scope_out: Array[CheckDiagnostic] ref,
    expr_out: Array[CheckDiagnostic] ref)
  =>
    """
    Each local and parameter against what its scope chain already
    holds: an earlier binding in the same scope island that is
    visible at it or declared by the same pattern, the members of its
    entity, object literal or lambda — the ones ponyc's sugar and
    desugar add included — and a `use` alias. A local becomes
    visible to later names when its declaring statement ends — a
    binding inside the statement's own expression does not reuse it —
    and a match capture when its case's body starts; names of one
    pattern clash with each other at once. Two parameters of one
    scope clash, and a lambda capture enters its scope before the
    parameters written ahead of it, so a parameter reusing a
    capture's name is the reuse and the capture the previous use.
    Entities and type parameters fold to the type side and can never
    collide with a local's value-side fold.
    """
    let tree = file.tree
    let at = file.facts.offsets()
    let sites = _declaration_sites(tree, at)
    let members_by_entity = _MemberSites(tree, at)
    let captures = _capture_names(tree, at)
    let local_facts = _LocalFacts(tree, at)
    // Per-binding facts, indexed exactly as `bindings` is.
    let bindings = file.facts.bindings
    let n = bindings.size()
    let folds = Array[String val](n)
    let isles = Array[(USize | None)](n)
    let caps = Array[Bool](n)
    let heads = Array[(USize | None)](n)
    var walk_at = USize(0)
    for b in bindings.values() do
      ifdef debug then
        // The retire sweep and the earliest-first break both read
        // the bindings as emitted in ascending name order.
        if b.name_from() < walk_at then
          _Unreachable()
        end
        walk_at = b.name_from()
      end
      folds.push(_Fold(b.name))
      isles.push(islands.innermost(b.name_from()))
      caps.push(captures.contains(b.name_from()))
      heads.push(local_facts.with_head(b.name_from()))
    end
    // A clash crosses neither a fold nor an island, so the buckets
    // key on both and the comparison stays inside one bucket.
    let buckets = Map[String, Array[USize]]
    var k = USize(0)
    while k < n do
      if not _all_underscores(
        try bindings(k)?.name else _Unreachable(); "_" end)
      then
        let isle_part: String val =
          match try isles(k)? else None end
          | let x: USize => x.string()
          | None => ""
          end
        let fold_part = try folds(k)? else _Unreachable(); "" end
        let key: String val =
          recover val
            String(fold_part.size() + isle_part.size() + 1)
              .>append(fold_part)
              .>append("#")
              .>append(isle_part)
          end
        try
          buckets(key)?.push(k)
        else
          buckets(key) = [k]
        end
      end
      k = k + 1
    end
    // Bucket order decides render order where two diagnostics share
    // an offset, so it cannot be the map's hash order.
    let bucket_keys = Array[String val](buckets.size())
    for k2 in buckets.keys() do
      bucket_keys.push(k2)
    end
    _SortStrings(bucket_keys)
    for bucket_key in bucket_keys.values() do
      let bucket =
        try buckets(bucket_key)? else _Unreachable(); continue end
      let by_span = Map[U128, Array[USize]]
      let by_pattern = Map[USize, Array[USize]]
      let by_head = Map[USize, Array[USize]]
      for j in bucket.values() do
        let x = try bindings(j)? else _Unreachable(); continue end
        let span_key = _span_key(x)
        try
          by_span(span_key)?.push(j)
        else
          by_span(span_key) = [j]
        end
        match local_facts.pattern_of(x.name_from())
        | let pat: USize =>
          try by_pattern(pat)?.push(j) else by_pattern(pat) = [j] end
        end
        match try heads(j)? else None end
        | let h: USize =>
          try by_head(h)?.push(j) else by_head(h) = [j] end
        end
      end
      let active = Array[USize]
      for b_i in bucket.values() do
        let b = try bindings(b_i)? else _Unreachable(); break end
        let name = b.name
        let name_at = b.name_from()
        // Retire scopes that closed before this binding.
        var w = USize(0)
        var r = USize(0)
        while r < active.size() do
          let idx = try active(r)? else _Unreachable(); break end
          let x = try bindings(idx)? else _Unreachable(); break end
          if x.scope_to() > name_at then
            try active(w)? = idx else _Unreachable() end
            w = w + 1
          end
          r = r + 1
        end
        active.truncate(w)
        match b.kind
        | BindLocal | BindParam => None
        else
          active.push(b_i)
          continue
        end
        let fold = try folds(b_i)? else _Unreachable(); "" end
        let isle = try isles(b_i)? else _Unreachable(); None end
        // A rule born inside an island is the desugar's, ponyc's
        // expr pass; everything else is the scope pass.
        let out =
          match isle
          | None => scope_out
          | let _: USize => expr_out
          end
        let b_cap = try caps(b_i)? else _Unreachable(); false end
        let b_head = try heads(b_i)? else _Unreachable(); None end
        // A binding whose previous use can be later-written — a
        // `with` name or a capture — needs every candidate before
        // selecting; anything else takes the earliest match.
        let need_all = (b_head isnt None) or b_cap
        var prev: (_Declared | None) = None
        let candidates = Array[USize]
        for idx in active.values() do
          if _try_candidate(bindings, b, b_i, idx, b_cap, b_head,
            caps, heads, local_facts)
          then
            candidates.push(idx)
            if not need_all then
              // Actives are in offset order, so the first match is
              // the earliest here; a group candidate can still win
              // with a smaller offset.
              break
            end
          end
        end
        let groups = Array[Array[USize] box]
        try
          groups.push(by_span(_span_key(b))?)
        else
          _Unreachable()
        end
        match local_facts.pattern_of(name_at)
        | let pat: USize => try groups.push(by_pattern(pat)?) end
        end
        match b_head
        | let h: USize => try groups.push(by_head(h)?) end
        end
        for group in groups.values() do
          for idx in group.values() do
            if (idx != b_i) and
              _try_candidate(bindings, b, b_i, idx, b_cap, b_head,
                caps, heads, local_facts)
            then
              candidates.push(idx)
              if not need_all then
                // Groups hold bucket members in ascending order, so
                // the first match is this group's earliest — the
                // selection keeps the earliest overall.
                break
              end
            end
          end
        end
        // ponyc names as "previous" what its symtab held when the
        // reuse was inserted. A prepended sibling — a later-written
        // capture, or a `with` name in another element — holds the
        // slot only when no ordinary candidate clashed with it
        // first, so any ordinary candidate wins, earliest first;
        // among prepended siblings the first-inserted one holds the
        // slot: the latest element's earliest id, or the latest
        // capture.
        var prev_at = USize(0)
        var prev_sib = false
        var prev_elem = USize(0)
        for idx in candidates.values() do
          let other =
            try bindings(idx)? else _Unreachable(); continue end
          let site =
            try
              sites(other.name_from())?
            else
              _Declared(other.name, other.name_from(),
                other.name_from())
            end
          let sib =
            (b_cap and (try caps(idx)? else false end)) or
              (match (b_head, try heads(idx)? else None end)
              | (let wb: USize, let wo: USize) if wb == wo =>
                not _same_elem(b, other, local_facts)
              else
                false
              end)
          if sib then
            let elem =
              match local_facts.with_elem(other.name_from())
              | let e: USize => e
              | None => other.name_from()
              end
            if
              (prev is None) or
                (prev_sib and ((elem > prev_elem) or
                  ((elem == prev_elem) and
                    (site.name_offset < prev_at))))
            then
              prev = site
              prev_at = site.name_offset
              prev_sib = true
              prev_elem = elem
            end
          else
            if
              (prev is None) or prev_sib or
                (site.name_offset < prev_at)
            then
              prev = site
              prev_at = site.name_offset
              prev_sib = false
            end
          end
        end
        active.push(b_i)
        var from_island = false
        if prev is None then
          match isle
          | None =>
            match members_by_entity.covering(name_at, fold)
            | let m: _Declared => prev = m
            end
          | let i2: USize =>
            try
              prev = islands.members(i2)(fold)?
              from_island = true
            end
          end
        end
        match prev
        | let p: _Declared =>
          if from_island and b_cap then
            // A capture becomes a field of the desugared class, and
            // ponyc appends the synthesized members after the fields
            // — so the synthesized member is the reuse and the
            // capture the previous use.
            out.push(
              CheckDiagnostic(file.path, p.info_offset,
                "can't reuse name '" + p.name + "'"
                where info' = CheckDiagnostic(file.path, name_at,
                  _previous(p.name, name))))
          else
            out.push(
              CheckDiagnostic(file.path, name_at,
                "can't reuse name '" + name + "'"
                where info' = CheckDiagnostic(file.path,
                  p.info_offset,
                  _previous(name, p.name))))
          end
          continue
        end
        // A `use` alias: reported without an Info line.
        if aliases.contains(fold) then
          out.push(CheckReuse.alias_clash(file.path, name_at, name))
        end
      end
    end

  fun alias_clash(path: String val, at: USize, name: String val)
    : CheckDiagnostic
  =>
    """
    An alias reuse, reported without an Info line as ponyc's
    positionless Info is not reproduced.
    """
    CheckDiagnostic(path, at, "can't reuse name '" + name + "'")

  fun duplicate(dup: _EntitySite, prev: _EntitySite)
    : CheckDiagnostic
  =>
    """
    The duplicate-entity diagnostic — the rule lives with the loader,
    which holds the whole package; the wording lives here with every
    other `can't reuse name`.
    """
    CheckDiagnostic(dup.file, dup.name_offset,
      "can't reuse name '" + dup.name + "'"
      where info' = CheckDiagnostic(prev.file, prev.keyword_offset,
        _previous(dup.name, prev.name)))

  fun _previous(written: String val, prev_name: String val)
    : String val
  =>
    if written == prev_name then
      "previous use of '" + written + "'"
    else
      "previous use of '" + written + "' differs only by case"
    end

  fun _clashes(
    b: Binding,
    other: Binding,
    b_cap: Bool,
    other_cap: Bool,
    b_head: (USize | None),
    other_head: (USize | None),
    facts: _LocalFacts val)
    : Bool
  =>
    """
    Whether `other` is a previous use `b` reuses: an earlier binding
    that is visible at `b` or declared by the same pattern at the
    same rank, an earlier binding sharing `b`'s scope span on the
    same side of a lambda's captures — or, at either side of `b`, a
    capture whose scope `b`'s parameter shares, or a same-statement
    binding `b` outranks.
    """
    match (b_head, other_head)
    | (let wb: USize, let wo: USize) if wb == wo =>
      // ponyc's `with` desugar prepends one local per element and
      // carries each element's ids through in written order — so
      // two ids of one element keep the ordinary rules below, and
      // across elements the earliest of a clashing pair reports
      // with the later one as the previous use. Whether a
      // cross-element pair clashes at all is the ordinary scope
      // question with the roles swapped — a nested block inside a
      // head initialiser still scopes its own locals.
      if not _same_elem(b, other, facts) then
        if other.name_from() < b.name_from() then
          return false
        end
        return _scope_clash(other, b, other_cap, b_cap, facts)
      end
    end
    if facts.cross_init(b.name_from(), other.name_from()) then
      return false
    end
    if b_cap and other_cap then
      // A lambda's captures are prepended one by one too, so the
      // earliest of a clashing pair reports and the later one is
      // the previous use.
      if other.name_from() < b.name_from() then
        return false
      end
      return _scope_clash(other, b, other_cap, b_cap, facts)
    end
    if other.name_from() < b.name_from() then
      _scope_clash(b, other, b_cap, other_cap, facts)
    else
      (_same_scope(b, other) and other_cap and (not b_cap)) or
        (facts.same_pattern(other.name_from(), b.name_from()) and
          (facts.rank(b.name_from()) >
            facts.rank(other.name_from())))
    end

  fun _try_candidate(
    bindings: Array[Binding] val,
    b: Binding,
    b_i: USize,
    idx: USize,
    b_cap: Bool,
    b_head: (USize | None),
    caps: Array[Bool] box,
    heads: Array[(USize | None)] box,
    facts: _LocalFacts val)
    : Bool
  =>
    """Whether the bucket member at `idx` is a previous use of `b`."""
    if idx == b_i then
      return false
    end
    let other =
      try bindings(idx)? else _Unreachable(); return false end
    _clashes(b, other, b_cap,
      try caps(idx)? else false end, b_head,
      try heads(idx)? else None end, facts)

  fun _span_key(b: Binding): U128 =>
    """The scope span's byte offsets packed as a bucket key."""
    (b.scope_from().u128() << 64) or b.scope_to().u128()

  fun _scope_clash(
    late: Binding,
    early: Binding,
    late_cap: Bool,
    early_cap: Bool,
    facts: _LocalFacts val)
    : Bool
  =>
    """
    Whether the earlier binding is a previous use the later one
    reuses: it covers the later name and is visible there, the same
    pattern declared both at one rank, or the two share a scope span
    on the same side of a lambda's captures.
    """
    (early.covers(late.name_from()) and
      (late.name_from() >= facts.visible_from(early.name_from()))) or
      (facts.same_pattern(early.name_from(), late.name_from()) and
        (facts.rank(early.name_from()) ==
          facts.rank(late.name_from()))) or
      (_same_scope(late, early) and (late_cap == early_cap))

  fun _same_scope(a: Binding, b: Binding): Bool =>
    (a.scope_from() == b.scope_from()) and
      (a.scope_to() == b.scope_to())

  fun _capture_names(tree: SyntaxTree val, at: Array[USize] val)
    : Set[USize] val
  =>
    """
    The name offsets of the file's lambda captures — the identifiers
    themselves, so a binding inside a capture's initialiser is not
    mistaken for one.
    """
    recover val
      let out = Set[USize]
      for (element, _, _, kind, _) in tree.walk() do
        if kind is NdLambdaCapture then
          try
            for part in tree.children(element)? do
              if tree.kind(part)? is TkId then
                out.set(at(part)?)
                break
              end
            end
          end
        end
      end
      out
    end

  fun _same_elem(a: Binding, b: Binding, facts: _LocalFacts val)
    : Bool
  =>
    """Whether two `with` names sit in one element's id list."""
    match
      (facts.with_elem(a.name_from()), facts.with_elem(b.name_from()))
    | (let x: USize, let y: USize) => x == y
    else
      false
    end

  fun _declaration_sites(tree: SyntaxTree val, at: Array[USize] val)
    : Map[USize, _Declared] val
  =>
    """
    Every `let`/`var`/`embed` local's declaration site, keyed by
    the name's byte offset — the join key the bindings projection
    shares. A local's Info line points at its keyword. Parameters
    are not here: a miss is the parameter case, and the caller's
    fallback sites them at their own name.
    """
    recover val
      let out = Map[USize, _Declared]
      var kw: USize = 0
      var pending = false
      for (element, _, _, kind, _) in tree.walk() do
        match kind
        | TkLet | TkVar | TkEmbed =>
          kw = _offset(at, element)
          pending = true
        | TkId =>
          if pending then
            let off = _offset(at, element)
            out(off) =
              _Declared(_txt(tree, at, element), off, kw)
            pending = false
          end
        | TkWhitespace | TkLineComment | TkNestedComment =>
          None
        else
          pending = false
        end
      end
      out
    end

  fun _all_underscores(name: String val): Bool =>
    var i: USize = 0
    while i < name.size() do
      if try name(i)? != '_' else true end then
        return false
      end
      i = i + 1
    end
    true

  fun _offset(at: Array[USize] val, element: USize): USize =>
    try at(element)? else _Unreachable(); 0 end

  fun _txt(
    tree: SyntaxTree val,
    at: Array[USize] val,
    element: USize)
    : String val
  =>
    _ProjectEntities._text(tree, at, element)

class val _MemberSites
  """
  Each top-level entity's span and its members' declaration sites,
  folded, the members ponyc's sugar adds included — what a local
  inside that entity collides with. A synthesized member's site is
  the entity's keyword, where ponyc's Info points.
  """
  let _spans: Array[(USize, USize, Map[String, _Declared] val)] val

  new val create(tree: SyntaxTree val, at: Array[USize] val) =>
    _spans =
      recover val
        let out = Array[(USize, USize, Map[String, _Declared] val)]
        try
          for child in tree.children(0)? do
            if tree.kind(child)? is NdClassDef then
              let from = CheckReuse._offset(at, child)
              var keyword: SyntaxKind = TkTrait
              var kw_off: USize = 0
              var entity_name: String val = ""
              for part in tree.children(child)? do
                match tree.kind(part)?
                | TkClass | TkActor | TkPrimitive | TkStruct
                | TkTrait | TkInterface | TkType =>
                  keyword = tree.kind(part)?
                  kw_off = CheckReuse._offset(at, part)
                | TkId =>
                  if entity_name.size() == 0 then
                    entity_name =
                      CheckReuse._txt(tree, at, part)
                  end
                end
              end
              let members: Map[String, _Declared] val =
                recover val
                  (let mm, let no_create, let no_override, _) =
                    _CollectMembers(tree, at, child)
                  for synth in
                    _SynthesizedMembers(
                      keyword, entity_name, no_create, no_override)
                      .values()
                  do
                    mm.insert_if_absent(
                      _Fold(synth), _Declared(synth, kw_off, kw_off))
                  end
                  mm
                end
              let to =
                try
                  let last = (child + tree.subtree_size(child)?) - 1
                  at(last)? + tree.width(last)?
                else
                  _Unreachable(); from
                end
              ifdef debug then
                // `covering`'s binary search reads the spans in
                // ascending start order.
                try
                  if out(out.size() - 1)?._1 > from then
                    _Unreachable()
                  end
                end
              end
              out.push((from, to, members))
            end
          end
        end
        out
      end

  fun covering(offset: USize, fold: String val)
    : (_Declared | None)
  =>
    // Top-level entities never overlap and the build walks them in
    // source order, so the last-starting span at or before the
    // offset is the only candidate.
    var lo: USize = 0
    var hi = _spans.size()
    while lo < hi do
      let mid = (lo + hi) / 2
      (let from, _, _) =
        try _spans(mid)? else _Unreachable(); return None end
      if from <= offset then
        lo = mid + 1
      else
        hi = mid
      end
    end
    if lo == 0 then
      return None
    end
    match try _spans(lo - 1)? else _Unreachable(); None end
    | (let from: USize, let to: USize,
      let members: Map[String, _Declared] val)
    =>
      if (offset >= from) and (offset < to) then
        return try members(fold)? else None end
      end
    end
    None

primitive _CollectMembers
  """
  The folded member declarations under an entity or object literal
  node — each member's written name, name offset, and declaring
  keyword offset, first declaration of a fold winning — with what
  the synthesized-member rules need alongside: whether a constructor
  or exact `create` suppresses sugar's `create`, whether an exact
  `runtime_override_defaults` suppresses Main's hook, and the first
  member's keyword offset.
  """
  fun apply(
    tree: SyntaxTree val,
    at: Array[USize] val,
    entity: USize)
    : (Map[String, _Declared], Bool, Bool, (USize | None))
  =>
    let out = Map[String, _Declared]
    var first_kw: (USize | None) = None
    let list = _list(tree, at, entity)
    (let no_create, let no_override) = _suppressions(list)
    for (d, _, _) in list.values() do
      if first_kw is None then
        first_kw = d.info_offset
      end
      out.insert_if_absent(_Fold(d.name), d)
    end
    (out, no_create, no_override, first_kw)

  fun _suppressions(list: Array[(_Declared, Bool, Bool)] box)
    : (Bool, Bool)
  =>
    """
    Whether the written members suppress sugar's `create` (a
    constructor, or any member exactly named it) and Main's override
    hook (any member exactly named it) — one home, so the member
    rule and the locals rule cannot disagree about which synthesized
    members exist.
    """
    var no_create = false
    var no_override = false
    for (d, _, is_new) in list.values() do
      if is_new or (d.name == "create") then
        no_create = true
      end
      if d.name == "runtime_override_defaults" then
        no_override = true
      end
    end
    (no_create, no_override)

  fun _list(
    tree: SyntaxTree val,
    at: Array[USize] val,
    entity: USize)
    : Array[(_Declared, Bool, Bool)]
  =>
    """
    The written members under an entity or object literal node, in
    written order: each member's sites, whether it is a field, and
    whether it is a constructor. The one walk every member rule
    reads, so two rules cannot differ on what counts as a member.
    """
    let out = Array[(_Declared, Bool, Bool)]
    try
      for child in tree.children(entity)? do
        if tree.kind(child)? is NdMembers then
          for member in tree.children(child)? do
            let kind = tree.kind(member)?
            match kind
            | NdField | NdMethod =>
              match _member_site(tree, at, member)
              | (let d: _Declared, let is_new: Bool) =>
                out.push((d, kind is NdField, is_new))
              end
            end
          end
        end
      end
    end
    out

  fun _member_site(
    tree: SyntaxTree val,
    at: Array[USize] val,
    member: USize)
    : ((_Declared, Bool) | None)
  =>
    """
    One member's written name, name offset and keyword offset, and
    whether it is a constructor.
    """
    var kw: USize = 0
    var found_kw = false
    var is_new = false
    try
      for part in tree.children(member)? do
        match tree.kind(part)?
        | TkWhitespace | TkLineComment | TkNestedComment
        | NdAnnotations =>
          None
        | TkId =>
          let off = CheckReuse._offset(at, part)
          if not found_kw then
            kw = off
          end
          return
            (_Declared(
              CheckReuse._txt(tree, at, part), off, kw),
              is_new)
        else
          if tree.kind(part)? is TkNew then
            is_new = true
          end
          if not found_kw then
            kw = CheckReuse._offset(at, part)
            found_kw = true
          end
        end
      end
    end
    None

primitive _SynthesizedMembers
  """
  The members ponyc's sugar adds: `create` for a concrete entity,
  unless a constructor or a member exactly named `create` is
  written, and Main's `runtime_override_defaults` hook, unless a
  member exactly named it is written — sugar's `has_member` checks
  the exact name, whatever the member's kind.
  """
  fun apply(
    keyword: SyntaxKind,
    entity_name: String val,
    no_create: Bool,
    no_override: Bool)
    : Array[String val]
  =>
    // In ponyc's insertion order: sugar_entity adds Main's override
    // hook before the default constructor.
    let out = Array[String val]
    if (keyword is TkActor) and (entity_name == "Main") and
      (not no_override)
    then
      out.push("runtime_override_defaults")
    end
    match keyword
    | TkClass | TkActor | TkPrimitive | TkStruct =>
      if not no_create then
        out.push("create")
      end
    end
    out

class val _Islands
  """
  The file's lambdas and object literals — each the span of a scope
  island. ponyc rewrites the literal into an anonymous type whose
  scope chain reaches the module but not the enclosing method or
  entity, so `_locals` collides bindings only within one island and
  reads the island's own members where an entity's would otherwise
  apply. An object literal's map holds its written members plus the
  `create` ponyc's desugar adds regardless, sited at the first
  member as ponyc's Info is; a lambda's holds the `create` and
  `apply` its desugar builds, sited at the lambda itself.
  """
  let _spans:
    Array[(USize, USize, Map[String, _Declared] val)] val
  let _parents: Array[(USize | None)] val

  new val create(tree: SyntaxTree val, at: Array[USize] val) =>
    _spans =
      recover val
        let out =
          Array[(USize, USize, Map[String, _Declared] val)]
        for (element, _, _, kind, _) in tree.walk() do
          match kind
          | NdLambda | NdBareLambda | NdObject =>
            try
              let from = at(element)?
              let last = (element + tree.subtree_size(element)?) - 1
              let to = at(last)? + tree.width(last)?
              let mm: Map[String, _Declared] val =
                if kind is NdObject then
                  recover val
                    (let held, _, _, let first_kw) =
                      _CollectMembers(tree, at, element)
                    match first_kw
                    | let f: USize =>
                      held.insert_if_absent(
                        _Fold("create"), _Declared("create", f, f))
                    end
                    held
                  end
                else
                  recover val
                    let held = Map[String, _Declared]
                    held(_Fold("create")) =
                      _Declared("create", from, from)
                    held(_Fold("apply")) =
                      _Declared("apply", from, from)
                    held
                  end
                end
              ifdef debug then
                // `innermost`'s binary search and the parent chain
                // read the spans in ascending start order.
                try
                  if out(out.size() - 1)?._1 > from then
                    _Unreachable()
                  end
                end
              end
              out.push((from, to, mm))
            else
              _Unreachable()
            end
          end
        end
        out
      end
    _parents =
      recover val
        // The walk pushes spans in start order, so a stack of the
        // still-open spans links each to its innermost encloser.
        let out = Array[(USize | None)](_spans.size())
        let stack = Array[USize]
        var i: USize = 0
        while i < _spans.size() do
          (let from, let to, _) =
            try _spans(i)? else _Unreachable(); break end
          while stack.size() > 0 do
            let top = try stack(stack.size() - 1)? else break end
            (_, let top_to, _) =
              try _spans(top)? else _Unreachable(); break end
            if top_to <= from then
              try stack.pop()? else _Unreachable() end
            else
              break
            end
          end
          out.push(try stack(stack.size() - 1)? else None end)
          stack.push(i)
          i = i + 1
        end
        out
      end

  fun innermost(offset: USize): (USize | None) =>
    """
    The index of the innermost island whose span holds the offset,
    or None outside every island. Nested islands nest strictly, so
    every span holding the offset encloses the last-starting span
    at or before it — that span's chain of enclosers holds them
    all, innermost first.
    """
    var lo: USize = 0
    var hi = _spans.size()
    while lo < hi do
      let mid = (lo + hi) / 2
      (let from, _, _) =
        try _spans(mid)? else _Unreachable(); return None end
      if from <= offset then
        lo = mid + 1
      else
        hi = mid
      end
    end
    if lo == 0 then
      return None
    end
    var walk: (USize | None) = lo - 1
    while true do
      match walk
      | let i: USize =>
        (let from, let to, _) =
          try _spans(i)? else _Unreachable(); return None end
        if (offset >= from) and (offset < to) then
          return i
        end
        walk = try _parents(i)? else _Unreachable(); None end
      | None =>
        break
      end
    end
    None

  fun members(isle: USize): Map[String, _Declared] val =>
    """
    The island's member map — every island has one, since a lambda
    carries its desugared `create` and `apply`.
    """
    try
      _spans(isle)?._3
    else
      _Unreachable()
      recover val Map[String, _Declared] end
    end

class val _LocalFacts
  """
  When each of the file's locals becomes visible to later names, and
  which pattern declared it. A local's name enters its scope when the
  statement declaring it ends, so nothing inside the statement's own
  expression reuses it; a match capture's enters when its case's body
  starts, visible through guard and body. Names declared by one
  pattern — a tuple assignment's elements, a case pattern's captures
  — clash with each other at once; `same_pattern` is that test.
  """
  let _visible: Map[USize, USize] val
  let _pattern: Map[USize, USize] val
  let _rank: Map[USize, USize] val
  let _with_names: Array[(USize, USize, USize)] val
    """
    The byte spans of `with` name positions — each element's names,
    up to its `=` — tagged by their `with`, whose desugar prepends
    the names, reversing their insertion order. A head initialiser
    is not a name position: its locals insert before any name.
    """
  let _with_inits: Array[(USize, USize, USize, USize)] val
    """
    The byte spans of `with` initialisers — each element from its
    `=` to its end — tagged by their `with` and their element.
    ponyc's desugar lifts the initialisers out in reversed element
    order, which these facts do not model, so two elements'
    initialisers declaring one name are not compared: the pair
    fails open rather than blaming a site ponyc does not.
    """

  new val create(tree: SyntaxTree val, at: Array[USize] val) =>
    (_visible, _pattern, _rank, _with_names, _with_inits) =
      _build(tree, at)

  fun tag _build(tree: SyntaxTree val, at: Array[USize] val)
    : (Map[USize, USize] val, Map[USize, USize] val,
      Map[USize, USize] val, Array[(USize, USize, USize)] val,
      Array[(USize, USize, USize, USize)] val)
  =>
    let visible = Map[USize, USize]
    let pattern = Map[USize, USize]
    let ranks = Map[USize, USize]
    let with_names = Array[(USize, USize, USize)]
    let with_inits = Array[(USize, USize, USize, USize)]
    // Every element on the path from the root to the walk's current
    // element: its element id, depth, `_code`, offset, and width.
    let chain = Array[(USize, USize, U8, USize, USize)]
    for (element, depth, at', kind, width) in tree.walk() do
      while
        try chain(chain.size() - 1)?._2 >= depth else false end
      do
        try chain.pop()? end
      end
      if kind is NdLocal then
        _record(tree, at, element, at', width, chain, visible,
          pattern, ranks)
      elseif kind is NdWith then
        try
          for child in tree.children(element)? do
            if tree.kind(child)? is NdWithElem then
              for part in tree.children(child)? do
                if tree.kind(part)? is TkAssign then
                  with_names.push((at(child)?, at(part)?, element))
                  with_inits.push(
                    (at(part)?, at(child)? + tree.width(child)?,
                      element, child))
                  break
                end
              end
            end
          end
        end
      end
      chain.push((element, depth, _code(kind), at', width))
    end
    let v = recover iso Map[USize, USize](visible.size()) end
    for (k, value) in visible.pairs() do
      v(k) = value
    end
    let q = recover iso Map[USize, USize](pattern.size()) end
    for (k, value) in pattern.pairs() do
      q(k) = value
    end
    let r = recover iso Map[USize, USize](ranks.size()) end
    for (k, value) in ranks.pairs() do
      r(k) = value
    end
    // The walk pushes every element region of a `with` when it
    // reaches the `with` itself, so a `with` nested in an earlier
    // element's initialiser lands after regions that start past it.
    // The binary search in `_region` needs start order, so sort —
    // the regions never overlap, a nested `with` sitting past its
    // element's `=`.
    var sort_i: USize = 1
    while sort_i < with_names.size() do
      let held = try with_names(sort_i)? else _Unreachable(); break end
      var back = sort_i
      while
        (back > 0) and
          ((try with_names(back - 1)? else _Unreachable(); held end)._1
            > held._1)
      do
        try
          with_names(back)? = with_names(back - 1)?
        else
          _Unreachable()
        end
        back = back - 1
      end
      try with_names(back)? = held else _Unreachable() end
      sort_i = sort_i + 1
    end
    let w =
      recover iso Array[(USize, USize, USize)](with_names.size()) end
    for span in with_names.values() do
      w.push(span)
    end
    let wi =
      recover iso
        Array[(USize, USize, USize, USize)](with_inits.size())
      end
    for span in with_inits.values() do
      wi.push(span)
    end
    (consume v, consume q, consume r, consume w, consume wi)

  fun tag _record(
    tree: SyntaxTree val,
    at: Array[USize] val,
    local: USize,
    local_from: USize,
    local_width: USize,
    chain: Array[(USize, USize, U8, USize, USize)] box,
    visible: Map[USize, USize],
    pattern: Map[USize, USize],
    ranks: Map[USize, USize])
  =>
    let name =
      match _bound_id(tree, local)
      | let id: USize => CheckReuse._offset(at, id)
      | None => return
      end
    // The nearest enclosing scope, looking past the sequences that
    // groups, tuples and `with` elements wrap — ponyc opens no
    // scope for those. The
    // entry inside it on the path is the local's statement.
    var i = chain.size()
    var inner = local
    var inner_from = local_from
    var inner_width = local_width
    while i > 0 do
      i = i - 1
      (let element, _, let code, let from, let width) =
        try chain(i)? else _Unreachable(); return end
      let transparent =
        (code == _group()) or
        ((code == _seq()) and
          ((try chain(i - 1)?._3 else _other() end) == _group()))
      if transparent then
        inner = element
        inner_from = from
        inner_width = width
        continue
      end
      if code == _case() then
        if name < _body_start(tree, at, element) then
          // A capture in the case's pattern.
          visible(name) = _body_start(tree, at, element)
          pattern(name) = element
          ranks(name) = 1
          return
        end
        inner = element
        inner_from = from
        inner_width = width
        continue
      end
      if (code == _seq()) or (code == _scope()) then
        // `inner` is the statement: the path's entry directly under
        // the scope the local lands in. ponyc scopes an assignment's
        // right side before the pattern on its left, so within one
        // statement a left-side local ranks above a right-side one
        // and reuses its name.
        visible(name) = inner_from + inner_width
        pattern(name) = inner
        ranks(name) =
          if name < _assign_op(tree, at, inner) then 1 else 0 end
        return
      end
      inner = element
      inner_from = from
      inner_width = width
    end

  fun tag _code(kind: SyntaxKind): U8 =>
    """
    What `_record` needs of a node: a transparent wrapper — a
    group, a tuple or a `with` element — a sequence, a case,
    another scope opener, or none of those. Both lists here must
    agree with `_Bindings` in pony_analysis/_project.pony, whose
    scope spans `_clashes` combines with these facts: the
    transparent kinds with `group_at`, and the scope openers with
    `_OpensScope`. If either pair diverges, the two sides compute
    different scope spans for the same node, and a reuse is
    reported at the wrong site or missed. A code rather
    than the `SyntaxKind` itself: ponyc 0.69.1 hangs type-checking
    an array of tuples that carries the full kind union.
    """
    match kind
    | NdGrouped | NdTuple | NdWithElem => _group()
    | NdSeq => _seq()
    | NdCase => _case()
    | NdModule | NdClassDef | NdMethod | NdObject | NdLambda
    | NdBareLambda | NdFor | NdWith | NdUseFFI | NdDefaultArg =>
      _scope()
    else
      _other()
    end

  fun tag _group(): U8 => 1
  fun tag _seq(): U8 => 2
  fun tag _case(): U8 => 3
  fun tag _scope(): U8 => 4
  fun tag _other(): U8 => 0

  fun tag _bound_id(tree: SyntaxTree val, local: USize)
    : (USize | None)
  =>
    """The local's name: its first identifier child."""
    try
      for child in tree.children(local)? do
        if tree.kind(child)? is TkId then
          return child
        end
      end
    end
    None

  fun tag _assign_op(
    tree: SyntaxTree val,
    at: Array[USize] val,
    statement: USize)
    : USize
  =>
    """
    The offset of the statement's own `=`, or 0 when it has none —
    every name then ranks as right-side.
    """
    try
      if tree.kind(statement)? is NdAssign then
        for child in tree.children(statement)? do
          if tree.kind(child)? is TkAssign then
            return at(child)?
          end
        end
      end
    end
    0

  fun tag _body_start(
    tree: SyntaxTree val,
    at: Array[USize] val,
    case_element: USize)
    : USize
  =>
    """Where the case's body begins: after its `=>`."""
    try
      for child in tree.children(case_element)? do
        if tree.kind(child)? is TkDblarrow then
          return at(child)? + tree.width(child)?
        end
      end
    end
    0

  fun visible_from(name: USize): USize =>
    """
    Where the local declared at this name offset becomes visible to
    later names; the offset itself for anything not a local.
    """
    try _visible(name)? else name end

  fun same_pattern(a: USize, b: USize): Bool =>
    """Whether one pattern declared the locals at both offsets."""
    try _pattern(a)? == _pattern(b)? else false end

  fun pattern_of(name: USize): (USize | None) =>
    """The statement or pattern that declared the local, if any."""
    try _pattern(name)? else None end

  fun rank(name: USize): USize =>
    """
    The local's insertion rank within its statement: 1 on an
    assignment's left side or in a case pattern, 0 elsewhere.
    """
    try _rank(name)? else 0 end

  fun cross_init(a: USize, b: USize): Bool =>
    """
    Whether the two offsets sit in different elements' initialisers
    of one `with` — the pair the desugar's lift order covers and
    these facts do not, so it fails open. Initialiser regions can
    nest (a `with` inside an initialiser), so membership is checked
    per region, not by search.
    """
    for (from_a, to_a, with_a, elem_a) in _with_inits.values() do
      if (a >= from_a) and (a < to_a) then
        for (from_b, to_b, with_b, elem_b) in _with_inits.values() do
          if
            (b >= from_b) and (b < to_b) and (with_a == with_b) and
              (elem_a != elem_b)
          then
            return true
          end
        end
      end
    end
    false

  fun with_elem(offset: USize): (USize | None) =>
    """
    The `with` element whose name region holds the offset — the
    region's start stands for the element — or None outside one.
    """
    match _region(offset)
    | (let from: USize, _, _) => from
    | None => None
    end

  fun _region(offset: USize)
    : ((USize, USize, USize) | None)
  =>
    """
    The name region holding the offset. The regions never overlap
    and `_build` sorts them by start, so the last-starting region
    at or before the offset is the only candidate.
    """
    var lo: USize = 0
    var hi = _with_names.size()
    while lo < hi do
      let mid = (lo + hi) / 2
      (let from, _, _) =
        try _with_names(mid)? else _Unreachable(); return None end
      if from <= offset then
        lo = mid + 1
      else
        hi = mid
      end
    end
    if lo == 0 then
      return None
    end
    match try _with_names(lo - 1)? else _Unreachable(); None end
    | (let from: USize, let to: USize, let with_id: USize) =>
      if (offset >= from) and (offset < to) then
        return (from, to, with_id)
      end
    end
    None

  fun with_head(offset: USize): (USize | None) =>
    """
    The `with` whose name positions hold the offset, or None — an
    offset anywhere else in a `with`, initialisers included, is no
    name of its.
    """
    match _region(offset)
    | (_, _, let with_id: USize) => with_id
    | None => None
    end

class val _EntitySite
  """One entity declaration: name, file, and both positions."""
  let name: String val
  let file: String val
  let keyword_offset: USize
  let name_offset: USize

  new val create(
    name': String val,
    file': String val,
    keyword_offset': USize,
    name_offset': USize)
  =>
    name = name'
    file = file'
    keyword_offset = keyword_offset'
    name_offset = name_offset'

class val _PackageEntities
  """
  A package's entity declarations in ponyc's processing order —
  files descending bytewise, source order within a file.
  """
  let _sites: Array[_EntitySite] val
  let _by_fold: Map[String, _EntitySite] val
    """
    The first site per folded name, in processing order — what
    ponyc's symbol table holds after every insert, since a later
    duplicate never replaces the first.
    """
  let _folded: Array[(String val, _EntitySite)] val

  new val create(files: Array[FileData] val) =>
    let sites = recover iso Array[_EntitySite] end
    var i = files.size()
    while i > 0 do
      i = i - 1
      let file = try files(i)? else _Unreachable(); break end
      let tree = file.tree
      let at = file.facts.offsets()
      try
        for child in tree.children(0)? do
          if tree.kind(child)? is NdClassDef then
            var kw_off: USize = 0
            var name_off: USize = 0
            var name: String val = ""
            for part in tree.children(child)? do
              match tree.kind(part)?
              | TkClass | TkActor | TkPrimitive | TkStruct | TkTrait
              | TkInterface | TkType =>
                kw_off = CheckReuse._offset(at, part)
              | TkId =>
                if name.size() == 0 then
                  name = CheckReuse._txt(tree, at, part)
                  name_off = CheckReuse._offset(at, part)
                end
              end
            end
            if name.size() > 0 then
              sites.push(
                _EntitySite(name, file.path, kw_off, name_off))
            end
          end
        end
      end
    end
    _sites = consume sites
    _by_fold =
      recover val
        let out = Map[String, _EntitySite]
        for s in _sites.values() do
          out.insert_if_absent(_Fold(s.name), s)
        end
        out
      end
    _folded =
      recover val
        let out = Array[(String val, _EntitySite)](_sites.size())
        for s in _sites.values() do
          out.push((_Fold(s.name), s))
        end
        out
      end

  fun duplicates(): Array[(_EntitySite, _EntitySite)] val =>
    """
    Every entity whose folded name an earlier processing position
    already declared, paired with that first declaration.
    """
    recover val
      let out = Array[(_EntitySite, _EntitySite)]
      let first = Map[String, _EntitySite]
      for s in _sites.values() do
        let fold = _Fold(s.name)
        match try first(fold)? else None end
        | let prev: _EntitySite => out.push((s, prev))
        | None => first(fold) = s
        end
      end
      out
    end

  fun all(): Array[_EntitySite] val =>
    """Every declaration site, in processing order."""
    _sites

  fun folded(): Array[(String val, _EntitySite)] val =>
    """
    Every declaration site paired with its folded name, in
    processing order — folded once here rather than per lookup.
    """
    _folded

  fun by_fold(fold: String val): (_EntitySite | None) =>
    """
    The first site whose folded name is the already-folded `fold`,
    in processing order — the case-insensitive lookup ponyc's
    `symtab_find_case` makes.
    """
    try _by_fold(fold)? else None end

  fun before(fold: String val, file: String val, offset: USize)
    : (_EntitySite | None)
  =>
    """
    The first entity declaring the already-folded `fold` at a
    processing position earlier than (file, offset), or None — only
    an entity already processed clashes.
    """
    match by_fold(fold)
    | let s: _EntitySite =>
      if (s.file.compare(file) is Greater) or
        ((s.file == file) and (s.keyword_offset < offset))
      then
        s
      else
        None
      end
    | None => None
    end
