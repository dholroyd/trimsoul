require 'sinatra'
require 'sinatra/json'
require 'json'
require 'data_mapper'
require "gst"

DataMapper.setup(:default, "sqlite3://#{Dir.pwd}/trimsoul-state.db")
DataMapper::Model.raise_on_save_failure = true

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
    src = Gst::ElementFactory.make("audiotestsrc")
    src.wave = 2
    src.freq = 200
    src.samplesperbuffer = 240
    conv = Gst::ElementFactory.make("audioconvert")
    rtp = Gst::ElementFactory.make("rtpL24pay")
    rtp.mtu = 1452
    udp = Gst::ElementFactory.make("udpsink")
    udp.port = dst_port
    udp.host = dst_host
    @bin << src << conv << rtp << udp
    caps = Gst::Caps.from_string("audio/x-raw,channels=2,rate=48000")
    unless src.link_filtered(conv, caps)
      raise "failed to link elements using filter #{caps}"
    end
    conv >> rtp >> udp
    puts @bin.play
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
