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
        input(type: "text", id: "add_category_name", name: "category[name]", class: Components::Kit::Field::INPUT)
      end
      div do
        label(for: "add_category_description", class: label_classes) { "Description" }
        textarea(id: "add_category_description", name: "category[description]", rows: "2", class: Components::Kit::Field::TEXTAREA)
      end

      div(class: "flex items-center gap-3 pt-1") do
        render Components::Kit::Button.new(tone: :brand, type: :submit) { "Add category" }
        render Components::Kit::Button.new(variant: :ghost, data: { action: "click->modal#close" }) { "Cancel" }
      end
    end
  end

  def label_classes = "block text-sm font-medium text-default mb-1"
end
