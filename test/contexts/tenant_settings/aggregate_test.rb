# frozen_string_literal: true

require "test_helper"

class TenantSettings::AggregateTest < ActiveSupport::TestCase
  subject { TenantSettings::Aggregate.new }

  def events = subject.unpublished_events.to_a
  def on_since(at = 1.day.ago) = subject.tap { it.enable(at:) }

  should "start where a tenant that never changed anything stands" do
    assert_equal 7, subject.retention_years
    assert_not subject.scheduled_forgetting?
    assert_not subject.recorded?
  end

  context "setting the period" do
    should "write nothing when it is unchanged" do
      assert_not subject.set_retention_period(7)
      assert_empty events
    end

    should "turn the schedule off in the same change when it makes more people due" do
      on_since
      assert subject.set_retention_period(3, set_by_id: "p-1")

      assert_not subject.scheduled_forgetting?
      disabled = events.last
      assert_instance_of TenantSettings::Events::ScheduledForgettingDisabled, disabled
      assert_equal({ disabled_by_id: "p-1", reason: "period_shortened", already_held: false }, disabled.data)
    end

    should "count leaving never behind as making more people due" do
      on_since
      subject.set_retention_period(nil)
      assert subject.set_retention_period(20)
    end

    should "keep the schedule on for a longer period or never" do
      on_since
      assert_not subject.set_retention_period(10)
      assert_not subject.set_retention_period(nil)
      assert subject.scheduled_forgetting?
    end
  end

  context "turning the schedule on" do
    should "refuse while the period is never, or when it is already on" do
      subject.set_retention_period(nil)
      assert_raises(TenantSettings::Aggregate::Refused) { subject.enable }

      subject.set_retention_period(7)
      subject.enable
      assert_raises(TenantSettings::Aggregate::Refused) { subject.enable }
    end

    should "record who turned it on, when, and the count they confirmed" do
      at = Time.utc(2026, 11, 1, 9, 30, 0.5r)
      subject.enable(enabled_by_id: "p-1", confirmed_count: 4, at:)

      assert_equal [ at, "p-1" ], [ subject.enabled_at, subject.enabled_by_id ]
      assert_equal({ enabled_at: at.iso8601(6), enabled_by_id: "p-1", confirmed_count: 4, already_held: false }, events.last.data)
    end

    should "forget who turned it on once it is off, and write nothing turning off what is off" do
      on_since.disable(disabled_by_id: "p-2")
      assert_nil subject.enabled_by_id
      assert_nil subject.enabled_at

      count = events.count
      subject.disable
      assert_equal count, events.count
    end
  end

  context "recording what the JSON holds" do
    should "record nothing the stream already holds" do
      at = 1.day.ago
      on_since(at)
      count = events.count

      assert_equal 0, subject.record_held(retention_years: 7, scheduled_forgetting: true, enabled_at: at)
      assert_equal count, events.count
    end

    should "record a schedule and period set outside it as already held, naming no reason" do
      at = 2.days.ago
      assert_equal 2, subject.record_held(retention_years: 3, scheduled_forgetting: true, enabled_at: at, enabled_by_id: "p-1")

      assert_equal [ 3, true, at.to_i, "p-1" ], [ subject.retention_years, subject.scheduled_forgetting?, subject.enabled_at.to_i, subject.enabled_by_id ]
      assert events.all? { it.data[:already_held] }
    end

    should "not count a shorter period it records as turning the schedule off" do
      on_since
      subject.record_held(retention_years: 1, scheduled_forgetting: true, enabled_at: subject.enabled_at)

      assert subject.scheduled_forgetting?
    end

    should "record a schedule turned off outside it" do
      on_since
      subject.record_held(retention_years: 7, scheduled_forgetting: false)

      assert_not subject.scheduled_forgetting?
      assert_equal({ disabled_by_id: nil, reason: nil, already_held: true }, events.last.data)
    end

    should "record a schedule turned off and on again outside it as both" do
      on_since(3.days.ago)
      again = 1.hour.ago
      assert_equal 2, subject.record_held(retention_years: 7, scheduled_forgetting: true, enabled_at: again)

      assert_equal again.to_i, subject.enabled_at.to_i
      assert_equal [ TenantSettings::Events::ScheduledForgettingDisabled, TenantSettings::Events::ScheduledForgettingEnabled ],
                   events.last(2).map(&:class)
    end
  end
end
