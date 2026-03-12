begin
  namespace :development do
    desc "run erblint"
    task erblint: [] do
      status = system("bundle exec erb_lint --lint-all", exception: true)
      raise "erblint checks failed" unless status
    end

    desc "run rubocop"
    task rubocop: [] do
      status = system("bin/rubocop", exception: true)
      raise "rubocop checks failed" unless status
    end

    desc "run brakeman"
    task brakeman: [] do
      status = system("bin/brakeman --no-pager", exception: true)
      raise "brakeman security checks failed" unless status
    end

    desc "run bundler audit"
    task bundler_audit: [] do
      status = system("bundle audit", exception: true)
      raise "bundler audit checks failed" unless status
    end

    desc "run importmap audit"
    task importmap_audit: [] do
      status = system("bin/importmap audit", exception: true)
      raise "importmap audit checks failed" unless status
    end

    desc "watch tests"
    task watch_tests: [] do
      system("find ./test -name '*.rb' | entr -s 'rails test'", exception: false)
    end

    desc "Validation before commit."
    task precommit: [ :erblint, :rubocop, :brakeman, :bundler_audit, :importmap_audit, "db:test:prepare", "zeitwerk:check", :test, "test:system" ]
  end
rescue LoadError => e
  Rails.error.handle(e) do |error|
    error.message = "Not in development environment so skipping definition of development rake tasks: #{e.message}"
  end
end
