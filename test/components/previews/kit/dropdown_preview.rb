# frozen_string_literal: true

# @label Dropdown
class Kit::DropdownPreview < Lookbook::Preview
  # @param align select { choices: [left, right] }
  # @param strategy select { choices: [absolute, fixed] }
  def playground(align: :right, strategy: :absolute)
    comment_menu(align: align.to_sym, strategy: strategy.to_sym)
  end

  # @!group Strategy

  # Inside a box that clips its overflow: the open menu is cut off
  def absolute
    render_with_template(
      template: "kit/dropdown_preview/clipped", locals: { strategy: :absolute }
    )
  end

  # Inside the same box: the controller positions the menu against the viewport, so it escapes
  def fixed
    render_with_template(
      template: "kit/dropdown_preview/clipped", locals: { strategy: :fixed }
    )
  end

  # @!endgroup

  private

  def comment_menu(align:, strategy:)
    render_with_template(
      template: "kit/dropdown_preview/comment_menu", locals: { align: align, strategy: strategy }
    )
  end
end
