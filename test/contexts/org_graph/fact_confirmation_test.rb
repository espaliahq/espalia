# frozen_string_literal: true

require "test_helper"

class OrgGraph::FactConfirmationTest < ActiveSupport::TestCase
  ESPALIA = { provider: "espalia", effective_on: "2026-11-01" }.freeze
  HIBOB = { provider: "hibob", effective_on: "2026-11-01" }.freeze

  setup do
    @aggregate = OrgGraph::PersonAggregate.new
    @person_id = SecureRandom.uuid_v7
    @confirmer_id = SecureRandom.uuid_v7
    @unit_id = SecureRandom.uuid_v7
    @aggregate.record(@person_id, **HIBOB, employment_status: "employed", title: "Engineer")
  end

  def confirm(fact, **options)
    @aggregate.confirm_fact(fact, confirmed_by_id: @confirmer_id, effective_on: "2026-11-10", **options)
  end

  def confirmations
    @aggregate.unpublished_events.grep(OrgGraph::Events::FactConfirmed)
  end

  should "confirm a membership Espalia holds, naming the unit and who confirmed it, and no value" do
    @aggregate.set_membership(@unit_id, **ESPALIA, allocation: 0.5, role: "Tech lead")
    confirm(:membership, unit_id: @unit_id.upcase)

    data = confirmations.sole.data
    assert_equal({ person_id: @person_id, provider: "espalia", effective_on: "2026-11-10", fact: "membership",
                   unit_id: @unit_id, confirmed_by_id: @confirmer_id }, data)
  end

  should "confirm a person fact Espalia holds" do
    @aggregate.change_manager(SecureRandom.uuid_v7, **ESPALIA)
    confirm(:manager_id)

    assert_equal [ "manager_id", nil ], confirmations.sole.data.values_at(:fact, :unit_id)
  end

  should "refuse a fact another provider holds, and write nothing" do
    @aggregate.set_membership(@unit_id, **HIBOB)

    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:title) }
    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:membership, unit_id: @unit_id) }
    assert_empty confirmations
  end

  should "refuse a fact the person doesn't have" do
    @aggregate.change_title(nil, **ESPALIA)

    assert_raises(RuntimeError, match: /Espalia holds/) { confirm(:title) }
    assert_raises(RuntimeError, match: /Not a member/) { confirm(:membership, unit_id: @unit_id) }
  end

  should "refuse an unknown fact, a membership with no unit, and a unit on another fact" do
    assert_raises(RuntimeError, match: /Unknown fact/) { confirm(:email) }
    assert_raises(RuntimeError, match: /UUID/) { confirm(:membership) }
    assert_raises(RuntimeError, match: /names a unit/) { confirm(:title, unit_id: @unit_id) }
  end

  should "refuse without a confirmer, for a leaver, and before the person is recorded" do
    @aggregate.change_title("Lead", **ESPALIA)
    assert_raises(RuntimeError, match: /Confirmed by/) do
      @aggregate.confirm_fact(:title, confirmed_by_id: nil, effective_on: "2026-11-10")
    end

    @aggregate.leave(**HIBOB)
    assert_raises(RuntimeError, match: /has left/) { confirm(:title) }

    assert_raises(RuntimeError) do
      OrgGraph::PersonAggregate.new.confirm_fact(:title, confirmed_by_id: @confirmer_id, effective_on: "2026-11-10")
    end
  end

  should "leave the facts as they were" do
    @aggregate.change_title("Lead", **ESPALIA)
    confirm(:title)

    @aggregate.change_title("Lead", **ESPALIA)
    assert_equal 1, @aggregate.unpublished_events.grep(OrgGraph::Events::TitleChanged).size
  end

  should "write the confirmation to the person's stream through the command handler" do
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) do
      handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      handler.record_person(@person_id, **ESPALIA, employment_status: "employed", title: "Engineer")
      handler.confirm_fact(@person_id, "title", confirmed_by_id: @confirmer_id, effective_on: "2026-11-10")
    end

    event = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(@person_id, tenant: tenant)).last
    assert_instance_of OrgGraph::Events::FactConfirmed, event
    assert_equal tenant.id, event.metadata[:tenant_id]
  end

  should "confirm as the actor, under the same rights as changing the fact" do
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) do
      level, unit = SecureRandom.uuid_v7, SecureRandom.uuid_v7
      system = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: level, name: "Team" } ], effective_on: "2026-01-01")
      structure.create_unit(unit, "Payments", level_id: level, effective_on: "2026-01-01")
      lead = create(:person, tenant: tenant)
      report = create(:person, tenant: tenant, manager: lead)
      system.record_person(report.id, **ESPALIA, employment_status: "employed", title: "Engineer")
      system.set_membership(report.id, unit, **ESPALIA)

      as = ->(person) { OrgGraph::CommandHandler.new(actor: actor_for(tenant, person)) }
      as.(lead).confirm_fact(report.id, :membership, unit_id: unit, effective_on: "2026-11-10")
      assert_raises(OrgGraph::Authorization::Refused) { as.(lead).confirm_fact(report.id, :title, effective_on: "2026-11-10") }
      outsider = create(:person, tenant: tenant)
      assert_raises(OrgGraph::Authorization::Refused) do
        as.(outsider).confirm_fact(report.id, :membership, unit_id: unit, effective_on: "2026-11-10")
      end

      confirmed = Rails.configuration.event_store.read.stream(EventStreamNaming.person_stream(report.id)).to_a
        .grep(OrgGraph::Events::FactConfirmed)
      assert_equal [ lead.id ], confirmed.map { |event| event.data[:confirmed_by_id] }
    end
  end

  def actor_for(tenant, person)
    user = create(:user)
    AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant:, user:, person:), person:)
  end
end
