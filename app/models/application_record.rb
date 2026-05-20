class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_create :assign_uuid_v7_id

  private

  # Assigns a UUID v7 to the primary key when the table has a uuid `id` column
  # and no id was supplied. v7 IDs are time-ordered, giving append-mostly
  # B-tree index inserts and better cache locality than v4. We do this in Ruby
  # because Render-managed Postgres 16 has neither the built-in `uuidv7()`
  # (PG 17) nor the `pg_uuidv7` extension available.
  def assign_uuid_v7_id
    return unless self.class.primary_key == "id"
    return if self[:id].present?

    column = self.class.columns_hash["id"]
    return unless column&.sql_type == "uuid"

    self.id = SecureRandom.uuid_v7
  end
end
