# frozen_string_literal: true

require "test_helper"

class PersonFrameworkAssignmentTest < ActiveSupport::TestCase
  context "validations" do
    subject { build(:person_framework_assignment) }

    should validate_presence_of(:person_id)
    should validate_presence_of(:framework_id)
    should validate_presence_of(:role_id)
    should validate_presence_of(:level_id)
    should validate_presence_of(:cycle_status)
    should validate_inclusion_of(:cycle_status).in_array(PersonFrameworkAssignment::CYCLE_STATUSES)
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

    should "filter to open cycles" do
      tenant = create(:tenant)
      ActsAsTenant.with_tenant(tenant) do
        create(:person_framework_assignment, :with_open_cycle, tenant: tenant)
        create(:person_framework_assignment, tenant: tenant)

        assert_equal 1, PersonFrameworkAssignment.with_open_cycle.count
      end
    end
  end

  context "#cycle_open?" do
    should "return true when cycle_status is open" do
      assignment = build(:person_framework_assignment, :with_open_cycle)
      assert assignment.cycle_open?
    end

    should "return false when cycle_status is none" do
      assignment = build(:person_framework_assignment)
      assert_not assignment.cycle_open?
    end
  end
end
