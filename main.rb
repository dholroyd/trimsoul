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

def add_bus_watcher(name, pipeline)
  callback = Proc.new do |bus, msg, data|
    begin
      case msg.type
      when :eos
	puts "#{name} End of stream"
      when :warning
	puts "#{name} Warning:"
	warning, debug = msg.parse_warning
	puts "#{name} Debugging info: #{debug || 'none'}"
	puts warning.message
      when :error
	puts "#{name} Error:"
	error, debug = msge.parse_error
	puts "#{name} Debugging info: #{debug || 'none'}"
	puts error.message
      when :tag
	handle_tags(msg.parse_tag)
      when :state_changed
	oldstate, newstate, pending = msg.parse_state_changed
	val = GObject::Value.new
	val.init(GObject::TYPE_STRING)
	msg.src.get_property_without_override("name", val)
	print "#{name} State changed #{val.get_value}: #{oldstate}->#{newstate}"
	puts pending==:void_pending ? "" : " (pending: #{pending})"
	if msg.src == pipeline
	  if newstate==:ready
	    puts "#{name}  ..setting pipeline to :paused"
	    pipeline.set_state(:paused)
	  elsif oldstate==:ready && newstate==:paused
	    puts "#{name}  ..setting pipeline to :playing"
	    pipeline.set_state(:playing)
	  end
	end
      else
	puts "#{name} #{msg.type}"
      end
      $stdout.flush
    rescue => e
      p e
    end
    true
  end
  pipeline.get_bus.add_watch(GLib::PRIORITY_DEFAULT, callback, nil, nil)
end

class Sender
  def initialize(id, dst_port, dst_host)
    conv = Gst::ElementFactory.make("audioconvert", "pre-resample-conv")
    conv2 = Gst::ElementFactory.make("audioconvert", "pre-rtp-conv")
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
    #@identity.set_property_without_override("signal-handoffs", true)
    @identity.set_property_without_override("single-segment", true)
    @identity.set_property_without_override("sync", true)
    @audiorate = Gst::ElementFactory.make("audiorate", nil) or raise "failed to make audiorate element"
    @audiorate.set_property_without_override("tolerance", true)
    @offset = 0
    @last_time = nil
#    callback = FFI::Function.new(:void, [:pointer, :pointer, :pointer]) do |identity, buf, data|
#      begin
#	b = Gst::Buffer.wrap(buf)
#	#b.pts = b.pts + @offset
#	puts "buffer pts=#{b.pts.inspect} dts=#{b.dts.inspect} duration=#{b.duration.inspect}"
#      rescue => e
#	$stderr.puts [e, *e.backtrace].join("\n  ")
#      end
#    end
#    GirFFI::CallbackBase.store_callback callback
#    r = GObject::Lib.g_signal_connect_data(@identity, "handoff", callback, nil, nil, 0)
#    puts "g_signal_connect_data(#{@identity}, #{"handoff"}, #{callback}) => #{r}"
  end

  def link(pipeline, sender)
    @pipeline = pipeline
    pipeline.add @appsrc
    pipeline.add @festival
    pipeline.add @wavparse
    pipeline.add @identity
    pipeline.add @audiorate
    pipeline.add sender.sink_bin
    @appsrc.link(@festival) or raise "not linked"
    @festival.link(@wavparse) or raise "not linked"
    @wavparse.link(@identity) or raise "not linked"
    @identity.link(@audiorate) or raise "not linked"
    @audiorate.link(sender.sink_bin) or raise "not linked"
    callback = Proc.new do
      begin
	# make waveparse recognise a new file
	@wavparse.set_state(:ready)
	@wavparse.set_state(:playing)
	announce_time(Time.new)
      rescue => e
	$stderr.puts [e, *e.backtrace].join("\n  ")
      end
      true
    end
    # TODO: probably the 'notify' argument is required for proper GC?
    GLib.timeout_add(GLib::PRIORITY_DEFAULT, 10_000, callback, nil, nil)
  end

  private

  def announce_time(t)
    if @last_time
      @offset += (t - @last_time) * 1_000_000_000
      @wavparse.get_static_pad("src").set_offset(@offset)
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
    @pipeline = Gst::Pipeline.new("sender-pipeline-#{id}")
    @pipeline.set_auto_flush_bus(false)
    @source = source
    @sender = sender
  end

  def start

    @source.link(@pipeline, @sender)

    @pipeline.set_state(:playing)
    @main_loop = GLib::MainLoop.new(nil, true)
    trap("SIGINT") do
      $stderr.puts "trimsoul: quit"
      @main_loop.quit
    end
    @main_loop.run
  end

  private

  def event_loop(name, pipe)
    running = true
    bus = pipe.bus

    @title = nil
    while running
      message = bus.poll(:any, -1)
      raise "#{name} message nil" if message.nil?

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
