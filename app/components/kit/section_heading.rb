# frozen_string_literal: true

# Section header with title and optional subtitle.
#
# @example
#   render Components::Kit::SectionHeading.new("Role Families", subtitle: "7 families, 11 roles")
#
# @example With action slot
#   render Components::Kit::SectionHeading.new("Capabilities") do |heading|
#     heading.action { a(href: "#") { "View All" } }
#   end
#
class Components::Kit::SectionHeading < Components::Base
  # @param title [String] the section title
  # @param subtitle [String, nil] optional subtitle text
  # @param tag [Symbol] HTML heading tag (:h2, :h3, etc.)
  def initialize(title, subtitle: nil, tag: :h2)
    @title = title
    @subtitle = subtitle
    @tag = tag
  end

  def view_template
    div(class: "flex items-baseline justify-between mb-4") do
      div do
        send(@tag, class: heading_classes) { @title }
        p(class: "mt-1 text-sm text-muted") { @subtitle } if @subtitle
      end
      yield(self) if block_given?
    end
  end

  # Renders the action slot (right-aligned).
  #
  # @yield the action content
  def action(&block)
    div(&block)
  end

  private

  def heading_classes
    case @tag
    when :h2 then "text-xl font-bold text-default"
    when :h3 then "text-lg font-semibold text-default"
    else "text-base font-semibold text-default"
    end
  end
end
