# frozen_string_literal: true

# Brings one person's Person Development stream into line with what their
# Org Graph stream holds today: the role and level their title and level
# map to, their reporting manager, and whether they still work here.
#
# It reads both streams and issues only the commands that close the gap, so
# running it twice does nothing the second time. With `apply: false` it
# reports the same changes without issuing them.
#
# Only HRIS-held people are fed: someone Espalia holds keeps the assignment
# people gave them. A forgotten person gets nothing. An unmapped title keeps
# the assignment they have. A manager is cleared only when the HRIS itself
# recorded that they have none.
#
# @example
#   OrgGraph::PersonDevelopmentFeed.new(tenant).reconcile(person_id) # => [:change_level]
class OrgGraph::PersonDevelopmentFeed
  # What {#reconcile} can do to a person, in the order it does them.
  KINDS = %i[withdraw unassign assign change_role change_level record_manager clear_manager].freeze

  # The reason a leaver's withdrawal and unassignment carry, as the sync's.
  OFFBOARD_REASON = "left_company"

  # @param tenant [Tenant]
  # @param apply [Boolean] issue the commands; false only reports them
  # @param org_graph [OrgGraph::Repository]
  # @param person_development [PersonDevelopment::CommandHandler]
  # @param cycles [AssessmentCycles::CommandHandler]
  def initialize(tenant, apply: true, org_graph: OrgGraph::Repository.new,
                 person_development: PersonDevelopment::CommandHandler.new,
                 cycles: AssessmentCycles::CommandHandler.new)
    @tenant = tenant
    @apply = apply
    @org_graph = org_graph
    @person_development = person_development
    @cycles = cycles
  end

  # @param person_id [String]
  # @return [Array<Symbol>] the changes made, or that would be made, from {KINDS}
  def reconcile(person_id)
    person = Person.hris_managed.find_by(id: person_id)
    return [] if person.nil? || framework.nil?

    stream = @org_graph.load_person(person_id)
    return [] unless stream.recorded?
    return [] if stream.forgotten?

    held = @person_development.load(person_id, framework_id)
    return offboard(person_id, held) if stream.left?

    placed = place(person_id, stream, held)
    placed + manager(person, stream, held, assigned: held.assigned? || placed.include?(:assign))
  end

  private

  def offboard(person_id, held)
    return [] unless held.assigned?

    changes = []
    if held.current_cycle_id
      issue { @cycles.unenroll(held.current_cycle_id, person_id, OFFBOARD_REASON) }
      changes << :withdraw
    end
    issue { @person_development.unassign_from_framework(person_id, framework_id, reason: OFFBOARD_REASON) }
    changes << :unassign
  end

  def place(person_id, stream, held)
    target = resolution.target(stream.fact(:title), Integer(stream.fact(:level), exception: false))
    return [] unless target.status == :resolved

    role_id = target.role.role_id
    level_id = target.level.level_id
    if !held.assigned?
      issue { @person_development.assign_to_framework(person_id, framework_id, role_id, level_id) }
      [ :assign ]
    elsif held.role_id != role_id
      issue { @person_development.change_person_role(person_id, framework_id, role_id, level_id) }
      [ :change_role ]
    elsif held.level_id != level_id
      issue { @person_development.change_person_level(person_id, framework_id, level_id) }
      [ :change_level ]
    else
      []
    end
  end

  # Runs after placement, so someone assigned just now gets their manager
  # in the same pass. A leaver keeps theirs on record.
  def manager(person, stream, held, assigned:)
    return [] unless assigned

    manager_id = stream.fact(:manager_id)
    if manager_id.present?
      return [] if manager_id == held.manager_id

      issue { @person_development.record_reporting_manager(person.id, framework_id, manager_id, source: "hris") }
      [ :record_manager ]
    elsif held.manager_id && hris_recorded_none?(person, stream)
      issue { @person_development.clear_reporting_manager(person.id, framework_id, source: "hris") }
      [ :clear_manager ]
    else
      []
    end
  end

  def hris_recorded_none?(person, stream)
    stream.fact_supplier(:manager_id) == person.hris_source
  end

  def issue
    yield if @apply
  end

  def resolution
    @resolution ||= Integrations::HrisTitleResolution.new(@tenant)
  end

  def framework = resolution.framework

  def framework_id = framework.framework_id
end
