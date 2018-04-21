defmodule Tortoise.Connection.Receiver do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Connection.{Transmitter, Controller}

  defstruct client_id: nil, socket: nil, buffer: <<>>
  alias __MODULE__, as: State

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    data = %State{client_id: client_id}

    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  defp via_name(pid) when is_pid(pid), do: pid

  defp via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def handle_socket(client_id, {:tcp, socket}) do
    {:ok, pid} = GenStateMachine.call(via_name(client_id), {:handle_socket, socket})
    :ok = :gen_tcp.controlling_process(socket, pid)
  end

  def init(%State{} = data) do
    {:ok, :disconnected, data}
  end

  # Dropped connection: the connection process will monitor the
  # socket, so it should be busy trying to reestablish a connection at
  # this point
  def handle_event(:info, {:tcp_closed, socket}, _state, %{socket: socket} = data) do
    # should we empty the buffer?
    {:next_state, :disconnected, %{data | socket: nil}}
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

  # activate network socket for incoming traffic
  def handle_event(:internal, :activate_socket, _state_name, data) do
    :ok = :inet.setopts(data.socket, active: :once)
    :keep_state_and_data
  end

  # consume buffer
  def handle_event(:internal, :consume_buffer, _state_name, %{buffer: <<>>}) do
    :keep_state_and_data
  end

  # consuming message
  def handle_event(
        :internal,
        :consume_buffer,
        {:connected, {:receiving_variable, length}},
        %State{buffer: buffer} = data
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

      {:error, :invalid_header_length} ->
        {:stop, {:protocol_violation, :invalid_header_length}}
    end
  end

  def handle_event(:internal, {:emit, package}, _, data) do
    :ok = Controller.handle_incoming(data.client_id, package)
    :keep_state_and_data
  end

  def handle_event({:call, from}, {:handle_socket, socket}, :disconnected, data) do
    new_state = {:connected, :receiving_fixed_header}

    next_actions = [
      {:reply, from, {:ok, self()}},
      {:next_event, :internal, :pass_socket_to_transmitter},
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    # better reset the buffer
    {:next_state, new_state, %State{data | socket: socket, buffer: <<>>}, next_actions}
  end

  def handle_event(:internal, :pass_socket_to_transmitter, {:connected, _}, data) do
    :ok = Transmitter.handle_socket(data.client_id, data.socket)
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
