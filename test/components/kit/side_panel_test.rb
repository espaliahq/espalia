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

    should "take the toggle's label from a block, keeping its controls" do
      html = Components::Kit::SidePanel.new(id: "plan-side-panel", title: "About this plan", open: true,
                                            cookie: "plan_side_panel_open", url_key: "panel").call do |panel|
        panel.main { panel.toggle { panel.plain "About "; panel.span(class: "sr-only") { "this plan" } } }
        panel.body { panel.p { "Rules" } }
      end
      toggle = Nokogiri::HTML5.fragment(html).at_css("button[data-activity-pane-target='toggle']")

      assert_equal "About this plan", toggle.text.strip
      assert_equal "this plan", toggle.at_css("span.sr-only").text
      assert_equal "plan-side-panel", toggle["aria-controls"]
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

    should "put the controller around the whole page when wrapped, with the row where columns places it" do
      html = Components::Kit::SidePanel.new(id: "activity", title: "Activity", open: false, cookie: "c", url_key: "activity",
                                            heading: false, sticky: true, fit_viewport: true).call do |panel|
        panel.main { panel.p { "Matrix" } }
        panel.body { panel.p { "Feed" } }
        panel.wrap do
          panel.tag(:page_header) { panel.render Components::Kit::SidePanel::Toggle.new(controls: "activity", open: false) { "Activity" } }
          panel.columns
        end
      end
      doc = Nokogiri::HTML5.fragment(html)

      host = doc.at_css("[data-controller='activity-pane']")
      assert_equal "true", host["data-activity-pane-fit-viewport-value"]
      assert_equal "keydown.esc@window->activity-pane#escape:capture", host["data-action"]
      assert_equal "true", host["data-activity-pane-screen-value"]
      assert host.at_css("page-header button[data-activity-pane-target='toggle'][aria-controls='activity']")
      aside = host.at_css("page-header + div aside#activity")
      assert_equal "Activity", aside["aria-label"]
      assert_includes aside["class"].split, "lg:sticky"
      assert_nil aside.at_css("h2")
      assert_equal "Feed", aside.text
    end

    should "close from a button the body draws" do
      button = Nokogiri::HTML5.fragment(Components::Kit::SidePanel::Close.new(label: "Close activity").call { "×" }).at_css("button")

      assert_equal "activity-pane#close", button["data-action"]
      assert_equal "Close activity", button["aria-label"]
    end

    should "keep a caller's data and aria on the toggle and the close button" do
      toggle = Nokogiri::HTML5.fragment(
        Components::Kit::SidePanel::Toggle.new(controls: "activity", open: true, data: { test_id: "t" }, aria: { describedby: "hint" }).call { "Activity" }
      ).at_css("button")
      assert_equal "t", toggle["data-test-id"]
      assert_equal "hint", toggle["aria-describedby"]
      assert_equal "click->activity-pane#toggle", toggle["data-action"]
      assert_equal "activity", toggle["aria-controls"]

      close = Nokogiri::HTML5.fragment(Components::Kit::SidePanel::Close.new(label: "Close", data: { test_id: "c" }).call { "×" }).at_css("button")
      assert_equal "c", close["data-test-id"]
      assert_equal "activity-pane#close", close["data-action"]
    end

    context ".open?" do
      should "take the URL's choice over the cookie's, and the cookie's over the default" do
        assert Components::Kit::SidePanel.open?(url: "open", cookie: "closed", default: false)
        assert_not Components::Kit::SidePanel.open?(url: nil, cookie: "closed", default: true)
        assert Components::Kit::SidePanel.open?(url: nil, cookie: nil, default: true)
      end

      should "skip a value that is neither open nor closed, as the controller does" do
        assert_not Components::Kit::SidePanel.open?(url: "OPEN", cookie: "closed", default: true)
        assert_not Components::Kit::SidePanel.open?(url: "", cookie: nil, default: false)
      end
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
