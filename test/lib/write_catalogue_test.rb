# frozen_string_literal: true

require "test_helper"

class WriteCatalogueTest < ActiveSupport::TestCase
  def set_columns(sql) = WriteCatalogue.send(:columns, "update", sql)

  should "read every top-level SET column, past a subquery's WHERE" do
    sql = 'UPDATE "people" SET "name" = (SELECT name FROM x WHERE id = 1), "manager_id" = 2 WHERE "people"."id" = 3'

    assert_equal %w[manager_id name], set_columns(sql)
  end

  should "not let a literal parenthesis or WHERE hide a later column" do
    assert_equal %w[manager_id name], set_columns(%q{UPDATE people SET name = '(', manager_id = 42 WHERE id = 1})
    assert_equal %w[manager_id name], set_columns(%q(UPDATE people SET name = 'x WHERE y', manager_id = 42))
    assert_equal %w[manager_id name], set_columns(%q{UPDATE people SET name = 'it''s (', manager_id = 42})
  end

  should "read a quoted column name that holds an escaped quote" do
    assert_equal [ 'a"b' ], set_columns('UPDATE t SET "a""b" = 1')
  end

  should "record the columns an upsert updates on conflict, not every column it inserts" do
    sql = 'INSERT INTO "people" ("id","manager_id","name") VALUES ($1, $2, $3) ON CONFLICT ("id") DO UPDATE SET ' \
          'updated_at=(CASE WHEN ("people"."name" IS NOT DISTINCT FROM excluded."name") THEN "people".updated_at ' \
          'ELSE CURRENT_TIMESTAMP END),"name"=excluded."name" RETURNING "id"'

    assert_equal %w[name updated_at], WriteCatalogue.send(:conflict_updates, "upsert", sql)
    assert_empty WriteCatalogue.send(:conflict_updates, "insert", 'INSERT INTO "people" ("id") VALUES ($1)')
  end
end
