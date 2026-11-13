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

    should "hold the stream's lock while it loads and stores" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        before = advisory_locks
        held = nil
        OrgGraph::Repository.new.with_person(SecureRandom.uuid_v7) { held = advisory_locks }
        assert_operator held, :>, before
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

    should "hold the stream's lock while it loads and stores" do
      ActsAsTenant.with_tenant(create(:tenant)) do
        before = advisory_locks
        held = nil
        OrgGraph::Repository.new.with_structure { held = advisory_locks }
        assert_operator held, :>, before
      end
    end
  end

  def advisory_locks
    ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()
    SQL
  end
end
