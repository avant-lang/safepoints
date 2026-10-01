abstract class Myc::Backend::AbstractBackend
  protected def gc_safepoints_disabled? : Bool
    ENV["MYC_GC_SAFEPOINTS"]? == "0" || !!data.options["no-gc-safepoints"]?
  end

  protected def gc_config_from_cli : GcConfig
    cfg = GcConfig.new
    cfg.root = data.options["gc-root"]? || ENV["MYC_GC_ROOT"]? || "gc_root"
    cfg.reload = data.options["gc-reload"]? || ENV["MYC_GC_RELOAD"]? || "gc_reload"
    cfg.enter = data.options["gc-enter"]? || ENV["MYC_GC_ENTER"]? || ""
    cfg.leave = data.options["gc-leave"]? || ENV["MYC_GC_LEAVE"]? || ""
    extra = data.options["gc-leaf"]? || ENV["MYC_GC_LEAF"]?
    extra.try(&.split(',').each { |n|
      name = n.strip
      cfg.leaves << name unless name.empty?
    })
    cfg
  end

  protected def module_has_func?(mods : Array(Mod), header_mod : Mod, name : String) : Bool
    mods.any? { |m| m.func_defs.has_key?(name) } || header_mod.func_defs.has_key?(name)
  end

  protected def gc_safepoints_for?(mod : Mod, header_mod : Mod, cfg : GcConfig) : Bool
    return false if gc_safepoints_disabled?
    mod.func_defs.has_key?(cfg.root) || header_mod.func_defs.has_key?(cfg.root)
  end
end
