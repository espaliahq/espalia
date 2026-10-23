# frozen_string_literal: true

# The current person's feedback hub: requests addressed to them (incoming —
# respond / decline), requests they made (outgoing — cancel), feedback waiting
# to be placed on a capability (about them, and about their reports), the
# feedback they've given, and the way to give more. This is the surface
# notifications deep-link to.
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
    placing = Operations::Assessments::FeedbackToPlace.call(context: pundit_user, params: { scope: place_param })
    to_place_about_me, to_place_for_team = to_place_records(placing)
    responses = responses_for(completed_outgoing)
    shown = authored + to_place_about_me + to_place_for_team
    responded_items = responses.values.map { |r| r[:item] }
    # A suggestion block's id is the item's, so an item whose block shows
    # elsewhere on the page must not be listed again under "May fit elsewhere
    # too". The viewer's own self feedback is the exception: its suggestions
    # show there, and its card under "Feedback you've provided" leaves them out.
    # Suggestion work only when something could show: a pending row somewhere,
    # or a tenant that can ask for one. Off is the default.
    can_regenerate = Evidence::PlacementSuggestionRows.regenerable?(ActsAsTenant.current_tenant)
    suggestions_live = can_regenerate || EvidencePlacementSuggestion.pending.exists?
    listed_elsewhere = shown.reject { |item| item.source == "self" && item.author_id == current_person.id } + responded_items
    all_with_suggestions = suggestions_live ? placed_with_suggestions(exclude: listed_elsewhere.map(&:id)) : []
    with_suggestions = elsewhere_all? ? all_with_suggestions : all_with_suggestions.first(Views::Evidence::HubView::ELSEWHERE_LIMIT)
    decidable = suggestions_live ? decidable_items(shown + with_suggestions, responded_items) : []

    all_requests = open_incoming + open_outgoing + completed_incoming + completed_outgoing
    # One combined context lookup for every cell on the page — request ids and
    # evidence ids are all distinct UUIDs, so a single id-keyed hash serves both.
    details = Evidence::CellContextResolver.new(all_requests + shown + with_suggestions).by_id

    render Views::Evidence::HubView.new(
      open_incoming: open_incoming,
      open_outgoing: open_outgoing,
      completed_incoming: completed_incoming,
      completed_outgoing: completed_outgoing,
      authored: authored,
      to_place_about_me: to_place_about_me,
      to_place_for_team: to_place_for_team,
      place_scope: placing[:scope],
      place_counts: (placing[:counts] if placing[:beyond_team]),
      open_give_step: params[:give].present? || draft.present?,
      draft: draft,
      cell_details: details,
      authored_details: details,
      responses: responses,
      in_situ_paths: in_situ_paths_for(authored + responses.values.map { |r| r[:item] }),
      with_suggestions: with_suggestions,
      elsewhere_ids: all_with_suggestions.to_set(&:id),
      elsewhere_all: elsewhere_all?,
      hub_params: hub_params,
      suggestions: Evidence::PlacementSuggestionRows.for(decidable),
      decidable_ids: decidable.to_set(&:id),
      can_regenerate: can_regenerate,
      viewer_person_id: current_person.id,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  # A Slack draft the author arrived with (Evidence::DraftsController): the
  # modal opens on arrival, filled from it. Theirs only, and only while open.
  def draft
    return @draft if defined?(@draft)

    @draft = FeedbackDraft.open_for(token: params[:draft], email: current_user.email)
  end

  def elsewhere_all? = params[:elsewhere] == "all"

  # The hub's view state, for links that change one part of it. The Slack
  # draft and ?give=1 open the modal on arrival, so they are left behind.
  def hub_params
    request.query_parameters.except("give", "draft").symbolize_keys
  end

  # "My team" unless the URL asks for the whole org.
  def place_param
    params[:place] == "org" ? "org" : ::Assessments::FeedbackToPlace::DEFAULT_SCOPE
  end

  # The cards render records; the Operation decides which, in its order.
  def to_place_records(placing)
    ids = (placing[:about_you] + placing[:items]).map { |row| row[:evidence_id] }
    items = EvidenceItem.where(id: ids).includes(:author).index_by(&:id)
    [ placing[:about_you], placing[:items] ].map { |rows| rows.filter_map { |row| items[row[:evidence_id]] } }
  end

  # Placed items about the viewer, or about the assessments in the chosen
  # view, with pending placement suggestions — the extra cells the model sees.
  # Feedback the viewer gave someone else stays under "Feedback you've
  # provided"; their self feedback is about them, so it is listed here.
  def placed_with_suggestions(exclude:)
    keys = ::Assessments::FeedbackToPlace.new(current_person).assignments(place_param).keys.to_set
    person_ids = [ current_person.id, *keys.map(&:first) ].uniq
    pending = EvidencePlacementSuggestion.pending.where(person_id: person_ids)
    items = EvidenceItem.arel_table

    EvidenceItem.active.where(id: pending.select(:evidence_id)).where.not(id: exclude)
      .where(items[:author_id].not_eq(current_person.id).or(items[:source].eq("self")))
      .where.not(capability_stable_id: nil)
      .includes(:author).order(recorded_at: :desc).to_a
      .select { |item| item.person_id == current_person.id || keys.include?([ item.person_id, item.framework_id ]) }
  end

  # Items whose suggestions the viewer may decide. Everything the hub already
  # lists for placing qualifies by construction; a response the viewer asked
  # for depends on who they are to the assessee, so the policy decides. A
  # withdrawn response can no longer be linked anywhere.
  def decidable_items(placeable, responded)
    placeable + responded.select { |item| !item.withdrawn? && EvidencePolicy.new(pundit_user, item).add_link? }
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
