# frozen_string_literal: true

# "Start alignment against PM3" — the confirmation for starting alignment
# against a lens role (ADR-22). Starting it is the one deliberate act that
# shares the manager's ratings on the role's cells with the assessee and
# freezes both parties' ratings there, so it asks first, in a dialog
# rather than `confirm()`. Mounted with the page's other embedded modals.
class Views::Assessments::StartLensAlignmentModal < Views::Base
  ID = "start-lens-alignment-modal"

  # @param lens [Assessments::Lens] the lens role and level to align against
  # @param assessment_id [String]
  # @param assessee_name [String]
  def initialize(lens:, assessment_id:, assessee_name:)
    @lens = lens
    @assessment_id = assessment_id
    @first_name = assessee_name.to_s.split.first.presence || "them"
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Start alignment against #{@lens.code}?",
                                      standalone: false) do |modal|
      modal.body { body }
    end
  end

  private

  def body
    form(action: assessment_alignment_start_path(@assessment_id), method: "post", class: "space-y-4") do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "as_role", value: @lens.role.role_id)
      input(type: "hidden", name: "as_level", value: @lens.level.ordinal)
      ul(class: "list-disc pl-5 space-y-1 text-sm text-gray-700 dark:text-gray-200") do
        li { "#{@first_name} sees your ratings on the #{@lens.label} capabilities." }
        li { "Both of your ratings on those capabilities lock, including the ones #{@lens.home_code} shares." }
        li { "Capabilities you already agree on are agreed automatically." }
      end
      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        "#{@first_name}'s #{@lens.home_code} assessment is unchanged."
      end
      div(class: "flex justify-end gap-2 pt-1") do
        button(type: "button", data: { action: "click->modal#close" },
               class: "text-sm font-medium px-3 py-1.5 rounded-md border border-gray-300 dark:border-gray-600 " \
                      "text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer") do
          "Cancel"
        end
        button(type: "submit",
               class: "text-sm font-semibold px-3 py-1.5 rounded-md bg-gray-900 dark:bg-white text-white " \
                      "dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-gray-100 cursor-pointer") do
          "Start alignment"
        end
      end
    end
  end
end
