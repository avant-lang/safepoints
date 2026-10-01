require "./spec_helper"

# Kostya (kostya/myc#9): "so no optimizations at all, if you use this?"
# The closed PR forced optnone + default<O0> + CodeGenOptLevel::None whenever
# a root hook was present. This shard must keep myc's default / --debug /
# --final selection.

private OPT_IR = <<-MYC
FUNC :gc_root
  ARGS
    TYPE :ptr<void>
ENDFUNC

FUNC :collect
  ARGS
    TYPE :ptr<void>
ENDFUNC

FUNC :main
  BODY
    PUSH 8
    MALLOC :i8
    AS :ptr<void>
    CALL :collect
ENDFUNC
MYC

private def dump_ll(options = {} of String => String) : String
  path = Myc::Backend::AbstractBackend.new_tmp_path("optsp", "myc")
  File.write(path, OPT_IR)
  data = Myc::Cli::Data.new
  data.mode = :dump
  data.values << path
  options.each { |k, v| data.options[k] = v }
  backend = Myc::Backend::Llvm::Backend.new(data)
  begin
    backend.spec_dump_text
  ensure
    data.clean_temp_files
    File.delete(path) if File.exists?(path)
  end
end

describe "GC safepoints honor myc opt levels" do
  it "default with gc_root does not set optnone" do
    ll = dump_ll
    ll.should contain("llvm.experimental.gc.statepoint")
    ll.should_not contain("optnone")
    ll.should contain("statepoint-example")
  end

  it "--final with gc_root does not set optnone" do
    ll = dump_ll({"final" => ""})
    ll.should contain("llvm.experimental.gc.statepoint")
    ll.should_not contain("optnone")
  end

  it "--debug with gc_root may stay O0 but still emits statepoints" do
    ll = dump_ll({"debug" => ""})
    ll.should contain("llvm.experimental.gc.statepoint")
  end

  it "--no-gc-safepoints --final has no statepoint and no optnone" do
    ll = dump_ll({"no-gc-safepoints" => "", "final" => ""})
    ll.should_not contain("llvm.experimental.gc.statepoint")
    ll.should_not contain("optnone")
  end
end
