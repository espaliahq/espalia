# frozen_string_literal: true

# Text a person wrote — feedback, a comment, a note — with its Markdown
# rendered. The only component that emits {::Prose} HTML; it inherits the
# caller's font size and colour, so it drops into any text slot.
#
# @example
#   render Components::Kit::Prose.new(@item.content, class: "mt-0.5 text-gray-700")
#
class Components::Kit::Prose < Components::Base
  # @param text [String, nil] the text as the author typed it
  # @param attributes [Hash] HTML attributes for the wrapper; `class` is appended
  def initialize(text, **attributes)
    @text = text
    @attributes = attributes
  end

  def view_template
    div(**@attributes.except(:class), class: [ "md-prose", @attributes[:class] ].compact.join(" ")) do
      raw(safe(::Prose.to_html(@text)))
    end
  end
end
