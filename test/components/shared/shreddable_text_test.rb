# frozen_string_literal: true

require "test_helper"

class Components::Shared::ShreddableTextTest < ActiveSupport::TestCase
  def render_text(value) = Components::Shared::ShreddableText.new(value).call

  context "Components::Shared::ShreddableText" do
    should "show the value while its key is there" do
      assert_equal "Next year &amp; after", render_text(Shreddable::Value.new("Next year & after"))
    end

    should "say the value was removed once its key is gone" do
      assert_includes render_text(Shreddable::Value.removed), ">Removed</span>"
    end

    should "render nothing for no value" do
      assert_equal "", render_text(nil)
    end
  end
end
