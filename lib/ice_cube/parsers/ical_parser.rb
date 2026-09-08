module IceCube
  class IcalParser
    def self.schedule_from_ical(ical_string, options = {})
      data = {}
      lines = unfold_lines(ical_string)

      # DTSTART carries the zone the whole event is expressed in, so a value
      # elsewhere in the event that names no zone of its own belongs to that
      # zone rather than to the system zone. Read it up front: DTSTART is not
      # guaranteed to appear before the properties that depend on it.
      default_tzid = dtstart_tzid(lines)

      lines.each do |line|
        (name_and_params, value) = split_content_line(line)
        next if value.nil?

        (property, *params) = split_unquoted(name_and_params, ";")
        # Property and parameter names are case-insensitive (RFC 5545 section 3.1)
        property = property.strip.upcase
        tzid = tzid_from_params(params) || default_tzid

        case property
        when "DTSTART"
          data[:start_time] = TimeUtil.deserialize_time_with_zone(value, tzid)
        when "DTEND"
          data[:end_time] = TimeUtil.deserialize_time_with_zone(value, tzid)
        when "RDATE"
          data[:rtimes] ||= []
          data[:rtimes] += value.split(",").map { |v| TimeUtil.deserialize_time_with_zone(v, tzid) }
        when "EXDATE"
          data[:extimes] ||= []
          data[:extimes] += value.split(",").map { |v| TimeUtil.deserialize_time_with_zone(v, tzid) }
        when "DURATION"
          data[:duration] = ical_duration_to_seconds(value)
        when "RRULE"
          data[:rrules] ||= []
          data[:rrules] += [rule_from_ical(value, tzid)]
        end
      end
      Schedule.from_hash data
    end

    # Join lines that are wrapped (RFC 5545 section 3.1 line folding).
    def self.unfold_lines(ical_string)
      lines = []
      ical_string.each_line do |line|
        if lines[-1] && line =~ /\A[ \t].+/
          lines[-1] = lines[-1].strip + line.sub(/\A[ \t]+/, "")
        else
          lines << line
        end
      end
      lines
    end

    # The TZID of the event's DTSTART, which acts as the default zone for any
    # other value that does not name one. Returns nil when DTSTART is absent,
    # floating, or in UTC, leaving those values to be read as they always were.
    def self.dtstart_tzid(lines)
      lines.each do |line|
        (name_and_params, value) = split_content_line(line)
        next if value.nil?

        (property, *params) = split_unquoted(name_and_params, ";")
        next unless property.strip.casecmp("DTSTART").zero?

        return tzid_from_params(params)
      end
      nil
    end

    # Convert an iCalendar duration (RFC 5545 section 3.3.6) to seconds, as
    # expected by Schedule. Returns nil for a value that cannot be read, so a
    # malformed DURATION is ignored rather than silently becoming zero.
    def self.ical_duration_to_seconds(value)
      match = /\A([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/
        .match(value.to_s.strip)
      return nil if match.nil?

      sign, weeks, days, hours, minutes, seconds = match.captures
      return nil if [weeks, days, hours, minutes, seconds].all?(&:nil?)

      total = weeks.to_i * 604800 + days.to_i * 86400 +
        hours.to_i * 3600 + minutes.to_i * 60 + seconds.to_i
      (sign == "-") ? -total : total
    end

    # Split a content line into its property part (name and parameters) and its
    # value, at the first colon that is not inside a quoted parameter value.
    # Parameter values are quoted precisely so they may contain a colon
    # (RFC 5545 section 3.1), as in DTSTART;TZID="GMT+05:00":20130101T090000.
    # Returns a nil value for a line with no colon at all.
    def self.split_content_line(line)
      in_quotes = false
      line.each_char.with_index do |char, index|
        case char
        when '"' then in_quotes = !in_quotes
        when ":" then return [line[0, index], line[(index + 1)..]] unless in_quotes
        end
      end
      [line, nil]
    end

    # Split on +delimiter+, ignoring delimiters inside a quoted value.
    def self.split_unquoted(string, delimiter)
      parts = [+""]
      in_quotes = false
      string.each_char do |char|
        in_quotes = !in_quotes if char == '"'
        if char == delimiter && !in_quotes
          parts << +""
        else
          parts.last << char
        end
      end
      parts
    end

    # Find the TZID parameter among a property's parameters. TZID is not
    # necessarily the first parameter (DTSTART;VALUE=DATE-TIME;TZID=... is
    # equally valid), parameter names are case-insensitive, and the value may be
    # double-quoted (RFC 5545 sections 3.1 and 3.2.19).
    def self.tzid_from_params(params)
      param = params.find { |p| p =~ /\ATZID=/i }
      return nil unless param

      tzid = param.split("=", 2).last.to_s.strip
      tzid = tzid[1..-2] if tzid.length >= 2 && tzid.start_with?('"') && tzid.end_with?('"')
      tzid.empty? ? nil : tzid
    end

    # +default_tzid+ is the zone of the enclosing schedule's DTSTART, used to
    # read an UNTIL value that names no zone of its own.
    def self.rule_from_ical(ical, default_tzid = nil)
      raise ArgumentError, "empty ical rule" if ical.nil?

      validations = {}
      params = {validations: validations, interval: 1}

      ical.split(";").each do |rule|
        (name, value) = rule.split("=", 2)
        raise ArgumentError, "Invalid iCal rule component" if value.nil?
        value = value.strip
        # Rule part names and their keyword values are case-insensitive
        name = name.strip.upcase
        case name
        when "FREQ"
          value = value.upcase
          params[:rule_type] = "IceCube::#{value[0]}#{value.downcase[1..]}Rule"
        when "INTERVAL"
          params[:interval] = value.to_i
        when "COUNT"
          params[:count] = value.to_i
        when "UNTIL"
          params[:until] = TimeUtil.deserialize_time_with_zone(value, default_tzid).utc
        when "WKST"
          params[:week_start] = TimeUtil.ical_day_to_symbol(value.upcase)
        when "BYSECOND"
          validations[:second_of_minute] = value.split(",").map(&:to_i)
        when "BYMINUTE"
          validations[:minute_of_hour] = value.split(",").map(&:to_i)
        when "BYHOUR"
          validations[:hour_of_day] = value.split(",").map(&:to_i)
        when "BYDAY"
          dows = {}
          days = []
          value.split(",").each do |expr|
            expr = expr.strip.upcase
            day = TimeUtil.ical_day_to_symbol(expr[-2..])
            if expr.length > 2 # day with occurence
              occ = expr[0..-3].to_i
              dows[day].nil? ? dows[day] = [occ] : dows[day].push(occ)
              days.delete(TimeUtil.sym_to_wday(day))
            elsif dows[day].nil?
              days.push TimeUtil.sym_to_wday(day)
            end
          end
          validations[:day_of_week] = dows unless dows.empty?
          validations[:day] = days unless days.empty?
        when "BYMONTHDAY"
          validations[:day_of_month] = value.split(",").map(&:to_i)
        when "BYMONTH"
          validations[:month_of_year] = value.split(",").map(&:to_i)
        when "BYYEARDAY"
          validations[:day_of_year] = value.split(",").map(&:to_i)
        when "BYSETPOS"
          validations[:by_set_pos] = value.split(",").map(&:to_i)
        else
          validations[name] = nil # invalid type
        end
      end

      Rule.from_hash(params)
    end
  end
end
