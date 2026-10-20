# frozen_string_literal: true

# @label Modal
class Kit::ModalPreview < Lookbook::Preview
  # @param title text
  # @param size select { choices: [sm, md, lg, xl, 2xl, 3xl] }
  # @param dismiss_on_outside_click toggle
  def playground(title: "Manage delegates", size: :md, dismiss_on_outside_click: false)
    render Components::Kit::Modal.new(
      id: "modal-playground", title: title, size: size.to_sym,
      dismiss_on_outside_click: dismiss_on_outside_click
    ) do |modal|
      modal.trigger { "Delegates" }
      modal.body do
        modal.p(class: "text-sm text-muted") do
          "Delegates can record manager ratings for Priya Natarajan but cannot start or complete alignment."
        end
      end
    end
  end

  # @!group Sizes

  def small
    render Components::Kit::Modal.new(id: "modal-small", title: "Stop exploring E3?", size: :sm) do |modal|
      modal.trigger { "Stop exploring" }
      modal.body do
        modal.p(class: "text-sm text-muted") do
          "Your ratings against E3 stay on record. You can explore it again later."
        end
      end
    end
  end

  def medium
    render Components::Kit::Modal.new(id: "modal-medium", title: "Manage delegates") do |modal|
      modal.trigger { "Delegates · 2" }
      modal.body do
        modal.p(class: "text-sm text-muted") do
          "Delegates can record manager ratings for Priya Natarajan but cannot start or complete alignment."
        end
      end
    end
  end

  # Informational, so a click on the backdrop closes it
  def large
    render Components::Kit::Modal.new(
      id: "modal-large", title: "How is this calculated?", size: :lg, dismiss_on_outside_click: true
    ) do |modal|
      modal.trigger { "How is this calculated?" }
      modal.body do
        modal.div(class: "space-y-3 text-sm text-muted") do
          modal.p do
            "The score is how much of what E3 expects the ratings show, across every capability. " \
              "Feedback and comments are not part of it."
          end
          modal.p do
            "Some capabilities count for more or less than others: a ×2 capability moves the number " \
              "twice as much as a ×1 one, and a ×0.5 one half as much."
          end
        end
      end
    end
  end

  def extra_large
    render Components::Kit::Modal.new(id: "modal-xl", title: "Give feedback", size: :xl) do |modal|
      modal.trigger { "Give feedback" }
      modal.body do
        modal.p(class: "text-sm text-muted") { "Room for a long form: the capability, the evidence and who can see it." }
      end
    end
  end

  def double_extra_large
    render Components::Kit::Modal.new(id: "modal-2xl", title: "Request feedback", size: :"2xl") do |modal|
      modal.trigger { "Request feedback" }
      modal.body do
        modal.p(class: "text-sm text-muted") { "Room for a form with a recipient picker beside it." }
      end
    end
  end

  def triple_extra_large
    render Components::Kit::Modal.new(id: "modal-3xl", title: "Feedback / evidence", size: :"3xl") do |modal|
      modal.trigger { "Add evidence" }
      modal.body do
        modal.p(class: "text-sm text-muted") { "The widest size, 768px: the evidence and request-evidence forms." }
      end
    end
  end

  # @!endgroup

  # No title bar: the body draws its own heading and ×, and the title still names the dialog
  def without_header
    render_with_template
  end

  # Already open, as it looks after its trigger is clicked
  def open
    render_with_template(template: "kit/modal_preview/open")
  end
end
