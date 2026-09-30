# frozen_string_literal: true

require "test_helper"

# The alignment predicates per role (ADR-22): the reporting manager starts,
# completes and re-opens alignment against the home role or a lens role —
# never a delegate, the assessee or an admin outside the chain — and a lens
# role reads as alignment only once alignment against it has started.
class AssessmentPolicyRoleAlignmentTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @manager = create(:person, tenant: @tenant)
    @person = create(:person, tenant: @tenant, manager: @manager)
    @delegate = create(:person, tenant: @tenant)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    create(:manager_assessment_delegation, tenant: @tenant, person_id: @person.id,
           framework_id: @fx.framework_id, delegate_person_id: @delegate.id)
    @pm = @fx.pm.role_id
    set_home_status("started")
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def policy_for(person, admin: false)
    user = create(:user)
    tenant_user = create(:tenant_user, tenant: @tenant, user: user, person: person, role: admin ? :admin : :member)
    AssessmentPolicy.new(AuthorizationContext.new(user: user, tenant_user: tenant_user, person: person), @assignment)
  end

  def set_home_status(status)
    AssessmentCycleProgress.find_by!(cycle_id: @cycle_id, person_id: @person.id)
      .update!(status: status, started_at: 1.day.ago)
  end

  def role_row(status: "aligning")
    AssessmentCycleRoleAlignment.create!(tenant: @tenant, cycle_id: @cycle_id, person_id: @person.id,
      framework_id: @fx.framework_id, role_id: @pm, level_ordinal: 2, status: status,
      alignment_started_at: Time.current, alignment_started_by_id: @manager.id)
  end

  context "starting alignment against a lens role" do
    should "be the reporting manager's alone" do
      assert policy_for(@manager).start_alignment?(role_id: @pm)
      assert_not policy_for(@delegate).start_alignment?(role_id: @pm)
      assert_not policy_for(@person).start_alignment?(role_id: @pm)
      assert_not policy_for(create(:person, tenant: @tenant), admin: true).start_alignment?(role_id: @pm)
    end

    should "not wait for the home role, but happen once" do
      set_home_status("aligned")
      assert policy_for(@manager).start_alignment?(role_id: @pm)

      role_row
      assert_not policy_for(@manager).start_alignment?(role_id: @pm)
    end

    should "treat the home role named explicitly as home" do
      assert policy_for(@manager).start_alignment?(role_id: @fx.engineer.role_id)
      set_home_status("aligning")
      assert_not policy_for(@manager).start_alignment?(role_id: @fx.engineer.role_id)
    end
  end

  context "completing and re-opening a lens role's alignment" do
    should "follow that role's own lifecycle" do
      manager = policy_for(@manager)
      assert_not manager.complete_alignment?(role_id: @pm)

      role_row
      assert policy_for(@manager).complete_alignment?(role_id: @pm)
      assert_not policy_for(@manager).reopen_alignment?(role_id: @pm)
      assert_not policy_for(@delegate).complete_alignment?(role_id: @pm)
      assert_not policy_for(@person).complete_alignment?(role_id: @pm)

      AssessmentCycleRoleAlignment.find_by!(role_id: @pm).update!(status: "aligned")
      assert policy_for(@manager).reopen_alignment?(role_id: @pm)
      assert_not policy_for(@manager).complete_alignment?(role_id: @pm)
      assert_not policy_for(@delegate).reopen_alignment?(role_id: @pm)
    end
  end

  context "viewing a lens role as alignment" do
    should "wait for that role's alignment even when home is aligned" do
      set_home_status("aligned")
      assert policy_for(@person).view_alignment?
      assert_not policy_for(@person).view_alignment?(role_id: @pm)

      role_row
      assert policy_for(@person).view_alignment?(role_id: @pm)
      assert policy_for(@manager).view_alignment?(role_id: @pm)
    end
  end

  should "take agreed values while only a lens role's alignment is in progress" do
    assert_not policy_for(@person).create_alignment_rating?

    role_row
    assert policy_for(@person).create_alignment_rating?
    assert policy_for(@manager).create_alignment_rating?
    assert_not policy_for(@delegate).create_alignment_rating?
  end
end
