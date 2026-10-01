# kostya/myc#10: do not copy AbstractVisitor#initialize. Class-body
# ivars are initialized before myc's initialize, so myc can add fields
# without this shard going stale.
abstract class Myc::Backend::AbstractVisitor
  @gc_spill = {} of String => Value
  @gc_root_slots = [] of Value
  @gc_seen_locals = Set(String).new

  def visit(op : Opcode::Call)
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
    gc_safepoint_before_call(nil)
    if gc_safepoints?
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
      @stack[@stack.size - 1] = gc_root_call_result(@stack.last)
    end
    gc_safepoint_reload_after(nil)
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
    lives = [] of Value
    @gc_root_slots.each do |slot|
      next unless slot.type.is_a?(Type::PtrType)
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
    @bb = saved
    ptrs.each { |slot| register_one_gc_root(slot) }
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
