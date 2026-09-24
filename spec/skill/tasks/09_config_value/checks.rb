require "assert"

assert_equal("dev", config_value("ADJUTANT_EXAM_UNSET", "dev"))
assert("PATH comes back, not the fallback") { config_value("PATH", "missing") != "missing" }
