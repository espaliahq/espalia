# frozen_string_literal: true

require "test_helper"

class ProseTest < ActiveSupport::TestCase
  def html(text) = Nokogiri::HTML5.fragment(Prose.to_html(text))

  context ".to_html" do
    should "keep a single newline as a line break, as these fields always have" do
      assert_equal 1, html("line one\nline two").css("br").size
    end

    should "turn a pasted URL into a link that opens safely" do
      link = html("see https://example.com/x?a=1 now").at_css("a")

      assert_equal "https://example.com/x?a=1", link["href"]
      assert_equal "noopener noreferrer nofollow", link["rel"]
      assert_equal "_blank", link["target"]
    end

    should "render a Markdown link and a reference-style link" do
      assert_equal "https://example.com", html("[the doc](https://example.com)").at_css("a")["href"]
      assert_equal "https://example.com/ref", html("per [1]\n\n[1]: https://example.com/ref").at_css("a")["href"]
    end

    should "link a mailto address" do
      assert_equal "mailto:a@b.com", html("write to a@b.com").at_css("a")["href"]
    end

    should "render lists, emphasis and inline code" do
      fragment = html("- **a**\n- _b_ with `code`")

      assert_equal 2, fragment.css("ul li").size
      assert fragment.at_css("strong")
      assert fragment.at_css("em")
      assert_equal "code", fragment.at_css("code").text
    end

    should "show typed HTML as text instead of running or dropping it" do
      fragment = html("<script>alert(1)</script> hi\n<Component> renders wrong")

      assert_nil fragment.at_css("script")
      assert_includes fragment.text, "<script>alert(1)</script> hi"
      assert_includes fragment.text, "<Component> renders wrong"
    end

    should "never emit an event handler attribute" do
      fragment = html("<a href='https://e.com' onclick='x()'>e</a> [ok](https://e.com)")
      attributes = fragment.css("*").flat_map { |node| node.attribute_nodes.map(&:name) }

      assert_empty attributes.grep(/\Aon/i)
    end

    should "drop links to unsafe schemes but keep their text" do
      %w[javascript:alert(1) data:text/html;base64,PHNjcmlwdD4= vbscript:x].each do |href|
        fragment = html("[click](#{href})")

        assert_nil fragment.at_css("a"), "#{href} must not become a link"
        assert_includes fragment.text, "click"
      end
    end

    should "drop an unsafe reference definition" do
      assert_nil html("per [1]\n\n[1]: javascript:alert(1)").at_css("a")
    end

    should "turn an image into a plain link so nothing loads from a third party" do
      fragment = html("![pixel](https://tracker.example/p.gif)")

      assert_nil fragment.at_css("img")
      assert_equal "https://tracker.example/p.gif", fragment.at_css("a")["href"]
      assert_equal "pixel", fragment.at_css("a").text
    end

    should "keep a heading's text as a bold paragraph" do
      fragment = html("# 3 priority items")

      assert_empty fragment.css("h1, h2, h3, h4, h5, h6")
      assert_equal "3 priority items", fragment.at_css("p strong").text
    end

    should "allow only the tags in the allowlist" do
      tags = html("# h\n\n> quote\n\n1. one\n\n```\npre\n```\n\n~~gone~~ ![i](https://e.com/i.png)")
        .css("*").map(&:name).uniq

      assert_empty tags - Prose::ALLOWED_TAGS
    end

    should "return an empty string for blank input" do
      assert_equal "", Prose.to_html(nil)
      assert_equal "", Prose.to_html("  ")
    end
  end

  context ".to_plain" do
    should "keep a link's URL beside its text, so an excerpt can still be followed" do
      assert_equal "See the RFC (https://e.com)", Prose.to_plain("See [the RFC](https://e.com)")
    end

    should "not repeat a bare URL or an email address" do
      assert_equal "see https://e.com and a@b.com", Prose.to_plain("see https://e.com and a@b.com")
    end

    should "keep line breaks and put list items on their own lines" do
      assert_equal "Details:\n- bold item\n- second\n\nafter", Prose.to_plain("Details:\n- **bold** item\n- second\n\nafter")
      assert_equal "one\ntwo", Prose.to_plain("one\ntwo")
      assert_equal "a\n- one\n- two", Prose.to_plain("a\n\n- one\n\n- two")
    end

    should "keep typed angle brackets as typed" do
      assert_equal "<Component> renders wrong", Prose.to_plain("<Component> renders wrong")
    end

    should "return an empty string for blank input" do
      assert_equal "", Prose.to_plain(nil)
    end
  end
end
