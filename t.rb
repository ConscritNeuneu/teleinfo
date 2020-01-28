require "json"
require "serialport"
require "thread"

def validate_historic(sub_group)
  data = sub_group[0..-3]
  cksum = sub_group[-1]

  (data.bytes.sum & 0x3f) + 0x20 == cksum.bytes[0]
end

def parse_trame(trame)
  infos = {}
  trame.split("\n").each do |g|
    g.chomp!
    if g.empty? || !validate_historic(g)
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

system("stty raw 1200 -parodd -cstopb cs7 < /dev/ttyS0")
SerialPort.open("/dev/ttyS0") do |io|
  i = 0
  loop do
    trame = read_trame(io)
    if trame
      infos = parse_trame(trame)
      File.open("/home/quentin/teleinfo/trame_#{i}.txt", "wb") { |f| f.write(trame) }
      File.open("/home/quentin/teleinfo/trame_#{i}.json", "wb") { |f| f.write(JSON.pretty_generate(infos)) }
      i += 1
    end
  end
end

#trame = "\x02\nADCO 811775412275 I\r\nOPTARIF HC.. <\r\nISOUSC 45 ?\r\nHCHC 004070290 \\\r\nHCHP 006438891 :\r\nPTEC HP..  \r\nIINST 004 [\r\nIMAX 090 H\r\nPAPP 01090 +\r\nHHPHC A ,\r\nMOTDETAT 000000 B\r\x03"
#groups = trame[1..-2]
#infos = parse_trame(groups)

#puts JSON.pretty_generate(infos)
