# frozen_string_literal: true

require "test_helper"

class OrgGraphDrawerTest < ActiveSupport::TestCase
  class Host
    include OrgGraphDrawer

    attr_reader :params, :redirects

    def initialize(params = {})
      @params = ActionController::Parameters.new(params)
      @redirects = []
    end

    def redirect_to(path, **options) = @redirects << [ path, options ]

    def drawer_path = "/drawer?on=#{drawer_on}"
  end

  def host(params = {}) = Host.new(params)

  context "#write" do
    should "come back to the drawer with the notice" do
      drawer = host
      drawer.send(:write, notice: "Saved.") { nil }

      assert_equal [ [ "/drawer?on=", { status: :found, notice: "Saved." } ] ], drawer.redirects
    end

    should "come back with a refusal's reason, naming the provider by its label" do
      drawer = host
      drawer.send(:write, notice: "Saved.", status: :see_other) { raise "hibob supplies this unit" }

      assert_equal [ [ "/drawer?on=", { status: :see_other, flash: { drawer_alert: "HiBob supplies this unit" } } ] ], drawer.redirects
    end

    should "let an error it doesn't expect through" do
      assert_raises(ArgumentError) { host.send(:write, notice: "Saved.") { raise ArgumentError } }
    end
  end

  context "the effective date" do
    should "carry a chosen day into the operation and the drawer path" do
      drawer = host(effective_on: "2026-01-05")

      assert_equal({ unit_id: "u", effective_on: "2026-01-05" }, drawer.send(:with_date, unit_id: "u"))
      assert_equal "/drawer?on=2026-01-05", drawer.send(:drawer_path)
    end

    should "leave today out of the drawer path, and nothing chosen out of both" do
      assert_equal "/drawer?on=", host(effective_on: Date.current.iso8601).send(:drawer_path)
      assert_equal({ unit_id: "u" }, host.send(:with_date, unit_id: "u"))
    end
  end

  context "#allocation" do
    should "turn a percentage into a fraction" do
      assert_in_delta 0.4, host(allocation: "40").send(:allocation)
    end

    should "be nil when none is given" do
      assert_nil host(allocation: "").send(:allocation)
    end

    should "refuse what isn't a number" do
      error = assert_raises(Operations::Base::ParameterError) { host(allocation: "half").send(:allocation) }
      assert_equal 'Allocation must be a number, got "half"', error.message
    end
  end
end
