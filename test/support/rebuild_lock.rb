# frozen_string_literal: true

# Puts projections in the state a rebuild leaves them in while it runs: their
# lock held by another database session, as the rake task holds it, and their
# tables reset for the tenant. Transactional tests share one connection, so
# the lock needs a PG connection of its own; closing it releases the lock.
module RebuildLock
  # @param tenant [Tenant]
  # @param projections [Array<Class>] projection classes
  # @yield while the rebuild holds their locks
  def while_rebuilding(tenant, *projections)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    rebuild = PG.connect({ dbname: config[:database], user: config[:username], password: config[:password],
                           host: config[:host], port: config[:port] }.compact)
    rebuild.exec("SET lock_timeout = '10s'") # a write that never lets go fails the test, not hangs it
    projections.each do |projection|
      rebuild.exec("SELECT pg_advisory_lock(#{ProjectionVersion.lock_key(projection::PROJECTION_NAME)})")
      ActsAsTenant.with_tenant(tenant) { projection.reset!(tenant:) }
    end
    yield
  ensure
    rebuild&.close
  end

  # Finishes the rebuild: replays each projection for the tenant.
  #
  # @param tenant [Tenant]
  # @param projections [Array<Class>]
  def replay(tenant, *projections)
    ActsAsTenant.with_tenant(tenant) do
      projections.each { Projections::Replayer.replay(projection_class: it, tenant:) }
    end
  end
end
