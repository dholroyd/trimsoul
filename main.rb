require 'gir_ffi'
require 'pathname'

GirFFI.setup :Gst, "1.0"
GirFFI.setup :GstApp, "1.0"
GirFFI.setup :GstBase, "1.0"
GirFFI.setup :GstRtp, "1.0"

t = Gst::MapInfo

require "gst_overrides"

Gst.init([])

class Playlist
  def initialize
    @list = Pathname.glob("audio/ebu_sqam/*.flac").sort.map{|p| p.realpath}
    @index = -1
  end

  def next
    @index += 1
    @list[@index % @list.length]
  end
end

class Sender
  def initialize(id, dst_port, dst_host)
    conv = Gst::ElementFactory.make("audioconvert", "pre-resample-conv")
    conv2 = Gst::ElementFactory.make("audioconvert", "pre-rtp-conv")
    audiorate = Gst::ElementFactory.make("audiorate", nil)
    resample = Gst::ElementFactory.make("audioresample", "to-48kHz-resample")
    rtp = Gst::ElementFactory.make("rtpL24pay", nil)
    # default element MTU gives packets shorter than we want,
    rtp.set_property_without_override("mtu", 1452)
    # set a 5ms minimum duration so that some packets don't end up short,
    min_ptime = GObject::Value.new
    min_ptime.init(GObject::TYPE_INT64)
    min_ptime.set_int64(5_000_000_000)
    rtp.set_property_without_override("min-ptime", min_ptime)
    # create X192-style timestamp alignment,
    # does not work; not sure why: rtp.timestamp_offset = (Time.new.to_f * 48_000).to_i & 0xffffffff
    timestamp_offset = GObject::Value.new
    timestamp_offset.init(GObject::TYPE_UINT)
    timestamp_offset.set_uint((Time.new.to_f * 48_000).to_i & 0xffffffff)
    rtp.set_property_without_override("timestamp-offset", timestamp_offset)
    udp = Gst::ElementFactory.make("udpsink", nil)
    udp.set_property_without_override("port", dst_port)
    udp.set_property_without_override("host", dst_host)

    @sink_bin = Gst::Bin.new("sink_bin-#{id}")
    @sink_bin.add conv
    @sink_bin.add resample
    @sink_bin.add conv2
    @sink_bin.add audiorate
    @sink_bin.add rtp
    @sink_bin.add udp
    gpad = Gst::GhostPad.new("sink", conv.get_static_pad("sink"))
    gpad.active = true
    @sink_bin.add_pad(gpad) or raise "add_pad failed"

    conv.link(resample)
    caps = Gst::Caps.from_string("audio/x-raw,rate=48000,channels=2")
    unless resample.link_filtered(conv2, caps)
      raise "failed to link elements using filter #{caps}"
    end
    #conv2.link(audiorate)
    #audiorate.link(rtp)
    conv2.link(rtp)
    rtp.link(udp)
  end

  attr_reader :sink_bin
end

class TestSource
  def initialize
    @src = Gst::ElementFactory.make("audiotestsrc", nil)
    @src.wave = 2
    @src.freq = 200
    @src.samplesperbuffer = 240
  end

  def link(pipeline, sender)
    @src >> sender.sink_bin
    pipeline << @src
  end

  def element
    @src
  end
end

class FestivalSource
  def initialize()
    @appsrc = Gst::ElementFactory.make("appsrc", nil) or raise "failed to make appsrc element"
    @appsrc.caps = Gst::Caps.from_string("text/x-raw,format=\"utf8\"")
    @festival = Gst::ElementFactory.make("festival", nil) or raise "failed to make festival element"
    @wavparse = Gst::ElementFactory.make("wavparse", nil) or raise "failed to make wavparse element"
    @identity = Gst::ElementFactory.make("identity", nil) or raise "failed to make identity element"
    @identity.set_property_without_override("signal-handoffs", true)
    @offset = 0
    @last_time = nil
    callback = FFI::Function.new(:void, [:pointer, :pointer, :pointer]) do |identity, buf, data|
      b = Gst::Buffer.wrap(buf)
      b.pts = b.pts + @offset
      #puts "buffer pts=#{b.pts.inspect} dts=#{b.dts.inspect}"
    end
    GirFFI::CallbackBase.store_callback callback
    r = GObject::Lib.g_signal_connect_data(@identity, "handoff", callback, nil, nil, 0)
    puts "g_signal_connect_data(#{@identity}, #{"handoff"}, #{callback}) => #{r}"
  end

  def link(pipeline, sender)
    @pipeline = pipeline
    pipeline.add @appsrc
    pipeline.add @festival
    pipeline.add @wavparse
    pipeline.add @identity
    pipeline.add sender.sink_bin
    @appsrc.link(@festival)
    @festival.link(@wavparse)
    @wavparse.link(@identity)
    @identity.link(sender.sink_bin)
    Thread.new do
      sleep 1
      # TODO: track actual pipeline state (signals?)
      state = :playing
      while state == :playing
	begin
	  # make waveparse recognise a new file
	  @wavparse.set_state(:ready)
	  @wavparse.set_state(:playing)
	  announce_time(Time.new)
	  sleep 10
	rescue => e
	  $stderr.puts [e, *e.backtrace].join("\n  ")
	end
      end
    end
  end

  private

  def announce_time(t)
    if @last_time
      @offset += (t - @last_time) * 1_000_000_000
    end
    add = GObject::Value.new
    add.init(GObject::TYPE_UINT64)
    data = t.strftime("%A, %B %d, %Y -- %H:%M:%S")
    alloc = Gst::Allocator.find(nil)  # default allocator
    mem = alloc.alloc(data.bytesize, nil)
    buf = Gst::Buffer.new
    buf.append_memory(mem)
    ret, map = mem.map(:write)
    raise "map() failed" unless ret
    map.data_write(data)
    map.size = data.bytesize
    @last_buf = buf
    @appsrc.push_buffer(buf)
    @last_time = t
  end

end

class PlaylistSource
  def initialize(playlist)
    @playlist = playlist
    @src = Gst::ElementFactory.make("playbin", nil)
    if @src.nil?
      raise "failed to create 'playbin'"
    end
    r = @src.signal_connect("about-to-finish") do |src|
      next_uri = @playlist.next
      src.uri = "file:#{next_uri}"
      puts "  next: #{next_uri}"
    end
    p r
    @src.uri = "file:#{@playlist.next}"
  end

  def link(pipeline, sender)
    pipeline << @src
    @src.audio_sink = sender.sink_bin
  end

  def element
    @src
  end
end

class Player

  def initialize(id, source, sender)
    @id = id
    @source = source
    @sender = sender
  end

  def start
    @pipeline = Gst::Pipeline.new("pipeline-#{@id}")

    # add all children to parent pipeline,
    #@pipeline << @source.element
    @source.link(@pipeline, @sender)

    ret = @pipeline.set_state(:playing)
    if ret == :failure
      raise "failed to play"
    end
    event_loop(@pipeline)
  end


  def stop
    @pipeline.stop
    @pipeline.remove_all
  end

  private

  def event_loop(pipe)
    running = true
    bus = pipe.bus

    @title = nil
    while running
      message = bus.poll(:any, -1)
      raise "message nil" if message.nil?

      case message.type
      when :eos
	puts "End of stream"
	running = false
      when :warning
	puts "Warning:"
	warning, debug = message.parse_warning
	puts "Debugging info: #{debug || 'none'}"
	puts warning.message
      when :error
	puts "Error:"
	error, debug = message.parse_error
	puts "Debugging info: #{debug || 'none'}"
	puts error.message
	running = false
      when :tag
	handle_tags(message.parse_tag)
      when :state_changed
	puts "State changed: #{message.parse_state_changed.inspect}"
      else
	p message.type
      end
    end
  end

  def handle_tags(tag_list)
    0.upto(tag_list.n_tags-1) do |i|
      name = tag_list.nth_tag_name(i)
      if name == "title"
	s, title = tag_list.string?(name)
	if s && title != @title
	  puts "  TITLE: #{title}"
	  @title = title
	end
      end
    end
  end
end

class PlayService
  def initialize(player)
    @queue = Queue.new
    Thread.new do
      main_loop(player)
    end
  end

  def main_loop(player)
    running = true
    player.start
    while running
      msg = @queue.pop
    end
    player.stop
  end
end

class Stream
  @@streams = {}

  attr_accessor :id
  attr_accessor :dst_port
  attr_accessor :dst_host

  def valid_id?(id)
    id && id.to_s =~ /^[a-z]+[a-z_0-9]*$/
  end

  def start
    #playlist = Playlist.new
    #source = PlaylistSource.new(playlist)
    source = FestivalSource.new()
    sender = Sender.new(id, dst_port, dst_host)
    @player = Player.new(id, source, sender)
    @player.start
  end

  def stop
    @player.stop
  end

  def self.[](id)
    @@streams[id]
  end

  def self.streams
    @@streams
  end
end

# Hack to allow ruby threads to run (ctrl-c not working though),
GLib.idle_add GLib::PRIORITY_DEFAULT_IDLE, Proc.new{Thread.pass; sleep 0.01; true}, nil, nil

s = Stream.new
s.id = "trimsoul"
s.dst_port = 5004
s.dst_host = "localhost"

s.start
