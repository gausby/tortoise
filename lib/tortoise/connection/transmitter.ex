defmodule Tortoise.Connection.Transmitter do
  @moduledoc false

  use GenStateMachine

  alias Tortoise.Package
  alias Tortoise.Connection.Transmitter.Inflight

  defstruct client_id: nil, inflight: %{}

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

  def handle_socket(client_id, socket) do
    GenStateMachine.call(via_name(client_id), {:handle_socket, socket})
  end

  def track(client_id, {:positive, %Package.Publish{} = package}) do
    GenStateMachine.cast(via_name(client_id), Inflight.track(:positive, package))
  end

  def update(client_id, %{__struct__: _, identifier: _identifier} = package) do
    GenStateMachine.cast(via_name(client_id), {:received, package})
  end

  def publish(client_id, %Package.Publish{qos: 1} = package) do
    GenStateMachine.call(via_name(client_id), {:publish, package}, :infinity)
  end

  def publish(client_id, %Package.Publish{qos: 2} = package) do
    GenStateMachine.call(via_name(client_id), {:publish, package}, :infinity)
  end

  def publish_sync(client_id, %Package.Publish{qos: 1} = package) do
    {:ok, ref} = publish(client_id, package)

    receive do
      {Tortoise, {{^client_id, ^ref}, :ok}} ->
        :ok
    end
  end

  def ping(client_id) do
    GenStateMachine.cast(via_name(client_id), :ping)
  end

  def ping_resp(client_id) do
    GenStateMachine.cast(via_name(client_id), :ping_resp)
  end

  # Server callbacks
  def init(data) do
    {:ok, :disconnected, data, []}
  end

  def handle_event({:call, from}, {:handle_socket, socket}, :disconnected, data) do
    new_state = {:connected, socket}
    next_actions = [{:reply, from, :ok}]
    {:next_state, new_state, data, next_actions}
  end

  def handle_event(
        {:call, {_, ref} = caller},
        {:publish, %Package.Publish{} = publish},
        {:connected, _socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    track = Inflight.track({:negative, caller}, publish)
    updated_inflight = Map.put_new(inflight, track.identifier, track)
    next_event = [{:reply, caller, {:ok, ref}}, {:next_event, :internal, track}]
    updated_data = %__MODULE__{data | inflight: updated_inflight}
    {:keep_state, updated_data, next_event}
  end

  def handle_event(
        :cast,
        {:received, package} = command,
        {:connected, _socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    {track, updated_inflight} =
      Map.get_and_update!(inflight, package.identifier, fn track ->
        updated_track = Inflight.update(track, command)
        {updated_track, updated_track}
      end)

    updated_data = %__MODULE__{data | inflight: updated_inflight}
    next_event = {:next_event, :internal, track}
    {:keep_state, updated_data, next_event}
  end

  def handle_event(
        :cast,
        %Inflight{pending: [_action | _]} = track,
        {:connected, _socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    updated_inflight = Map.put_new(inflight, track.identifier, track)
    next_event = {:next_event, :internal, track}
    updated_data = %__MODULE__{data | inflight: updated_inflight}
    {:keep_state, updated_data, next_event}
  end

  def handle_event(
        :internal,
        %Inflight{pending: [{:dispatch, package} | _]} = track,
        {:connected, socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    with :ok = :gen_tcp.send(socket, Package.encode(package)),
         track = Inflight.update(track, {:dispatched, package}),
         updated_inflight = Map.put(inflight, track.identifier, track),
         next_event = {:next_event, :internal, track},
         updated_data = %__MODULE__{data | inflight: updated_inflight} do
      {:keep_state, updated_data, next_event}
    end
  end

  def handle_event(
        :internal,
        %Inflight{pending: [{:expect, _package} | _]} = track,
        {:connected, _socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    updated_inflight = Map.put(inflight, track.identifier, track)
    updated_data = %__MODULE__{data | inflight: updated_inflight}
    {:keep_state, updated_data}
  end

  def handle_event(
        :internal,
        %Inflight{pending: []} = track,
        {:connected, _socket},
        %__MODULE__{inflight: inflight} = data
      ) do
    if track.caller do
      {pid, ref} = track.caller
      send(pid, {Tortoise, {{data.client_id, ref}, :ok}})
    end

    updated_inflight = Map.delete(inflight, track.identifier)
    updated_data = %__MODULE__{data | inflight: updated_inflight}
    {:keep_state, updated_data}
  end

  def handle_event(:cast, :ping, {:connected, socket}, _data) do
    pingreq = %Package.Pingreq{}
    :gen_tcp.send(socket, Package.encode(pingreq))
    :keep_state_and_data
  end

  def handle_event(:cast, :ping_resp, {:connected, socket}, _data) do
    pingresp = %Package.Pingresp{}
    :gen_tcp.send(socket, Package.encode(pingresp))
    :keep_state_and_data
  end
end
