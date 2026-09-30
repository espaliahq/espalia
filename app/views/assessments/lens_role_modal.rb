# frozen_string_literal: true

# "Read against another role" — the header lens control's second step.
#
# A plain GET form to the assessment page with `as_role` and `as_level`, so
# the result is an ordinary URL. The role select groups roles by family; the
# level select lists the chosen role's levels and, when the role changes,
# keeps the ordinal the reader started from if the new role has it
# (`lens-picker`). Mounted on the page root beside the other embedded modals.
class Views::Assessments::LensRoleModal < Views::Base
  ID = "lens-role-modal"

  # @param lens [Assessments::Lens]
  # @param assessment_id [String]
  # @param whose [String] "your", or the assessee's name with "'s"
  def initialize(lens:, assessment_id:, whose: "your")
    @lens = lens
    @assessment_id = assessment_id
    @whose = whose
  end

  def view_template
    render Components::Kit::Modal.new(id: ID, title: "Read against another role", standalone: false) do |modal|
      modal.body { form_body }
    end
  end

  private

  def form_body
    form(action: assessment_path(@assessment_id), method: "get", class: "space-y-4",
         data: { controller: "lens-picker", lens_picker_levels_value: levels_by_role.to_json }) do
      p(class: "text-sm text-gray-600 dark:text-gray-300") { intro }
      field("lens-role-select", "Role") { role_select }
      field("lens-level-select", "Level") { level_select }
      div(class: "flex justify-end gap-2 pt-1") do
        button(type: "button", data: { action: "click->modal#close" },
               class: "text-sm font-medium px-3 py-1.5 rounded-md border border-gray-300 dark:border-gray-600 " \
                      "text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer") do
          "Cancel"
        end
        button(type: "submit",
               class: "text-sm font-semibold px-3 py-1.5 rounded-md bg-gray-900 dark:bg-white text-white " \
                      "dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-gray-100 cursor-pointer") do
          "View"
        end
      end
    end
  end

  def field(id, label_text, &)
    div do
      label(for: id, class: "block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1") { label_text }
      yield
    end
  end

  def role_select
    select(id: "lens-role-select", name: "as_role", class: select_classes,
           data: { lens_picker_target: "role", action: "change->lens-picker#roleChanged" }) do
      @lens.ladders.each do |family, roles|
        optgroup(label: family) do
          roles.each do |role|
            option(value: role.role_id, selected: role.role_id == @lens.role.role_id) do
              role_option_label(role)
            end
          end
        end
      end
    end
  end

  def role_option_label(role)
    role.role_id == @lens.home_role.role_id ? "#{role.name} (#{possessive} role)" : role.name
  end

  def possessive = @whose

  def intro
    if @whose == "your"
      "Your ratings stay as they are. The page reads them against the role you pick, " \
        "and you can rate the capabilities it adds."
    else
      "#{@whose.capitalize} ratings stay as they are. The page reads them against the role you pick."
    end
  end

  def level_select
    select(id: "lens-level-select", name: "as_level", class: select_classes,
           data: { lens_picker_target: "level" }) do
      @lens.role.levels.sort_by(&:ordinal).each do |level|
        option(value: level.ordinal, selected: level.ordinal == @lens.level.ordinal) { level_label(@lens.role, level) }
      end
    end
  end

  # { role_id => [[ordinal, label], ...] } for the picker to rebuild the
  # level select from without a round trip.
  def levels_by_role
    @lens.ladders.flat_map(&:last).to_h do |role|
      [ role.role_id, role.levels.sort_by(&:ordinal).map { |level| [ level.ordinal, level_label(role, level) ] } ]
    end
  end

  def level_label(role, level)
    "#{role.code}#{level.ordinal} · #{level.title}"
  end

  def select_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 " \
      "px-3 py-2 text-sm text-gray-900 dark:text-white focus-visible:outline-hidden " \
      "focus-visible:ring-2 focus-visible:ring-primary"
  end
end
