# frozen_string_literal: true

# Who may change the Org Graph besides its owners and managers (#126): the
# editors an admin chose, and the admins, who always may.
class Operations::OrgGraph::Editors < Operations::Base
  include Operations::OrgGraph::EditorSupport

  description "List who may change the whole Org Graph: the Org Graph editors an admin chose, and the " \
              "tenant's admins, who always may. Each with a person id and name. Each editor also has since (the " \
              "date it took effect), added_by (who made them one, or null when no one did) and already_held " \
              "(true when they were an editor before Espalia recorded who gave it). Admins only."
  category :read
  approval :none

  # @return [Hash] editors and admins
  def perform = editors_payload
end
