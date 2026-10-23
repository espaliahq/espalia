# frozen_string_literal: true

# An alert that floats over the page and removes itself. Everything but the
# float, the shadow and the timer comes from {Components::Kit::Alert}.
#
# @example The layout's flash messages
#   render Components::Kit::Toast::Stack.new do
#     render Components::Kit::Toast.new(tone: :success) { flash[:notice] } if flash[:notice]
#     render Components::Kit::Toast.new(tone: :danger) { flash[:alert] } if flash[:alert]
#   end
#
class Components::Kit::Toast < Components::Base
  # Overlays share Kit::Dropdown's shadow step
  FLOAT = "pointer-events-auto w-full shadow-lg"

  # @param tone [Symbol] see {Components::Kit::Alert::TONES}
  # @param emphasis [Symbol] :subtle or :solid
  # @param title [String, nil] a bold first line
  # @param icon [String, nil] a {Components::Kit::IconSprite} glyph to lead with
  # @param dismiss_after [Integer] milliseconds on screen; 0 keeps it until dismissed.
  #   Defaults to 7 seconds for danger, which takes longer to act on, and 5 otherwise.
  # @param role [Symbol, nil] :status or :alert; defaults to :alert for danger
  def initialize(tone: :neutral, emphasis: :subtle, title: nil, icon: nil, dismiss_after: nil, role: nil)
    @tone = tone
    @emphasis = emphasis
    @title = title
    @icon = icon
    @dismiss_after = dismiss_after || (tone == :danger ? 7000 : 5000)
    @role = role
  end

  def view_template(&)
    render Components::Kit::Alert.new(
      tone: @tone, emphasis: @emphasis, title: @title, icon: @icon, role: @role,
      dismissible: true, dismiss_after: @dismiss_after, class: FLOAT
    ), &
  end
end

# Where toasts stack: the top-right corner, below the navbar so it never
# covers the user menu, and full width less the gutters on a phone.
class Components::Kit::Toast::Stack < Components::Base
  CLASSES = "pointer-events-none fixed top-16 right-4 left-4 z-50 flex flex-col items-end gap-2 " \
            "sm:left-auto sm:w-96"

  def view_template(&)
    div(class: CLASSES, &)
  end
end
