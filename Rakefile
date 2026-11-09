require 'rake'
task :generate do
  ruby 'scripts/generate.rb'
end
task :test do
  Dir['test/test_*.rb'].sort.each { |file| ruby '-I../spnl-utils', '-I../spnl-web', file }
end
task default: :test
