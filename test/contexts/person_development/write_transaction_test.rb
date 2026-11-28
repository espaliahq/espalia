# frozen_string_literal: true

require "test_helper"
require_relative "../../support/rebuild_lock"

# A Person Development write on the normal path stores its event and runs its
# synchronous handlers in one transaction (PersonDevelopment::Repository).
class PersonDevelopment::WriteTransactionTest < ActiveSupport::TestCase
  include RebuildLock

  PINGING = [
    PersonDevelopment::Projections::AssessmentAuthority,
    PersonDevelopment::Projections::CommentThread,
    PersonDevelopment::Projections::CurrentAssessment,
    PersonDevelopment::Projections::EvidenceCollection,
    PersonDevelopment::Projections::EvidenceRequests,
    PersonDevelopment::Projections::EvidenceSuggestions
  ].freeze

  # Fails after the projections have written, so the test sees them undone.
  class FailingHandler
    attr_reader :projected_before_failing

    def call(event)
      @projected_before_failing = ManagerAssessmentDelegation.where(person_id: event.metadata[:person_id]).exists?
      raise "handler failed"
    end
  end

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new
    @framework_id = SecureRandom.uuid_v7
    @person = create(:person, tenant: @tenant)
    @manager = create(:person, tenant: @tenant)
    @delegate = create(:person, tenant: @tenant)
    @handler.assign_to_framework(@person.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @stream = EventStreamNaming.person_development_stream(@person.id, @framework_id)
    @outside = ActiveRecord::Base.connection.open_transactions
  end

  teardown do
    ActsAsTenant.current_tenant = nil
  end

  context "the assessment-sync ping" do
    should "go out once, after the write commits" do
      pings = capture_pings { delegate }

      assert_equal [ @outside ], pings
    end

    should "not go out when the write rolls back" do
      pings = capture_pings do
        ActiveRecord::Base.transaction do
          delegate
          raise ActiveRecord::Rollback
        end
      end

      assert_empty pings
      assert_empty delegation_events
    end

    should "wait for the commit in every projection that sends it" do
      event = PersonDevelopment::Events::ManagerRatingDelegated.new(
        data: {}, metadata: { framework_id: @framework_id, person_id: @person.id }
      )

      PINGING.each do |projection|
        committed = capture_pings { ActiveRecord::Base.transaction { projection.new.send(:broadcast_assessment_sync, event) } }
        rolled_back = capture_pings do
          ActiveRecord::Base.transaction do
            projection.new.send(:broadcast_assessment_sync, event)
            raise ActiveRecord::Rollback
          end
        end

        assert_equal [ @outside ], committed, "#{projection} pinged before the commit"
        assert_empty rolled_back, "#{projection} pinged for a rollback"
      end
    end
  end

  should "store nothing and fail the caller when a synchronous handler raises" do
    failing = FailingHandler.new
    error = assert_raises(RuntimeError) do
      event_store.within { delegate }
        .subscribe(failing, to: [ PersonDevelopment::Events::ManagerRatingDelegated ]).call
    end

    assert_equal "handler failed", error.message
    assert failing.projected_before_failing
    assert_empty delegation_events
    assert_empty ManagerAssessmentDelegation.where(person_id: @person.id)
  end

  should "store the write and project it, without waiting, while every projection it feeds is rebuilt" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    while_rebuilding(@tenant, *PINGING) { delegate }

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5

    assert_equal 1, delegation_events.size
    assert_equal 1, ManagerAssessmentDelegation.where(person_id: @person.id).count
  end

  private

  def delegate
    @handler.delegate_manager_rating(@person.id, @framework_id, @delegate.id, granted_by_id: @manager.id)
  end

  def event_store = Rails.configuration.event_store

  def delegation_events
    event_store.read.stream(@stream).of_type(PersonDevelopment::Events::ManagerRatingDelegated).to_a
  end

  # Records how many transactions were open as each ping went out.
  def capture_pings(&)
    pings = []
    record = ->(*_args, **_kw) { pings << ActiveRecord::Base.connection.open_transactions }
    Turbo::StreamsChannel.stub(:broadcast_replace_to, record, &)
    pings
  end
end
