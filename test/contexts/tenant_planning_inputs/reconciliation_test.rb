# frozen_string_literal: true

require "test_helper"

class TenantPlanningInputs::ReconciliationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def reconcile = TenantPlanningInputs::Reconciliation.new(@tenant).call

  def events = Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_planning_inputs_stream(tenant: @tenant)).to_a

  def everything
    TenantPlanningInputs::Rows::TABLES.each_key.to_h do |table|
      [ table, TenantPlanningInputs::Rows.model(table).where(tenant_id: @tenant.id).order(:id).map(&:attributes) ]
    end
  end

  # Writes as the previous release does: straight to the table.
  def held_band(location, position:)
    PayBand.create!(location:, position:, currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3,
                    role_name: "Every role", level_name: "Every level")
  end

  context "rows the previous release wrote" do
    setup do
      @first = held_band("Fixtureland", position: 1)
      @second = held_band("Elsewhere", position: 2)
      @currency = ReferenceCurrency.create!(currency: "AUD")
      @report = reconcile
    end

    should "be recorded as already held, with their own ids, positions and no actor" do
      assert_equal [ 3, 0, 0 ], @report.to_h.values_at(:added, :removed, :changed)
      assert events.all? { it.data[:already_held] && it.data[:changed_by_id].nil? }
      assert_equal [ @first.id, @second.id ], TenantPlanningInputs::Repository.new.reading_locked(&:band_order)
    end

    should "leave a second run nothing to write" do
      count = events.size

      assert_equal [ 0, 0, 0 ], reconcile.to_h.values_at(:added, :removed, :changed)
      assert_equal count, events.size
    end

    should "leave the tables as a rebuild from the stream writes them" do
      before = everything

      TenantPlanningInputs::Projections::Tables.reset!(tenant: @tenant)

      assert_equal before, everything
    end

    should "record a row an earlier release changed in place, naming the person who changed it" do
      editor = create(:person, tenant: @tenant)
      PayBand.where(id: @first.id).update_all(midpoint: 2.5, updated_at: 1.minute.from_now, updated_by_person_id: editor.id)

      assert_equal [ 0, 0, 1 ], reconcile.to_h.values_at(:added, :removed, :changed)
      change = events.last
      assert_instance_of TenantPlanningInputs::Events::PayBandChanged, change
      assert_equal [ @first.id, nil, editor.id ], change.data.values_at(:id, :changed_by_id, :last_changed_by_id)
    end

    should "record a row the table no longer holds as removed" do
      PayBand.where(id: @second.id).delete_all

      assert_equal [ 0, 1, 0 ], reconcile.to_h.values_at(:added, :removed, :changed)
      assert_instance_of TenantPlanningInputs::Events::PayBandRemoved, events.last
      assert_equal [ @first.id ], TenantPlanningInputs::Repository.new.reading_locked(&:band_order)
    end
  end

  context "a row recorded before a column was added" do
    setup do
      rows = TenantPlanningInputs::Rows
      old = held_band("", position: 1)
      new = held_band("Fixtureland", position: 2)
      TenantPlanningInputs::Repository.new.with_aggregate do |inputs|
        { old => %w[location location_key], new => [] }.each do |band, unknown|
          inputs.record_held(:pay_bands, id: band.id, row: rows.dump(:pay_bands, band).except(*unknown),
                                         created_at: rows.time(band.created_at), updated_at: rows.time(band.updated_at),
                                         last_changed_by_id: nil)
        end
      end
    end

    should "rebuild beside rows that name the column, reading it as the column's default" do
      before = everything

      TenantPlanningInputs::Projections::Tables.reset!(tenant: @tenant)

      assert_equal before, everything
    end

    should "leave reconcile nothing to record" do
      assert_equal [ 0, 0, 0 ], reconcile.to_h.values_at(:added, :removed, :changed)
    end

    should "let a band be added after it, placed by a matcher that reads the column's default" do
      remove_planning_inputs!(PayBand.find_by!(location: "Fixtureland"))

      assert_difference -> { PayBand.where(tenant_id: @tenant.id).count }, 1 do
        add_pay_band!(location: "Elsewhere", currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3,
                      role_name: "Every role", level_name: "Every level")
      end
    end
  end

  should "leave another tenant's stream alone" do
    other = create(:tenant)
    ActsAsTenant.with_tenant(other) { ReferenceCurrency.create!(currency: "NZD") }

    held_band("Fixtureland", position: 1)
    reconcile

    assert_empty Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_planning_inputs_stream(tenant: other)).to_a
  end
end
