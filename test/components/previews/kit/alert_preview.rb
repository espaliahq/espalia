# frozen_string_literal: true

# @label Alert
class Kit::AlertPreview < Lookbook::Preview
  # @param message text
  # @param title text
  # @param tone select { choices: [neutral, info, success, warning, danger] }
  # @param emphasis select { choices: [subtle, solid] }
  # @param size select { choices: [sm, md] }
  # @param dismissible toggle
  def playground(message: "Ratings, evidence and comments are being migrated; you'll be notified when it's live.",
                 title: "Publishing v3…", tone: :neutral, emphasis: :subtle, size: :md, dismissible: false)
    render Components::Kit::Alert.new(
      tone: tone.to_sym, emphasis: emphasis.to_sym, size: size.to_sym,
      title: title.presence, dismissible: dismissible
    ) { message }
  end

  # Every tone × emphasis × size, with a title and without
  def matrix
    render_with_template(template: "kit/alert_preview/matrix")
  end

  # @!group Parts

  def message_only
    render Components::Kit::Alert.new(tone: :danger) { "Weight must be between 0 and 10." }
  end

  def with_title
    render Components::Kit::Alert.new(tone: :danger, title: "The last publish attempt failed") do
      "Archived capability “Systems thinking” has no migration mapping. Fix the mappings below and publish again."
    end
  end

  def with_icon
    render Components::Kit::Alert.new(tone: :info, icon: "discuss") do
      "Your feedback will be added to Priya's assessment — visible to Priya, their managers and workspace admins."
    end
  end

  def with_action
    render_with_template(template: "kit/alert_preview/with_action")
  end

  # The calibration "Ratings updated" note: neutral, dismissible, gone after 8 seconds
  def dismissible
    render Components::Kit::Alert.new(dismissible: true) { "Ratings updated. Readiness 76% → 78%." }
  end

  def solid_dismissible
    render Components::Kit::Alert.new(tone: :warning, emphasis: :solid, dismissible: true, title: "You're viewing as Priya") do
      "Changes you make are recorded as Priya's."
    end
  end

  def small_dismissible
    render Components::Kit::Alert.new(tone: :danger, size: :sm, dismissible: true) { "Couldn't save that rating. Try again." }
  end

  # @!endgroup
end
