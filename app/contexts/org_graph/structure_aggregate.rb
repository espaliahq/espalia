# frozen_string_literal: true

# Event-sourced aggregate for a tenant's organisational structure.
#
# One RES stream per tenant: tenant-{tenant_id}/OrgStructure. It holds the
# taxonomy (the tenant's names for its levels) and every unit's life. A unit
# keeps its id through renames and moves; its name and parent each carry the
# date they took effect.
#
# Every unit names its provider. A unit only accepts a change from the
# provider that supplies it, so a unit mirrored from an HRIS rejects edits
# made in Espalia and changes when the sync says so.
#
# The stream also holds the tenant's provider settings: one provider per
# taxonomy level and one per kind of person fact, Espalia until another is
# set. A level's units come from its provider.
#
class OrgGraph::StructureAggregate
  include AggregateRoot
  prepend OrgGraph::PlanReference::Stamping

  ESPALIA = "espalia"
  PROVIDERS = OrgGraph::PersonAggregate::PROVIDERS
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # The kinds of person fact a provider supplies, one per family of person event.
  FACTS = %w[employment_status title level manager cost_centre site employment].freeze
  # The facts an HRIS supplies unless someone chose otherwise. The sync writes
  # these, and connecting an HRIS claims them for it.
  HRIS_FACTS = %w[employment_status title level manager site employment].freeze

  Unit = Struct.new(:unit_id, :name, :parent_id, :level_id, :provider, :external_ref, :retired, :owner_ids,
                    :created_on, :changed_on, keyword_init: true)

  def initialize
    @levels = []
    @units = {}
    @level_providers = {}
    @fact_providers = {}
    @successions = {}
  end

  # Defines or redefines the tenant's taxonomy, top level first.
  #
  # A level keeps its id through a rename. A level any unit has held, retired
  # ones included, can't be dropped, so a unit's history keeps its level. The
  # levels live units hold must keep their order, or a unit would sit above
  # its own parent.
  #
  # A new level can name its provider, so a level can be added above one an
  # HRIS provides. An existing level changes provider through
  # {#set_level_provider}.
  #
  # @param levels [Array<Hash>] each `{ level_id:, name: }`, top first, with an
  #   optional `provider:` for a new level
  # @param effective_on [Date, String] when the taxonomy took effect
  # @param defined_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the levels are empty, blank or duplicated
  # @raise [RuntimeError] if a level in use is dropped or reordered
  def define_taxonomy(levels, effective_on:, defined_by_id: nil)
    new_providers = new_level_providers(levels)
    levels = normalise_levels(levels)
    return if levels == @levels

    dropped = @units.values.map(&:level_id).uniq - level_ids(levels)
    raise "Can't drop a level that holds units: #{dropped.join(', ')}" if dropped.any?

    in_use = live_units.map(&:level_id).uniq

    kept_order = level_ids(@levels) & in_use
    raise "Levels in use must keep their order" unless level_ids(levels) & in_use == kept_order

    ensure_hris_levels_on_top!(level_ids(levels), new_providers)

    apply(OrgGraph::Events::TaxonomyDefined.new(data: {
      levels: levels,
      previous_levels: @levels,
      effective_on: iso_date(effective_on),
      defined_by_id: defined_by_id
    }))
    new_providers.each do |level_id, provider|
      apply(OrgGraph::Events::LevelProviderSet.new(data: {
        level_id: level_id,
        provider: provider,
        previous_provider: ESPALIA,
        effective_on: iso_date(effective_on),
        set_by_id: defined_by_id
      }))
    end
  end

  # Sets who supplies a taxonomy level's units. An unchanged provider writes
  # nothing.
  #
  # A level that still holds live units keeps its provider: switching it is a
  # handover, which compares the two first. Levels an HRIS provides sit above
  # every level Espalia holds.
  #
  # @param level_id [String] a level in the current taxonomy
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the provider is unknown
  # @raise [RuntimeError] if the level is unknown, holds live units, or would
  #   break the order of providers
  def set_level_provider(level_id, provider, effective_on:, set_by_id: nil)
    level_id = require_id(level_id, "Level id")
    provider = require_provider(provider)
    raise "Level is not in the taxonomy" unless level_index(level_id)

    previous = level_provider(level_id)
    return if provider == previous
    raise "Level still holds units from #{previous}; hand it over instead" if live_units.any? { |unit| unit.level_id == level_id }

    ensure_hris_levels_on_top!(level_ids(@levels), level_id => provider)

    apply(OrgGraph::Events::LevelProviderSet.new(data: {
      level_id: level_id,
      provider: provider,
      previous_provider: previous,
      effective_on: iso_date(effective_on),
      set_by_id: set_by_id
    }))
  end

  # Sets who supplies a kind of person fact. An unchanged provider writes
  # nothing, but the first choice is always written, Espalia included, so a
  # later {#claim_facts} knows someone chose.
  #
  # @param fact [String, Symbol] one of {FACTS}
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the fact or the provider is unknown
  def set_fact_provider(fact, provider, effective_on:, set_by_id: nil)
    fact = fact.to_s
    raise ArgumentError, "Unknown fact: #{fact}" unless FACTS.include?(fact)

    provider = require_provider(provider)
    return if @fact_providers[fact] == provider

    previous = @fact_providers.fetch(fact, ESPALIA)

    apply(OrgGraph::Events::FactProviderSet.new(data: {
      fact: fact,
      provider: provider,
      previous_provider: previous,
      effective_on: iso_date(effective_on),
      set_by_id: set_by_id
    }))
  end

  # Hands each fact nobody has chosen a provider for to this one. A fact whose
  # provider was ever set, to anyone, keeps it, so running this again only
  # reaches facts added to the list since.
  #
  # @param facts [Array<String, Symbol>] each one of {FACTS}
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @return [Array<String>] the facts it claimed
  def claim_facts(facts, provider, effective_on:, set_by_id: nil)
    unclaimed = facts.map(&:to_s).uniq.reject { |fact| @fact_providers.key?(fact) }
    unclaimed.each { |fact| set_fact_provider(fact, provider, effective_on:, set_by_id:) }
    unclaimed.select { |fact| @fact_providers[fact] == provider }
  end

  # Creates a unit.
  #
  # @param unit_id [String] UUID for the unit
  # @param name [String]
  # @param level_id [String] a level in the current taxonomy
  # @param parent_id [String, nil] a live unit at a higher level; nil at the top
  # @param provider [String] the level's provider: "espalia", or the HRIS that supplies the unit
  # @param external_ref [String, nil] the provider's own reference; required for
  #   a mirrored unit, absent for one Espalia holds
  # @param effective_on [Date, String]
  # @param created_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError, RuntimeError] if any invariant above fails
  def create_unit(unit_id, name, level_id:, effective_on:, parent_id: nil, provider: ESPALIA,
                  external_ref: nil, created_by_id: nil)
    unit_id = require_id(unit_id, "Unit id")
    level_id = require_id(level_id, "Level id")
    parent_id = require_id(parent_id, "Parent id") if parent_id
    raise "Unit already exists" if @units.key?(unit_id)

    name = require_name(name)
    provider = require_provider(provider)
    external_ref = external_ref.presence
    raise ArgumentError, "A mirrored unit needs the provider's reference" if provider != ESPALIA && external_ref.nil?
    raise ArgumentError, "A unit Espalia holds has no external reference" if provider == ESPALIA && external_ref
    raise "Level is not in the taxonomy" unless level_index(level_id)
    if external_ref && live_units.any? { |unit| unit.provider == provider && unit.external_ref == external_ref }
      raise "A live unit already mirrors #{provider} #{external_ref}"
    end

    raise "#{level_provider(level_id)} supplies this level's units" unless provider == level_provider(level_id)

    effective_on = iso_date(effective_on)
    ensure_placeable!(provider, level_id, parent_id, on: effective_on)

    apply(OrgGraph::Events::UnitCreated.new(data: {
      unit_id: unit_id,
      name: name,
      parent_id: parent_id,
      level_id: level_id,
      provider: provider,
      external_ref: external_ref,
      effective_on: effective_on,
      created_by_id: created_by_id
    }))
  end

  # Renames a unit. An unchanged name writes nothing.
  #
  # @param unit_id [String]
  # @param name [String]
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param renamed_by_id [String, nil]
  def rename_unit(unit_id, name, effective_on:, provider: ESPALIA, renamed_by_id: nil)
    unit = editable_unit!(unit_id, provider)
    unit_id = unit.unit_id
    name = require_name(name)
    return if name == unit.name

    effective_on = dated_after_creation(unit, effective_on)
    apply(OrgGraph::Events::UnitRenamed.new(data: {
      unit_id: unit_id,
      name: name,
      previous_name: unit.name,
      provider: unit.provider,
      effective_on: effective_on,
      renamed_by_id: renamed_by_id
    }))
  end

  # Moves a unit beneath another parent. An unchanged parent writes nothing.
  #
  # @param unit_id [String]
  # @param parent_id [String, nil] a live unit at a higher level; nil to move it
  #   to the top. The level rule also keeps a unit from moving beneath itself.
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param moved_by_id [String, nil]
  def move_unit(unit_id, parent_id, effective_on:, provider: ESPALIA, moved_by_id: nil)
    unit = editable_unit!(unit_id, provider)
    unit_id = unit.unit_id
    parent_id = require_id(parent_id, "Parent id") if parent_id
    return if parent_id == unit.parent_id

    effective_on = dated_after_creation(unit, effective_on)
    ensure_placeable!(unit.provider, unit.level_id, parent_id, on: effective_on)

    apply(OrgGraph::Events::UnitMoved.new(data: {
      unit_id: unit_id,
      parent_id: parent_id,
      previous_parent_id: unit.parent_id,
      provider: unit.provider,
      effective_on: effective_on,
      moved_by_id: moved_by_id
    }))
  end

  # Retires a unit. Its live sub-units must be moved or retired first.
  #
  # @param unit_id [String]
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param retired_by_id [String, nil]
  def retire_unit(unit_id, effective_on:, provider: ESPALIA, retired_by_id: nil)
    effective_on = iso_date(effective_on)
    unit = retirable_unit!(unit_id, provider, on: effective_on)

    apply(retirement(unit, effective_on:, retired_by_id:))
  end

  # States that the successors carry on from the predecessors: a split, a
  # merge or a replacement. Nothing else ever links two units.
  #
  # Restating a succession exactly writes nothing, apart from retiring any
  # predecessor still live when asked to. A unit can't come to precede
  # itself, so no chain of successions loops back.
  #
  # @param succession_id [String] UUID for the succession
  # @param predecessor_ids [Array<String>] units that came before, live or retired
  # @param successor_ids [Array<String>] live units that carry on from them
  # @param effective_on [Date, String]
  # @param retire_predecessors [Boolean] also retire each live predecessor,
  #   naming the succession, so its members move instead of leaving
  # @param provider [String] who supplies a retirement; must be each
  #   predecessor's own
  # @param stated_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError, RuntimeError] if a unit is missing or the link is impossible
  def record_succession(succession_id, predecessor_ids:, successor_ids:, effective_on:, retire_predecessors: false,
                        provider: ESPALIA, stated_by_id: nil)
    succession_id = require_id(succession_id, "Succession id")
    predecessor_ids = require_ids(predecessor_ids, "predecessor")
    successor_ids = require_ids(successor_ids, "successor")
    effective_on = iso_date(effective_on)
    succession = { predecessor_ids: predecessor_ids.sort, successor_ids: successor_ids.sort, effective_on: effective_on }
    restated = @successions[succession_id] == succession
    raise "Succession already exists" if @successions.key?(succession_id) && !restated

    unless restated
      raise ArgumentError, "A unit can't succeed itself" if predecessor_ids.intersect?(successor_ids)
      raise "Unit not found" unless (predecessor_ids + successor_ids).all? { |id| @units.key?(id) }
      raise "A unit can't come to precede itself" if preceded_by(predecessor_ids).intersect?(successor_ids)

      latest = (predecessor_ids + successor_ids).map { |id| @units[id] }.max_by(&:created_on)
      raise "A succession can't predate #{latest.name}, created on #{latest.created_on}" if effective_on < latest.created_on
    end

    retiring = retire_predecessors ? predecessor_ids.map { |id| @units[id] }.reject(&:retired) : []
    retiring = retiring.sort_by { |unit| -level_index(unit.level_id) }
    if (!restated || retiring.any?) && successor_ids.any? { |id| @units[id].retired }
      raise "A successor must be live"
    end
    retiring.each { |unit| retirable_unit!(unit.unit_id, provider, on: effective_on, retiring: retiring) }

    unless restated
      apply(OrgGraph::Events::UnitSucceeded.new(data: {
        succession_id: succession_id,
        **succession,
        stated_by_id: stated_by_id
      }))
    end
    retiring.each do |unit|
      apply(retirement(unit, effective_on:, retired_by_id: stated_by_id,
                             succession_id:, successor_ids: succession[:successor_ids]))
    end
  end

  # Names a person as one of a unit's owners. A unit can have several, none
  # primary. Ownership is Espalia's to state, so a unit an HRIS supplies takes
  # owners too. An existing owner writes nothing.
  #
  # @param unit_id [String] a live unit
  # @param person_id [String] UUID of the owner
  # @param effective_on [Date, String]
  # @param added_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if an id isn't a UUID or the date is invalid
  # @raise [RuntimeError] if the unit is unknown or retired
  def add_unit_owner(unit_id, person_id, effective_on:, added_by_id: nil)
    unit = live_unit!(unit_id)
    person_id = require_id(person_id, "Person id")
    return if unit.owner_ids.include?(person_id)

    apply(OrgGraph::Events::UnitOwnerAdded.new(data: {
      unit_id: unit.unit_id, person_id: person_id, effective_on: iso_date(effective_on),
      added_by_id: added_by_id
    }))
  end

  # Removes one of a unit's owners. A person who isn't one writes nothing.
  #
  # @param unit_id [String] a live unit
  # @param person_id [String]
  # @param effective_on [Date, String]
  # @param removed_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if an id isn't a UUID or the date is invalid
  # @raise [RuntimeError] if the unit is unknown or retired
  def remove_unit_owner(unit_id, person_id, effective_on:, removed_by_id: nil)
    unit = live_unit!(unit_id)
    person_id = require_id(person_id, "Person id")
    return unless unit.owner_ids.include?(person_id)

    apply(OrgGraph::Events::UnitOwnerRemoved.new(data: {
      unit_id: unit.unit_id, person_id: person_id, effective_on: iso_date(effective_on),
      removed_by_id: removed_by_id
    }))
  end

  on OrgGraph::Events::TaxonomyDefined do |event|
    @levels = event.data[:levels].map { |level| level.to_h.symbolize_keys.slice(:level_id, :name) }
    @level_providers = @level_providers.slice(*level_ids(@levels))
  end

  on OrgGraph::Events::LevelProviderSet do |event|
    @level_providers[event.data[:level_id]] = event.data[:provider]
  end

  on OrgGraph::Events::FactProviderSet do |event|
    @fact_providers[event.data[:fact]] = event.data[:provider]
  end

  on OrgGraph::Events::UnitCreated do |event|
    data = event.data
    @units[data[:unit_id]] = Unit.new(
      unit_id: data[:unit_id], name: data[:name], parent_id: data[:parent_id], level_id: data[:level_id],
      provider: data[:provider], external_ref: data[:external_ref], retired: false, owner_ids: Set.new,
      created_on: data[:effective_on], changed_on: data[:effective_on]
    )
    touch(data[:parent_id], data[:effective_on])
  end

  on OrgGraph::Events::UnitOwnerAdded do |event|
    @units.fetch(event.data[:unit_id]).owner_ids << event.data[:person_id]
  end

  on OrgGraph::Events::UnitOwnerRemoved do |event|
    @units.fetch(event.data[:unit_id]).owner_ids.delete(event.data[:person_id])
  end

  on OrgGraph::Events::UnitRenamed do |event|
    @units.fetch(event.data[:unit_id]).name = event.data[:name]
    touch(event.data[:unit_id], event.data[:effective_on])
  end

  on OrgGraph::Events::UnitMoved do |event|
    unit = @units.fetch(event.data[:unit_id])
    [ unit.unit_id, unit.parent_id, event.data[:parent_id] ].each { |id| touch(id, event.data[:effective_on]) }
    unit.parent_id = event.data[:parent_id]
  end

  on OrgGraph::Events::UnitRetired do |event|
    unit = @units.fetch(event.data[:unit_id])
    unit.retired = true
    touch(unit.parent_id, event.data[:effective_on])
  end

  on OrgGraph::Events::UnitSucceeded do |event|
    @successions[event.data[:succession_id]] = event.data.slice(:predecessor_ids, :successor_ids, :effective_on).symbolize_keys
  end

  private

  def live_unit!(unit_id)
    unit = @units[unit_id.to_s.downcase]
    raise "Unit not found" unless unit
    raise "Unit is retired" if unit.retired

    unit
  end

  def editable_unit!(unit_id, provider)
    unit = live_unit!(unit_id)
    raise "#{unit.provider} supplies this unit; change it there" unless require_provider(provider) == unit.provider

    unit
  end

  def level_provider(level_id)
    @level_providers.fetch(level_id, ESPALIA)
  end

  # A unit retiring with others may still hold sub-units among them; those
  # retire before it.
  def retirable_unit!(unit_id, provider, on:, retiring: [])
    unit = editable_unit!(unit_id, provider)
    raise "A unit can't retire before its last change on #{unit.changed_on}" if on < unit.changed_on
    others = retiring.map(&:unit_id) - [ unit.unit_id ]
    if live_units.any? { |child| child.parent_id == unit.unit_id && !others.include?(child.unit_id) }
      raise "Move or retire its sub-units first"
    end

    unit
  end

  def retirement(unit, effective_on:, retired_by_id:, succession_id: nil, successor_ids: nil)
    OrgGraph::Events::UnitRetired.new(data: {
      unit_id: unit.unit_id,
      provider: unit.provider,
      effective_on: effective_on,
      retired_by_id: retired_by_id,
      succession_id: succession_id,
      successor_ids: successor_ids
    })
  end

  # Every unit the given ones carry on from, however far back.
  def preceded_by(unit_ids)
    seen = Set.new
    pending = unit_ids.dup
    while (unit_id = pending.pop)
      @successions.each_value do |succession|
        next unless succession[:successor_ids].include?(unit_id)

        succession[:predecessor_ids].each { |id| pending << id if seen.add?(id) }
      end
    end
    seen
  end

  # Levels an HRIS provides sit above every level Espalia holds, so the levels
  # top first run from HRIS ones to Espalia's and never back.
  def ensure_hris_levels_on_top!(ids, changes = {})
    providers = ids.map { |id| changes.fetch(id) { level_provider(id) } }
    first_espalia = providers.index(ESPALIA) || providers.size
    return if providers.drop(first_espalia).all?(ESPALIA)

    raise "Levels an HRIS provides must sit above every level Espalia holds"
  end

  # A unit's latest change includes a sub-unit arriving beneath it or leaving,
  # so it can't be dated as retired while it still held one.
  def touch(unit_id, effective_on)
    unit = @units[unit_id]
    unit.changed_on = [ unit.changed_on, effective_on ].max if unit
  end

  def dated_after_creation(unit, effective_on)
    effective_on = iso_date(effective_on)
    raise "The unit was created on #{unit.created_on}" if effective_on < unit.created_on

    effective_on
  end

  # A parent must be live and at a higher level, and a mirrored unit never
  # hangs beneath one Espalia holds.
  def ensure_placeable!(provider, level_id, parent_id, on:)
    return if parent_id.nil?

    parent = @units[parent_id]
    raise "Parent unit not found" unless parent
    raise "Parent unit is retired" if parent.retired
    raise "The parent unit was created on #{parent.created_on}" if on < parent.created_on
    raise "A parent must sit at a higher level" unless level_index(parent.level_id) < level_index(level_id)
    raise "A mirrored unit can't sit beneath a unit Espalia holds" if provider != ESPALIA && parent.provider == ESPALIA
  end

  def live_units
    @units.values.reject(&:retired)
  end

  def level_index(level_id)
    level_ids(@levels).index(level_id)
  end

  def level_ids(levels)
    levels.map { |level| level[:level_id] }
  end

  # The providers named for levels the taxonomy doesn't hold yet, Espalia's left out.
  def new_level_providers(levels)
    Array(levels).each_with_object({}) do |level, providers|
      level = level.to_h.symbolize_keys
      next if level[:provider].nil?

      level_id = require_id(level[:level_id], "Level id")
      provider = require_provider(level[:provider])
      if level_index(level_id)
        raise "Change an existing level's provider with set_level_provider" unless provider == level_provider(level_id)
      elsif provider != ESPALIA
        providers[level_id] = provider
      end
    end
  end

  def normalise_levels(levels)
    levels = Array(levels).map do |level|
      level = level.to_h.symbolize_keys
      { level_id: require_id(level[:level_id], "Level id"), name: level[:name].to_s.strip }
    end
    raise ArgumentError, "A taxonomy needs at least one level" if levels.empty?
    raise ArgumentError, "Every level needs a name" if levels.any? { |level| level[:name].empty? }
    raise ArgumentError, "Level ids must be unique" unless level_ids(levels).uniq.size == levels.size
    raise ArgumentError, "Level names must be unique" unless levels.map { |level| level[:name].downcase }.uniq.size == levels.size

    levels
  end

  def require_id(id, label)
    raise ArgumentError, "#{label} must be a UUID" unless UUID.match?(id.to_s)

    id.to_s.downcase
  end

  def require_ids(ids, label)
    ids = Array(ids).map { |id| require_id(id, "A #{label} id") }.uniq
    raise ArgumentError, "A succession needs at least one #{label}" if ids.empty?

    ids
  end

  def require_name(name)
    name = name.to_s.strip
    raise ArgumentError, "Name can't be blank" if name.empty?

    name
  end

  def require_provider(provider)
    provider = provider.to_s
    raise ArgumentError, "Unknown provider: #{provider}" unless PROVIDERS.include?(provider)

    provider
  end

  def iso_date(value)
    raise ArgumentError, "Effective date is required" if value.blank?

    (value.is_a?(String) ? Date.iso8601(value) : value.to_date).iso8601
  rescue Date::Error, NoMethodError
    raise ArgumentError, "Invalid effective date: #{value.inspect}"
  end
end
