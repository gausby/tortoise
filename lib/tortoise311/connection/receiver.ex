defmodule Tortoise311.Connection.Receiver do
  @moduledoc false

  use GenStateMachine

  alias Tortoise311.Connection.Controller
  alias Tortoise311.Events

  defstruct client_id: nil, transport: nil, socket: nil, buffer: <<>>
  alias __MODULE__, as: State

  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)

    data = %State{client_id: client_id}

    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  defp via_name(client_id) do
    Tortoise311.Registry.via_name(__MODULE__, client_id)
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

  def handle_socket(client_id, {transport, socket}) do
    {:ok, pid} = GenStateMachine.call(via_name(client_id), {:handle_socket, transport, socket})

    case transport.controlling_process(socket, pid) do
      :ok ->
        :ok

      {:error, reason} when reason in [:closed, :einval] ->
        # todo, this is an edge case, figure out what to do here
        :ok
    end
  end

  @impl true
  def init(%State{} = data) do
    {:ok, :disconnected, data}
  end

  @impl true
  # receiving data on the network connection
  def handle_event(:info, {transport, socket, tcp_data}, _, %{socket: socket} = data)
      when transport in [:tcp, :ssl] do
    next_actions = [
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    new_data = %{data | buffer: <<data.buffer::binary, tcp_data::binary>>}
    {:keep_state, new_data, next_actions}
  end

  # Dropped connection: tell the connection process that it should
  # attempt to get a new network socket; unfortunately we cannot just
  # monitor the socket port in the connection process as a transport
  # method such as the SSL based one will pass an opaque data
  # structure around instead of a port that can be monitored.
  def handle_event(:info, {transport, socket}, _state, %{socket: socket} = data)
      when transport in [:tcp_closed, :ssl_closed] do
    # should we empty the buffer?

    # communicate to the world that we have dropped the connection
    :ok = Events.dispatch(data.client_id, :status, :down)
    {:next_state, :disconnected, %{data | socket: nil}}
  end

  # activate network socket for incoming traffic
  def handle_event(:internal, :activate_socket, _state_name, %State{transport: nil}) do
    {:stop, :no_transport}
  end

  def handle_event(:internal, :activate_socket, _state_name, data) do
    case data.transport.setopts(data.socket, active: :once) do
      :ok ->
        :keep_state_and_data

      {:error, :einval} ->
        # @todo consider if there could be a buffer we should drain at this point
        {:next_state, :disconnected, data}
    end
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

  def handle_event(:internal, :consume_buffer, {:connected, {:receiving_variable, _}}, _data) do
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

  def handle_event({:call, from}, {:handle_socket, transport, socket}, :disconnected, data) do
    new_state = {:connected, :receiving_fixed_header}

    next_actions = [
      {:reply, from, {:ok, self()}},
      {:next_event, :internal, :activate_socket},
      {:next_event, :internal, :consume_buffer}
    ]

    # better reset the buffer
    new_data = %State{data | transport: transport, socket: socket, buffer: <<>>}

    {:next_state, new_state, new_data, next_actions}
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

  defp parse_fixed_header(header) when byte_size(header) > 5 do
    {:error, :invalid_header_length}
  end

  defp parse_fixed_header(_) do
    :cont
  end
end
