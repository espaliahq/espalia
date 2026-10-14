# frozen_string_literal: true

require "test_helper"

class Components::Kit::ProseTest < ActiveSupport::TestCase
  context "Components::Kit::Prose" do
    should "render the author's Markdown inside the md-prose wrapper, keeping the caller's class and data" do
      html = Components::Kit::Prose.new("See [the doc](https://example.com)",
                                        class: "mt-0.5", data: { comments_thread_target: "displayBody" }).call
      wrapper = Nokogiri::HTML5.fragment(html).at_css("div")

      assert_equal "md-prose mt-0.5", wrapper["class"]
      assert_equal "displayBody", wrapper["data-comments-thread-target"]
      assert_equal "https://example.com", wrapper.at_css("a")["href"]
    end

    should "show typed HTML as text, never as markup" do
      html = Components::Kit::Prose.new("<img src=x onerror=alert(1)>").call

      assert_nil Nokogiri::HTML5.fragment(html).at_css("img")
      assert_includes Nokogiri::HTML5.fragment(html).text, "<img src=x onerror=alert(1)>"
    end
  end
end
