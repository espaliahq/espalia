# frozen_string_literal: true

# The current person's evidence-request hub: requests addressed to them
# (incoming — respond / decline) and requests they made (outgoing — cancel).
# This is the surface notifications deep-link to.
class EvidenceHubController < ApplicationController
  before_action :require_person

  # GET /evidence
  def show
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy
    @page_title = "Feedback / Evidence"

    incoming = EvidenceRequest.incoming_for(current_person.id).includes(:requester, :assessee)
    outgoing = EvidenceRequest.outgoing_for(current_person.id).includes(:requestee, :assessee)

    # Open lists lead with the stalest request (least recently requested or
    # reminded); completed lists read as recent history.
    open_incoming = incoming.pending.least_recently_touched.to_a
    open_outgoing = outgoing.pending.least_recently_touched.to_a
    completed_incoming = incoming.resolved.recent_first.to_a
    completed_outgoing = outgoing.resolved.recent_first.to_a

    authored = EvidenceItem.active.where(author_id: current_person.id).order(recorded_at: :desc).limit(50).to_a

    all_requests = open_incoming + open_outgoing + completed_incoming + completed_outgoing
    # One combined context lookup for every cell on the page — request ids and
    # evidence ids are all distinct UUIDs, so a single id-keyed hash serves both.
    details = Evidence::CellContextResolver.new(all_requests + authored).by_id
    responses = responses_for(completed_outgoing)

    render Views::Evidence::HubView.new(
      open_incoming: open_incoming,
      open_outgoing: open_outgoing,
      completed_incoming: completed_incoming,
      completed_outgoing: completed_outgoing,
      authored: authored,
      cell_details: details,
      authored_details: details,
      responses: responses,
      in_situ_paths: in_situ_paths_for(authored + responses.values.map { |r| r[:item] }),
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  # For responded outgoing requests, load the evidence the requestee provided
  # plus the cells it's linked to (so the requester sees the full response, and
  # can edit its linkage).
  #
  # @return [Hash{String => Hash}] request_id => { item:, links: [{ capability_name:, level_code:, level_ordinal: }] }
  def responses_for(requests)
    responded = requests.select { |r| r.status == "responded" && r.evidence_id.present? }
    return {} if responded.empty?

    items = EvidenceItem.where(id: responded.map(&:evidence_id)).includes(:author).index_by(&:id)
    link_rows = EvidenceLink.active.where(evidence_id: items.keys)
      .pluck(:evidence_id, :capability_stable_id, :level_ordinal, :valence)

    cells = link_rows.map do |evidence_id, capability_stable_id, level_ordinal, _valence|
      item = items[evidence_id]
      Evidence::CellContextResolver::Cell.new(
        id: [ evidence_id, capability_stable_id, level_ordinal ], framework_id: item.framework_id,
        person_id: item.person_id, capability_stable_id: capability_stable_id, level_ordinal: level_ordinal
      )
    end
    link_ctx = Evidence::CellContextResolver.new(cells).by_id

    responded.each_with_object({}) do |req, acc|
      item = items[req.evidence_id]
      next unless item

      links = link_rows.select { |evidence_id, _, _, _| evidence_id == item.id }
        .map do |_, capability_stable_id, level_ordinal, valence|
          ctx = link_ctx[[ item.id, capability_stable_id, level_ordinal ]] || {}
          { capability_name: ctx[:name], level_code: ctx[:level_code],
            level_ordinal: level_ordinal, valence: valence }
        end
      acc[req.id] = { item: item, links: links }
    end
  end

  # For each evidence item on the page, a deep link to its FIRST active linkage
  # on the assessment (`?capability=` + `?level_ordinal=` focus + scroll the
  # capability card), so the item can be seen in situ. Rendered only when the
  # viewer may see that assessment (AssessmentPolicy#show?) — a peer who
  # provided feedback on a colleague's assessment gets no dead link.
  #
  # @param items [Array<EvidenceItem>]
  # @return [Hash{String => String}] evidence_id => assessment path
  def in_situ_paths_for(items)
    items = items.compact.uniq
    return {} if items.empty?

    first_links = EvidenceLink.active.where(evidence_id: items.map(&:id))
      .order(:linked_at, :id).group_by(&:evidence_id).transform_values(&:first)
    assignments = PersonFrameworkAssignment
      .where(framework_id: items.map(&:framework_id).uniq, person_id: items.map(&:person_id).uniq)
      .index_by { |a| [ a.framework_id, a.person_id ] }

    items.each_with_object({}) do |item, acc|
      link = first_links[item.id]
      assignment = assignments[[ item.framework_id, item.person_id ]]
      next if link.nil? || assignment.nil? || !policy(assignment).show?

      acc[item.id] = assessment_path(assignment,
        capability: link.capability_stable_id, level_ordinal: link.level_ordinal)
    end
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
