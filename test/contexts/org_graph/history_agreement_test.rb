# frozen_string_literal: true

require "test_helper"

class OrgGraph::HistoryAgreementTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia" }.freeze
  SYSTEM = OrgGraph::Authorization::SYSTEM
  HIBOB = { provider: "hibob", employment_status: "employed" }.freeze

  setup do
    @tenant = create(:tenant, org_graph_people_projected_at: Time.current)
    @handler = OrgGraph::CommandHandler.new(actor: SYSTEM)
    @structure = OrgGraph::StructureCommandHandler.new(actor: SYSTEM)
    @departments, @squads = SecureRandom.uuid_v7, SecureRandom.uuid_v7
    @engineering, @payments, @platform = Array.new(3) { SecureRandom.uuid_v7 }

    travel_to Time.zone.parse("2026-02-01 09:00")
    as_tenant do
      @ada = create(:person, tenant: @tenant)
      @structure.define_taxonomy([ { level_id: @departments, name: "Department" }, { level_id: @squads, name: "Squad" } ],
        effective_on: "2026-01-01")
      @structure.create_unit(@engineering, "Engineering", level_id: @departments, effective_on: "2026-01-01")
      @structure.create_unit(@payments, "Payments", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      @structure.create_unit(@platform, "Platform", level_id: @squads, parent_id: @engineering, effective_on: "2026-01-01")
      @handler.record_person(@ada.id, **ESPALIA, effective_on: "2026-02-01", employment_status: "employed", title: "Engineer")
      @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 0.5)

      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, user:, tenant: @tenant), person: nil)
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def on(date) = Date.iso8601(date)

  def later(date, &)
    travel_to Time.zone.parse("#{date} 09:00")
    as_tenant(&)
  end

  def as_of(date) = as_tenant { OrgGraph::AsOf.new(context: @context, date: on(date)).call }

  def changes(from, to) = as_tenant { OrgGraph::ChangesBetween.new(context: @context, from: on(from), to: on(to)).call }

  def history(fact, date, key: "") = history_for(@ada, fact, date, key:)

  def history_for(person, fact, date, key: "")
    as_tenant do
      OrgFactPeriod.current.in_effect_on(on(date))
                   .where(subject_type: "person", subject_id: person.id, fact:, key:).pick(:value)
    end
  end

  def hibob_person
    as_tenant do
      @structure.claim_facts(OrgGraph::StructureAggregate::FACTS, "hibob", effective_on: "2026-01-01")
      create(:person, tenant: @tenant, hris_source: "hibob", external_id: "hb-grace")
    end
  end

  def allocations_as_of(date) = as_of(date).memberships.to_h { [ it.unit_id, it.allocation ] }

  def live_allocations = as_tenant { OrgMembership.where(person_id: @ada.id).to_h { [ it.unit_id, it.allocation ] } }

  def live_title = @ada.reload.job_title

  context "a fact learned later with an earlier effective date than a fact already held" do
    should "leave the later membership terms in force today and fill only the gap before them" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8) }
      later("2026-04-15") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 1.0) }

      assert_equal 0.8, history("membership", "2026-04-15", key: @payments)["allocation"]
      assert_equal({ @payments => 0.8 }, allocations_as_of("2026-04-15"))
      assert_equal({ @payments => 0.8 }, live_allocations)

      OrgGraph::Projections::Members.reset!(tenant: @tenant)
      Projections::Replayer.replay(projection_class: OrgGraph::Projections::Members, tenant: @tenant)
      assert_equal({ @payments => 0.8 }, live_allocations)

      assert_equal 1.0, history("membership", "2026-02-15", key: @payments)["allocation"]
      assert_equal({ @payments => 1.0 }, allocations_as_of("2026-02-15"))
      assert_equal 0.5, history("membership", "2026-02-05", key: @payments)["allocation"]
    end

    should "leave the later title in force today and fill only the gap before it" do
      later("2026-03-01") { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01") }
      later("2026-04-15") { @handler.change_title(@ada.id, "Engineer II", **ESPALIA, effective_on: "2026-02-10") }

      assert_equal "Senior Engineer", history("title", "2026-04-15")["title"]
      assert_equal "Senior Engineer", as_of("2026-04-15").people.sole.title
      assert_equal "Senior Engineer", live_title

      OrgGraph::Projections::PeopleColumns.reset!(tenant: @tenant)
      Projections::Replayer.replay(projection_class: OrgGraph::Projections::PeopleColumns, tenant: @tenant)
      assert_equal "Senior Engineer", live_title

      assert_equal "Engineer II", history("title", "2026-02-15")["title"]
      assert_equal "Engineer II", as_of("2026-02-15").people.sole.title
      assert_equal "Engineer", as_of("2026-02-05").people.sole.title
    end
    should "write the backdated fact, so history still holds it" do
      later("2026-03-01") { @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01") }
      later("2026-04-15") { @handler.change_title(@ada.id, "Engineer II", **ESPALIA, effective_on: "2026-02-10") }

      stream = EventStreamNaming.person_stream(@ada.id, tenant: @tenant)
      titles = Rails.configuration.event_store.read.stream(stream).of_type(OrgGraph::Events::TitleChanged).map(&:data)
      assert_equal [ [ "Senior Engineer", "2026-03-01" ], [ "Engineer II", "2026-02-10" ] ],
                   titles.map { it.values_at(:title, :effective_on).map(&:to_s) }
    end

    should "carry the later terms into a move" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8) }
      later("2026-04-15") do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 1.0)
        @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-04-15")
      end

      assert_equal 0.8, history("membership", "2026-04-15", key: @platform)["allocation"]
      assert_equal({ @platform => 0.8 }, allocations_as_of("2026-04-15"))
      assert_equal({ @platform => 0.8 }, live_allocations)
    end

    should "leave the sync nothing to write when the HRIS still holds the later fact" do
      grace = hibob_person
      sync = ->(date, title) { later(date) { @handler.sync_person(grace.id, **HIBOB, effective_on: date, title:) } }

      sync.call("2026-02-01", "Engineer")
      sync.call("2026-03-01", "Senior Engineer")
      later("2026-04-15") { @handler.change_title(grace.id, "Engineer II", provider: "hibob", effective_on: "2026-02-10") }

      assert_equal 0, sync.call("2026-04-16", "Senior Engineer")
      assert_equal "Senior Engineer", grace.reload.job_title
      assert_equal 1, sync.call("2026-04-17", "Staff Engineer")
      assert_equal "Staff Engineer", grace.reload.job_title
    end

    should "let the later-learned fact win when two share a date" do
      later("2026-03-01") do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8)
        @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01")
      end
      later("2026-04-15") do
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.6)
        @handler.change_title(@ada.id, "Lead Engineer", **ESPALIA, effective_on: "2026-03-01")
      end

      assert_equal 0.6, history("membership", "2026-04-15", key: @payments)["allocation"]
      assert_equal({ @payments => 0.6 }, allocations_as_of("2026-04-15"))
      assert_equal({ @payments => 0.6 }, live_allocations)
      assert_equal "Lead Engineer", history("title", "2026-04-15")["title"]
      assert_equal "Lead Engineer", as_of("2026-04-15").people.sole.title
      assert_equal "Lead Engineer", live_title
    end

    should "write a backdated fact that matches the later one, so history moves its start back" do
      later("2026-03-01") do
        @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-03-01")
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8)
      end
      later("2026-04-15") do
        @handler.change_title(@ada.id, "Senior Engineer", **ESPALIA, effective_on: "2026-02-20")
        @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-20", allocation: 0.8)
      end

      assert_equal "Senior Engineer", history("title", "2026-02-25")["title"]
      assert_equal "Senior Engineer", as_of("2026-02-25").people.sole.title
      assert_equal 0.8, history("membership", "2026-02-25", key: @payments)["allocation"]
      assert_equal({ @payments => 0.8 }, allocations_as_of("2026-02-25"))
    end

    should "leave the sync nothing to write while a later-dated fact waits to take effect" do
      grace = hibob_person
      sync = ->(date, title) { later(date) { @handler.sync_person(grace.id, **HIBOB, effective_on: date, title:) } }

      sync.call("2026-02-01", "Engineer")
      later("2026-04-15") { @handler.change_title(grace.id, "Senior Engineer", provider: "hibob", effective_on: "2026-05-01") }

      assert_equal [ 0, 0 ], [ sync.call("2026-04-16", "Engineer"), sync.call("2026-04-17", "Engineer") ]
      assert_equal "Engineer", as_of("2026-04-17").people.find { it.id == grace.id }.title
      assert_equal "Senior Engineer", history_for(grace, "title", "2026-05-01")["title"]
    end

    should "change back a backdated membership change even when the later terms match the ones it restores" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8) }
      later("2026-04-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01", allocation: 0.5) }
      later("2026-04-15") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 1.0) }

      later("2026-04-16") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
      end

      assert_equal [ 0.5, 0.8, 0.5 ],
                   %w[2026-02-15 2026-03-15 2026-04-16].map { history("membership", it, key: @payments)["allocation"] }
      assert_equal({ @payments => 0.5 }, live_allocations)
    end

    should "change back a second change on the same date to the first one" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 0.8) }
      later("2026-03-02") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 0.3) }

      later("2026-03-03") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
      end

      assert_equal [ 0.5, 0.8 ], %w[2026-02-05 2026-02-15].map { history("membership", it, key: @payments)["allocation"] }
      assert_equal({ @payments => 0.8 }, live_allocations)
    end

    should "change back the backdated membership change and leave the later terms" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8) }
      later("2026-04-15") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-10", allocation: 1.0) }

      later("2026-04-16") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
      end

      assert_equal 0.5, history("membership", "2026-02-15", key: @payments)["allocation"]
      assert_equal({ @payments => 0.5 }, allocations_as_of("2026-02-15"))
      assert_equal({ @payments => 0.8 }, allocations_as_of("2026-04-16"))
      assert_equal({ @payments => 0.8 }, live_allocations)
    end

    should "refuse to change back a set that moved the day she joined earlier, and write nothing" do
      later("2026-04-15") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-01-10", allocation: 0.5) }
      change_back = OrgGraph::ChangeBackHandler.new(actor: SYSTEM)
      entry = as_tenant { OrgUnitActivity.for_unit(@payments).first }
      reason = "This moved the day they joined earlier, which can't be undone yet"

      assert_equal reason, as_tenant { change_back.refusal(entry) }
      error = assert_raises(RuntimeError) { later("2026-04-16") { change_back.change_back(entry) } }
      assert_equal reason, error.message
      assert_not as_tenant { entry.reload.changed_back? }
      assert_equal 0.5, history("membership", "2026-01-15", key: @payments)["allocation"]
      assert_equal on("2026-01-10"), as_tenant { OrgMembership.find_by!(person_id: @ada.id, unit_id: @payments).member_since }
    end

    should "change back a change of terms dated the day she joined" do
      later("2026-03-01") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8) }
      later("2026-04-15") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-01", allocation: 1.0) }

      later("2026-04-16") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
      end

      assert_equal [ 0.5, 0.8 ], %w[2026-02-15 2026-03-15].map { history("membership", it, key: @payments)["allocation"] }
    end

    should "change back two changes of terms made together, the later back to the earlier first" do
      later("2026-04-15") do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8)
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01", allocation: 0.5)
      end

      later("2026-04-16") { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back_group("request-1") }

      assert_equal [ 0.5, 0.5 ], %w[2026-03-15 2026-04-15].map { history("membership", it, key: @payments)["allocation"] }
    end

    should "leave her live terms as history reads them once two changes made together are changed back" do
      later("2026-04-15") do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8)
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01", allocation: 0.6)
      end

      later("2026-04-16") { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back_group("request-1") }

      assert_equal 0.5, history("membership", "2026-04-16", key: @payments)["allocation"]
      assert_equal({ @payments => 0.5 }, live_allocations)
    end

    should "leave her where she was, since the day she joined, once a move is changed back on its own day" do
      later("2026-04-15") { @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-04-01") }
      later("2026-04-16") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@platform).first)
      end

      assert_nil history("membership", "2026-04-16", key: @platform)
      assert_equal 0.5, history("membership", "2026-04-16", key: @payments)["allocation"]
      assert_equal({ @payments => 0.5 }, live_allocations)
      assert_equal on("2026-02-01"), as_tenant { OrgMembership.find_by!(person_id: @ada.id, unit_id: @payments).member_since }
    end

    should "let her membership end before the day of an ending that was changed back" do
      later("2026-04-15") { @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01") }
      later("2026-04-16") do
        OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back(OrgUnitActivity.for_unit(@payments).first)
      end

      later("2026-04-17") { @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-15") }

      assert_nil history("membership", "2026-03-16", key: @payments)
      assert_empty live_allocations
    end

    should "let her membership end before both of two changes made together, dated out of order, once they are changed back" do
      later("2026-04-15") do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01", allocation: 0.8)
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.6)
      end
      later("2026-04-16") { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back_group("request-1") }

      later("2026-04-17") { @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-02-15") }

      assert_nil history("membership", "2026-02-16", key: @payments)
      assert_empty live_allocations
    end

    should "let her be set to terms a change-back withdrew" do
      later("2026-04-15") do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-01", allocation: 0.8)
        request.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-01", allocation: 0.6)
      end
      later("2026-04-16") { OrgGraph::ChangeBackHandler.new(actor: SYSTEM).change_back_group("request-1") }

      later("2026-04-17") { @handler.set_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-04-17", allocation: 0.8) }

      assert_equal 0.8, history("membership", "2026-04-17", key: @payments)["allocation"]
      assert_equal({ @payments => 0.8 }, live_allocations)
    end

    should "change back a request that added her to a unit and then changed her terms there" do
      later("2026-04-15") do
        request = OrgGraph::CommandHandler.new(actor: SYSTEM, cause_id: "request-1")
        request.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-04-15", allocation: 0.4)
        request.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-04-15", allocation: 0.6)
      end
      change_back = OrgGraph::ChangeBackHandler.new(actor: SYSTEM)

      assert_nil as_tenant { change_back.group_refusal("request-1") }
      later("2026-04-16") { change_back.change_back_group("request-1") }
      assert_equal({ @payments => 0.5 }, live_allocations)
    end
  end

  context "a membership ended on a date" do
    should "count the person a member on that last day and not the next" do
      later("2026-03-31") { @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-31") }

      assert_not_nil history("membership", "2026-03-31", key: @payments)
      assert_nil history("membership", "2026-04-01", key: @payments)
      assert_equal [ @payments ], allocations_as_of("2026-03-31").keys
      assert_empty allocations_as_of("2026-04-01")

      assert_empty changes("2026-03-30", "2026-03-31").changes
      ended = changes("2026-03-31", "2026-04-01").changes.sole
      assert_equal [ :membership_ended, on("2026-04-01"), @payments ], [ ended.kind, ended.effective_on, ended.unit_id ]
    end

    should "hand over to a unit joined the next day with no day in neither or both" do
      later("2026-03-31") do
        @handler.end_membership(@ada.id, @payments, **ESPALIA, effective_on: "2026-03-31")
        @handler.set_membership(@ada.id, @platform, **ESPALIA, effective_on: "2026-04-01", allocation: 0.5)
      end

      assert_equal [ @payments ], allocations_as_of("2026-03-31").keys
      assert_equal [ @platform ], allocations_as_of("2026-04-01").keys
      assert_equal [ @platform ], live_allocations.keys
      assert_equal %i[membership_ended membership_started].sort,
                   changes("2026-03-31", "2026-04-01").changes.map(&:kind).sort
    end

    should "count a move on a date in the new unit only, from that date" do
      later("2026-03-31") { @handler.move_membership(@ada.id, @payments, @platform, effective_on: "2026-03-31") }

      assert_equal 0.5, history("membership", "2026-03-30", key: @payments)["allocation"]
      assert_nil history("membership", "2026-03-31", key: @payments)
      assert_equal 0.5, history("membership", "2026-03-31", key: @platform)["allocation"]

      assert_equal [ @payments ], allocations_as_of("2026-03-30").keys
      assert_equal [ @platform ], allocations_as_of("2026-03-31").keys
      assert_equal [ @platform ], live_allocations.keys

      moved = changes("2026-03-30", "2026-03-31").changes.sole
      assert_equal [ :moved, on("2026-03-31"), @payments, @platform ],
                   [ moved.kind, moved.effective_on, moved.from_unit_id, moved.unit_id ]
    end
  end
end
