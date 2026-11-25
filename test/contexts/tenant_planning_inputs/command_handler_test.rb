# frozen_string_literal: true

require "test_helper"

class TenantPlanningInputs::CommandHandlerTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @person = create(:person, tenant: @tenant)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  def events = Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_planning_inputs_stream(tenant: @tenant)).to_a

  def band(location: nil, **attrs)
    PayBand.new(location:, currency: "AUD", period: "year", minimum: 1, midpoint: 2, maximum: 3, **attrs).tap { it.match_on }
  end

  context "a write" do
    should "name the person who made it, and carry the row as the table holds it" do
      saved = save_planning_input!(:pay_bands, band(location: "Fixtureland"), changed_by_id: @person.id)

      event = events.sole
      assert_instance_of TenantPlanningInputs::Events::PayBandAdded, event
      assert_equal [ saved.id, @person.id, false ], event.data.values_at(:id, :changed_by_id, :already_held)
      assert_equal TenantPlanningInputs::Rows.dump(:pay_bands, saved), event.data[:row].deep_stringify_keys
      assert_equal [ saved.id ], event.data[:order]
    end

    should "refuse a row that fails its model's validations, and write nothing" do
      assert_raises(ActiveRecord::RecordInvalid) { save_planning_input!(:pay_bands, band(minimum: 9)) }

      assert_empty events
      assert_equal 0, PayBand.count
    end

    should "refuse a change to a row removed after it was loaded" do
      saved = save_planning_input!(:pay_bands, band)
      stale = PayBand.find(saved.id)
      remove_planning_inputs!(saved)

      error = assert_raises(TenantPlanningInputs::Refused) { save_planning_input!(:pay_bands, stale.tap { it.midpoint = 2.5 }) }

      assert_equal "There is no such pay band", error.message
      assert_equal 0, PayBand.count
    end

    should "refuse to remove a row the tenant doesn't hold" do
      error = assert_raises(TenantPlanningInputs::Refused) do
        TenantPlanningInputs::CommandHandler.new.remove(:exchange_rates, SecureRandom.uuid_v7, changed_by_id: nil)
      end

      assert_equal "There is no such exchange rate", error.message
    end

    should "keep a band's place when it changes" do
      wide = save_planning_input!(:pay_bands, band)
      narrow = save_planning_input!(:pay_bands, band(location: "Fixtureland"))
      reorder_pay_bands!([ narrow.id, wide.id ])

      save_planning_input!(:pay_bands, PayBand.find(narrow.id).tap { it.midpoint = 2.5 })

      assert_equal [ narrow.id, wide.id ], PayBand.order(:position).pluck(:id)
    end

    should "remember the currency a new reference currency replaces" do
      add_planning_input!(:reference_currencies, currency: "AUD")
      save_planning_input!(:reference_currencies, ReferenceCurrency.current.tap { it.currency = "NZD" })

      assert_equal [ nil, "AUD" ], events.map { it.data[:previous_currency] }
      assert_equal "NZD", ReferenceCurrency.current.currency
    end

    should "keep one default per rule" do
      add_planning_input!(:planning_rule_defaults, rule: "test_headcount_cap", value: { cap: 4 })

      assert_raises(ArgumentError) { add_planning_input!(:planning_rule_defaults, rule: "test_headcount_cap", value: { cap: 5 }) }
    end
  end
end
