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
  include Shreddable::AggregateRoot
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
                    :created_on, :changed_on, :retired_on, keyword_init: true)
  Placement = Struct.new(:unit, :parent_id, :until_on, :level_id, :parent_level_id, keyword_init: true)

  def initialize
    @levels = []
    @level_rules = {}
    @units = {}
    @parents = {}
    @unit_kinds = {}
    @held_kinds = {}
    @level_providers = {}
    @level_fields = {}
    @fact_providers = {}
    @fact_fields = {}
    @successions = {}
    @kinds_change_dates = []
    @kind_timelines = {}
    @structures = {}
    @structure_since = {}
    @structure_levels = {}
    @structure_changed_on = {}
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
  # {#set_level_provider}. Each kind keeps the rules it stated, and a kind
  # that goes leaves every list that named it.
  #
  # @param levels [Array<Hash>] each `{ level_id:, name: }`, top first, with an
  #   optional `provider:` for a new level
  # @param effective_on [Date, String] when the taxonomy took effect, no
  #   earlier than the kinds' last change
  # @param defined_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the levels are empty, blank or duplicated
  # @raise [RuntimeError] if a level any unit has held is dropped, naming the
  #   units, a level in use is reordered, or a live unit would be left where
  #   its kind may not sit
  def define_taxonomy(levels, effective_on:, defined_by_id: nil)
    write_taxonomy(levels, effective_on:, defined_by_id:)
  end

  # Says which kinds a kind's units may sit under, and whether they may sit at
  # the top. A kind may list itself, so its units can nest. Refused while a
  # live unit would be left where the new rule doesn't let it sit.
  #
  # A kind an HRIS provides may sit only at the top, or under one kind above
  # it that an HRIS provides, as the mirror reads one field per kind, top first.
  #
  # @param level_id [String]
  # @param parent_ids [Array<String>] kinds in the taxonomy
  # @param top [Boolean]
  # @param effective_on [Date, String] no earlier than the kinds' last change
  # @param defined_by_id [String, nil] person_id of the actor
  # @param structure_unit_id [String, nil] the unit whose own structure holds
  #   the kind; nil for the top structure
  # @raise [ArgumentError] if a kind is unknown, or the kind could sit nowhere
  # @raise [RuntimeError] if the date is too early, a live unit would no longer
  #   fit, or an HRIS provides the kind and the rules break the HRIS rule
  def set_kind_parents(level_id, parent_ids:, top:, effective_on:, defined_by_id: nil, structure_unit_id: nil)
    level_id = require_id(level_id, "Level id")
    if structure_unit_id
      return redefine_structure(structure_unit_id, effective_on:, defined_by_id:) do |levels|
        raise ArgumentError, "That unit type doesn't exist" unless levels.any? { it[:level_id] == level_id }

        levels.map { it[:level_id] == level_id ? it.merge(parent_level_ids: Array(parent_ids), top:) : it }
      end
    end
    raise ArgumentError, "That unit type doesn't exist" unless level_index(level_id)

    write_taxonomy(@levels, rules: { level_id => kind_rules(level_id, parent_ids, top) }, effective_on:, defined_by_id:)
  end

  # Adds a level Espalia holds below every other level. Works from the levels
  # this stream holds, so a level added meanwhile is kept.
  #
  # Without `parent_ids:` or `top:` the new kind keeps the rule every level was
  # first written under: it may sit under any kind above it, or at the top.
  # With only `top:`, it may sit under any kind above it.
  #
  # @param level_id [String] a new level's id
  # @param name [String]
  # @param parent_ids [Array<String>, nil] the kinds it may sit under; its
  #   own id lets its units nest
  # @param top [Boolean, nil] whether it may sit at the top, with
  #   `parent_ids:`; by default only when it lists no parents
  # @param effective_on [Date, String]
  # @param defined_by_id [String, nil] person_id of the actor
  # @param structure_unit_id [String, nil] the unit whose own structure gains
  #   the kind; nil for the top structure
  # @raise [ArgumentError] if the id is taken, the name blank or taken, or a
  #   parent kind unknown
  def add_level(level_id, name, effective_on:, parent_ids: nil, top: nil, defined_by_id: nil, structure_unit_id: nil)
    level_id = require_id(level_id, "Level id")
    raise ArgumentError, "Level id is taken" if kind_home(level_id)
    if structure_unit_id
      return redefine_structure(structure_unit_id, effective_on:, defined_by_id:) do |levels|
        parents = parent_ids.nil? ? level_ids(levels) : Array(parent_ids)
        [ *levels, { level_id:, name:, parent_level_ids: parents, top: top.nil? ? parent_ids.nil? || parents.empty? : top } ]
      end
    end

    rules = {}
    unless parent_ids.nil? && top.nil?
      parent_ids = level_ids(@levels) if parent_ids.nil?
      rules = { level_id => kind_rules(level_id, parent_ids, top.nil? ? Array(parent_ids).empty? : top) }
    end
    levels = [ *@levels, { level_id:, name: } ]
    write_taxonomy(levels, rules:, effective_on:, defined_by_id:)
  end

  # Removes a level Espalia holds that no unit has ever held. A unit keeps its
  # level for life, so the units this stream holds, retired ones included, are
  # every unit a level has held.
  #
  # @param level_id [String] a level in the current taxonomy
  # @param effective_on [Date, String]
  # @param defined_by_id [String, nil] person_id of the actor
  # @param structure_unit_id [String, nil] the unit whose own structure holds
  #   the level; nil for the top structure
  # @raise [ArgumentError] if the level isn't in the taxonomy or is the last one
  # @raise [RuntimeError] if an HRIS provides the level or a unit has held it
  def remove_level(level_id, effective_on:, defined_by_id: nil, structure_unit_id: nil)
    level_id = require_id(level_id, "Level id")
    if structure_unit_id
      return redefine_structure(structure_unit_id, effective_on:, defined_by_id:) do |levels|
        raise ArgumentError, "That unit type doesn't exist" unless levels.any? { it[:level_id] == level_id }
        raise ArgumentError, "A structure needs at least one unit type; withdraw it instead" if levels.one?

        levels.reject { it[:level_id] == level_id }.map { it.merge(parent_level_ids: it[:parent_level_ids] - [ level_id ]) }
      end
    end
    level = @levels.find { |candidate| candidate[:level_id] == level_id }
    raise ArgumentError, "That unit type doesn't exist" unless level
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
  # @param effective_on [Date, String] today or earlier, no earlier than the kinds' last change
  # @param field [String, nil] the HRIS field id, such as
  #   "work.custom.department_x"; nil keeps the current one for the same provider
  # @param set_by_id [String, nil] person_id of the actor
  # @raise [ArgumentError] if the provider is unknown, or a field is named for Espalia
  # @raise [RuntimeError] if the level is unknown, holds live units while its
  #   provider or field changes, would break the order of providers, would
  #   forbid a placement held since the date, or the date is out of range
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

      ensure_no_hris_kind_lists!(level_id) if provider == ESPALIA
      ensure_hris_levels_on_top!(level_ids(@levels), level_id => provider)
      ensure_hris_kinds_fit!(with_stated_rules(@levels), level_id => provider)
    end
    ensure_not_before_last_change!(effective_on)
    ensure_units_still_fit!({ level_id => provider }, from: iso_date(effective_on)) unless provider == previous

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
  #   unit is unmatched, a match names another unit, two units share a value,
  #   or the date is out of range
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
    ensure_not_before_last_change!(effective_on)
    ensure_hris_levels_on_top!(level_ids(@levels), level_id => provider)
    ensure_hris_kinds_fit!(with_stated_rules(@levels), level_id => provider)
    ensure_units_still_fit!({ level_id => provider }, from: effective_on)
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
  # @raise [RuntimeError] if Espalia already holds the level, a level below
  #   it is still the HRIS's, or the date is out of range
  def hand_back_level(level_id, effective_on:, set_by_id: nil)
    level_id = require_id(level_id, "Level id")
    raise "Level is not in the taxonomy" unless level_index(level_id)

    previous = level_provider(level_id)
    raise "Espalia already holds this level" if previous == ESPALIA

    previous_field = @level_fields[level_id]

    effective_on = iso_date(effective_on)
    ensure_not_before_last_change!(effective_on)
    ensure_no_hris_kind_lists!(level_id)
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
  # @param parent_id [String, nil] a live unit of a kind the unit's kind may sit
  #   beneath; nil at the top, where its kind must be allowed to sit
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
    raise "Level is not in the taxonomy" unless kind_home(level_id)
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
  # @param parent_id [String, nil] a live unit of a kind the unit's kind may sit
  #   beneath, and not the unit or one below it; nil to move it to the top
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param moved_by_id [String, nil]
  # @param changed_back_id [String, nil] the event this changes back
  def move_unit(unit_id, parent_id, effective_on:, provider: ESPALIA, moved_by_id: nil, changed_back_id: nil)
    unit = editable_unit!(unit_id, provider)
    unit_id = unit.unit_id
    parent_id = require_id(parent_id, "Parent id") if parent_id
    effective_on = dated_after_creation(unit, effective_on)
    return if parent_id == parent_on(unit_id, effective_on)

    ensure_same_structure!(unit, parent_id)
    ensure_placeable!(unit.provider, unit.level_id, parent_id, on: effective_on, unit_id:,
                                                              until_on: @parents[unit_id].keys.select { it > effective_on }.min)
    raise "A unit can't move beneath itself or a unit below it" if parent_id && loops?(unit_id, parent_id, from: effective_on)

    apply(OrgGraph::Events::UnitMoved.new(data: {
      unit_id: unit_id,
      parent_id: parent_id,
      previous_parent_id: parent_on(unit_id, effective_on),
      provider: unit.provider,
      effective_on: effective_on,
      moved_by_id: moved_by_id,
      changed_back_id: changed_back_id
    }))
  end

  # Changes a unit's kind in place, keeping its id, name, place, owners and
  # members. An unchanged kind writes nothing.
  #
  # The new kind must sit where the unit sits, and each sub-unit must sit
  # beneath it, on every day from the change's date, by the rules each day had.
  #
  # @param unit_id [String] a live unit Espalia holds
  # @param level_id [String] a kind Espalia supplies
  # @param effective_on [Date, String] no earlier than the unit's last change of kind, and no later than today
  # @param provider [String] who supplies the change; must be the unit's own
  # @param kind_changed_by_id [String, nil]
  # @param changed_back_id [String, nil] the event this changes back
  # @raise [RuntimeError] naming every unit that wouldn't fit
  def change_unit_kind(unit_id, level_id, effective_on:, provider: ESPALIA, kind_changed_by_id: nil, changed_back_id: nil)
    unit = editable_unit!(unit_id, provider)
    unit_id = unit.unit_id
    level_id = require_id(level_id, "Level id")
    raise "That unit type doesn't exist" unless kind_home(level_id)
    raise "#{level_provider(level_id)} supplies #{level_name(level_id)} units" unless level_provider(level_id) == unit.provider
    return if level_id == unit.level_id

    effective_on = dated_after_creation(unit, effective_on)
    last_change = @unit_kinds[unit_id].keys.max
    raise "The unit's type last changed on #{last_change}, so date this then or later" if effective_on < last_change
    raise "A unit's type can't change after today" if effective_on > today

    ensure_kind_fits!(unit, level_id)
    ensure_kind_fitted_since!(unit, level_id, from: effective_on)

    apply(OrgGraph::Events::UnitKindChanged.new(data: {
      unit_id: unit_id,
      level_id: level_id,
      previous_level_id: unit.level_id,
      provider: unit.provider,
      effective_on: effective_on,
      kind_changed_by_id: kind_changed_by_id,
      changed_back_id: changed_back_id
    }))
  end

  # Gives a unit a structure of its own: unit types that govern the units
  # beneath it, down to any unit that declares one in turn. Each unit it
  # governs changes to the type the conversion names, in the same change,
  # keeping its id, owners, members and history.
  #
  # @param unit_id [String] a live unit with no structure of its own; an HRIS
  #   may provide it, though none of the units beneath it
  # @param levels [Array<Hash>] top first, each `{ level_id:, name:, parent_level_ids:, top: }`,
  #   with `copied_from_level_id:` naming the type of `copied_from` it copies
  # @param conversion [Hash{String => String}] the type each unit beneath
  #   holds now, to the new type it takes; every type held beneath needs one
  # @param copied_from [String, nil] "top", or the unit whose structure it
  #   copies; nil for a fresh one
  # @param effective_on [Date, String] no later than today, and no earlier than
  #   the structure's last change or any change beneath it
  # @param defined_by_id [String, nil]
  # @raise [ArgumentError, RuntimeError] naming what doesn't fit
  def declare_structure(unit_id, levels:, conversion:, effective_on:, copied_from: nil, defined_by_id: nil)
    unit = live_unit!(unit_id)
    raise "#{unit.name} already has its own structure" if @structures.key?(unit.unit_id)

    copied_from = copy_source(copied_from)
    levels = declared_levels(levels, copied_from)
    governed = governed_by(unit.unit_id)
    if (mirrored = governed.find { it.provider != ESPALIA })
      raise "#{mirrored.name} comes from #{HrisConfig.provider_label(mirrored.provider)}, so #{unit.name} can't have a structure of its own over it"
    end

    effective_on = structure_dated!(unit, governed, effective_on)
    conversion = converted!(governed, conversion, into: OrgGraph::Taxonomy.new(levels), label: "#{unit.name}'s structure") do |parent_id|
      parent_id == unit.unit_id ? nil : parent_id
    end
    apply(OrgGraph::Events::TaxonomyDefined.new(data: {
      levels:, previous_levels: [], structure_unit_id: unit.unit_id, copied_from:, conversion:,
      effective_on:, defined_by_id:
    }))
    apply_conversion(governed, conversion, effective_on, defined_by_id)
  end

  # Withdraws a unit's own structure, so the structure above governs the units
  # beneath it again. Each changes to the type the conversion names, in the
  # same change.
  #
  # @param unit_id [String] a live unit with a structure of its own
  # @param conversion [Hash{String => String}] each type held beneath, to a type
  #   of the structure above that Espalia manages
  # @param effective_on [Date, String] as for {#declare_structure}
  # @param withdrawn_by_id [String, nil]
  # @raise [ArgumentError, RuntimeError] naming what doesn't fit
  def withdraw_structure(unit_id, conversion:, effective_on:, withdrawn_by_id: nil)
    unit = live_unit!(unit_id)
    raise "#{unit.name} has no structure of its own" unless @structures.key?(unit.unit_id)

    governed = governed_by(unit.unit_id)
    effective_on = structure_dated!(unit, governed, effective_on)
    above = structure_in_force(unit.unit_id)
    conversion = converted!(governed, conversion, into: kinds_at(above), label: structure_label(above), &:itself)
    apply(withdrawal(unit, conversion:, effective_on:, withdrawn_by_id:))
    apply_conversion(governed, conversion, effective_on, withdrawn_by_id)
  end

  # Retires a unit. Its live sub-units must be moved or retired first. A unit
  # with a structure of its own gives it up in the same change, whoever
  # supplies the retirement, so changing the retirement back can restore both.
  #
  # @param unit_id [String]
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param retired_by_id [String, nil]
  def retire_unit(unit_id, effective_on:, provider: ESPALIA, retired_by_id: nil)
    effective_on = iso_date(effective_on)
    unit = retirable_unit!(unit_id, provider, on: effective_on)

    retire(unit, effective_on:, retired_by_id:)
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

      ensure_one_structure!(predecessor_ids + successor_ids)
      latest = (predecessor_ids + successor_ids).map { |id| @units[id] }.max_by(&:created_on)
      raise "A succession can't predate #{latest.name}, created on #{latest.created_on}" if effective_on < latest.created_on
    end

    retiring = retire_predecessors ? predecessor_ids.map { |id| @units[id] }.reject(&:retired) : []
    retiring = retiring.sort_by { |unit| [ -ancestor_ids(unit.unit_id).size, -kind_position(unit.level_id) ] }
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
      retire(unit, effective_on:, retired_by_id: stated_by_id, succession_id:, successor_ids: succession[:successor_ids])
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
    levels = event.data[:levels].map { |level| level.to_h.symbolize_keys }
    if (structure_unit_id = event.data[:structure_unit_id])
      define_declared_structure(structure_unit_id, levels, event.data[:effective_on])
    else
      define_top_structure(levels, event)
    end
  end

  on OrgGraph::Events::LevelProviderSet do |event|
    @taxonomy = nil
    @kinds_change_dates << event.data[:effective_on] if event.data[:effective_on]
    @level_providers[event.data[:level_id]] = event.data[:provider]
    @level_fields[event.data[:level_id]] = event.data[:field]
    revise_kind(event.data[:level_id], event.data[:effective_on]) { |kind| kind&.merge(provider: event.data[:provider]) }
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
    @parents[data[:unit_id]] = { data[:effective_on] => data[:parent_id] }
    @unit_kinds[data[:unit_id]] = { data[:effective_on] => data[:level_id] }
    @held_kinds[data[:unit_id]] = Set[data[:level_id]]
    touch(data[:parent_id], data[:effective_on])
  end

  on OrgGraph::Events::UnitKindChanged do |event|
    unit = @units.fetch(event.data[:unit_id])
    @unit_kinds[unit.unit_id][event.data[:effective_on]] = event.data[:level_id]
    @held_kinds[unit.unit_id] << event.data[:level_id]
    unit.level_id = @unit_kinds[unit.unit_id].max_by(&:first).last
    touch(unit.unit_id, event.data[:effective_on])
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
    @parents[unit.unit_id][event.data[:effective_on]] = event.data[:parent_id]
    unit.parent_id = @parents[unit.unit_id].max_by(&:first).last
  end

  on OrgGraph::Events::UnitRetired do |event|
    unit = @units.fetch(event.data[:unit_id])
    unit.retired = true
    unit.retired_on = event.data[:effective_on]
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


  # The kinds of unit and where each may sit, as the taxonomy now stands.
  #
  # @return [OrgGraph::Taxonomy]
  def taxonomy
    @taxonomy ||= OrgGraph::Taxonomy.new(with_stated_rules(@levels), providers: @level_providers)
  end

  # The unit whose structure governs a unit: the nearest unit above it that
  # declared one. A declaring unit's own type comes from the structure above.
  #
  # @param unit_id [String]
  # @return [String, nil] the declaring unit's id; nil for the top structure
  def structure_in_force(unit_id)
    return if @structures.empty?

    above = @units[unit_id]&.parent_id
    above = @units[above]&.parent_id until above.nil? || @structures.key?(above)
    above
  end

  # @param unit_id [String]
  # @return [OrgGraph::Taxonomy] the types of the structure in force at a unit
  def taxonomy_for(unit_id) = structure_taxonomy(structure_in_force(unit_id), taxonomy)

  # @return [Hash{String => OrgGraph::Taxonomy}] each declared structure, by its declaring unit's id
  def declared_structures = @structures.dup

  # The live units sitting where their kind's rules no longer allow, each
  # judged by the structure in force where it sits. A unit directly beneath a
  # declaring unit sits at the top of that unit's structure.
  #
  # @param rules [OrgGraph::Taxonomy] the top structure's rules
  # @return [Array<Unit>] by name
  def misplaced_units(rules = taxonomy)
    live_units.reject do |unit|
      kinds = structure_taxonomy(structure_in_force(unit.unit_id), rules)
      parent_kind = seated_parent_kind(unit.parent_id)
      parent_kind ? kinds.allows?(unit.level_id, beneath: parent_kind) : kinds.may_be_top?(unit.level_id)
    end.sort_by(&:name)
  end

  # @param unit_id [String]
  # @return [Unit, nil] the unit, live or retired; nil for one the structure doesn't hold
  def unit(unit_id) = @units[unit_id]

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

  def structure_taxonomy(structure_unit_id, top) = structure_unit_id ? @structures.fetch(structure_unit_id) : top

  def define_top_structure(levels, event)
    @taxonomy = nil
    @kinds_change_dates << event.data[:effective_on] if event.data[:effective_on]
    @levels = levels.map { |level| level.slice(:level_id, :name) }
    @level_rules = levels.select { |level| level.key?(:parent_level_ids) }
                         .to_h { |level| [ level[:level_id], level.slice(:parent_level_ids, :top) ] }
    @level_providers = @level_providers.slice(*level_ids(@levels))
    @level_fields = @level_fields.slice(*level_ids(@levels))
    levels.each_with_index do |level, position|
      revise_kind(level[:level_id], event.data[:effective_on]) do |kind|
        { name: level[:name], position:, provider: kind&.fetch(:provider) || ESPALIA, **level.slice(:parent_level_ids, :top) }
      end
    end
    (@kind_timelines.keys - level_ids(@levels)).each { |level_id| revise_kind(level_id, event.data[:effective_on]) { nil } }
  end

  # Withdrawing a structure defines it with no types.
  def define_declared_structure(unit_id, levels, effective_on)
    @structure_changed_on[unit_id] = effective_on.to_s if effective_on
    if levels.empty?
      [ @structures, @structure_since, @structure_levels ].each { it.delete(unit_id) }
    else
      @structure_since[unit_id] ||= effective_on.to_s
      @structure_levels[unit_id] = levels
      @structures[unit_id] = OrgGraph::Taxonomy.new(levels.map { it.slice(:level_id, :name, :parent_level_ids, :top) })
    end
  end

  def withdrawal(unit, conversion:, effective_on:, withdrawn_by_id:)
    OrgGraph::Events::TaxonomyDefined.new(data: {
      levels: [], previous_levels: @structure_levels.fetch(unit.unit_id), structure_unit_id: unit.unit_id, conversion:,
      effective_on:, defined_by_id: withdrawn_by_id
    })
  end

  # Rewrites a declared structure's types from the block's edit of them,
  # refused while a type a unit has held would go, or a unit it governs
  # would no longer fit.
  def redefine_structure(unit_id, effective_on:, defined_by_id:)
    unit = live_unit!(require_id(unit_id, "Unit id"))
    old = @structure_levels[unit.unit_id] or raise "#{unit.name} has no structure of its own"
    levels = declared_levels(yield(old), nil, home: unit.unit_id)
    return if levels == old

    governed = governed_by(unit.unit_id)
    on = structure_dated!(unit, governed, effective_on)
    old.reject { level_ids(levels).include?(it[:level_id]) }.each { ensure_never_held!(it) }
    held = governed.map(&:level_id).uniq
    converted!(governed, held.zip(held).to_h, into: OrgGraph::Taxonomy.new(levels), label: "#{unit.name}'s structure") do |parent_id|
      parent_id == unit.unit_id ? nil : parent_id
    end
    apply(OrgGraph::Events::TaxonomyDefined.new(data: {
      levels:, previous_levels: old, structure_unit_id: unit.unit_id, effective_on: on, defined_by_id:
    }))
  end

  # The live units a structure at a unit governs: those beneath it, down to
  # and including any that declares a structure of its own.
  def governed_by(unit_id)
    children = live_units.group_by(&:parent_id)
    governed = []
    pending = [ unit_id ]
    while (id = pending.shift)
      children.fetch(id, []).each do |child|
        governed << child
        pending << child.unit_id unless @structures.key?(child.unit_id)
      end
    end
    governed
  end

  def copy_source(copied_from)
    return if copied_from.blank?
    return "top" if copied_from.to_s == "top"

    source = require_id(copied_from, "The structure copied from")
    raise ArgumentError, "No unit has that structure to copy" unless @structures.key?(source)

    source
  end

  # A declared structure's types state their rules, and each type a copy
  # names comes from the structure it copies.
  def declared_levels(levels, copied_from, home: nil)
    levels = Array(levels).map do |level|
      level = level.to_h.symbolize_keys
      { level_id: require_id(level[:level_id], "Level id"), name: require_name(level[:name]),
        parent_level_ids: Array(level[:parent_level_ids]).map { require_id(it, "Parent level id") }.uniq,
        top: level.fetch(:top, true), copied_from_level_id: level[:copied_from_level_id].presence&.then { require_id(it, "Copied level id") } }
    end
    raise ArgumentError, "A structure needs at least one unit type" if levels.empty?

    ids = level_ids(levels)
    raise ArgumentError, "Each unit type needs its own id" unless ids.uniq.size == ids.size
    raise ArgumentError, "Level id is taken" if ids.any? { (found = kind_home(it)) && found != home }
    raise ArgumentError, "Two unit types can't share a name" unless levels.map { it[:name].downcase }.uniq.size == levels.size

    source = copied_from && (copied_from == "top" ? taxonomy : @structures.fetch(copied_from))
    levels.map do |level|
      unknown = level[:parent_level_ids] - ids
      raise ArgumentError, "#{level[:name]} lists a unit type this structure doesn't hold" if unknown.any?
      raise ArgumentError, "Top must be true or false" unless [ true, false ].include?(level[:top])
      if !level[:top] && (level[:parent_level_ids] - [ level[:level_id] ]).empty?
        raise ArgumentError, "A unit type needs somewhere to sit: under another type, or at the top"
      end
      if level[:copied_from_level_id] && !home && !source&.kind(level[:copied_from_level_id])
        raise ArgumentError, "#{level[:name]} copies a unit type the structure copied from doesn't hold"
      end

      level.merge(parent_level_ids: ids & level[:parent_level_ids]).compact
    end.tap { ensure_every_kind_can_sit!(it) }
  end

  # A structure changes on a day no later than today, and no earlier than its
  # own last change or the last change to any unit it governs: a unit's
  # arrival, move or change of type, or the end of one that sat beneath.
  def structure_dated!(unit, governed, effective_on)
    on = iso_date(effective_on)
    raise "A structure can't change after today. Date it today or earlier" if on > today
    if (last = @structure_changed_on[unit.unit_id]) && on < last
      raise "#{unit.name}'s structure last changed on #{last}, so date this then or later"
    end

    beneath = [ unit.unit_id, *governed.map(&:unit_id) ]
    changes = governed.flat_map do |child|
      [ child.created_on, *@parents.fetch(child.unit_id, {}).keys, *@unit_kinds.fetch(child.unit_id, {}).keys ].map { [ it, child ] }
    end
    changes += placements_ended_after(on).select { beneath.include?(it.parent_id) }.map { [ it.until_on, it.unit ] }
    day, changed = changes.select { |changed_on, _| changed_on > on }.max_by { |changed_on, child| [ changed_on, child.name ] }
    raise "#{changed.name} changed on #{day}, so date this then or later" if changed

    on
  end

  # Checks a conversion against the units it covers and the structure they
  # move into, and keeps only the types they hold. The block gives the parent
  # whose type a unit answers to, nil for one at the top of the structure.
  def converted!(governed, conversion, into:, label:)
    conversion = conversion.to_h.to_h { |from, to| [ require_id(from, "Converted level id"), require_id(to, "Converted level id") ] }
    unknown = conversion.values.uniq.reject { into.kind(it) }
    raise ArgumentError, "The conversion names a unit type #{label} doesn't hold" if unknown.any?

    if (mirrored = conversion.values.uniq.find { level_provider(it) != ESPALIA })
      raise "#{any_kind_name(mirrored)} comes from #{HrisConfig.provider_label(level_provider(mirrored))}, so no unit here can change to it"
    end

    missing = governed.map(&:level_id).uniq - conversion.keys
    raise "Say what #{missing.map { any_kind_name(it) }.sort.to_sentence} units become" if missing.any?

    misfits = governed.filter_map do |child|
      kind = conversion.fetch(child.level_id)
      parent_id = yield(child.parent_id)
      parent_kind = parent_id && conversion.fetch(@units[parent_id].level_id, @units[parent_id].level_id)
      next if parent_kind ? into.allows?(kind, beneath: parent_kind) : into.may_be_top?(kind)

      where = parent_kind ? "under #{into.kind(parent_kind)&.name || any_kind_name(parent_kind)}" : "at the top"
      "#{child.name} (#{into.kind(kind).name} #{where})"
    end
    raise "These units wouldn't fit #{label}: #{misfits.sort.join(', ')}" if misfits.any?

    conversion.slice(*governed.map(&:level_id).uniq)
  end

  def apply_conversion(governed, conversion, effective_on, changed_by_id)
    governed.each do |child|
      next if conversion[child.level_id] == child.level_id

      apply(OrgGraph::Events::UnitKindChanged.new(data: {
        unit_id: child.unit_id, level_id: conversion.fetch(child.level_id), previous_level_id: child.level_id,
        provider: child.provider, effective_on:, kind_changed_by_id: changed_by_id
      }))
    end
  end

  # The structure a unit placed beneath a parent joins: the parent's own when
  # it declares one, else the one in force at the parent.
  def structure_beneath(parent_id)
    return if parent_id.nil? || @structures.empty?

    @structures.key?(parent_id) ? parent_id : structure_in_force(parent_id)
  end

  # The kind a unit beneath a parent answers to; nil at the top of its
  # structure, which is where a declaring unit's sub-units sit.
  def seated_parent_kind(parent_id)
    parent_id && !@structures.key?(parent_id) ? @units[parent_id]&.level_id : nil
  end

  def kinds_at(structure_unit_id) = structure_taxonomy(structure_unit_id, taxonomy)

  # :top for a type of the top structure, the declaring unit's id for a
  # declared one's, and nil for a type no structure holds. Each structure's
  # types have ids of their own, so a type names its structure.
  def kind_home(level_id)
    return :top if level_index(level_id)

    @structures.find { |_, kinds| kinds.kind(level_id) }&.first
  end

  def kind_position(level_id)
    home = kind_home(level_id)
    home == :top ? level_index(level_id) : (@structures[home]&.kinds&.index { it.id == level_id } || 0)
  end

  def structure_label(structure_unit_id)
    structure_unit_id ? "#{@units[structure_unit_id].name}'s structure" : "the top structure"
  end

  # A unit keeps the structure it sits in: moving one across a boundary needs
  # its types converted, which a move can't do.
  def ensure_same_structure!(unit, parent_id)
    from = structure_in_force(unit.unit_id)
    to = structure_beneath(parent_id)
    return if from == to

    raise "#{unit.name} can't move out of #{structure_label(from)} into #{structure_label(to)}"
  end

  def ensure_one_structure!(unit_ids)
    structures = unit_ids.map { structure_in_force(it) }.uniq
    return if structures.size == 1

    raise "A merge or split can't cross structures: these units sit in #{structures.map { structure_label(it) }.to_sentence}"
  end

  # A change to a unit in a declared structure can't predate the structure.
  def ensure_within_structure!(structure_unit_id, on)
    since = structure_unit_id && @structure_since[structure_unit_id]
    return unless since && on < since

    raise "#{structure_label(structure_unit_id).upcase_first} began on #{since}, so date the change then or later"
  end

  def write_taxonomy(levels, effective_on:, defined_by_id:, rules: {})
    new_providers = new_level_providers(levels)
    levels = tidy_parents(with_stated_rules(normalise_levels(levels), rules))
    return if levels == tidy_parents(with_stated_rules(@levels))

    ensure_every_kind_can_sit!(levels)

    ensure_not_before_last_change!(effective_on)
    @levels.reject { |level| level_ids(levels).include?(level[:level_id]) }.each { ensure_never_held!(it) }

    in_use = live_units.map(&:level_id).uniq

    ensure_levels_in_use_keep_order!(levels, in_use)

    ensure_hris_levels_on_top!(level_ids(levels), new_providers)
    ensure_hris_kinds_fit!(levels, new_providers)
    ensure_units_still_fit!(new_providers, levels:, from: iso_date(effective_on))

    apply(OrgGraph::Events::TaxonomyDefined.new(data: {
      levels: levels,
      previous_levels: with_stated_rules(@levels),
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

  def retire(unit, effective_on:, retired_by_id:, **succession)
    if @structures.key?(unit.unit_id)
      apply(withdrawal(unit, conversion: {}, effective_on:, withdrawn_by_id: retired_by_id))
    end
    apply(retirement(unit, effective_on:, retired_by_id:, **succession))
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
    held = @units.values.select { |unit| @held_kinds.fetch(unit.unit_id, Set.new).include?(level[:level_id]) }.sort_by(&:name)
    return if held.empty?

    live, retired = held.partition { !it.retired && it.level_id == level[:level_id] }
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

  # A level an HRIS provides may sit only beneath the one HRIS level its list
  # names (by default, the one directly above it), so handing a level over, or
  # inserting an HRIS level above one, can leave a unit where its kind may no
  # longer sit. A change dated in the past also covers the placements units
  # held since, retired units' included.
  def ensure_units_still_fit!(provider_changes, from:, levels: with_stated_rules(@levels))
    prospective = OrgGraph::Taxonomy.new(levels, providers: @level_providers.merge(provider_changes))
    stranded = misplaced_units(prospective) - misplaced_units
    if stranded.any?
      raise "These units wouldn't fit this structure, so move them first: #{stranded.map { describe_fit(it, prospective) }.join(', ')}"
    end

    held = placements_ended_after(from).select { fits?(it, taxonomy) && !fits?(it, prospective) }
    return if held.empty?

    raise "These units sat where this structure wouldn't allow after #{from}, so date it #{held.map(&:until_on).max} or later: " \
          "#{held.map { describe_held(it, prospective) }.join(', ')}"
  end

  # The placements that ended, by a move, a retirement or a change of type,
  # after a day. Each ends on the first day it no longer held: a move's or a
  # type change's date, or the day after a retirement, since a unit is still
  # live on the day it retires. A placement still held is today's, which
  # ensure_units_still_fit! checks on its own.
  def placements_ended_after(day)
    @units.values.flat_map do |unit|
      points = @parents.fetch(unit.unit_id, {}).sort
      ends = points.drop(1).map(&:first) + [ unit.retired_on && (Date.iso8601(unit.retired_on) + 1).iso8601 ]
      points.zip(ends).flat_map do |(from, parent_id), until_on|
        next [] if until_on && (until_on <= day || until_on <= from)

        held_kinds(unit.unit_id, parent_id, from:, until_on:).filter_map do |start, finish|
          next unless finish && finish > day

          Placement.new(unit:, parent_id:, until_on: finish, level_id: kind_on(unit.unit_id, start),
                        parent_level_id: parent_id && kind_on(parent_id, start))
        end
      end
    end
  end

  # A placement split where the unit or its parent changed type, each span as
  # `[from, until_on]`, the last open-ended when the placement is.
  def held_kinds(unit_id, parent_id, from:, until_on:)
    starts = [ from, *kind_change_days(unit_id, parent_id).select { it > from && (until_on.nil? || it < until_on) } ].uniq.sort
    starts.zip(starts.drop(1) + [ until_on ])
  end

  def kind_change_days(*unit_ids)
    unit_ids.compact.flat_map { @unit_kinds.fetch(it, {}).keys }
  end

  def fits?(placement, rules)
    return rules.may_be_top?(placement.level_id) unless placement.parent_id

    rules.allows?(placement.level_id, beneath: placement.parent_level_id)
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

  def ensure_kind_fits!(unit, level_id)
    structure_unit_id = structure_in_force(unit.unit_id)
    rules = kinds_at(structure_unit_id)
    raise "#{any_kind_name(level_id)} isn't a unit type of #{structure_label(structure_unit_id)}" unless rules.kind(level_id)

    kind = rules.kind(level_id).name
    parent = unit.parent_id && @units[unit.parent_id]
    parent_kind = seated_parent_kind(unit.parent_id)
    misfits = []
    if parent_kind.nil?
      misfits << "#{unit.name} at the top" unless rules.may_be_top?(level_id)
    elsif !rules.allows?(level_id, beneath: parent_kind)
      misfits << "#{unit.name} under #{parent.name} (#{rules.kind(parent_kind).name})"
    end
    # A declaring unit's sub-units sit at the top of its own structure.
    stranded = @structures.key?(unit.unit_id) ? [] : live_units.select { it.parent_id == unit.unit_id && !rules.allows?(it.level_id, beneath: level_id) }
    misfits += stranded.sort_by(&:name).map { "#{it.name} (#{rules.kind(it.level_id).name}) under #{unit.name}" }
    return if misfits.empty?

    raise "#{unit.name} can't change to #{kind}, as these wouldn't fit: #{misfits.join(', ')}"
  end

  # A change must fit each day from its date, by that day's rules: the parent
  # the unit had then, and the sub-units beneath it then. Days after today
  # count too, since a move can be dated ahead.
  def ensure_kind_fitted_since!(unit, level_id, from:)
    if (structure_unit_id = structure_in_force(unit.unit_id))
      return ensure_within_structure!(structure_unit_id, from)
    end

    [ from, *kind_fit_days(unit.unit_id).select { it > from } ].uniq.sort.each do |day|
      rules = rules_on(day)
      raise "#{level_name(level_id)} didn't exist on #{day}, so date the change later" unless rules.kind(level_id)

      misfits = kind_misfits_on(unit, level_id, day, rules)
      next if misfits.empty?

      kind = rules.kind(level_id).name
      raise "On #{day}, #{kind} wouldn't fit: #{misfits.join(', ')}" if day > today
      raise "On #{day}, #{kind} wouldn't have fit: #{misfits.join(', ')}. Date the change later"
    end
  end

  # The days the fit can change: the rules', and those on which the unit,
  # any parent it had, or any unit ever beneath it moved, changed type or
  # retired.
  def kind_fit_days(unit_id)
    children = @parents.select { |_, points| points.value?(unit_id) }.keys
    related = [ unit_id, *@parents.fetch(unit_id, {}).values.compact, *children ].uniq
    [ *@kind_timelines.values.flatten(1).map(&:first),
      *related.flat_map { [ *@parents.fetch(it, {}).keys, *@unit_kinds.fetch(it, {}).keys ] },
      *children.filter_map { (retired_on = @units[it]&.retired_on) && (Date.iso8601(retired_on) + 1).iso8601 } ]
  end

  def kind_misfits_on(unit, level_id, day, rules)
    parent_id = parent_on(unit.unit_id, day)
    parent_kind = parent_id && kind_on(parent_id, day)
    kind = rules.kind(level_id).name
    misfits = []
    if parent_id.nil?
      misfits << "#{unit.name} (#{kind} at the top)" unless rules.may_be_top?(level_id)
    elsif rules.kind(parent_kind) && !rules.allows?(level_id, beneath: parent_kind)
      misfits << "#{unit.name} (#{kind} under #{rules.kind(parent_kind).name})"
    end
    children = @units.values.select { live_on?(it, day) && parent_on(it.unit_id, day) == unit.unit_id }
    children.sort_by(&:name).each do |child|
      child_kind = kind_on(child.unit_id, day)
      next if !rules.kind(child_kind) || rules.allows?(child_kind, beneath: level_id)

      misfits << "#{child.name} (#{rules.kind(child_kind).name} under #{kind})"
    end
    misfits
  end

  def kind_on(unit_id, day)
    @unit_kinds.fetch(unit_id, {}).select { |from, _| from <= day }.max_by(&:first)&.last || @units[unit_id]&.level_id
  end

  def live_on?(unit, day) = unit.created_on <= day && (unit.retired_on.nil? || unit.retired_on >= day)

  # A parent must be live and of a kind the unit's kind may sit beneath, and a
  # mirrored unit never hangs beneath one Espalia holds. A back-dated placement
  # must also fit the kinds' rules on each day it holds, as the history shows
  # them; one that a later move ends before today answers only to those days.
  def ensure_placeable!(provider, level_id, parent_id, on:, until_on: nil, unit_id: nil)
    held_today = until_on.nil? || until_on > today
    parent = parent_id && @units[parent_id]
    if parent_id
      raise "Parent unit not found" unless parent
      raise "Parent unit is retired" if parent.retired
      raise "The parent unit was created on #{parent.created_on}" if on < parent.created_on
    end
    structure_unit_id = structure_beneath(parent_id)
    rules = kinds_at(structure_unit_id)
    raise "#{any_kind_name(level_id)} isn't a unit type of #{structure_label(structure_unit_id)}" unless rules.kind(level_id)

    parent_kind = seated_parent_kind(parent_id)
    if parent_kind.nil?
      where = structure_unit_id ? "at the top of #{structure_label(structure_unit_id)}" : "at the top"
      raise "#{rules.kind(level_id).name} can't sit #{where}" if held_today && !rules.may_be_top?(level_id)
    elsif held_today && !rules.allows?(level_id, beneath: parent_kind)
      raise "#{rules.kind(level_id).name} can't sit under #{rules.kind(parent_kind).name}"
    end
    raise "A mirrored unit can't sit beneath a unit Espalia holds" if parent && provider != ESPALIA && parent.provider == ESPALIA
    return ensure_within_structure!(structure_unit_id, on) if structure_unit_id

    ensure_placeable_while_held!(level_id, parent_id, unit_id:, on:, until_on:)
  end

  # Each day reads the kinds the unit and its parent held then, so a back-dated
  # move answers to a type either has since changed.
  def ensure_placeable_while_held!(level_id, parent_id, unit_id:, on:, until_on:)
    days = [ *@kind_timelines.values.flatten(1).map(&:first), *kind_change_days(unit_id, parent_id) ]
           .select { it > on && (until_on.nil? || it < until_on) }
    [ on, *days ].uniq.sort.each do |day|
      level_id = kind_on(unit_id, day) if unit_id
      parent_level_id = parent_id && kind_on(parent_id, day)
      rules = rules_on(day)
      next unless rules.kind(level_id) && (parent_level_id.nil? || rules.kind(parent_level_id))
      next if parent_level_id ? rules.allows?(level_id, beneath: parent_level_id) : rules.may_be_top?(level_id)

      where = parent_level_id ? "under #{rules.kind(parent_level_id).name}" : "at the top"
      raise "On #{day}, #{rules.kind(level_id).name} couldn't sit #{where}, so the change can't be dated before its rules allowed it"
    end
  end

  # The kinds of unit as they stood on a day, each with the rules it had then.
  def rules_on(day)
    kinds = @kind_timelines.filter_map { |level_id, points| points.select { it.first <= day }.last&.last&.merge(level_id:) }
                           .sort_by { it[:position] }
    OrgGraph::Taxonomy.new(kinds.map { it.except(:position, :provider) }, providers: kinds.to_h { [ it[:level_id], it[:provider] ] })
  end

  # Keeps each kind's dated values as the history does: a change takes effect
  # on its date, or on the kind's last change if that is later.
  def revise_kind(level_id, effective_on)
    points = (@kind_timelines[level_id] ||= [])
    latest = points.last&.last
    value = yield(latest)
    return if value == latest

    from = [ effective_on.to_s.presence || "0000-01-01", points.last&.first ].compact.max
    points.reject! { it.first == from }
    points << [ from, value ]
  end

  def live_units
    @units.values.reject(&:retired)
  end

  # The ids above a unit, its parent first. Stops at a loop, so it always ends.
  def ancestor_ids(unit_id)
    ids = []
    while (unit_id = @units[unit_id]&.parent_id) && !ids.include?(unit_id)
      ids << unit_id
    end
    ids
  end

  # Whether placing a unit beneath a parent from a date makes it its own
  # ancestor, today or on any day the move covers. A back-dated move can loop
  # on a day between other moves when today's placement shows no loop.
  def loops?(unit_id, parent_id, from:)
    return true if [ parent_id, *ancestor_ids(parent_id) ].include?(unit_id)

    until_on = @parents[unit_id].keys.select { |on| on > from }.min
    days = @parents.values.flat_map(&:keys).select { |on| on > from && (until_on.nil? || on < until_on) }
    [ from, *days ].uniq.any? { |on| ancestor_ids_on(parent_id, on).include?(unit_id) }
  end

  # The ids above a unit on a day, its parent first, by each unit's dated moves.
  def ancestor_ids_on(unit_id, on)
    ids = [ unit_id ]
    while (parent_id = parent_on(ids.last, on)) && !ids.include?(parent_id)
      ids << parent_id
    end
    ids.drop(1)
  end

  def parent_on(unit_id, on)
    @parents.fetch(unit_id, {}).select { |from, _| from <= on }.max_by(&:first)&.last
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

  # A level keeps the rules it stated when the taxonomy is redefined around it.
  def with_stated_rules(levels, rules = {})
    stated = @level_rules.merge(rules)
    levels.map { |level| level.slice(:level_id, :name).merge(stated.fetch(level[:level_id], {})) }
  end

  # Lists each kind's parents in taxonomy order, without the kinds that went.
  def tidy_parents(levels)
    ids = level_ids(levels)
    levels.map { |level| level.key?(:parent_level_ids) ? level.merge(parent_level_ids: ids & level[:parent_level_ids]) : level }
  end

  # A kind's first unit sits at the top or under a unit of a kind that can
  # already have one, so two kinds that list only each other can never start.
  def ensure_every_kind_can_sit!(levels)
    seated = levels.reject { |level| level[:top] == false }.map { |level| level[:level_id] }
    loop do
      more = levels.select { |level| !seated.include?(level[:level_id]) && Array(level[:parent_level_ids]).intersect?(seated) }
      break if more.empty?

      seated += more.map { |level| level[:level_id] }
    end
    stuck = levels.find { |level| !seated.include?(level[:level_id]) }
    raise "#{stuck[:name]} would have nowhere to sit, so give it another place first" if stuck
  end

  # The mirror reads one field per kind, top first, so a kind an HRIS provides
  # can take its parent only from one kind above it that an HRIS provides too.
  def ensure_hris_kinds_fit!(levels, changes = {})
    providers = @level_providers.merge(changes)
    hris = ->(id) { providers.fetch(id, ESPALIA) != ESPALIA }
    ids = level_ids(levels)
    levels.each_with_index do |level, index|
      next unless level.key?(:parent_level_ids) && hris.(level[:level_id])

      parents = level[:parent_level_ids]
      next if level[:top] != false && parents.size <= 1 && (parents - ids.first(index).select(&hris)).empty?

      raise "#{level[:name]} can sit only at the top, or under one type above it that an HRIS provides, " \
            "while it comes from #{HrisConfig.provider_label(providers[level[:level_id]])}"
    end
  end

  def ensure_no_hris_kind_lists!(level_id)
    lister = with_stated_rules(@levels).find do |level|
      level[:level_id] != level_id && level_provider(level[:level_id]) != ESPALIA && Array(level[:parent_level_ids]).include?(level_id)
    end
    return unless lister

    raise "#{level_name(level_id)} can't come back to Espalia while #{lister[:name]}, " \
          "which comes from #{HrisConfig.provider_label(level_provider(lister[:level_id]))}, can sit under it"
  end

  # A kind's rules as an event states them: its parent kinds, in taxonomy
  # order, and whether it may sit at the top.
  # A unit of a kind that lists only itself needs a parent of its own kind
  # first, so it could sit nowhere unless it may also sit at the top.
  def kind_rules(kind_id, parent_ids, top)
    ids = level_ids(@levels) | [ kind_id ]
    parent_ids = Array(parent_ids).map { |id| require_id(id, "Parent level id") }.uniq
    unknown = parent_ids - ids
    raise ArgumentError, "Not in the taxonomy: #{unknown.join(', ')}" if unknown.any?
    raise ArgumentError, "Top must be true or false" unless [ true, false ].include?(top)
    raise ArgumentError, "A unit type needs somewhere to sit: under another type, or at the top" if !top && (parent_ids - [ kind_id ]).empty?

    { parent_level_ids: parent_ids.sort_by { |id| ids.index(id) }, top: }
  end

  def describe_fit(unit, rules)
    parent = unit.parent_id && @units[unit.parent_id]
    kind = rules.kind(unit.level_id).name
    "#{unit.name} (#{parent ? "#{kind} under #{rules.kind(parent.level_id).name}" : "#{kind} at the top"})"
  end

  def describe_held(placement, rules)
    kind = rules.kind(placement.level_id).name
    where = placement.parent_id ? "under #{rules.kind(placement.parent_level_id).name}" : "at the top"
    "#{placement.unit.name} (#{kind} #{where} until #{placement.until_on})"
  end

  def level_name(level_id) = @levels.find { |level| level[:level_id] == level_id }&.dig(:name)

  def any_kind_name(level_id)
    level_name(level_id) || @structures.values.filter_map { it.kind(level_id)&.name }.first || "That unit type"
  end

  # The kinds' history dates each change no earlier than the last, so a
  # change dated before it would be recorded on a day it wasn't made.
  # A structure that takes effect later belongs in a plan, so a change is
  # dated today or earlier. A future-dated change an older stream holds is
  # left out of the comparison, so it can't lock out today's changes.
  def ensure_not_before_last_change!(effective_on)
    on = iso_date(effective_on)
    raise "A change to the unit types can't be dated after today. Date it today or earlier; plan a future structure in a plan" if on > today

    last = @kinds_change_dates.select { it <= today }.max
    return unless last && on < last

    raise "The unit types last changed on #{last}, so a change can't be dated before it"
  end

  def today = Tenant.today.iso8601

  def normalise_levels(levels)
    levels = Array(levels).map do |level|
      level = level.to_h.symbolize_keys
      { level_id: require_id(level[:level_id], "Level id"), name: level[:name].to_s.strip }
    end
    raise ArgumentError, "A structure needs at least one unit type" if levels.empty?
    raise ArgumentError, "Every unit type needs a name" if levels.any? { |level| level[:name].empty? }
    raise ArgumentError, "Unit type ids must be unique" unless level_ids(levels).uniq.size == levels.size
    raise ArgumentError, "Unit type names must be unique" unless levels.map { |level| level[:name].downcase }.uniq.size == levels.size

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
