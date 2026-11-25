# frozen_string_literal: true

# Event-sourced aggregate for a tenant's retention period and scheduled
# forgetting.
#
# One RES stream per tenant: tenant-{tenant_id}/TenantSettings. It starts
# where a tenant that never changed anything stands: leavers are forgotten
# seven years after they leave, and nothing is forgotten on a schedule.
#
# A period that makes more people due turns scheduled forgetting off in the
# same commit, so turning it back on confirms a fresh count. Setting the
# period it already has, or turning off what is off, writes nothing.
#
class TenantSettings::Aggregate
  include Shreddable::AggregateRoot

  # Turning scheduled forgetting on when the guards don't allow it.
  class Refused < StandardError; end

  # Where every stream starts, so frozen like an event's shape: a tenant
  # that never set a period records nothing, and a new default would move
  # them all without an event.
  DEFAULT_RETENTION_YEARS = 7

  # @return [Integer, nil] years after leaving that a person is forgotten, nil for never
  attr_reader :retention_years
  # @return [Time, nil] when scheduled forgetting was turned on, nil while it is off
  attr_reader :enabled_at
  # @return [String, nil] person_id of whoever turned it on, nil while off or when not known
  attr_reader :enabled_by_id

  def initialize
    @retention_years = DEFAULT_RETENTION_YEARS
    @scheduled_forgetting = false
    @recorded = false
  end

  # @return [Boolean] whether leavers are forgotten on a schedule
  def scheduled_forgetting? = @scheduled_forgetting

  # @return [Boolean] whether the stream holds any event, so a projection writes a row
  def recorded? = @recorded

  # @param years [Integer, nil] nil for never
  # @param set_by_id [String, nil] person_id of the actor
  # @return [Boolean] whether the change turned scheduled forgetting off
  def set_retention_period(years, set_by_id: nil)
    return false if years == retention_years

    shortened = scheduled_forgetting? && sooner?(years)
    apply(TenantSettings::Events::RetentionPeriodSet.new(data: {
      retention_years: years, previous: retention_years, set_by_id:, already_held: false
    }))
    disable(disabled_by_id: set_by_id, reason: "period_shortened") if shortened
    shortened
  end

  # @param enabled_by_id [String, nil] person_id of the actor
  # @param confirmed_count [Integer, nil] how many were due when the admin confirmed
  # @param at [Time]
  # @raise [Refused] while the period is never or the schedule is already on
  def enable(enabled_by_id: nil, confirmed_count: nil, at: Time.current)
    raise Refused, "retention is set to never, so there is nothing to schedule" if retention_years.nil?
    raise Refused, "scheduled forgetting is already on" if scheduled_forgetting?

    apply(TenantSettings::Events::ScheduledForgettingEnabled.new(data: {
      enabled_at: at.utc.iso8601(6), enabled_by_id:, confirmed_count:, already_held: false
    }))
  end

  # @param disabled_by_id [String, nil] person_id of the actor
  # @param reason [String] "by_admin" or "period_shortened"
  def disable(disabled_by_id: nil, reason: "by_admin")
    return unless scheduled_forgetting?

    apply(TenantSettings::Events::ScheduledForgettingDisabled.new(data: {
      disabled_by_id:, reason:, already_held: false
    }))
  end

  on TenantSettings::Events::RetentionPeriodSet do |event|
    @recorded = true
    @retention_years = event.data[:retention_years]
  end

  on TenantSettings::Events::ScheduledForgettingEnabled do |event|
    @recorded = true
    @scheduled_forgetting = true
    @enabled_at = Time.iso8601(event.data[:enabled_at])
    @enabled_by_id = event.data[:enabled_by_id]
  end

  on TenantSettings::Events::ScheduledForgettingDisabled do |_event|
    @recorded = true
    @scheduled_forgetting = false
    @enabled_at = nil
    @enabled_by_id = nil
  end

  private

  def sooner?(years) = !years.nil? && (retention_years.nil? || years < retention_years)
end
