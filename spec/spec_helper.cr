require "spec"
require "myc"
require "../lib/myc/src/backend/llvm/all"
require "../src/myc_llvm_safepoints"

ENV["MYC_SPEC"] = "1"

class Myc::Backend::AbstractBackend
  def spec_dump_text : String
    input = data.values.first
    output = new_tmp_path("myc", "dump")
    mod, header = load_single(input)
    run_dump(mod, header, output)
    File.read(output)
  end

  def spec_write_obj(output : String)
    mod, header = load_single(data.values.first)
    run_obj(mod, header, output)
  end
end
