# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/projection_replay"

class OrgGraph::Projections::LeaversTest < ActiveSupport::TestCase
  include ProjectionReplayHelpers

  ESPALIA = { provider: "espalia" }.freeze
  TODAY = Date.new(2033, 6, 1)

  setup do
    @tenant = create(:tenant)
    @handler = OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
    as_tenant do
      @ada, @grace, @linus, @hedy = create_list(:person, 4, tenant: @tenant)
      [ @ada, @grace, @linus, @hedy ].each do |person|
        @handler.record_person(person.id, **ESPALIA, effective_on: "2020-01-01", employment_status: "employed")
      end
    end
  end

  def as_tenant(&) = ActsAsTenant.with_tenant(@tenant, &)

  def leave(person, on) = as_tenant { @handler.leave(person.id, **ESPALIA, effective_on: on) }

  def due(on: TODAY) = as_tenant { OrgLeaver.due_to_be_forgotten(@tenant.reload, on:) }

  context "with the default seven years" do
    should "list a leaver once seven years have passed since they left, and nobody else" do
      leave(@ada, "2026-05-31")
      leave(@grace, "2026-06-01")
      leave(@linus, "2026-06-02")

      assert_equal [ @ada.id, @grace.id ], due
      assert_equal 2, due.size
    end

    should "not list someone who returned" do
      leave(@ada, "2024-01-01")
      as_tenant { @handler.return_to_work(@ada.id, **ESPALIA, effective_on: "2025-01-01") }

      assert_empty due
    end

    should "count from a corrected leaving date" do
      leave(@ada, "2027-01-01")
      as_tenant do
        @handler.sync_person(@ada.id, **ESPALIA, effective_on: "2027-02-01", employment_status: "left",
                                               left_on: "2026-01-01")
      end

      assert_equal [ @ada.id ], due
    end

    should "count a leaver the provider stopped returning from the day the sync noticed" do
      as_tenant { @handler.record_absence(@ada.id, **ESPALIA, effective_on: "2026-06-01") }

      assert_empty due(on: TODAY - 1)
      assert_equal [ @ada.id ], due
    end

    should "count someone first recorded as a leaver from their leaving date, or the day they were recorded" do
      as_tenant do
        kept, undated = create_list(:person, 2, tenant: @tenant)
        @handler.record_person(kept.id, **ESPALIA, effective_on: "2026-01-01", employment_status: "left",
                                                 started_on: "2020-01-01", left_on: "2025-01-01")
        @handler.record_person(undated.id, **ESPALIA, effective_on: "2027-01-01", employment_status: "left")

        assert_equal({ kept.id => Date.new(2025, 1, 1), undated.id => Date.new(2027, 1, 1) },
                     OrgLeaver.where(person_id: [ kept.id, undated.id ]).pluck(:person_id, :left_on).to_h)
      end
    end

    should "leave another tenant's leavers out" do
      other = create(:tenant)
      ActsAsTenant.with_tenant(other) do
        neighbour = create(:person, tenant: other)
        @handler.record_person(neighbour.id, **ESPALIA, effective_on: "2020-01-01", employment_status: "left",
                                                      left_on: "2020-01-01")
      end

      assert_empty due
    end
  end

  should "follow the tenant's own period" do
    leave(@ada, "2030-05-31")
    @tenant.update!(org_graph_config: { retention_years: 3 })

    assert_equal [ @ada.id ], due
  end

  should "list nobody while the tenant keeps leavers for ever" do
    leave(@ada, "2020-02-01")
    @tenant.update!(org_graph_config: { retention_years: nil })

    assert_empty due
  end

  context "rebuild contract" do
    should "reset! + replay produce identical read-model state, including the stable ids" do
      leave(@ada, "2026-01-01")
      leave(@grace, "2025-01-01")
      as_tenant { @handler.return_to_work(@grace.id, **ESPALIA, effective_on: "2025-06-01") }
      leave(@linus, "2026-03-01")
      as_tenant do
        @handler.sync_person(@linus.id, **ESPALIA, effective_on: "2026-04-01", employment_status: "left",
                                                 left_on: "2026-02-01")
      end

      before = snapshot_read_models(OrgGraph::Projections::Leavers, @tenant)
      assert_equal 2, before[:leavers].size

      OrgGraph::Projections::Leavers.reset!(tenant: @tenant)
      as_tenant { assert_equal 0, OrgLeaver.count }
      Projections::Replayer.replay(projection_class: OrgGraph::Projections::Leavers, tenant: @tenant)

      assert_equal before, snapshot_read_models(OrgGraph::Projections::Leavers, @tenant)
    end
  end
end
