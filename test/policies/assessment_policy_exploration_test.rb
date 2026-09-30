# frozen_string_literal: true

require "test_helper"

# Declaring and closing an exploration (ADR-22) belongs to the people the
# conversation is between — the assessee, their reporting manager and an
# active rating delegate. A view-only ancestor, an admin outside the chain
# and a peer may not, and none of it needs an open cycle.
class AssessmentPolicyExplorationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @skip_level = create(:person, tenant: @tenant)
    @manager = create(:person, tenant: @tenant, manager: @skip_level)
    @person = create(:person, tenant: @tenant, manager: @manager)
    @delegate = create(:person, tenant: @tenant)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
           framework_id: @fx.framework_id, delegate_person_id: @delegate.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def policy_for(person, admin: false)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: person, role: admin ? :admin : :member)
    AssessmentPolicy.new(AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person), @assignment)
  end

  %i[start_exploration? close_exploration?].each do |query|
    context query.to_s do
      should "permit the assessee, the reporting manager and an active delegate" do
        assert policy_for(@person).public_send(query)
        assert policy_for(@manager).public_send(query)
        assert policy_for(@delegate).public_send(query)
      end

      should "deny a view-only ancestor, an admin outside the chain and a peer" do
        assert policy_for(@skip_level).show?, "the ancestor can read it"
        assert_not policy_for(@skip_level).public_send(query)
        assert_not policy_for(create(:person, tenant: @tenant), admin: true).public_send(query)
        assert_not policy_for(create(:person, tenant: @tenant)).public_send(query)
      end

      should "not need an open cycle" do
        AssessmentCycles::CommandHandler.new.close_cycle(@cycle_id)

        assert_nil @assignment.reload.current_open_cycle
        assert policy_for(@person).public_send(query)
      end
    end
  end
end
