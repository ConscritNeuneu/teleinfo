require "json"
require "serialport"
require "thread"
require "sqlite3"
require "time"

STANDARD_BAUD = 9600
HISTORIC_BAUD = 1200

GENERAL_METER = "/dev/ttyS0"
SPECIAL_METER = "/dev/ttyAMA1"
SPECIAL_METER_ID = 1
METER_DATABASE = "/home/quentin/index_reports.sqlite3"
REPORT_FILE = '/run/meter_report.txt'
REPORT_PATRICE = '/run/report_patrice.csv'

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

def parse_date(time_signed_field)
  begin
    teleinfo_date = time_signed_field.split("\t")[0]
    zone = teleinfo_date[0]
    date = teleinfo_date[1..-1]
    zone =
      case zone
      when 'H', 'h'
        '+0100'
      when 'E', 'e'
        '+0200'
      when ' '
        '+0000'
      end

    if zone
      Time.strptime("20#{date}#{zone}", '%Y%m%d%H%M%S%z')
    end
  rescue
    nil
  end
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

def read_meter_info(file, baud, &block) # never returns
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
      end
    end
  end
end

def sum_indexes(meter_info)
  [
    %w(EAST),
    %w(BASE),
    %w(HCHC HCHP),
    %w(EJPHN EJPHPM),
    %w(BBRHCJB BBRHPJB BBRHCJW BBRHPJW BBRHCJR BBRHPJR),
  ].each do |index_names|
    indexes = index_names.map { |key| meter_info[key] }.compact
    if !indexes.empty? && indexes.count == index_names.count
      return indexes.map(&:to_i).sum
    end
  end

  nil
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

REPORT_INDEXES = [
  ["index_1", "HC BLEU "],
  ["index_2", "HP BLEU "],
  ["index_3", "HC BLANC"],
  ["index_4", "HP BLANC"],
  ["index_5", "HC ROUGE"],
  ["index_6", "HP ROUGE"],
  ["unknown", "INCONNU "]
]

def write_report(report_file, meter_id, meter_split, current_index)
  current_index_friendly_name = (REPORT_INDEXES.find { |i, name| i == current_index } || [current_index, current_index])[1]
  File.open(report_file, 'wb') do |f|
    f.write("Report for meter_id #{meter_id}\n")
    f.write("Date: #{Time.now}\n")
    f.write("\n")
    f.write("Index courant de ventilation: #{current_index_friendly_name}\n")
    f.write("\n")
    f.write(
      REPORT_INDEXES.map do |index, friendly_name|
        consumption = meter_split[index].to_f / 1000
        "#{friendly_name}\t#{consumption} kWh"
      end.join("\n")
    )
    f.write("\n")
  end
end

def report_patrice_line(time, split)
  ([time] + REPORT_INDEXES.map { |i,_| split[i].to_f / 1000 }).join(";") + "\n"
end

def write_report_patrice(report_file, lines_raw, current_split)
  File.open(report_file, 'wb') do |f|
    f.write("date;Bleu HC;Bleu HP;Blanc HC;Blanc HP;Rouge HC;Rouge HP;Inconnu\n")
    current_day = 0
    lines_raw.reverse_each do |entry|
      time = Time.strptime("#{entry[0]}Z", '%Y-%m-%d %H:%M:%S%z').getlocal
      day = time.strftime("%Y%j").to_i
      if day > current_day
        current_day = day
        f.write(report_patrice_line(time, JSON.parse(entry[1])))
      end
    end
    f.write(report_patrice_line(Time.now, current_split))
  end
end

INDEXES = {
  "01" => "index_1",
  "02" => "index_2",
  "03" => "index_3",
  "04" => "index_4",
  "05" => "index_5",
  "06" => "index_6",
  "07" => "index_7",
  "08" => "index_8",
  "09" => "index_9",
  "10" => "index_10"
}
UNKNOWN_INDEX = "unknown"

STDOUT.sync = true

db = setup_database(METER_DATABASE)

mutex = Mutex.new
threads = []
general_meter_current_index_name = UNKNOWN_INDEX
general_meter_current_index_time = Time.now
line_id , special_meter_index_split = get_indexes(db, SPECIAL_METER_ID)
record_incident(db, "read indexes from database for meter #{SPECIAL_METER_ID} from line number #{line_id}")

threads << Thread.new do
  read_meter_info(GENERAL_METER, STANDARD_BAUD) do |meter_info|
    time = parse_date(meter_info["DATE"])
    if time && (Time.now-time).abs > 60
      ret = system("date -s '#{time}'")
      record_incident(db, "Trying to set time of day to #{time} with return value #{ret}")
    end
    mutex.synchronize do
      ptec = meter_info["NTARF"]
      if ptec && INDEXES[ptec]
        if INDEXES[ptec] != general_meter_current_index_name
          record_incident(db, "Setting general meter index from #{general_meter_current_index_name} to #{INDEXES[ptec]}")
        end
        general_meter_current_index_name = INDEXES[ptec]
        general_meter_current_index_time = Time.now
      end
    end
  end
end

60.times do
  sleep(1)
  current_index = nil
  mutex.synchronize do
    current_index = general_meter_current_index_name
  end
  break if current_index != UNKNOWN_INDEX
end

threads << Thread.new do
  incident_cnt = 0
  read_meter_info(SPECIAL_METER, HISTORIC_BAUD) do |meter_info|
    mutex.synchronize do
      old_sum = special_meter_index_split.sum { |_, idx| idx }
      new_sum = sum_indexes(meter_info)
      if new_sum && new_sum.is_a?(Integer) && new_sum != 0
        delta = new_sum - old_sum
        if delta > 0 && delta <= 1000
          adjust_index(special_meter_index_split, general_meter_current_index_name, delta)
          if general_meter_current_index_name == UNKNOWN_INDEX
            if (incident_cnt % 100) == 0
              record_incident(db, "ventilate #{delta} Wh of meter #{SPECIAL_METER_ID} into the unknown index")
            end
            incident_cnt += 1
          end
        elsif delta < 0 || delta > 1000
          adjust_index(special_meter_index_split, UNKNOWN_INDEX, delta)
          save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
          record_incident(db, "strange consumption of #{SPECIAL_METER_ID} of #{delta} Wh")
          record_incident(db, "meter_info for #{SPECIAL_METER_ID} #{meter_info.to_json}")
        end
      end
    end
  end
end

threads << Thread.new do
  loop do
    sleep(1800)
    mutex.synchronize do
      save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
      if (Time.now - general_meter_current_index_time) >= 1800
        general_meter_current_index_name = UNKNOWN_INDEX
        general_meter_current_index_time = Time.now
        record_incident(db, "Reverting general meter index to unknown. Last update was #{general_meter_current_index_update}.")
      end
    end
  end
end

threads << Thread.new do
  loop do
    sleep(10)
    split = nil
    mutex.synchronize do
      split = special_meter_index_split.dup
    end
    write_report(REPORT_FILE, SPECIAL_METER_ID, split, general_meter_current_index_name)
  end
end

threads << Thread.new do
  loop do
    lines_raw = nil
    current_split = nil
    mutex.synchronize do
      lines_raw = db.execute("SELECT created_at, indexes FROM index_reports WHERE meter_id = ? ORDER BY id DESC LIMIT 10000;", SPECIAL_METER_ID)
      current_split = special_meter_index_split.dup
    end
    write_report_patrice(REPORT_PATRICE, lines_raw, current_split)
    sleep(3600)
  end
end

Signal.trap("INT") do
  save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
  exit
end

Signal.trap("TERM") do
  save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
  exit
end

loop do
  sleep(10)
  if threads.any? { |thr| !%w(sleep run).include?(thr.status) }
    break
  end
end

save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
