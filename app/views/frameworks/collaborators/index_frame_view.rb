# frozen_string_literal: true

# Per-framework collaborators list + assignment form.
#
# Rendered:
# - Embedded in the framework settings page via a Turbo Frame
#   (`framework-collaborators`) for tenant admins.
# - Standalone via `/frameworks/:id/collaborators` for framework owners
#   who can manage collaborators but are not tenant admins.
#
# When Turbo fetches the frame, it extracts only the matching
# `<turbo-frame>` element, so the surrounding chrome below is harmless.
#
class Views::Frameworks::Collaborators::IndexFrameView < Views::Base
  # @param framework [FrameworkState::Framework]
  # @param rows [Array<FrameworkCollaboratorRow>]
  # @param people [Array<Person>]
  def initialize(framework:, rows:, people:)
    @framework = framework
    @rows = rows
    @people = people
  end

  def view_template
    turbo_frame_tag "framework-collaborators" do
      div(class: "space-y-4") do
        rows_table
        assignment_form_section
      end
    end
  end

  private

  def rows_table
    if @rows.any?
      div(class: "overflow-x-auto") do
        table(class: "min-w-full divide-y divide-gray-200 dark:divide-gray-700") do
          thead(class: "bg-gray-50 dark:bg-gray-900/50") do
            tr do
              th_label "Person"
              th_label "Role"
              th_label "Scope"
              th_label ""
            end
          end
          tbody(class: "divide-y divide-gray-200 dark:divide-gray-700") do
            @rows.each { |row| collaborator_row(row) }
          end
        end
      end
    else
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "No collaborators on this framework yet."
      end
    end
  end

  def collaborator_row(row)
    tr do
      cell { row.person_name }
      cell { render Components::Kit::Badge.new(row.role.humanize, variant: :info) }
      cell { row.scope_label }
      cell(extra_classes: "text-right") { remove_button(row) }
    end
  end

  def remove_button(row)
    form(
      action: framework_collaborator_path(@framework.framework_id, row.destroy_id),
      method: "post",
      class: "inline-block"
    ) do
      input(type: "hidden", name: "_method", value: "DELETE")
      input(type: "hidden", name: "authenticity_token",
            value: view_context.form_authenticity_token)
      button(
        type: "submit",
        class: "text-sm text-red-700 dark:text-red-400 hover:underline"
      ) { "Remove" }
    end
  end

  def assignment_form_section
    div(class: "pt-4 border-t border-gray-200 dark:border-gray-700") do
      h4(class: "text-sm font-semibold text-gray-900 dark:text-white mb-3") do
        "Add a collaborator"
      end
      render Views::Frameworks::Collaborators::AssignmentForm.new(
        form_url: framework_collaborators_path(@framework.framework_id),
        scope_picker_url: scope_picker_framework_collaborators_path(@framework.framework_id),
        framework: @framework,
        people: @people,
        person_locked: false
      )
    end
  end

  def th_label(text)
    th(class: "px-4 py-3 text-left text-xs font-medium uppercase tracking-wider " \
              "text-gray-600 dark:text-gray-300") { text }
  end

  def cell(extra_classes: nil, &block)
    classes = "px-4 py-3 text-sm text-gray-900 dark:text-gray-100"
    classes = "#{classes} #{extra_classes}" if extra_classes
    td(class: classes, &block)
  end
end
