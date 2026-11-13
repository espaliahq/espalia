# frozen_string_literal: true

# One unit's activity as the sidebar and its MCP read show it: a page of
# groups, newest first, each with its parts in words and the reason, if any,
# it can't be changed back by the person reading it.
#
# People are read through {Person}, so a forgotten person reads as
# {Person::FORMER_MEMBER}.
class OrgGraph::ActivityFeed
  PER_PAGE = 25

  # A group of entries under one cause, as the person reading it may act on it.
  #
  # @!attribute group [OrgUnitActivity::Group]
  # @!attribute parts [Array<Part>] newest first
  # @!attribute refusal [String, nil] why the whole group can't be changed back
  Item = Data.define(:group, :parts, :refusal) do
    # @return [Boolean]
    def changeable? = refusal.nil?
  end

  # @!attribute entry [OrgUnitActivity]
  # @!attribute description [String] what it did, e.g. "Moved Ada Quill in from Checkout"
  # @!attribute by [String] the person who made it, or the provider that supplied it
  # @!attribute refusal [String, nil]
  Part = Data.define(:entry, :description, :by, :refusal) do
    # @return [Boolean]
    def changeable? = refusal.nil?
  end

  attr_reader :unit, :page

  # @param unit [OrgUnit]
  # @param actor [AuthorizationContext] whose rights decide what can be changed back
  # @param page [Integer] from 1
  def initialize(unit:, actor:, page: 1)
    @unit = unit
    @page = page.to_i.clamp(1..)
    @change_back = OrgGraph::ChangeBackHandler.new(actor:)
  end

  # @return [Array<Item>]
  def items = @items ||= groups.map { |group| item(group) }

  # @return [Boolean]
  def next_page? = OrgUnitActivity.for_unit(unit.id).distinct.count(:cause_id) > page * PER_PAGE

  # @param part [OrgUnitActivity]
  # @return [String] the person who made the change, or the provider that supplied it
  def self.by(part)
    return part.actor&.name || Person::FORMER_MEMBER if part.actor_id

    HrisConfig.provider_label(part.provider || OrgGraph::StructureAggregate::ESPALIA)
  end

  private

  def groups
    @groups ||= OrgUnitActivity.feed(unit.id, page:, per_page: PER_PAGE).tap { preload(it) }
  end

  def preload(groups)
    ActiveRecord::Associations::Preloader.new(records: groups.flat_map(&:parts), associations: %i[person actor other_unit]).call
  end

  def item(group)
    parts = group.parts.map do |entry|
      Part.new(entry:, description: describe(entry), by: self.class.by(entry), refusal: @change_back.refusal(entry))
    end
    Item.new(group:, parts:, refusal: group.parts.one? ? parts.first.refusal : @change_back.group_refusal(group.cause_id))
  end

  def describe(entry)
    person = entry.person&.name || Person::FORMER_MEMBER
    case entry.event_type
    when "MembershipSet" then entry.before ? "Changed #{person}'s terms" : "Added #{person}"
    when "MembershipEnded" then "Removed #{person}"
    when "MembershipMoved" then moved(entry, person)
    when "UnitCreated" then "Created the unit"
    when "UnitRenamed" then "Renamed it from #{entry.before['name']} to #{entry.after['name']}"
    when "UnitMoved" then "Moved the unit #{parent_phrase(entry.after['parent_id'])}"
    when "UnitOwnerAdded" then "Made #{person} an owner"
    when "UnitOwnerRemoved" then "Removed #{person} as an owner"
    when "UnitRetired" then "Retired the unit"
    else OrgUnitActivity::Group.new([ entry ]).summary.upcase_first
    end
  end

  def moved(entry, person)
    other = entry.other_unit&.name || "another unit"
    entry.after ? "Moved #{person} in from #{other}" : "Moved #{person} out to #{other}"
  end

  def parent_phrase(parent_id)
    parent = parent_id && OrgUnit.find_by(id: parent_id)
    parent ? "under #{parent.name}" : "to the top"
  end
end
