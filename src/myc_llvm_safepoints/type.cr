abstract class Myc::Type
  # Heap pointers and aggregates that contain them. Spill these across
  # CALL so a moving GC can rewrite the slots. C pointers that are not
  # heap objects are still PtrType; the collector leaves non-heap words
  # unchanged.
  def gc_pointer? : Bool
    case self
    when Type::PtrType
      true
    when Type::StructType
      self.as(Type::StructType).data.any?(&.gc_pointer?)
    else
      false
    end
  end
end

class Myc::Mod::FuncDef
  # IR ATTR :leaf is a myc-core enum member this shard does not add.
  # Use --gc-leaf / MYC_GC_LEAF.
  def leaf?
    false
  end
end
