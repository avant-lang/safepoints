abstract class Myc::Backend::AbstractBuilder
  property gc_config : GcConfig = GcConfig.new

  def gc_safepoints : Bool
    gc_config.enabled
  end

  def gc_safepoints=(value : Bool)
    gc_config.enabled = value
  end
end
