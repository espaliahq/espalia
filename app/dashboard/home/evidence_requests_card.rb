# frozen_string_literal: true

# "Evidence requested of you" — pending evidence requests addressed to the
# viewer that still need their response. The "act now" subset of the evidence
# hub; outgoing requests and authored evidence stay on the standalone
# {Views::Evidence::HubView} surface (`/evidence`), which this card links to.
#
# A single instance summarising across requests, mirroring {AwaitingYouCard}.
class Home::EvidenceRequestsCard < Home::Card
  PRIORITY = 65
  PREVIEW_LIMIT = 5

  def self.key = "evidence_requests"

  def self.audience?(context)
    person = context.person
    return false unless person

    pending_incoming(person).exists?
  end

  def self.instances(context)
    person = context.person
    return [] unless person
    return [] unless pending_incoming(person).exists?

    [ build_instance(priority: PRIORITY, title: "Evidence requested of you") ]
  end

  # Pending evidence requests addressed to this person — the only actionable
  # (by them) subset. Tenant scoping is implicit via acts_as_tenant.
  # @return [ActiveRecord::Relation<EvidenceRequest>]
  def self.pending_incoming(person)
    EvidenceRequest.incoming_for(person.id).pending
  end
  private_class_method :pending_incoming

  def render_content(_instance_key)
    requests = self.class.send(:pending_incoming, person)
      .recent_first
      .includes(:requester, :assessee)
      .to_a

    Views::Home::Cards::EvidenceRequests.new(requests: requests)
  end
end
