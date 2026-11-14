# frozen_string_literal: true

# A shreddable value as text, or "Removed" once its key is destroyed: its plan
# was deleted, or the person it was about forgotten.
#
# @example
#   render Components::Shared::ShreddableText.new(plan.name)
#
class Components::Shared::ShreddableText < Components::Base
  # @param value [Shreddable::Value, nil]
  def initialize(value)
    @value = value
  end

  def view_template
    return if @value.nil?

    if @value.removed?
      span(class: "text-muted italic") { "Removed" }
    else
      plain @value.reveal.to_s
    end
  end
end
