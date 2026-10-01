class Myc::Backend::Llvm::Backend < Myc::Backend::AbstractBackend
  @pending_gc_config : GcConfig? = nil

  def new_builder : AbstractBuilder
    b = if common_options.debug && !common_options.final
          layout = Layout.new(common_options.target || Target.from_triple(LLVM.default_target_triple))
          Builder.new(self, layout, LLVM::CodeGenOptLevel::None)
        else
          previous_def.as(Builder)
        end
    if cfg = @pending_gc_config
      b.disable_fast_isel! if cfg.enabled
      b.gc_config = cfg
    end
    b
  end

  def build(mod : Mod, header_mod : Mod) : Builder
    cfg = gc_config_from_cli
    cfg.enabled = gc_safepoints_for?(mod, header_mod, cfg)
    @pending_gc_config = cfg
    previous_def
  ensure
    @pending_gc_config = nil
  end
end
