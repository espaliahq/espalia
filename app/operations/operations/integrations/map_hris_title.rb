# frozen_string_literal: true

# Map one HRIS job title to a framework role (#436).
#
# The title moves out of whichever mapping held it before, so this is both
# "add" and "edit". The level either comes from the HRIS level column
# (`level_ordinal` omitted) or is fixed for everyone holding the title.
#
# Nothing is reassigned here — the next sync applies the mapping. The result
# says what that sync will do to each person holding the title.
#
# Approval is :in_app: a mapping moves people between career ladders, and
# the mcp-server.md cheat sheet puts tenant settings behind the in-app gate.
class Operations::Integrations::MapHrisTitle < Operations::Base
  include Operations::Integrations::HrisTitlePreview

  description "Map an HRIS job title to a framework role, replacing any mapping it had. Omit " \
              "level_ordinal to take each person's level from the HRIS level column, or pass one to " \
              "fix the level for everyone with that title. Applied by the next HRIS sync; the result " \
              "previews what that sync will do to each person holding the title."
  category :write
  approval :in_app

  MAX_TITLE_LENGTH = 200

  parameter :title,               String,  required: true, allow_blank: false
  parameter :framework_role_code, String,  required: true, allow_blank: false
  parameter :level_ordinal,       Integer

  def policy_check
    authorize :integrations, :update_role_mappings?
  end

  # @return [Hash] the title, the mapping it now resolves to, and the
  #   people the next sync will assign or move
  def perform
    title = params[:title].strip
    validate_title!(title)
    role = find_role!
    validate_level!(role)

    tenant = ActsAsTenant.current_tenant
    tenant.with_lock do
      tenant.hris_config.map_title(title, framework_role_code: role.code, level_ordinal: params[:level_ordinal])
      tenant.save!
    end

    {
      title: title,
      mapping: mapping_payload(tenant.hris_config.mapping_for(title)),
      people: people_payload(rows_for_title(tenant, title))
    }
  end

  private

  def validate_title!(title)
    return if title.length <= MAX_TITLE_LENGTH

    raise ParameterError, "title: must be #{MAX_TITLE_LENGTH} characters or fewer"
  end

  def find_role!
    FrameworkState::Role.find_by(code: params[:framework_role_code].strip) ||
      raise(ParameterError, "framework_role_code: no framework role has the code '#{params[:framework_role_code]}'")
  end

  def validate_level!(role)
    ordinal = params[:level_ordinal]

    if ordinal.nil?
      return if ActsAsTenant.current_tenant.hris_config.level_field_id.present?

      raise ParameterError,
        "level_ordinal: required, because this workspace has no HRIS level column to read levels from"
    end

    return if FrameworkState::Level.exists?(role_id: role.role_id, ordinal: ordinal)

    raise ParameterError, "level_ordinal: #{role.code} has no level #{ordinal}"
  end
end
