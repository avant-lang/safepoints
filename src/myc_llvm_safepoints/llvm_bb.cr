class Myc::Backend::Llvm::BB < Myc::Backend::AbstractBB
  @gc_stackmap_lives = [] of Value
  @gc_tagged_leaves = Set(String).new

  def alloca(name : String, type : Type) : Value
    slot = previous_def
    if gc_slot_is_volatile?(type)
      inst = @llvm_builder.store(llvm_type(type).null, llvm_val(slot))
      inst.volatile = true
    end
    slot
  end

  def load_ref(value : Value) : Value
    # g_avant_shared is stored by another thread when it registers.
    # A plain load is lifted out of a loop, and the loop then keeps a
    # raw buffer after a moving collection. A volatile load stays put.
    if shared_flag?(value)
      return wrap_val(@llvm_builder.load_volatile(llvm_type(value), llvm_val(value)), value.type, value.pp)
    end
    if gc_slot_is_volatile?(value.type)
      wrap_val(@llvm_builder.load_volatile(llvm_type(value), llvm_val(value)), value.type, value.pp)
    else
      previous_def
    end
  end

  def call(name : String, type_fn : Type::Fn, args : Array(Value)) : Value?
    # Collector II Wave 1: the barrier's common case (a young or
    # already-remembered heap target) is a flag test on the header.
    # Emit it inline and keep the call for everything else.
    # MYC_GC_INLINE_BARRIER=0 restores the call for A/B measurement.
    if name == "avant_barrier" && builder.gc_safepoints &&
       ENV["MYC_GC_INLINE_BARRIER"]? != "0" && args.size == 1
      gc_barrier_inline(name, type_fn, args[0])
      return nil
    end
    # Collector II Wave 1: a nursery allocation whose fast conditions
    # the runtime published (avant_gc_fast_ok) is a bump, a header
    # store, a payload memset, a start bit, and three counter adds in
    # generated code. The slow block is the ordinary call, statepoint
    # wrapped exactly as below. MYC_GC_INLINE_ALLOC=0 restores the
    # call for A/B measurement.
    if (name == "avant_alloc" || name == "avant_bump_alloc") && builder.gc_safepoints &&
       ENV["MYC_GC_INLINE_ALLOC"]? != "0" && args.size == 2 && !type_fn.ret.needs_blit?
      lives = take_gc_stackmap_lives
      if v = gc_alloc_inline(name, type_fn, args, lives)
        return v
      end
      @gc_stackmap_lives = lives
    end
    tag_gc_leaf(name, type_fn)
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
    result = previous_def
    emit_gc_reg_clobber(name)
    result
  end

  def gc_set_stackmap_lives(lives : Array(Value))
    @gc_stackmap_lives = lives
  end

  private def gc_extern(name : String, type : LLVM::Type, tls : Bool) : LLVM::Value
    mod = builder.llvm_mod
    if g = mod.globals[name]?
      return g
    end
    g = mod.globals.add(type, name)
    g.thread_local = true if tls
    g
  end

  private def gc_add_total(b : LLVM::Builder, ptr : LLVM::Value, delta : LLVM::Value)
    ctx = builder.context
    old = b.load(ctx.int64, ptr)
    b.store(b.add(old, delta), ptr)
  end

  # Returns the phi Value for the allocation, or nil before emitting
  # anything when the inline form does not apply. Header layout and
  # flag values are the ABI documented in avant_rt.h.
  private def gc_alloc_inline(name : String, type_fn : Type::Fn, args : Array(Value), lives : Array(Value)) : Value?
    ctx = builder.context
    pair = llvm_intrinsic("llvm.memset", [ctx.pointer, ctx.int64])
    return nil unless pair
    ms_fn, ms_ty = pair
    fn = @func.as(Myc::Backend::Llvm::Func).link.llvm_function
    fast_bb = fn.basic_blocks.append "alloc_fast"
    slow_bb = fn.basic_blocks.append "alloc_slow"
    cont_bb = fn.basic_blocks.append "alloc_cont"
    b = @llvm_builder
    size_ll = llvm_val(args[0])
    type_ll = llvm_val(args[1])
    total = b.and(b.add(size_ll, ctx.int64.const_int(15)), ctx.int64.const_int(-8))
    shared = b.load(ctx.int32, gc_extern("g_avant_shared", ctx.int32, false))
    c_shared = b.icmp(LLVM::IntPredicate::EQ, shared, ctx.int32.const_int(0))
    fast_ok = b.load(ctx.int32, gc_extern("avant_gc_fast_ok", ctx.int32, true))
    c_ok = b.icmp(LLVM::IntPredicate::EQ, fast_ok, ctx.int32.const_int(1))
    bump_g = gc_extern("avant_gc_bump", ctx.pointer, true)
    bump = b.load(ctx.pointer, bump_g)
    limit = b.load(ctx.pointer, gc_extern("avant_gc_limit", ctx.pointer, true))
    new_bump = b.inbounds_gep(ctx.int8, bump, total)
    c_fit = b.and(
      b.icmp(LLVM::IntPredicate::NE, bump, ctx.pointer.null),
      b.icmp(LLVM::IntPredicate::ULE, new_bump, limit))
    c_small = b.icmp(LLVM::IntPredicate::ULE, total, ctx.int64.const_int(8192))
    big_scalar = b.and(
      b.icmp(LLVM::IntPredicate::EQ, type_ll, ctx.int32.const_int(0)),
      b.icmp(LLVM::IntPredicate::UGE, size_ll, ctx.int64.const_int(6144)))
    go = b.and(b.and(c_shared, c_ok), b.and(c_fit, b.and(c_small, b.not(big_scalar))))
    b.cond(go, fast_bb, slow_bb)

    b.position_at_end(fast_bb)
    b.store(new_bump, bump_g)
    block_ptr = b.load(ctx.pointer, gc_extern("avant_gc_block", ctx.pointer, true))
    b.store(new_bump, b.inbounds_gep(ctx.int8, block_ptr, ctx.int64.const_int(32)))
    flags_word = b.shl(ctx.int64.const_int(0x8020), ctx.int64.const_int(48))
    word = b.or(
      b.or(b.zext(b.trunc(size_ll, ctx.int32), ctx.int64),
        b.shl(b.zext(type_ll, ctx.int64), ctx.int64.const_int(32))),
      flags_word)
    b.store(word, bump)
    payload = b.inbounds_gep(ctx.int8, bump, ctx.int64.const_int(8))
    b.call(ms_ty, ms_fn, [payload, ctx.int8.const_int(0), size_ll, ctx.int1.const_int(0)])
    base = b.load(ctx.pointer, gc_extern("avant_gc_base", ctx.pointer, true))
    off = b.sub(b.ptr2int(bump, ctx.int64), b.ptr2int(base, ctx.int64))
    starts = b.load(ctx.pointer, gc_extern("avant_gc_starts", ctx.pointer, true))
    widx = b.lshr(off, ctx.int64.const_int(9))
    bit = b.shl(ctx.int64.const_int(1),
      b.and(b.lshr(off, ctx.int64.const_int(3)), ctx.int64.const_int(63)))
    wp = b.inbounds_gep(ctx.int64, starts, widx)
    b.store(b.or(b.load(ctx.int64, wp), bit), wp)
    stats = gc_extern("avant_g_stats", ctx.int64, false)
    gc_add_total(b, b.inbounds_gep(ctx.int8, stats, ctx.int64.const_int(24)), total)
    gc_add_total(b, gc_extern("avant_since_gc", ctx.int64, false), total)
    gc_add_total(b, gc_extern("avant_nursery_held", ctx.int64, false), total)
    gc_add_total(b, gc_extern("avant_inline_allocs", ctx.int64, false), ctx.int64.const_int(1))
    b.br(cont_bb)

    b.position_at_end(slow_bb)
    link = builder.func_link(name, type_fn)
    slow_result = nil.as(LLVM::Value?)
    unless lives.empty?
      target = LLVM::Value.new(link.llvm_function.to_unsafe)
      emitted, wrapped = emit_statepoint_call(target, link.llvm_type, type_fn, args, lives)
      if emitted && wrapped
        slow_result = llvm_val(wrapped.not_nil!)
      end
    end
    unless slow_result
      slow_result = b.call(link.llvm_type, link.llvm_function, [size_ll, type_ll])
    end
    emit_gc_reg_clobber(name)
    b.br(cont_bb)

    b.position_at_end(cont_bb)
    phi = b.phi(ctx.pointer, [fast_bb, slow_bb], [payload, slow_result.not_nil!])
    wrap_val(phi, type_fn.ret, Value::PP::CallResult.new(name))
  end

  # Flag layout is AvantHeader in avant_rt.h: HEAP 0x8000, YOUNG 32,
  # REM 16, flags at byte 6. Skip the call when the target is a heap
  # object that is young or already remembered; the runtime call
  # handles null, non-heap, and mature-unremembered targets.
  private def gc_barrier_inline(name : String, type_fn : Type::Fn, obj : Value)
    ctx = builder.context
    fn = @func.as(Myc::Backend::Llvm::Func).link.llvm_function
    call_bb = fn.basic_blocks.append "barrier_call"
    test_bb = fn.basic_blocks.append "barrier_test"
    cont_bb = fn.basic_blocks.append "barrier_cont"
    obj_ll = llvm_val(obj)
    is_null = @llvm_builder.icmp(LLVM::IntPredicate::EQ, obj_ll, ctx.pointer.null)
    @llvm_builder.cond(is_null, cont_bb, test_bb)
    @llvm_builder.position_at_end(test_bb)
    header = @llvm_builder.inbounds_gep(ctx.int8, obj_ll, ctx.int64.const_int(-8))
    flags_ptr = @llvm_builder.inbounds_gep(ctx.int8, header, ctx.int64.const_int(6))
    flags = @llvm_builder.load(ctx.int16, flags_ptr)
    heap = @llvm_builder.icmp(LLVM::IntPredicate::NE,
      @llvm_builder.and(flags, ctx.int16.const_int(0x8000)), ctx.int16.const_int(0))
    young_rem = @llvm_builder.icmp(LLVM::IntPredicate::NE,
      @llvm_builder.and(flags, ctx.int16.const_int(32 | 16)), ctx.int16.const_int(0))
    skip = @llvm_builder.and(heap, young_rem)
    @llvm_builder.cond(skip, cont_bb, call_bb)
    @llvm_builder.position_at_end(call_bb)
    link = builder.func_link(name, type_fn)
    @llvm_builder.call(link.llvm_type, link.llvm_function, [obj_ll])
    @llvm_builder.br(cont_bb)
    @llvm_builder.position_at_end(cont_bb)
  end

  # One avant_gc_root_begin call publishes the frame's whole slot list;
  # each slot address is then a plain store at its fixed index. The
  # runtime array is sized by that call, so no capacity check belongs
  # here. Emitted once per function at entry (from visitor finish) on a
  # dedicated builder placed right after the block's first instruction
  # (avant_gc_enter), so this block's own builder keeps its position
  # for the terminator Func#finish appends next.
  def gc_root_batch_at_entry(slots : Array(Value), begin_name : String, type_fn : Type::Fn)
    return unless builder.gc_safepoints
    return if slots.empty?
    link = builder.func_link(begin_name, type_fn)
    ctx = builder.context
    entry = ctx.new_builder
    first = LibLLVM.get_first_instruction(@llvm_bb.to_unsafe)
    return if first.null?
    nxt = LibLLVM.get_next_instruction(first)
    if nxt.null?
      entry.position_at_end(@llvm_bb)
    else
      LibLLVM.position_builder_before(entry.to_unsafe, nxt)
    end
    count = ctx.int32.const_int(slots.size)
    base = entry.call(link.llvm_type, link.llvm_function, [count])
    slots.each_with_index do |slot, i|
      dest = entry.inbounds_gep(ctx.pointer, base, ctx.int32.const_int(i))
      entry.store(llvm_val(slot), dest)
    end
  end

  def gc_reload_root_slots(slots : Array(Value))
    # Removing this reload slowed Matmul, Brainfuck, GameOfLife, and the
    # templates. The volatile load/store stays; Collector II Wave 0
    # emits it inline instead of paying a noinline call per slot.
    # MYC_GC_INLINE_RELOAD=0 restores the call for A/B measurement.
    return unless builder.gc_safepoints
    return if slots.empty?
    if ENV["MYC_GC_INLINE_RELOAD"]? == "0"
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
      return
    end
    slots.each do |slot|
      next unless slot.type.is_a?(Type::PtrType)
      addr = llvm_val(slot)
      loaded = @llvm_builder.load_volatile(llvm_type(slot), addr)
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
    result = previous_def
    emit_gc_reg_clobber(nil)
    result
  end

  # kostya/myc#10: do not copy va_copy. previous_def is myc's store;
  # mark the LLVM store volatile when the slot is a GC pointer.
  def store(lhs : Value, rhs : Value)
    inst = previous_def
    if gc_slot_is_volatile?(lhs.type) && inst.is_a?(LLVM::Value)
      inst.volatile = true
    end
  end

  # The alloca block is the function entry. finish() appends its branch
  # after the visitor, so a root call appended here runs once. If that
  # block already has a terminator, appending would be dead; plant the
  # call before the branch instead.
  def gc_insert_before_terminator
    term = LibLLVM.get_basic_block_terminator(@llvm_bb.to_unsafe)
    return if term.null?
    LibLLVM.position_builder_before(@llvm_builder.to_unsafe, term)
  end



  # A --gc-leaf function cannot collect, so a pointer slot is not a
  # moving root while it runs. Volatile loads would keep the slot on
  # the hot path and block register promotion.
  private def gc_slot_is_volatile?(type : Type) : Bool
    # Dropping volatile slowed Sieve, the templates, the mazes, and the
    # interpreter. Non-leaf pointer slots stay volatile. g_avant_shared
    # is handled in load_ref.
    return false unless builder.gc_safepoints
    return false unless type.gc_pointer?
    !builder.gc_config.leaf?(func_def.name)
  end

  private def emit_gc_reg_clobber(name : String?) : Nil
    # Dropping this clobber slowed Matmul::T8, Matmul::T16, and
    # Brainfuck::Recursion. Callee-saved registers still need the barrier.
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

  private def shared_flag?(value : Value) : Bool
    case pp = value.pp
    when Value::PP::Global
      pp.name == "g_avant_shared"
    else
      false
    end
  end

  # nounwind and willreturn let LLVM move a leaf call. nosync does not
  # apply to malloc or to a hook that takes a lock, so libc leaves are
  # left alone. avant_barrier and avant_pin can lock; they stay nosync-free.
  private def tag_gc_leaf(name : String, type_fn : Type::Fn) : Nil
    return unless builder.gc_safepoints
    return unless gc_callee_is_leaf?(name)
    return if Myc::Backend::GcConfig.libc_leaves.includes?(name)
    return if @gc_tagged_leaves.includes?(name)
    @gc_tagged_leaves << name
    fn = builder.func_link(name, type_fn).llvm_function
    fn.add_attribute LLVM::Attribute::NoUnwind
    fn.add_attribute LLVM::Attribute::WillReturn
    return if name.includes?("barrier") || name.includes?("pin") || name.includes?("alloc")
    fn.add_attribute LLVM::Attribute::NoSync
  end

  private def gc_callee_is_leaf?(name : String) : Bool
    return true if builder.gc_config.leaf?(name)
    if f = func_def.mod.func_defs[name]?
      return true if f.leaf?
    end
    false
  end
end
