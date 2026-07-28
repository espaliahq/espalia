# frozen_string_literal: true

require "test_helper"

# Verifies a calibration rating-revisit request (the PD mirror event)
# notifies the rater being asked — with the room's note quoted and the cell
# deep-linked — and stays silent when the ask was already acted on or when
# the asker is the rater themselves.
class PersonDevelopment::AsyncHandlers::RatingRevisitNotifierTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @handler = PersonDevelopment::CommandHandler.new

    @rater_user = create(:user)
    @rater = create(:person, tenant: @tenant, name: "Mia Manager")
    @assessee = create(:person, tenant: @tenant, name: "Ivy IC", manager: @rater)
    @facilitator = create(:person, tenant: @tenant, name: "Dana Dept")
    create(:tenant_user, tenant: @tenant, user: @rater_user, person: @rater, role: :member)

    @framework_id = SecureRandom.uuid_v7
    @cap_stable = SecureRandom.uuid_v7
    @handler.assign_to_framework(@assessee.id, @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7)
    @assignment_id = PersonFrameworkAssignment
      .find_by(person_id: @assessee.id, framework_id: @framework_id).id
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def request_revisit!(requested_by: @facilitator, note: "Compare against the two peers we discussed",
                       calibration_session_id: SecureRandom.uuid_v7)
    @handler.request_rating_revisit(@assessee.id, @framework_id,
      capability_stable_id: @cap_stable, level_ordinal: 3,
      calibration_session_id: calibration_session_id,
      rater_id: @rater.id, note: note,
      session_name: "Engineering calibration", requested_by_id: requested_by.id)
  end

  context "a revisit request lands" do
    should "notify the rater with the note, session context, and cell deep link" do
      perform_enqueued_jobs { request_revisit! }

      notifications = @rater_user.notifications.reload
      assert_equal 1, notifications.size
      n = notifications.first
      assert_equal "Dana Dept asked you to revisit Ivy IC's rating", n.inbox_title
      assert_includes n.inbox_body, "Engineering calibration"
      assert_includes n.inbox_body, "L3"
      assert_includes n.inbox_body, "“Compare against the two peers we discussed”"
      assert_equal "/assessments/#{@assignment_id}?capability=#{@cap_stable}&level_ordinal=3",
                   n.inbox_url
    end

    should "stay silent when the rater is the person who asked" do
      perform_enqueued_jobs { request_revisit!(requested_by: @rater) }

      assert_empty @rater_user.notifications.reload
    end

    should "stay silent when the rating already changed by the time the job runs" do
      # Enqueue without performing, act on the rating, then drain the queue —
      # the same "resolved before the job ran" ordering a busy queue produces.
      request_revisit!
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      travel 1.minute do
        create(:assessment_level_rating, tenant: @tenant,
               cycle_id: cycle.cycle_id,
               person_id: @assessee.id, framework_id: @framework_id,
               capability_stable_id: @cap_stable, level_ordinal: 3,
               manager_rated_frequency: "occasional", last_manager_rated_at: Time.current)
      end
      perform_enqueued_jobs

      assert_empty @rater_user.notifications.reload
    end

    should "still notify when only ANOTHER cycle's rating row changed (cycle-scoped resolution)" do
      # The asking session's cycle has no rating change; a later cycle's
      # seeded carry-forward stamps a fresh last_manager_rated_at on its own
      # row — that must not suppress the ping.
      session_cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      other_cycle = create(:assessment_cycle, :closed, tenant: @tenant, framework_id: @framework_id)
      session = create(:calibration_session, tenant: @tenant,
                       cycle_id: session_cycle.cycle_id, framework_id: @framework_id,
                       facilitator_id: @facilitator.id, status: "started")

      request_revisit!(calibration_session_id: session.id)
      travel 1.minute do
        create(:assessment_level_rating, tenant: @tenant,
               cycle_id: other_cycle.cycle_id,
               person_id: @assessee.id, framework_id: @framework_id,
               capability_stable_id: @cap_stable, level_ordinal: 3,
               manager_rated_frequency: "occasional", last_manager_rated_at: Time.current)
      end
      perform_enqueued_jobs

      assert_equal 1, @rater_user.notifications.reload.size
    end
  end
end
