defmodule Mint.HTTP2Test do
  use ExUnit.Case, async: true

  import Mint.HTTP2.Frame
  import Mint.HTTP2.TestHelpers, only: [extract_port: 1]
  import ExUnit.CaptureLog

  alias Mint.{
    HTTPError,
    HTTP2,
    HTTP2.TestServer,
    TransportError
  }

  require Mint.HTTP

  @moduletag :capture_log
  @pdict_key {__MODULE__, :http2_test_server}

  setup :start_connection

  defmacrop assert_recv_frames([]) do
    quote do: refute_receive({:ssl, _socket, _data})
  end

  defmacrop assert_recv_frames(frames) when is_list(frames) do
    quote do: unquote(frames) = recv_frames(unquote(length(frames)))

  defmacrop assert_recv_frames(conn, frames) when is_list(frames) do
    quote do: unquote(frames) = recv_frames(unquote(conn), unquote(length(frames)))
  end

  defmacrop assert_http2_error(error, expected_reason) do
    quote do
      error = unquote(error)

      assert %HTTPError{reason: unquote(expected_reason)} = error

      message = Exception.message(error)
      refute message =~ "got FunctionClauseError"
      assert message != inspect(error.reason)
    end
  end

  defmacrop assert_transport_error(error, expected_reason) do
    quote do
      error = unquote(error)

      assert %TransportError{reason: unquote(expected_reason)} = error

      message = Exception.message(error)
      refute message =~ "got FunctionClauseError"
      assert message != inspect(error.reason)
    end
  end

  # TODO: Remove check once we depend on Elixir 1.10+.
  if Version.match?(System.version(), ">= 1.10.0") do
    describe "Mint.HTTP.is_mint_message/2" do
      test "the guard works with HTTP2 connections", %{conn: conn} do
        import Mint.HTTP, only: [is_connection_message: 2]

        assert is_connection_message(conn, {:tcp, conn.socket, "foo"}) == true
        assert is_connection_message(conn, {:tcp_closed, conn.socket}) == true
        assert is_connection_message(conn, {:tcp_error, conn.socket, :nxdomain}) == true

        assert is_connection_message(conn, {:tcp, :not_a_socket, "foo"}) == false
        assert is_connection_message(conn, {:tcp_closed, :not_a_socket}) == false

        assert is_connection_message(_conn = %HTTP2{}, {:tcp, conn.socket, "foo"}) == false

        # If the first argument is not a connection struct, we return false.
        assert is_connection_message(%{socket: conn.socket}, {:tcp, conn.socket, "foo"}) == false
        assert is_connection_message(%URI{}, {:tcp, conn.socket, "foo"}) == false
      end
    end
  end

  describe "handling unknown frames from the server" do
    test "handle origin frame from the server", %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames [headers(stream_id: stream_id)]

      origin_payload =
        Base.decode16!("001c68747470733a2f2f6472616e642e636c6f7564666c6172652e636f6d",
          case: :lower
        )

      frame = HTTP2.Frame.encode_raw(12, 0, 0, origin_payload)

      {:ok, conn, responses} =
        HTTP2.stream(
          conn,
          {:ssl, conn.socket, IO.iodata_to_binary(frame)}
        )

      assert responses == []

      hbf = server_encode_headers([{":status", "200"}])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert responses == [
               {:status, ref, 200},
               {:headers, ref, []},
               {:done, ref}
             ]

      assert HTTP2.open?(conn)
    end
  end

  describe "stream/2 with unknown messages or error messages" do
    test "unknown message", %{conn: conn} do
      assert HTTP2.stream(conn, :unknown_message) == :unknown
    end

    test "socket error messages are treated as errors", %{conn: conn} do
      message = {:ssl_error, conn.socket, :etimeout}

      assert {:error, %HTTP2{} = conn, %TransportError{reason: :etimeout}, []} =
               HTTP2.stream(conn, message)

      refute HTTP2.open?(conn)
    end
  end

  describe "closed streams" do
    test "server closes a stream with RST_STREAM", %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 rst_stream(stream_id: stream_id, error_code: :protocol_error)
               ])

      assert [{:error, ^ref, error}] = responses
      assert_http2_error error, {:server_closed_request, :protocol_error}

      assert HTTP2.open?(conn)
    end

    test "when server sends frames after sending RST_STREAM, they are ignored",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 rst_stream(stream_id: stream_id, error_code: :cancel),
                 {:headers, stream_id, [{":status", "200"}], [:end_headers, :end_stream]}
               ])

      assert [{:error, ^ref, error}] = responses
      assert_http2_error error, {:server_closed_request, :cancel}

      assert HTTP2.open?(conn)
    end

    test "client closes a stream with cancel_request/2", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)
      {:ok, conn} = HTTP2.cancel_request(conn, ref)

      assert_recv_frames(conn, [
        headers(stream_id: stream_id),
        rst_stream(stream_id: stream_id, error_code: :cancel)
      ])

      # If the server replies next, we ignore the replies.
      assert {:ok, %HTTP2{} = conn, []} =
               stream_frames(conn, [
                 {:headers, stream_id, [{":status", "200"}], [:end_headers]},
                 data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
               ])

      assert HTTP2.open?(conn)
    end

    test "client closes a non-existent request with cancel_request/2", %{conn: conn} do
      assert {:ok, ^conn} = HTTP2.cancel_request(conn, make_ref())
    end

    test "receiving a RST_STREAM on a closed stream is ignored", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 {:headers, stream_id, [{":status", "200"}], [:end_headers, :end_stream]}
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, []}, {:done, ^ref}] = responses

      assert_recv_frames(conn, [rst_stream(stream_id: ^stream_id)])

      assert {:ok, %HTTP2{} = conn, []} =
               stream_frames(conn, [
                 rst_stream(stream_id: stream_id, error_code: :no_error),
                 rst_stream(stream_id: stream_id, error_code: :no_error)
               ])

      assert HTTP2.open?(conn)
    end
  end

  describe "stream state transitions" do
    test "if client receives HEADERS after receiving a END_STREAM flag, it ignores it",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 {:headers, stream_id, [{":status", "200"}], [:end_headers, :end_stream]},
                 {:headers, stream_id, [{":status", "200"}], [:end_headers, :end_stream]}
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, []}, {:done, ^ref}] = responses

      assert HTTP2.open?(conn)
    end

    test "if client receives DATA after receiving a END_STREAM flag, it ignores it",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 {:headers, stream_id, [{":status", "200"}], [:end_headers, :end_stream]},
                 data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, []}, {:done, ^ref}] = responses

      assert HTTP2.open?(conn)
    end
  end

  describe "server closes the connection" do
    test "with GOAWAY with :protocol_error", %{conn: conn} do
      {conn, _ref} = open_request(conn)
      {conn, ref1} = open_request(conn)
      {conn, ref2} = open_request(conn)

      assert_recv_frames(conn, [
        headers(stream_id: first_stream_id),
        headers(),
        headers()
      ])

      assert {:error, %HTTP2{} = conn, error, responses} =
               stream_frames(conn, [
                 goaway(
                   last_stream_id: first_stream_id,
                   error_code: :protocol_error,
                   debug_data: "debug data"
                 )
               ])

      assert_http2_error error, {
        :server_closed_connection,
        :protocol_error,
        "debug data"
      }

      assert [{:error, server_ref1, error1}, {:error, server_ref2, error2}] = responses
      assert MapSet.new([server_ref1, server_ref2]) == MapSet.new([ref1, ref2])

      assert_http2_error error1, :unprocessed
      assert_http2_error error2, :unprocessed

      assert HTTP2.open_request_count(conn) == 1

      refute HTTP2.open?(conn, :write)
      assert HTTP2.open?(conn, :read)
    end

    test "with GOAWAY with :no_error and responses after the GOAWAY frame", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: ""),
                 headers(
                   stream_id: stream_id,
                   hbf: encode_headers([{":status", "200"}]),
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
                   hbf: encode_headers([{":status", "200"}]),
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, []}, {:data, ^ref, "hello"}, {:done, ^ref}] =
               responses

      # the client would normally send two window_updates and a rst_stream, but since the
      # connection is now read-only, it should send nothing
      assert_recv_frames []

      assert HTTP2.open_request_count(conn) == 0

      refute HTTP2.open?(conn, :write)
      assert HTTP2.open?(conn, :read)
    end

    test "with GOAWAY followed by another GOAWAY then the error reason is from the last GOAWAY",
         %{conn: conn} do
      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 goaway(last_stream_id: 1, error_code: :no_error, debug_data: "1"),
                 goaway(last_stream_id: 1, error_code: :flow_control_error, debug_data: "2"),
                 goaway(last_stream_id: 1, error_code: :protocol_error, debug_data: "3")
               ])

      assert_http2_error error, {:server_closed_connection, :protocol_error, "3"}

      refute HTTP2.open?(conn, :write)
      assert HTTP2.open?(conn, :read)
    end

    test "with direct socket close and no in-flight requests", %{conn: conn} do
      assert {:ok, %HTTP2{} = conn, []} = HTTP2.stream(conn, {:ssl_closed, conn.socket})
      refute HTTP2.open?(conn)
    end

    test "with direct socket close and in-flight requests", %{conn: conn} do
      {conn, _ref} = open_request(conn)
      assert {:error, %HTTP2{} = conn, error, []} = HTTP2.stream(conn, {:ssl_closed, conn.socket})
      assert %TransportError{reason: :closed} = error
      refute HTTP2.open?(conn)
    end
  end

  describe "closed connection" do
    test "client closes the connection with close/1", %{
      conn: conn
    } do
      assert {:ok, conn} = HTTP2.close(conn)

      assert_recv_frames(conn, [goaway(error_code: :no_error)])

      refute HTTP2.open?(conn)
    end

    test "close/1 an already closed connection with default inet_backend does not cause error", %{
      conn: conn
    } do
      assert HTTP2.open?(conn)
      # ignore the returned conn, otherwise transport.close/1 will not be called
      assert {:ok, _conn} = HTTP2.close(conn)
      assert {:ok, conn} = HTTP2.close(conn)
      refute HTTP2.open?(conn)
    end

    test "request/5 returns error if the connection is closed", %{conn: conn} do
      assert {:error, %HTTP2{} = conn, _error, []} =
               stream_frames(conn, [
                 goaway(
                   stream_id: 0,
                   last_stream_id: 3,
                   error_code: :protocol_error,
                   debug_data: "debug data"
                 )
               ])

      expected_window_size = HTTP2.get_window_size(conn, :connection)
      test_bodies = [nil, :stream, "XX"]

      conn =
        Enum.reduce(test_bodies, conn, fn body, conn ->
          assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], body)
          assert_http2_error error, :closed_for_writing
          assert HTTP2.open_request_count(conn) == 0
          assert HTTP2.get_window_size(conn, :connection) == expected_window_size
          conn
        end)

      assert {:ok, conn} = HTTP2.close(conn)

      Enum.reduce(test_bodies, conn, fn body, conn ->
        assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], body)
        assert_http2_error error, :closed
        assert HTTP2.open_request_count(conn) == 0
        assert HTTP2.get_window_size(conn, :connection) == expected_window_size
        conn
      end)
    end

    test "close/1 properly closes socket on active connection", %{conn: conn} do
      # Check port status, before close it should be opened
      port = conn |> HTTP2.get_socket() |> extract_port
      refute :erlang.port_info(port) == :undefined

      # Closed successfully
      assert {:ok, conn} = HTTP2.close(conn)
      refute HTTP2.open?(conn)

      # Check port status again, after close it should be closed
      assert :erlang.port_info(port) == :undefined
    end

    test "close/1 properly closes socket on errornous connection", %{conn: conn} do
      # force the transport to one that always times out on send
      conn = %{conn | transport: Mint.HTTP2.TestTransportSendTimeout}

      # Check port status, before close it should be opened
      port = conn |> HTTP2.get_socket() |> extract_port
      refute :erlang.port_info(port) == :undefined

      # Closed successfully
      assert {:ok, conn} = HTTP2.close(conn)
      refute HTTP2.open?(conn)

      # Check port status again, after close it should be closed
      assert :erlang.port_info(port) == :undefined
    end
  end

  describe "client errors" do
    @tag server_settings: [max_concurrent_streams: 1]
    @tag connect_options: [enable_async_settings: true]
    test "when the client tries to open too many concurrent requests", %{conn: conn} do
      {:ok, conn} = wait_for_settings(conn)
      {conn, _ref} = open_request(conn)
      assert HTTP2.open_request_count(conn) == 1
      expected_window_size = HTTP2.get_window_size(conn, :connection)

      Enum.reduce([nil, :stream, "XX"], conn, fn body, conn ->
        assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], body)
        assert_http2_error error, :too_many_concurrent_requests

        assert HTTP2.open_request_count(conn) == 1
        assert HTTP2.open?(conn)
        assert HTTP2.get_window_size(conn, :connection) == expected_window_size
        conn
      end)
    end

    test "when an ssl timeout is triggered on request", %{conn: conn} do
      # force the transport to one that always times out on send
      conn = %{conn | transport: Mint.HTTP2.TestTransportSendTimeout}

      expected_window_size = HTTP2.get_window_size(conn, :connection)

      Enum.reduce([nil, :stream, "XX"], conn, fn body, conn ->
        assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], body)
        assert_transport_error error, :timeout

        assert HTTP2.open_request_count(conn) == 0
        assert HTTP2.open?(conn)
        assert HTTP2.get_window_size(conn, :connection) == expected_window_size
        conn
      end)
    end

    test "when an ssl timeout is triggered on stream request body", %{
      conn: conn
    } do
      # open a streaming request.
      {conn, ref} = open_request(conn, :stream)

      assert_recv_frames(conn, [headers()])

      # force the transport to one that always times out on send
      conn = %{conn | transport: Mint.HTTP2.TestTransportSendTimeout}

      expected_window_size = HTTP2.get_window_size(conn, :connection)

      data = :binary.copy(<<0>>, HTTP2.get_window_size(conn, {:request, ref}))
      assert {:error, %HTTP2{} = conn, error} = HTTP2.stream_request_body(conn, ref, data)
      assert_transport_error error, :timeout

      assert HTTP2.open_request_count(conn) == 1
      assert HTTP2.open?(conn)
      assert HTTP2.get_window_size(conn, :connection) == expected_window_size
    end
  end

  describe "headers and continuation" do
    test "server splits headers into multiple CONTINUATION frames", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      <<hbf1::1-bytes, hbf2::1-bytes, hbf3::binary>> =
        encode_headers([{":status", "200"}, {"foo", "bar"}, {"baz", "bong"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(stream_id: stream_id, hbf: hbf1, flags: set_flags(:headers, [])),
                 continuation(
                   stream_id: stream_id,
                   hbf: hbf2,
                   flags: set_flags(:continuation, [])
                 ),
                 continuation(
                   stream_id: stream_id,
                   hbf: hbf3,
                   flags: set_flags(:continuation, [:end_headers])
                 )
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, headers}] = responses
      assert headers == [{"foo", "bar"}, {"baz", "bong"}]

      assert HTTP2.open?(conn)
    end

    test "server sends a badly encoded header block fragment", %{
      conn: conn
    } do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: "not a good hbf",
                   flags: set_flags(:headers, [:end_headers])
                 )
               ])

      assert_http2_error error, {:compression_error, debug_data}
      assert debug_data =~ "unable to decode headers: :bad_binary_encoding"

      assert_recv_frames(conn, [goaway(error_code: :compression_error)])

      refute HTTP2.open?(conn)
    end

    test "server sends a CONTINUATION frame outside of headers streaming",
         %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [continuation(stream_id: stream_id, hbf: "hbf")])

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "CONTINUATION received outside of headers streaming"

      assert_recv_frames(conn, [goaway(error_code: :protocol_error)])

      refute HTTP2.open?(conn)
    end

    test "server sends a non-CONTINUATION frame while streaming headers",
         %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 headers(stream_id: stream_id, hbf: "hbf", flags: set_flags(:headers, [])),
                 data(stream_id: stream_id, data: "hello")
               ])

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "headers are streaming but got a :data frame"

      assert_recv_frames(conn, [goaway(error_code: :protocol_error)])

      refute HTTP2.open?(conn)
    end

    test "server sends HEADERS with END_STREAM but no END_HEADERS and then sends CONTINUATIONs",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      <<hbf1::1-bytes, hbf2::1-bytes, hbf3::binary>> =
        encode_headers([{":status", "200"}, {"foo", "bar"}, {"baz", "bong"}])

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      {:ok, %HTTP2{} = conn, responses} =
        stream_frames(conn, [
          headers(stream_id: stream_id, hbf: hbf1, flags: set_flags(:headers, [:end_stream])),
          continuation(stream_id: stream_id, hbf: hbf2, flags: set_flags(:continuation, [])),
          continuation(
            stream_id: stream_id,
            hbf: hbf3,
            flags: set_flags(:continuation, [:end_headers])
          )
        ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, _headers}, {:done, ^ref}] = responses

      assert_recv_frames(conn, [rst_stream(error_code: :no_error)])

      assert HTTP2.open?(conn)
    end

    test "server sends a response without a :status header", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 {:headers, stream_id, [{"foo", "bar"}, {"baz", "bong"}],
                  [:end_headers, :end_stream]}
               ])

      assert [{:error, ^ref, error}] = responses
      assert_http2_error error, :missing_status_header

      assert_recv_frames(conn, [rst_stream(error_code: :protocol_error)])

      assert HTTP2.open?(conn)
    end

    test "client has to split headers because of max frame size", %{
      conn: conn
    } do
      # This is an empirical number of headers so that the minimum max frame size (~16kb) fits
      # between 2 and 3 times (so that we can test the behaviour above).
      headers = for i <- 1..400, do: {"a#{i}", String.duplicate("a", 100)}
      assert {:ok, conn, _ref} = HTTP2.request(conn, "GET", "/", headers, nil)

      assert_recv_frames(conn, [
        headers(stream_id: stream_id, hbf: hbf1, flags: flags1),
        continuation(stream_id: stream_id, hbf: hbf2, flags: flags2),
        continuation(stream_id: stream_id, hbf: hbf3, flags: flags3)
      ])

      assert flag_set?(flags1, :headers, :end_stream)
      refute flag_set?(flags1, :headers, :end_headers)
      refute flag_set?(flags2, :continuation, :end_headers)
      assert flag_set?(flags3, :continuation, :end_headers)

      headers = decode_headers(hbf1 <> hbf2 <> hbf3)
      assert [{":method", "GET"}, {":path", "/"}, {":scheme", "https"} | _] = headers

      assert HTTP2.open?(conn)
    end

    @tag server_settings: [max_header_list_size: 20]
    @tag connect_options: [enable_async_settings: true]
    test "an error is returned if client exceeds SETTINGS_MAX_HEADER_LIST_SIZE", %{conn: conn} do
      # With such a low max_header_list_size, even the default :special headers (such as
      # :method or :path) exceed the size.
      {:ok, conn} = wait_for_settings(conn)
      expected_window_size = HTTP2.get_window_size(conn, :connection)

      Enum.reduce([nil, :stream, "XX"], conn, fn body, conn ->
        assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], body)
        assert_http2_error error, {:max_header_list_size_exceeded, _, 20}

        assert HTTP2.open_request_count(conn) == 0
        assert HTTP2.open?(conn)
        assert HTTP2.get_window_size(conn, :connection) == expected_window_size
        conn
      end)
    end

    test ":authority pseudo-header includes port", %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(hbf: hbf)])

      assert {":authority", authority} =
               hbf
               |> decode_headers()
               |> List.keyfind(":authority", 0)

      assert authority == "#{conn.hostname}:#{conn.port}"

      assert HTTP2.open?(conn)
    end

    test ":authority pseudo-header does not include port if it is the scheme's default",
         %{conn: conn} do
      default_https_port = URI.default_port("https")

      try do
        # Override default https port for this test
        URI.default_port("https", conn.port)

        {conn, _ref} = open_request(conn)

        assert_recv_frames(conn, [headers(hbf: hbf)])

        assert {":authority", authority} =
                 hbf
                 |> decode_headers()
                 |> List.keyfind(":authority", 0)

        assert authority == conn.hostname

        assert HTTP2.open?(conn)
      after
        URI.default_port("https", default_https_port)
      end
    end

    test "when there's a request body, the content-length header is passed if not present",
         %{conn: conn} do
      {conn, _ref} = open_request(conn, "hello")

      assert_recv_frames(conn, [headers(hbf: hbf), data()])

      assert hbf
             |> decode_headers()
             |> List.keyfind("content-length", 0) == {"content-length", "5"}

      # Let's check that content-length is not overridden if already present.

      headers = [{"content-length", "10"}]
      assert {:ok, conn, _ref} = HTTP2.request(conn, "GET", "/", headers, "XX")

      assert_recv_frames(conn, [headers(hbf: hbf), data()])

      assert hbf
             |> decode_headers()
             |> List.keyfind("content-length", 0) == {"content-length", "10"}

      # Let's make sure content-length isn't added if the body is nil or :stream.

      {conn, _ref} = open_request(conn, nil)

      assert_recv_frames(conn, [headers(hbf: hbf)])

      refute hbf
             |> decode_headers()
             |> List.keymember?("content-length", 0)

      assert HTTP2.open?(conn)
    end

    test "the Cookie header is joined into a single value if present multiple times",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf =
        encode_headers([
          {":status", "200"},
          {"accept", "text/plain"},
          {"cookie", "a=b"},
          {"Cookie", "c=d; e=f"},
          {"content-type", "application/json"},
          {"cookie", "g=h"},
          {"x-header", "value"}
        ])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 )
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, headers}] = responses

      assert [{"cookie", cookie}, {"accept", _}, {"content-type", _}, {"x-header", _}] = headers

      assert cookie == "a=b; c=d; e=f; g=h"
    end

    test "a CONNECT request omits :scheme and :path pseudo-headers", %{
      conn: conn
    } do
      assert {:ok, conn, _ref} = HTTP2.request(conn, "CONNECT", "/", [], nil)

      assert_recv_frames(conn, [headers(hbf: hbf)])

      refute hbf
             |> decode_headers()
             |> List.keymember?(":scheme", 0)

      refute hbf
             |> decode_headers()
             |> List.keymember?(":path", 0)

      assert HTTP2.open?(conn)
    end

    test "explicitly passed pseudo-headers are sorted to the front of the headers list", %{
      conn: conn
    } do
      headers = [
        {":scheme", conn.scheme},
        {":path", "/ws"},
        {":protocol", "websocket"}
      ]

      assert {:ok, conn, _ref} = HTTP2.request(conn, "CONNECT", "/", headers, :stream)

      assert_recv_frames(conn, [headers(hbf: hbf)])

      assert [
               {":method", "CONNECT"},
               {":authority", _},
               {":scheme", _},
               {":path", "/ws"},
               {":protocol", "websocket"},
               {"user-agent", _}
             ] = decode_headers(hbf)

      assert HTTP2.open?(conn)
    end
  end

  describe "interim responses (1xx)" do
    test "multiple before a single HEADERS", %{conn: conn} do
      info_status1 = Enum.random(100..199)
      info_status2 = Enum.random(100..199)

      {conn, ref} = open_request(conn)

      assert_recv_frames [headers(stream_id: stream_id)]

      <<info_hbf1_part1::1-bytes, info_hbf1_part2::binary>> =
        server_encode_headers([
          {":status", Integer.to_string(info_status1)},
          {"x-info-header1", "this is an info"}
        ])

      info_hbf2 =
        server_encode_headers([
          {":status", Integer.to_string(info_status2)},
          {"x-info-header2", "this is an info"}
        ])

      hbf =
        server_encode_headers([
          {":status", "200"},
          {"content-type", "application/json"}
        ])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: info_hbf1_part1,
                   flags: set_flags(:headers, [])
                 ),
                 continuation(
                   stream_id: stream_id,
                   hbf: info_hbf1_part2,
                   flags: set_flags(:continuation, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: info_hbf2,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert [
               {:status, ^ref, ^info_status1},
               {:headers, ^ref, [{"x-info-header1", "this is an info"}]},
               {:status, ^ref, ^info_status2},
               {:headers, ^ref, [{"x-info-header2", "this is an info"}]},
               {:status, ^ref, 200},
               {:headers, ^ref, [{"content-type", "application/json"}]},
               {:done, ^ref}
             ] = responses

      assert HTTP2.open?(conn)
    end

    test "protocol error if interim response has END_STREAM set", %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames [headers(stream_id: stream_id)]

      info_hbf =
        server_encode_headers([
          {":status", "101"},
          {"x-info-header1", "this is an info"}
        ])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: info_hbf,
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert [{:error, ^ref, error}] = responses

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "informational response (1xx) must not have the END_STREAM flag set"

      assert HTTP2.open?(conn)
    end

    test "protocol error if interim response HEADERS comes after final HEADERS", %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames [headers(stream_id: stream_id)]

      hbf = server_encode_headers([{":status", "200"}])
      info_hbf = server_encode_headers([{":status", "101"}])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: info_hbf,
                   flags: set_flags(:headers, [:end_headers])
                 )
               ])

      assert [{:status, ^ref, 200}, {:headers, ^ref, []}, {:error, ^ref, error}] = responses

      assert_http2_error error, {:protocol_error, debug_data}

      assert debug_data =~
               "informational response (1xx) must appear before final response, got a 101 status"

      assert HTTP2.open?(conn)
    end
  end

  describe "trailing headers" do
    test "sent by the server with a normal response", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf = encode_headers([{":status", "200"}])

      <<trailing_hbf1::1-bytes, trailing_hbf2::binary>> =
        encode_headers([{"x-trailing", "some value"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 data(stream_id: stream_id, data: "some data", flags: set_flags(:data, [])),
                 headers(
                   stream_id: stream_id,
                   hbf: trailing_hbf1,
                   flags: set_flags(:headers, [:end_stream])
                 ),
                 continuation(
                   stream_id: stream_id,
                   hbf: trailing_hbf2,
                   flags: set_flags(:continuation, [:end_headers])
                 )
               ])

      assert [
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:data, ^ref, "some data"},
               {:headers, ^ref, trailing_headers},
               {:done, ^ref}
             ] = responses

      assert trailing_headers == [{"x-trailing", "some value"}]
      assert HTTP2.open?(conn)
    end

    test "sent by the server directly after the \"opening\" headers (without data in between)",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf = encode_headers([{":status", "200"}])
      trailing_hbf = encode_headers([{"x-trailing", "some value"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: trailing_hbf,
                   flags: set_flags(:headers, [:end_stream, :end_headers])
                 )
               ])

      assert [
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:headers, ^ref, [{"x-trailing", "some value"}]},
               {:done, ^ref}
             ] = responses

      assert HTTP2.open?(conn)
    end

    test "with a push promise request", %{conn: conn} do
      promised_stream_id = 4

      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      promised_hbf = encode_headers([{":method", "GET"}])
      hbf1 = encode_headers([{":status", "200"}])
      hbf2 = encode_headers([{":status", "200"}])
      trailing_hbf = encode_headers([{"x-trailing", "some value"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 push_promise(
                   stream_id: stream_id,
                   hbf: promised_hbf,
                   promised_stream_id: promised_stream_id,
                   flags: set_flags(:push_promise, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: hbf1,
                   flags: set_flags(:headers, [:end_stream, :end_headers])
                 ),
                 # Promised stream with trailing headers.
                 headers(
                   stream_id: promised_stream_id,
                   hbf: hbf2,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: promised_stream_id,
                   hbf: trailing_hbf,
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert [
               {:push_promise, ^ref, promised_ref, [{":method", "GET"}]},
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:done, ^ref},
               {:status, promised_ref, 200},
               {:headers, promised_ref, []},
               {:headers, promised_ref, [{"x-trailing", "some value"}]},
               {:done, promised_ref}
             ] = responses

      assert HTTP2.open?(conn)
    end

    test "protocol error if trailing headers don't have END_STREAM set", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf = encode_headers([{":status", "200"}])
      trailing_hbf = encode_headers([{"x-trailing", "some value"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 data(stream_id: stream_id, data: "some data", flags: set_flags(:data, [])),
                 headers(
                   stream_id: stream_id,
                   hbf: trailing_hbf,
                   flags: set_flags(:headers, [:end_headers])
                 )
               ])

      assert [
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:data, ^ref, "some data"},
               {:error, ^ref, error}
             ] = responses

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "trailing headers didn't set the END_STREAM flag"

      assert HTTP2.open?(conn)
    end

    test "unallowed headers are removed", %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf = encode_headers([{":status", "200"}])

      # Note that headers are lowercase in HTTP/2 responses because the spec
      # says so.
      trailing_hbf = encode_headers([{"x-trailing", "value"}, {"host", "example.com"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: trailing_hbf,
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert [
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:headers, ^ref, trailing_headers},
               {:done, ^ref}
             ] = responses

      assert trailing_headers == [{"x-trailing", "value"}]
      assert HTTP2.open?(conn)
    end
  end

  describe "server pushes" do
    test "a PUSH_PROMISE frame and a few CONTINUATION frames are received",
         %{conn: conn} do
      promised_stream_id = 4

      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      # Promised headers.
      headers = [{":method", "GET"}, {"foo", "bar"}, {"baz", "bong"}]

      <<hbf1::1-bytes, hbf2::1-bytes, hbf3::binary>> = encode_headers(headers)

      # Normal headers.
      hbf = encode_headers([{":status", "200"}, {"push", "promise"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 push_promise(
                   stream_id: stream_id,
                   hbf: hbf1,
                   promised_stream_id: promised_stream_id
                 ),
                 continuation(stream_id: stream_id, hbf: hbf2),
                 continuation(
                   stream_id: stream_id,
                   hbf: hbf3,
                   flags: set_flags(:continuation, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_stream, :end_headers])
                 )
               ])

      assert [
               {:push_promise, ^ref, promised_ref, headers},
               {:status, ^ref, 200},
               {:headers, ^ref, [{"push", "promise"}]},
               {:done, ^ref}
             ] = responses

      assert is_reference(promised_ref)
      assert headers == [{":method", "GET"}, {"foo", "bar"}, {"baz", "bong"}]

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: promised_stream_id,
                   hbf: hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 data(
                   stream_id: promised_stream_id,
                   data: "hello",
                   flags: set_flags(:data, [:end_stream])
                 )
               ])

      assert [
               {:status, ^promised_ref, 200},
               {:headers, ^promised_ref, [{"push", "promise"}]},
               {:data, ^promised_ref, "hello"},
               {:done, ^promised_ref}
             ] = responses

      assert HTTP2.open?(conn)
    end

    @tag connect_options: [enable_async_settings: true, client_settings: [enable_push: false]]
    test "receiving PUSH_PROMISE frame when SETTINGS_ENABLE_PUSH is false causes an error",
         %{conn: conn} do
      {:ok, conn} = wait_for_settings(conn)
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      hbf = encode_headers([{":method", "GET"}])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 push_promise(
                   stream_id: stream_id,
                   hbf: hbf,
                   promised_stream_id: 4,
                   flags: set_flags(:push_promise, [:end_headers])
                 )
               ])

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "received PUSH_PROMISE frame when SETTINGS_ENABLE_PUSH was false"

      assert_recv_frames(conn, [goaway(error_code: :protocol_error)])
      refute HTTP2.open?(conn)
    end

    test "if the server tries to reserve an already existing stream the connection errors",
         %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      promised_headers_hbf = encode_headers([{":method", "GET"}])
      normal_headers_hbf = encode_headers([{":status", "200"}])

      assert {:error, %HTTP2{} = conn, error, _responses} =
               stream_frames(conn, [
                 push_promise(
                   stream_id: stream_id,
                   hbf: promised_headers_hbf,
                   promised_stream_id: 4,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 push_promise(
                   stream_id: stream_id,
                   hbf: promised_headers_hbf,
                   promised_stream_id: 4,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: normal_headers_hbf,
                   flags: set_flags(:headers, [:end_stream, :end_headers])
                 )
               ])

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "stream with ID 4 already exists and can't be reserved by the server"

      refute HTTP2.open?(conn)
    end

    @tag connect_options: [
           enable_async_settings: true,
           client_settings: [max_concurrent_streams: 1]
         ]
    test "if the server reaches the max number of client streams, the client sends an error",
         %{conn: conn} do
      {:ok, conn} = wait_for_settings(conn)
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      promised_headers_hbf = encode_headers([{":method", "GET"}])
      normal_headers_hbf = encode_headers([{":status", "200"}])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 push_promise(
                   stream_id: stream_id,
                   hbf: promised_headers_hbf,
                   promised_stream_id: 4,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 push_promise(
                   stream_id: stream_id,
                   hbf: promised_headers_hbf,
                   promised_stream_id: 6,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: stream_id,
                   hbf: normal_headers_hbf,
                   flags: set_flags(:headers, [:end_stream, :end_headers])
                 )
               ])

      assert [
               {:push_promise, ^ref, promised_ref1, _},
               {:push_promise, ^ref, _promised_ref2, _},
               {:status, ^ref, 200},
               {:headers, ^ref, []},
               {:done, ^ref}
             ] = responses

      assert_recv_frames(conn, [
        rst_stream(stream_id: ^stream_id, error_code: :no_error)
      ])

      # Here we send headers for the two promised streams. Note that neither of the
      # header frames have the END_STREAM flag set otherwise we close the streams and
      # they don't count towards the open stream count.
      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: 4,
                   hbf: normal_headers_hbf,
                   flags: set_flags(:headers, [:end_headers])
                 ),
                 headers(
                   stream_id: 6,
                   hbf: normal_headers_hbf,
                   flags: set_flags(:headers, [:end_headers])
                 )
               ])

      assert [{:status, ^promised_ref1, 200}, {:headers, ^promised_ref1, []}] = responses

      assert_recv_frames(conn, [
        rst_stream(stream_id: 6, error_code: :refused_stream)
      ])

      assert HTTP2.open?(conn)
    end
  end

  describe "misbehaving server" do
    test "sends a frame with the wrong stream id", %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers()])

      data = IO.iodata_to_binary(encode_raw(_ping = 0x06, 0x00, 3, <<0::64>>))
      assert {:error, %HTTP2{} = conn, error, []} = HTTP2.stream(conn, {:ssl, conn.socket, data})

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "frame :ping only allowed at the connection level"

      assert_recv_frames(conn, [goaway(error_code: :protocol_error)])

      refute HTTP2.open?(conn)
    end

    test "sends a frame with a bad size", %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers()])

      # Payload should be 8 bytes long, but is empty here.
      data = IO.iodata_to_binary(encode_raw(_ping = 0x06, 0x00, 3, <<>>))

      assert {:error, %HTTP2{} = conn, error, []} = HTTP2.stream(conn, {:ssl, conn.socket, data})

      assert_http2_error error, {:frame_size_error, debug_data}
      assert debug_data =~ "error with size of frame: :ping"

      assert_recv_frames(conn, [goaway(error_code: :frame_size_error)])
      refute HTTP2.open?(conn)
    end

    test "sends a frame on a stream with a stream ID bigger than client's biggest",
         %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      bad_stream_id = stream_id + 10

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 {:headers, bad_stream_id, [{":status", "200"}], [:end_headers]}
               ])

      assert_http2_error error, {:protocol_error, debug_data}
      assert debug_data =~ "frame with stream ID #{bad_stream_id} has not been opened yet"

      assert_recv_frames(conn, [goaway(error_code: :protocol_error)])

      refute HTTP2.open?(conn)
    end
  end

  describe "flow control" do
    test "client sends data that goes over window size of a stream/connection when streaming",
         %{conn: conn} do
      # First we decrease the connection size by 5 bytes, so that the connection window
      # size is smaller than the stream window size.
      {conn, _ref} = open_request(conn, "XXXXX")

      assert_recv_frames(conn, [headers(), data()])

      # Then we open a streaming request.
      {conn, ref} = open_request(conn, :stream)

      assert_recv_frames(conn, [headers()])

      data = :binary.copy(<<0>>, HTTP2.get_window_size(conn, {:request, ref}) + 1)
      assert {:error, %HTTP2{} = conn, error} = HTTP2.stream_request_body(conn, ref, data)
      assert_http2_error error, {:exceeds_window_size, :request, window_size}
      assert is_integer(window_size) and window_size >= 0

      data = :binary.copy(<<0>>, HTTP2.get_window_size(conn, :connection) + 1)
      assert {:error, %HTTP2{} = conn, error} = HTTP2.stream_request_body(conn, ref, data)
      assert_http2_error error, {:exceeds_window_size, :connection, window_size}
      assert is_integer(window_size) and window_size >= 0

      assert HTTP2.open?(conn)
    end

    @tag server_settings: [initial_window_size: 1]
    @tag connect_options: [enable_async_settings: true]
    test "if client's request goes over window size, no HEADER frames are sent",
         %{conn: conn} do
      {:ok, conn} = wait_for_settings(conn)
      expected_window_size = HTTP2.get_window_size(conn, :connection)
      assert {:error, %HTTP2{} = conn, error} = HTTP2.request(conn, "GET", "/", [], "XX")
      assert_http2_error error, {:exceeds_window_size, :request, 1}
      assert HTTP2.open?(conn)
      assert HTTP2.open_request_count(conn) == 0
      assert HTTP2.get_window_size(conn, :connection) == expected_window_size
      refute_received {:ssl, _sock, _data}
    end

    test "server sends a WINDOW_UPDATE with too big of a size on a stream",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 window_update(
                   stream_id: stream_id,
                   window_size_increment: _max_window_size = 2_147_483_647
                 )
               ])

      assert [{:error, ^ref, error}] = responses
      assert_http2_error error, {:flow_control_error, debug_data}
      assert debug_data =~ "window size too big"

      assert_recv_frames(conn, [
        rst_stream(stream_id: ^stream_id, error_code: :flow_control_error)
      ])

      assert HTTP2.open?(conn)
    end

    test "server sends a WINDOW_UPDATE with too big of a size on the connection level",
         %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: _stream_id)])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 window_update(
                   stream_id: 0,
                   window_size_increment: _max_window_size = 2_147_483_647
                 )
               ])

      assert_http2_error error, {:flow_control_error, debug_data}
      assert debug_data =~ "window size too big"

      assert_recv_frames(conn, [goaway(error_code: :flow_control_error)])

      refute HTTP2.open?(conn)
    end

    test "server violates client's max frame size", %{
      conn: conn
    } do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:error, %HTTP2{} = conn, error, []} =
               stream_frames(conn, [
                 data(stream_id: stream_id, data: :binary.copy(<<0>>, 100_000))
               ])

      assert_http2_error error, {:frame_size_error, debug_data}
      assert debug_data =~ "frame payload exceeds connection's max frame size"

      assert_recv_frames(conn, [goaway(error_code: :frame_size_error)])

      refute HTTP2.open?(conn)
    end

    test "client splits data automatically based on server's max frame size",
         %{conn: conn} do
      max_frame_size = HTTP2.get_server_setting(conn, :max_frame_size)

      body = :binary.copy(<<0>>, max_frame_size + 1)
      {conn, _ref} = open_request(conn, body)

      assert_recv_frames(conn, [
        headers(stream_id: stream_id),
        data(stream_id: stream_id, flags: flags1, data: data1),
        data(stream_id: stream_id, flags: flags2, data: data2)
      ])

      assert flags1 == set_flags(:data, [])
      assert data1 == :binary.copy(<<0>>, max_frame_size)

      assert flags2 == set_flags(:data, [:end_stream])
      assert data2 == <<0>>

      assert HTTP2.open?(conn)
    end

    test "window size of the connection and single requests can be read with get_window_size/2",
         %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)

      initial_conn_window_size = HTTP2.get_window_size(conn, :connection)
      initial_request_window_size = HTTP2.get_window_size(conn, {:request, ref})

      assert is_integer(initial_conn_window_size) and initial_conn_window_size > 0
      assert is_integer(initial_request_window_size) and initial_request_window_size > 0

      body_chunk = "hello"
      {:ok, conn} = HTTP2.stream_request_body(conn, ref, body_chunk)

      new_conn_window_size = HTTP2.get_window_size(conn, :connection)
      new_request_window_size = HTTP2.get_window_size(conn, {:request, ref})

      assert new_conn_window_size == initial_conn_window_size - byte_size(body_chunk)
      assert new_request_window_size == initial_request_window_size - byte_size(body_chunk)
    end

    test "if the server sends an empty DATA frame, we don't send WINDOW_UPDATE back",
         %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert {:ok, %HTTP2{} = _conn, responses} =
               stream_frames(conn, [
                 data(stream_id: stream_id, data: "", flags: set_flags(:data, [:end_stream]))
               ])

      assert_recv_frames(conn, [
        rst_stream(stream_id: ^stream_id, error_code: :no_error)
      ])

      assert responses == [{:data, ref, ""}, {:done, ref}]
    end

    test "get_window_size/2 raises if the request is not found", %{conn: conn} do
      assert_raise ArgumentError, ~r/request with request reference .+ was not found/, fn ->
        HTTP2.get_window_size(conn, {:request, make_ref()})
      end
    end
  end

  describe "settings" do
    @tag connect_options: [enable_async_settings: true]
    test "put_settings/2 can be used to send settings to server", %{
      conn: conn
    } do
      {:ok, conn} = wait_for_settings(conn)
      {:ok, conn} = HTTP2.put_settings(conn, max_concurrent_streams: 123)

      assert_recv_frames(conn, [settings() = frame])
      assert settings(frame, :params) == [max_concurrent_streams: 123]
      assert settings(frame, :flags) == set_flags(:settings, [])

      assert {:ok, %HTTP2{} = conn, [:settings_ack]} =
               stream_frames(conn, [
                 settings(flags: set_flags(:settings, [:ack]), params: [])
               ])

      assert HTTP2.open?(conn)
    end

    test "put_settings/2 fails with unknown settings", %{conn: conn} do
      assert_raise ArgumentError, ":header_table_size must be an integer, got: :oops", fn ->
        HTTP2.put_settings(conn, header_table_size: :oops)
      end

      assert_raise ArgumentError, "unknown setting parameter :oops", fn ->
        HTTP2.put_settings(conn, oops: 1)
      end
    end

    test "get_server_setting/2 can be used to read server settings", %{conn: conn} do
      assert HTTP2.get_server_setting(conn, :max_concurrent_streams) == 100
      assert HTTP2.get_server_setting(conn, :enable_push) == true
      assert HTTP2.get_server_setting(conn, :enable_connect_protocol) == false
    end

    test "get_server_setting/2 fails with unknown settings", %{conn: conn} do
      assert_raise ArgumentError, "unknown HTTP/2 setting: :unknown", fn ->
        HTTP2.get_server_setting(conn, :unknown)
      end
    end

    @tag connect_options: [enable_async_settings: true]
    test "server can update the initial window size and affect open streams",
         %{conn: conn} do
      {:ok, conn} = wait_for_settings(conn)
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers()])

      {:ok, %HTTP2{} = conn, [:settings]} =
        stream_frames(conn, [settings(params: [initial_window_size: 100])])

      assert HTTP2.get_server_setting(conn, :initial_window_size) == 100

      # This stream is half_closed_local, so there's not point in updating its window size since
      # we won't send anything on it anymore.
      assert HTTP2.get_window_size(conn, {:request, ref}) == 65535
    end

    # TODO: We're skipping this test for now because we need to find a good way
    # to assert on the errors that might be returned by HTTP2.connect/4. Right
    # now the connect/4 calls happens when setting up the connection to the test
    # server and we assert that a successful connection is established in that code.
    # An example of an invalid setting is "max_frame_size: 1".
    @tag :skip
    test "protocol error when server sends an invalid setting"
  end

  describe "stream_request_body/3" do
    test "streaming a request", %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)
      assert {:ok, conn} = HTTP2.stream_request_body(conn, ref, "foo")
      assert {:ok, conn} = HTTP2.stream_request_body(conn, ref, "bar")
      assert {:ok, conn} = HTTP2.stream_request_body(conn, ref, :eof)

      assert_recv_frames(conn, [
        headers(stream_id: stream_id) = headers,
        data(stream_id: stream_id, data: "foo") = data1,
        data(stream_id: stream_id, data: "bar") = data2,
        data(stream_id: stream_id, data: "") = data3
      ])

      refute flag_set?(headers(headers, :flags), :headers, :end_stream)
      refute flag_set?(data(data1, :flags), :data, :end_stream)
      refute flag_set?(data(data2, :flags), :data, :end_stream)
      assert flag_set?(data(data3, :flags), :data, :end_stream)

      assert HTTP2.open?(conn)
    end

    test "streaming a request on a request that wasn't opened with :stream errors out",
         %{conn: conn} do
      {conn, ref} = open_request(conn)

      assert HTTP2.open_request_count(conn) == 1
      expected_window_size = HTTP2.get_window_size(conn, :connection)

      assert {:error, %HTTP2{} = conn, error} = HTTP2.stream_request_body(conn, ref, "foo")
      assert_http2_error error, :request_is_not_streaming

      assert HTTP2.get_window_size(conn, :connection) == expected_window_size
      assert HTTP2.open_request_count(conn) == 1

      assert HTTP2.open?(conn)
    end

    test "streaming to an unknown request returns an error", %{conn: conn} do
      assert HTTP2.open_request_count(conn) == 0
      expected_window_size = HTTP2.get_window_size(conn, :connection)

      assert {:error, %HTTP2{} = conn, error} = HTTP2.stream_request_body(conn, make_ref(), "x")
      assert_http2_error error, :unknown_request_to_stream

      assert HTTP2.get_window_size(conn, :connection) == expected_window_size
      assert HTTP2.open_request_count(conn) == 0
      assert HTTP2.open?(conn)
    end

    test "streaming a request with trailing headers", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn, :stream)

      # Using 1000 headers will go over the default max_frame_size so that the
      # HEADERS frame for the trailing headers will also be split into a HEADERS
      # plus CONTINUATION frames.
      trailing_headers = for index <- 1..1000, do: {"my-trailing-#{index}", "value"}

      assert {:ok, _conn} = HTTP2.stream_request_body(conn, ref, {:eof, trailing_headers})

      assert_recv_frames(conn, [
        headers(stream_id: stream_id) = headers,
        headers(stream_id: stream_id, hbf: trailing_hbf1) = trailing_headers1,
        continuation(stream_id: stream_id, hbf: trailing_hbf2) = trailing_headers2
      ])

      assert flag_set?(headers(headers, :flags), :headers, :end_headers)
      refute flag_set?(headers(headers, :flags), :headers, :end_stream)

      refute flag_set?(headers(trailing_headers1, :flags), :headers, :end_headers)
      assert flag_set?(headers(trailing_headers1, :flags), :headers, :end_stream)

      assert flag_set?(continuation(trailing_headers2, :flags), :continuation, :end_headers)

      assert decode_headers(trailing_hbf1 <> trailing_hbf2) == trailing_headers
    end

    test "unallowed trailing headers cause an error", %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)

      assert HTTP2.open_request_count(conn) == 1
      expected_window_size = HTTP2.get_window_size(conn, :connection)

      trailing_headers = [{"x-trailing", "value"}, {"Host", "example.com"}]

      assert {:error, %HTTP2{} = _conn, error} =
               HTTP2.stream_request_body(conn, ref, {:eof, trailing_headers})

      assert_http2_error error, {:unallowed_trailing_header, {"host", "example.com"}}

      assert HTTP2.get_window_size(conn, :connection) == expected_window_size
      assert HTTP2.open_request_count(conn) == 1
    end

    test "streaming to a closed connection returns an error", %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)
      {:ok, closed_conn} = HTTP2.close(conn)
      assert {:error, conn, error} = HTTP2.stream_request_body(closed_conn, ref, :eof)
      assert_http2_error error, :closed
      refute HTTP2.open?(conn)
    end

    test "streaming to a connection that got GOAWAY returns an error", %{conn: conn} do
      {conn, ref} = open_request(conn, :stream)

      assert_recv_frames [headers(stream_id: stream_id)]

      assert {:error, conn, _goaway_error, _responses} =
               stream_frames(conn, [
                 goaway(
                   last_stream_id: stream_id,
                   error_code: :protocol_error,
                   debug_data: "debug data"
                 )
               ])

      assert {:error, _conn, error} = HTTP2.stream_request_body(conn, ref, :eof)
      assert_http2_error error, :closed_for_writing
    end
  end

  describe "open_request_count/1" do
    test "returns the number of client-initiated open streams", %{
      conn: conn
    } do
      assert HTTP2.open_request_count(conn) == 0

      {conn, _ref} = open_request(conn)
      assert HTTP2.open_request_count(conn) == 1

      {conn, _ref} = open_request(conn)
      assert HTTP2.open_request_count(conn) == 2

      assert_recv_frames(conn, [headers(stream_id: stream_id1), headers()])

      assert {:ok, %HTTP2{} = conn, _responses} =
               stream_frames(conn, [
                 headers(
                   stream_id: stream_id1,
                   hbf: encode_headers([{":status", "200"}]),
                   flags: set_flags(:headers, [:end_headers, :end_stream])
                 )
               ])

      assert HTTP2.open_request_count(conn) == 1
    end
  end

  describe "connection modes" do
    @tag connect_options: [mode: :passive]
    test "starting a connection with :passive mode and using recv/3", %{
      conn: conn
    } do
      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      data =
        encode_frames([
          headers(
            stream_id: stream_id,
            hbf: encode_headers([{":status", "200"}]),
            flags: set_flags(:headers, [:end_headers, :end_stream])
          )
        ])

      :ok = send_data(conn, data)

      assert {:ok, conn, responses} = HTTP2.recv(conn, 0, 100)

      assert responses == [{:status, ref, 200}, {:headers, ref, []}, {:done, ref}]

      assert HTTP2.open?(conn)
    end

    test "changing the mode of a connection with set_mode/2", %{
      conn: conn
    } do
      assert_raise ArgumentError, ~r"^can't use recv/3", fn ->
        HTTP2.recv(conn, 0, 100)
      end

      assert {:ok, %HTTP2{} = conn} = HTTP2.set_mode(conn, :passive)

      {conn, ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      headers_frames = [
        headers(
          stream_id: stream_id,
          hbf: encode_headers([{":status", "200"}]),
          flags: set_flags(:headers, [:end_headers, :end_stream])
        )
      ]

      data = encode_frames(headers_frames)

      :ok = send_data(conn, data)

      assert {:ok, conn, responses} = HTTP2.recv(conn, 0, 100)

      assert responses == [
               {:status, ref, 200},
               {:headers, ref, []},
               {:done, ref}
             ]

      assert {:ok, %HTTP2{} = conn} = HTTP2.set_mode(conn, :active)

      assert_raise ArgumentError, ~r"^can't use recv/3", fn ->
        HTTP2.recv(conn, 0, 100)
      end

      assert HTTP2.open?(conn)
    end
  end

  describe "ping" do
    test "if we send a PING we then get a :pong reply", %{
      conn: conn
    } do
      assert {:ok, conn, ref} = HTTP2.ping(conn)

      ping_frame = recv_frames(conn, 1)

      assert [ping(opaque_data: opaque_data)] = ping_frame

      assert {:ok, %HTTP2{} = conn, responses} =
               stream_frames(conn, [
                 ping(flags: set_flags(:ping, [:ack]), opaque_data: opaque_data)
               ])

      assert responses == [{:pong, ref}]

      assert HTTP2.open?(conn)
    end

    test "if the server sends a PING we reply automatically", %{
      conn: conn
    } do
      opaque_data = :binary.copy(<<0>>, 8)
      assert {:ok, %HTTP2{}, []} = stream_frames(conn, [ping(opaque_data: opaque_data)])
      assert [ping(opaque_data: ^opaque_data)] = recv_frames(conn, 1)
    end

    test "if the server sends a PING ack but no PING requests are pending we emit a warning",
         %{conn: conn} do
      opaque_data = :binary.copy(<<0>>, 8)

      assert capture_log(fn ->
               assert {:ok, %HTTP2{}, []} =
                        stream_frames(conn, [
                          ping(opaque_data: opaque_data, flags: set_flags(:ping, [:ack]))
                        ])
             end) =~ "Received PING ack but no PING requests are pending"
    end

    test "if the server sends a PING ack but no PING requests match we emit a warning",
         %{conn: conn} do
      assert {:ok, conn, _ref} = HTTP2.ping(conn, <<1, 2, 3, 4, 5, 6, 7, 8>>)
      opaque_data = <<1, 2, 3, 4, 5, 6, 7, 0>>

      assert capture_log(fn ->
               assert {:ok, %HTTP2{}, []} =
                        stream_frames(conn, [
                          ping(opaque_data: opaque_data, flags: set_flags(:ping, [:ack]))
                        ])
             end) =~ "Received PING ack that doesn't match next PING request in the queue"
    end
  end

  describe "stream priority" do
    test "PRIORITY frames are ignored", %{conn: conn} do
      {conn, _ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      assert capture_log(fn ->
               assert {:ok, %HTTP2{} = conn, []} =
                        stream_frames(conn, [
                          priority(
                            stream_id: stream_id,
                            exclusive?: false,
                            stream_dependency: 1,
                            weight: 1
                          )
                        ])

               assert HTTP2.open?(conn)
             end) =~ "Ignoring PRIORITY frame"
    end
  end

  describe "controlling process" do
    test "changing the controlling process with controlling_process/2", %{
      conn: conn
    } do
      parent = self()
      ref = make_ref()

      new_pid =
        spawn_link(fn ->
          receive do
            message ->
              send(parent, {ref, message})
              Process.sleep(:infinity)
          end
        end)

      {conn, request_ref} = open_request(conn)

      assert_recv_frames(conn, [headers(stream_id: stream_id)])

      data =
        encode_frames([
          headers(
            stream_id: stream_id,
            hbf: encode_headers([{":status", "200"}]),
            flags: set_flags(:headers, [:end_headers, :end_stream])
          )
        ])

      {:ok, %HTTP2{} = conn} = HTTP2.controlling_process(conn, new_pid)

      :ok = send_data(conn, data)

      assert_receive {^ref, message}
      assert {:ok, %HTTP2{} = conn, responses} = HTTP2.stream(conn, message)

      assert responses == [
               {:status, request_ref, 200},
               {:headers, request_ref, []},
               {:done, request_ref}
             ]

      assert HTTP2.open?(conn)
    end
  end

  defp start_connection(context) do
    default_connect_options = [transport_opts: [verify: :verify_none]]

    context_connect_options = context[:connect_options] || []
    context_server_settings = context[:server_settings] || []

    connect_options = Keyword.merge(default_connect_options, context_connect_options)

    send_settings_delay = Enum.random(0..10)

    args = [
      test_runner: self(),
      connect_options: connect_options,
      server_settings: context_server_settings,
      send_settings_delay: send_settings_delay
    ]

    {:ok, server_pid} = start_http2_server(args)

    port =
      receive do
        {:port, port} ->
          port
      after
        1000 ->
          flunk("did not get server port in time!")
      end

    assert {:ok, conn} = HTTP2.connect(:https, "localhost", port, connect_options)
    assert %HTTP2{} = conn

    enable_async_settings = Keyword.get(context_connect_options, :enable_async_settings, false)

    conn =
      if enable_async_settings do
        conn
      else
        # Wait for SETTINGS here.
        if context_connect_options[:mode] == :passive do
          assert {:ok, %HTTP2{} = conn, []} = HTTP2.recv(conn, 0, 100)
          conn
        else
          assert_receive message, 100
          assert {:ok, %HTTP2{} = conn, []} = HTTP2.stream(conn, message)
          conn
        end
      end

    conn = put_server_pid(conn, server_pid)

    [conn: conn, send_settings_delay: send_settings_delay]
  end

  defp recv_frames(conn, n) do
    receive do
      {:frames_available, c} when c >= n ->
        TestServer.recv_next_frames(get_server_pid(conn), n)

      {:frames_available, c} when c < n ->
        recv_frames(conn, n)
    after
      1000 ->
        flunk("did not decode #{n} frames in 1000ms")
    end
  end

  defp stream_frames(conn, frames) do
    data = encode_frames(frames)
    HTTP2.stream(conn, {:ssl, conn.socket, data})
  end

  @spec encode_frames([frame :: term(), ...]) :: binary()
  defp encode_frames(frames) when is_list(frames) and frames != [] do
    {data, _final_encode_table} =
      Enum.map_reduce(frames, HPAX.new(4096), fn
        {frame_type, stream_id, headers, flags}, enc_tbl
        when frame_type in [:headers, :push_promise] ->
          {enc_tbl, hbf} = encode_headers(enc_tbl, headers)
          flags = set_flags(frame_type, flags)
          frame = headers(stream_id: stream_id, hbf: hbf, flags: flags)
          {encode(frame), enc_tbl}

        frame, enc_tbl ->
          {encode(frame), enc_tbl}
      end)

    IO.iodata_to_binary(data)
  end

  @spec encode_headers(Mint.Types.headers()) :: binary()
  defp encode_headers(headers) when is_list(headers) do
    headers = for {name, value} <- headers, do: {:store_name, name, value}
    {hbf, _encode_table} = HPAX.encode(headers, HPAX.new(4096))
    IO.iodata_to_binary(hbf)
  end

  @spec encode_headers(binary(), Mint.Types.headers()) :: binary()
  defp encode_headers(encode_table, headers) when is_list(headers) do
    headers = for {name, value} <- headers, do: {:store_name, name, value}
    {hbf, encode_table} = HPAX.encode(headers, encode_table)
    {encode_table, IO.iodata_to_binary(hbf)}
  end

  @spec decode_headers(binary()) :: Mint.Types.headers()
  def decode_headers(hbf) when is_binary(hbf) do
    decode_table = HPAX.new(4096)
    assert {:ok, headers, _decode_table} = HPAX.decode(hbf, decode_table)
    headers
  end

  defp open_request(conn, body \\ nil) do
    assert {:ok, %HTTP2{} = conn, ref} = HTTP2.request(conn, "GET", "/", [], body)
    assert is_reference(ref)
    {conn, ref}
  end

  defp start_http2_server(args) do
    http2_server_spec = TestServer.child_spec(args)
    http2_server_spec = Map.put(http2_server_spec, :restart, :transient)
    server_pid = start_supervised!(http2_server_spec)
    {:ok, server_pid}
  end

  defp wait_for_settings(conn0) do
    conn1 =
      receive do
        msg ->
          {:ok, c, [:settings]} = Mint.HTTP.stream(conn0, msg)
          c
      after
        1000 ->
          flunk("did not receive expected :settings frame in 1s")
      end

    receive do
      msg ->
        {:ok, c, [:settings_ack]} = Mint.HTTP.stream(conn1, msg)
        {:ok, c}
    after
      1000 ->
        flunk("did not receive expected :settings_ack frame in 1s")
    end
  end

  defp get_server_pid(conn) do
    HTTP2.get_private(conn, :server_pid)
  end

  defp put_server_pid(conn, server_pid) do
    HTTP2.put_private(conn, :server_pid, server_pid)
  end

  defp send_data(conn, data) do
    :ok = TestServer.send_data(get_server_pid(conn), data)
  end
end
