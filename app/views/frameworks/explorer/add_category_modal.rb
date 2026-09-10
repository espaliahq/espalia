# frozen_string_literal: true

# Shared "add category" modal for the Framework Explorer (edit mode). Opened by
# the "+ Add category" trigger at the foot of the matrix. Adds an empty
# capability category (shape-preserving), then submits to
# {Frameworks::CategoriesController#create}.
class Views::Frameworks::Explorer::AddCategoryModal < Views::Base
  # @param framework_id [String]
  def initialize(framework_id:)
    @framework_id = framework_id
  end

  def view_template
    render Components::Kit::Modal.new(
      id: "add-category-modal", title: "Add category", standalone: false
    ) do |m|
      m.body { form_body }
    end
  end

  private

  def form_body
    form(
      action: framework_categories_path(@framework_id),
      method: "post",
      class: "space-y-4",
      data: { controller: "tree-scope-fields", action: "turbo:submit-end->modal#submitted" }
    ) do
      input(type: "hidden", name: "authenticity_token", value: view_context.form_authenticity_token)

      div do
        label(for: "add_category_name", class: label_classes) { "Name" }
        input(type: "text", id: "add_category_name", name: "category[name]", class: field_classes)
      end
      div do
        label(for: "add_category_description", class: label_classes) { "Description" }
        textarea(id: "add_category_description", name: "category[description]", rows: "2", class: field_classes)
      end

      div(class: "flex items-center gap-3 pt-1") do
        button(
          type: "submit",
          class: "inline-flex items-center rounded-md bg-primary px-4 py-2 text-sm font-semibold " \
                 "text-white hover:bg-primary/90 transition-colors"
        ) { "Add category" }
        button(
          type: "button", data: { action: "click->modal#close" },
          class: "text-sm text-gray-600 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200"
        ) { "Cancel" }
      end
    end
  end

  def label_classes = "block text-sm font-medium text-gray-900 dark:text-white mb-1"

  def field_classes
    "block w-full rounded-md border border-gray-300 dark:border-gray-600 " \
      "bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white " \
      "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-primary"
  end
end
