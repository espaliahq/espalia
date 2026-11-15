# frozen_string_literal: true

# Who supplies the facts a change moves: the place someone goes to make it
# happen ([#287](https://github.com/espaliahq/espalia/issues/287)). A person
# fact comes from its {OrgFactProvider}. A membership the Org Graph holds comes
# from whoever supplied it, as Espalia can hold one in a unit an HRIS mirrors.
# A unit, a succession and a planned placement come from the providers of the
# units they touch, since a unit mirrored from an HRIS takes its members from
# the sync. A unit only the plan holds is Espalia's.
#
# @example
#   sources = TeamPlanning::SourceOfTruth.new(tenant_id:)
#   sources.of_drift(change) # => ["hibob"]
class TeamPlanning::SourceOfTruth
  ESPALIA = OrgGraph::StructureAggregate::ESPALIA
  # The person fact each planned facet moves.
  FACT_OF_FACET = { "level" => "level", "reporting_line" => "manager", "departure" => "employment_status" }.freeze
  MEMBERSHIP_KINDS = %i[membership_started membership_ended membership_changed moved].freeze

  # @param tenant_id [String]
  def initialize(tenant_id:)
    @tenant_id = tenant_id
    @units = {}
    @successions = {}
  end

  # Reads the units and successions a list of changes touches in one query
  # each, rather than one per change.
  #
  # @param unit_ids [Array<String, nil>]
  # @param succession_ids [Array<String, nil>]
  # @return [self]
  def preload(unit_ids: [], succession_ids: [])
    succession_ids = succession_ids.compact.uniq - @successions.keys
    if succession_ids.any?
      rows = OrgUnitSuccession.where(tenant_id: @tenant_id, succession_id: succession_ids)
                              .pluck(:succession_id, :predecessor_id, :successor_id)
      succession_ids.each { |id| @successions[id] = rows.select { it.first == id }.flat_map { it.drop(1) } }
    end
    load_units(unit_ids + @successions.values_at(*succession_ids).flatten)
    self
  end

  # @param id [String]
  # @return [String, nil] the unit's name, once loaded
  def unit_name(id) = @units[id]&.first

  # @param change [OrgGraph::ChangesBetween::Change]
  # @return [Array<String>] sorted providers
  def of_drift(change)
    case change.kind
    when :joined, :left then of_fact("employment_status")
    when :fact_changed then of_fact(change.fact)
    when *MEMBERSHIP_KINDS then [ change.provider ]
    when :unit_succeeded then of_units(succession_units(change.succession_id))
    else of_units([ change.unit_id, change.from_unit_id ])
    end
  end

  # @param facet [String]
  # @param unit_ids [Array<String>] the units a planned change touches, for a
  #   facet no person fact supplies
  # @return [Array<String>] sorted providers
  def of_plan(facet, unit_ids: [])
    fact = FACT_OF_FACET[facet]
    fact ? of_fact(fact) : of_units(unit_ids)
  end

  # @param fact [String] one of {OrgGraph::StructureAggregate::FACTS}
  # @return [Array<String>]
  def of_fact(fact) = [ fact_providers.fetch(fact, ESPALIA) ]

  # @param ids [Array<String, nil>]
  # @return [Array<String>]
  def of_units(ids)
    ids = ids.compact.uniq
    load_units(ids)
    providers = ids.map { @units[it]&.last || ESPALIA }.uniq.sort
    providers.empty? ? [ ESPALIA ] : providers
  end

  private

  def fact_providers = @fact_providers ||= OrgFactProvider.where(tenant_id: @tenant_id).pluck(:fact, :provider).to_h

  def load_units(ids)
    ids = ids.compact.uniq - @units.keys
    return if ids.empty?

    found = OrgUnit.where(tenant_id: @tenant_id, id: ids).pluck(:id, :name, :provider).to_h { |id, *rest| [ id, rest ] }
    ids.each { @units[it] = found[it] }
  end

  def succession_units(succession_id)
    preload(succession_ids: [ succession_id ])
    @successions[succession_id]
  end
end
