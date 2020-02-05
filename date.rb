def parse_date(time_signed_field)
  teleinfo_date = time_signed_field.split("\t")[0]
  zone = teleinfo_date[0]
  date = teleinfo_date[1..-1]
  zone =
    case zone
    when 'H', 'h'
      '+0100'
    when 'E', 'e'
      '+0200'
    end

  if zone
    begin
      Time.strptime("20#{date}#{zone}", '%Y%m%d%H%M%S%z')
    rescue
      nil
    end
  end
end

time = "H200205193643\t"
parse_date(time)
