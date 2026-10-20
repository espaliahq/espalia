# frozen_string_literal: true

# Inline-editable planned end date for an assessment cycle. The planned end
# is a soft deadline — it carries no domain invariant; participants and admins
# see it as a target completion date.
#
# Display mode: "Target completion: <formatted date>" or "Target completion: not set".
# Edit mode (admin + open cycle): a date input. Submitting a blank value clears
# the date.
#
class Views::AssessmentCycles::CyclePlannedEndFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  # @param cycle [AssessmentCycle]
  # @param is_admin [Boolean]
  def initialize(cycle:, is_admin:)
    @cycle = cycle
    @is_admin = is_admin
  end

  def view_template
    turbo_frame_tag("cycle-planned-end-#{@cycle.cycle_id}") do
      if editable?
        editable
      else
        plain_value
      end
    end
  end

  private

  def editable?
    @is_admin && @cycle.open?
  end

  def display_text
    if @cycle.planned_end_at
      @cycle.planned_end_at.strftime("%-d %b %Y")
    else
      "not set"
    end
  end

  def plain_value
    span(class: value_classes) { display_text }
  end

  def value_classes
    if @cycle.planned_end_at
      "font-medium text-default"
    else
      "italic text-muted"
    end
  end

  def editable
    div(class: "group/ine inline-flex items-center gap-1",
        data: { controller: "inline-editor" }) do
      div(class: "flex items-center gap-1",
          data: { inline_editor_target: "display" }) do
        plain_value
        pencil
      end
      edit_form
    end
  end

  def pencil
    button(
      type: "button",
      class: "opacity-0 group-hover/ine:opacity-100 group-focus-within/ine:opacity-100 " \
             "focus-visible:opacity-100 transition-opacity text-muted hover:text-brand shrink-0",
      data: { action: "inline-editor#startEdit" },
      aria_label: "Edit planned end date"
    ) do
      svg(class: "w-3.5 h-3.5", fill: "none", viewBox: "0 0 24 24",
          stroke: "currentColor", stroke_width: "2") do |s|
        s.path(d: "M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5" \
                  "m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z")
      end
    end
  end

  def edit_form
    form(
      class: "hidden",
      method: "post",
      action: set_planned_end_assessment_cycle_path(@cycle),
      data: { inline_editor_target: "form", turbo: "true" }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div(class: "inline-block") do
        input(
          type: "date",
          name: "assessment_cycle[planned_end_at]",
          value: @cycle.planned_end_at&.iso8601,
          class: Components::Kit::Field::INLINE,
          data: { inline_editor_target: "input" }
        )
      end
      div(class: "inline-flex gap-1 ml-2") do
        render Components::Kit::Button.new(tone: :brand, size: :xs, type: :submit) { "Save" }
        render Components::Kit::Button.new(
          variant: :outline, size: :xs, data: { action: "inline-editor#cancel" }
        ) { "Cancel" }
      end
    end
  end
end
