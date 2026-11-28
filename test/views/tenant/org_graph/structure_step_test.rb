# frozen_string_literal: true

require "test_helper"

class Views::Tenant::OrgGraph::StructureStepTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @user = create(:user)
    @member = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member, person: @org[:ezra]) }
  end

  def render_step(step, key, **options)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @user, tenant_user: @member, person: @org[:ezra])
      unit = OrgUnit.find(@org[key])
      overview = OrgGraph::UnitsOverview.new(selected_unit_id: unit.id)
      rights = OrgGraphPolicy::UnitRights.new(OrgGraphPolicy.new(context, :org_graph), unit, overview)
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      html = controller.view_context.render(step.new(unit:, overview:, rights:, effective_on: "2026-11-28", **options))
      Nokogiri::HTML5(html)
    end
  end

  should "refuse a caller without the right in the command's words, naming only the unit" do
    page = render_step(Views::Tenant::OrgGraph::DeclareStructureStep, :checkout)

    assert_equal "You can change Checkout's structure if you own Checkout or a unit above it, " \
                 "have such an owner below you in your reporting line, or are an Org Graph editor.",
                 page.at_css("#org-unit-step-blocked").text.strip
    assert_nil page.at_css("form")
  end
end
