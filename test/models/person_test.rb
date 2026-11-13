# frozen_string_literal: true

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

    should "need no email once forgotten" do
      assert build(:person, name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current).valid?
    end
  end

  context ".first_name" do
    should "take the first word of a name, and keep the stand-in whole" do
      assert_equal "Alex", Person.first_name("Alex Chen")
      assert_equal Person::FORMER_MEMBER, Person.first_name(Person::FORMER_MEMBER)
      assert_nil Person.first_name(nil)
    end
  end

  context "a forgotten person" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
      @person = create(:person, tenant: @tenant)
      @person.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end
    teardown { ActsAsTenant.current_tenant = nil }

    should "read as a former member, to a pluck as well" do
      assert_equal Person::FORMER_MEMBER, @person.reload.name
      assert_equal Person::FORMER_MEMBER, Person.where(id: @person.id).pick(:name)
    end

    should "be held to the stand-in by the database" do
      assert_raises(ActiveRecord::StatementInvalid) { @person.update_columns(name: "Someone") }
    end

    should "need a name while remembered, at the database too" do
      live = create(:person, tenant: @tenant)
      assert_raises(ActiveRecord::StatementInvalid) { live.update_columns(name: nil) }
    end

    should "have no user to notify" do
      assert_no_difference -> { User.count } do
        assert_nil @person.ensure_user!
      end
    end

    should "not provision from a copy loaded before they were forgotten" do
      live = create(:person, tenant: @tenant)
      stale = Person.find(live.id)
      live.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)

      assert_no_difference -> { User.count } do
        assert_nil stale.ensure_user!
      end
    end

    should "be refused by the database without that mark" do
      assert_raises(ActiveRecord::StatementInvalid) { @person.update_columns(forgotten_at: nil) }
    end
  end

  context "#ensure_user!" do
    setup do
      @tenant = create(:tenant)
      ActsAsTenant.current_tenant = @tenant
    end
    teardown { ActsAsTenant.current_tenant = nil }

    should "return the existing linked user" do
      person = create(:person, tenant: @tenant)
      user = create(:user)
      create(:tenant_user, tenant: @tenant, user: user, person: person)
      assert_equal user, person.ensure_user!
    end

    should "provision a user + membership for a person who has none" do
      person = create(:person, tenant: @tenant, email: "Newbie@Example.com")
      account = nil
      assert_difference -> { User.count } => 1, -> { TenantUser.count } => 1 do
        account = person.ensure_user!
      end
      assert_equal "newbie@example.com", account.email
      assert_equal account, person.reload.user
      assert_equal "member", person.tenant_user.role
    end

    should "adopt an existing user (by email) + an unlinked membership rather than duplicate" do
      person = create(:person, tenant: @tenant, email: "ada@example.com")
      user = create(:user, email: "ada@example.com")
      create(:tenant_user, tenant: @tenant, user: user, person: nil) # logged in, not yet linked
      assert_no_difference -> { User.count } do
        assert_equal user, person.ensure_user!
      end
      assert_equal person, user.tenant_users.first.person
    end

    should "be idempotent" do
      person = create(:person, tenant: @tenant)
      first = person.ensure_user!
      assert_no_difference [ "User.count", "TenantUser.count" ] do
        assert_equal first, person.ensure_user!
      end
    end
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

  context "#all_reports" do
    setup do
      @tenant = create(:tenant)
    end

    should "return an empty relation for a leaf with no reports" do
      ActsAsTenant.with_tenant(@tenant) do
        leaf = create(:person)
        assert_empty leaf.all_reports
      end
    end

    should "return all descendants across multiple levels, excluding self" do
      ActsAsTenant.with_tenant(@tenant) do
        ceo = create(:person)
        vp = create(:person, manager: ceo)
        lead = create(:person, manager: vp)
        ic = create(:person, manager: lead)
        sibling = create(:person, manager: ceo)

        ids = ceo.all_reports.pluck(:id)
        assert_equal [ vp.id, lead.id, ic.id, sibling.id ].sort, ids.sort
        assert_not_includes ids, ceo.id
      end
    end

    should "scope to a subtree when called on a mid-level manager" do
      ActsAsTenant.with_tenant(@tenant) do
        ceo = create(:person)
        vp = create(:person, manager: ceo)
        lead = create(:person, manager: vp)

        assert_equal [ lead.id ], vp.all_reports.pluck(:id)
      end
    end

    should "not include people from other tenants" do
      other_tenant = create(:tenant)
      manager = ActsAsTenant.with_tenant(@tenant) { create(:person) }
      ActsAsTenant.with_tenant(other_tenant) { create(:person, manager_id: manager.id) }

      ActsAsTenant.with_tenant(@tenant) do
        assert_empty manager.all_reports
      end
    end

    should "terminate and exclude the root when a management cycle exists" do
      ActsAsTenant.with_tenant(@tenant) do
        a = create(:person)
        b = create(:person, manager: a)
        # Inject a cycle: a now reports to b.
        a.update!(manager: b)

        ids = a.all_reports.pluck(:id)
        assert_includes ids, b.id
        assert_not_includes ids, a.id
      end
    end

    should "return a composable relation" do
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person)
        active = create(:person, manager: manager, status: "active")
        create(:person, manager: manager, status: "inactive")

        ids = manager.all_reports.where(status: "active").pluck(:id)
        assert_equal [ active.id ], ids
      end
    end
  end
end
