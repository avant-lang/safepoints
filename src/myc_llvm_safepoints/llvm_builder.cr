class Myc::Backend::Llvm::Builder < Myc::Backend::AbstractBuilder
  def disable_fast_isel! : Nil
    LibLLVM.set_target_machine_fast_isel(target_machine, false)
  end

  def generate_obj(filename)
    previous_def
    mark_llvm_stackmaps_writable(filename) if gc_safepoints && File.exists?(filename)
  end

  # LLVM emits .llvm_stackmaps as SHF_ALLOC only. Function-address
  # relocs in that read-only section become DT_TEXTREL in a PIE.
  # SHF_WRITE makes them ordinary data relocs.
  private def mark_llvm_stackmaps_writable(filename : String) : Nil
    File.open(filename, "r+") do |f|
      ident = Bytes.new(16)
      return if f.read(ident) != 16
      return unless ident[0] == 0x7f && ident[1] == 'E'.ord && ident[2] == 'L'.ord && ident[3] == 'F'.ord
      return unless ident[4] == 2
      return unless ident[5] == 1

      f.seek(40)
      shoff = f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      f.seek(58)
      shentsize = f.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      shnum = f.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      shstrndx = f.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      return if shoff == 0 || shentsize != 64 || shnum == 0 || shstrndx >= shnum

      f.seek(shoff + shstrndx.to_u64 * 64)
      f.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      f.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      str_off = f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      str_size = f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      return if str_size == 0 || str_size > 1_048_576

      f.seek(str_off)
      names = Bytes.new(str_size)
      return if f.read(names) != str_size.to_i

      i = 0_u16
      while i < shnum
        f.seek(shoff + i.to_u64 * 64)
        name_off = f.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        f.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        flags_pos = f.pos
        flags = f.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        if elf_section_name?(names, name_off, ".llvm_stackmaps")
          unless flags.bits_set?(0x1_u64)
            f.seek(flags_pos)
            f.write_bytes(flags | 0x1_u64, IO::ByteFormat::LittleEndian)
          end
          return
        end
        i = i &+ 1
      end
    end
  rescue
  end

  private def elf_section_name?(names : Bytes, off : UInt32, want : String) : Bool
    start = off.to_i
    return false if start < 0 || start >= names.size
    bytes = want.to_slice
    return false if start + bytes.size >= names.size
    i = 0
    while i < bytes.size
      return false if names[start + i] != bytes[i]
      i += 1
    end
    names[start + bytes.size] == 0
  end
end
