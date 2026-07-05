# frozen_string_literal: true

require "test_helper"

# Reminder timing policy on the EvidenceRequest read model — the pure "when is
# a nudge due" rules the sweep job consumes. The sent-at-most-once-per-kind
# invariant itself is aggregate-guarded and covered in
# test/contexts/person_development/evidence_requests_test.rb.
class EvidenceRequestTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def request(**attrs)
    build(:evidence_request, tenant: @tenant, **attrs)
  end

  context "#due_reminder_kind" do
    should "be nil while the request is fresh" do
      assert_nil request(requested_at: 2.days.ago).due_reminder_kind
    end

    should "be no_response once 7 quiet days have passed" do
      assert_equal "no_response", request(requested_at: 8.days.ago).due_reminder_kind
    end

    should "be due_soon within 2 days of the due date" do
      req = request(requested_at: 3.days.ago, due_at: 1.day.from_now)
      assert_equal "due_soon", req.due_reminder_kind
    end

    should "not fire due_soon once the due date has passed" do
      req = request(requested_at: 5.days.ago, due_at: 1.day.ago)
      assert_nil req.due_reminder_kind
    end

    should "hold the 24h floor even when the due date is imminent" do
      # The reminder_candidates scope also enforces this, but the method must
      # be self-sufficient — a due date right after the ask is the case that
      # would otherwise double-ping.
      req = request(requested_at: 2.hours.ago, due_at: 20.hours.from_now)
      assert_nil req.due_reminder_kind
    end

    should "pick the earlier threshold when both kinds are due" do
      # no_response threshold (requested + 7d = 2d ago) precedes due_soon's
      # (due - 2d = 1d ago) → no_response wins.
      req = request(requested_at: 9.days.ago, due_at: 1.day.from_now)
      assert_equal "no_response", req.due_reminder_kind

      # due_soon threshold (due - 2d = 18h ago) precedes no_response's
      # (requested + 7d = 2h ago) → due_soon wins.
      req = request(requested_at: 7.days.ago - 2.hours, due_at: 30.hours.from_now)
      assert_equal "due_soon", req.due_reminder_kind
    end

    should "suppress a second kind within the reminder gap" do
      req = request(requested_at: 9.days.ago, due_at: 1.day.from_now,
                    no_response_reminded_at: 1.day.ago, last_reminded_at: 1.day.ago)
      assert_nil req.due_reminder_kind
    end

    should "allow the second kind once the gap has passed" do
      req = request(requested_at: 12.days.ago, due_at: 1.day.from_now,
                    no_response_reminded_at: 4.days.ago, last_reminded_at: 4.days.ago)
      assert_equal "due_soon", req.due_reminder_kind
    end

    should "defer automatic reminders after a recent manual nudge" do
      req = request(requested_at: 9.days.ago, last_reminded_at: 1.day.ago)
      assert_nil req.due_reminder_kind
    end

    should "not repeat a kind that was already sent" do
      req = request(requested_at: 12.days.ago, no_response_reminded_at: 4.days.ago)
      assert_nil req.due_reminder_kind
    end

    should "be nil for a resolved request" do
      req = request(requested_at: 9.days.ago, status: "responded")
      assert_nil req.due_reminder_kind
    end
  end

  context ".reminder_candidates" do
    should "exclude fresh, ancient, and resolved requests" do
      eligible = create(:evidence_request, tenant: @tenant, requested_at: 8.days.ago)
      create(:evidence_request, tenant: @tenant, requested_at: 2.hours.ago)   # < 24h old
      create(:evidence_request, tenant: @tenant, requested_at: 40.days.ago)  # > 30d old
      create(:evidence_request, tenant: @tenant, requested_at: 8.days.ago, status: "cancelled")

      assert_equal [ eligible.id ], EvidenceRequest.reminder_candidates.pluck(:id)
    end
  end

  context "#can_nudge?" do
    should "allow a nudge once the gap since the last reminder has passed" do
      assert request(requested_at: 9.days.ago, last_reminded_at: 3.days.ago).can_nudge?
    end

    should "block a nudge within the gap of the last reminder" do
      assert_not request(requested_at: 9.days.ago, last_reminded_at: 1.day.ago).can_nudge?
    end

    should "measure from the ask when never reminded" do
      assert request(requested_at: 3.days.ago).can_nudge?
      assert_not request(requested_at: 1.day.ago).can_nudge?
    end

    should "never allow nudging a resolved request" do
      assert_not request(requested_at: 9.days.ago, status: "responded").can_nudge?
    end
  end

  context ".least_recently_touched" do
    should "order by the later of requested and last-reminded, stalest first" do
      recently_reminded = create(:evidence_request, tenant: @tenant,
        requested_at: 10.days.ago, last_reminded_at: 1.day.ago)
      stale = create(:evidence_request, tenant: @tenant, requested_at: 6.days.ago)
      fresh = create(:evidence_request, tenant: @tenant, requested_at: 2.days.ago)

      assert_equal [ stale.id, fresh.id, recently_reminded.id ],
        EvidenceRequest.least_recently_touched.pluck(:id)
    end
  end
end
