require "sample"

def build_config
  { action: delete_file(), url: fetch_url() }
end

build_config()
