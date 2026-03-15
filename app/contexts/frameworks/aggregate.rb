# frozen_string_literal: true

# Event-sourced aggregate for a career framework.
#
# One RES stream per framework: tenant-{tenant_id}/Framework-{framework_id}.
# Command methods validate invariants and apply events.
# Event handler methods (on blocks) update internal state.
#
class Frameworks::Aggregate
  include AggregateRoot

  def initialize
    @name = nil
    @status = :new
    @role_families = {}
    @capabilities = {}
    @expectations = {}
    @illustrations = {}
    @bindings = {}
    @collaborators = {}
    @pending_edits = {}
    @current_version = 0
    @draft_in_progress = false
  end

  # Creates a new framework.
  #
  # @param framework_id [String] UUID for the framework
  # @param name [String] display name
  # @raise [RuntimeError] if the framework has already been created
  def create(framework_id, name)
    raise "Framework already created" unless @status == :new

    apply(Frameworks::Events::FrameworkCreated.new(data: {
      framework_id: framework_id,
      name: name
    }))
  end

  on Frameworks::Events::FrameworkCreated do |event|
    @name = event.data[:name]
    @status = :created
  end
end
