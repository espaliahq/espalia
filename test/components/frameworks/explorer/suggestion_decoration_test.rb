# frozen_string_literal: true

require "test_helper"

# Unit coverage for the pure styling helpers on the SuggestionDecoration concern
# — the "wiggle is the universal differs-from-published signal" rule.
class Views::Frameworks::Explorer::SuggestionDecorationTest < ActiveSupport::TestCase
  # Minimal host — the concern's class/string helpers don't need Phlex rendering.
  class Host
    include Views::Frameworks::Explorer::Concerns::SuggestionDecoration
  end

  setup { @d = Host.new }

  WIGGLE = "decoration-amber-400"

  context "#suggestion_text_classes" do
    should "return the wiggle for a pending edit" do
      assert_includes @d.suggestion_text_classes(pending_edit_count: 1), WIGGLE
    end

    should "return the wiggle for an added-in-draft entity (no pill needed)" do
      assert_includes @d.suggestion_text_classes(added_in_draft: true), WIGGLE
    end

    should "return nothing for a published, unchanged entity" do
      assert_equal "", @d.suggestion_text_classes
    end

    should "prefer the delete strikethrough over edit/draft decoration" do
      classes = @d.suggestion_text_classes(pending_delete_count: 1, added_in_draft: true)
      assert_includes classes, "line-through"
      assert_not_includes classes, WIGGLE
    end
  end

  context "#draft_change_title" do
    should "describe the not-yet-published state when added in draft" do
      assert_match(/not yet published/i, @d.draft_change_title(true))
    end

    should "be nil when not added in draft" do
      assert_nil @d.draft_change_title(false)
    end
  end
end
