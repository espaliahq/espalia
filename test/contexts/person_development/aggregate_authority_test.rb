# frozen_string_literal: true

require "test_helper"

# Reporting-manager recording, manager-rating delegation, and the soft
# manager-authority guard on the PersonDevelopment aggregate.
class PersonDevelopment::AggregateAuthorityTest < ActiveSupport::TestCase
  setup do
    @aggregate = PersonDevelopment::Aggregate.new
    @person_id = SecureRandom.uuid_v7
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @manager_id = SecureRandom.uuid_v7
    @delegate_id = SecureRandom.uuid_v7
    @cycle_id = SecureRandom.uuid_v7
    @aggregate.assign_to_framework(@person_id, @framework_id, @role_id, @level_id)
  end

  context "#record_reporting_manager" do
    should "apply ReportingManagerRecorded with previous manager and source" do
      @aggregate.record_reporting_manager(@manager_id, source: "hris")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ReportingManagerRecorded, event
      assert_equal @manager_id, event.data[:manager_id]
      assert_nil event.data[:previous_manager_id]
      assert_equal "hris", event.data[:source]
    end

    should "be idempotent — no event when the manager is unchanged" do
      @aggregate.record_reporting_manager(@manager_id)
      before = @aggregate.unpublished_events.to_a.size
      @aggregate.record_reporting_manager(@manager_id)
      assert_equal before, @aggregate.unpublished_events.to_a.size
    end

    should "emit a new event carrying the previous manager when it changes" do
      @aggregate.record_reporting_manager(@manager_id)
      new_manager = SecureRandom.uuid_v7
      @aggregate.record_reporting_manager(new_manager)

      event = @aggregate.unpublished_events.to_a.last
      assert_equal new_manager, event.data[:manager_id]
      assert_equal @manager_id, event.data[:previous_manager_id]
    end

    should "no-op when manager_id is nil" do
      before = @aggregate.unpublished_events.to_a.size
      @aggregate.record_reporting_manager(nil)
      assert_equal before, @aggregate.unpublished_events.to_a.size
    end
  end

  context "#delegate_manager_rating" do
    should "apply ManagerRatingDelegated with attribution" do
      granter = SecureRandom.uuid_v7
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: granter,
        expires_at: nil, reason: "seconded")

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRatingDelegated, event
      assert_equal @delegate_id, event.data[:delegate_person_id]
      assert_equal granter, event.data[:granted_by_id]
      assert_equal "seconded", event.data[:reason]
    end

    should "be idempotent when the delegate is already active" do
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: SecureRandom.uuid_v7)
      before = @aggregate.unpublished_events.to_a.size
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: SecureRandom.uuid_v7)
      assert_equal before, @aggregate.unpublished_events.to_a.size
    end

    should "reject delegating to the assessee" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.delegate_manager_rating(@person_id, granted_by_id: SecureRandom.uuid_v7)
      end
    end

    should "allow renewing an expired delegation (idempotency is expiry-aware)" do
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: SecureRandom.uuid_v7,
        expires_at: "2000-01-01T00:00:00Z")
      before = @aggregate.unpublished_events.to_a.size

      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: SecureRandom.uuid_v7,
        expires_at: "2999-01-01T00:00:00Z")
      assert_equal before + 1, @aggregate.unpublished_events.to_a.size
    end
  end

  context "#revoke_manager_rating_delegation" do
    should "apply ManagerRatingDelegationRevoked" do
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: SecureRandom.uuid_v7)
      revoker = SecureRandom.uuid_v7
      @aggregate.revoke_manager_rating_delegation(@delegate_id, revoked_by_id: revoker)

      event = @aggregate.unpublished_events.to_a.last
      assert_kind_of PersonDevelopment::Events::ManagerRatingDelegationRevoked, event
      assert_equal @delegate_id, event.data[:delegate_person_id]
      assert_equal revoker, event.data[:revoked_by_id]
    end

    should "raise when no active delegation exists" do
      assert_raises(PersonDevelopment::Aggregate::CommandError) do
        @aggregate.revoke_manager_rating_delegation(@delegate_id, revoked_by_id: SecureRandom.uuid_v7)
      end
    end
  end

  context "manager-authority soft guard (Stage 1)" do
    setup { @aggregate.join_cycle(@cycle_id, 1) }

    should "allow the recorded manager to rate" do
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "consistent",
        cycle_id: @cycle_id, rated_by_id: @manager_id)
      assert_kind_of PersonDevelopment::Events::ManagerRated, @aggregate.unpublished_events.to_a.last
    end

    should "allow an active delegate to rate" do
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: @manager_id)
      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: @delegate_id)
      assert_kind_of PersonDevelopment::Events::ManagerRated, @aggregate.unpublished_events.to_a.last
    end

    should "fail open (still record) when no manager has been recorded" do
      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: SecureRandom.uuid_v7)
      assert_kind_of PersonDevelopment::Events::ManagerRated, @aggregate.unpublished_events.to_a.last
    end

    should "log but still record a rating from a non-manager non-delegate (Stage 1)" do
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: SecureRandom.uuid_v7)
      assert_kind_of PersonDevelopment::Events::ManagerRated, @aggregate.unpublished_events.to_a.last
    end

    should "deny an expired delegate (guard honours expiry, agreeing with the policy)" do
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: @manager_id,
        expires_at: "2000-01-01T00:00:00Z")
      assert_not @aggregate.send(:delegate_active?, @delegate_id)
    end

    should "stamp via_delegation true for a delegate's rating, false for the manager's" do
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.delegate_manager_rating(@delegate_id, granted_by_id: @manager_id)

      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: @delegate_id)
      assert_equal true, @aggregate.unpublished_events.to_a.last.data[:via_delegation]

      @aggregate.rate_as_manager("cap-2", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: @manager_id)
      assert_equal false, @aggregate.unpublished_events.to_a.last.data[:via_delegation]
    end
  end

  context "#clear_manager_rating authority guard" do
    setup do
      @aggregate.join_cycle(@cycle_id, 1)
      @aggregate.record_reporting_manager(@manager_id)
      @aggregate.rate_as_manager("cap-1", level_ordinal: 1, frequency: "some",
        cycle_id: @cycle_id, rated_by_id: @manager_id)
    end

    should "let the recorded manager clear" do
      @aggregate.clear_manager_rating("cap-1", level_ordinal: 1, cycle_id: @cycle_id,
        rated_by_id: @manager_id)
      assert_kind_of PersonDevelopment::Events::ManagerRatingCleared,
        @aggregate.unpublished_events.to_a.last
    end
  end
end
