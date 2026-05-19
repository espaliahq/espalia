require "test_helper"

class AssessmentCycleEnrollmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @cycle = create(:assessment_cycle, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "validations" do
    subject { build(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle) }

    should validate_presence_of(:cycle_id)
    should validate_presence_of(:person_id)
    should validate_presence_of(:enrolled_at)
    should validate_inclusion_of(:status).in_array(AssessmentCycleEnrollment::STATUSES)
  end

  context "scopes" do
    setup do
      @active = create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, status: "enrolled")
      @withdrawn = create(:assessment_cycle_enrollment, :withdrawn, tenant: @tenant, cycle: @cycle)
    end

    should "#active returns only non-withdrawn rows" do
      assert_includes AssessmentCycleEnrollment.active, @active
      assert_not_includes AssessmentCycleEnrollment.active, @withdrawn
    end

    should "#withdrawn returns only withdrawn rows" do
      assert_includes AssessmentCycleEnrollment.withdrawn, @withdrawn
      assert_not_includes AssessmentCycleEnrollment.withdrawn, @active
    end

    should "#for_person filters by person_id" do
      pid = @active.person_id
      assert_equal [ @active.id ], AssessmentCycleEnrollment.for_person(pid).pluck(:id)
    end
  end

  context "cascade" do
    should "be destroyed when the parent cycle is destroyed" do
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle)
      assert_difference "AssessmentCycleEnrollment.count", -1 do
        @cycle.destroy
      end
    end
  end
end
