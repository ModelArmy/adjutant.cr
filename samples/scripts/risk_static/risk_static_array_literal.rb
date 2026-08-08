require "sample"

def build_targets
  [delete_file(), fetch_url()]
end

build_targets()
