# frozen_string_literal: true

# Hands a structure level Espalia holds to an HRIS field, and back (story 6.8).
#
# {#compare} reads the field live and sets it against the level's units and
# memberships. It suggests a value for each unit by name, never matches one:
# the admin confirms each match and chooses, for each unit left over, a
# successor or a retirement. {#hand_over!} writes that, all under one cause in
# one transaction, then mirrors the field once so memberships agree.
#
# Handing back keeps every unit and membership as it is, and leaves standing
# the successions and retirements the handover made.
class Hris::LevelHandover
  class Refused < StandardError; end

  RETIRE = "retire"

  Reading = Data.define(:value) do
    def field_value(*, **) = value
  end

  Comparison = Data.define(:level, :field, :provider, :units, :items, :differing, :blank, :hand_added, :joining,
                           :unresolved, :blocked, :memberships_ended, :units_retired, :held, :live_units, :preview,
                           :fingerprint) do
    def over_brake?
      Hris::BaseAdapter.over_brake?(memberships_ended, held) || Hris::BaseAdapter.over_brake?(units_retired, live_units)
    end
  end

  Handback = Data.define(:level, :provider, :units, :memberships, :fingerprint)

  # @param tenant [Tenant]
  # @param level [OrgTaxonomyLevel]
  # @param adapter [Hris::BaseAdapter]
  # @param today [Date]
  def initialize(tenant, level, adapter: Hris::BaseAdapter.for(tenant), today: Date.current)
    @tenant = tenant
    @level = level
    @adapter = adapter
    @today = today
  end

  # @param field_id [String] the HRIS field the level would come from
  # @param matches [Hash{String => String}] unit_id => the value's key the admin confirmed
  # @param resolutions [Hash{String => String}] unit_id => a matched successor's unit_id, or {RETIRE}
  # @return [Comparison]
  # @raise [Refused] when the level is not Espalia's or the field is unknown
  def compare(field_id:, matches: {}, resolutions: {})
    raise Refused, "#{@level.provider} already supplies the #{@level.name} level" unless espalia?

    field = catalogue_field(field_id)
    values = read(field)
    Comparer.new(@level, field, provider, values, units, memberships, matches.to_h.stringify_keys,
                 resolutions.to_h.stringify_keys, sub_units:, today: @today).call
  end

  # @param field_id [String]
  # @param matches [Hash{String => String}]
  # @param resolutions [Hash{String => String}]
  # @param fingerprint [String] the comparison's, as the admin saw it
  # @param confirm [Hash{Symbol => Integer}] memberships_ended: and units_retired:,
  #   required when the comparison is over the brake
  # @param actor [AuthorizationContext]
  # @return [Comparison] what was written
  # @raise [Refused] when the comparison changed, a unit is unresolved, or the
  #   counts over the brake were not confirmed
  def hand_over!(field_id:, matches:, resolutions:, fingerprint:, actor:, confirm: {})
    comparison = compare(field_id:, matches:, resolutions:)
    raise Refused, "The HRIS or the level has changed since that comparison: compare again" unless
      comparison.fingerprint == fingerprint
    raise Refused, "Match or resolve every unit first: #{comparison.unresolved.join(', ')}" if comparison.unresolved.any?
    raise Refused, "These units can't retire yet: #{comparison.blocked.map { "#{it[:name]} (#{it[:reason]})" }.join(', ')}" if
      comparison.blocked.any?
    confirm_counts!(comparison, confirm) if comparison.over_brake?

    cause_id = SecureRandom.uuid_v7
    ActiveRecord::Base.transaction do
      resolve(comparison, matches.to_h.stringify_keys, resolutions.to_h.stringify_keys, actor, cause_id)
      OrgGraph::StructureCommandHandler.new(actor:, cause_id:).hand_over_level(
        @level.id, provider, field: comparison.field.id, effective_on: @today,
        matches: matches.to_h.stringify_keys.to_h { |unit_id, key| [ unit_id, "#{comparison.field.id}/#{key}" ] }
      )
      take_memberships(comparison, actor, cause_id)
      mirror(comparison, cause_id)
    end
    comparison
  end

  # @return [Handback] what handing the level back would keep
  # @raise [Refused] when Espalia already holds the level
  def compare_handback
    raise Refused, "Espalia already holds the #{@level.name} level" if espalia?

    held = units.map(&:id)
    rows = OrgMembership.where(unit_id: held).order(:id).pluck(:id, :person_id, :unit_id, :provider)
    Handback.new(level: @level, provider: @level.provider, units: held.size, memberships: rows.size,
                 fingerprint: digest([ @level.id, @level.provider, @level.provider_field, held.sort, rows ]))
  end

  # @param fingerprint [String] the hand-back comparison's
  # @param actor [AuthorizationContext]
  # @return [Handback]
  # @raise [Refused] when the level changed since the comparison
  def hand_back!(fingerprint:, actor:)
    handback = compare_handback
    raise Refused, "The level has changed since that comparison: compare again" unless handback.fingerprint == fingerprint

    cause_id = SecureRandom.uuid_v7
    ActiveRecord::Base.transaction do
      OrgGraph::StructureCommandHandler.new(actor:, cause_id:).hand_back_level(@level.id, effective_on: @today)
      people = OrgGraph::CommandHandler.new(actor:, cause_id:)
      OrgMembership.where(unit_id: units.map(&:id), provider: handback.provider).find_each do |membership|
        people.set_membership(membership.person_id, membership.unit_id, provider: OrgGraph::StructureAggregate::ESPALIA,
                              allocation: membership.allocation, role: membership.role, effective_on: @today)
      end
      Hris::LevelMirror.forget_parent_readings([ @level ])
    end
    handback
  end

  # @return [Boolean] whether Espalia holds the level, so it can be handed over
  def espalia? = @level.provider.nil? || @level.provider == OrgGraph::StructureAggregate::ESPALIA

  private

  def provider = @adapter.provider_name

  def units = OrgUnit.live.where(level_id: @level.id).order(:name).to_a

  def memberships = OrgMembership.in_live_units.where(unit_id: units.map(&:id)).to_a

  # Live units at any level whose parent is one of this level's.
  def sub_units = OrgUnit.live.where(parent_id: units.map(&:id)).pluck(:parent_id).to_set

  def catalogue_field(field_id)
    id = @adapter.catalogue_id(field_id)
    @adapter.field_catalogue.find { it.id == id } or raise Refused, "The HRIS has no field #{field_id}"
  end

  # A list value whose item the HRIS no longer offers reads as withheld, as
  # the mirror reads it, so nobody is handed a unit the mirror would not keep.
  #
  # @return [Hash{Person => Hris::FieldValue}] the people the sync writes for
  def read(field)
    by_external_id = @adapter.read_field(field.id, kind: field.kind)
    live_keys = field.values.to_set { it.id.to_s } if field.list?
    Person.where(hris_source: provider, status: "active", external_id: by_external_id.keys).order(:id).to_h do |person|
      value = by_external_id.fetch(person.external_id)
      [ person, value.value? && live_keys && !live_keys.include?(value.key) ? Hris::FieldValue.withheld : value ]
    end
  end

  def confirm_counts!(comparison, confirm)
    asked = { memberships_ended: comparison.memberships_ended, units_retired: comparison.units_retired }
    return if asked.all? { |key, count| confirm[key] == count }

    raise Refused, "This handover ends #{asked[:memberships_ended]} memberships and retires #{asked[:units_retired]} units, " \
                   "over the brake: confirm both counts to go ahead"
  end

  def resolve(comparison, matches, resolutions, actor, cause_id)
    structure = OrgGraph::StructureCommandHandler.new(actor:, cause_id:)
    comparison.units.reject { matches.key?(it[:unit_id]) }.each do |unit|
      resolution = resolutions.fetch(unit[:unit_id])
      if resolution == RETIRE
        structure.retire_unit(unit[:unit_id], effective_on: @today)
      else
        structure.record_succession(SecureRandom.uuid_v7, predecessor_ids: [ unit[:unit_id] ], successor_ids: [ resolution ],
                                    retire_predecessors: true, effective_on: @today)
      end
    end
  end

  # A person the HRIS reads at the level now holds their membership from it,
  # so the sync can move or end it. A hand-added member keeps Espalia's.
  def take_memberships(comparison, actor, cause_id)
    known = comparison.preview[:readings].reject { |_, value| value.withheld? || value.unreadable? }.keys.to_set(&:id)
    people = OrgGraph::CommandHandler.new(actor:, cause_id:)
    OrgMembership.in_live_units.where(unit_id: OrgUnit.where(level_id: @level.id), person_id: known.to_a)
      .where(provider: OrgGraph::StructureAggregate::ESPALIA).find_each do |membership|
      people.set_membership(membership.person_id, membership.unit_id, provider:, allocation: membership.allocation,
                            role: membership.role, effective_on: @today)
    end
  end

  def mirror(comparison, cause_id)
    result = { errors: [], split_units: [], org_graph_events: 0 }
    Hris::LevelMirror.new(provider:, catalogue: [ comparison.field ], levels: [ @level.reload ], today: @today, cause_id:,
                          brake: false, readings: comparison.preview[:readings].transform_values { Reading.new(it) }, result:).call
    raise Refused, "The handover could not mirror the field: #{result[:errors].map { it[:error] }.uniq.join('; ')}" if
      result[:errors].any?
  end

  def digest(parts) = Digest::SHA256.hexdigest(parts.to_json).first(16)

  # Sets the field's values against the level, for {#compare}.
  class Comparer
    def initialize(level, field, provider, values, units, memberships, matches, resolutions, sub_units:, today:)
      @level = level
      @field = field
      @provider = provider
      @values = values
      @units = units
      @memberships = memberships
      @matches = matches
      @resolutions = resolutions
      @sub_units = sub_units
      @today = today
    end

    def call
      items = item_rows
      by_key = items.index_by { it[:key] }
      unit_of_key = @matches.invert
      Comparison.new(
        level: @level, field: @field, provider: @provider, units: unit_rows(by_key), items: items.map { it.merge(unit_id: unit_of_key[it[:key]]) },
        differing:, blank:, hand_added:, joining:, unresolved:, blocked:, memberships_ended:, units_retired: retiring.size,
        held: @memberships.size, live_units: @units.size, preview:, fingerprint:
      )
    end

    private

    def values_by_person = @values_by_person ||= @values.to_h { |person, value| [ person.id, value ] }

    def item_rows = @item_rows ||= build_item_rows

    def members_of(unit) = (@members_by_unit ||= @memberships.group_by(&:unit_id)).fetch(unit.id, [])

    def build_item_rows
      counts = @values.values.select(&:value?).group_by(&:key)
      rows = if @field.list?
        @field.values.map { |item| { key: item.id.to_s, label: item.name, people: counts.fetch(item.id.to_s, []).size } }
      else
        counts.map { |key, group| { key: key, label: group.first.label.presence || key, people: group.size } }
      end
      rows.sort_by { [ -it[:people], it[:label].to_s.downcase ] }
    end

    def unit_rows(by_key)
      @units.map do |unit|
        members = members_of(unit)
        held = members.filter_map { values_by_person[it.person_id] }.select(&:value?).group_by(&:key)
          .map { |key, group| { key:, label: by_key.dig(key, :label) || key, people: group.size } }
          .sort_by { [ -it[:people], it[:label].to_s.downcase ] }.first(3)
        { unit_id: unit.id, name: unit.name, members: members.size, suggestion: suggestion(unit, by_key), held:,
          match: @matches[unit.id], resolution: @resolutions[unit.id] }
      end
    end

    def suggestion(unit, by_key)
      name = normalise(unit.name)
      item = by_key.values.find { normalise(it[:label]) == name }
      item&.slice(:key, :label)
    end

    def normalise(text) = text.to_s.unicode_normalize(:nfkc).downcase.squish

    # The key the member's unit has after the switch: its own match, or the
    # match of the unit it is succeeded into.
    def matched_key(membership) = @matches[membership.unit_id] || @matches[@resolutions[membership.unit_id]]

    def differing
      @memberships.filter_map do |membership|
        value = values_by_person[membership.person_id]
        next unless value&.value? && matched_key(membership) != value.key

        { person_id: membership.person_id, unit_id: membership.unit_id, key: value.key, label: value.label }
      end
    end

    def blank
      @memberships.filter_map do |membership|
        { person_id: membership.person_id, unit_id: membership.unit_id } if values_by_person[membership.person_id]&.blank?
      end
    end

    def hand_added
      @memberships.filter_map do |membership|
        value = values_by_person[membership.person_id]
        { person_id: membership.person_id, unit_id: membership.unit_id } if value.nil? || value.withheld? || value.unreadable?
      end
    end

    def joining
      members = @memberships.map(&:person_id).to_set
      values_by_person.count { |person_id, value| value.value? && !members.include?(person_id) }
    end

    def retiring = @units.reject { @matches.key?(it.id) }

    def unresolved
      matched = @matches.keys.to_set
      shared = @matches.values.tally.select { |_, count| count > 1 }.keys.to_set
      bad_matches = @matches.reject do |unit_id, key|
        @units.any? { it.id == unit_id } && item_keys.include?(key) && !shared.include?(key)
      end.keys
      unresolved = retiring.reject do |unit|
        resolution = @resolutions[unit.id]
        resolution == RETIRE || matched.include?(resolution)
      end
      (bad_matches.filter_map { |id| @units.find { it.id == id }&.name || id } + unresolved.map(&:name)).uniq
    end

    # A unit the switch retires must be free to retire today, or the handover
    # would fail partway through its writes.
    def blocked
      retiring.filter_map do |unit|
        reason = if @sub_units.include?(unit.id) then "it has live sub-units"
        elsif last_change(unit) > @today then "it changes on #{last_change(unit)}"
        end
        { unit_id: unit.id, name: unit.name, reason: } if reason
      end
    end

    def last_change(unit) = [ unit.created_on, unit.name_effective_on, unit.parent_effective_on ].compact.max

    def item_keys = @item_keys ||= item_rows.map { it[:key] }.to_set

    # Memberships the switch ends with nothing in their place: a blank value,
    # or a retired unit whose member the HRIS gives no value.
    def memberships_ended
      retired = retiring.select { @resolutions[it.id] == RETIRE }.map(&:id).to_set
      @memberships.count do |membership|
        value = values_by_person[membership.person_id]
        value&.blank? || (retired.include?(membership.unit_id) && !value&.value?)
      end
    end

    def preview
      { readings: @values, people: @values.size, units: item_rows.count { it[:people].positive? },
        blank: @values.values.count(&:blank?), withheld: @values.values.count(&:withheld?),
        unreadable: @values.values.count(&:unreadable?) }
    end

    def fingerprint
      Digest::SHA256.hexdigest([
        @level.id, @field.id, item_rows, @values.map { |person, value| [ person.id, value.key, value.blank?, value.value? ] },
        @units.map { [ it.id, it.name ] }, @memberships.map { [ it.person_id, it.unit_id, it.provider ] }.sort,
        @matches.sort, @resolutions.sort
      ].to_json).first(16)
    end
  end
end
