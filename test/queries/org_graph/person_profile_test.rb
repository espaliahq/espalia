# frozen_string_literal: true

require "test_helper"

class OrgGraph::PersonProfileTest < ActiveSupport::TestCase
  include OrgGraphFixture

  TODAY = Date.new(2026, 4, 1)

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def profile(person) = as_tenant { OrgGraph::PersonProfile.new(person.reload, today: TODAY).tap(&:history) }

  def as_actor(person, &)
    AuditMetadata.with(acting_via: :web, actor_id: person.id) { AuditMetadata.wrap_event_store(&) }
  end

  should "list a person's teams by unit name, with role and allocation" do
    memberships = as_tenant { profile(@org[:brook]).memberships }

    assert_equal %w[Checkout Platform], memberships.map { |m| m.unit.name }
    assert_equal [ "Tech lead", 0.5 ], [ memberships.first.role, memberships.first.allocation ]
  end

  should "give each employment fact in effect today its provider and since, then the start date" do
    as_tenant do
      @handler.apply_facts(@org[:brook].id, provider: "espalia", effective_on: "2026-02-01",
                           title: "Senior Engineer", manager_id: @org[:ada].id, site: "Sydney", country: "AU",
                           fte: 0.8, employment_type: "part_time")
    end

    facts = profile(@org[:brook]).employment.index_by(&:fact)

    assert_equal %w[title manager site employment started], facts.keys
    assert_equal [ "Senior Engineer", "espalia", Date.new(2026, 2, 1) ], facts["title"].to_h.values_at(:value, :provider, :since)
    assert_equal "Ada Quill", facts["manager"].value
    assert_equal "Sydney, AU", facts["site"].value
    assert_equal "Part time, 0.8 FTE", facts["employment"].value
    assert_equal Date.new(2026, 1, 5), facts["started"].since
  end

  should "leave out a fact that takes effect after today" do
    as_tenant { @handler.apply_facts(@org[:brook].id, provider: "espalia", effective_on: "2026-06-01", title: "Staff Engineer") }

    assert_not_includes profile(@org[:brook]).employment.map(&:value), "Staff Engineer"
  end

  should "tell the history newest first, with effective and learned dates and who made each change" do
    as_tenant { @handler.apply_facts(@org[:brook].id, provider: "espalia", effective_on: "2026-02-01", title: "Engineer") }
    travel_to Time.zone.parse("2026-03-10 09:00") do
      as_tenant do
        as_actor(@org[:ada]) do
          @handler.apply_facts(@org[:brook].id, provider: "espalia", effective_on: "2026-03-01", title: "Senior Engineer")
          @handler.end_membership(@org[:brook].id, @org[:platform], provider: "espalia", effective_on: "2026-03-02")
        end
      end
    end

    history = profile(@org[:brook]).history

    left, retitled = history.first(2)
    assert_equal [ "Left Platform", Date.new(2026, 3, 2), "Ada Quill" ], [ left.summary, left.effective_on, left.actor&.name ]
    assert_equal "Title changed from Engineer to Senior Engineer", retitled.summary
    assert_equal Time.zone.parse("2026-03-10 09:00"), retitled.learned_at
    assert_includes history.map(&:summary), "Joined Checkout as Tech lead at 50%"
    assert_equal "Started", history.last.summary
    assert_nil history.last.actor, "the system recorded the start, not a person"
  end

  should "date a move's leaving on the day of the move, not the day before" do
    as_tenant { @handler.move_membership(@org[:brook].id, @org[:platform], @org[:payments], effective_on: "2026-03-02") }

    changes = profile(@org[:brook]).history.index_by(&:summary)

    assert_equal Date.new(2026, 3, 2), changes.fetch("Left Platform").effective_on
    assert_equal Date.new(2026, 3, 2), changes.keys.grep(/\AJoined Payments/).then { changes.fetch(it.first).effective_on }
  end

  should "write nothing for a change that changes nothing" do
    as_tenant do
      @handler.set_membership(@org[:brook].id, @org[:checkout], allocation: 0.5, role: "Tech lead", provider: "espalia", effective_on: "2026-02-01")
      @handler.join(@org[:brook].id, provider: "espalia", effective_on: "2026-02-01")
    end

    summaries = profile(@org[:brook]).history.map(&:summary)

    assert_equal 1, summaries.count { it.start_with?("Joined Checkout") }
    assert_empty summaries.grep(/\AIn Checkout/)
    assert_equal 1, summaries.count("Started")
  end

  should "give the first day of the spell they are in, and no start once they have left" do
    as_tenant { @handler.join(@org[:brook].id, provider: "espalia", effective_on: "2026-02-01") }
    assert_equal Date.new(2026, 1, 5), profile(@org[:brook]).employment.find { it.fact == "started" }.since

    as_tenant { @handler.leave(@org[:brook].id, provider: "espalia", effective_on: "2026-03-01") }
    assert_nil profile(@org[:brook]).employment.find { it.fact == "started" }
  end

  should "read a forgotten person as a former member and keep their history" do
    brook = @org[:brook]
    as_tenant { brook.update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current) }

    result = profile(brook)

    assert_equal Person::FORMER_MEMBER, result.person.name
    assert_includes result.history.map(&:summary), "Joined Platform at 50%"
  end

  should "name a manager who was forgotten as a former member" do
    as_tenant do
      @handler.apply_facts(@org[:brook].id, provider: "espalia", effective_on: "2026-02-01", manager_id: @org[:ada].id)
      @org[:ada].update_columns(name: Person::FORMER_MEMBER, email: nil, forgotten_at: Time.current)
    end

    assert_equal Person::FORMER_MEMBER, profile(@org[:brook]).employment.find { |f| f.fact == "manager" }.value
  end
end
