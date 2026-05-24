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

  private

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
    cats = FrameworkState::CapabilityCategory
      .where(framework_id: @framework.framework_id)
      .includes(:capabilities)
      .order(:ordinal)

    cats.map do |category|
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

  def active_capabilities(category)
    category.capabilities
      .reject { |c| c.respond_to?(:status) && c.status == "archived" }
      .sort_by(&:name)
  end
end
