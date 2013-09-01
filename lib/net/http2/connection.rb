module Net
  module HTTP2

    DEFAULT_FLOW_WINDOW = 65535
    DEFAULT_PRIORITY    = 2**30
    CONNECTION_HEADER   = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    class Connection
      attr_accessor :type, :window, :state, :error
      attr_accessor :stream_limit, :active_stream_count

      def initialize(type = :client)
        @type = type

        @stream_id = (@type == :client) ? 1 : 2
        @stream_limit = Float::INFINITY
        @active_stream_count = 0
        @streams = {}

        @framer = Framer.new
        @window = DEFAULT_FLOW_WINDOW
        @window_limit = DEFAULT_FLOW_WINDOW

        @send_buffer = []
        @state = :new
        @error = nil
      end

      def new_stream
        raise StreamLimitExceeded.new if @active_stream_count == @stream_limit

        @stream_id += 2
        stream = Stream.new(self, @stream_id, DEFAULT_PRIORITY, @window)

        # Streams that are in the "open" state, or either of the "half closed"
        # states count toward the maximum number of streams that an endpoint is
        # permitted to open.
        stream.once(:active) { @active_stream_count += 1 }
        stream.once(:close)  { @active_stream_count -= 1 }
        stream.on(:frame)    { |frame| process(frame) }

        @streams[@stream_id] = stream
      end

      def receive(data)
        data = StringIO.new(data)

        while frame = @framer.parse(data) do
          # SETTINGS frames always apply to a connection, never a single stream.
          # The stream identifier for a settings frame MUST be zero.  If an
          # endpoint receives a SETTINGS frame whose stream identifier field is
          # anything other than 0x0, the endpoint MUST respond with a connection
          # error (Section 5.4.1) of type PROTOCOL_ERROR.
          if (frame[:stream] == 0 || frame[:type] == :settings)
            connection_management(frame)
          else
            @streams[frame[:stream]].process frame
          end
        end
      end
      alias :<< :receive

      def buffered_amount
        @send_buffer.map {|f| f[:length] }.reduce(:+) || 0
      end

      private

      def process(frame)
        if frame[:type] != :data
          # send immediately
        else
          @send_buffer.push frame
          send_data
        end
      end

      def send_data
        while @window > 0 && !@send_buffer.empty? do
          frame = @send_buffer.shift

          sent, frame_size = 0, frame[:payload].bytesize

          if frame_size > @window
            payload = frame.delete(:payload)
            chunk   = frame.dup

            frame[:payload] = payload.slice!(0, @window)
            chunk[:length]  = payload.bytesize
            chunk[:payload] = payload

            # if no longer last frame in sequence...
            if frame[:flags].include? :end_stream
              frame[:flags] -= [:end_stream]
            end

            @send_buffer.unshift chunk
            sent = @window
          else
            sent = frame_size
          end

          # TODO: send immediately
          @window -= sent
        end
      end

      def connection_management(frame)
        case @state
        # SETTINGS frames MUST be sent at the start of a connection.
        when :new
          connection_settings(frame)
          @state = :connected

        when :connected
          case frame[:type]
          when :settings
            connection_settings(frame)
          when :window_update
            flow_control_allowed?
            @window += frame[:increment]
            send_data
          else
            connection_error
          end
        else
          connection_error
        end
      end

      def connection_settings(frame)
        if (frame[:type] != :settings || frame[:stream] != 0)
          connection_error
        end

        frame[:payload].each do |key,v|
          case key
          when :settings_max_concurrent_streams
            @stream_limit = v

          # A change to SETTINGS_INITIAL_WINDOW_SIZE could cause the available
          # space in a flow control window to become negative. A sender MUST
          # track the negative flow control window, and MUST NOT send new flow
          # controlled frames until it receives WINDOW_UPDATE frames that cause
          # the flow control window to become positive.
          when :settings_initial_window_size
            flow_control_allowed?
            @window = @window - @window_limit + v
            @streams.each do |id, stream|
              stream.emit(:window, stream.window - @window_limit + v)
            end

            @window_limit = v

          # Flow control can be disabled the entire connection using the
          # SETTINGS_FLOW_CONTROL_OPTIONS setting. This setting ends all forms
          # of flow control. An implementation that does not wish to perform
          # flow control can use this in the initial SETTINGS exchange.
          when :settings_flow_control_options
            flow_control_allowed?

            if v == 1
              @window = @window_limit = Float::INFINITY
            end
          end
        end
      end

      def flow_control_allowed?
        if @window_limit == Float::INFINITY
          connection_error(:flow_control_error)
        end
      end

      def connection_error(error = :protocol_error)
        if @state != :closed
          process({type: :rst_stream, stream: 0, error: error})
        end

        @state, @error = :closed, error
        klass = error.to_s.split('_').map(&:capitalize).join
        raise Kernel.const_get(klass).new
      end

    end
  end
end
