# frozen_string_literal: true

# Shared archive-category modal for the Framework Explorer (edit mode). One
# instance per page; each category header's archive kebab opens it, passing the
# category's id/name via the trigger dataset (read by the `archive-category-form`
# Stimulus controller).
#
# A category carries no ratings, so — unlike the capability ArchiveModal — there
# is no migration mapping to capture: just an optional reason. The category
# header's kebab only renders for an empty category (the aggregate refuses to
# archive one that still holds active capabilities), so this modal assumes the
# archive will succeed and surfaces the aggregate's error via flash if not.
# Submits to {Frameworks::CategoryArchivesController#create}.
class Views::Frameworks::Explorer::ArchiveCategoryModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "archive-category-modal", title: "Archive category", standalone: false
    ) do |m|
      m.body { archive_form }
    end
  end

  private

  def archive_form
    form(
      action: framework_category_archives_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: { controller: "archive-category-form tree-scope-fields",
              action: "turbo:submit-end->modal#submitted" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)
      input(type: "hidden", name: "archive[category_id]", data: { archive_category_form_target: "categoryId" })

      p(class: "text-sm text-gray-600 dark:text-gray-300") do
        plain "Archiving "
        span(class: "font-semibold text-gray-900 dark:text-white",
             data: { archive_category_form_target: "title" }) { "this category" }
        plain "."
      end

      reason_field
      actions
    end
  end

  def reason_field
    div do
      label(for: "archive_category_reason",
            class: "block text-sm font-medium text-gray-900 dark:text-white mb-1") { "Reason" }
      textarea(
        id: "archive_category_reason", name: "archive[reason]", rows: "2",
        class: field_classes, placeholder: "Why is this category being retired?",
        data: { archive_category_form_target: "reason" }
      )
    end
  end

  def actions
    div(class: "flex items-center gap-3 pt-1") do
      button(
        type: "submit",
        class: "inline-flex items-center rounded-md bg-red-600 px-4 py-2 text-sm font-semibold " \
               "text-white hover:bg-red-700 transition-colors"
      ) { "Archive category" }
      button(
        type: "button", data: { action: "click->modal#close" },
        class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
      ) { "Cancel" }
    end
  end

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
