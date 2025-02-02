require "pg_partition_manager/version"
require "date"
require "pg"
require "ulid"

module PgPartitionManager
  class Error < StandardError; end

  class Time
    def initialize(partition, start: Date.today, db: nil)
      raise ArgumentError, "Period must be 'month', 'week', or 'day'" unless ["month", "week", "day"].include?(partition[:period])

      @partition = partition
      @start =
        case partition[:period]
         when "month"
           start - start.day + 1 # First day of the current month
         when "week"
           start - (start.cwday - 1) # First calendar day of the current week
         when "day"
           start
        end
      @db = db || PG.connect(ENV["DATABASE_URL"])
    end

    # Drop the tables that contain data that should be expired based on the
    # retention period
    def drop_tables
      schema, table = @partition[:parent_table].split(".")
      table_suffix = retention.to_s.tr("-", "_")

      result = @db.exec("select nspname, relname from pg_class c inner join pg_namespace n on n.oid = c.relnamespace where nspname = '#{schema}' and relname like '#{table}_p%' and relkind = 'r' and relname < '#{table}_p#{table_suffix}' order by 1, 2")
      result.map do |row|
        child_table = "#{row["nspname"]}.#{row["relname"]}"
        @db.exec("drop table if exists #{child_table}")
        child_table
      end
    end

    # Create tables to hold future data
    def create_tables
      schema, table = @partition[:parent_table].split(".")
      start = @start
      stop = period_end(start)

      # Note that this starts in the *current* period, so we start at 0 rather
      # than 1 for the range, to be sure the current period gets a table *and*
      # we make the number of desired future tables
      (0..(@partition[:premake] || 4)).map do |month|
        child_table = "#{schema}.#{table}_p#{start.to_s.tr("-", "_")}"

        if @partition[:ulid] == true
          # ULID is lexographic https://github.com/rafaelsales/ulid
          # First 10 chars are timestamp, next 16 are random. Alphabet starts with 0 and ends with Z
          pg_start = ULID.generate(start.to_time).first(10) + ("0" * 16) # pin to start
          pg_stop = ULID.generate(stop.to_time - 1).first(10) + ("Z" * 16) # pin to end
        else
          pg_start = start
          pg_stop = stop
        end
        @db.exec("create table if not exists #{child_table} partition of #{schema}.#{table} for values from ('#{pg_start}') to ('#{pg_stop}')")
        start = stop
        stop = period_end(start)
        child_table
      end
    end

    # Return the date for the oldest table to keep, based on the retention setting
    def retention
      case @partition[:period]
      when "month"
        @start << @partition[:retain] || 6 # Default to 6 months
      when "week"
        @start - ((@partition[:retain] || 4) * 7) # Default to 4 weeks
      when "day"
        @start - (@partition[:retain] || 7) # Default to 7 days
      end
    end

    # Return the begin and end dates for the next partition range
    def period_end(start)
      case @partition[:period]
      when "month"
        start >> 1
      when "week"
        start + 7
      when "day"
        start + 1
      end
    end

    # A convenience method for doing all the maintenance for a list of partitions.
    # opts are passed directly to the initialize method.
    def self.process(partitions, **opts)
      partitions.each do |part|
        pm = new(part, **opts)
        pm.drop_tables
        pm.create_tables
      end
    end
  end
end
