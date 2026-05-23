# frozen_string_literal: true

# Tracks every concrete subclass of {Operations::Base} so the MCP server
# can derive its tool list at runtime without explicit wiring. Subclasses
# self-register via `Operations::Base.inherited`; the registry is the
# single source of truth consumed by {Mcp::ToolRegistry}.
#
# Anonymous subclasses (used pervasively in tests) are filtered out so
# `Class.new(Operations::Base) { ... }` doesn't pollute the production
# tool surface.
class Operations::Registry
  # Guards the lazy eager-load in `ensure_loaded`. Puma serves dev requests
  # on multiple threads, so two concurrent registry reads could otherwise
  # both pass the `@loaded` check and re-trigger `eager_load_dir`. The
  # work itself is idempotent in Zeitwerk, but doing it once is cleaner
  # and the mutex eliminates a needless race on the `@loaded` flag.
  @load_mutex = Mutex.new

  class << self
    # @param klass [Class<Operations::Base>]
    def register(klass)
      return if klass.name.nil? # anonymous test subclasses
      return if raw_list.include?(klass)

      raw_list << klass
    end

    # @return [Array<Class<Operations::Base>>] every registered concrete operation.
    def all
      ensure_loaded
      raw_list
    end

    # Stable, snake_case identifier used as the MCP tool name.
    # e.g. `Operations::System::Whoami` → `"system_whoami"`.
    #
    # @param klass [Class<Operations::Base>]
    # @return [String]
    def tool_name_for(klass)
      klass.name
        .delete_prefix("Operations::")
        .gsub("::", "_")
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
    end

    # @param tool_name [String]
    # @return [Class<Operations::Base>, nil]
    def find_by_tool_name(tool_name)
      all.find { |klass| tool_name_for(klass) == tool_name }
    end

    # Test seam — wipe between test runs that load throwaway subclasses.
    def reset!
      @all = []
    end

    private

    # Direct accessor for the in-memory list. Used by `register` so the
    # `inherited` callback (which fires DURING `eager_load_dir`) doesn't
    # re-enter `ensure_loaded` and deadlock the load mutex.
    def raw_list
      @all ||= []
    end

    # In production Rails eager-loads everything at boot, so every
    # `Operations::Base` subclass has already run `inherited` by the time
    # the MCP server takes a request. In development and (non-CI) test
    # eager_load is off — so on the first registry read we eager-load the
    # subtree under `app/operations/operations/` via Zeitwerk so the list
    # is exhaustive.
    def ensure_loaded
      return if @loaded

      @load_mutex.synchronize do
        return if @loaded

        Rails.autoloaders.main.eager_load_dir(
          Rails.root.join("app/operations/operations").to_s
        )
        @loaded = true
      end
    end
  end
end
