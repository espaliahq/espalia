# frozen_string_literal: true

require "test_helper"

# Disclosure and freeze are the union of every started role's scope
# (ADR-22); the home role's lifecycle is the participation's status, every
# other role's its alignment row.
class Assessments::DisclosureTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @fx = build_role_lens_framework(tenant: @tenant)
    @person = create(:person, tenant: @tenant)
    @assignment, @cycle_id = enrol_in_role_lens_framework(@person, @fx, tenant: @tenant)
    @home = Assessments::Lens.home(@assignment)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def lens_row(role, **attrs)
    create_row(role, home: false, **attrs)
  end

  def create_row(role, **attrs)
    AssessmentCycleRoleAlignment.create!(tenant: @tenant, cycle_id: @cycle_id, person_id: @person.id,
      framework_id: @fx.framework_id, role_id: role.role_id, level_ordinal: 2,
      alignment_started_at: Time.current, **attrs)
  end

  def disclosure(status: "started")
    Assessments::Disclosure.for(lens: @home, participant_status: status)
  end

  should "disclose and freeze nothing before any alignment starts" do
    d = disclosure

    assert_not d.include?(@fx.shared.stable_id, 2)
    assert_not d.frozen?(@fx.shared.stable_id, 2)
    assert_empty d.alignments
  end

  should "disclose the home scope once home alignment has started" do
    d = disclosure(status: "aligning")

    assert d.include?(@fx.e_only.stable_id, 2)
    assert_not d.include?(@fx.pm_only.stable_id, 2)
    assert_equal "E2", d.frozen_by(@fx.shared.stable_id, 2).code
  end

  should "disclose a lens role's scope once alignment against it has started" do
    lens_row(@fx.pm)
    d = disclosure

    assert d.include?(@fx.pm_only.stable_id, 2)
    assert d.include?(@fx.shared.stable_id, 1)
    assert_not d.include?(@fx.e_only.stable_id, 2)
    assert_equal [ "PM2" ], d.lens_alignments.map(&:code)
    assert_equal "Product Manager · PM2", d.alignment_for(@fx.pm.role_id).label
  end

  should "name the home alignment first when both froze a cell" do
    lens_row(@fx.pm)

    assert_equal "E2", disclosure(status: "aligning").frozen_by(@fx.shared.stable_id, 2).code
    assert_equal "PM2", disclosure(status: "aligning").frozen_by(@fx.pm_only.stable_id, 2).code
  end

  should "freeze every cell for a home alignment started before per-role alignment" do
    create_row(@fx.engineer, home: true, whole_assessment: true)
    d = disclosure(status: "aligning")

    assert d.frozen?(@fx.pm_only.stable_id, 2)
    assert_not d.include?(@fx.pm_only.stable_id, 2), "it still discloses only the home scope"
  end

  context "the agreed value" do
    should "move only while an alignment reading the cell is in progress" do
      lens_row(@fx.pm)
      d = disclosure

      assert_not d.agreed_value_locked?(@fx.pm_only.stable_id, 2, agreed: true)
      assert d.agreed_value_locked?(@fx.e_only.stable_id, 2, agreed: false)
    end

    should "never move where a completed alignment agreed it" do
      lens_row(@fx.pm)
      d = disclosure(status: "aligned")

      assert d.agreed_value_locked?(@fx.shared.stable_id, 2, agreed: true)
      assert_not d.agreed_value_locked?(@fx.shared.stable_id, 2, agreed: false)
    end
  end
end
