# frozen_string_literal: true

# Every job title held by active HRIS people, with the role mapping it
# resolves to and the people the next sync would change (#436).
#
# The read half of the HRIS mapping surface: an agent can find the titles
# nobody has mapped, and the people still carrying an assignment an earlier
# title gave them, before calling `integrations_map_hris_title`.
class Operations::Integrations::HrisTitles < Operations::Base
  include Operations::Integrations::HrisTitlePreview

  description "List the job titles active HRIS people hold, each with the framework role mapping it " \
              "resolves to (nil = unmapped, so the sync skips those people) and the people the next " \
              "sync would change. Also lists the framework's roles and their levels as mapping targets."
  category :read
  approval :none

  parameter :unmapped_only, :boolean

  def policy_check
    authorize :integrations, :show?
  end

  # @return [Hash] titles, the roles a title can map to, and whether levels
  #   can come from the HRIS level column
  def perform
    tenant = ActsAsTenant.current_tenant
    resolution = Integrations::HrisTitleResolution.new(tenant)
    titles = resolution.titles
    titles = titles.select(&:unmapped?) if params[:unmapped_only]

    {
      level_column_configured: tenant.hris_config.level_field_id.present?,
      framework_roles: framework_roles(resolution),
      titles: titles.map { |entry| title_payload(entry) }
    }
  end

  private

  def title_payload(entry)
    {
      title: entry.title,
      people_count: entry.people_count,
      hris_levels: entry.hris_levels,
      mapping: mapping_payload(entry.mapping),
      needs_attention: people_payload(entry.attention_rows)
    }
  end

  def framework_roles(resolution)
    levels = resolution.level_ordinals_by_role_code
    resolution.roles.map { |role| { code: role.code, name: role.name, level_ordinals: levels[role.code] || [] } }
  end
end
