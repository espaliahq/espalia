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
  # The parts of a fact an HRIS can be told to read from a field of the tenant's
  # choosing. The rest come from the fields each adapter reads by default.
  MAPPABLE_FIELDS = { "cost_centre" => %w[cost_centre], "site" => %w[country] }.freeze

  Unit = Struct.new(:unit_id, :name, :parent_id, :level_id, :provider, :external_ref, :retired, :owner_ids,
                    :created_on, :changed_on, keyword_init: true)

  def initialize
    @levels = []
    @units = {}
    @level_providers = {}
    @level_fields = {}
    @fact_providers = {}
    @fact_fields = {}
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
  # @raise [RuntimeError] if a level any unit has held is dropped, naming the
  #   units, or a level in use is reordered
  def define_taxonomy(levels, effective_on:, defined_by_id: nil)
    new_providers = new_level_providers(levels)
    levels = normalise_levels(levels)
    return if levels == @levels

    @levels.reject { |level| level_ids(levels).include?(level[:level_id]) }.each { ensure_never_held!(it) }

    in_use = live_units.map(&:level_id).uniq

    ensure_levels_in_use_keep_order!(levels, in_use)

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

  # Adds a level Espalia holds below every other level. Works from the levels
  # this stream holds, so a level added or moved meanwhile is kept.
  #
  # @param level_id [String] a new level's id
  # @param name [String]
  # @param effective_on [Date, String]
  # @param defined_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the id is taken or the name blank or taken
  def add_level(level_id, name, effective_on:, defined_by_id: nil)
    raise ArgumentError, "Level id is taken" if level_index(require_id(level_id, "Level id"))

    define_taxonomy([ *@levels, { level_id:, name: } ], effective_on:, defined_by_id:)
  end

  # Puts the levels this stream holds in a new order, keeping their names.
  #
  # @param level_ids [Array<String>] every level's id once, top first
  # @param effective_on [Date, String]
  # @param defined_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] unless the ids are exactly the current levels'
  # @raise [RuntimeError] if the order breaks one {#define_taxonomy} keeps
  def reorder_levels(level_ids, effective_on:, defined_by_id: nil)
    by_id = @levels.index_by { |level| level[:level_id] }
    ids = Array(level_ids).map { |id| id.to_s.downcase }
    unless ids.any? && ids.uniq.size == ids.size && ids.sort == by_id.keys.sort
      raise ArgumentError, "Name every level in the taxonomy once, top first"
    end

    define_taxonomy(ids.map { |id| by_id[id] }, effective_on:, defined_by_id:)
  end

  # Removes a level Espalia holds that no unit has ever held. A unit keeps its
  # level for life, so the units this stream holds, retired ones included, are
  # every unit a level has held.
  #
  # @param level_id [String] a level in the current taxonomy
  # @param effective_on [Date, String]
  # @param defined_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the level isn't in the taxonomy or is the last one
  # @raise [RuntimeError] if an HRIS provides the level or a unit has held it
  def remove_level(level_id, effective_on:, defined_by_id: nil)
    level_id = require_id(level_id, "Level id")
    level = @levels.find { |candidate| candidate[:level_id] == level_id }
    raise ArgumentError, "Level is not in the taxonomy" unless level
    unless level_provider(level_id) == ESPALIA
      raise "#{level[:name]} comes from #{level_provider(level_id)}; hand it back to Espalia before removing it"
    end

    define_taxonomy(@levels - [ level ], effective_on:, defined_by_id:)
  end

  # Sets who supplies a taxonomy level's units and, for an HRIS, the field
  # each person's unit at that level is read from. Moving the level to another
  # provider clears its field; restating the same provider with a new field
  # changes only the field. An unchanged setting writes nothing.
  #
  # A level that still holds live units keeps its provider: switching it is a
  # handover, which compares the two first. Levels an HRIS provides sit above
  # every level Espalia holds.
  #
  # @param level_id [String] a level in the current taxonomy
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param field [String, nil] the HRIS field id, such as
  #   "work.custom.department_x"; nil keeps the current one for the same provider
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the provider is unknown, or a field is named for Espalia
  # @raise [RuntimeError] if the level is unknown, holds live units while its
  #   provider or field changes, or would break the order of providers
  def set_level_provider(level_id, provider, effective_on:, field: nil, set_by_id: nil)
    level_id = require_id(level_id, "Level id")
    provider = require_provider(provider)
    field = require_level_field(provider, field)
    raise "Level is not in the taxonomy" unless level_index(level_id)

    previous = level_provider(level_id)
    if provider == previous
      return if field.nil? || field == @level_fields[level_id]

      raise "Level still holds units read from another field; hand it over instead" if live_units.any? { |unit| unit.level_id == level_id }
    else
      raise "Level still holds units from #{previous}; hand it over instead" if live_units.any? { |unit| unit.level_id == level_id }

      ensure_hris_levels_on_top!(level_ids(@levels), level_id => provider)
    end

    apply(OrgGraph::Events::LevelProviderSet.new(data: {
      level_id: level_id,
      provider: provider,
      previous_provider: previous,
      field: field,
      effective_on: iso_date(effective_on),
      set_by_id: set_by_id
    }))
  end

  # Hands a level Espalia holds to an HRIS field. Each of the level's live
  # units must be matched to the field's value it becomes; resolve the rest
  # first, with {#record_succession} or {#retire_unit}. Writes the level's new
  # provider and field, then hands over each matched unit.
  #
  # @param level_id [String] a level Espalia supplies
  # @param provider [String] the HRIS
  # @param field [String] the HRIS field id
  # @param matches [Hash{String => String}] unit_id => the external reference
  #   of the value it becomes, as the mirror would key it
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError, RuntimeError] if the level is not Espalia's, a live
  #   unit is unmatched, a match names another unit, or two units share a value
  def hand_over_level(level_id, provider, field:, matches:, effective_on:, set_by_id: nil)
    level_id = require_id(level_id, "Level id")
    provider = require_provider(provider)
    raise ArgumentError, "Hand a level to an HRIS, or hand it back" if provider == ESPALIA
    raise "Level is not in the taxonomy" unless level_index(level_id)
    raise "#{level_provider(level_id)} supplies this level, not Espalia" unless level_provider(level_id) == ESPALIA

    field = require_level_field(provider, field)
    raise ArgumentError, "A handover names the field" unless field

    matches = matches.to_h { |unit_id, ref| [ require_id(unit_id, "Unit id"), ref.to_s.strip ] }
    units = live_units.select { |unit| unit.level_id == level_id }
    unmatched = units.map(&:unit_id) - matches.keys
    raise "Match or resolve every unit first: #{unmatched.map { @units[it].name }.sort.join(', ')}" if unmatched.any?
    raise "Only the level's live units can be matched" unless (matches.keys - units.map(&:unit_id)).empty?
    raise ArgumentError, "Each match needs a reference" if matches.values.any?(&:empty?)
    raise "Two units can't become the same value" unless matches.values.uniq.size == matches.size

    effective_on = iso_date(effective_on)
    ensure_hris_levels_on_top!(level_ids(@levels), level_id => provider)
    apply(OrgGraph::Events::LevelProviderSet.new(data: {
      level_id:, provider:, previous_provider: ESPALIA, field:, effective_on:, set_by_id:
    }))
    units.sort_by(&:name).each do |unit|
      apply(handed_over(unit, provider, matches.fetch(unit.unit_id), effective_on, set_by_id, field:, previous_field: nil))
    end
  end

  # Hands a level an HRIS provides back to Espalia. Units and memberships stay
  # as they are; successions and retirements made by the handover stand.
  # The level's field and its units' references are cleared.
  #
  # @param level_id [String] a level an HRIS supplies
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [RuntimeError] if Espalia already holds the level, or a level below
  #   it is still the HRIS's
  def hand_back_level(level_id, effective_on:, set_by_id: nil)
    level_id = require_id(level_id, "Level id")
    raise "Level is not in the taxonomy" unless level_index(level_id)

    previous = level_provider(level_id)
    raise "Espalia already holds this level" if previous == ESPALIA

    previous_field = @level_fields[level_id]

    effective_on = iso_date(effective_on)
    ensure_hris_levels_on_top!(level_ids(@levels), level_id => ESPALIA)
    apply(OrgGraph::Events::LevelProviderSet.new(data: {
      level_id:, provider: ESPALIA, previous_provider: previous, field: nil, effective_on:, set_by_id:
    }))
    live_units.select { |unit| unit.level_id == level_id }.sort_by(&:name).each do |unit|
      apply(handed_over(unit, ESPALIA, nil, effective_on, set_by_id, field: nil, previous_field:))
    end
  end

  # Sets who supplies a kind of person fact and, for an HRIS, the fields it
  # reads the fact from. A field names its provider in the same event, so no
  # fact Espalia holds has one. Moving a fact to another provider clears its
  # fields; restating the same provider without `fields:` keeps them. An
  # unchanged setting writes nothing, but the first choice is always written,
  # Espalia included, so a later {#claim_facts} knows someone chose.
  #
  # @param fact [String, Symbol] one of {FACTS}
  # @param provider [String] one of {PROVIDERS}
  # @param effective_on [Date, String]
  # @param fields [Hash{String => String}, nil] the HRIS field path for each
  #   part of the fact named in {MAPPABLE_FIELDS}; nil keeps the current ones
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the fact, the provider or a field is unknown, or
  #   a field is named for Espalia
  def set_fact_provider(fact, provider, effective_on:, fields: nil, set_by_id: nil)
    fact = fact.to_s
    raise ArgumentError, "Unknown fact: #{fact}" unless FACTS.include?(fact)

    provider = require_provider(provider)
    unchanged = @fact_providers[fact] == provider
    current_fields = @fact_fields.fetch(fact, {})
    fields = fields.nil? && unchanged ? current_fields : require_fields(fact, provider, fields)
    return if unchanged && fields == current_fields

    previous = @fact_providers.fetch(fact, ESPALIA)

    apply(OrgGraph::Events::FactProviderSet.new(data: {
      fact: fact,
      provider: provider,
      previous_provider: previous,
      fields: fields,
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
  # @param changed_back_id [String, nil] the event this changes back
  def rename_unit(unit_id, name, effective_on:, provider: ESPALIA, renamed_by_id: nil, changed_back_id: nil)
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
      renamed_by_id: renamed_by_id,
      changed_back_id: changed_back_id
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
  # @param changed_back_id [String, nil] the event this changes back
  def move_unit(unit_id, parent_id, effective_on:, provider: ESPALIA, moved_by_id: nil, changed_back_id: nil)
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
      moved_by_id: moved_by_id,
      changed_back_id: changed_back_id
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
  # @param changed_back_id [String, nil] the event this changes back
  # @raise [ArgumentError] if an id isn't a UUID or the date is invalid
  # @raise [RuntimeError] if the unit is unknown or retired
  def add_unit_owner(unit_id, person_id, effective_on:, added_by_id: nil, changed_back_id: nil)
    unit = live_unit!(unit_id)
    person_id = require_id(person_id, "Person id")
    return if unit.owner_ids.include?(person_id)

    apply(OrgGraph::Events::UnitOwnerAdded.new(data: {
      unit_id: unit.unit_id, person_id: person_id, effective_on: iso_date(effective_on),
      added_by_id: added_by_id, changed_back_id: changed_back_id
    }))
  end

  # Removes one of a unit's owners. A person who isn't one writes nothing.
  #
  # @param unit_id [String] a live unit
  # @param person_id [String]
  # @param effective_on [Date, String]
  # @param removed_by_id [String, nil] person_id of the actor
  # @param changed_back_id [String, nil] the event this changes back
  # @raise [ArgumentError] if an id isn't a UUID or the date is invalid
  # @raise [RuntimeError] if the unit is unknown or retired
  def remove_unit_owner(unit_id, person_id, effective_on:, removed_by_id: nil, changed_back_id: nil)
    unit = live_unit!(unit_id)
    person_id = require_id(person_id, "Person id")
    return unless unit.owner_ids.include?(person_id)

    apply(OrgGraph::Events::UnitOwnerRemoved.new(data: {
      unit_id: unit.unit_id, person_id: person_id, effective_on: iso_date(effective_on),
      removed_by_id: removed_by_id, changed_back_id: changed_back_id
    }))
  end

  on OrgGraph::Events::TaxonomyDefined do |event|
    @levels = event.data[:levels].map { |level| level.to_h.symbolize_keys.slice(:level_id, :name) }
    @level_providers = @level_providers.slice(*level_ids(@levels))
    @level_fields = @level_fields.slice(*level_ids(@levels))
  end

  on OrgGraph::Events::LevelProviderSet do |event|
    @level_providers[event.data[:level_id]] = event.data[:provider]
    @level_fields[event.data[:level_id]] = event.data[:field]
  end

  on OrgGraph::Events::FactProviderSet do |event|
    @fact_providers[event.data[:fact]] = event.data[:provider]
    @fact_fields[event.data[:fact]] = (event.data[:fields] || {}).transform_keys(&:to_s)
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
    touch(event.data[:unit_id], event.data[:effective_on])
  end

  on OrgGraph::Events::UnitOwnerRemoved do |event|
    @units.fetch(event.data[:unit_id]).owner_ids.delete(event.data[:person_id])
    touch(event.data[:unit_id], event.data[:effective_on])
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

  on OrgGraph::Events::UnitHandedOver do |event|
    unit = @units.fetch(event.data[:unit_id])
    unit.provider = event.data[:provider]
    unit.external_ref = event.data[:external_ref]
    touch(unit.unit_id, event.data[:effective_on])
  end

  on OrgGraph::Events::UnitSucceeded do |event|
    @successions[event.data[:succession_id]] = event.data.slice(:predecessor_ids, :successor_ids, :effective_on).symbolize_keys
  end


  # The date of a unit's last change, the one it can't retire before: its
  # own edits, its owners, and sub-units arriving beneath it or leaving.
  #
  # @param unit_id [String]
  # @return [Date, nil] nil for a unit the structure doesn't hold
  def unit_changed_on(unit_id)
    changed_on = @units[unit_id.to_s.downcase]&.changed_on
    changed_on && Date.iso8601(changed_on.to_s)
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

  def handed_over(unit, provider, external_ref, effective_on, handed_over_by_id, field:, previous_field:)
    if external_ref && live_units.any? { |other| other.provider == provider && other.external_ref == external_ref }
      raise "A live unit already mirrors #{provider} #{external_ref}"
    end

    OrgGraph::Events::UnitHandedOver.new(data: {
      unit_id: unit.unit_id, provider:, previous_provider: unit.provider, field:, previous_field:, external_ref:,
      previous_external_ref: unit.external_ref, effective_on: [ effective_on, unit.changed_on ].max, handed_over_by_id:
    })
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

  def ensure_never_held!(level)
    held = @units.values.select { |unit| unit.level_id == level[:level_id] }.sort_by(&:name)
    return if held.empty?

    retired, live = held.partition(&:retired)
    reasons = [ ("holds #{live.map(&:name).to_sentence}" if live.any?),
                ("held #{retired.map(&:name).to_sentence}" if retired.any?) ].compact
    raise "#{level[:name]} can't be removed, as it #{reasons.join(' and ')}"
  end

  def ensure_levels_in_use_keep_order!(levels, in_use)
    kept_order = level_ids(@levels) & in_use
    new_order = level_ids(levels) & in_use
    moved, passed = new_order.zip(kept_order).find { |new_id, old_id| new_id != old_id }
    return unless moved

    name = ->(id) { levels.find { |level| level[:level_id] == id }[:name] }
    raise "#{name[passed]} and #{name[moved]} both hold units, so #{name[passed]} must stay above #{name[moved]}"
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

  def require_level_field(provider, field)
    field = field.to_s.strip.presence
    raise ArgumentError, "A field needs an HRIS provider, not #{ESPALIA}" if field && provider == ESPALIA

    field
  end

  # @return [Hash{String => String}]
  def require_fields(fact, provider, fields)
    fields = (fields || {}).to_h { |part, path| [ part.to_s, path.to_s.strip ] }
    return fields if fields.empty?

    raise ArgumentError, "A field needs an HRIS provider, not #{ESPALIA}" if provider == ESPALIA

    unknown = fields.keys - MAPPABLE_FIELDS.fetch(fact, [])
    raise ArgumentError, "No field can be chosen for #{fact} #{unknown.join(', ')}" if unknown.any?
    raise ArgumentError, "A field needs a path" if fields.value?("")

    fields
  end

  def iso_date(value)
    raise ArgumentError, "Effective date is required" if value.blank?

    (value.is_a?(String) ? Date.iso8601(value) : value.to_date).iso8601
  rescue Date::Error, NoMethodError
    raise ArgumentError, "Invalid effective date: #{value.inspect}"
  end
end
