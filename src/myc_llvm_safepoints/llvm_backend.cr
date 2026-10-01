class Myc::Backend::Llvm::Backend < Myc::Backend::AbstractBackend
  def new_builder : AbstractBuilder
    layout = Layout.new(common_options.target || Target.from_triple(LLVM.default_target_triple))
    opt = if common_options.final
            LLVM::CodeGenOptLevel::Aggressive
          elsif common_options.debug
            LLVM::CodeGenOptLevel::None
          else
            LLVM::CodeGenOptLevel::Default
          end
    Builder.new(self, layout, opt)
  end

  def build(mod : Mod, header_mod : Mod) : Builder
    cfg = gc_config_from_cli
    sp = gc_safepoints_for?(mod, header_mod, cfg)
    layout = Layout.new(common_options.target || Target.from_triple(LLVM.default_target_triple))
    opt = if common_options.final
            LLVM::CodeGenOptLevel::Aggressive
          elsif common_options.debug
            LLVM::CodeGenOptLevel::None
          else
            LLVM::CodeGenOptLevel::Default
          end
    b = Builder.new(self, layout, opt)
    b.disable_fast_isel! if sp
    cfg.enabled = sp
    b.gc_config = cfg
    build_mod(mod, header_mod, b).as(Builder).tap do |builder|
      builder.verify unless ENV["MYC_VERIFY"]? == "0"

      Myc.measure("backend:llvmopt") do
        mode = if common_options.final
                 data.options["llvm-bitcode-obj"]? ? "lto-pre-link<O3>" : "default<O3>"
               elsif common_options.debug
                 "default<O0>"
               else
                 "mem2reg,sccp,dce,simplifycfg"
               end
        builder.optimize!(mode)
      end
    end
  end
end
