# frozen_string_literal: true

# Lets a member change the Org Graph's providers, units and people's facts
# (#126), unit types included.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::OrgGraph::AddEditor < Operations::Base
  include Operations::OrgGraph::EditorSupport

  description "Make an active person with an account in this organisation an Org Graph editor, so they may " \
              "change its providers, units, unit types and people's facts. Admins already may, and only " \
              "admins may add an editor. A person with more than one account is refused " \
              "until the duplicate is settled. Returns the list as org_graph_editors reads it."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] editors and admins
  # @raise [ParameterError] for a person with no account or two, an admin, or someone who has left
  def perform
    account = sole_account!("the right to edit the Org Graph can't be granted")
    raise ParameterError, "person_id: admins may already edit the Org Graph" if account.admin?
    raise ParameterError, "person_id: only someone still in the organisation can be an editor" unless account.person&.status == "active"

    grant_handler.add(:org_graph_editor, account, added_by_id: context.person&.id)
    editors_payload
  end
end
