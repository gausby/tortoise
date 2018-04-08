defmodule Tortoise.Connection.Receiver do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package
  alias Tortoise.Connection.{Transmitter, Controller}

  defstruct connection: %Package.Connect{client_id: "tortoise"},
            host: 'localhost',
            port: 1883,
            socket: nil,
            buffer: <<>>

  def start_link({_protocol, host, port} = _server, opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    data = %__MODULE__{
      connection: %Package.Connect{
        user_name: opts[:user_name],
        password: opts[:password],
        clean_session: Keyword.get(opts, :clean_session, true),
        keep_alive: Keyword.get(opts, :keep_session, 60),
        client_id: client_id,
        will: Keyword.get(opts, :will, %Package.Publish{})
      },
      host: host,
      port: port,
      socket: Keyword.get(opts, :socket, nil)
    }

    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  defp via_name(pid) when is_pid(pid), do: pid

  defp via_name(client_id) do
    key = {__MODULE__, client_id}
    {:via, Registry, {Registry.Tortoise, key}}
  end

  def init(%__MODULE__{} = data) do
    next_actions = [{:next_event, :internal, :connect}]
    {:ok, :disconnected, data, next_actions}
  end

  # dropped connection, should we try to reconnect ?
  def handle_event(:info, {:tcp_closed, socket}, state, %{socket: socket} = data) do
    case state do
      {:connected, :awaiting_connack} ->
        {:stop, :failed_to_receive_connack}

      otherwise ->
        IO.inspect("lost connection, reason: #{inspect(otherwise)}")
        {:next_state, :disconnected, %{data | socket: nil}}
    end
  end

  # receiving data on the tcp connection
  def handle_event(:info, {:tcp, socket, tcp_data}, _, %{socket: socket} = data) do
    next_actions = [
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    new_data = %{data | buffer: <<data.buffer::binary, tcp_data::binary>>}
    {:keep_state, new_data, next_actions}
  end

  def handle_event(:internal, :pass_socket_to_transmitter, {:connected, _}, data) do
    :ok = Transmitter.handle_socket(data.connection.client_id, data.socket)
    :keep_state_and_data
  end

  # activate network socket for incoming traffic
  def handle_event(:internal, :activate_socket, _state_name, data) do
    :ok = :inet.setopts(data.socket, active: :once)
    :keep_state_and_data
  end

  def handle_event(:internal, :connect, :disconnected, data) do
    case :gen_tcp.connect(data.host, data.port, [:binary, packet: :raw]) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, Package.encode(data.connection))
        new_data = %{data | socket: socket}
        {:next_state, {:connected, :awaiting_connack}, new_data}

      {:error, :econnrefused} ->
        {:stop, :econnrefused}
    end
  end

  # consume buffer
  def handle_event(:internal, :consume_buffer, _state_name, %{buffer: <<>>}) do
    :keep_state_and_data
  end

  def handle_event(
        :internal,
        :consume_buffer,
        {:connected, :awaiting_connack},
        %{buffer: buffer} = data
      )
      when byte_size(buffer) >= 4 do
    <<package::binary-size(4), rest::binary>> = data.buffer

    case Package.decode(package) do
      %Package.Connack{status: :accepted, session_present: false} ->
        next_state = {:connected, :receiving_fixed_header}

        next_actions = [
          {:next_event, :internal, :pass_socket_to_transmitter},
          {:next_event, :internal, :consume_buffer}
        ]

        new_data = %{data | buffer: rest}
        {:next_state, next_state, new_data, next_actions}

      %Package.Connack{status: :accepted, session_present: true} ->
        raise "todo, implement handling of existing sessions"

      %Package.Connack{status: {:refused, reason}} ->
        {:stop, reason}
    end
  end

  # consuming message
  def handle_event(
        :internal,
        :consume_buffer,
        {:connected, {:receiving_variable, length}},
        %__MODULE__{buffer: buffer} = data
      )
      when byte_size(buffer) >= length do
    <<package::binary-size(length), rest::binary>> = buffer
    next_state = {:connected, :receiving_fixed_header}

    next_actions = [
      {:next_event, :internal, {:emit, package}},
      {:next_event, :internal, :consume_buffer}
    ]

    new_data = %{data | buffer: rest}
    {:next_state, next_state, new_data, next_actions}
  end

  def handle_event(:internal, :consume_buffer, {:connected, {:receiving_variable, _, _}}, _data) do
    # await more bytes
    :keep_state_and_data
  end

  # what should happen here?
  def handle_event(:internal, :consume_buffer, :disconnected, _data) do
    # we might be disconnected, but could we have data in the buffer still ?
    # perhaps we should consume that
    :keep_state_and_data
  end

  # receiving fixed header
  def handle_event(:internal, :consume_buffer, {:connected, :receiving_fixed_header}, data) do
    case parse_fixed_header(data.buffer) do
      {:ok, length} ->
        new_state = {:connected, {:receiving_variable, length}}
        next_actions = [{:next_event, :internal, :consume_buffer}]
        {:next_state, new_state, data, next_actions}

      :cont ->
        :keep_state_and_data

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_event(:internal, {:emit, package}, _, data) do
    :ok = Controller.handle_incoming(data.connection.client_id, package)
    :keep_state_and_data
  end

  defp parse_fixed_header(<<_::8, 0::1, length::7, _::binary>>) do
    {:ok, length + 2}
  end

  # 2 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 0::1, b::7, _::binary>>) do
    <<length::integer-size(14)>> = <<b::7, a::7>>
    {:ok, length + 3}
  end

  # 3 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 1::1, b::7, 0::1, c::7, _::binary>>) do
    <<length::integer-size(21)>> = <<c::7, b::7, a::7>>
    {:ok, length + 4}
  end

  # 4 bytes
  defp parse_fixed_header(<<_::8, 1::1, a::7, 1::1, b::7, 1::1, c::7, 0::1, d::7, _::binary>>) do
    <<length::integer-size(28)>> = <<d::7, c::7, b::7, a::7>>
    {:ok, length + 5}
  end

  defp parse_fixed_header(<<_::8, _::binary>>) do
    {:error, :invalid_header_length}
  end

  defp parse_fixed_header(_) do
    :cont
  end
end
