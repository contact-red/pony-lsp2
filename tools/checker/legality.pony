use "../../upstream/tools/lib/ponylang/pony_syntax"

primitive CheckLegality
  """
  ponyc's `syntax`-pass legality rules that need nothing but the tree:
  the entity and method permission tables from `pass/syntax.c`, ported row
  for row with ponyc's own wordings, plus the Main checks, the reserved
  `_` names, the type-alias type requirement, the provides-type shape, and
  object-literal field initialisation.

  Body-level rules from the same pass — compile intrinsics, semicolon
  placement, FFI calls in default methods — are not here yet; each lands
  with its corpus case.
  """
  fun apply(file: String val, tree: SyntaxTree val): Array[CheckDiag] val =>
    recover val
      let out = Array[CheckDiag]
      // Offsets and widths by element index, so structure walks below can
      // locate any element without recomputing.
      let at = Array[USize](tree.size())
      let width = Array[USize](tree.size())
      for (_, _, a, _, w) in tree.walk() do
        at.push(a)
        width.push(w.usize())
      end

      for (element, _, a, kind, w) in tree.walk() do
        if kind is NdClassDef then
          _entity(file, tree, element, a, w.usize(), at, width, out)
        elseif kind is NdObject then
          _object_fields(file, tree, element, at, width, out)
        end
      end
      out
    end

  fun _entity(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    a: USize,
    w: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    var ent: USize = 0
    var name: String val = ""
    var name_i: (USize | None) = None
    var c_api: (USize | None) = None
    var defcap: (USize | None) = None
    var typeparams: (USize | None) = None
    var provides: (USize | None) = None
    var members: (USize | None) = None

    try
      for child in tree.children(element)? do
        match tree.kind(child)?
        | TkActor => ent = 0
        | TkClass => ent = 1
        | TkStruct => ent = 2
        | TkPrimitive => ent = 3
        | TkTrait => ent = 4
        | TkInterface => ent = 5
        | TkType => ent = 6
        | TkAt => c_api = child
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if name_i is None then defcap = child end
        | TkId =>
          if name_i is None then
            name_i = child
            name = recover val tree.text(child)? end
          end
        | NdTypeParams => typeparams = child
        | NdProvides => provides = child
        | NdMembers => members = child
        end
      end
    end

    let desc = _EntityDesc(ent)

    if name == "Main" then
      match typeparams
      | let tp: USize =>
        _diag(file, tp, at, width, out,
          "the Main actor cannot have type parameters")
      end
      if _EntityPerm.main(ent) == 'N' then
        out.push(CheckDiag(file, a, w, "Main must be an actor"))
      end
    end
    if name == "_" then
      match name_i
      | let id: USize =>
        _diag(file, id, at, width, out, desc + " name cannot be \"_\"")
      end
    end
    match defcap
    | let cap: USize if _EntityPerm.cap(ent) == 'N' =>
      _diag(file, cap, at, width, out,
        desc + " cannot specify default capability")
    end
    match c_api
    | let bare: USize =>
      if _EntityPerm.c_api(ent) == 'N' then
        _diag(file, bare, at, width, out, desc + " cannot specify C api")
      elseif typeparams isnt None then
        match typeparams
        | let tp: USize =>
          _diag(file, tp, at, width, out,
            "generic actor cannot specify C api")
        end
      end
    end
    if ent == 6 then
      if provides is None then
        match name_i
        | let id: USize =>
          _diag(file, id, at, width, out, "a type alias must specify a type")
        end
      end
    else
      match provides
      | let pr: USize => _provides(file, tree, pr, at, width, out)
      end
    end
    match members
    | let ms: USize => _members(file, tree, ent, ms, at, width, out)
    end

  fun _members(
    file: String val,
    tree: SyntaxTree val,
    ent: USize,
    members: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for member in tree.children(members)? do
        match tree.kind(member)?
        | NdField =>
          if _EntityPerm.field(ent) == 'N' then
            _diag(file, member, at, width, out,
              "Can't have fields in " + _EntityDesc(ent))
          end
          _id_is(file, tree, member, "field", at, width, out)
        | NdMethod =>
          _method(file, tree, ent, member, at, width, out)
        end
      end
    end

  fun _method(
    file: String val,
    tree: SyntaxTree val,
    ent: USize,
    method: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    var mkind: USize = 0
    var cap: (USize | None) = None
    var bare: (USize | None) = None
    var ret: (USize | None) = None
    var err: (USize | None) = None
    var body = false
    var named = false

    try
      for child in tree.children(method)? do
        match tree.kind(child)?
        | TkFun => mkind = 0
        | TkBe => mkind = 1
        | TkNew => mkind = 2
        | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag =>
          if not named then cap = child end
        | TkAt => if not named then bare = child end
        | TkId => named = true
        | TkColon => ret = child
        | TkQuestion => err = child
        | TkDblarrow => body = true
        end
      end
    end

    let desc = _MethodDesc(mkind, ent)
    match _MethodPerm(mkind, ent)
    | None =>
      _diag(file, method, at, width, out, desc + "s are not allowed")
      return
    | let perms: String val =>
      _element(file, perms, 0, cap, method, "receiver capability", desc,
        at, width, out)
      _element(file, perms, 1, bare, method, "bareness", desc,
        at, width, out)
      _element(file, perms, 2, ret, method, "return type", desc,
        at, width, out)
      _element(file, perms, 3, err, method, "?", desc, at, width, out)
      let body_el: (USize | None) = if body then method else None end
      _element(file, perms, 4, body_el, method, "body", desc,
        at, width, out)
    end
    _id_is(file, tree, method, "method", at, width, out)

  fun _element(
    file: String val,
    perms: String val,
    index: USize,
    actual: (USize | None),
    report_at: USize,
    context: String val,
    desc: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    let permission = try perms(index)? else 'X' end
    if (permission == 'N') and (actual isnt None) then
      match actual
      | let el: USize =>
        _diag(file, el, at, width, out,
          desc + " cannot specify " + context)
      end
    elseif (permission == 'Y') and (actual is None) then
      _diag(file, report_at, at, width, out,
        desc + " must specify " + context)
    end

  fun _provides(
    file: String val,
    tree: SyntaxTree val,
    provides: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(provides)? do
        match tree.kind(child)?
        | NdNominal | NdInfixType | NdGroupedType =>
          _provides_type(file, tree, child, at, width, out)
        end
      end
    end

  fun _provides_type(
    file: String val,
    tree: SyntaxTree val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    """
    ponyc's `check_provides_type`: a provides type is a nominal without a
    capability, an intersection of such, or parentheses around one. A `|`
    in an infix type, or any other type shape, is invalid there.
    """
    try
      match tree.kind(element)?
      | NdNominal =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkIso | TkTrn | TkRef | TkVal | TkBox | TkTag
          | TkCapRead | TkCapSend | TkCapShare | TkCapAlias | TkCapAny =>
            _diag(file, child, at, width, out,
              "can't specify a capability in a provides type")
          | TkEphemeral | TkAliased =>
            _diag(file, child, at, width, out,
              "can't specify a capability in a provides type")
          end
        end
      | NdInfixType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | TkPipe =>
            _diag(file, element, at, width, out, _invalid_provides())
            return
          | NdNominal | NdGroupedType | NdInfixType =>
            _provides_type(file, tree, child, at, width, out)
          | TkIsecttype => None
          | TkWhitespace | TkLineComment | TkNestedComment =>
            // The tree is lossless, so trivia are children here too.
            None
          else
            _diag(file, element, at, width, out, _invalid_provides())
            return
          end
        end
      | NdGroupedType =>
        for child in tree.children(element)? do
          match tree.kind(child)?
          | NdNominal | NdInfixType | NdGroupedType =>
            _provides_type(file, tree, child, at, width, out)
          end
        end
      else
        _diag(file, element, at, width, out, _invalid_provides())
      end
    end

  fun _invalid_provides(): String val =>
    "invalid provides type. Can only be interfaces, traits and intersects " +
      "of those."

  fun _object_fields(
    file: String val,
    tree: SyntaxTree val,
    obj: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(obj)? do
        if tree.kind(child)? is NdMembers then
          for member in tree.children(child)? do
            if tree.kind(member)? is NdField then
              var initialised = false
              for part in tree.children(member)? do
                if tree.kind(part)? is TkAssign then
                  initialised = true
                end
              end
              if not initialised then
                _diag(file, member, at, width, out,
                  "object literal fields must be initialized")
              end
            end
          end
        end
      end
    end

  fun _id_is(
    file: String val,
    tree: SyntaxTree val,
    parent: USize,
    what: String val,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref)
  =>
    try
      for child in tree.children(parent)? do
        if tree.kind(child)? is TkId then
          if (recover val tree.text(child)? end) == "_" then
            _diag(file, child, at, width, out,
              what + " name cannot be \"_\"")
          end
          return
        end
      end
    end

  fun _diag(
    file: String val,
    element: USize,
    at: Array[USize] box,
    width: Array[USize] box,
    out: Array[CheckDiag] ref,
    message: String val)
  =>
    let a = try at(element)? else 0 end
    let w = try width(element)? else 0 end
    out.push(CheckDiag(file, a, w, message))

primitive _EntityDesc
  fun apply(ent: USize): String val =>
    match ent
    | 0 => "actor"
    | 1 => "class"
    | 2 => "struct"
    | 3 => "primitive"
    | 4 => "trait"
    | 5 => "interface"
    else
      "type alias"
    end

primitive _EntityPerm
  """
  ponyc's `_entity_def` table: whether each entity kind may be Main, have
  fields, take a default capability, or take a C api annotation.
  """
  fun main(ent: USize): U8 => _perm(ent, 0)
  fun field(ent: USize): U8 => _perm(ent, 1)
  fun cap(ent: USize): U8 => _perm(ent, 2)
  fun c_api(ent: USize): U8 => _perm(ent, 3)

  fun _perm(ent: USize, element: USize): U8 =>
    let row =
      match ent
      | 0 => "XXNX" // actor
      | 1 => "NXXN" // class
      | 2 => "NXXN" // struct
      | 3 => "NNNN" // primitive
      | 4 => "NNXN" // trait
      | 5 => "NNXN" // interface
      else
        "NNNN"      // type alias
      end
    try row(element)? else 'X' end

primitive _MethodDesc
  fun apply(mkind: USize, ent: USize): String val =>
    _EntityDesc(ent) + " " +
      (match mkind
      | 0 => "function"
      | 1 => "behaviour"
      else
        "constructor"
      end)

primitive _MethodPerm
  """
  ponyc's `_method_def` table, by method kind and entity kind: the five
  elements are receiver capability, bareness, return type, `?`, and body;
  `None` is a row ponyc disallows outright.
  """
  fun apply(mkind: USize, ent: USize): (String val | None) =>
    match mkind
    | 0 => // function
      match ent
      | 4 | 5 => "XXXXX" // trait, interface: body optional
      | 6 => None        // type alias
      else
        "XXXXY"
      end
    | 1 => // behaviour
      match ent
      | 0 => "NNNNY"     // actor
      | 4 | 5 => "NNNNX" // trait, interface
      else
        None
      end
    else // constructor
      match ent
      | 0 => "NNNNY"     // actor
      | 1 | 2 => "XNNXY" // class, struct
      | 3 => "NNNXY"     // primitive
      | 4 | 5 => "XNNXN" // trait, interface
      else
        None
      end
    end
