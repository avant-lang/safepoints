# kostya/myc#10: do not copy AbstractVisitor#initialize. Class-body
# ivars are initialized before myc's initialize, so myc can add fields
# without this shard going stale.
abstract class Myc::Backend::AbstractVisitor
  @gc_spill = {} of String => Value
  @gc_root_slots = [] of Value
  @gc_seen_locals = Set(String).new

  def visit(op : Opcode::Call)
    # This frame is --gc-leaf. It does not collect, and its callees do
    # not. Rooting each pointer result planted avant_gc_root here for
    # pointers that cannot move. A frame that is not a leaf still roots
    # below.
    if gc_safepoints? && builder.gc_config.leaf?(func_def.name)
      # runtime_leaves do not allocate. They are not --gc-leaf: a
      # non-leaf caller still statepoints them. A leaf frame does not.
      if gc_call_may_collect?(op.name) && !Myc::Backend::GcConfig.runtime_leaves.includes?(op.name)
        raise error("gc safepoint: --gc-leaf #{func_def.name} calls #{op.name}, which can collect")
      end
      previous_def
      return
    end
    type_fn = find_func_type_fn(op.name)
    gc_safepoint_before_call(op.name)
    if gc_safepoints? && gc_call_may_collect?(op.name)
      @bb.gc_set_stackmap_lives(gc_collect_stackmap_lives)
    end
    previous_def
    if type_fn && !type_fn.ret.eq?(@mod.typer.void)
      @stack[@stack.size - 1] = gc_root_call_result(@stack.last)
    else
      gc_safepoint_after_void(op.name)
    end
    gc_safepoint_reload_after(op.name)
  end

  def visit(op : Opcode::Invoke)
    target = invoke_leaf_target
    if gc_safepoints? && builder.gc_config.leaf?(func_def.name) && target.nil?
      raise error("gc safepoint: --gc-leaf #{func_def.name} uses an indirect call, which can collect")
    end
    gc_safepoint_before_call(target)
    if gc_safepoints? && (target.nil? || gc_call_may_collect?(target))
      @bb.gc_set_stackmap_lives(gc_collect_stackmap_lives)
    end
    ret_void = true
    unless @stack.empty?
      case fn_ty = @stack.last.type
      when Type::Fn
        ret_void = fn_ty.ret.eq?(@mod.typer.void)
      end
    end
    previous_def
    unless ret_void
      if target.nil? || gc_call_may_collect?(target)
        @stack[@stack.size - 1] = gc_root_call_result(@stack.last)
      end
    end
    gc_safepoint_reload_after(target)
  end

  # The function pointer is the last value pushed. A direct address of a
  # --gc-leaf function does not collect. A local or an unknown pointer does.
  private def invoke_leaf_target : String?
    return nil if @stack.empty?
    case pp = @stack.last.pp
    when Value::PP::FnAddress
      pp.name if builder.gc_config.leaf?(pp.name)
    else
      nil
    end
  end

  private def gc_safepoints?
    builder.gc_safepoints
  end

  private def gc_call_may_collect?(name : String) : Bool
    return false if builder.gc_config.leaf?(name)
    if f = (@mod.func_defs[name]? || @header_mod.func_defs[name]?)
      return false if f.leaf?
    end
    true
  end

  private def gc_safepoint_before_call(name : String?)
    return unless gc_safepoints?
    leave = builder.gc_config.leave
    if name && !leave.empty? && name == leave
      gc_keep_roots_live
      return
    end
    return if name && !gc_call_may_collect?(name)
    gc_register_pointer_locals
    @stack.size.times do |i|
      @stack[i] = gc_safepoint_materialize_at(i, @stack[i])
    end
  end

  private def gc_safepoint_after_void(name : String)
    return unless gc_safepoints?
    enter = builder.gc_config.enter
    return if enter.empty? || name != enter
    if res = @func.result
      register_pointer_slots(res) if res.type.gc_pointer?
    end
  end

  private def gc_collect_stackmap_lives : Array(Value)
    # Spill slots exist only to hold a stack temporary across a call.
    # Once nothing on the stack, in a local, or in a parameter still
    # names that slot, it is dead. Aggregate field roots are not spills,
    # so they stay.
    spills = Set(UInt64).new
    @gc_spill.each_value { |slot| spills << slot.object_id }
    active = Set(UInt64).new
    @locals.each_value { |v| active << v.object_id }
    @params.each { |v| active << v.object_id }
    @stack.each { |v| active << v.object_id }
    lives = [] of Value
    @gc_root_slots.each do |slot|
      next unless slot.type.is_a?(Type::PtrType)
      if spills.includes?(slot.object_id) && !active.includes?(slot.object_id)
        next
      end
      lives << slot
    end
    lives
  end

  private def gc_register_pointer_locals
    @locals.each do |lname, local|
      next if @gc_seen_locals.includes?(lname)
      next unless local.type.gc_pointer?
      next if local.pp.is_a?(Value::PP::LocalUninitialized)
      @gc_seen_locals << lname
      register_pointer_slots(local)
    end
  end

  private def gc_safepoint_reload_after(name : String?)
    return unless gc_safepoints?
    return if name && !gc_call_may_collect?(name)
    gc_register_pointer_locals
    @bb.gc_reload_root_slots(@gc_root_slots)
  end

  private def gc_root_call_result(v : Value) : Value
    return v unless gc_safepoints?
    return v unless v.type.gc_pointer?
    loaded = v.to_rhs(self)
    slot = gc_spill_slot(@stack.size, v.type)
    unless slot.type.eq?(loaded.type)
      if cast = @bb.to?(loaded, loaded.type, slot.type)
        loaded = cast
      else
        raise error("gc safepoint: cannot store #{loaded.type} into #{slot.type}")
      end
    end
    slot.store(self, loaded)
    gc_ensure_rooted(slot)
    slot
  end

  private def gc_keep_roots_live
    @gc_root_slots.each do |slot|
      slot.to_rhs(self)
    end
    @locals.each_value do |local|
      next unless local.type.gc_pointer?
      next if local.pp.is_a?(Value::PP::LocalUninitialized)
      local.to_rhs(self)
    end
  end

  private def gc_safepoint_materialize_at(i : Int32, v : Value) : Value
    return v unless v.type.gc_pointer?
    loaded = v.to_rhs(self)
    slot = gc_spill_slot(i, v.type)
    unless slot.type.eq?(loaded.type)
      if cast = @bb.to?(loaded, loaded.type, slot.type)
        loaded = cast
      else
        raise error("gc safepoint: cannot store #{loaded.type} into #{slot.type}")
      end
    end
    slot.store(self, loaded)
    gc_ensure_rooted(slot)
    slot
  end

  private def gc_spill_slot(i : Int32, type : Type) : Value
    key = "#{i}:#{type}"
    if existing = @gc_spill[key]?
      return existing
    end
    slot = @func.alloca_bb.alloca(next_unique("gc_spill"), type)
    slot.pp = Value::PP::Local.new("gc_spill")
    @gc_spill[key] = slot
    slot
  end

  private def gc_ensure_rooted(slot : Value)
    return if @gc_root_slots.includes?(slot)
    register_pointer_slots(slot)
  end

  private def register_pointer_slots(ref : Value)
    saved = @bb
    @bb = @func.alloca_bb
    ptrs = [] of Value
    collect_pointer_slots_in_entry(ref, ptrs)
    # The slot address is computed in the alloca block. The call itself
    # has to run after avant_gc_enter, which is the first body instruction.
    # The first safepoint is often the loop, and that block is where the
    # call used to be planted. The body block is usually already branched
    # into the loop, so the call goes in before that branch.
    body = @func.body_bb
    @bb = body
    if body.is_a?(Myc::Backend::Llvm::BB)
      body.gc_insert_before_terminator
    end
    ptrs.each { |slot| register_one_gc_root(slot) }
    @bb = saved
  end

  private def collect_pointer_slots_in_entry(ref : Value, ptrs : Array(Value))
    case t = ref.type
    when Type::PtrType
      ptrs << ref
    when Type::StructType
      t.data.each_with_index do |ft, i|
        next unless ft.gc_pointer?
        collect_pointer_slots_in_entry(ref.field(self, i), ptrs)
      end
    end
  end

  private def register_one_gc_root(slot : Value)
    root = builder.gc_config.root
    type_fn = find_func_type_fn(root)
    return unless type_fn
    addr = slot.addr(self)
    cast = if addr.type.eq?(mod.typer.voidp)
             addr
           elsif (c = @bb.to?(addr, addr.type, mod.typer.voidp))
             c
           else
             raise error("gc safepoint: cannot pass #{addr.type} to #{root}")
           end
    @bb.call(root, type_fn, [cast])
    @gc_root_slots << slot
  end
end
