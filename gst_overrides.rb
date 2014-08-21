
module Gst

class MapInfo

  def data_write(data)
    if data.bytesize > @struct[:maxsize]
      raise "#{data.bytesize} bytes of data will not fit in a #{@struct[:maxsize]} buffer"
    end
    @struct[:data].write_string(data)
    @struct[:size] = data.bytesize
  end

  def data_read
    @struct[:data].read_string_length(@struct[:size])
  end

end

end
