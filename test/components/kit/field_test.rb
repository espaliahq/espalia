# frozen_string_literal: true

require "test_helper"

class Components::Kit::FieldTest < ActiveSupport::TestCase
  CONSTANTS = %i[INPUT TEXTAREA SELECT INLINE CHECKBOX RADIO INVALID].freeze
  TEXT_FIELDS = %i[INPUT TEXTAREA SELECT INLINE].freeze

  class FormFixture < Components::Base
    def view_template
      label(for: "name") { "Name" }
      input(id: "name", class: [ Components::Kit::Field::INPUT, Components::Kit::Field::INVALID ], aria: { invalid: "true" })
      select(id: "capability", class: Components::Kit::Field::SELECT) { option { "Delivery" } }
    end
  end

  context "Components::Kit::Field" do
    should "colour every field from roles, not palette steps" do
      CONSTANTS.each do |name|
        assert_no_match(/\b(gray|slate|red|blue|teal)-\d{2,3}\b/, Components::Kit::Field.const_get(name), name.to_s)
      end
    end

    should "show focus on a text field as its edge, not an offset ring" do
      TEXT_FIELDS.each do |name|
        classes = Components::Kit::Field.const_get(name)
        assert_includes classes, "focus:border-strong", name.to_s
        assert_no_match(/ring-offset|ring-2|ring-primary/, classes, name.to_s)
      end
    end

    should "put the classes on a field rendered in a form" do
      html = Nokogiri::HTML5.fragment(FormFixture.new.call)
      input_classes = html.at_css("input#name")["class"].split

      assert_empty Components::Kit::Field::INPUT.split - input_classes
      assert_includes input_classes, "border-danger-strong!"
      assert_includes html.at_css("select#capability")["class"], "pr-10"
    end
  end
end
