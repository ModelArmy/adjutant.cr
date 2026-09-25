require "../fatal_signal"
require "../ruby_class"
require "../native_callable"
require "../risk_profile"
require "../builtins/helpers"
require "./helpers"

module Adjutant
  module Legate
    # Core's FatalSignal, under the name LEGATE.md §9.2 uses.
    alias FatalSignal = ::Adjutant::FatalSignal

    module Exceptions
      # Builds `Legate::Error < StandardError` and its recoverable
      # subclasses (LEGATE.md §9.1), nested in `legate`. The fatal tier
      # (Denied, Exhausted, Aborted) has no class: it is a FatalSignal,
      # never a script-visible object, and is reported only through
      # the host's diagnostics (§8.6).
      def self.bootstrap(interp : Interpreter, legate : RubyClass, standard_error : RubyClass) : Nil
        error = Helpers.nest(legate, interp, "Error", standard_error)
        # `EOF` is raised by a second terminal walk over a stream, or
        # over anything derived from it (§6.1).
        %w[NotFound Malformed TooLarge TooMany Timeout Transport Conflict EOF].each do |name|
          Helpers.nest(legate, interp, name, error)
        end

        bootstrap_redirect(interp, legate, error)
      end

      # `Legate::Redirect` (§4.5): a request with a body was
      # redirected, and the decision is handed back to the script. The
      # only Legate error with data: `status`, the Integer HTTP
      # status, and `location`, the target URL as a String, so a
      # script can branch without parsing the message.
      private def self.bootstrap_redirect(interp : Interpreter, legate : RubyClass,
                                          error : RubyClass) : Nil
        cls = Helpers.nest(legate, interp, "Redirect", error)
        status_sym = interp.symbols.intern("status").value
        location_sym = interp.symbols.intern("location").value

        # Nil when absent, as for a `raise Legate::Redirect, "..."`
        # that set no attributes.
        Builtins.define(cls, interp, "status") do |args|
          args.first.as_robject.ivars[status_sym]? || Value.nil_value
        end

        Builtins.define(cls, interp, "location") do |args|
          args.first.as_robject.ivars[location_sym]? || Value.nil_value
        end
      end
    end
  end
end
