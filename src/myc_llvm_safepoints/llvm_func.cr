class Myc::Backend::Llvm::Func < Myc::Backend::AbstractFunc
  def initialize(builder, func_def, header_mod)
    previous_def
    # Frame pointer and the statepoint GC strategy stay on every function
    # while safepoints are on. Limiting them to collecting functions made
    # Brainfuck::Array and Brainfuck::Recursion slower.
    if builder.gc_safepoints
      @link.llvm_function.add_target_dependent_attribute("frame-pointer", "all")
      @link.llvm_function.gc = "statepoint-example"
    end
  end
end
