# frozen_string_literal: true

require "test_helper"

class Components::Kit::SidePanelTest < ActiveSupport::TestCase
  context "Components::Kit::SidePanel" do
    should "render the main column, the toggle where it's called and the panel, open" do
      doc = render_panel(open: true)

      host = doc.at_css("[data-controller='activity-pane']")
      assert_equal "plan_side_panel_open", host["data-activity-pane-cookie-value"]
      assert_equal "panel", host["data-activity-pane-url-key-value"]
      assert_equal "open", host["data-activity-pane-default-state-value"]

      toggle = doc.at_css("main-column button[data-activity-pane-target='toggle']")
      assert_equal "About this plan", toggle.text.strip
      assert_equal "true", toggle["aria-expanded"]
      assert_equal "plan-side-panel", toggle["aria-controls"]

      aside = doc.at_css("aside#plan-side-panel")
      assert_equal "open", aside["data-pane-state"]
      assert_not_includes aside["class"].split, "hidden"
      assert_equal "plan-side-panel-title", aside["aria-labelledby"]
      assert_equal "About this plan", aside.at_css("h2#plan-side-panel-title").text
      assert_equal "Rules", aside.at_css("p").text
      assert aside.at_css("button[data-action='activity-pane#close'][aria-label='Close about this plan']")
    end

    should "render closed, hidden until the controller opens it" do
      doc = render_panel(open: false)

      assert_equal "closed", doc.at_css("[data-controller='activity-pane']")["data-activity-pane-default-state-value"]
      assert_equal "false", doc.at_css("[data-activity-pane-target='toggle']")["aria-expanded"]
      aside = doc.at_css("aside")
      assert_equal "closed", aside["data-pane-state"]
      assert_includes aside["class"].split, "hidden"
    end

    should "overlay the page below lg by default, and leave a tap outside to close it" do
      doc = render_panel(open: true)

      assert_equal "true", doc.at_css("[data-controller]")["data-activity-pane-dismiss-outside-value"]
      assert_includes doc.at_css("aside")["class"].split, "max-lg:fixed"
    end

    should "stack under the main column below lg, where a tap outside is on the page" do
      doc = render_panel(open: true, narrow: :stack)

      assert_equal "false", doc.at_css("[data-controller]")["data-activity-pane-dismiss-outside-value"]
      assert_not_includes doc.at_css("aside")["class"].split, "max-lg:fixed"
    end
  end

  private

  def render_panel(**options)
    html = Components::Kit::SidePanel.new(id: "plan-side-panel", title: "About this plan",
                                          cookie: "plan_side_panel_open", url_key: "panel", **options).call do |panel|
      panel.main { panel.tag(:main_column) { panel.toggle } }
      panel.body { panel.p { "Rules" } }
    end
    Nokogiri::HTML5.fragment(html)
  end
end
