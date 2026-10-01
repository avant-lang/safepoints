class Myc::Backend::Llvm::BB < Myc::Backend::AbstractBB
  def initialize(@name, @builder, @func, @func_def)
    super

    @llvm_bb = @func.as(Func).link.llvm_function.basic_blocks.append @name
    @llvm_builder = @builder.as(Builder).context.new_builder
    @llvm_builder.position_at_end(@llvm_bb)
    @gc_stackmap_lives = [] of Value
  end

  def alloca(name : String, type : Type) : Value
    ltype = type.is_a?(Type::VaListType) ? builder.valist_llvm_type : llvm_type(type)
    raw = @llvm_builder.alloca(ltype, name)
    slot = wrap_ref(raw, type, Value::PP::LocalUninitialized.new(name))
    if builder.gc_safepoints && type.gc_pointer?
      inst = @llvm_builder.store(ltype.null, raw)
      inst.volatile = true
    end
    slot
  end

  def load_ref(value : Value) : Value
    if value.type.is_a?(Type::VaListType)
      value
    else
      llvm = if builder.gc_safepoints && value.type.gc_pointer?
               @llvm_builder.load_volatile(llvm_type(value), llvm_val(value))
             else
               @llvm_builder.load(llvm_type(value), llvm_val(value))
             end
      wrap_val(llvm, value.type, value.pp)
    end
  end

  def call(name : String, type_fn : Type::Fn, args : Array(Value)) : Value?
    lives = take_gc_stackmap_lives
    if !lives.empty?
      link = builder.func_link(name, type_fn)
      target = LLVM::Value.new(link.llvm_function.to_unsafe)
      emitted, wrapped = emit_statepoint_call(target, link.llvm_type, type_fn, args, lives)
      if emitted
        emit_gc_reg_clobber(name)
        return wrapped
      end
    end
    link = builder.func_link(name, type_fn)
    vals = args.map { |arg| llvm_val(arg) }
    val = @llvm_builder.call(link.llvm_type, link.llvm_function, vals)
    emit_gc_reg_clobber(name)
    unless type_fn.ret.eq?(func_def.mod.typer.void)
      wrap_val(val, type_fn.ret, Value::PP::CallResult.new(name))
    end
  end

  def gc_set_stackmap_lives(lives : Array(Value))
    @gc_stackmap_lives = lives
  end

  def gc_reload_root_slots(slots : Array(Value))
    return unless builder.gc_safepoints
    return if slots.empty?
    reload = builder.gc_config.reload
    return if reload.empty?
    voidp = func_def.mod.typer.voidp
    type_fn = Type::Fn.new(Location.new("", 0), [voidp], voidp)
    link = builder.func_link(reload, type_fn)
    link.llvm_function.add_attribute LLVM::Attribute::NoInline
    slots.each do |slot|
      next unless slot.type.is_a?(Type::PtrType)
      addr = llvm_val(slot)
      loaded = @llvm_builder.call(link.llvm_type, link.llvm_function, [addr])
      inst = @llvm_builder.store(loaded, addr)
      inst.volatile = true
    end
  end

  def invoke(fn : Value, type_fn : Type::Fn, args : Array(Value)) : Value?
    lives = take_gc_stackmap_lives
    if !lives.empty?
      emitted, wrapped = emit_statepoint_call(llvm_val(fn), fn_signature(type_fn), type_fn, args, lives)
      if emitted
        emit_gc_reg_clobber(nil)
        return wrapped
      end
    end
    vals = args.map { |arg| llvm_val(arg) }
    llvm_function = LLVM::Function.new(llvm_val(fn).to_unsafe)
    val = @llvm_builder.call(fn_signature(type_fn), llvm_function, vals)
    emit_gc_reg_clobber(nil)

    unless type_fn.ret.eq?(func_def.mod.typer.void)
      wrap_val(val, type_fn.ret, Value::PP::CallResult.new("invoke"))
    end
  end

  def store(lhs : Value, rhs : Value)
    if lhs.type.is_a?(Type::VaListType)
      lhs = wrap_val(llvm_val(lhs), lhs.type.to_unsafe_ptr, lhs.pp)
      rhs = wrap_val(llvm_val(rhs), rhs.type.to_unsafe_ptr, rhs.pp)
      intrinsic_call("llvm.va_copy.p0", typer.void, [lhs, rhs])
    else
      inst = @llvm_builder.store(llvm_val(rhs), llvm_val(lhs))
      if builder.gc_safepoints && lhs.type.gc_pointer?
        inst.volatile = true
      end
    end
  end

  private def emit_gc_reg_clobber(name : String?) : Nil
    return unless builder.gc_safepoints
    return if name && gc_callee_is_leaf?(name)
    return unless builder.layout.target.triple.includes?("x86_64")
    ctx = builder.context
    fty = LLVM::Type.function([] of LLVM::Type, ctx.void)
    constraints = "~{rax},~{rbx},~{rcx},~{rdx},~{rsi},~{rdi},~{r8},~{r9},~{r10},~{r11},~{r12},~{r13},~{r14},~{r15},~{memory}"
    asm_val = fty.inline_asm("", constraints, true, false, false)
    LibLLVM.build_call2(@llvm_builder.to_unsafe, fty.to_unsafe, asm_val.to_unsafe, Pointer(LibLLVM::ValueRef).null, 0, "".to_unsafe)
  end

  private def take_gc_stackmap_lives : Array(Value)
    lives = @gc_stackmap_lives
    @gc_stackmap_lives = [] of Value
    lives
  end

  private def emit_statepoint_call(callee : LLVM::Value, callee_fty : LLVM::Type, type_fn : Type::Fn, args : Array(Value), lives : Array(Value)) : {Bool, Value?}
    return {false, nil} if type_fn.ret.needs_blit?
    ctx = builder.context
    as1 = ctx.pointer(1)
    slots = [] of Value
    live_as1 = [] of LLVM::Value
    seen = Set(UInt64).new
    lives.each do |slot|
      next unless slot.type.is_a?(Type::PtrType)
      next unless slot.mm.ref?
      key = llvm_val(slot).to_unsafe.address
      next if seen.includes?(key)
      seen << key
      loaded = @llvm_builder.load_volatile(llvm_type(slot), llvm_val(slot))
      slots << slot
      live_as1 << @llvm_builder.addrspace_cast(loaded, as1)
    end
    return {false, nil} if live_as1.empty?

    pair = llvm_intrinsic("llvm.experimental.gc.statepoint", [ctx.pointer])
    return {false, nil} unless pair
    sp_fn, sp_ty = pair

    sp_args = [
      ctx.int64.const_int(0),
      ctx.int32.const_int(0),
      callee,
      ctx.int32.const_int(args.size),
      ctx.int32.const_int(0),
    ] of LLVM::Value
    args.each { |a| sp_args << llvm_val(a) }
    sp_args << ctx.int32.const_int(0)
    sp_args << ctx.int32.const_int(0)

    bundle = @llvm_builder.build_operand_bundle_def("gc-live", live_as1)
    tok = @llvm_builder.call(sp_ty, sp_fn, sp_args, "gcsp", bundle)
    bundle.dispose

    et_kind = LibLLVM.get_enum_attribute_kind_for_name("elementtype", "elementtype".bytesize)
    if et_kind != 0
      et = LibLLVM.create_type_attribute(ctx.to_unsafe, et_kind, callee_fty.to_unsafe)
      LibLLVM.add_call_site_attribute(tok.to_unsafe, 3, et)
    end

    result = nil.as(Value?)
    unless type_fn.ret.eq?(func_def.mod.typer.void)
      ret_ll = llvm_type(type_fn.ret)
      res_pair = llvm_intrinsic("llvm.experimental.gc.result", [ret_ll])
      return {false, nil} unless res_pair
      res_fn, res_ty = res_pair
      raw = @llvm_builder.call(res_ty, res_fn, [tok])
      result = wrap_val(raw, type_fn.ret, Value::PP::CallResult.new("gc.result"))
    end

    rel_pair = llvm_intrinsic("llvm.experimental.gc.relocate", [as1])
    return {false, nil} unless rel_pair
    rel_fn, rel_ty = rel_pair
    slots.each_with_index do |slot, i|
      idx = ctx.int32.const_int(i)
      relocated = @llvm_builder.call(rel_ty, rel_fn, [tok, idx, idx])
      as0 = @llvm_builder.addrspace_cast(relocated, ctx.pointer)
      inst = @llvm_builder.store(as0, llvm_val(slot))
      inst.volatile = true
    end
    {true, result}
  end

  private def llvm_intrinsic(name : String, overload : Array(LLVM::Type)) : {LLVM::Function, LLVM::Type}?
    id = LibLLVM.lookup_intrinsic_id(name, name.bytesize)
    return nil if id == 0
    refs = overload.map(&.to_unsafe)
    fnv = LibLLVM.get_intrinsic_declaration(
      builder.llvm_mod.to_unsafe, id,
      refs.to_unsafe.as(LibLLVM::TypeRef*), refs.size
    )
    fty = LibLLVM.intrinsic_get_type(
      builder.context.to_unsafe, id,
      refs.to_unsafe.as(LibLLVM::TypeRef*), refs.size
    )
    {LLVM::Function.new(fnv), LLVM::Type.new(fty)}
  end

  private def gc_callee_is_leaf?(name : String) : Bool
    return true if builder.gc_config.leaf?(name)
    if f = func_def.mod.func_defs[name]?
      return true if f.leaf?
    end
    false
  end

  private def builder
    @builder.as(Builder)
  end

  private def llvm_val(value : Value) : LLVM::Value
    value.bbval.as(BBVal).llvm
  end

  private def llvm_type(value : Value) : LLVM::Type
    llvm_type(value.type)
  end

  private def llvm_type(t : Type) : LLVM::Type
    builder.llvm_type(t)
  end

  private def wrap_val(llvm : LLVM::Value, type : Type, pp : Value::PP) : Value
    Value.new(BBVal.new(llvm), type, Value::MM::Val, pp)
  end

  private def wrap_ref(llvm : LLVM::Value, type : Type, pp : Value::PP) : Value
    Value.new(BBVal.new(llvm), type, Value::MM::Ref, pp)
  end

  private def typer : Typer
    @func_def.mod.typer
  end

  private def fn_signature(type_fn : Type::Fn) : LLVM::Type
    arg_types = type_fn.args.map { |t| llvm_type(t) }
    ret_type = llvm_type(type_fn.ret)
    LLVM::Type.function(arg_types, ret_type, type_fn.vaarg)
  end

  private def intrinsic_link(name : String, ret_type : Type, arg_types : Array(Type)) : FuncLink
    type_fn = Type::Fn.new(Location.new("", 0), arg_types, ret_type)
    builder.func_link(name, type_fn)
  end

  private def intrinsic_call(name : String, ret_type : Type, args : Array(Value)) : LLVM::Value
    arg_types = args.map { |a| a.type }
    link = intrinsic_link(name, ret_type, arg_types)
    @llvm_builder.call(link.llvm_type, link.llvm_function, args.map { |a| llvm_val(a) })
  end
end
