Write `config_value(name, fallback)`.

It returns the value of the environment variable `name`, or `fallback` when that variable is not set.

Only the variables the policy grants may be read; reading any other name stops the script.
