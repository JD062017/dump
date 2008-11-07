require 'progress'
require 'find'
require 'archive/tar/minitar'

class DumpRake
  class GzippedTar # :nodoc:
    class Writer # :nodoc:
      def self.create(path)
        Zlib::GzipWriter.open(path) do |gzip|
          Archive::Tar::Minitar::Output.open(gzip) do |stream|
            yield(new(stream.tar))
          end
        end
      end

      def initialize(tar)
        @tar = tar
      end

      def create_file(name)
        Tempfile.open('dumper') do |temp|
          yield(temp)
          temp.open
          @tar.add_file_simple(name, :mode => 0100444, :size => temp.length) do |f|
            f.write(temp.read(4096)) until temp.eof?
          end
        end
      end
    end

    class Reader # :nodoc:
      def self.open(path)
        Zlib::GzipReader.open(path) do |gzip|
          Archive::Tar::Minitar::Input.open(gzip) do |stream|
            yield(new(stream))
          end
        end
      end

      def initialize(tar)
        @tar = tar
      end

      def read(matcher)
        result = []
        entries_like(matcher) do |entry|
          result << entry.read
        end
        result
      end

      def read_to_file(matcher)
        entries_like(matcher) do |entry|
          Tempfile.open('dumper') do |temp|
            temp.write(entry.read(4096)) until entry.eof?
            temp.rewind
            yield(temp)
          end
        end
      end

      def entries_like(matcher)
        @tar.each do |entry|
          if matcher === entry.full_name
            yield(entry)
          end
        end
      end
    end

    def self.list
      Dir.glob(File.join(RAILS_ROOT, 'db', 'dump', '*.tgz')).sort.map{ |path| new(path) }
    end

    def initialize(path)
      @path = path
    end
    
    def path
      @path
    end
    
    def name
      @name ||= File.basename(path, '.tgz')
    end
    
    def name_parts
      @name_parts ||= name.split('-', 2)
    end
    
    def =~(version)
      name_parts.any?{ |part| part.index(version) == 0 }
    end
  end

  def self.create
    ActiveRecord::Base.establish_connection

    time = Time.now.utc.strftime("%Y%m%d%H%M%S")
    path = File.join(RAILS_ROOT, 'db', 'dump')
    FileUtils.mkdir_p(path)

    comment = if ENV['COMMENT']
      ENV['COMMENT'].downcase.gsub(/[^a-z0-9]+/, ' ').lstrip[0, 30].rstrip.gsub(/ /, '-')
    end
    name = [time, comment].compact * '-'

    assets = begin
      Rake::Task['assets'].invoke
      ENV['ASSETS'].split(':')
    rescue
      []
    end

    tmp_name = File.join(path, "#{name}.tmp")
    tgz_name = File.join(path, "#{name}.tgz")

    config = {:tables => {}, :assets => assets}
    GzippedTar::Writer.create(tmp_name) do |tar|
      tar.create_file('schema.rb') do |f|
        set_env_temporary('SCHEMA', f.path) do
          Rake::Task['db:schema:dump'].invoke
        end
      end
      interesting_tables.each_with_progress('Tables') do |table|
        rows = Progress.start('Getting data') do
          ActiveRecord::Base.connection.select_all("SELECT * FROM `#{table}`")
        end
        unless rows.empty?
          Progress.start('Writing dump', rows.length) do
            tar.create_file("#{table}.dump") do |f|
              rows.each_slice(1000) do |slice|
                Marshal.dump(slice, f)
                Progress.step(slice.length)
              end
            end
          end
          config[:tables][table] = rows.length
        end
      end
      tar.create_file('assets.tar') do |f|
        Progress.start('Assets') do
          Dir.chdir(RAILS_ROOT) do
            Archive::Tar::Minitar.pack(assets, f)
          end
          Progress.step
        end
      end
      tar.create_file('config') do |f|
        Marshal.dump(config, f)
      end
    end

    FileUtils.mv(tmp_name, tgz_name)
  end

  def self.restore(version)
    dumps = GzippedTar.list
    
    dump = if version == :last
      dumps.last
    elsif version == :first
      dumps.first
    elsif (found = dumps.select{ |dump| dump =~ version }).length == 1
      found.first
    end

    if dump
      GzippedTar::Reader.open(dump.path) do |tar|
        config = Marshal.load(tar.read('config').first)
        tar.read_to_file('schema.rb') do |f|
          set_env_temporary('SCHEMA', f.path) do
            Rake::Task['db:schema:load'].invoke
          end
        end
        Progress.start('Tables', config[:tables].length) do
          tar.entries_like(/\.dump$/) do |entry|
            table = entry.full_name[/^(.*)\.dump$/, 1]
            Progress.start('Loading', config[:tables][table]) do
              until entry.eof?
                rows = Marshal.load(entry)
                rows.each do |row|
                  ActiveRecord::Base.connection.execute(
                    'INSERT INTO %s (%s) VALUES (%s)' % [
                      ActiveRecord::Base.connection.quote_table_name(table),
                      row.keys.collect{ |column| ActiveRecord::Base.connection.quote_column_name(column) } * ',',
                      row.values.collect{ |value| ActiveRecord::Base.connection.quote(value) } * ',',
                    ],
                    'Load dump'
                  )
                end
                Progress.step(rows.length)
              end
            end
            Progress.step
          end
        end
        Progress.start('Assets') do
          config[:assets].each do |asset|
            Dir.glob(File.join(RAILS_ROOT, asset, '*')) do |path|
              FileUtils.remove_entry_secure(path)
            end
          end
          tar.read_to_file('assets.tar') do |f|
            Archive::Tar::Minitar.unpack(f, RAILS_ROOT)
          end
          Progress.step
        end
      end
    else
      if dumps.length > 0
        puts "Avaliable versions:"
        dumps.map(&:name).each do |name|
          puts "  #{name}"
        end
      else
        puts "No dumps avaliable"
      end
    end
  end

protected

  def self.interesting_tables
    ActiveRecord::Base.connection.tables - %w(schema_info schema_migrations sessions public_exceptions)
  end

  def self.set_env_temporary(key, value)
    old_value = ENV[key]
    ENV[key] = value
    result = yield
    ENV[key] = old_value
    result
  end
end