# frozen_string_literal: true

# Event-sourced aggregate for one plan.
#
# One RES stream per plan: tenant-{tenant_id}/Plan-{plan_id}. A plan stands on
# the Org Graph as of its base date, read as known at the end of the day
# before (decision 3 in docs/team-planning/team-planning-plan.md). Once
# deleted, it takes no more changes.
#
# Its members are editors or viewers, and its creator is its first editor. A
# plan always keeps an editor: the last one can neither leave nor become a
# viewer.
#
class TeamPlanning::PlanAggregate
  include AggregateRoot

  NAME_LIMIT = 120
  ROLES = %w[editor viewer].freeze

  # @return [String, nil]
  attr_reader :plan_id, :name, :base_on, :created_by_id

  def initialize
    @members = {}
  end

  # Opens the plan.
  #
  # @param plan_id [String] UUID minted by the caller
  # @param name [String]
  # @param base_on [Date, String] the day the plan stands on
  # @param created_by_id [String] person_id of the creator
  # @raise [TeamPlanning::Error] if the plan exists, or the name is blank or too long
  # @raise [Date::Error] unless base_on is a Date or a YYYY-MM-DD string
  def create(plan_id, name:, base_on:, created_by_id:)
    raise TeamPlanning::Error, "This plan already exists" if @plan_id

    apply(TeamPlanning::Events::PlanCreated.new(data: {
      plan_id: plan_id,
      name: require_name(name),
      base_on: require_date(base_on).iso8601,
      created_by_id: created_by_id
    }))
  end

  # Renames the plan. The same name writes nothing.
  #
  # @param name [String]
  # @param renamed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, or the name is blank or too long
  def rename(name, renamed_by_id:)
    ensure_open!
    name = require_name(name)
    return if name == @name

    apply(TeamPlanning::Events::PlanRenamed.new(data: {
      plan_id: @plan_id, name: name, previous_name: @name, renamed_by_id: renamed_by_id
    }))
  end

  # Deletes the plan.
  #
  # @param deleted_by_id [String]
  # @param reason [String, nil] why, when a tenant admin deletes a frozen plan
  # @raise [TeamPlanning::Error] if the plan is gone
  def delete(deleted_by_id:, reason: nil)
    ensure_open!

    apply(TeamPlanning::Events::PlanDeleted.new(data: {
      plan_id: @plan_id, deleted_by_id: deleted_by_id, reason: reason.to_s.squish.presence
    }.compact))
  end

  # Makes someone a member, or gives a member another role. The role they
  # already have writes nothing.
  #
  # @param person_id [String]
  # @param role [String] "editor" or "viewer"
  # @param added_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, the role is unknown, or
  #   this would leave the plan without an editor
  def add_member(person_id, role:, added_by_id:)
    ensure_open!
    role = role.to_s
    raise TeamPlanning::Error, "A member is an editor or a viewer" unless ROLES.include?(role)
    return if @members[person_id] == role

    ensure_editor_remains!(person_id) if role == "viewer"
    apply(TeamPlanning::Events::PlanMemberAdded.new(data: {
      plan_id: @plan_id, person_id: person_id, role: role, added_by_id: added_by_id
    }))
  end

  # Takes someone off the plan, or lets them leave it.
  #
  # @param person_id [String]
  # @param removed_by_id [String]
  # @raise [TeamPlanning::Error] if the plan is gone, they aren't a member, or
  #   they are its last editor
  def remove_member(person_id, removed_by_id:)
    ensure_open!
    raise TeamPlanning::Error, "They aren't a member of this plan" unless member?(person_id)

    ensure_editor_remains!(person_id)
    apply(TeamPlanning::Events::PlanMemberRemoved.new(data: {
      plan_id: @plan_id, person_id: person_id, removed_by_id: removed_by_id
    }))
  end

  # @return [Hash{String => String}] person_id to role
  def members = @members.dup

  # @param person_id [String, nil]
  # @return [String, nil] "editor", "viewer", or nil for a non-member
  def role_of(person_id) = @members[person_id]

  # @param person_id [String, nil]
  # @return [Boolean]
  def member?(person_id) = @members.key?(person_id)

  # @return [Array<String>] person ids
  def editor_ids = @members.select { |_, role| role == "editor" }.keys

  # @return [Boolean] whether the plan has been created
  def exists? = !@plan_id.nil?

  # @return [Boolean]
  def deleted? = @deleted == true

  on TeamPlanning::Events::PlanCreated do |event|
    @plan_id = event.data[:plan_id]
    @name = event.data[:name]
    @base_on = Date.iso8601(event.data[:base_on])
    @created_by_id = event.data[:created_by_id]
    @members[@created_by_id] = "editor"
  end

  on TeamPlanning::Events::PlanMemberAdded do |event|
    @members[event.data[:person_id]] = event.data[:role]
  end

  on TeamPlanning::Events::PlanMemberRemoved do |event|
    @members.delete(event.data[:person_id])
  end

  on TeamPlanning::Events::PlanRenamed do |event|
    @name = event.data[:name]
  end

  on TeamPlanning::Events::PlanDeleted do |_event|
    @deleted = true
  end

  private

  def ensure_editor_remains!(person_id)
    return unless editor_ids == [ person_id ]

    raise TeamPlanning::Error, "A plan needs an editor: make someone else an editor first"
  end

  def ensure_open!
    raise TeamPlanning::Error, "No such plan" unless exists?
    raise TeamPlanning::Error, "#{@name} has been deleted" if deleted?
  end

  def require_date(value)
    return value if value.is_a?(Date)
    raise Date::Error, "invalid date: #{value.inspect}" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value)
  end

  def require_name(name)
    name = name.to_s.squish
    raise TeamPlanning::Error, "A plan needs a name" if name.empty?
    raise TeamPlanning::Error, "A plan's name can be at most #{NAME_LIMIT} characters" if name.length > NAME_LIMIT

    name
  end
end
