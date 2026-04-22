# frozen_string_literal: true

# Override Rails' default tmp:screenshots:clear to recursively remove
# subdirectories. AutoScreenshots organises captures into per-test-class
# directories (tmp/screenshots/FooTest/...), which the stock task's `rm`
# (non-recursive) cannot delete — it raises Errno::EISDIR and aborts
# `bin/rails tmp:clear` at container start.
Rake::Task["tmp:screenshots:clear"].clear if Rake::Task.task_defined?("tmp:screenshots:clear")

namespace :tmp do
  namespace :screenshots do
    task :clear do
      rm_rf Dir["tmp/screenshots/[^.]*"], verbose: false
    end
  end
end
