# frozen_string_literal: true

require "test_helper"

class Frameworks::EntityLabelsTest < ActiveSupport::TestCase
  context ".for" do
    should "call a role illustration an example — the whole reason this map exists" do
      assert_equal "Example", Frameworks::EntityLabels.for("role_illustration")
    end

    should "label every entity type a suggestion can target" do
      expected = {
        "role_illustration" => "Example",
        "behavioural_expectation" => "Expectation",
        "capability" => "Capability",
        "capability_category" => "Category",
        "role" => "Role",
        "role_family" => "Role family",
        "level" => "Level"
      }

      expected.each do |type, label|
        assert_equal label, Frameworks::EntityLabels.for(type), "#{type} should read as #{label}"
      end
    end

    # Guard: every entity type a suggestion can actually carry must have a
    # label, or a flash message would leak the raw identifier. Sourced from the
    # Operations' own enums so adding a type without a label fails here.
    should "never leak a raw identifier for a type a suggestion can carry" do
      types = (
        Operations::Frameworks::SuggestCreate::ALLOWED_CREATION_KEYS.keys +
        Operations::Frameworks::SuggestEdit::EDITABLE_FIELDS.keys +
        Frameworks::Aggregate::DELETABLE_ENTITY_TYPES +
        Frameworks::Aggregate::CLARIFIABLE_ENTITY_TYPES
      ).uniq

      assert_operator types.size, :>=, 7, "expected the suggestion entity types to be discoverable"

      types.each do |type|
        assert_includes Frameworks::EntityLabels::LABELS.keys, type,
                        "#{type} has no human label — add it to Frameworks::EntityLabels"
      end
    end

    should "accept a symbol" do
      assert_equal "Example", Frameworks::EntityLabels.for(:role_illustration)
    end

    should "humanize an unmapped type rather than raising" do
      assert_equal "Widget thing", Frameworks::EntityLabels.for("widget_thing")
    end

    should "fall back to a neutral word for a blank type" do
      assert_equal "change", Frameworks::EntityLabels.for(nil)
    end
  end

  context ".humanized" do
    should "read mid-sentence" do
      assert_equal "example", Frameworks::EntityLabels.humanized("role_illustration")
      assert_equal "role family", Frameworks::EntityLabels.humanized("role_family")
    end
  end
end
