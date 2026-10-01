lib LibLLVM
  fun build_addr_space_cast = LLVMBuildAddrSpaceCast(BuilderRef, val : ValueRef, dest_ty : TypeRef, name : Char*) : ValueRef
  fun lookup_intrinsic_id = LLVMLookupIntrinsicID(name : Char*, name_len : SizeT) : UInt
  fun get_intrinsic_declaration = LLVMGetIntrinsicDeclaration(mod : ModuleRef, id : UInt, param_types : TypeRef*, param_count : SizeT) : ValueRef
  fun intrinsic_get_type = LLVMIntrinsicGetType(ctx : ContextRef, id : UInt, param_types : TypeRef*, param_count : SizeT) : TypeRef
  fun set_gc = LLVMSetGC(fn : ValueRef, name : Char*)
  fun set_target_machine_fast_isel = LLVMSetTargetMachineFastISel(t : TargetMachineRef, enable : Bool)
end

class LLVM::Builder
  def addrspace_cast(value : LLVM::Value, dest : LLVM::Type, name : String = "") : LLVM::Value
    LLVM::Value.new(LibLLVM.build_addr_space_cast(self.to_unsafe, value.to_unsafe, dest.to_unsafe, name.to_unsafe))
  end
end

struct LLVM::Function
  def gc=(name : String)
    LibLLVM.set_gc(self, name)
  end
end
