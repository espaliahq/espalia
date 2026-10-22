# frozen_string_literal: true

# @label Field
class Kit::FieldPreview < Lookbook::Preview
  # A small form with one field per constant, all in one state.
  class Form < Components::Base
    def initialize(state:)
      @state = state
    end

    def view_template
      render Components::Kit::Card.new(title: "Request feedback") do |card|
        card.body do
          div(class: "grid max-w-md gap-4") do
            field("Who should give it?", "recipient") { |id| input(**text_attributes(id, Components::Kit::Field::INPUT, "Name or email", value: "Priya Raman")) }
            field("Capability", "capability") do |id|
              select_field(id)
              p(id: "capability-error-#{@state}", class: "text-sm text-danger") { "Choose a capability." } if invalid?
            end
            field("What should they comment on?", "prompt") { |id| textarea(**text_attributes(id, Components::Kit::Field::TEXTAREA, "A project, a meeting, a piece of work")) { filled? ? "How I ran the Q3 planning offsite" : nil } }
            field("Cycle name (inline editor)", "cycle") { |id| input(**text_attributes(id, Components::Kit::Field::INLINE, "Cycle name", value: "H2 2026 performance review")) }
            choice("Ask anonymously", "anonymous", "checkbox", Components::Kit::Field::CHECKBOX)
            fieldset(class: "grid gap-2") do
              legend(class: "text-sm font-medium text-default") { "Due" }
              choice("In a week", "due-week", "radio", Components::Kit::Field::RADIO, name: "due-#{@state}")
              choice("In a fortnight", "due-fortnight", "radio", Components::Kit::Field::RADIO, name: "due-#{@state}", checked: false)
            end
            p(id: "error-#{@state}", class: "text-sm text-danger") { "Enter a name or an email address." } if invalid?
          end
        end
      end
    end

    private

    def field(label_text, key)
      id = "#{key}-#{@state}"
      div(class: "grid gap-1") do
        label(for: id, class: "text-sm font-medium text-default") { label_text }
        yield id
      end
    end

    def text_attributes(id, classes, placeholder, value: nil)
      attributes = { id:, name: id, placeholder:, class: [ classes, (Components::Kit::Field::INVALID if invalid?) ], disabled: disabled? }
      attributes[:value] = value if filled?
      attributes[:autofocus] = true if @state == :focused && id.start_with?("recipient")
      attributes[:aria] = { invalid: "true", describedby: "error-#{@state}" } if invalid?
      attributes
    end

    def select_field(id)
      aria = invalid? ? { invalid: "true", describedby: "capability-error-#{@state}" } : {}
      select(id:, name: id, class: [ Components::Kit::Field::SELECT, (Components::Kit::Field::INVALID if invalid?) ], disabled: disabled?, aria:) do
        option(value: "") { "Choose a capability" }
        option(value: "delivery", selected: filled?) { "Delivery" }
        option(value: "collaboration") { "Collaboration" }
      end
    end

    def choice(label_text, key, type, classes, name: nil, checked: true)
      id = "#{key}-#{@state}"
      label(for: id, class: "flex items-center gap-2 text-sm text-default") do
        input(type:, id:, name: name || id, class: classes, checked: filled? && checked, disabled: disabled?)
        plain label_text
      end
    end

    def filled? = %i[filled focused disabled invalid].include?(@state)
    def disabled? = @state == :disabled
    def invalid? = @state == :invalid
  end

  # @!group States

  def empty
    render Form.new(state: :empty)
  end

  def filled
    render Form.new(state: :filled)
  end

  # The first field takes focus on load; tab on to see the rest.
  def focused
    render Form.new(state: :focused)
  end

  def disabled
    render Form.new(state: :disabled)
  end

  def invalid
    render Form.new(state: :invalid)
  end

  # @!endgroup
end
