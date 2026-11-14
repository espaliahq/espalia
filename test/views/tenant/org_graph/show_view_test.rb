# frozen_string_literal: true

require "test_helper"

# The Units view's two slots are the seam the screen stories build on: 5.2
# and 5.3 hand in a drawer, 5.4 a sidebar, and none of them edits ShowView.
class Views::Tenant::OrgGraph::ShowViewTest < ActiveSupport::TestCase
  include OrgGraphFixture

  class StubDrawer < Views::Base
    def view_template
      render(Views::Tenant::OrgGraph::Drawer.new(title: "Platform", close_href: "/back")) { p { "drawer body" } }
    end
  end

  class StubSidebar < Views::Base
    def view_template
      render(Views::Tenant::OrgGraph::Sidebar.new(title: "Activity")) { p { "sidebar body" } }
    end
  end

  class StubComparisonBar < Views::Base
    def view_template = p(id: "comparison-bar") { "Since 1 Oct" }
  end

  class StubComparison < OrgGraph::Comparison
    def unit_marks(unit) = { "Platform" => [ "was Core" ], "Engineering" => [ "moved" ] }.fetch(unit.name, [])

    def people_changes(unit)
      { "Platform" => [ PersonChange.new(name: "Brook Tamsin", text: "joined 5 Nov") ],
        "Engineering" => [ PersonChange.new(name: "Cyril Moss", text: "left 31 Oct") ] }.fetch(unit.name, [])
    end

    def window_label = "Since 1 Oct"
  end

  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :admin) }
    build_org_graph(@tenant)
  end

  def render_page(tenant: @tenant, selected_unit_id: nil, **slots)
    ActsAsTenant.with_tenant(tenant) do
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      user = @user
      controller.define_singleton_method(:current_user) { user }
      view = Views::Tenant::OrgGraph::ShowView.new(
        overview: OrgGraph::UnitsOverview.new(selected_unit_id:), user: @user, current_tenant: tenant, **slots
      )
      Nokogiri::HTML5(controller.view_context.render(view))
    end
  end

  should "leave both slots empty by default" do
    page = render_page

    assert page.at_css("#org-graph-unit")
    assert_nil page.at_css("##{Views::Tenant::OrgGraph::Drawer::ID}")
    assert_nil page.at_css("##{Views::Tenant::OrgGraph::Sidebar::ID}")
  end

  should "render a drawer handed in, titled and with a way back" do
    drawer = render_page(drawer: StubDrawer.new).at_css("aside##{Views::Tenant::OrgGraph::Drawer::ID}")

    assert_equal "Platform", drawer.at_css("##{Views::Tenant::OrgGraph::Drawer::ID}-title").text
    assert_equal "/back", drawer.at_css("a[aria-label='Close']")["href"]
    assert_includes drawer.text, "drawer body"
  end

  should "isolate a drawer that covers the page, and let focus land on its title" do
    drawer = render_page(drawer: StubDrawer.new).at_css("aside##{Views::Tenant::OrgGraph::Drawer::ID}")

    assert_equal "drawer-isolation", drawer["data-controller"]
    title = drawer.at_css("[data-drawer-isolation-target='title']")
    assert_equal "-1", title["tabindex"]
  end

  should "render a sidebar handed in beside the opened unit" do
    page = render_page(sidebar: StubSidebar.new)
    sidebar = page.at_css("aside##{Views::Tenant::OrgGraph::Sidebar::ID}")

    assert_equal "Activity", sidebar.at_css("h2").text
    assert_includes sidebar.text, "sidebar body"
    assert_equal page.at_css("#org-graph-unit").ancestors("div.flex-1").first.parent, sidebar.parent
  end

  should "keep a sidebar handed in when the graph has no units yet" do
    page = render_page(tenant: create(:tenant), sidebar: StubSidebar.new)

    assert_includes page.text, "No units yet"
    assert page.at_css("aside##{Views::Tenant::OrgGraph::Sidebar::ID}")
  end

  should "mark nothing and show no comparison bar by default" do
    page = render_page

    assert_nil page.at_css("#comparison-bar")
    refute_includes page.text, "was Core"
    assert_empty page.css("[aria-label^='Since']")
  end

  should "mark a unit in the tree and on its card, and list its people changes, from a comparison handed in" do
    page = render_page(comparison_bar: StubComparisonBar.new, comparison: StubComparison.new)

    assert_equal "Since 1 Oct", page.at_css("#comparison-bar").text
    tree_link = page.css("nav[aria-labelledby=org-graph-tree-label] a").find { it.at_css("span span").text == "Platform" }
    assert_includes tree_link.text, "was Core"
    card = page.css("[id^='unit-']").find { it.at_css("h4")&.text == "Platform" }
    assert_includes card.text, "was Core"
    assert_includes page.at_css("#org-graph-unit").parent.text, "moved"
    assert_equal "Brook Tamsin joined 5 Nov", card.at_css("[aria-label='Since 1 Oct in Platform'] li").text.squish
  end

  should "show the changes of an opened unit with no card of its own under its heading" do
    section = render_page(comparison: StubComparison.new).at_css("section[aria-labelledby=org-graph-unit]")

    assert_includes section.at_css("#org-graph-unit").parent.text, "moved"
    assert_equal "Cyril Moss left 31 Oct", section.at_css("[aria-label='Since 1 Oct in Engineering'] li").text.squish
    assert_nil section.at_css("[id^='unit-'] [aria-label='Since 1 Oct in Engineering']")
  end

  should "mark an opened unit with a card of its own once, on the card" do
    platform = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find_by!(name: "Platform") }
    page = render_page(comparison: StubComparison.new, selected_unit_id: platform.id)

    refute_includes page.at_css("#org-graph-unit").parent.text, "was Core"
    assert_includes page.at_css("#unit-#{platform.id}").text, "was Core"
  end
end
