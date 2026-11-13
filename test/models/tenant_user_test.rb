# frozen_string_literal: true

require "test_helper"

class TenantUserTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
  end

  subject { ActsAsTenant.with_tenant(@tenant) { build(:tenant_user, tenant: @tenant, user: @user) } }

  context "associations" do
    should belong_to(:tenant)
    should belong_to(:user)
    should belong_to(:person).optional
  end

  context "validations" do
    should validate_presence_of(:role)
  end

  context "role enum" do
    should "default to member" do
      ActsAsTenant.with_tenant(@tenant) do
        tenant_user = create(:tenant_user, tenant: @tenant, user: @user)
        assert tenant_user.member?
      end
    end

    should "accept admin role" do
      ActsAsTenant.with_tenant(@tenant) do
        tenant_user = build(:tenant_user, tenant: @tenant, user: @user, role: :admin)
        assert tenant_user.valid?
        assert tenant_user.admin?
      end
    end
  end

  context "uniqueness" do
    should "prevent duplicate user within a tenant" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user)
        duplicate = build(:tenant_user, tenant: @tenant, user: @user)
        assert_not duplicate.valid?
      end
    end

    should "allow same user in different tenants" do
      other_tenant = create(:tenant)
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user) }
      ActsAsTenant.with_tenant(other_tenant) do
        other_membership = build(:tenant_user, tenant: other_tenant, user: @user)
        assert other_membership.valid?
      end
    end
  end

  context "#ensure_person!" do
    setup do
      @tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, person: nil) }
    end

    should "start no stream while the HRIS sync writes the tenant's people" do
      person = @tenant_user.ensure_person!

      assert_empty person_stream(person)
    end

    should "record a new person as Espalia's once the tenant is cut over to the Org Graph" do
      @tenant.update!(org_graph_people_projected_at: Time.current)

      recorded = person_stream(@tenant_user.ensure_person!).sole

      assert_kind_of OrgGraph::Events::PersonRecorded, recorded
      assert_equal [ "espalia", "employed" ], recorded.data.values_at(:provider, :employment_status)
    end

    context "for an existing person in a cut-over tenant" do
      setup do
        @tenant.update!(org_graph_people_projected_at: Time.current)
        @existing = ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .claim_facts(OrgGraph::StructureAggregate::HRIS_FACTS, "hibob", effective_on: "2026-11-01")
          create(:person, tenant: @tenant, email: @user.email, job_title: "Analyst", external_id: "bob-1", hris_source: "hibob")
        end
      end

      should "record one with no stream from their row, as their HRIS's" do
        assert_equal @existing, @tenant_user.ensure_person!

        assert_equal [ "hibob", "Analyst" ], person_stream(@existing).sole.data.values_at(:provider, :title)
      end

      should "leave one who already has a stream alone" do
        ActsAsTenant.with_tenant(@tenant) do
          OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .record_person(@existing.id, provider: "hibob", effective_on: "2026-11-01", employment_status: "employed")
        end

        @tenant_user.ensure_person!

        assert_equal 1, person_stream(@existing).size
      end
    end
  end

  private

  def person_stream(person)
    Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(person.id, tenant: @tenant)).to_a
  end
end
