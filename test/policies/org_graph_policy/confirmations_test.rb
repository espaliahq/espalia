# frozen_string_literal: true

require "test_helper"

class OrgGraphPolicy::ConfirmationsTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    travel 91.days
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def policy_for(viewer, role:)
    tenant_user = create(:tenant_user, tenant: @tenant, person: viewer, role:)
    OrgGraphPolicy.new(AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: viewer), :org_graph)
  end

  def overview = OrgGraph::UnitsOverview.new(selected_unit_id: @org[:checkout])

  def confirmations_for(viewer, role: :member)
    as_tenant do
      OrgGraphPolicy::Confirmations.new(policy_for(viewer, role:), overview, OrgGraph::StaleFacts.new(person_ids: Person.ids))
    end
  end

  def membership(person, key)
    as_tenant { OrgMembership.includes(:person).find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  should "flag the stale memberships of the cards on screen, and let an admin confirm them" do
    confirmations = as_tenant do
      OrgGraphPolicy::Confirmations.for_cards(policy_for(create(:person, tenant: @tenant), role: :admin), overview)
    end

    assert confirmations.membership(membership(:cyril, :checkout))
    assert confirmations.membership(membership(:dot, :payments))
    assert confirmations.membership?(membership(:cyril, :checkout))
    assert confirmations.facts?(@org[:cyril])
  end

  should "let a manager confirm a report's membership but not their own facts" do
    as_tenant { @org[:cyril].update!(manager: @org[:ada]) }
    confirmations = confirmations_for(@org[:ada])

    assert confirmations.membership?(membership(:cyril, :checkout))
    assert_not confirmations.membership?(membership(:dot, :payments))
    assert_not confirmations.facts?(@org[:cyril])
  end

  should "never offer to confirm a membership an HRIS supplies" do
    as_tenant do
      @org[:cyril].update_columns(hris_source: "hibob", external_id: "hb-cyril")
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .set_membership(@org[:cyril].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
    end
    confirmations = as_tenant do
      OrgGraphPolicy::Confirmations.for_cards(policy_for(create(:person, tenant: @tenant), role: :admin), overview)
    end

    assert_not confirmations.membership?(membership(:cyril, :engineering))
  end
end
