require 'bundler/setup'
require 'lightstep'
require 'opentracing'

require 'rack'
require 'rack/server'

$token = '61c90a839a46c996e79c56afa1f116b8'
$request_id = 'abc123'

class Router
  def initialize
    @tracer = LightStep::Tracer.new(component_name: 'router', access_token: $token)
  end

  def call(env)
    span = @tracer.start_span("router_call").set_baggage_item("request-id", $request_id)
    span.log(event: "router_request", env: env)
    puts "parent #{span.span_context.trace_id}"

    client = Net::HTTP.new("localhost", "9002")
    req = Net::HTTP::Post.new("/")
    @tracer.inject(span.span_context, OpenTracing::FORMAT_RACK, req)
    res = client.request(req)

    span.log(event: "application_response", response: res.to_s)
    span.finish
    @tracer.flush
    puts "----> https://app.lightstep.com/#{$token}/trace?span_guid=#{span.span_context.id}&at_micros=#{span.start_micros} <----"
    [200, {}, [res.body]]
  end
end

class App
  def initialize
    @tracer = LightStep::Tracer.new(component_name: 'app', access_token: $token)
  end

  def call(env)
    wire_ctx = @tracer.extract(OpenTracing::FORMAT_RACK, env)
    span = @tracer.start_span("app_call", child_of: wire_ctx)
    puts "child  #{span.to_h[:trace_guid]}"
    span.log(event: "application", env: env)
    sleep 0.05
    span.finish
    @tracer.flush
    [200, {}, ["application"]]
  end
end

router_thread = Thread.new do
  Thread.abort_on_exception = true
  Rack::Server.start(app: Router.new, Port: 9001)
end

app_thread = Thread.new do
  Thread.abort_on_exception = true
  Rack::Server.start(app: App.new, Port: 9002)
end

loop do
  begin
    p Net::HTTP.get(URI("http://127.0.0.1:9001/"))
    break
  rescue Errno::ECONNREFUSED
    sleep 0.05
  end
end
