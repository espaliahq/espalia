# frozen_string_literal: true

# What choosing an HRIS field would give, before anyone chooses it (#107).
#
# Reads the field live for the people the next sync places and counts what
# it finds. It writes nothing: no event, no row, no cached value.
#
# For a level, each distinct value is a unit, told apart as the mirror (#100)
# tells them apart: a list item's id, else the text. For a fact, each value is
# compared with what the person's Org Graph stream holds now. A withheld or
# unreadable person is never compared, the rule the sync follows.
class Integrations::HrisFieldPreview
  LEVEL = "level"
  # The fact parts a field can be chosen for, as the sync names them.
  FACTS = OrgGraph::StructureAggregate::MAPPABLE_FIELDS.values.flatten.freeze
  TARGETS = [ LEVEL, *FACTS ].freeze

  class UnknownField < StandardError; end

  Unit = Data.define(:label, :people)
  # @!attribute [r] units
  #   @return [Array<Unit>] largest first
  Level = Data.define(:field, :people, :units, :blank, :withheld, :unreadable)
  Fact = Data.define(:field, :target, :people, :with_value, :blank, :withheld, :unreadable, :would_change)

  # @param tenant [Tenant]
  # @param field_id [String] the field's catalogue id
  # @param target [String] one of {TARGETS}
  # @param adapter [Hris::BaseAdapter]
  # @param repository [OrgGraph::Repository]
  def initialize(tenant, field_id:, target:, adapter: Hris::BaseAdapter.for(tenant), repository: OrgGraph::Repository.new)
    raise ArgumentError, "Unknown preview target: #{target.inspect}" unless TARGETS.include?(target)

    @tenant = tenant
    @field_id = field_id
    @target = target
    @adapter = adapter
    @repository = repository
  end

  # @return [Level, Fact]
  # @raise [UnknownField] when the catalogue holds no such field
  def call
    field = catalogue_field
    values = held_values(adapter.read_field(field.id, kind: field.kind, alongside:))
    target == LEVEL ? level(field, values) : fact(field, values)
  end

  private

  attr_reader :tenant, :field_id, :target, :adapter, :repository

  # The fact the sync writes the target only beside, as country with site.
  def alongside
    OrgGraph::StructureAggregate::MAPPABLE_FIELDS.find { |base, parts| base != target && parts.include?(target) }&.first
  end

  def catalogue_field
    id = adapter.catalogue_id(field_id)
    adapter.field_catalogue.find { it.id == id } or raise UnknownField, "The HRIS has no field #{field_id}"
  end

  # Each person the adapter read, whom the next sync places, beside their
  # value. The adapter applies the sync's rule; this only finds their row,
  # matched by id as the sync matches it.
  #
  # @param by_external_id [Hash{String => Hris::FieldValue}]
  # @return [Array<(String, Hris::FieldValue)>] the row's id, or nil for a
  #   person the sync has yet to create or link by email, beside their value
  def held_values(by_external_id)
    rows = ActsAsTenant.with_tenant(tenant) { Person.where(external_id: by_external_id.keys).pluck(:external_id, :id).to_h }
    by_external_id.map { |external_id, value| [ rows[external_id], value ] }
  end

  def level(field, values)
    units = values.map(&:last).select(&:value?).group_by(&:key).map do |_, group|
      Unit.new(label: group.first.label, people: group.size)
    end
    Level.new(field:, people: values.size, units: units.sort_by { [ -it.people, it.label.downcase ] },
      **tally(values))
  end

  def fact(field, values)
    changing = ActsAsTenant.with_tenant(tenant) do
      values.count do |person_id, value|
        held = repository.load_person(person_id).fact(target) if person_id
        (value.value? || value.blank?) && held != (value.label if value.value?)
      end
    end
    Fact.new(field:, target:, people: values.size, with_value: values.count { it.last.value? }, would_change: changing,
      **tally(values))
  end

  def tally(values)
    { blank: values.count { it.last.blank? }, withheld: values.count { it.last.withheld? },
      unreadable: values.count { it.last.unreadable? } }
  end
end
