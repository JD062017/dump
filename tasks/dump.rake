desc 'Short for dump:create'
task :dump => 'dump:create'

namespace :dump do
  desc 'Show avaliable versions, use version as for restore to show only matching dumps'
  task :versions => :environment do
    DumpRake.versions(:like => ENV['VER'] || ENV['VERSION'] || ENV['LIKE'])
  end

  desc 'Create dump DESC[RIPTION]="meaningfull description"'
  task :create => :environment do
    DumpRake.create(:description => ENV['DESC'] || ENV['DESCRIPTION'])
  end

  desc "Restore dump, use VER[SION]=uniq part of dump name to select which dump to use (last dump is the default)"
  task :restore => :environment do
    DumpRake.restore(:like => ENV['VER'] || ENV['VERSION'] || ENV['LIKE'])
  end
end
