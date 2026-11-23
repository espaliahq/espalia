# frozen_string_literal: true

require "test_helper"

class Projections::ReconcilersTest < ActiveSupport::TestCase
  should "name a reconciler of a tenant stream for every entry" do
    Projections::Reconcilers.names.each do |name|
      assert_operator Projections::Reconcilers.fetch(name), :<, TenantStreams::Reconciliation, name
    end
  end

  should "adopt only registered projections" do
    adopted = Projections::Reconcilers::LIST.values.flat_map { it[:adopts] }

    assert_empty adopted - Projections::Registry.names
  end

  context ".adopt" do
    setup { Projections::Registry.classes.each { ProjectionVersion.stamp!(it) } }

    should "stamp an adopted projection that has no stamp" do
      ProjectionVersion.where(name: "account_grants/account_flags").delete_all

      assert_equal %w[account_grants/account_flags], Projections::Reconcilers.adopt
      assert ProjectionVersion.exists?(name: "account_grants/account_flags")
    end

    should "stamp nothing when every adopted projection has a stamp" do
      assert_empty Projections::Reconcilers.adopt
    end
  end
end
