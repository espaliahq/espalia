# frozen_string_literal: true

require "test_helper"

class Components::Kit::IconSpriteTest < ActiveSupport::TestCase
  context "Components::Kit::IconSprite" do
    should "define one symbol per registered icon" do
      html = Components::Kit::IconSprite.new.call

      Components::Kit::IconSprite::NAMES.each do |name|
        assert_includes html, %(id="icon-#{name}")
      end
    end

    should "carry the presentation attributes so call sites need only size and colour" do
      html = Components::Kit::IconSprite.new.call

      assert_includes html, %(viewBox="0 0 24 24")
      assert_includes html, %(stroke="currentColor")
      assert_includes html, %(viewBox="0 0 20 20")
    end
  end

  context "the icon helper" do
    should "render a <use> reference rather than a path definition" do
      html = IconProbe.new("pencil").call

      assert_includes html, %(<use href="#icon-pencil")
      assert_includes html, %(class="w-3 h-3")
      assert_includes html, %(aria-hidden="true")
      assert_not_includes html, "<path"
    end

    should "pass extra attributes through to the svg" do
      html = IconProbe.new("chevron-right", data: { matrix_target: "rowChevron" }).call

      assert_includes html, %(data-matrix-target="rowChevron")
    end

    should "refuse an icon the sprite does not define" do
      assert_raises(ArgumentError) { IconProbe.new("no-such-glyph").call }
    end
  end

  # Minimal host so the helper can be exercised without dragging in a real view.
  class IconProbe < Components::Base
    def initialize(name, **attrs)
      @name = name
      @attrs = attrs
    end

    def view_template
      icon(@name, class: "w-3 h-3", **@attrs)
    end
  end
end
