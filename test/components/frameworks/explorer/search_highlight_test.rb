# frozen_string_literal: true

require "test_helper"

# Minimal Phlex host for the concern under test — a top-level qualified class
# (not nested) per the repo's `class Module::ClassName` convention.
class Views::Frameworks::Explorer::SearchHighlightTestHarness < Phlex::HTML
  include Views::Frameworks::Explorer::Concerns::SearchHighlight

  def initialize(text:, query:)
    @text = text
    @query = query
  end

  def view_template
    span { render_highlighted(@text, @query) }
  end
end

# Unit-tests the SearchHighlight concern via the harness above, so the highlight
# logic (token matching, case-insensitivity, overlap merging, escaping) is
# exercised without the matrix frames' view-context needs.
class Views::Frameworks::Explorer::SearchHighlightTest < ActiveSupport::TestCase
  def render_highlighted(text, query)
    Views::Frameworks::Explorer::SearchHighlightTestHarness.new(text: text, query: query).call
  end

  context "search highlighting" do
    should "wrap a single match in <mark>, preserving surrounding text" do
      html = render_highlighted("Strategic Thinking", "strategic")
      assert_match %r{<mark[^>]*>Strategic</mark>}, html
      assert_includes html, "Thinking"
    end

    should "be case-insensitive but keep the original casing inside the mark" do
      html = render_highlighted("Strategic Thinking", "STRATEGIC")
      assert_match %r{<mark[^>]*>Strategic</mark>}, html
    end

    should "highlight every query token" do
      html = render_highlighted("Stakeholder Management", "stakeholder management")
      assert_match %r{<mark[^>]*>Stakeholder</mark>}, html
      assert_match %r{<mark[^>]*>Management</mark>}, html
    end

    should "merge overlapping token matches into a single mark" do
      # "dat" → [0,3), "ata" → [1,4); merged to [0,4) — "data" marked once.
      html = render_highlighted("data", "dat ata")
      assert_equal 1, html.scan("<mark").size
      assert_match %r{<mark[^>]*>data</mark>}, html
    end

    should "not mark anything when the query is blank" do
      assert_not_includes render_highlighted("Strategic Thinking", nil), "<mark"
      assert_not_includes render_highlighted("Strategic Thinking", "   "), "<mark"
    end

    should "not mark anything when nothing matches" do
      assert_not_includes render_highlighted("Strategic Thinking", "zzz"), "<mark"
    end

    should "escape the source text (no HTML injection)" do
      html = render_highlighted("A <b>bold</b> move", "bold")
      assert_not_includes html, "<b>bold</b>"
      assert_includes html, "&lt;b&gt;"
    end
  end
end
