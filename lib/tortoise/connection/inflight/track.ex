defmodule Tortoise.Connection.Inflight.Track do
  @moduledoc false

  # A data structure implementing state machines tracking the state of a
  # message in flight.

  # Messages can have two polarities, positive and negative, describing
  # what direction they are going. A positive polarity is messages
  # coming from the server to the client (us), a negative polarity is
  # messages send from the client (us) to the server.

  # For now we care about tracking the state of a handful of message
  # kinds: the publish control packages with a quality of service above
  # 0 and subscribe and unsubscribe control packages. We do not track
  # the in-flight state of a QoS 0 control packet because there is no
  # state to track.

  # For negative polarity we need to track the caller, which is the
  # process that instantiated the publish control package. This process
  # will wait for a message to get passed to it when the ownership of
  # the control package has been transferred to the server. Messages
  # with a positive polarity will get passed to the callback module
  # attached to the Controller module, so in that case there will be no
  # caller.

  @type package_identifier :: 0x0001..0xFFFF
  @type package :: Package.Publish | Package.Subscribe | Package.Unsubscribe

  @type caller :: {pid(), reference()} | nil
  @type polarity :: :positive | {:negative, caller()}
  @type next_action :: {:dispatch | :expect, Tortoise.Encodable.t()}
  @type status_update :: {:received | :dispatched, Tortoise.Encodable.t()}

  @opaque t :: %__MODULE__{
            polarity: :positive | :negative,
            type: package,
            identifier: package_identifier(),
            status: [status_update()],
            pending: [next_action()],
            caller: caller(),
            result: term() | nil
          }
  @enforce_keys [:type, :identifier, :polarity, :pending]
  defstruct type: nil,
            polarity: nil,
            identifier: nil,
            status: [],
            pending: [],
            caller: nil,
            result: nil

  alias __MODULE__, as: State
  alias Tortoise.Package

  @spec update(__MODULE__.t(), status_update()) :: __MODULE__.t()
  # ":dispatch, ..." should be answered with ":dispatched, ..."
  def update(
        %State{identifier: id, pending: [{:dispatch, package} | rest]} = state,
        {:dispatched, %{identifier: id} = package} = status_update
      ) do
    %{state | status: [status_update | state.status], pending: rest}
  end

  # ":expect, ..." should be answered with ":received, ..."
  def update(
        %State{identifier: id, pending: [{:expect, %{__struct__: t}} | rest]} = state,
        {:received, %{__struct__: t, identifier: id}} = status_update
      ) do
    case rest do
      [] ->
        finalize(%{state | status: [status_update | state.status], pending: []})

      rest ->
        %{state | status: [status_update | state.status], pending: rest}
    end
  end

  @doc """
  Roll the state back to the previous state
  """
  @spec rollback(__MODULE__.t()) :: __MODULE__.t()
  def rollback(%State{status: []} = state), do: state

  def rollback(%State{status: [previous | status], pending: pending} = state) do
    %State{state | status: status, pending: [do_rollback(previous) | pending]}
  end

  defp do_rollback({:dispatched, %Package.Publish{} = package}) do
    {:dispatch, %Package.Publish{package | dup: true}}
  end

  defp do_rollback({:dispatched, package}) do
    {:dispatch, package}
  end

  defp do_rollback({:received, package}) do
    {:expect, package}
  end

  @type trackable :: Tortoise.Encodable

  @doc """
  Set up a data structure that will track the status of a control
  packet
  """
  # @todo, enable this when I've figured out what is wrong with this spec
  # @spec create(polarity :: polarity(), package :: trackable()) :: __MODULE__.t()
  def create(:positive, %Package.Publish{qos: 1, identifier: id} = publish) do
    %State{
      type: Package.Publish,
      polarity: :positive,
      identifier: id,
      status: [{:received, publish}],
      pending: [{:dispatch, %Package.Puback{identifier: id}}]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Publish{qos: 1, identifier: id} = publish)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Publish,
      polarity: :negative,
      identifier: id,
      caller: {pid, ref},
      pending: [
        {:dispatch, publish},
        {:expect, %Package.Puback{identifier: id}}
      ]
    }
  end

  def create(:positive, %Package.Publish{identifier: id, qos: 2} = publish) do
    %State{
      type: Package.Publish,
      polarity: :positive,
      identifier: id,
      status: [{:received, publish}],
      caller: nil,
      pending: [
        {:dispatch, %Package.Pubrec{identifier: id}},
        {:expect, %Package.Pubrel{identifier: id}},
        {:dispatch, %Package.Pubcomp{identifier: id}}
      ]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Publish{identifier: id, qos: 2} = publish)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Publish,
      polarity: :negative,
      identifier: id,
      caller: {pid, ref},
      pending: [
        {:dispatch, publish},
        {:expect, %Package.Pubrec{identifier: id}},
        {:dispatch, %Package.Pubrel{identifier: id}},
        {:expect, %Package.Pubcomp{identifier: id}}
      ]
    }
  end

  # subscription
  def create({:negative, {pid, ref}}, %Package.Subscribe{identifier: id} = subscribe)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Subscribe,
      polarity: :negative,
      identifier: id,
      caller: {pid, ref},
      pending: [
        {:dispatch, subscribe},
        {:expect, %Package.Suback{identifier: id}}
      ]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Unsubscribe{identifier: id} = unsubscribe)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Unsubscribe,
      polarity: :negative,
      identifier: id,
      caller: {pid, ref},
      pending: [
        {:dispatch, unsubscribe},
        {:expect, %Package.Unsuback{identifier: id}}
      ]
    }
  end

  # Calculate a result if needed
  defp finalize(%State{type: Package.Publish} = track) do
    %State{track | result: :ok}
  end

  defp finalize(
         %State{
           type: Package.Unsubscribe,
           status: [
             {:received, _},
             {:dispatched, %Package.Unsubscribe{topics: topics}}
           ]
         } = track
       ) do
    %State{track | result: topics}
  end

  defp finalize(
         %State{
           type: Package.Subscribe,
           status: [
             {:received, %Package.Suback{acks: acks}},
             {:dispatched, %Package.Subscribe{topics: topics}}
           ]
         } = track
       ) do
    result =
      List.zip([topics, acks])
      |> Enum.reduce(%{error: [], warn: [], ok: []}, fn
        {{topic, level}, {:ok, level}}, %{ok: oks} = acc ->
          %{acc | ok: oks ++ [{topic, level}]}

        {{topic, requested}, {:ok, actual}}, %{warn: warns} = acc ->
          %{acc | warn: warns ++ [{topic, [requested: requested, accepted: actual]}]}

        {{topic, level}, {:error, :access_denied}}, %{error: errors} = acc ->
          %{acc | error: errors ++ [{:access_denied, {topic, level}}]}
      end)

    %State{track | result: result}
  end
end
