require "gst"


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
    resample = Gst::ElementFactory.make("audioresample", "to-48kHz-resample")
    rtp = Gst::ElementFactory.make("rtpL24pay")
    # default element MTU gives packets shorter than we want,
    rtp.mtu = 1452
    # set a 5ms minimum duration so that some packets don't end up short,
    rtp.min_ptime = 5_000_000_000
    # create X192-style timestamp alignment,
    rtp.timestamp_offset = (Time.new.to_f * 48_000).to_i & 0xffffffff
    udp = Gst::ElementFactory.make("udpsink")
    udp.port = dst_port
    udp.host = dst_host

    @sink_bin = Gst::Bin.new("sink_bin-#{id}")
    @sink_bin << conv << resample << conv2 << rtp << udp
    gpad = Gst::GhostPad.new("sink", conv.sinkpad)
    gpad.active = true
    @sink_bin.add_pad(gpad) or raise "add_pad failed"

    conv >> resample
    caps = Gst::Caps.from_string("audio/x-raw,rate=48000")
    unless resample.link_filtered(conv2, caps)
      raise "failed to link elements using filter #{caps}"
    end
    conv2 >> rtp
    rtp >> udp
  end

  attr_reader :sink_bin
end

class TestSource
  def initialize
    @src = Gst::ElementFactory.make("audiotestsrc")
    @src.wave = 2
    @src.freq = 200
    @src.samplesperbuffer = 240
  end

  def link(sender)
    @src >> sender.sink_bin
    @pipeline << @src
  end

  def element
    @src
  end
end

class PlaylistSource
  def initialize(playlist)
    @playlist = playlist
    @src = Gst::ElementFactory.make("playbin")
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

  def link(sender)
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
    @pipeline << @source.element
    @source.link(@sender)

    ret = @pipeline.play
    if Gst::StateChangeReturn::FAILURE === ret
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
      message = bus.poll(Gst::MessageType::ANY, Gst::CLOCK_TIME_NONE)
      raise "message nil" if message.nil?

      case message.type
      when Gst::MessageType::EOS
	puts "End of stream"
	running = false
      when Gst::MessageType::WARNING
	puts "Warning:"
	warning, debug = message.parse_warning
	puts "Debugging info: #{debug || 'none'}"
	puts warning.message
      when Gst::MessageType::ERROR
	puts "Error:"
	error, debug = message.parse_error
	puts "Debugging info: #{debug || 'none'}"
	puts error.message
	running = false
      when Gst::MessageType::TAG
	handle_tags(message.parse_tag)
      else
	#p message.type
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
    playlist = Playlist.new
    source = PlaylistSource.new(playlist)
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

s = Stream.new
s.id = "test"
s.dst_port = 5004
s.dst_host = "localhost"

s.start
