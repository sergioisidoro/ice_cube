module IceCube
  class IcalBuilder
    ICAL_DAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    def initialize
      @hash = {}
    end

    def self.fixnum_to_ical_day(num)
      ICAL_DAYS[num]
    end

    def [](key)
      @hash[key] ||= []
    end

    # Build for a single rule entry
    def to_s
      arr = []
      if (freq = @hash.delete("FREQ"))
        arr << "FREQ=#{freq.join(",")}"
      end
      arr.concat(@hash.map do |key, value|
        if value.is_a?(Array)
          "#{key}=#{value.join(",")}"
        end
      end.compact)
      arr.join(";")
    end

    def self.ical_utc_format(time)
      time = time.dup.utc
      IceCube::I18n.l(time, format: "%Y%m%dT%H%M%SZ") # utc time
    end

    def self.ical_format(time, force_utc)
      time = time.dup.utc if force_utc

      # Keep timezone. strftime will serializer short versions of time zone (eg. EEST),
      # which are not reversivible, as there are many repeated abbreviated zones. This will result in
      # issues in parsing
      if time.respond_to?(:time_zone)
        tz_id = time.time_zone.name
        return ";TZID=#{tz_id}:#{IceCube::I18n.l(time, format: "%Y%m%dT%H%M%S")}" # local time specified"
      end

      if time.utc?
        ":#{IceCube::I18n.l(time, format: "%Y%m%dT%H%M%SZ")}" # utc time
      else
        # Convert to UTC as TZID=+xxxx format is not recognized by JS libraries
        warn "IceCube: Time object does not have timezone info. Assuming UTC: #{caller(1..1).first}"
        utc_time = time.dup.utc
        ":#{IceCube::I18n.l(utc_time, format: "%Y%m%dT%H%M%SZ")}" # converted to utc time
      end
    end

    def self.ical_duration(duration)
      hours = duration / 3600
      duration %= 3600
      minutes = duration / 60
      duration %= 60
      repr = ""
      repr << "#{hours}H" if hours > 0
      repr << "#{minutes}M" if minutes > 0
      repr << "#{duration}S" if duration > 0
      "PT#{repr}"
    end
  end
end
