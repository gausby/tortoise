defmodule Tortoise.Connection.Transmitter do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package

  @enforce_keys [:client_id]
  defstruct client_id: nil, subscribers: %{}, passive: []
  alias __MODULE__, as: State

  @type client_id :: pid() | term()

  # Client API
  def start_link(opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    data = %State{client_id: client_id}
    GenStateMachine.start_link(__MODULE__, data, name: via_name(client_id))
  end

  def via_name(pid) when is_pid(pid), do: pid

  def via_name(client_id) do
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

  def stop(client_id) do
    GenStateMachine.stop(via_name(client_id))
  end

  def handle_socket(client_id, socket) do
    GenStateMachine.call(via_name(client_id), {:handle_socket, socket})
  end

  def unsubscribe(client_id) do
    GenStateMachine.cast(via_name(client_id), {:unsubscribe, self()})
  end

  @doc false
  @spec subscribers(client_id()) :: [pid()]
  def subscribers(client_id) do
    GenStateMachine.call(via_name(client_id), :get_subscribers)
  end

  def get_socket(client_id, opts \\ [timeout: :infinity]) do
    active = Keyword.get(opts, :active, false)
    timeout = Keyword.get(opts, :timeout, :infinity)

    case GenStateMachine.call(via_name(client_id), {:get_socket, active}) do
      {:ok, socket} ->
        {:ok, socket}

      :pending ->
        receive do
          {{Tortoise, ^client_id}, :socket, socket} ->
            {:ok, socket}
        after
          timeout ->
            {:error, :timeout}
        end
    end
  end

  def cast(client_id, %{__struct__: _} = package) do
    data = Package.encode(package)
    GenStateMachine.cast(via_name(client_id), {:transmit, data})
  end

  # Server callbacks
  def init(data) do
    {:ok, :disconnected, data, []}
  end

  # Putting data on the wire
  def handle_event(:cast, {:transmit, package}, {:connected, socket}, data) do
    case :gen_tcp.send(socket, package) do
      :ok ->
        :keep_state_and_data

      {:error, :closed} ->
        new_state = :disconnected
        # todo, does postpone work like this?
        {:next_state, new_state, data, :postpone}
    end
  end

  def handle_event(:cast, {:transmit, _package}, :disconnected, _data) do
    # postpone the data transmit for when we are online again
    {:keep_state_and_data, :postpone}
  end

  # receiving sockets and dispatching to processes holding pipes
  # configured as "active"
  def handle_event({:call, from}, {:handle_socket, socket}, _, data) do
    new_state = {:connected, socket}

    next_actions = [
      {:reply, from, :ok},
      {:next_event, :internal, :handle_passive},
      {:next_event, :internal, :broadcast_socket}
    ]

    {:next_state, new_state, data, next_actions}
  end

  def handle_event(:internal, :broadcast_socket, {:connected, socket}, data) do
    for {subscriber, _monitor_ref} <- data.subscribers do
      send(subscriber, {{Tortoise, data.client_id}, :socket, socket})
    end

    :keep_state_and_data
  end

  # handle the socket to passive pipes
  def handle_event(:internal, :handle_passive, {:connected, _socket}, %State{passive: []}) do
    :keep_state_and_data
  end

  def handle_event(:internal, :handle_passive, {:connected, socket}, %State{} = data) do
    for pid <- data.passive do
      send(pid, {{Tortoise, data.client_id}, :socket, socket})
    end

    {:keep_state, %State{data | passive: []}}
  end

  # socket subscriptions
  def handle_event(:internal, {:add_subscriber, client_pid}, _, %State{} = data) do
    monitor_ref = Process.monitor(client_pid)
    updated_subscribers = Map.put(data.subscribers, client_pid, monitor_ref)
    {:keep_state, %State{data | subscribers: updated_subscribers}}
  end

  def handle_event(:cast, {:unsubscribe, pid}, _, %State{} = data) do
    {monitor_ref, updated_subscribers} = Map.pop(data.subscribers, pid)
    updated_data = %State{data | subscribers: updated_subscribers}
    true = Process.demonitor(monitor_ref)
    {:keep_state, updated_data}
  end

  def handle_event(:info, {:DOWN, ref, :process, pid, _}, _, data) do
    {^ref, updated_subscribers} = Map.pop(data.subscribers, pid)
    updated_data = %State{data | subscribers: updated_subscribers}
    {:keep_state, updated_data}
  end

  def handle_event({:call, from}, :get_subscribers, _, %State{} = data) do
    subscribers = Map.keys(data.subscribers)
    next_action = {:reply, from, subscribers}
    {:keep_state_and_data, next_action}
  end

  # requesting sockets
  def handle_event({:call, {pid, _} = from}, {:get_socket, true}, {:connected, socket}, %State{}) do
    next_actions = [
      {:next_event, :internal, {:add_subscriber, pid}},
      {:reply, from, {:ok, socket}}
    ]

    {:keep_state_and_data, next_actions}
  end

  def handle_event({:call, from}, {:get_socket, false}, {:connected, socket}, %State{}) do
    next_action = {:reply, from, {:ok, socket}}
    {:keep_state_and_data, next_action}
  end

  def handle_event({:call, {pid, _ref} = from}, {:get_socket, true}, :disconnected, %State{}) do
    next_actions = [
      {:next_event, :internal, {:add_subscriber, pid}},
      {:reply, from, :pending}
    ]

    {:keep_state_and_data, next_actions}
  end

  def handle_event(
        {:call, {pid, _ref} = from},
        {:get_socket, false},
        :disconnected,
        %State{} = data
      ) do
    next_action = {:reply, from, :pending}
    {:keep_state, %State{data | passive: [pid | data.passive]}, next_action}
  end
end
