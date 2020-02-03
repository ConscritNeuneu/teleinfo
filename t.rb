require "json"
require "serialport"
require "thread"
require "sqlite3"

STANDARD_BAUD = 9600
HISTORIC_BAUD = 1200

GENERAL_METER = "/dev/ttyS0"
SPECIAL_METER = "/dev/ttyAMA1"
SPECIAL_METER_ID = 1
METER_DATABASE = "/home/quentin/index_reports.sqlite3"
REPORT_FILE = '/run/user/1000/report.txt'

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

REPORT_INDEXES = [
  "HC BLEU",
  "HP BLEU",
  "HC BLANC",
  "HP BLANC",
  "HC ROUGE",
  "HP ROUGE",
  "INCONNU"
]

def write_report(report_file, meter_id, meter_split)
  File.open(report_file, 'wb') do |f|
    f.write("Report for meter_id #{meter_id}\n")
    f.write("Date: #{Time.now}\n")
    f.write("\n")
    f.write(
      REPORT_INDEXES.map do |index|
        consumption = meter_split[index].to_f / 1000
        "#{index}\t#{consumption} kWh"
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
UNKNOWN_INDEX = "INCONNU"

db = setup_database(METER_DATABASE)

mutex = Mutex.new
general_meter_current_index_name = UNKNOWN_INDEX
general_meter_current_index_time = Time.now
special_meter_index_sync = false
line_id , special_meter_index_split = get_indexes(db, SPECIAL_METER_ID)
record_incident(db, "read indexes from database for meter #{SPECIAL_METER_ID} from line number #{line_id}")

Thread.new do
  read_meter_info(GENERAL_METER, STANDARD_BAUD) do |meter_info|
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

Thread.new do
  read_meter_info(SPECIAL_METER, HISTORIC_BAUD) do |meter_info|
    mutex.synchronize do
      old_sum = special_meter_index_split.sum { |_, idx| idx }
      new_sum = sum_indexes(meter_info)
      if new_sum
        delta = new_sum - old_sum
        if !special_meter_index_sync
          if delta != 0
            adjust_index(special_meter_index_split, UNKNOWN_INDEX, delta)
            save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
            record_incident(db, "adjust unknown index from meter #{SPECIAL_METER_ID} by #{delta} Wh")
          end
          special_meter_index_sync = true
          puts "sync with #{delta}"
        else
          if delta > 0
            adjust_index(special_meter_index_split, general_meter_current_index_name, delta)
            if general_meter_current_index_name == UNKNOWN_INDEX
              record_incident(db, "ventilate #{delta} Wh of meter #{SPECIAL_METER_ID} into the unknown index")
            end
            puts "add #{delta} to #{general_meter_current_index_name}"
          elsif delta < 0
            adjust_index(special_meter_index_split, UNKNOWN_INDEX, delta)
            save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
            record_incident(db, "negative consumption of #{SPECIAL_METER_ID} of #{delta} Wh")
          end
        end
      end
    end
  end
end

Thread.new do
  loop do
    sleep 10
    split = nil
    mutex.synchronize do
      split = special_meter_index_split.dup
    end
    write_report(REPORT_FILE, SPECIAL_METER_ID, split)
  end
end

Signal.trap("INT") do
  save_indexes(db, SPECIAL_METER_ID, special_meter_index_split)
  exit
end

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

#trame = "\x02\nADCO 811775412275 I\r\nOPTARIF HC.. <\r\nISOUSC 45 ?\r\nHCHC 004070290 \\\r\nHCHP 006438891 :\r\nPTEC HP..  \r\nIINST 004 [\r\nIMAX 090 H\r\nPAPP 01090 +\r\nHHPHC A ,\r\nMOTDETAT 000000 B\r\x03"
#groups = trame[1..-2]
#infos = parse_trame(groups)

#puts JSON.pretty_generate(infos)
