require "json"
require "serialport"

def validate_historic(sub_group)
  data = sub_group[0..-3]
  cksum = sub_group[-1]

  (data.bytes.sum & 0x3f) + 0x20 == cksum.bytes[0]
end

def validate_standard(sub_group)
  data = sub_group[0..-2]
  cksum = sub_group[-1]

  (data.bytes.sum & 0x3f) + 0x20 == cksum.bytes[0]
end

def parse_trame(trame)
  infos = {}
  trame.split("\n").each do |g|
    g.chomp!
    if g.empty? || !(validate_historic(g) || validate_standard(g))
      next
    end
    match = g.match('\A([^\t ]*)[\t ](.*)[\t ].\z')
    if match
      infos[match[1]] = match[2]
    end
  end

  infos
end

def read_buf(buffer, io)
  read = io.read(64)
  if read
    buffer << read
  end
end

def read_trame(io)
  start_trame = nil
  end_trame = nil
  buffer = ""
  while !start_trame do
    buffer = ""
    read_buf(buffer, io)
    start_trame = buffer.index("\x02")
  end
  buffer = buffer[(start_trame + 1)..-1]
  while !end_trame || buffer.length > 10240 do
    read_buf(buffer, io)
    end_trame = buffer.index("\x03")
  end

  if end_trame
    buffer[0..(end_trame - 1)]
  end
end

def read_meter_info(file, baud, cont = true, &block) # never returns
  system("stty raw #{baud} -parodd -cstopb cs7 < #{file}")
  loop do
    trame = nil
    SerialPort.open(file) do |io|
      trame = read_trame(io)
    end
    if trame
      infos = parse_trame(trame)
      if !infos.empty?
        yield infos
        if !cont
          return
        end
      end
    end
  end
end

def sum_indexes(meter_info)
  [
    %w(EAST),
    %w(BASE),
    %w(HCHC HCHP),
    %w(BBRHCJB BBRHPJB BBRHCJW BBRHPJW BBRHCJR BBRHPJR),
  ].each do |index_names|
    indexes = index_names.map { |key| meter_info[key] }.compact
    if !indexes.empty?
      return indexes.map(&:to_i).sum
    end
  end
end

def setup_database(meters_database)
  db = SQLite3::Database.new(meters_database)

  db.execute('CREATE TABLE IF NOT EXISTS index_reports (id INTEGER PRIMARY KEY AUTOINCREMENT, meter_id INTEGER NOT NULL, created_at TEXT NOT NULL, indexes TEXT NOT NULL);')
  db.execute('CREATE TABLE IF NOT EXISTS incidents(id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, incident TEXT NOT NULL);')

  db
end

def get_indexes(db, meter_id)
  id, indexes = db.execute('SELECT id, indexes FROM index_reports WHERE meter_id = ? ORDER BY id DESC LIMIT 1;', [meter_id]).first
  
  [id, JSON.parse(indexes || '{}')]
end

def save_indexes(db, meter_id, indexes)
  db.execute('INSERT INTO index_reports (meter_id, created_at, indexes) VALUES (?, datetime(), ?);', [meter_id, JSON.generate(indexes)])
end

def record_incident(db, text)
  db.execute('INSERT INTO incidents (created_at, incident) VALUES (datetime(), ?);', [text])
  puts text + "\n"
end

def adjust_index(split, index_name, value)
  split[index_name] ||= 0
  split[index_name] += value
end

def write_report(report_file, meter_id, meter_split)
  File.open(report_file, 'wb') do |f|
    f.write("Report for meter_id #{meter_id}\n")
    f.write("Date: #{Time.now}\n")
    f.write("\n")
    f.write(
      meter_split.map do |index, consumption|
        "#{index}\t#{(consumption.to_f / 1000)} kWh"
      end.join("\n")
    )
    f.write("\n")
  end
end

INDEXES = {
  "01" => "HC BLEU",
  "02" => "HP BLEU",
  "03" => "HC BLANC",
  "04" => "HP BLANC",
  "05" => "HC ROUGE",
  "06" => "HP ROUGE",
  "07" => "index 7",
  "08" => "index 8",
  "09" => "index 9",
  "10" => "index 10"
}
UNKNOWN_INDEX = "unknown"

read_meter_info(ARGV[0], ARGV[1], false) do |infos|
  puts JSON.pretty_generate(infos)
end
