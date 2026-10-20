# frozen_string_literal: true

require "test_helper"

# The two component classes in application.css stand in for a Kit component
# where its utility string would repeat hundreds of times a frame (#383), so
# each must stay the component's own look.
class KitCssComponentsTest < ActiveSupport::TestCase
  should "build .kit-btn-secondary from Kit::Button's outline neutral classes" do
    expected = Components::Kit::Button.classes(variant: :outline, tone: :neutral, size: :md, touch: true).split

    assert_equal expected.sort, applied(".kit-btn-secondary").sort
  end

  should "build .kit-alert-panel from a small danger Kit::Alert's classes" do
    html = Components::Kit::Alert.new(tone: :danger, size: :sm).call { "x" }
    alert = Nokogiri::HTML5.fragment(html).at_css("div")["class"].split

    assert_empty applied(".kit-alert-panel") - alert, "every class the panel applies is one the Alert renders"
    assert_includes applied(".kit-alert-panel"), "tone-danger"
  end

  private

  def applied(selector)
    css = Rails.root.join("app/assets/tailwind/application.css").read
    rule = css[/^#{Regexp.escape(selector)} \{\s*@apply ([^;]+);/, 1]
    assert rule, "#{selector} should be one @apply"
    rule.split
  end
end
