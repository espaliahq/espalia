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
  class << self
    # @param klass [Class<Operations::Base>]
    def register(klass)
      return if klass.name.nil? # anonymous test subclasses
      return if all.include?(klass)

      all << klass
    end

    # @return [Array<Class<Operations::Base>>] every registered concrete operation,
    #   alphabetised by class name for stable tool ordering.
    def all
      @all ||= []
      ensure_loaded
      @all
    end

    private

    # In production Rails eager-loads everything at boot, so every
    # `Operations::Base` subclass has already run `inherited` by the time
    # the MCP server takes a request. In development and (non-CI) test
    # eager_load is off — so on the first registry read we eager-load the
    # subtree under `app/operations/operations/` via Zeitwerk so the list
    # is exhaustive.
    def ensure_loaded
      return if @loaded

      Rails.autoloaders.main.eager_load_dir(
        Rails.root.join("app/operations/operations").to_s
      )
      @loaded = true
    end

    public

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
  end
end
