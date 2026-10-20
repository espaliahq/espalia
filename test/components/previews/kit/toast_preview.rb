# frozen_string_literal: true

# @label Toast
class Kit::ToastPreview < Lookbook::Preview
  # Each toast stays until dismissed, so the preview holds still
  # @param message text
  # @param tone select { choices: [neutral, info, success, warning, danger] }
  # @param emphasis select { choices: [subtle, solid] }
  def playground(message: "Assessment cycle defined.", tone: :success, emphasis: :subtle)
    render_with_template(template: "kit/toast_preview/playground",
                         locals: { message: message, tone: tone.to_sym, emphasis: emphasis.to_sym })
  end

  # Every tone at both emphases, stacked as the layout shows them
  def stacked
    render_with_template(template: "kit/toast_preview/stacked")
  end

  # The layout's flash notice, gone after 5 seconds as in the app. Reload to see it again.
  def auto_dismiss
    render_with_template(template: "kit/toast_preview/auto_dismiss")
  end
end
