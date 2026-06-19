# frozen_string_literal: true

# The current person's evidence-request hub: requests addressed to them
# (incoming — respond / decline) and requests they made (outgoing — cancel).
# This is the surface notifications deep-link to.
class EvidenceHubController < ApplicationController
  before_action :require_person

  # GET /evidence
  def show
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy

    incoming = EvidenceRequest.incoming_for(current_person.id).recent_first.includes(:requester)
    outgoing = EvidenceRequest.outgoing_for(current_person.id).recent_first.includes(:requestee)

    render Views::Evidence::HubView.new(
      incoming: incoming.to_a,
      outgoing: outgoing.to_a,
      capability_names: capability_names_for(incoming + outgoing),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  # Resolve capability stable_id → name in one query so the view doesn't N+1.
  def capability_names_for(requests)
    stable_ids = requests.map(&:capability_stable_id).uniq
    return {} if stable_ids.empty?

    FrameworkState::Capability.where(stable_id: stable_ids).pluck(:stable_id, :name).to_h
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
