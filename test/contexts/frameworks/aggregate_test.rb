# frozen_string_literal: true

require "test_helper"

class Frameworks::AggregateTest < ActiveSupport::TestCase
  setup do
    @aggregate = Frameworks::Aggregate.new
    @framework_id = SecureRandom.uuid_v7
  end

  context "#create" do
    should "apply FrameworkCreated event" do
      @aggregate.create(@framework_id, "Engineering Growth")

      events = @aggregate.unpublished_events.to_a
      assert_equal 1, events.length
      assert_kind_of Frameworks::Events::FrameworkCreated, events.first
      assert_equal @framework_id, events.first.data[:framework_id]
      assert_equal "Engineering Growth", events.first.data[:name]
    end

    should "raise if framework already created" do
      @aggregate.create(@framework_id, "Engineering Growth")

      assert_raises(RuntimeError, /already created/) do
        @aggregate.create(@framework_id, "Duplicate")
      end
    end
  end
end
