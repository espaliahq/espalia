# frozen_string_literal: true

# The Feedback / Evidence page: what needs the current person (requests
# to answer, feedback to place), then their conversations — one per person,
# or for a manager one per report — with the selected one open beside the
# list. This is the surface notifications link to: `item` and
# `evidence_request` find the conversation holding what a link names.
class EvidenceHubController < ApplicationController
  # A thread shows its latest messages; `?all=1` shows the rest.
  THREAD_LIMIT = 40

  before_action :require_person

  # GET /evidence
  # GET /evidence/with/:person_id
  # GET /evidence/about/:person_id
  def show
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy
    @page_title = "Feedback / Evidence"

    conversations = Evidence::Conversations.new(current_person, scope: place_param)
    conversations.group = group_for(conversations)
    return redirect_to(org_thread_path) if org_only_thread?(conversations)

    reads = Evidence::ConversationReads.new(current_user)
    selected, partner = selected_conversation(conversations)
    shown = shown_messages(selected)
    new_keys = Set.new
    if params[:person_id] && selected
      new_keys = shown.select { |m| reads.unread?(m) }.flat_map(&:read_keys).to_set
      reads.mark_read!(shown) unless impersonating? || prefetch?
    end

    render Views::Evidence::HubView.new(
      conversations: conversations, reads: reads, selected: selected, partner: partner,
      explicit: params[:person_id].present?, new_keys: new_keys,
      thread: thread_details(conversations, shown, (selected&.messages&.size || 0) - shown.size, partner),
      needs: needs_you(conversations),
      open_give_step: params[:give].present? || draft.present?, draft: draft,
      user: current_user, current_tenant: ActsAsTenant.current_tenant, tenants: current_user_tenants
    )
  end

  # GET /evidence/items/:id — a notification's link to one item
  def item
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy
    redirect_to located_path(item_id: params[:id], anchor: EvidenceItem.dom_id(params[:id]))
  end

  # GET /evidence/requests/:id — a notification's link to one request
  def evidence_request
    authorize EvidenceRequest, :index?, policy_class: EvidenceRequestPolicy
    redirect_to located_path(request_id: params[:id], anchor: EvidenceRequest.dom_id(params[:id]))
  end

  private

  def require_person
    head :forbidden unless current_person
  end

  # Turbo fetches a link when the pointer rests on it; that isn't reading.
  def prefetch?
    request.headers["X-Sec-Purpose"] == "prefetch"
  end

  # The route's group for a thread, or `?view=` on the page itself; reports
  # unless the URL asks for people, and only when there are reports.
  def group_for(conversations)
    asked = params[:group] || params[:view]
    asked == "person" || !conversations.reports? ? "person" : "report"
  end

  # The conversation the URL names, or the most recent one. A person with no
  # conversation yet still opens, so "Give feedback" has somewhere to land.
  #
  # @return [Array(Evidence::Conversations::Conversation, Person)]
  def selected_conversation(conversations)
    if params[:person_id]
      convo = conversations.find(params[:person_id])
      person = conversations.people[params[:person_id]] || Person.find_by(id: params[:person_id])
      raise ActiveRecord::RecordNotFound, "No such person" if person.nil?

      [ convo, person ]
    else
      convo = conversations.all.first
      [ convo, convo && conversations.people[convo.person_id] ]
    end
  end

  # The thread holding a message: a report's thread before a person's, and
  # the team view before the org view. The org view lists everything the team
  # view does, so a link already in the org view looks nowhere else.
  def located_path(anchor:, item_id: nil, request_id: nil)
    views = (place_param == "org" ? %w[org] : %w[team org]).map { |scope| Evidence::Conversations.new(current_person, scope: scope) }
    %w[report person].each do |group|
      views.each do |conversations|
        next if group == "report" && !conversations.reports?

        convo = conversations.containing(item_id: item_id, request_id: request_id, group: group)
        next if convo.nil?

        return conversation_path(convo.person_id, group, anchor: anchor, all: beyond_shown?(convo, item_id, request_id),
                                                         scope: conversations.scope)
      end
    end
    evidence_hub_path
  end

  # A thread only the org view lists, opened in the team view (a bookmark, a
  # link from before the switch scoped the conversations). The route names
  # the group: without reports in the team view, the page itself falls back
  # to people.
  def org_only_thread?(conversations)
    return false unless params[:person_id].present? && conversations.scope == "team" && conversations.beyond_team?
    return false if conversations.find(params[:person_id], group: params[:group])

    Evidence::Conversations.new(current_person, scope: "org").find(params[:person_id], group: params[:group]).present?
  end

  def org_thread_path = page_path(request.path, **request.query_parameters.symbolize_keys, place: "org")

  def conversation_path(person_id, group, anchor: nil, all: false, scope: place_param)
    query = { place: (scope == "org" ? "org" : nil), all: (1 if all), anchor: anchor }
    if group == "report"
      evidence_report_conversation_path(person_id, **query)
    else
      evidence_conversation_path(person_id, **query)
    end
  end

  # Whether a message is older than the part of its thread that shows, so a
  # link to it has to ask for the whole thread.
  def beyond_shown?(convo, item_id, request_id)
    index = convo.messages.index { |m| (item_id && m.item&.id == item_id) || (request_id && m.request&.id == request_id) }
    index.present? && index < convo.messages.size - THREAD_LIMIT
  end

  # A link to a message: its thread in the group on screen, or its person
  # thread when the group on screen doesn't list it.
  def message_path(conversations, item_id: nil, request_id: nil, anchor:)
    [ conversations.group, "person" ].uniq.each do |group|
      convo = conversations.containing(item_id: item_id, request_id: request_id, group: group)
      return conversation_path(convo.person_id, group, anchor: anchor, all: beyond_shown?(convo, item_id, request_id)) if convo
    end
    nil
  end

  # ── Needs you ──

  def needs_you(conversations)
    placing = Operations::Assessments::FeedbackToPlace.call(context: pundit_user, params: { scope: place_param })
    about_you, for_team = to_place_records(placing)
    incoming = EvidenceRequest.incoming_for(current_person.id).pending.least_recently_touched
      .includes(:requester, :assessee).to_a
    waiting = EvidenceRequest.outgoing_for(current_person.id).pending.least_recently_touched.includes(:requestee).to_a
    paths = {}
    incoming.each do |r|
      paths[r.id] = message_path(conversations, request_id: r.id, anchor: r.dom_id)
    end
    waiting.each { |r| paths[r.id] = message_path(conversations, request_id: r.id, anchor: r.dom_id) }
    (about_you + for_team).each do |item|
      paths[item.id] = message_path(conversations, item_id: item.id, anchor: EvidenceItem.dom_id(item.id))
    end

    {
      incoming: incoming, about_you: about_you, for_team: for_team, waiting: waiting, paths: paths,
      people: Person.where(id: for_team.map(&:person_id).uniq).index_by(&:id),
      place_scope: placing[:scope], place_counts: (placing[:counts] if conversations.beyond_team?),
      scope_paths: scope_paths(conversations),
      suggestion_counts: EvidencePlacementSuggestion.pending.where(evidence_id: (about_you + for_team).map(&:id))
        .group(:evidence_id).count
    }
  end

  # The page in each scope. Every thread the team view lists is in the org
  # view, but not the other way round: a thread only the org view lists
  # gives way to the list. A person with no thread yet opens in either.
  def scope_paths(conversations)
    in_team = params[:person_id].blank? || conversations.scope == "team" || conversations.find(params[:person_id]).nil? ||
      Evidence::Conversations.new(current_person, scope: "team").find(params[:person_id], group: conversations.group)
    team = in_team ? page_path(request.path, view: params[:view]) : page_path(evidence_hub_path, view: conversations.group)
    { "team" => team, "org" => page_path(request.path, view: params[:view], place: "org") }
  end

  def page_path(path, **query) = [ path, query.compact_blank.to_query.presence ].compact.join("?")

  # "My team" unless the URL asks for the whole org.
  def place_param
    params[:place] == "org" ? "org" : ::Assessments::FeedbackToPlace::DEFAULT_SCOPE
  end

  # The Operation decides which items and in what order; the rows render records.
  def to_place_records(placing)
    ids = (placing[:about_you] + placing[:items]).map { |row| row[:evidence_id] }
    items = EvidenceItem.where(id: ids).includes(:author).index_by(&:id)
    [ placing[:about_you], placing[:items] ].map { |rows| rows.filter_map { |row| items[row[:evidence_id]] } }
  end

  # ── The open thread ──

  # The thread's latest messages, or all of them for `?all=1`.
  def shown_messages(selected)
    messages = selected&.messages || []
    params[:all].present? ? messages : messages.last(THREAD_LIMIT)
  end

  def thread_details(conversations, shown, hidden_count, partner)
    return {} if partner.nil?

    items = shown.filter_map(&:item)
    requests = shown.filter_map(&:request).uniq
    can_regenerate = Evidence::PlacementSuggestionRows.regenerable?(ActsAsTenant.current_tenant)
    linkable = linkable_items(conversations, shown)
    decidable = can_regenerate || EvidencePlacementSuggestion.pending.exists? ? linkable : []

    {
      messages: shown, hidden_count: hidden_count, shown_ids: shown.to_set(&:dom_id),
      owed_ids: shown.select { |m| conversations.owes?(m) }.map(&:dom_id).to_set,
      cells: Evidence::CellContextResolver.new(requests + items.select(&:capability_stable_id)).by_id,
      links: links_for(items),
      in_situ_paths: in_situ_paths_for(items),
      people: Person.where(id: items.map(&:person_id).uniq).index_by(&:id),
      answering: answering(shown),
      suggestions: Evidence::PlacementSuggestionRows.for(decidable), decidable_ids: decidable.to_set(&:id),
      linkable_ids: linkable.to_set(&:id),
      can_regenerate: can_regenerate,
      composer: composer_for(conversations, partner)
    }
  end

  # Items the viewer may place or link: what they're asked to place, plus
  # anything else the policy lets them link. The same items' suggestions are
  # theirs to decide.
  def linkable_items(conversations, shown)
    shown.select(&:item).select do |m|
      conversations.owes?(m) || EvidencePolicy.new(pundit_user, m.item).add_link?
    end.map(&:item)
  end

  # Who asked for each piece of feedback that answers a request the viewer
  # can't see: Alex reads Jordan's answer to Maya as "answering Maya's request".
  #
  # @return [Hash{String => Person}] evidence_id => requester
  def answering(shown)
    ids = shown.select { |m| m.kind == :feedback }.map { |m| m.item.id }
    return {} if ids.empty?

    EvidenceRequest.where(evidence_id: ids).includes(:requester).to_h { |r| [ r.evidence_id, r.requester ] }
  end

  # Every active link of each item, named: "Applies to: Ownership E3".
  #
  # @return [Hash{String => Array<Hash>}] evidence_id => [{ capability_name:, level_code:, valence: }]
  def links_for(items)
    return {} if items.empty?

    by_id = items.index_by(&:id)
    rows = EvidenceLink.active.where(evidence_id: by_id.keys).order(:linked_at, :id)
      .pluck(:evidence_id, :capability_stable_id, :level_ordinal, :valence)
    cells = rows.map do |evidence_id, capability_stable_id, level_ordinal, _valence|
      item = by_id[evidence_id]
      Evidence::CellContextResolver::Cell.new(
        id: [ evidence_id, capability_stable_id, level_ordinal ], framework_id: item.framework_id,
        person_id: item.person_id, capability_stable_id: capability_stable_id, level_ordinal: level_ordinal
      )
    end
    context = Evidence::CellContextResolver.new(cells).by_id
    rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(evidence_id, capability_stable_id, level_ordinal, valence), acc|
      cell = context[[ evidence_id, capability_stable_id, level_ordinal ]] || {}
      acc[evidence_id] << { capability_name: cell[:name], level_code: cell[:level_code] || "L#{level_ordinal}", valence: valence }
    end
  end

  # A deep link to each item's first linkage on its assessment, only where
  # the viewer may open that assessment, so a peer never gets a dead link.
  #
  # @return [Hash{String => String}] evidence_id => assessment path
  def in_situ_paths_for(items)
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

  # What the composer under a thread can do: give the other person feedback,
  # and ask for some — of them about the viewer, or of anyone about a report.
  def composer_for(conversations, partner)
    report_thread = conversations.group == "report"
    own = PersonFrameworkAssignment.where(person_id: current_person.id).order(:created_at, :id).last
    return { self_thread: true, own_assessment_path: own && assessment_path(own) } if partner.id == current_person.id

    partner_assignments = PersonFrameworkAssignment.where(person_id: partner.id).order(:created_at, :id).to_a
    # A request is about one assessment; with several, the newest is the one in use.
    ask_assignment = report_thread ? partner_assignments.last : own
    can_ask = ask_assignment.present? && EvidenceRequestPolicy.new(pundit_user, ask_assignment).request?

    {
      report_thread: report_thread,
      give_assignment_id: (partner_assignments.first.id if partner_assignments.one?),
      can_give: partner_assignments.any?,
      ask_assignment_id: (ask_assignment.id if can_ask),
      ask_requestee_id: (partner.id unless report_thread)
    }
  end

  # A Slack draft the author arrived with (Evidence::DraftsController): the
  # modal opens on arrival, filled from it. Theirs only, and only while open.
  def draft
    return @draft if defined?(@draft)

    @draft = FeedbackDraft.open_for(token: params[:draft], email: current_user.email)
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end
