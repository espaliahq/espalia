# frozen_string_literal: true

# Takes back a member's right to change the whole Org Graph (#126). Units
# they own, and their own reports' memberships, stay theirs to change.
#
# Approval is :in_app, as it changes someone's permissions.
class Operations::OrgGraph::RemoveEditor < Operations::Base
  include Operations::OrgGraph::EditorSupport

  description "Stop a person being an Org Graph editor. They keep their rights over units they own and " \
              "their reports' memberships. An admin's rights can't be removed this way. Returns the list " \
              "as org_graph_editors reads it."
  category :write
  approval :in_app

  parameter :person_id, String, required: true, allow_blank: false

  # @return [Hash] editors and admins
  # @raise [ParameterError] for a person with no account, or an admin
  def perform
    account = account!
    raise ParameterError, "person_id: an admin may always edit the Org Graph" if account.admin?

    account.update!(org_graph_editor: false)
    editors_payload
  end
end
