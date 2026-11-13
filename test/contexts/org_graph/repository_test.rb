# frozen_string_literal: true

require "test_helper"

class OrgGraph::RepositoryTest < ActiveSupport::TestCase
  context "#with_person" do
    should "raise without a tenant context" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) do
          OrgGraph::Repository.new.with_person(SecureRandom.uuid_v7) { }
        end
      end
    end

    should "yield a person aggregate" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        OrgGraph::Repository.new.with_person(SecureRandom.uuid_v7) do |person|
          assert_kind_of OrgGraph::PersonAggregate, person
        end
      end
    end
  end
  context "#with_structure" do
    should "raise without a tenant context" do
      ActsAsTenant.without_tenant do
        assert_raises(ArgumentError) { OrgGraph::Repository.new.with_structure { } }
      end
    end

    should "yield the tenant's structure aggregate" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        OrgGraph::Repository.new.with_structure do |structure|
          assert_kind_of OrgGraph::StructureAggregate, structure
        end
      end
    end
  end
end
