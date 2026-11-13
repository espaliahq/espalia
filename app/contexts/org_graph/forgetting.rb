# frozen_string_literal: true

# Erases a leaver's identifiers and records `PersonForgotten`. The one step
# in the Org Graph that cannot be undone.
#
# Each person is one transaction: the row's identifiers, their tenant
# membership's link to a login, the names notifications copied, and the
# event, with the projections that handle it. A run that dies partway
# leaves each person either forgotten or untouched, and the next run takes
# whoever is still due.
#
# The row keeps a keyed digest of its external id, so a later sync can
# recognise the person without identifying them. Without the key nothing is
# forgotten.
#
# Every result is a count and person ids, never a name or an email.
#
# @example
#   forgetting = OrgGraph::Forgetting.new(tenant)
#   forgetting.dry_run                 # => #<data Report count=2, person_ids=[...]>
#   forgetting.forget_due              # => #<data Report count=2, person_ids=[...]>
#   forgetting.forget(person_id, requested_by: context, before_due: true)
class OrgGraph::Forgetting
  # A forgetting the guards don't allow.
  class Refused < StandardError; end

  # The tenant turned scheduled forgetting off while a scheduled run was going.
  class ScheduleTurnedOff < StandardError; end

  # The digest key is missing, so nobody can be forgotten, and a sync can't
  # recognise anyone already forgotten.
  class KeyMissing < StandardError
    def initialize(msg = "The Org Graph forgetting key is not set: set credentials org_graph.forgetting_key " \
                         "or ORG_GRAPH_FORGETTING_KEY")
      super
    end
  end

  # Who a run would forget, or did.
  #
  # @!attribute count [Integer]
  # @!attribute person_ids [Array<String>]
  Report = Data.define(:count, :person_ids) do
    def self.of(person_ids) = new(count: person_ids.size, person_ids: person_ids)
  end

  # Notification params that copy a person's name by value, each beside the
  # param that holds that person's id. Notifications written before 8.2 have
  # only the name.
  NAME_PARAMS = { "actor_name" => "actor_id", "assessee_name" => "assessee_id", "author_name" => "author_id",
                  "decliner_name" => "decliner_id", "requested_by_name" => "requested_by_id",
                  "requester_name" => "requester_id", "responder_name" => "responder_id",
                  "started_by_name" => "started_by_id" }.freeze
  NAME_LIST_PARAMS = { "skipped_names" => "skipped_ids" }.freeze
  # A comment notification's context opens "<name>'s feedback" when the
  # thread hangs off someone's evidence.
  FEEDBACK_CONTEXT = "'s feedback"

  # Removes the manager a stored HiBob payload names, in both its shapes.
  WITHOUT_REPORTS_TO = "hris_raw_data = hris_raw_data #- '{work,reportsTo}' #- '{humanReadable,work,reportsTo}'"

  # @return [String, nil]
  def self.key
    Rails.application.credentials.dig(:org_graph, :forgetting_key).presence || ENV["ORG_GRAPH_FORGETTING_KEY"].presence
  end

  # @raise [KeyMissing]
  def self.key! = key || raise(KeyMissing)

  # Drops the names of forgotten people from a notification about to be
  # written. Waits on an erasure in flight in its tenant, which holds the
  # lock exclusively until it commits, so a notification built from a name
  # read before the erasure can't land after its scrub with the name.
  #
  # @param params [Hash] the notification's params, changed in place
  # @return [Hash]
  def self.without_forgotten_names(params)
    tenant = params[:tenant_id].presence && Tenant.find_by(id: params[:tenant_id])
    ids = named_ids(params)
    return params if tenant.nil? || ids.empty?

    Person.connection.select_value(
      Person.sanitize_sql_array([ "SELECT 1 FROM pg_advisory_xact_lock_shared(?)", OrgGraph::PeopleCutover.lock_key(tenant) ])
    )
    forgotten = Person.unscoped.where(tenant_id: tenant.id, id: ids).where.not(forgotten_at: nil).pluck(:id)
    forgotten.empty? ? params : drop_names(params, forgotten.to_set)
  end

  def self.named_ids(params)
    (NAME_PARAMS.values.map { params[it.to_sym] } +
      NAME_LIST_PARAMS.values.flat_map { Array(params[it.to_sym]) } +
      [ params[:feedback_author_id] ]).compact_blank.map(&:to_s).uniq
  end

  def self.drop_names(params, forgotten)
    NAME_PARAMS.each { |name_key, id_key| params[name_key.to_sym] = nil if forgotten.include?(params[id_key.to_sym].to_s) }
    NAME_LIST_PARAMS.each do |names_key, ids_key|
      next unless params[ids_key.to_sym].is_a?(Array)

      kept = params[ids_key.to_sym].each_with_index.reject { |id, _| forgotten.include?(id.to_s) }
      params[names_key.to_sym] = kept.map { |_, at| Array(params[names_key.to_sym])[at] } if params.key?(names_key.to_sym)
      params[ids_key.to_sym] = kept.map(&:first)
    end
    if forgotten.include?(params[:feedback_author_id].to_s) && params[:context].to_s.include?(FEEDBACK_CONTEXT)
      params[:context] = Person::FORMER_MEMBER + params[:context].to_s.partition(FEEDBACK_CONTEXT).drop(1).join
    end
    params
  end
  private_class_method :named_ids, :drop_names

  # @param tenant [Tenant]
  # @param source [String] the HRIS the id comes from
  # @param external_id [String]
  # @return [String] what a forgotten row keeps of its external id
  # @raise [KeyMissing]
  def self.digest(tenant, source, external_id)
    OpenSSL::HMAC.hexdigest("SHA256", key!, "#{tenant.id}:#{source}:#{external_id}")
  end

  # @param tenant [Tenant]
  # @param hris [#active_external_ids, nil] the tenant's HRIS, or nil when it has none
  def initialize(tenant, hris: default_hris(tenant))
    @tenant = tenant
    @hris = hris
  end

  # Who {#forget_due} would forget today, after the same HRIS check.
  #
  # @param on [Date]
  # @return [Report]
  # @raise [Hris::Hibob::Errors::Error] and the like, when the HRIS can't be reached
  def dry_run(on: Date.current)
    Report.of(candidates(on))
  end

  # Forgets every leaver whose retention period has ended and whom the HRIS
  # doesn't show as employed or starting again. Each person is checked again
  # against the tenant's settings as they stand when their turn comes, so a
  # longer retention period spares them, and a scheduled run stops once the
  # schedule is off.
  #
  # @param on [Date]
  # @param scheduled [Boolean] whether the daily schedule is running this
  # @return [Report] who was forgotten
  # @raise [KeyMissing] before anything is erased
  def forget_due(on: Date.current, scheduled: false)
    self.class.key!
    forgotten = []
    candidates(on).each { |person_id| forgotten << person_id if erase_due(person_id, on:, scheduled:) }
    Report.of(forgotten)
  rescue ScheduleTurnedOff
    Report.of(forgotten)
  end

  # Forgets one leaver at a tenant admin's request. A leaver not yet due is
  # refused unless the admin says so with `before_due`, and the event names
  # them either way.
  #
  # @param person_id [String]
  # @param requested_by [AuthorizationContext] the admin asking
  # @param before_due [Boolean] whether to forget a leaver whose period hasn't ended
  # @param on [Date]
  # @return [Boolean] whether this call forgot them; false when they already were
  # @raise [Pundit::NotAuthorizedError] unless the requester is a tenant admin
  # @raise [Refused] for anyone not due without `before_due`, or whom the HRIS
  #   still employs, and for a requester with no tenant membership to record
  # @raise [KeyMissing]
  def forget(person_id, requested_by:, before_due: false, on: Date.current)
    self.class.key!
    raise Pundit::NotAuthorizedError, "Only a tenant admin can forget a person" unless
      TenantPolicy.new(requested_by, @tenant).forget_person?
    requested_by_id = requested_by.tenant_user&.id
    raise Refused, "The request must come from a tenant member, so the event can name who asked" unless requested_by_id
    return false if within_tenant { Person.find(person_id).forgotten? }

    due = within_tenant { OrgLeaver.due_to_be_forgotten(@tenant, on:) }.include?(person_id)
    raise Refused, "This person is not due to be forgotten; say before_due to forget them now" unless due || before_due
    raise Refused, "The HRIS still shows this person as employed or starting" unless candidate_ids([ person_id ]).any?

    erase(person_id, on:, reason: due ? "retention" : "request", requested_by_id:)
  end

  private

  def default_hris(tenant)
    Hris::BaseAdapter.for(tenant) if tenant.hris_config.connected?(tenant)
  end

  def within_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def candidates(on)
    candidate_ids(within_tenant { OrgLeaver.due_to_be_forgotten(@tenant, on:) })
  end

  # A rehire whose start is still ahead has no `PersonReturned` yet, so they
  # stay on the due list. The HRIS still holding them active keeps them.
  def candidate_ids(person_ids)
    held = within_tenant { Person.where(id: person_ids).where.not(external_id: nil).pluck(:id, :external_id).to_h }
    return person_ids if held.empty? || @hris.nil?

    active = @hris.active_external_ids.to_set
    person_ids.reject { |person_id| active.include?(held[person_id]) }
  end

  # One person who can't be forgotten must not hold up those due after them.
  def erase_due(person_id, on:, scheduled:)
    erase(person_id, on:, reason: "retention", scheduled:)
  rescue ScheduleTurnedOff
    raise
  rescue => e
    Rails.error.report(e, context: { tenant_id: @tenant.id, person_id: })
    Rails.logger.error("[OrgGraph::Forgetting] tenant=#{@tenant.id} person=#{person_id} failed: #{e.class}")
    false
  end

  # The tenant row is read under a share lock, so its retention period and
  # schedule can't change until this person is done.
  def erase(person_id, on:, reason:, requested_by_id: nil, scheduled: false)
    within_tenant do
      Person.transaction do
        hold_off_syncs
        config = Tenant.lock("FOR SHARE").find(@tenant.id).org_graph_config
        raise ScheduleTurnedOff if scheduled && !config.scheduled_forgetting
        person = Person.lock.find(person_id)
        next false if person.forgotten?
        if reason == "retention" && !due?(person_id, config, on)
          raise Refused, "This person is no longer due to be forgotten" if requested_by_id

          next false
        end

        scrub_notifications(person.id, person.read_attribute(:name))
        drop_notifications_to(person)
        scrub_exchange_ledger(person.email)
        scrub_reports_raw_data(person.external_id)
        AuditMetadata.wrap_event_store do
          OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
            .forget_person(person_id, effective_on: on, reason:, retention_years: config.retention_years,
                                      requested_by_id:)
        end
        erase_identifiers(person)
        true
      end
    end
  end

  def due?(person_id, config, on)
    cutoff = config.forget_left_on_or_before(on)
    cutoff.present? && OrgLeaver.where(tenant: @tenant, person_id:, left_on: ..cutoff).exists?
  end

  # Every HRIS sync holds this lock shared for its whole run, and checks once
  # at its start whether anyone is forgotten. Taken before any row lock, so it
  # waits for a running sync and never deadlocks with one.
  def hold_off_syncs
    Person.connection.select_value(
      Person.sanitize_sql_array([ "SELECT 1 FROM pg_advisory_xact_lock(?)", OrgGraph::PeopleCutover.lock_key(@tenant) ])
    )
  end

  def erase_identifiers(person)
    now = Time.current
    digest = self.class.digest(@tenant, person.hris_source, person.external_id) if person.external_id.present?
    person.update_columns(name: nil, email: nil, external_id: nil, hris_raw_data: nil,
                          forgotten_external_id_digest: digest, forgotten_at: now, updated_at: now)
    TenantUser.where(person_id: person.id)
      .update_all(person_id: nil, user_id: nil, slack_user_id: nil, forgotten_at: now, updated_at: now)
  end

  # Their own inbox in this tenant. The login is global and stays, so
  # notifications would otherwise tie it to the former member.
  def drop_notifications_to(person)
    user_ids = TenantUser.where(person_id: person.id).where.not(user_id: nil).select(:user_id)
    Noticed::Notification.where(recipient_type: "User", recipient_id: user_ids)
      .where(event_id: tenant_events.select(:id)).delete_all
  end

  # A skipped feedback-exchange record is kept whole to be retried, people's
  # emails and names included. Without it the row is never retried.
  def scrub_exchange_ledger(email)
    return if email.blank?

    FeedbackExchangeImport.where(tenant: @tenant).where.not(record: nil)
      .where("LOWER(record->'recipient'->>'email') = :email OR LOWER(record->'author'->>'email') = :email",
             email: email.downcase)
      .update_all(record: nil, updated_at: Time.current)
  end

  # A report's stored HiBob payload names their manager under `reportsTo`.
  # The sync reads the manager from the live response, never from here.
  def scrub_reports_raw_data(external_id)
    return if external_id.blank?

    Person.where("hris_raw_data #>> '{work,reportsTo,id}' = ?", external_id.to_s)
      .update_all(OrgGraph::Forgetting::WITHOUT_REPORTS_TO)
  end

  def tenant_events = Noticed::Event.where("params->>'tenant_id' = ?", @tenant.id)

  # A notification names a person beside their id, so the scrub matches the
  # id. One written before 8.2 holds only the name, so there the match is on
  # the name within the tenant, and a namesake loses theirs too.
  def scrub_notifications(person_id, name)
    scrub_feedback_contexts(person_id, name)
    ids = tenant_events.where(notification_matches(person_id, name).join(" OR ")).pluck(:id)
    return if ids.empty?

    events = Noticed::Event.where(id: ids)
    NAME_PARAMS.each do |name_key, id_key|
      events.where(by_id(id_key, person_id)).or(events.where(legacy_name(name_key, id_key, name)))
        .update_all([ "params = jsonb_set(params, ARRAY[?], 'null'::jsonb)", name_key ])
    end
    NAME_LIST_PARAMS.each do |names_key, ids_key|
      events.where(listed_id(ids_key, person_id)).update_all(without_listed(names_key, ids_key, person_id))
      events.where(legacy_listed_name(names_key, ids_key, name))
        .update_all([ "params = jsonb_set(params, ARRAY[?], (params->?) - ?)", names_key, names_key, name ])
    end
  end

  def scrub_feedback_contexts(person_id, name)
    named = sql("params->>'feedback_author_id' = ? AND strpos(params->>'context', ?) > 0", person_id, FEEDBACK_CONTEXT)
    if name.present?
      named += " OR " + sql("NOT jsonb_exists(params, 'feedback_author_id') AND starts_with(params->>'context', ?)",
                            name + FEEDBACK_CONTEXT)
    end
    tenant_events.where(named).update_all(sql(<<~SQL.squish, Person::FORMER_MEMBER + FEEDBACK_CONTEXT, FEEDBACK_CONTEXT))
      params = jsonb_set(params, '{context}',
        to_jsonb(? || substr(params->>'context', strpos(params->>'context', ?) + #{FEEDBACK_CONTEXT.length})))
    SQL
  end

  def notification_matches(person_id, name)
    NAME_PARAMS.flat_map { |name_key, id_key| [ by_id(id_key, person_id), legacy_name(name_key, id_key, name) ] } +
      NAME_LIST_PARAMS.flat_map do |names_key, ids_key|
        [ listed_id(ids_key, person_id), legacy_listed_name(names_key, ids_key, name) ]
      end
  end

  def by_id(id_key, person_id) = sql("params->>? = ?", id_key, person_id)

  def legacy_name(name_key, id_key, name)
    return "FALSE" if name.blank?

    sql("NOT jsonb_exists(params, ?) AND params->>? = ?", id_key, name_key, name)
  end

  def listed_id(ids_key, person_id) = sql("jsonb_exists(params->?, ?)", ids_key, person_id)

  def legacy_listed_name(names_key, ids_key, name)
    return "FALSE" if name.blank?

    sql("NOT jsonb_exists(params, ?) AND jsonb_exists(params->?, ?)", ids_key, names_key, name)
  end

  # Drops the person's id from the list and the name at the same position.
  def without_listed(names_key, ids_key, person_id)
    sql(<<~SQL.squish, names_key, names_key, ids_key, person_id, ids_key, ids_key, person_id)
      params = jsonb_set(jsonb_set(params, ARRAY[?],
        COALESCE((SELECT jsonb_agg(listed.name ORDER BY listed.at)
                  FROM jsonb_array_elements(params->?) WITH ORDINALITY AS listed(name, at)
                  WHERE params->?->>(listed.at::int - 1) IS DISTINCT FROM ?), '[]'::jsonb)),
        ARRAY[?], (params->?) - ?)
    SQL
  end

  def sql(*args) = Noticed::Event.sanitize_sql_array(args)
end
