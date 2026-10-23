# frozen_string_literal: true

# @label Tree nav
class Kit::TreeNavPreview < Lookbook::Preview
  # @param expanded toggle
  # @param checked select { choices: [all, some, none] }
  def playground(expanded: true, checked: "some")
    tree([ engineering(expanded: expanded, checked: checked.to_sym), product ])
  end

  # @!group Selection

  def all_checked
    tree([ engineering(checked: :all) ])
  end

  def partly_checked
    tree([ engineering(checked: :some) ])
  end

  def none_checked
    tree([ engineering(checked: :none) ])
  end

  # @!endgroup

  # @!group States

  def several_families
    tree([ engineering, product, design ])
  end

  def collapsed
    tree([ engineering(expanded: false), product(expanded: false), design ])
  end

  def long_labels
    tree([
      {
        id: "rf-data",
        label: "Data, Analytics and Machine Learning Engineering",
        children: [
          { id: "r-ds", label: "Senior Machine Learning Engineer, Recommendations and Search", checked: true, data: { track: "ic" } },
          { id: "r-dm", label: "Head of Data", checked: false, data: { track: "management" } }
        ]
      }
    ])
  end

  def family_without_roles
    tree([ { id: "rf-ops", label: "Operations", children: [] } ])
  end

  # @!endgroup

  private

  def tree(nodes)
    render_with_template(template: "kit/tree_nav_preview/tree", locals: { nodes: nodes })
  end

  def engineering(expanded: true, checked: :all)
    roles = [
      { id: "r-se", label: "Software Engineer", data: { track: "ic" } },
      { id: "r-sre", label: "Site Reliability Engineer", data: { track: "ic" } },
      { id: "r-em", label: "Engineering Manager", data: { track: "management" } }
    ]
    roles.each_with_index do |role, index|
      role[:checked] = checked == :all || (checked == :some && index.zero?)
    end
    { id: "rf-eng", label: "Engineering", expanded: expanded, children: roles }
  end

  def product(expanded: true)
    {
      id: "rf-product",
      label: "Product",
      expanded: expanded,
      children: [
        { id: "r-pm", label: "Product Manager", checked: true, data: { track: "ic" } },
        { id: "r-gpm", label: "Group Product Manager", checked: true, data: { track: "management" } }
      ]
    }
  end

  def design
    {
      id: "rf-design",
      label: "Design",
      children: [
        { id: "r-pd", label: "Product Designer", checked: false, data: { track: "ic" } },
        { id: "r-ux", label: "UX Researcher", checked: false, data: { track: "ic" } }
      ]
    }
  end
end
