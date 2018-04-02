defmodule Tortoise.Connection.Transmitter do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package

  defstruct client_id: nil, subscribers: %{}

  @type client_id :: pid() | term()

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    data = %__MODULE__{client_id: client_id}
    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
    {:via, Registry, reg_name(client_id)}
  end

  def reg_name(client_id) do
    {Registry.Tortoise, {__MODULE__, client_id}}
  end

  def stop(client_id) do
    GenStateMachine.stop(via_name(client_id))
  end

  def handle_socket(client_id, socket) do
    GenStateMachine.call(via_name(client_id), {:handle_socket, socket})
  end

  def subscribe(client_id) do
    GenStateMachine.call(via_name(client_id), :subscribe)
  end

  def unsubscribe(client_id) do
    pid = self()
    GenStateMachine.cast(via_name(client_id), {:unsubscribe, pid})
  end

  @doc false
  @spec subscribers(client_id()) :: [pid()]
  def subscribers(client_id) do
    GenStateMachine.call(via_name(client_id), :get_subscribers)
  end

  def ping(client_id) do
    pingreq = Package.encode(%Package.Pingreq{})
    GenStateMachine.cast(via_name(client_id), {:transmit, pingreq})
  end

  def cast(client_id, %{__struct__: _} = package) do
    data = Package.encode(package)
    GenStateMachine.cast(via_name(client_id), {:transmit, data})
  end

  # Server callbacks
  def init(data) do
    {:ok, :disconnected, data, []}
  end

  def handle_event({:call, from}, {:handle_socket, socket}, _, data) do
    new_state = {:connected, socket}

    next_actions = [
      {:reply, from, :ok},
      {:next_event, :internal, :broadcast_connection_to_subscribers}
    ]

    {:next_state, new_state, data, next_actions}
  end

  def handle_event(:internal, :broadcast_connection_to_subscribers, {:connected, socket}, data) do
    for {subscriber, _} <- data.subscribers do
      send_transmitter_to_subscriber(socket, subscriber)
    end

    :keep_state_and_data
  end

  def handle_event(:cast, {:transmit, package}, {:connected, socket}, _data) do
    case :gen_tcp.send(socket, package) do
      :ok ->
        :keep_state_and_data
    end
  end

  def handle_event(:cast, {:transmit, _package}, :disconnected, _data) do
    # postpone the data transmit for when we are online again
    {:keep_state_and_data, :postpone}
  end

  def handle_event({:call, {pid, _} = from}, :subscribe, _, %__MODULE__{} = data) do
    monitor_ref = Process.monitor(pid)
    next_actions = [{:reply, from, :ok}, {:next_event, :internal, {:send_socket, pid}}]
    updated_subscribers = Map.put(data.subscribers, pid, monitor_ref)
    updated_data = %__MODULE__{data | subscribers: updated_subscribers}
    {:keep_state, updated_data, next_actions}
  end

  def handle_event(:internal, {:send_socket, subscriber}, {:connected, socket}, _data) do
    send_transmitter_to_subscriber(socket, subscriber)
    :keep_state_and_data
  end

  def handle_event(:internal, {:send_socket, _subscriber}, :disconnected, _data) do
    # a connection will get broadcast when we get online
    :keep_state_and_data
  end

  def handle_event(:cast, {:unsubscribe, pid}, _, %__MODULE__{} = data) do
    {monitor_ref, updated_subscribers} = Map.pop(data.subscribers, pid)
    updated_data = %__MODULE__{data | subscribers: updated_subscribers}
    true = Process.demonitor(monitor_ref)
    {:keep_state, updated_data}
  end

  def handle_event({:call, from}, :get_subscribers, _, %__MODULE__{} = data) do
    subscribers = Map.keys(data.subscribers)
    next_action = {:reply, from, subscribers}
    {:keep_state_and_data, next_action}
  end

  def handle_event(:info, {:DOWN, ref, :process, pid, _}, _, data) do
    {^ref, updated_subscribers} = Map.pop(data.subscribers, pid)
    updated_data = %{data | subscribers: updated_subscribers}
    {:keep_state, updated_data}
  end

  defp send_transmitter_to_subscriber(socket, subscriber_pid) do
    transmitter = socket
    send(subscriber_pid, {Tortoise, {:transmitter, transmitter}})
  end
end
