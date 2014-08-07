require 'sinatra'
require 'sinatra/json'
require 'json'
require 'data_mapper'
require "gst"

DataMapper.setup(:default, "sqlite3://#{Dir.pwd}/trimsoul-state.db")
DataMapper::Model.raise_on_save_failure = true

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

$playlist = Playlist.new

def event_loop(pipe)
  running = true
  bus = pipe.bus

  while running
    message = bus.poll(Gst::MessageType::ANY, Gst::CLOCK_TIME_NONE)
    raise "message nil" if message.nil?

    case message.type
    when Gst::MessageType::EOS
      running = false
    when Gst::MessageType::WARNING
      warning, debug = message.parse_warning
      puts "Debugging info: #{debug || 'none'}"
      puts "Warning: #{warning.message}"
    when Gst::MessageType::ERROR
      error, debug = message.parse_error
      puts "Debugging info: #{debug || 'none'}"
      puts "Error: #{error.message}"
      running = false
    else
      p message.type
    end
  end
end

# TODO: hax - make this a configurable property of the stream
$kind = :playlist

class Stream
  @@streams = {}

  include DataMapper::Resource
  property :id, String, :key => true
  property :dst_port, Integer
  property :dst_host, String

  def valid_id?(id)
    id && id.to_s =~ /^[a-z]+[a-z_0-9]*$/
  end

  before :destroy do |s|
    @@streams.delete(s.id)
    s.stop
  end

  after :save, :bootstrap

  def bootstrap
    @@streams[id] = self
    start
  end

  def start
    @pipeline = Gst::Pipeline.new("pipeline-#{id}")
    src = nil
    case $kind
    when :test
      src = Gst::ElementFactory.make("audiotestsrc")
      src.wave = 2
      src.freq = 200
      src.samplesperbuffer = 240
    when :playlist
      src = Gst::ElementFactory.make("playbin")
      if src.nil?
	raise "failed to create 'playbin'"
      end
      src.signal_connect("about-to-finish") do |src|
	next_uri = $playlist.next
	src.uri = "file:#{next_uri}"
        puts "#{src} about-to-finish, next: #{next_uri}"
      end
      src.uri = "file:#{$playlist.next}"
    end
    conv = Gst::ElementFactory.make("audioconvert", "pre-resample-conv")
    conv2 = Gst::ElementFactory.make("audioconvert", "pre-rtp-conv")
    resample = Gst::ElementFactory.make("audioresample", "to-48kHz-resample")
    rtp = Gst::ElementFactory.make("rtpL24pay")
    # default element MTU gives packets shorter than we want,
    rtp.mtu = 1452
    # TODO: try to fix packet length to 240 stereo samples
    udp = Gst::ElementFactory.make("udpsink")
    udp.port = dst_port
    udp.host = dst_host
    # add all children to parent pipeline,
    @pipeline << src

    sink_bin = Gst::Bin.new("sink_bin")
    sink_bin << conv << resample << conv2 << rtp << udp
    gpad = Gst::GhostPad.new("sink", conv.sinkpad)
    gpad.active = true
    sink_bin.add_pad(gpad) or raise "add_pad failed"

    src.audio_sink = sink_bin

    src >> conv
    conv >> resample
    caps = Gst::Caps.from_string("audio/x-raw,rate=48000")
    unless resample.link_filtered(conv2, caps)
      raise "failed to link elements using filter #{caps}"
    end
    conv2 >> rtp
    rtp >> udp
    ret = @pipeline.play
    case ret
    when Gst::StateChangeReturn::FAILURE
      $stderr.puts "failed to play"
    when Gst::StateChangeReturn::SUCCESS
      $stderr.puts "playback start succeeded"
    when Gst::StateChangeReturn::ASYNC
      $stderr.puts "playback starts asynchronously"
    end
  end

  def stop
    @pipeline.stop
    @pipeline.remove_all
  end

  def self.[](id)
    @@streams[id]
  end

  def self.streams
    @@streams
  end
end

DataMapper.auto_upgrade!

Stream.all.each do |stream|
  stream.bootstrap
end

get '/' do 
  json(
    :streams => Stream.streams
  )
end 

put '/streams/:id' do
  id = params[:id]
  if Stream[id]
    # TODO: handle updates
    status 409  # conflict
  else
    data = JSON.parse(request.body.read)
    stream = Stream.new(data)
    stream.id = id
    stream.save
    status 201
  end
end

delete '/streams/:id' do
  if stream = Stream[params[:id]]
    stream.destroy
  else
    status 404
  end
end
