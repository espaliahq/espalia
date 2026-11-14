# frozen_string_literal: true

# Event-sourced aggregate for one plan.
#
# One RES stream per plan: tenant-{tenant_id}/Plan-{plan_id}. A plan stands on
# the Org Graph as of its base date, read as known at the end of the day
# before (decision 3 in docs/team-planning/team-planning-plan.md). Once
# deleted, it takes no more changes.
#
class TeamPlanning::PlanAggregate
  include AggregateRoot

  NAME_LIMIT = 120

  # @return [String, nil]
  attr_reader :plan_id, :name, :base_on, :created_by_id

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
  # @raise [TeamPlanning::Error] if the plan is gone
  def delete(deleted_by_id:)
    ensure_open!

    apply(TeamPlanning::Events::PlanDeleted.new(data: { plan_id: @plan_id, deleted_by_id: deleted_by_id }))
  end

  # @return [Boolean] whether the plan has been created
  def exists? = !@plan_id.nil?

  # @return [Boolean]
  def deleted? = @deleted == true

  on TeamPlanning::Events::PlanCreated do |event|
    @plan_id = event.data[:plan_id]
    @name = event.data[:name]
    @base_on = Date.iso8601(event.data[:base_on])
    @created_by_id = event.data[:created_by_id]
  end

  on TeamPlanning::Events::PlanRenamed do |event|
    @name = event.data[:name]
  end

  on TeamPlanning::Events::PlanDeleted do |_event|
    @deleted = true
  end

  private

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
