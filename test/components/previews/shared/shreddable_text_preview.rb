# frozen_string_literal: true

# @label Shreddable text
class Shared::ShreddableTextPreview < Lookbook::Preview
  # A value whose key is still there
  def present
    render Components::Shared::ShreddableText.new(Shreddable::Value.new("Next year's platform team"))
  end

  # Once its plan is deleted or its person forgotten
  def removed
    render Components::Shared::ShreddableText.new(Shreddable::Value.removed)
  end
end
