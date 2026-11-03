abstract class Myc::Backend::AbstractBB
  def gc_root_batch(slots : Array(Value), begin_name : String, type_fn : Type::Fn)
  end

  def gc_reload_root_slots(slots : Array(Value))
  end

  def gc_set_stackmap_lives(lives : Array(Value))
  end
end
