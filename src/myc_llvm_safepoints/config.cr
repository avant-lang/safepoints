# Pointer safepoints for a moving GC (LLVM backend). Frontends declare a
# root hook; myc-llvm spills live pointers around collecting CALL and
# wraps those calls as gc.statepoint so LLVM records stack-map slots.
class Myc::Backend::GcConfig
  property enabled : Bool = false
  property root : String = "gc_root"
  property reload : String = "gc_reload"
  property enter : String = ""
  property leave : String = ""
  property leaves : Set(String)

  def self.libc_leaves : Set(String)
    Set{"printf", "memset", "memcpy", "memmove", "malloc", "calloc", "free"}
  end

  def initialize
    @leaves = self.class.libc_leaves.dup
  end

  def leaf?(name : String) : Bool
    return true if @leaves.includes?(name)
    return true if name == @root || name == @reload
    return true if !@enter.empty? && name == @enter
    return true if !@leave.empty? && name == @leave
    false
  end
end
