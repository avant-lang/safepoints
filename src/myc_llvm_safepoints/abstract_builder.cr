abstract class Myc::Backend::AbstractBuilder
  property gc_config : GcConfig

  def initialize(@backend, @layout)
    @gc_config = GcConfig.new
    @std_funcs = add_std_funcs
    @inspect_funcs = Hash(Type, String).new
    @inspect_type_fns = Hash(String, Mod::FuncDef).new
    @label_counter = 0_u64
  end

  def gc_safepoints : Bool
    gc_config.enabled
  end

  def gc_safepoints=(value : Bool)
    gc_config.enabled = value
  end
end
