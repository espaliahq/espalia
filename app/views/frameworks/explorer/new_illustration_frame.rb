# frozen_string_literal: true

# Renders an "Add illustration" inline form inside a Turbo Frame.
#
# After a successful POST the controller returns a Turbo Stream that:
# 1. Appends the new IllustrationFrame to `ul#illustrations-{eid}-{rid}`
# 2. Replaces this frame with a fresh copy (button visible, form hidden)
#
# Reuses the inline-editor Stimulus controller — same display/form/input
# target pattern as IllustrationFrame.
#
class Views::Frameworks::Explorer::NewIllustrationFrame < Views::Base
  # @param expectation_id [String] UUID of the parent expectation
  # @param role_id [String] UUID of the role this illustration will belong to
  # @param framework_id [String] UUID of the framework (for the POST URL)
  def initialize(expectation_id:, role_id:, framework_id:)
    @expectation_id = expectation_id
    @role_id = role_id
    @framework_id = framework_id
  end

  def view_template
    turbo_frame_tag("new-illustration-#{@expectation_id}-#{@role_id}") do
      div(
        class: "group/new-ill pl-2 mt-1",
        data: { controller: "inline-editor" }
      ) do
        add_button
        add_form
      end
    end
  end

  private

  def add_button
    button(
      type: "button",
      class: "text-xs text-gray-400 hover:text-primary flex items-center gap-1 py-0.5",
      data: { inline_editor_target: "display", action: "inline-editor#startEdit" }
    ) do
      svg(
        class: "w-3 h-3", fill: "none", viewBox: "0 0 24 24",
        stroke: "currentColor", stroke_width: "2"
      ) do |s|
        s.path(d: "M12 4v16m8-8H4")
      end
      plain "Add illustration"
    end
  end

  def add_form
    form(
      class: "hidden",
      method: "post",
      action: framework_illustrations_path(framework_id: @framework_id),
      data: {
        inline_editor_target: "form",
        turbo: "true",
        action: "turbo:submit-end->inline-editor#submitted"
      }
    ) do
      input(type: "hidden", name: "illustration[expectation_id]", value: @expectation_id)
      input(type: "hidden", name: "illustration[role_id]", value: @role_id)

      textarea(
        class: "w-full text-xs border border-primary rounded px-2 py-1 " \
               "bg-white dark:bg-gray-900 text-gray-900 dark:text-white " \
               "resize-none focus:outline-none focus:ring-1 focus:ring-primary",
        rows: "3",
        name: "illustration[description]",
        placeholder: "Describe how this behaviour shows up in this role…",
        data: { inline_editor_target: "input" }
      ) { "" }

      div(class: "flex gap-1 mt-1") do
        button(
          type: "submit",
          class: "text-xs px-2 py-0.5 rounded bg-primary text-white hover:bg-primary/90"
        ) { "Add" }
        button(
          type: "button",
          class: "text-xs px-2 py-0.5 rounded border border-gray-300 dark:border-gray-600 " \
                 "text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800",
          data: { action: "inline-editor#cancel" }
        ) { "Cancel" }
      end
    end
  end
end
