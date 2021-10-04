# rmodbus
# digest
# digest-crc
# serialport

require "digest/crc16_modbus"
require "rmodbus"
require "serialport"
require "time"

def read(address, count)
  ext = nil
  ModBus::RTUClient.connect('/dev/ttyUSB0', 9600, :data_bits => 8, :stop_bits => 1, :parity => SerialPort::EVEN) do |cl|
    cl.with_slave(1) do |slave|
      ext = slave.read_holding_registers(address, count).pack("n*")
    end
  end

  ext
end

def write(address, byte_string)
  ext = nil
  ModBus::RTUClient.connect('/dev/ttyUSB0', 9600, :data_bits => 8, :stop_bits => 1, :parity => SerialPort::EVEN) do |cl|
    cl.with_slave(1) do |slave|
      ext = slave.write_multiple_registers(address, byte_string.unpack("n*"))
    end
  end

  ext
end

def decode_time(time_string)
  tm = time_string.bytes.map { |b| '%2.2x' % b }.reverse.join
  tm = tm[2..7]+tm[10..]
  Time.strptime(tm, "%y%m%d%H%M%S")
end

def encode_time(time)
  s = time.strftime("00%y%m%d0%u%H%M%S")
  8.times.map { |i| s[2*i..2*i+1].to_i(16) }.reverse.pack("C*")
end

EMPTY_DATA = [
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0
].pack("C*")

TEMPO_DATA = [
  0x06, 0, 1, # HH:MM Tariff
  0x22, 0, 2,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0,
  0, 0, 0
].pack("C*")

TIME_INTERVALS = [0x300, 0x30C, 0x318, 0x324, 0x330, 0x33C, 0x348, 0x354, 0x360]

#write(0x300, TEMPO_DATA)

#9.times do |i|
#  STDOUT.write read(0x300+i*12, 12)
#end

#STDOUT.write read(0x100, (0x15E-0x100)+2)
#STDOUT.write read(0x0, 0x41+1)
