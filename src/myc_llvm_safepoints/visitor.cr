abstract class Myc::Backend::AbstractVisitor
  def initialize(@builder, @func, @bb, @func_def, @mod, @header_mod, @params)
    @stack = Deque(Value).new
    @loop_finish_stack = Deque(AbstractBB).new
    @loop_step_stack = Deque(AbstractBB).new
    @locals = Hash(String, Value).new
    @current_op = @func_def.body.not_nil!
    @unique_id = 0_u64
    @was_ret = false
    @pending_labels = Hash(String, AbstractBB).new
    @labels = Hash(String, AbstractBB).new
    @fake_bb = func.new_raw_bb("__myc_fake_bb__")
    @slots = Deque(Hash(String, Value)).new
    @all_slots = Hash(String, Value).new
    @instruction_id = 0_u32
    @gc_spill = {} of String => Value
    @gc_root_slots = [] of Value
    @gc_seen_locals = Set(String).new
  end

  def visit(op : Opcode::Call)
    type_fn = find_func_type_fn(op.name)
    raise error("func #{op.name} not found") unless type_fn

    gc_safepoint_before_call(op.name)

    types = type_fn.args
    args = types.size.times.map do |index|
      arg = pop_rhs
      if arg.type.eq?(types[index])
        arg
      else
        if arg2 = @bb.to?(arg, arg.type, types[index])
          arg2
        else
          raise error("bad arg #{index} type, expected: #{types[index]}, got: #{arg.type}, type_fn: #{type_fn.id_name}")
        end
      end
    end.to_a

    if type_fn.vaarg
      op.vaargs_count.times do
        last_va_extend
        args << pop_rhs
      end
    else
      if op.vaargs_count > 0
        raise error("function #{op.name} have no vaargs, but passes #{op.vaargs_count}")
      end
    end
    if gc_safepoints? && gc_call_may_collect?(op.name)
      @bb.gc_set_stackmap_lives(gc_collect_stackmap_lives)
    end
    if value = @bb.call(op.name, type_fn, args)
      self << gc_root_call_result(value)
    else
      gc_safepoint_after_void(op.name)
    end
    gc_safepoint_reload_after(op.name)
  end

  def visit(op : Opcode::Invoke)
    gc_safepoint_before_call(nil)
    fn_ptr = pop_rhs

    case type_fn = fn_ptr.type
    when Type::Fn
    else
      raise error("INVOKE expected fn type, got #{type_fn}")
    end

    types = type_fn.args
    args = types.size.times.map do |index|
      arg = pop_rhs
      if arg.type.eq?(types[index])
        arg
      else
        if arg2 = @bb.to?(arg, arg.type, types[index])
          arg2
        else
          raise error("bad arg #{index} type, expected: #{types[index]}, got: #{arg.type}, type_fn: #{type_fn.id_name}")
        end
      end
    end.to_a

    if type_fn.vaarg
      op.vaargs_count.times do
        last_va_extend
        args << pop_rhs
      end
    else
      if op.vaargs_count > 0
        raise error("function pointer has no vaargs, but passes #{op.vaargs_count}")
      end
    end
    if gc_safepoints?
      @bb.gc_set_stackmap_lives(gc_collect_stackmap_lives)
    end

    case _pp = fn_ptr.pp
    when Value::PP::FnAddress
      if value = @bb.call(_pp.name, type_fn, args)
        self << gc_root_call_result(value)
      end
    else
      if value = @bb.invoke(fn_ptr, type_fn, args)
        self << gc_root_call_result(value)
      end
    end
    gc_safepoint_reload_after(nil)
  end

  private def <<(v : Value)
    @stack << v
  end

  private def pop : Value
    raise error("empty stack") if @stack.empty?
    @stack.pop
  end

  private def last : Value
    raise error("empty stack") if @stack.empty?
    @stack.last
  end

  private def pop_rhs : Value
    pop.to_rhs(self)
  end

  private def find_func_type_fn(name : String) : Type::Fn?
    @mod.func_defs[name]?.try(&.type_fn) ||
      @header_mod.func_defs[name]?.try(&.type_fn) ||
      @builder.std_funcs[name]? ||
      @builder.inspect_type_fns[name]?.try(&.type_fn)
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
