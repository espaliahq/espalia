require "test_helper"

class PersonTest < ActiveSupport::TestCase
  subject { build(:person) }

  context "associations" do
    should belong_to(:tenant)
    should belong_to(:manager).class_name("Person").optional
    should have_many(:direct_reports).class_name("Person").dependent(:nullify)
    should have_one(:tenant_user).dependent(:nullify)
    should have_one(:user).through(:tenant_user)
  end

  context "validations" do
    should validate_presence_of(:email)
    should validate_presence_of(:name)
  end

  context "tenant scoping" do
    should "only return people within the current tenant" do
      tenant_a = create(:tenant)
      tenant_b = create(:tenant)
      ActsAsTenant.with_tenant(tenant_a) { create(:person) }
      ActsAsTenant.with_tenant(tenant_b) { create(:person) }

      ActsAsTenant.with_tenant(tenant_a) do
        assert_equal 1, Person.count
      end
    end
  end

  context "org chart" do
    should "link direct reports to manager" do
      tenant = create(:tenant)
      ActsAsTenant.with_tenant(tenant) do
        manager = create(:person)
        report = create(:person, manager: manager)
        assert_includes manager.direct_reports, report
      end
    end
  end
end
