class Myc::Backend::Llvm::Func < Myc::Backend::AbstractFunc
  def initialize(@builder, @func_def, @header_mod)
    @link = builder.func_link(func_def.name, func_def.type_fn)
    func_def.attrs.each do |attr|
      case attr
      when Mod::FuncDef::Attr::Noinline
        @link.llvm_function.add_attribute LLVM::Attribute::NoInline
      when Mod::FuncDef::Attr::Private
        @link.llvm_function.linkage = LLVM::Linkage::Private
      end
    end
    unless builder.backend.common_options.final
      @link.llvm_function.add_attribute LLVM::Attribute::NoInline
    end
    if builder.gc_safepoints
      @link.llvm_function.add_target_dependent_attribute("frame-pointer", "all")
      @link.llvm_function.gc = "statepoint-example"
    end
    @link.llvm_function.add_attribute LLVM::Attribute::NoUnwind
    super
  end
end
