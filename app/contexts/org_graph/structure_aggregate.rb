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
class OrgGraph::StructureAggregate
  include AggregateRoot

  ESPALIA = "espalia"
  PROVIDERS = (HrisConfig::PROVIDERS + [ ESPALIA ]).freeze

  Unit = Struct.new(:unit_id, :name, :parent_id, :level_id, :provider, :external_ref, :retired, keyword_init: true)

  def initialize
    @levels = []
    @units = {}
  end

  # Defines or redefines the tenant's taxonomy, top level first.
  #
  # A level keeps its id through a rename. A level that still holds a live
  # unit can't be dropped, and the levels in use must keep their order, or
  # a unit would sit above its own parent.
  #
  # @param levels [Array<Hash>] each `{ level_id:, name: }`, top first
  # @param effective_on [Date, String] when the taxonomy took effect
  # @param defined_by_id [String, nil] person_id of the actor
  # @param plan_change_id [String, nil] the plan change it was applied from
  # @raise [ArgumentError] if the levels are empty, blank or duplicated
  # @raise [RuntimeError] if a level in use is dropped or reordered
  def define_taxonomy(levels, effective_on:, defined_by_id: nil, plan_change_id: nil)
    levels = normalise_levels(levels)
    return if levels == @levels

    in_use = live_units.map(&:level_id).uniq
    dropped = in_use - levels.map { |level| level[:level_id] }
    raise "Can't drop a level that still holds units: #{dropped.join(', ')}" if dropped.any?

    kept_order = level_ids(@levels) & in_use
    raise "Levels in use must keep their order" unless level_ids(levels) & in_use == kept_order

    apply(OrgGraph::Events::TaxonomyDefined.new(data: {
      levels: levels,
      previous_levels: @levels,
      effective_on: iso_date(effective_on),
      defined_by_id: defined_by_id,
      plan_change_id: plan_change_id
    }))
  end

  # Creates a unit.
  #
  # @param unit_id [String] UUID for the unit
  # @param name [String]
  # @param level_id [String] a level in the current taxonomy
  # @param parent_id [String, nil] a live unit at a higher level; nil at the top
  # @param provider [String] one of {PROVIDERS}: "espalia", or the HRIS that supplies the unit
  # @param external_ref [String, nil] the provider's own reference; required for
  #   a mirrored unit, absent for one Espalia holds
  # @param effective_on [Date, String]
  # @param created_by_id [String, nil] person_id of the actor
  # @param plan_change_id [String, nil] the plan change it was applied from
  # @raise [ArgumentError, RuntimeError] if any invariant above fails
  def create_unit(unit_id, name, level_id:, effective_on:, parent_id: nil, provider: ESPALIA,
                  external_ref: nil, created_by_id: nil, plan_change_id: nil)
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

    ensure_placeable!(provider, level_id, parent_id)

    apply(OrgGraph::Events::UnitCreated.new(data: {
      unit_id: unit_id,
      name: name,
      parent_id: parent_id,
      level_id: level_id,
      provider: provider,
      external_ref: external_ref,
      effective_on: iso_date(effective_on),
      created_by_id: created_by_id,
      plan_change_id: plan_change_id
    }))
  end

  # Renames a unit. An unchanged name writes nothing.
  #
  # @param unit_id [String]
  # @param name [String]
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param renamed_by_id [String, nil]
  # @param plan_change_id [String, nil]
  def rename_unit(unit_id, name, effective_on:, provider: ESPALIA, renamed_by_id: nil, plan_change_id: nil)
    unit = editable_unit!(unit_id, provider)
    name = require_name(name)
    return if name == unit.name

    apply(OrgGraph::Events::UnitRenamed.new(data: {
      unit_id: unit_id,
      name: name,
      previous_name: unit.name,
      provider: unit.provider,
      effective_on: iso_date(effective_on),
      renamed_by_id: renamed_by_id,
      plan_change_id: plan_change_id
    }))
  end

  # Moves a unit beneath another parent. An unchanged parent writes nothing.
  #
  # @param unit_id [String]
  # @param parent_id [String, nil] a live unit at a higher level, never the
  #   unit itself or one beneath it; nil to move it to the top
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param moved_by_id [String, nil]
  # @param plan_change_id [String, nil]
  def move_unit(unit_id, parent_id, effective_on:, provider: ESPALIA, moved_by_id: nil, plan_change_id: nil)
    unit = editable_unit!(unit_id, provider)
    return if parent_id == unit.parent_id

    raise "A unit can't sit beneath itself or a unit beneath it" if parent_id && lineage(parent_id).include?(unit_id)

    ensure_placeable!(unit.provider, unit.level_id, parent_id)

    apply(OrgGraph::Events::UnitMoved.new(data: {
      unit_id: unit_id,
      parent_id: parent_id,
      previous_parent_id: unit.parent_id,
      provider: unit.provider,
      effective_on: iso_date(effective_on),
      moved_by_id: moved_by_id,
      plan_change_id: plan_change_id
    }))
  end

  # Retires a unit. Its live sub-units must be moved or retired first.
  #
  # @param unit_id [String]
  # @param effective_on [Date, String]
  # @param provider [String] who supplies the change; must be the unit's own
  # @param retired_by_id [String, nil]
  # @param plan_change_id [String, nil]
  def retire_unit(unit_id, effective_on:, provider: ESPALIA, retired_by_id: nil, plan_change_id: nil)
    unit = editable_unit!(unit_id, provider)
    raise "Move or retire its sub-units first" if live_units.any? { |child| child.parent_id == unit_id }

    apply(OrgGraph::Events::UnitRetired.new(data: {
      unit_id: unit_id,
      provider: unit.provider,
      effective_on: iso_date(effective_on),
      retired_by_id: retired_by_id,
      plan_change_id: plan_change_id
    }))
  end

  on OrgGraph::Events::TaxonomyDefined do |event|
    @levels = event.data[:levels].map { |level| level.to_h.symbolize_keys.slice(:level_id, :name) }
  end

  on OrgGraph::Events::UnitCreated do |event|
    data = event.data
    @units[data[:unit_id]] = Unit.new(
      unit_id: data[:unit_id], name: data[:name], parent_id: data[:parent_id], level_id: data[:level_id],
      provider: data[:provider], external_ref: data[:external_ref], retired: false
    )
  end

  on OrgGraph::Events::UnitRenamed do |event|
    @units.fetch(event.data[:unit_id]).name = event.data[:name]
  end

  on OrgGraph::Events::UnitMoved do |event|
    @units.fetch(event.data[:unit_id]).parent_id = event.data[:parent_id]
  end

  on OrgGraph::Events::UnitRetired do |event|
    @units.fetch(event.data[:unit_id]).retired = true
  end

  private

  def editable_unit!(unit_id, provider)
    unit = @units[unit_id]
    raise "Unit not found" unless unit
    raise "Unit is retired" if unit.retired
    raise "#{unit.provider} supplies this unit; change it there" unless require_provider(provider) == unit.provider

    unit
  end

  # A parent must be live and at a higher level, and a mirrored unit never
  # hangs beneath one Espalia holds.
  def ensure_placeable!(provider, level_id, parent_id)
    return if parent_id.nil?

    parent = @units[parent_id]
    raise "Parent unit not found" unless parent
    raise "Parent unit is retired" if parent.retired
    raise "A parent must sit at a higher level" unless level_index(parent.level_id) < level_index(level_id)
    raise "A mirrored unit can't sit beneath a unit Espalia holds" if provider != ESPALIA && parent.provider == ESPALIA
  end

  def lineage(unit_id)
    ids = []
    while unit_id
      ids << unit_id
      unit_id = @units[unit_id]&.parent_id
    end
    ids
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

  def normalise_levels(levels)
    levels = Array(levels).map do |level|
      level = level.to_h.symbolize_keys
      { level_id: level[:level_id].to_s, name: level[:name].to_s.strip }
    end
    raise ArgumentError, "A taxonomy needs at least one level" if levels.empty?
    raise ArgumentError, "Every level needs an id and a name" if levels.any? { |level| level.values.any?(&:empty?) }
    raise ArgumentError, "Level ids must be unique" unless level_ids(levels).uniq.size == levels.size
    raise ArgumentError, "Level names must be unique" unless levels.map { |level| level[:name].downcase }.uniq.size == levels.size

    levels
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
  end
end
