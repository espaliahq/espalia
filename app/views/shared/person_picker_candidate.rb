# frozen_string_literal: true

# One person the picker can add — a full row in the typeahead results, or
# a compact quick-add chip in the suggestions block. Clicking dispatches
# `person-picker#add`; the controller reads id/name from the data-params.
class Views::Shared::PersonPickerCandidate < Views::Base
  # @param person [Person]
  # @param subtitle [String, nil] secondary line (e.g. "job title · 6 reports")
  # @param compact [Boolean] chip (suggestion) vs. row (search result)
  def initialize(person:, subtitle: nil, compact: false)
    @person = person
    @subtitle = subtitle
    @compact = compact
  end

  def view_template
    button(type: "button", class: classes,
           data: {
             action: "person-picker#add",
             person_picker_person_id_param: @person.id,
             person_picker_name_param: @person.name
           }) { inner }
  end

  private

  def inner
    if @compact
      plain("+ #{@person.name}")
    else
      div(class: "min-w-0 text-left") do
        p(class: "truncate text-sm font-medium text-gray-900 dark:text-gray-100") { @person.name }
        p(class: "truncate text-xs text-gray-600 dark:text-gray-300") { secondary }
      end
      span(class: "shrink-0 text-xs font-medium text-primary") { "Add" }
    end
  end

  def secondary
    [ @person.email, @subtitle.presence ].compact.join(" · ")
  end

  def classes
    if @compact
      "inline-flex items-center min-h-9 px-2.5 rounded-full border border-gray-300 dark:border-gray-600 " \
        "text-xs font-medium text-gray-700 dark:text-gray-200 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800"
    else
      "flex w-full items-center justify-between gap-3 min-h-11 px-3 py-2 rounded-md " \
        "hover:bg-gray-50 dark:hover:bg-gray-800 cursor-pointer"
    end
  end
end
