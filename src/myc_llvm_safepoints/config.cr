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
  # FastISel is a target-machine switch, not a per-function one. It stays
  # off for the module when any function can collect. A module with no
  # statepoint keeps it.
  property fast_isel_off : Bool = false

  def self.libc_leaves : Set(String)
    Set{"printf", "memset", "memcpy", "memmove", "malloc", "calloc", "free"}
  end

  # Avant lowers these from fields. They do not allocate, so a quiet
  # leaf may call them even when the frontend forgot to name them.
  def self.runtime_leaves : Set(String)
    Set{
      "avant_str_size", "avant_str_byte", "avant_str_eq",
      "avant_str_to_f", "avant_str_to_i", "avant_str_to_f_slice",
      "avant_checksum_str", "avant_checksum_f64",
      "avant_buf_size", "avant_buf_starts",
      "avant_wide_op", "avant_wide_hi",
      "avant_now_ms", "avant_now_us",
      "avant_hash_size",
    }
  end

  def initialize
    @leaves = self.class.libc_leaves.dup
  end

  # True when this function's own body can reach a moving call.
  # A --gc-leaf frame cannot. An indirect call can.
  def function_collects?(func_def) : Bool
    return false if leaf?(func_def.name)
    hit = false
    func_def.deep_walk do |op|
      case op
      when Opcode::Call
        hit = true unless leaf?(op.name)
      when Opcode::Invoke
        hit = true
      end
    end
    hit
  end

  def leaf?(name : String) : Bool
    return true if @leaves.includes?(name)
    return true if name == @root || name == @reload
    return true if !@enter.empty? && name == @enter
    return true if !@leave.empty? && name == @leave
    false
  end
end
