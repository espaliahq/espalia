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

  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :admin) }
    build_org_graph(@tenant)
  end

  def render_page(**slots)
    ActsAsTenant.with_tenant(@tenant) do
      controller = ApplicationController.new
      controller.request = ActionDispatch::TestRequest.create
      user = @user
      controller.define_singleton_method(:current_user) { user }
      view = Views::Tenant::OrgGraph::ShowView.new(
        overview: OrgGraph::UnitsOverview.new, user: @user, current_tenant: @tenant, **slots
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

  should "render a sidebar handed in beside the opened unit" do
    page = render_page(sidebar: StubSidebar.new)
    sidebar = page.at_css("aside##{Views::Tenant::OrgGraph::Sidebar::ID}")

    assert_equal "Activity", sidebar.at_css("h2").text
    assert_includes sidebar.text, "sidebar body"
    assert_equal page.at_css("#org-graph-unit").ancestors("div.flex-1").first.parent, sidebar.parent
  end
end
