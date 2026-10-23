# frozen_string_literal: true

# Turbo Frame fragment that renders the scope-entity dropdown for the
# currently selected framework + role on the collaborator assignment
# form. Empty for framework-wide roles.
#
class Views::Tenant::Users::ScopePickerFrame < Views::Base
  # Each scoped role maps to:
  #   [scope_type, human-readable label, ->(framework) { [[id, name], ...] } ]
  ROLE_TO_SCOPE = {
    "role_family_lead" => [
      "role_family", "Role family",
      ->(fw) { FrameworkState::RoleFamily.where(framework_id: fw.framework_id).order(:name).pluck(:role_family_id, :name) }
    ],
    "role_lead" => [
      "role", "Role",
      lambda do |fw|
        FrameworkState::Role
          .joins("INNER JOIN framework_role_families ON framework_role_families.role_family_id = framework_roles.role_family_id")
          .where("framework_role_families.framework_id = ?", fw.framework_id)
          .order("framework_roles.name")
          .pluck(:role_id, :name)
      end
    ],
    "capability_category_lead" => [
      "capability_category", "Capability category",
      lambda do |fw|
        FrameworkState::CapabilityCategory
          .where(framework_id: fw.framework_id, status: "active")
          .order(:name)
          .pluck(:category_id, :name)
      end
    ],
    "capability_lead" => [
      "capability", "Capability",
      lambda do |fw|
        FrameworkState::Capability
          .joins("INNER JOIN framework_capability_categories ON framework_capability_categories.category_id = framework_capabilities.category_id")
          .where("framework_capability_categories.framework_id = ?", fw.framework_id)
          .where("framework_capability_categories.status = ?", "active")
          .where(status: "active")
          .order("framework_capabilities.name")
          .pluck(:capability_id, :name)
      end
    ]
  }.freeze

  # @param framework [FrameworkState::Framework, nil]
  # @param role [String]
  def initialize(framework:, role:)
    @framework = framework
    @role = role
  end

  def view_template
    turbo_frame_tag "collaborator-scope-picker" do
      if scoped? && @framework
        scope_select
      else
        empty_fragment
      end
    end
  end

  private

  def scoped?
    ROLE_TO_SCOPE.key?(@role)
  end

  def scope_select
    scope_type, label, entity_loader = ROLE_TO_SCOPE[@role]
    entities = entity_loader.call(@framework)

    div(class: "mt-3") do
      input(type: "hidden", name: "collaborator[scope_type]", value: scope_type)

      label_for_select(label)
      select(
        name: "collaborator[scope_id]",
        required: true,
        class: select_classes
      ) do
        option(value: "") { "— Pick a #{label.downcase} —" }
        entities.each do |id, name|
          option(value: id) { name }
        end
      end
    end
  end

  def empty_fragment
    # Clear any prior scope params so a framework-wide role doesn't carry
    # over a stale scope_id / scope_type from a previous selection.
    input(type: "hidden", name: "collaborator[scope_type]", value: "")
    input(type: "hidden", name: "collaborator[scope_id]", value: "")
  end

  def label_for_select(text)
    label(class: "block text-xs font-medium text-muted mb-1") do
      "Scope (#{text.downcase})"
    end
  end

  def select_classes
    Components::Kit::Field::SELECT
  end
end
