# frozen_string_literal: true

require "test_helper"

class PersonFrameworkAssignmentTest < ActiveSupport::TestCase
  context "validations" do
    subject { build(:person_framework_assignment) }

    should validate_presence_of(:person_id)
    should validate_presence_of(:framework_id)
    should validate_presence_of(:role_id)
    should validate_presence_of(:level_id)
  end

  context "scopes" do
    should "filter by person_id" do
      tenant = create(:tenant)
      ActsAsTenant.with_tenant(tenant) do
        person_id = SecureRandom.uuid_v7
        create(:person_framework_assignment, tenant: tenant, person_id: person_id)
        create(:person_framework_assignment, tenant: tenant, person_id: SecureRandom.uuid_v7)

        assert_equal 1, PersonFrameworkAssignment.for_person(person_id).count
      end
    end
  end

  context "#current_open_cycle" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
      @person_id = SecureRandom.uuid_v7
      @framework_id = SecureRandom.uuid_v7
      @assignment = create(:person_framework_assignment,
        tenant: @tenant, person_id: @person_id, framework_id: @framework_id)
    end

    teardown do
      ActsAsTenant.current_tenant = nil
    end

    should "return nil when the person is not enrolled in any cycle" do
      assert_nil @assignment.current_open_cycle
    end

    should "return the cycle when the person is enrolled in an open cycle for this framework" do
      cycle = create(:assessment_cycle,
        tenant: @tenant, framework_id: @framework_id)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: cycle, person_id: @person_id)

      assert_equal cycle.id, @assignment.current_open_cycle.id
    end

    should "return nil when the cycle is closed" do
      cycle = create(:assessment_cycle, :closed,
        tenant: @tenant, framework_id: @framework_id)
      create(:assessment_cycle_enrollment,
        tenant: @tenant, cycle: cycle, person_id: @person_id)

      assert_nil @assignment.current_open_cycle
    end

    should "return nil when the participant is withdrawn" do
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: @framework_id)
      create(:assessment_cycle_enrollment, :withdrawn,
        tenant: @tenant, cycle: cycle, person_id: @person_id)

      assert_nil @assignment.current_open_cycle
    end

    should "return nil when the open cycle is for a different framework" do
      other_framework = SecureRandom.uuid_v7
      cycle = create(:assessment_cycle, tenant: @tenant, framework_id: other_framework)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle, person_id: @person_id)

      assert_nil @assignment.current_open_cycle
    end
  end
end
