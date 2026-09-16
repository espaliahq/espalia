# frozen_string_literal: true

require "test_helper"

# The MCP read tools' score payload. The load-bearing property is that it
# reads the SAME perspective the viewer's own screen renders — an agent
# quoting a number the page disagrees with is worse than no number.
class Assessments::ScoreSummaryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, name: "Alice")

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)

      @caps = [ "Critical Thinking", "Problem Solving" ].map do |name|
        cap = create(:framework_capability, category_id: cat.category_id, name: name)
        create(:framework_capability_role_binding,
          capability_id: cap.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: cap.capability_id, level_ordinal: 2, description: "Does the thing")
        cap
      end

      pd = PersonDevelopment::CommandHandler.new
      pd.assign_to_framework(@person.id, @framework_id, @role.role_id, @level.level_id)
      cycles = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycles.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      # The assessee rates both capabilities; the manager has only got to
      # the first. The two perspectives therefore disagree, and the
      # `:effective` fallback chain (aligned → manager → self) agrees with
      # neither — it would read the second capability off the self rating.
      @caps.each do |cap|
        pd.rate_self(@person.id, @framework_id, cap.stable_id,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)
      end
      pd.rate_as_manager(@person.id, @framework_id, @caps.first.stable_id,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id, rated_by_id: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
  end

  def summary_for(context)
    ActsAsTenant.with_tenant(@tenant) do
      Assessments::ScoreSummary.new(assignment: @assignment, context: context).overall
    end
  end

  context "#overall" do
    should "read the assessee's own ratings in self context" do
      assert_equal 100, summary_for(:self)[:score]
    end

    should "read the manager's ratings in manager context, not the effective blend" do
      # Manager-rated: one of two capabilities. The effective chain would
      # fill the gap from the self rating and report 100.
      assert_equal 50, summary_for(:manager)[:score]
    end

    should "roll up each category on the same perspective as the whole" do
      category = summary_for(:manager)[:categories].sole

      assert_equal 50, category[:score]
      assert_equal 2, category[:total_at_assessed_level]
      assert_equal 1, category[:rated_at_assessed_level]
    end
  end

  context "#capability" do
    should "score one capability on the viewer's perspective too" do
      rated, unrated = @caps.map { |c| c.stable_id }
      summary = ActsAsTenant.with_tenant(@tenant) do
        Assessments::ScoreSummary.new(assignment: @assignment, context: :manager)
      end

      assert_equal 100, summary.capability(rated)[:score]
      assert_equal 0, summary.capability(unrated)[:score]
    end
  end
end
