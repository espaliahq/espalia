# frozen_string_literal: true

require "test_helper"

class AssessmentCycleProgressTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @cycle = create(:assessment_cycle, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "validations" do
    subject { build(:assessment_cycle_progress, tenant: @tenant, cycle: @cycle) }

    should validate_presence_of(:cycle_id)
    should validate_presence_of(:person_id)
    should validate_inclusion_of(:status).in_array(AssessmentCycleProgress::STATUSES)
  end

  context "associations" do
    should belong_to(:cycle).class_name("AssessmentCycle").with_primary_key(:cycle_id).with_foreign_key(:cycle_id)
    should belong_to(:alignment_started_by).class_name("Person").with_foreign_key(:alignment_started_by_id).optional
    should belong_to(:aligned_by).class_name("Person").with_foreign_key(:aligned_by_id).optional
  end

  context "cascade" do
    # AssessmentCycleProgress is owned by PersonDevelopment::CurrentAssessment.
    # AssessmentCycle deliberately does NOT cascade `dependent: :destroy` to
    # progress rows — cross-context cascades would let a single-projection
    # rebuild of `assessment_cycles/current_state` wipe another projection's
    # read model. Truncation of progress rows happens exclusively in
    # `CurrentAssessment.reset!`.
    should "be retained when the parent cycle is destroyed" do
      create(:assessment_cycle_progress, tenant: @tenant, cycle: @cycle)
      assert_no_difference "AssessmentCycleProgress.count" do
        @cycle.destroy
      end
    end
  end

  context "traits" do
    should ":aligning trait stamps alignment_started_at" do
      progress = create(:assessment_cycle_progress, :aligning,
        tenant: @tenant, cycle: @cycle)

      assert_equal "aligning", progress.status
      assert_not_nil progress.alignment_started_at
      assert_not_nil progress.alignment_started_by_id
    end

    should ":aligned trait stamps aligned_at" do
      progress = create(:assessment_cycle_progress, :aligned,
        tenant: @tenant, cycle: @cycle)

      assert_equal "aligned", progress.status
      assert_not_nil progress.aligned_at
    end
  end
end
