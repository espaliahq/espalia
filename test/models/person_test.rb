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

  context "#manager_chain" do
    setup do
      @tenant = create(:tenant)
    end

    should "return empty array when person has no manager" do
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person)
        assert_equal [], person.manager_chain
      end
    end

    should "return direct manager only when there is no skip-level" do
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person)
        person = create(:person, manager: manager)
        assert_equal [ manager.id ], person.manager_chain.map(&:id)
      end
    end

    should "return chain ordered closest-first across multiple levels" do
      ActsAsTenant.with_tenant(@tenant) do
        ceo = create(:person)
        skip = create(:person, manager: ceo)
        manager = create(:person, manager: skip)
        person = create(:person, manager: manager)

        assert_equal [ manager.id, skip.id, ceo.id ], person.manager_chain.map(&:id)
      end
    end

    should "stop walking when a cycle is detected" do
      ActsAsTenant.with_tenant(@tenant) do
        a = create(:person)
        b = create(:person, manager: a)
        # Inject a cycle: a now reports to b. The walk should stop instead of looping.
        a.update!(manager: b)

        chain = b.manager_chain.map(&:id)
        # We don't assert exact order — only that the walk terminates and
        # never includes b itself.
        assert_not_includes chain, b.id
        assert chain.length <= 2
      end
    end
  end

  context "#managed_by?" do
    setup do
      @tenant = create(:tenant)
    end

    should "return true for direct manager" do
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person)
        person = create(:person, manager: manager)
        assert person.managed_by?(manager)
      end
    end

    should "return true for skip-level manager" do
      ActsAsTenant.with_tenant(@tenant) do
        skip = create(:person)
        manager = create(:person, manager: skip)
        person = create(:person, manager: manager)
        assert person.managed_by?(skip)
      end
    end

    should "return false for unrelated person" do
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person)
        unrelated = create(:person)
        person = create(:person, manager: manager)
        assert_not person.managed_by?(unrelated)
      end
    end

    should "return false when other is nil" do
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person)
        assert_not person.managed_by?(nil)
      end
    end
  end
end
