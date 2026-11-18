# frozen_string_literal: true

require "test_helper"

class Views::Tenant::OrgGraph::UnitDrawerTest < ActiveSupport::TestCase
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
  end

  def render_drawer(unit_key, viewer, select: "select#org-unit-parent")
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: viewer.user, tenant_user: viewer, person: viewer.person)
      policy = OrgGraphPolicy.new(context, :org_graph)
      unit = OrgUnit.find(@org[unit_key])
      overview = OrgGraph::UnitsOverview.new(selected_unit_id: unit.id)
      drawer = Views::Tenant::OrgGraph::UnitDrawer.new(
        unit:, overview:, rights: OrgGraphPolicy::UnitRights.new(policy, unit, overview),
        confirmations: OrgGraphPolicy::Confirmations.new(policy, overview, OrgGraph::StaleFacts.new(person_ids: [])), effective_on: Date.current.iso8601
      )
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      Nokogiri::HTML5.fragment(controller.view_context.render(drawer)).at_css(select)
    end
  end

  # #448: with no option matching the current parent, the browser opened the select on Ledger.
  should "open the parent select on where the unit stays when its owner can't choose that parent" do
    owner = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :member, person: @org[:dot]) }
    ledger = own_two_squads(@tenant, @org, @org[:dot])

    select = render_drawer(:payments, owner)
    first = select.at_css("option")

    assert_equal [ "", ledger ], select.css("option").map { it["value"] }
    assert_equal "Checkout (stays where it is)", first.text
    assert first.key?("disabled") && first.key?("selected")
    assert select.key?("required"), "Move waits until they pick another parent"
  end

  should "open on the current parent, and leave the top a choice, for a structure editor" do
    admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :admin) }

    select = render_drawer(:payments, admin)

    assert_equal "Checkout", select.at_css("option[selected]").text.squish
    assert_equal "None (at the top)", select.at_css("option").text
    assert_not select.key?("required")
  end

  context "the unit type" do
    should "be a fact, not a control, for an owner of the unit and its parent" do
      owner = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :member, person: @org[:ada]) }
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      ActsAsTenant.with_tenant(@tenant) do
        %i[engineering platform].each { structure.add_unit_owner(@org[it], @org[:ada].id, effective_on: Date.current) }
      end

      assert render_drawer(:platform, owner), "an owner may still move it"
      assert_nil render_drawer(:platform, owner, select: "select#org-unit-type")
    end

    should "offer the types that fit to an Org Graph editor and a tenant admin" do
      editor, admin = ActsAsTenant.with_tenant(@tenant) do
        [ create(:tenant_user, tenant: @tenant, role: :member, org_graph_editor: true, person: @org[:ezra]),
          create(:tenant_user, tenant: @tenant, role: :admin) ]
      end

      [ editor, admin ].each do |viewer|
        select = render_drawer(:platform, viewer, select: "select#org-unit-type")
        assert_equal %w[Team Squad], select.css("option").map(&:text)
        assert_equal "Team", select.at_css("option[selected]").text
      end
    end
  end
end
