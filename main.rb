require 'sinatra'
require 'sinatra/json'
require 'json'
require 'data_mapper'
require "gst"

DataMapper.setup(:default, "sqlite3://#{Dir.pwd}/trimsoul-state.db")
DataMapper::Model.raise_on_save_failure = true

class Playlist
  def initialize
    @list = Pathname.glob("audio/ebu_sqam/*.flac").map{|p| p.realpath}
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
    @bin = Gst::Pipeline.new(id)
    src = nil
    case $kind
    when :test
      src = Gst::ElementFactory.make("audiotestsrc")
      src.wave = 2
      src.freq = 200
      src.samplesperbuffer = 240
    when :playlist
      src = Gst::ElementFactory.make("uridecodebin")
      if src.nil?
	raise "failed to create 'uridecodebin'"
      end
      src.signal_connect("drained") do |src|
        puts "#{src} drained"
	src.uri = "file:#{$playlist.next}"
	@bin.play
      end
      src.signal_connect("pad-added") do |src, pad|
	caps = pad.caps
	name = caps.get_structure(0).name
	if !@apad.linked? && name == "audio/x-raw"
	  pad.link(@apad)
	end
      end
      src.uri = "file:#{$playlist.next}"
    end
    conv = Gst::ElementFactory.make("audioconvert")
    conv2 = Gst::ElementFactory.make("audioconvert")
    resample = Gst::ElementFactory.make("audioresample")
    #capsfilter = Gst::ElementFactory.make("capsfilter")
    # remember the sink so we can link to it from the 'pad-added' callback above,
    @apad = conv.sinkpad
    rtp = Gst::ElementFactory.make("rtpL24pay")
    # default element MTU gives packets shorter than we want,
    rtp.mtu = 1452
    # TODO: try to fix packet length to 240 stereo samples
    udp = Gst::ElementFactory.make("udpsink")
    udp.port = dst_port
    udp.host = dst_host
    # add all children to parent pipeline,
    @bin << src << conv << resample << conv2 << rtp << udp
    src >> conv
    conv >> resample
    caps = Gst::Caps.from_string("audio/x-raw,rate=48000")
    unless resample.link_filtered(conv2, caps)
      raise "failed to link elements using filter #{caps}"
    end
    conv2 >> rtp
    rtp >> udp
    ret = @bin.play
    # TODO: event_loop is for debugging - presumably blocks sinatra :(
    event_loop(@bin)
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
    @bin.stop
    @bin.remove_all
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
