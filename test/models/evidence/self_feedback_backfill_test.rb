# frozen_string_literal: true

require "test_helper"
require_relative "../../support/placement_suggestion_fixture"

class Evidence::SelfFeedbackBackfillTest < ActiveJob::TestCase
  include PlacementSuggestionFixture

  setup do
    build_placement_fixture
    @plain = record_self_feedback(content: "Shipped the billing rewrite.")
    @superseded = record_self_feedback(content: "Ran the planning offsite.")
    @pending = record_self_feedback(content: "Paired with the new hire all week.")
    @dismissed = record_self_feedback(content: "Rewrote the on-call runbook.")
    @withdrawn = record_self_feedback(content: "Said something I took back.")
    @peer = record_peer_feedback(placed_on: @collaboration)
    ActsAsTenant.with_tenant(@tenant) do
      { @superseded => "superseded", @pending => "pending", @dismissed => "dismissed" }.each do |item, status|
        create(:evidence_placement_suggestion, tenant: @tenant, item: item, capability_stable_id: @ownership.stable_id, status: status)
      end
      PersonDevelopment::CommandHandler.new.withdraw_evidence(@alex.id, @framework_id, @withdrawn.id, withdrawn_by_id: @alex.id)
    end
    clear_enqueued_jobs
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def configured(&) = Evidence::SuggestionModel.stub(:configured?, true, &)

  should "pick active self feedback with nothing pending or decided, oldest first" do
    configured do
      backfill = Evidence::SelfFeedbackBackfill.new
      assert_equal({ @tenant => [ @plain.id, @superseded.id ] }, backfill.candidates)
      assert_equal 2, backfill.count
    end
  end

  should "leave out a workspace with suggestions off, or with no model" do
    other = create(:tenant, ai_config: AiModelConfig.new(suggestions_enabled: false))
    configured do
      backfill = Evidence::SelfFeedbackBackfill.new
      assert_equal [ @tenant ], backfill.candidates.keys
      assert_includes backfill.skipped_tenants, other
    end
    Evidence::SuggestionModel.stub(:configured?, false) do
      assert_empty Evidence::SelfFeedbackBackfill.new.candidates
    end
  end

  should "narrow to one workspace by slug" do
    configured do
      assert_equal [ @tenant ], Evidence::SelfFeedbackBackfill.new(tenant_slug: @tenant.slug).candidates.keys
      assert_empty Evidence::SelfFeedbackBackfill.new(tenant_slug: "nowhere").candidates
    end
  end

  should "spread the runs per minute and enqueue nothing new when run again" do
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      configured do
        freeze_time do
          assert_equal 2, Evidence::SelfFeedbackBackfill.new(per_minute: 1).enqueue!
          scheduled = enqueued_jobs.select { |job| job[:job] == Evidence::SuggestPlacementsJob }
          assert_equal [ [ @plain.id ], [ @superseded.id ] ], scheduled.map { |job| job[:args] }
          assert_equal [ Time.current.to_f, 1.minute.from_now.to_f ], scheduled.map { |job| job[:at] }

          assert_equal 0, Evidence::SelfFeedbackBackfill.new(per_minute: 1).enqueue!
        end
      end
    end
  end
end
