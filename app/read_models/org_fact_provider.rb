# frozen_string_literal: true

# Who supplies one kind of person fact for a tenant, such as its titles.
#
# Projected from FactProviderSet by {OrgGraph::Projections::Structure}. A fact
# with no row is Espalia's.
#
class OrgFactProvider < ApplicationRecord
  include DeterministicId
  deterministic_id_from :tenant_id, :fact

  acts_as_tenant :tenant

  belongs_to :tenant

  # @param fact [String, Symbol] one of {OrgGraph::StructureAggregate::FACTS}
  # @return [String] the fact's provider in the current tenant
  def self.provider_for(fact)
    find_by(fact: fact.to_s)&.provider || OrgGraph::StructureAggregate::ESPALIA
  end
end
