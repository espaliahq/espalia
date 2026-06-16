# frozen_string_literal: true

# Adds a capability category to a framework — an empty container that
# capabilities are then added to. Shape-preserving (an empty category doesn't
# change the rating grid), so it does not open a draft on its own.
#
# Write — :mcp_client. Restricted to edit-rights holders
# (FrameworkPolicy#add_category?).
class Operations::Frameworks::AddCategory < Operations::Base
  description "Add a capability category to a framework (owner/editor/lead only)."
  category :write
  approval :mcp_client

  parameter :framework_id, String, required: true
  parameter :name,         String, required: true
  parameter :description,  String
  parameter :ordinal,      Integer

  def policy_check
    authorize framework, :add_category?
  end

  # @return [Hash] { framework_id:, category_id:, name: }
  def perform
    category_id = SecureRandom.uuid_v7
    Frameworks::CommandHandler.new.add_capability_category(
      framework.framework_id, category_id, params[:name],
      description: params[:description].presence, ordinal: params[:ordinal]
    )
    { framework_id: framework.framework_id, category_id: category_id, name: params[:name] }
  end

  private

  def framework
    @framework ||= FrameworkState::Framework.find_by!(framework_id: params[:framework_id])
  end
end
