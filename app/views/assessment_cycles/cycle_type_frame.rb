# frozen_string_literal: true

# Inline-editable cycle type. Renders the type as a labelled value with a
# pencil affordance (when admin + open); the form switches to a <select>.
#
# Submitting PATCHes {AssessmentCyclesController#change_type} and the
# response carries the updated value back into this frame.
#
class Views::AssessmentCycles::CycleTypeFrame < Views::Base
  include Phlex::Rails::Helpers::TurboFrameTag

  CYCLE_TYPE_LABELS = {
    "regular" => "Regular",
    "performance_review" => "Performance Review",
    "promotion_review" => "Promotion Review"
  }.freeze

  # @param cycle [AssessmentCycle]
  # @param is_admin [Boolean]
  def initialize(cycle:, is_admin:)
    @cycle = cycle
    @is_admin = is_admin
  end

  def view_template
    turbo_frame_tag("cycle-type-#{@cycle.cycle_id}") do
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

  def plain_value
    span(class: "font-medium text-default") { current_label }
  end

  def current_label
    CYCLE_TYPE_LABELS.fetch(@cycle.cycle_type, @cycle.cycle_type)
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
      aria_label: "Edit cycle type"
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
      action: change_type_assessment_cycle_path(@cycle),
      data: { inline_editor_target: "form", turbo: "true" }
    ) do
      input(type: "hidden", name: "_method", value: "patch")
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      div(class: "inline-block") do
        select(
          name: "assessment_cycle[cycle_type]",
          class: Components::Kit::Field::SELECT,
          data: { inline_editor_target: "input" }
        ) do
          AssessmentCycle::CYCLE_TYPES.each do |type|
            option(value: type, selected: (type == @cycle.cycle_type)) do
              plain CYCLE_TYPE_LABELS.fetch(type, type.humanize)
            end
          end
        end
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
