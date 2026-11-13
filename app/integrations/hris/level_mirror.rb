# frozen_string_literal: true

# Mirrors the structure levels an HRIS provides from what each person's record
# holds for the level's field (story 6.7).
#
# For each mirrored level, top first:
#
# - **Units.** Each value someone holds is a unit, created at the level and
#   keyed by "<field>/<value key>". A list item's new name renames its unit.
#   A list item that is archived or gone retires its unit, and so does a text
#   value nobody holds any more. {OrgGraph::SyncHandlers::RetiredUnitMemberships}
#   ends what a retired unit still holds.
# - **Memberships.** A value sets or moves the person's membership at the
#   level; a value sent blank ends it; a record that withholds the field
#   changes nothing for that person. A person Espalia holds a membership
#   for at the level is left alone.
# - **Parents.** A unit sits under the unit at the level above that all its
#   people with a value there share. A unit whose people disagree keeps its
#   parent, or is created with none, and is listed in the result's
#   :split_units. A parent changes only when two syncs in a row read the same
#   one ({HrisUnitParentProposal}). A new unit takes the parent read when it
#   is created.
#
# Retirements and ended memberships each have their own brake, as
# {Hris::BaseAdapter::ABSENCE_BRAKE} has for people: over it, none of that
# kind is written and the result says why.
#
# Every unit-level change and every person's membership change is its own
# cause, written by SYSTEM with the HRIS as provider, dated the sync's day.
#
class Hris::LevelMirror
  # @param provider [String]
  # @return [Array<OrgTaxonomyLevel>] the levels the provider supplies from a field, top first
  def self.levels(provider)
    OrgTaxonomyLevel.top_first.where(provider: provider).where.not(provider_field: nil).to_a
  end

  # @param provider [String] the HRIS, such as "hibob"
  # @param catalogue [Array<Hris::Field>] the HRIS's field catalogue
  # @param readings [Hash{Person => #field_value}] each current person's
  #   record, read through the provider's mapper; a leaver is left out
  # @param result [Hash] the sync's running tally
  # @param levels [Array<OrgTaxonomyLevel>] the levels to mirror, as {.levels} gives them
  # @param today [Date]
  def initialize(provider:, catalogue:, readings:, result:, levels: self.class.levels(provider), today: Date.current)
    @provider = provider
    @levels = levels
    @fields = catalogue.index_by(&:id)
    @readings = readings
    @result = result
    @today = today
    @units = {}
  end

  # @return [void]
  def call
    return if @levels.empty?

    taxonomy = OrgTaxonomyLevel.top_first.pluck(:id)
    plans = @levels.filter_map { |level| plan(level, taxonomy) }
    @plans = plans.index_by { it.level.id }
    @proposals = HrisUnitParentProposal.where(unit_id: OrgUnit.where(level_id: plans.map { it.level.id })).index_by(&:unit_id)
    plans.each { |level_plan| mirror_units(level_plan) }
    write_memberships(plans)
    retire_units(plans)
  end

  private

  LevelPlan = Struct.new(:level, :field, :above_id, :values, :held, :withheld, :live_keys, keyword_init: true)

  def plan(level, taxonomy)
    field = @fields[level.provider_field]
    unless field
      @result[:errors] << { error: "#{@provider} has no field #{level.provider_field} for the #{level.name} level, so it was not mirrored" }
      return
    end
    # A list whose items HiBob didn't send would read every value as archived.
    if field.list? && field.values.empty?
      @result[:errors] << { error: "#{@provider} sent no items for #{field.name}, so the #{level.name} level was not mirrored" }
      return
    end

    live_keys = field.list? ? field.values.to_h { [ it.id, it.name ] } : nil
    values = @readings.to_h { |person, mapper| [ person, mapper.field_value(field.id, kind: field.kind) ] }
    values.transform_values! { |value| value.value? && live_keys && !live_keys.key?(value.key) ? Hris::FieldValue.withheld : value }

    index = taxonomy.index(level.id)
    LevelPlan.new(level:, field:, above_id: (taxonomy[index - 1] if index.positive?), values:,
                  held: values.values.select(&:value?).group_by(&:key), withheld: values.values.any? { !it.value? && !it.blank? }, live_keys:)
  end

  def mirror_units(level_plan)
    units = live_units(level_plan).index_by(&:external_ref)
    @units[level_plan.level.id] = units

    level_plan.held.each do |key, values|
      ref = reference(level_plan, key)
      name = level_plan.live_keys&.dig(key).presence || values.first.label.presence || key
      parent = parent_reading(level_plan, key)

      if (unit = units[ref])
        rename(unit, name) if level_plan.field.list?
        reparent(unit, parent)
      else
        units[ref] = create(level_plan, ref, name, parent)
      end
    rescue => e
      @result[:errors] << { unit: ref, error: e.message }
    end
  end

  # @return [String, nil, :split] the one parent the unit's people share, nil
  #   when none of them has a value at the level above, :split when they differ
  def parent_reading(level_plan, key)
    above_plan = @plans[level_plan.above_id]
    return unless above_plan

    above = @units.fetch(above_plan.level.id)
    parents = level_plan.values.filter_map do |person, value|
      next unless value.value? && value.key == key

      above_value = above_plan.values[person]
      above[reference(above_plan, above_value.key)]&.id if above_value.value?
    end.uniq
    parents.many? ? :split : parents.first
  end

  def create(level_plan, ref, name, parent)
    unit_id = SecureRandom.uuid_v7
    if parent == :split
      parent = nil
      @result[:split_units] << { unit_id:, name: }
    end
    structure.create_unit(unit_id, name, level_id: level_plan.level.id, parent_id: parent, provider: @provider,
                          external_ref: ref, effective_on: @today)
    counted
    OrgUnit.find(unit_id)
  end

  def rename(unit, name)
    return if unit.name == name

    structure.rename_unit(unit.id, name, provider: @provider, effective_on: @today)
    counted
  end

  def reparent(unit, parent)
    proposal = @proposals[unit.id]
    if parent.nil?
      proposal&.destroy!
    elsif parent == :split
      proposal&.destroy!
      @result[:split_units] << { unit_id: unit.id, name: unit.name }
    elsif parent == unit.parent_id
      proposal&.destroy!
    elsif proposal&.parent_id == parent
      structure.move_unit(unit.id, parent, provider: @provider, effective_on: @today)
      proposal.destroy!
      counted
    else
      (proposal || HrisUnitParentProposal.new(unit_id: unit.id)).update!(parent_id: parent, first_seen_on: @today)
    end
  end

  def write_memberships(plans)
    changes = plans.flat_map { |level_plan| membership_changes(level_plan) }
    ends, others = changes.partition { |change| change[:action] == :end }
    held = OrgMembership.where(provider: @provider, unit_id: OrgUnit.where(level_id: plans.map { it.level.id })).count
    ends = [] if braked?(ends.size, held, "memberships would end", "no membership was ended")

    (others + ends).each { |change| write_membership(change) }
  end

  def membership_changes(level_plan)
    units = @units.fetch(level_plan.level.id)
    current = OrgMembership.in_live_units.where(unit_id: OrgUnit.where(level_id: level_plan.level.id)).group_by(&:person_id)

    level_plan.values.filter_map do |person, value|
      memberships = current.fetch(person.id, [])
      next if memberships.any? { it.provider != @provider }

      membership = memberships.first
      if value.value?
        target = units[reference(level_plan, value.key)]
        next if target.nil? || membership&.unit_id == target.id

        membership ? { action: :move, person:, from: membership.unit_id, to: target.id } : { action: :set, person:, to: target.id }
      elsif value.blank? && membership
        { action: :end, person:, from: membership.unit_id }
      end
    end
  end

  def write_membership(change)
    people = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: SecureRandom.uuid_v7)
    person_id = change[:person].id
    case change[:action]
    when :set then people.set_membership(person_id, change[:to], provider: @provider, effective_on: @today)
    when :move then people.move_membership(person_id, change[:from], change[:to], effective_on: @today)
    when :end then people.end_membership(person_id, change[:from], provider: @provider, effective_on: @today)
    end
    counted
  rescue => e
    @result[:errors] << { person_id: person_id, error: e.message }
  end

  def retire_units(plans)
    retiring = plans.reverse.flat_map do |level_plan|
      @units.fetch(level_plan.level.id).values.reject { |unit| kept?(level_plan, unit) }
    end
    live = plans.sum { |level_plan| @units.fetch(level_plan.level.id).size }
    return if braked?(retiring.size, live, "mirrored units would retire", "no unit was retired")

    retiring.each do |unit|
      structure.retire_unit(unit.id, provider: @provider, effective_on: @today)
      @proposals[unit.id]&.destroy!
      counted
    rescue => e
      @result[:errors] << { unit_id: unit.id, error: e.message }
    end
  end

  # A text value nobody is seen holding may still be held by someone whose
  # record withheld the field, so its unit stays until every record is read.
  def kept?(level_plan, unit)
    prefix = "#{level_plan.field.id}/"
    return false unless unit.external_ref.start_with?(prefix)

    key = unit.external_ref.delete_prefix(prefix)
    level_plan.live_keys ? level_plan.live_keys.key?(key) : level_plan.held.key?(key) || level_plan.withheld
  end

  def braked?(count, of, what, outcome)
    return false unless count > Hris::BaseAdapter::ABSENCE_BRAKE[:people] && count > of * Hris::BaseAdapter::ABSENCE_BRAKE[:share]

    @result[:errors] << { error: "#{count} of #{of} #{what}, more than #{(Hris::BaseAdapter::ABSENCE_BRAKE[:share] * 100).round}% " \
                                 "and #{Hris::BaseAdapter::ABSENCE_BRAKE[:people]}, so #{outcome}" }
    true
  end

  def live_units(level_plan)
    OrgUnit.live.where(level_id: level_plan.level.id, provider: @provider).to_a
  end

  def reference(level_plan, key) = "#{level_plan.field.id}/#{key}"

  def structure
    OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM, cause_id: SecureRandom.uuid_v7)
  end

  def counted = @result[:org_graph_events] += 1
end
