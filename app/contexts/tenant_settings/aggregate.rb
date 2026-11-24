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

  DEFAULT_RETENTION_YEARS = OrgGraphConfig::DEFAULT_RETENTION_YEARS

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
  # @param already_held [Boolean] true when recording a period set before it was an event
  # @return [Boolean] whether the change turned scheduled forgetting off
  def set_retention_period(years, set_by_id: nil, already_held: false)
    return false if years == retention_years

    shortened = !already_held && scheduled_forgetting? && sooner?(years)
    apply(TenantSettings::Events::RetentionPeriodSet.new(data: {
      retention_years: years, previous: retention_years, set_by_id:, already_held:
    }))
    disable(disabled_by_id: set_by_id, reason: "period_shortened") if shortened
    shortened
  end

  # @param enabled_by_id [String, nil] person_id of the actor
  # @param confirmed_count [Integer, nil] how many were due when the admin confirmed
  # @param at [Time]
  # @param already_held [Boolean] true when recording a schedule turned on before it was an event
  # @raise [Refused] while the period is never or the schedule is already on, unless already held
  def enable(enabled_by_id: nil, confirmed_count: nil, at: Time.current, already_held: false)
    return if already_held && scheduled_forgetting?
    unless already_held
      raise Refused, "retention is set to never, so there is nothing to schedule" if retention_years.nil?
      raise Refused, "scheduled forgetting is already on" if scheduled_forgetting?
    end

    apply(TenantSettings::Events::ScheduledForgettingEnabled.new(data: {
      enabled_at: at.utc.iso8601(6), enabled_by_id:, confirmed_count:, already_held:
    }))
  end

  # @param disabled_by_id [String, nil] person_id of the actor
  # @param reason [String, nil] "by_admin" or "period_shortened"; nil when already held
  # @param already_held [Boolean] true when recording a schedule turned off before it was an event
  def disable(disabled_by_id: nil, reason: "by_admin", already_held: false)
    return unless scheduled_forgetting?

    apply(TenantSettings::Events::ScheduledForgettingDisabled.new(data: {
      disabled_by_id:, reason: already_held ? nil : reason, already_held:
    }))
  end

  # Records, as already held, whatever settings stand outside the stream that
  # it doesn't hold: the previous release writes the tenant's JSON only. A
  # schedule turned off and on again there since is recorded as both.
  #
  # @param retention_years [Integer, nil]
  # @param scheduled_forgetting [Boolean]
  # @param enabled_at [Time, nil]
  # @param enabled_by_id [String, nil] person_id of whoever turned it on, when known
  # @return [Integer] how many events it applied
  def record_held(retention_years:, scheduled_forgetting:, enabled_at: nil, enabled_by_id: nil)
    before = unpublished_events.count
    restarted = scheduled_forgetting && scheduled_forgetting? && enabled_at && enabled_at.to_i != self.enabled_at.to_i
    disable(already_held: true) if !scheduled_forgetting || restarted
    set_retention_period(retention_years, already_held: true)
    enable(enabled_by_id:, at: enabled_at || Time.current, already_held: true) if scheduled_forgetting
    unpublished_events.count - before
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
