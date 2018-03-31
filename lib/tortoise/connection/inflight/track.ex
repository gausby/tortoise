defmodule Tortoise.Connection.Inflight.Track do
  @moduledoc """
  A data structure implementing state machines tracking the state of a
  message in flight.

  Messages can have two polarities, positive and negative, describing
  what direction they are going. A positive polarity is messages
  coming from the server to the client (us), a negative polarity is
  messages send from the client (us) to the server.

  For now we care about tracking the state of two kinds of messages:
  the publish control package with a quality of service above 0. We do
  not track the in-flight state of a QoS 0 control packet because
  there is no state to track.

  For negative polarity we need to track the caller, which is the
  process that instantiated the publish control package. This process
  will wait for a message to get passed to it when the ownership of
  the control package has been transferred to the server. Messages
  with a positive polarity will get passed to the callback module
  attached to the Controller module, so in that case there will be no
  caller.

  ## Publish control package with QoS 1

  ## Publish control package with QoS 2
  """

  @type package_identifier :: 0x0001..0xFFFF
  @type package ::
          Package.Publish
          | Package.Puback
          | Package.Pubrec
          | Package.Pubrel
          | Package.Pubcomp

  @type caller :: {pid(), reference()}
  @type polarity :: :positive | {:negative, caller()}
  @type next_action :: {:expect, package()} | {:dispatch, package()}
  @type status_update :: {:received, package()} | {:dispatched, package()}

  @opaque t :: %__MODULE__{
            identifier: package_identifier() | nil,
            status: [status_update()],
            pending: [next_action()],
            caller: nil | {pid(), reference()}
          }
  defstruct status: [], pending: [], identifier: nil, caller: nil

  alias __MODULE__, as: State
  alias Tortoise.Package

  @spec update(__MODULE__.t(), package()) :: {next_action() | nil, __MODULE__.t()}
  # ":dispatch, ..." should be answered with ":dispatched, ..."
  def update(
        %State{identifier: identifier, pending: [{:dispatch, package} | rest]} = state,
        {:dispatched, %{identifier: identifier} = package} = status_update
      ) do
    %{state | status: [status_update | state.status], pending: rest}
  end

  # ":expect, ..." should be answered with ":received, ..."
  def update(
        %State{identifier: identifier, pending: [{:expect, package} | rest]} = state,
        {:received, %{identifier: identifier} = package} = status_update
      ) do
    %{state | status: [status_update | state.status], pending: rest}
  end

  @doc """
  Set up a data structure that will track the status of a control
  packet
  """
  @spec create(polarity(), Package.Publish.t()) :: __MODULE__.t()
  def create(:positive, %Package.Publish{qos: 1, identifier: id}) do
    %State{
      identifier: id,
      status: [{:received, Package.Publish}],
      pending: [{:dispatch, %Package.Puback{identifier: id}}]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Publish{qos: 1, identifier: id} = publish)
      when is_pid(pid) and is_reference(ref) do
    %State{
      identifier: id,
      caller: {pid, ref},
      pending: [
        {:dispatch, publish},
        {:expect, %Package.Puback{identifier: id}}
      ]
    }
  end

  def create(:positive, %Package.Publish{identifier: id, qos: 2}) do
    %State{
      identifier: id,
      status: [{:received, Package.Publish}],
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
end
