require "../spec_helper"

# Keeps skills/adjutant/SKILL.md in step with the runtime it describes.
# The skill names every Legate verb and no verb that does not exist, and
# every U-code in UNSUPPORTED.md is either covered by a phrase the skill
# must keep or listed as deliberately left out. A new verb or U-code
# therefore fails here until someone decides what the skill says about it.
module Adjutant
  SKILL_TEXT       = File.read(File.join(__DIR__, "../../skills/adjutant/SKILL.md"))
  UNSUPPORTED_TEXT = File.read(File.join(__DIR__, "../../UNSUPPORTED.md"))

  # The phrase in SKILL.md that redirects each covered construct.
  SKILL_COVERED_U_CODES = {
    "U001" => "&blk",
    "U005" => "send(:name)",
    "U006" => "`eval`",
    "U008" => "`private`",
    "U009" => "Struct.new",
    "U011" => "$global",
    "U012" => "Name block parameters explicitly",
    "U013" => "def sq(x) = x * x",
    "U014" => "class << self",
    "U017" => "def ==(o)",
    "U019" => "proc { }",
    "U020" => "retry",
    "U021" => "The outside world is reached only through `Legate`",
  }

  # U-codes the skill leaves to their diagnostics, with the reason.
  SKILL_OMITTED_U_CODES = {
    "U002" => "Class.new and Module.new are rare in scripts; the diagnostic names the fix",
    "U003" => "reopening a class is rare in scripts; the diagnostic names the fix",
    "U004" => "a def inside a def is rare in scripts; the diagnostic names the fix",
    "U007" => "reflection on internals is rare in scripts; the diagnostic names the fix",
    "U010" => "retired, not an exclusion",
    "U015" => "undef and method hooks are rare in scripts; the diagnostic names the fix",
    "U016" => "begin...end while is rare in scripts; the diagnostic names the fix",
    "U018" => "extend or include on a receiver is rare in scripts; the diagnostic names the fix",
  }

  private def self.skill_legate_verb_names : Array(String)
    interp, _ = make_interp
    legate = interp.get_global("Legate").as_rclass
    legate.native_singleton_methods.keys.map { |id| interp.symbols.name_for(id).not_nil! }.sort
  end

  describe "skills/adjutant/SKILL.md" do
    it "names every Legate verb" do
      missing = skill_legate_verb_names.reject do |verb|
        SKILL_TEXT.matches?(/Legate\.#{Regex.escape(verb)}(?![\w!?])/)
      end
      missing.should eq [] of String
    end

    it "names no Legate verb that does not exist" do
      named = SKILL_TEXT.scan(/Legate\.([a-z_]+[!?]?)/).map(&.[1]).uniq
      (named - skill_legate_verb_names).should eq [] of String
    end

    it "accounts for every U-code in UNSUPPORTED.md" do
      codes = UNSUPPORTED_TEXT.lines.compact_map { |line| line.match(/\A### (U\d{3}) — /).try(&.[1]) }
      accounted = SKILL_COVERED_U_CODES.keys + SKILL_OMITTED_U_CODES.keys
      accounted.sort.should eq codes.sort
    end

    it "keeps the redirect for every U-code it covers" do
      missing = SKILL_COVERED_U_CODES.reject { |_, phrase| SKILL_TEXT.includes?(phrase) }
      missing.keys.should eq [] of String
    end
  end
end
