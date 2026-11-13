# frozen_string_literal: true

# Candidate participant raters for a calibration session: **managers
# only** (people with at least one report), scoped the way the
# assessment-cycle reports scope their audience — tenant-wide for
# tenant/global admins, the viewer's own org subtree (plus themselves)
# for a manager. Powers the shared person-picker's typeahead and its
# quick-add suggestions.
class CalibrationSessions::ParticipantCandidates
  SEARCH_LIMIT = 12
  SUGGESTION_LIMIT = 8

  # @param viewer [Person, nil] the acting person (nil only for admins)
  # @param admin [Boolean] tenant/global admin → tenant-wide scope
  def initialize(viewer:, admin:)
    @viewer = viewer
    @admin = admin
  end

  # Typeahead search by name or email (token-AND, case-insensitive).
  #
  # @param query [String, nil]
  # @param limit [Integer]
  # @return [Array<Hash>] `{ person:, subtitle: }`, name-ordered
  def search(query, limit: SEARCH_LIMIT)
    tokens = query.to_s.strip.split(/\s+/).first(5)
    return [] if tokens.empty?

    scope = manager_scope
    tokens.each do |token|
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"
      scope = scope.where("people.name ILIKE :q OR people.email ILIKE :q", q: pattern)
    end
    decorate(scope.order(:name).limit(limit))
  end

  # Quick-add suggestions: the viewer's direct reports who are themselves
  # managers — the department-head-with-their-EMs shape most sessions
  # take. Applies whenever the viewer has a linked Person (an admin who
  # also manages people gets their own team too); an admin without one
  # is search-first.
  #
  # @return [Array<Hash>] `{ person:, subtitle: }`
  def suggestions
    return [] if @viewer.nil?

    decorate(
      manager_scope.where(manager_id: @viewer.id).order(:name).limit(SUGGESTION_LIMIT)
    )
  end

  private

  # Managers within scope: admins search the whole org; a manager stays
  # inside their own subtree (themselves included — a facilitator who
  # directly manages ICs may sit in the room as a rater too).
  def manager_scope
    scope = Person.where(forgotten_at: nil).where(id: Person.where.not(manager_id: nil).select(:manager_id).distinct)
    return scope if @admin
    return Person.none unless @viewer

    scope.where(id: @viewer.all_reports.select(:id)).or(scope.where(id: @viewer.id))
  end

  def decorate(people)
    report_counts = Person.where(manager_id: people.map(&:id)).group(:manager_id).count
    people.map do |person|
      count = report_counts.fetch(person.id, 0)
      subtitle = [ person.job_title.presence, "#{count} #{'report'.pluralize(count)}" ].compact.join(" · ")
      { person: person, subtitle: subtitle }
    end
  end
end
