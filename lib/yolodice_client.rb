require 'socket'
require 'openssl'
require 'thread'
require 'logger'
require 'json'
require 'bitcoin'

##
# YolodiceClient is a simple JSON-RPC 2.0 client that connects to YOLOdice.com.

class YolodiceClient

  # <tt>OpenSSL::SSL::SSLSocket</tt> object created by the <tt>connect</tt> method.
  attr_reader :connection

  # Proc for handling notifications from the server. This proc (if set) will be
  # called each time the server sends a notification, i.e. a message that is not a
  # response to any client call.
  # The proc is given a single argument: the message hash.
  # The proc is called in a separate thread.
  attr_accessor :notification_proc

  ##
  # Initializes the client object. The method accepts an option hash with the following keys:
  # * <tt>:host</tt> -- defaults to <tt>api.yolodice.com</tt>
  # * <tt>:port</tt> -- defaults to <tt>4444</tt>
  # * <tt>:ssl</tt> -- if SSL should be used, defaults to <tt>true</tt>

  def initialize opts={}
    @opts = {
      host: 'api.yolodice.com',
      port: 4444,
      ssl: true
    }.merge opts

    @req_id_seq = 0
    @current_requests = {}
    @receive_queues = {}
    @thread_semaphore = Mutex.new
  end


  ##
  # Sets a logger for the object.

  def logger=(logger)
    @log = logger
  end


  ##
  # Connects to the host.

  def connect
    @connection = if @opts[:ssl]
                    log.debug "Connecting to #{@opts[:host]}:#{@opts[:port]} over SSL"
                    socket = TCPSocket.open @opts[:host], @opts[:port]
                    ssl_socket = OpenSSL::SSL::SSLSocket.new socket
                    ssl_socket.sync_close = true
                    ssl_socket.connect
                    ssl_socket
                  else
                    log.debug "Connecting to #{@opts[:host]}:#{@opts[:port]}"
                    TCPSocket.open @opts[:host], @opts[:port]
                  end

    log.info "Connected to #{@opts[:host]}:#{@opts[:port]}"
    # Start a thread that keeps listening on the socket
    @listening_thread = Thread.new do
      log.debug 'Listening thread started'
      loop do
        begin
          msg = @connection.gets
          next if msg == nil
          log.debug{ "<<< #{msg}" }
          message = JSON.parse msg
          if message['id'] && (message.has_key?('result') || message.has_key?('error'))
            # definitealy a response
            callback = @thread_semaphore.synchronize{ @current_requests.delete message['id'] }
            raise Error, "Unknown id in response" unless callback
            if callback.is_a? Integer
              # it's a thread
              @receive_queues[callback] << message
            elsif callback.is_a? Proc
              # A thread pool would be better.
              Thread.new do
                callback.call message
              end
            end
          else
            if message['id']
              # It must be a request from the server. We do not support it yet.
            else
              # No id, it must be a notification then.
              if notification_proc
                Thread.new do
                  notification_proc.call message
                end
              end
            end
          end
        rescue StandardError => e
          log.error e
        end
      end
    end
    # Start a thread that pings the server
    @pinging_thread = Thread.new do
      log.debug 'Pinging thread started'
      loop do
        begin
          sleep 30
          call :ping
        rescue StandardError => e
          log.error e
        end
      end
    end
    true
  end


  ##
  # Closes connection to the host.

  def close
    log.debug "Closing connection"
    # Stop threads
    @connection.close
    @listening_thread.exit
    @pinging_thread.exit
    true
  end


  ##
  # Authenticates the connection by requesting a challenge message, signing it and sending the response back.
  # 
  # Parameters:
  # * <tt>auth_key</tt> -- Base58 encoded private key for the API key
  #
  # Returns
  # * <tt>false</tt> if authentication fails,
  # * user object (Hash with public user attributes) when authentication succeeds.

  def authenticate auth_key
    auth_key = Bitcoin::Key.from_base58(auth_key) unless auth_key.is_a?(Bitcoin::Key)
    challenge = generate_auth_challenge
    user = auth_by_address address: auth_key.addr, signature: auth_key.sign_message(challenge)
    raise Error, "Authentication failed" unless user
    log.debug "Authenticated as user #{user['name']}(#{user['id']})"
    user
  end


  ##
  # Calls an arbitrary method on the server.
  #
  # Parameters:
  # * <tt>method</tt> -- method name,
  # * <tt>*arguments</tt> -- any arguments for the method, will be passed as the <tt>params</tt> object (optional),
  # * <tt>&blk</tt> -- a callback (optional) to be called upon receiving a response for async calls. The callback will receive the response object.

  def call method, *arguments, &blk
    raise Error, "Not connected" unless @connection && !@connection.closed?
    params = if arguments.count == 0
               nil
             elsif arguments.is_a?(Array) && arguments[0].is_a?(Hash)
               arguments[0]
             else
               arguments
             end
    id = @thread_semaphore.synchronize{ @req_id_seq += 1 }
    request = {
      id: id,
      method: method
    }
    request[:params] = params if params != nil
    if blk
      @thread_semaphore.synchronize{ @current_requests[id] = blk }
      log.debug{ "Calling remote method #{method}(#{params.inspect if params != nil}) with an async callback" }
      log.debug{ ">>> #{request.to_json}" }
      @connection.puts request.to_json
      nil
    else
      # a regular blocking request
      @thread_semaphore.synchronize{ @current_requests[id] = Thread.current.object_id }
      queue = (@receive_queues[Thread.current.object_id] ||= Queue.new)
      queue.clear
      log.debug{ "Calling remote method #{method}(#{params.inspect if params != nil})" }
      log.debug{ ">>> #{request.to_json}" }
      @connection.puts request.to_json
      response = queue.pop
      if response.has_key? 'result'
        response['result']
      elsif response['error']
        raise RemoteError.new response['error']
      end
    end
  end

 
  ##
  # Overloading the <tt>method_missing</tt> gives a convenience way to call server-side methods. This method calls the <tt>call</tt> with the same set of arguments.

  def method_missing method, *args, &blk
    call method, *args, &blk
  end

  def log
    # no logging by default
    @log ||= Logger.new '/dev/null'
  end

  private :log


  ##
  # Thrown whenever an error in the client occurs.

  class Error < StandardError; end


  ##
  # Thrown when an error is received from the server. <tt>RemoteError</tt> has two extra attributes: <tt>code</tt> and <tt>data</tt> that correspond to the values returned in the error object in server response.

  class RemoteError < StandardError
    
    # Error code, as returned from the server.
    attr_accessor :code

    # Optional data object, if returned by the server.
    attr_accessor :data
    
    def initialize(error_obj = {'code' => -1, 'message' => "RPC Error"})
      @code = error_obj['code'] || -1
      @data = error_obj['data'] if error_obj['data']
      msg = "#{@code}: #{error_obj['message']}"
      if @code == 422 && @data && @data.has_key?('errors')
        msg += ': ' + @data['errors'].to_json
      end
      super msg
    end
  end

  class << self

    ##
    # Returns bet terget given the required multiplier.

    def target_from_multiplier m
      edge = 0.01
      (1_000_000.0 * (1.0 - edge) / m).round
    end

    ##
    # Returns bet target given the required win probability.

    def target_from_probability p
      (p * 1_000_000.0).round
    end

    ##
    # Converts amount from satoshi (integer) to amount in bitcoins (float).

    def satoshi_to_btc v
      (v.to_f / 100_000_000).round(8)
    end

    ## Converts amount from bitcoins (float) to satoshi (integer).
    def btc_to_satoshi v
      (v * 100_000_000).round
    end

  end
end
