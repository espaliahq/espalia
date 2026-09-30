# frozen_string_literal: true

# Maps and unmaps HRIS job titles from the HRIS integration page (#436).
#
# Both actions dispatch the shared Operations (web + MCP parity) and redirect
# back to the page with a flash saying what the next sync will do — nothing
# is reassigned until that sync runs.
class Tenant::HrisTitleMappingsController < ApplicationController
  # How many people a flash names before it switches to a count.
  NAMED_PEOPLE_LIMIT = 3

  # POST /tenant/integrations/hris/title_mapping
  def create
    authorize :integrations, :update_role_mappings?

    result = Operations::Integrations::MapHrisTitle.call(context: pundit_user, params: map_params)
    redirect_to tenant_integration_path("hris"), notice: mapped_notice(result)
  rescue Operations::Base::ParameterError, ActiveRecord::RecordInvalid => e
    redirect_to tenant_integration_path("hris"),
                alert: "The mapping could not be saved: #{error_message(e)}",
                status: :see_other
  end

  # DELETE /tenant/integrations/hris/title_mapping
  def destroy
    authorize :integrations, :update_role_mappings?

    result = Operations::Integrations::UnmapHrisTitle.call(context: pundit_user, params: { title: title_param })
    redirect_to tenant_integration_path("hris"), notice: unmapped_notice(result), status: :see_other
  rescue Operations::Base::ParameterError, ActiveRecord::RecordInvalid => e
    redirect_to tenant_integration_path("hris"),
                alert: "The mapping could not be removed: #{error_message(e)}",
                status: :see_other
  end

  private

  def map_params
    mapping = params.expect(hris_title_mapping: [ :title, :framework_role_code, :level_ordinal ])
    {
      title: mapping[:title].to_s,
      framework_role_code: mapping[:framework_role_code].to_s,
      # Blank is the "from the HRIS level column" choice.
      level_ordinal: mapping[:level_ordinal].presence&.to_i
    }
  end

  def title_param
    params.expect(hris_title_mapping: [ :title ])[:title].to_s
  end

  def mapped_notice(result)
    role = result.dig(:mapping, :framework_role_code)
    level = result.dig(:mapping, :level_ordinal)
    target = level ? "#{role} L#{level}" : "#{role} (level from HRIS)"
    moves = result[:people].select { |p| p[:next_sync_assignment] && p[:next_sync_assignment] != p[:current_assignment] }
    stuck = result[:people].count { |p| p[:next_sync_assignment].nil? }

    [ "Mapped “#{result[:title]}” to #{target}.", moves_sentence(moves), stuck_sentence(stuck, role) ].compact.join(" ")
  end

  def moves_sentence(moves)
    return "Nobody holding it changes on the next sync." if moves.empty?
    return "The next sync moves #{moves.size} people." if moves.size > NAMED_PEOPLE_LIMIT

    changes = moves.map do |person|
      from = person[:current_assignment] ? "from #{person[:current_assignment]} " : ""
      "#{person[:name]} #{from}to #{person[:next_sync_assignment]}"
    end
    "The next sync moves #{changes.to_sentence}."
  end

  def stuck_sentence(count, role)
    return nil if count.zero?

    "#{count} #{'person'.pluralize(count)} can't be placed: #{role} has no level matching their HRIS level."
  end

  def unmapped_notice(result)
    count = result[:people].size
    return "Removed “#{result[:title]}”. Nobody holds that title right now." if count.zero?

    holders = count == 1 ? "the one person holding it, who keeps" : "the #{count} people holding it, who keep"
    "Removed “#{result[:title]}”. The next sync skips #{holders} their current assignment."
  end

  def error_message(error)
    return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

    error.message
  end
end
