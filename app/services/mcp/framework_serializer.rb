# frozen_string_literal: true

# Canonical shape for framework data exposed over MCP. Both
# `Operations::Frameworks::Get` and `Operations::Assessments::Get`
# build their payloads on top of this so the LLM-visible schema is
# identical between "exploring a framework" and "viewing an assessment
# on that framework". An assessment payload is a strict superset of the
# corresponding framework payload — same keys, same nesting, plus an
# overlay (ratings / scoring / evidence).
#
# Disclosure policy: one level of recursion. A framework returns its
# role-family + category children with one level of ID + name inside
# them (roles inside families, capabilities inside categories) — enough
# for the LLM to pick a drill-in without another round trip. We do NOT
# recurse further (no inline expectations or illustrations); those live
# behind `framework_capability_get` / `assessment_capability_get` tools.
class Mcp::FrameworkSerializer
  # @param framework [FrameworkState::Framework]
  # @return [Hash]
  def self.framework(framework)
    new(framework).framework
  end

  # @param framework [FrameworkState::Framework]
  # @param capability [FrameworkState::Capability]
  # @return [Hash] capability detail — description, status, category,
  #   bindings (role + weight), and expectations per level (each with
  #   its illustrations grouped by role). This IS the drill-in payload;
  #   both framework_capability_get and assessment_capability_get use it.
  def self.capability(framework, capability)
    new(framework).capability(capability)
  end

  def initialize(framework)
    @framework = framework
  end

  def framework
    {
      id: @framework.framework_id,
      name: @framework.name,
      current_published_version: @framework.current_published_version,
      draft_in_progress: @framework.draft_in_progress,
      role_families: role_families,
      categories: categories
    }
  end

  def capability(capability)
    expectations = FrameworkState::BehaviouralExpectation
      .where(capability_id: capability.capability_id)
      .includes(:illustrations)
      .order(:level_ordinal)

    bindings = FrameworkState::CapabilityRoleBinding
      .where(capability_id: capability.capability_id)
      .includes(:role)

    {
      id: capability.capability_id,
      stable_id: capability.stable_id,
      name: capability.name,
      description: capability.description,
      status: capability.status,
      category: capability.category && {
        id: capability.category.category_id,
        name: capability.category.name
      },
      bindings: bindings.map { |b| binding_payload(b) }.sort_by { |b| b.dig(:role, :code).to_s },
      expectations: expectations.map { |e| expectation_payload(e) }
    }
  end

  private

  def binding_payload(binding)
    role = binding.role
    {
      role: role && { id: role.role_id, code: role.code, name: role.name },
      weight: binding.weight.to_f
    }
  end

  def expectation_payload(expectation)
    {
      id: expectation.expectation_id,
      stable_id: expectation.stable_id,
      level_ordinal: expectation.level_ordinal,
      description: expectation.description,
      illustrations: expectation.illustrations.sort_by(&:ordinal).map { |i|
        role = role_for(i.role_id)
        {
          id: i.illustration_id,
          role: role && { id: role.role_id, code: role.code, name: role.name },
          description: i.description
        }
      }
    }
  end

  def role_for(role_id)
    @roles_by_id ||= FrameworkState::Role
      .joins(:role_family)
      .where(framework_role_families: { framework_id: @framework.framework_id })
      .index_by(&:role_id)
    @roles_by_id[role_id]
  end

  def role_families
    families = FrameworkState::RoleFamily
      .where(framework_id: @framework.framework_id)
      .includes(:roles)
      .order(:name)

    families.map do |family|
      {
        id: family.role_family_id,
        name: family.name,
        roles: family.roles.sort_by(&:name).map { |r|
          { id: r.role_id, name: r.name, code: r.code, track: r.track }
        }
      }
    end
  end

  def categories
    active_categories.map do |category|
      {
        id: category.category_id,
        name: category.name,
        ordinal: category.ordinal,
        capabilities: active_capabilities(category).map { |c|
          { id: c.capability_id, stable_id: c.stable_id, name: c.name }
        }
      }
    end
  end

  def active_categories
    FrameworkState::CapabilityCategory
      .where(framework_id: @framework.framework_id, status: "active")
      .includes(:capabilities)
      .order(:ordinal, :created_at, :id)
  end

  def active_capabilities(category)
    category.capabilities.select { |c| c.status == "active" }
  end
end
