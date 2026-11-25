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
end
