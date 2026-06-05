# frozen_string_literal: true

require "test_helper"

# Activity-feed coverage for assessment-authority events: delegation grant/
# revoke, reporting-manager changes, and the "(delegate)" badge on a delegate's
# manager rating.
class Assessments::ActivityFeedAuthorityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework_id = SecureRandom.uuid_v7
    @role_id = SecureRandom.uuid_v7
    @level_id = SecureRandom.uuid_v7
    @cap_sid = SecureRandom.uuid_v7

    ActsAsTenant.with_tenant(@tenant) do
      @assessee = create(:person, tenant: @tenant, name: "Report")
      @manager = create(:person, tenant: @tenant, name: "Manager")
      @delegate = create(:person, tenant: @tenant, name: "Casey Delegate")
      @assessee.update!(manager: @manager)

      @assignment = create(:person_framework_assignment, tenant: @tenant,
        person_id: @assessee.id, framework_id: @framework_id, role_id: @role_id, level_id: @level_id)

      handler = PersonDevelopment::CommandHandler.new
      cycle_handler = AssessmentCycles::CommandHandler.new
      handler.assign_to_framework(@assessee.id, @framework_id, @role_id, @level_id)
      handler.record_reporting_manager(@assessee.id, @framework_id, @manager.id, source: "hris")
      handler.delegate_manager_rating(@assessee.id, @framework_id, @delegate.id,
        granted_by_id: @manager.id, reason: "seconded")

      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @manager.id)
      cycle_handler.enroll(@cycle_id, @assessee.id, enrolled_by: @manager.id)

      # The delegate records a manager rating.
      handler.rate_as_manager(@assessee.id, @framework_id, @cap_sid,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id, rated_by_id: @delegate.id)
    end
  end

  def manager_entries
    run_query(viewer: @manager, sees_all: true, context: :manager, alignment_started: false)
  end

  context "as the manager (sees_all)" do
    should "surface a delegation_granted entry with actor and delegate names" do
      entry = manager_entries.find { |e| e.kind == "delegation_granted" }
      assert entry, "expected a delegation_granted entry"
      assert_equal "Manager", entry.payload[:actor_name]
      assert_equal "Casey Delegate", entry.payload[:delegate_name]
    end

    should "surface a reporting_manager_recorded entry with the new manager name" do
      entry = manager_entries.find { |e| e.kind == "reporting_manager_recorded" }
      assert entry, "expected a reporting_manager_recorded entry"
      assert_equal "Manager", entry.payload[:manager_name]
    end

    should "badge the delegate's manager rating with via_delegation" do
      entry = manager_entries.find { |e| e.kind == "manager_rated" }
      assert entry
      assert_equal true, entry.payload[:via_delegation]
    end

    should "group authority entries outside the four filter chips" do
      kinds = manager_entries.select { |e| %w[delegation_granted reporting_manager_recorded].include?(e.kind) }
      assert kinds.any?
      kinds.each do |e|
        group = Views::Assessments::Activity::Entry::KIND_GROUP[e.kind]
        assert_not_includes %w[ratings evidence comments alignment], group
      end
    end
  end

  context "privacy" do
    should "hide delegation entries from the assessee before alignment, but show reporting-manager change" do
      entries = run_query(viewer: @assessee, sees_all: true, context: :self, alignment_started: false)
      kinds = entries.map(&:kind)
      assert_not_includes kinds, "delegation_granted"
      assert_includes kinds, "reporting_manager_recorded"
    end

    should "let the delegate see manager ratings and delegation entries (controller grants sees_all)" do
      # The controller treats an active delegate like a manager
      # (viewer_sees_all_evidence? → true, context :manager), so the feed must
      # not hide the manager ratings they are authorised to record.
      entries = run_query(viewer: @delegate, sees_all: true, context: :manager, alignment_started: false)
      kinds = entries.map(&:kind)
      assert_includes kinds, "manager_rated"
      assert_includes kinds, "delegation_granted"
    end
  end

  private

  def run_query(viewer:, sees_all:, context:, alignment_started:)
    ActsAsTenant.with_tenant(@tenant) do
      Assessments::ActivityFeedQuery.new(
        assignment: @assignment.reload, context: context, viewer_person_id: viewer.id,
        viewer_sees_all: sees_all, alignment_started: alignment_started
      ).call
    end
  end
end
