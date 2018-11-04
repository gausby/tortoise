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

  @type package :: Package.Publish | Package.Subscribe | Package.Unsubscribe

  @type caller :: {pid(), reference()} | nil
  @type polarity :: :positive | {:negative, caller()}
  @type next_action :: {:dispatch | :expect, Tortoise.Encodable.t()}
  @type status_update :: {:received | :dispatched, Tortoise.Encodable.t()}

  @opaque t :: %__MODULE__{
            polarity: :positive | :negative,
            type: package,
            caller: {pid(), reference()} | nil,
            identifier: Tortoise.package_identifier(),
            status: [status_update()],
            pending: [next_action()]
          }
  @enforce_keys [:type, :identifier, :polarity, :pending]
  defstruct type: nil,
            polarity: nil,
            caller: nil,
            identifier: nil,
            status: [],
            pending: []

  alias __MODULE__, as: State
  alias Tortoise.Package

  def next(%State{pending: [[next_action, resolution] | _]}) do
    {next_action, resolution}
  end

  def resolve(%State{pending: [[action, :cleanup]]} = state, :cleanup) do
    {:ok, %State{state | pending: [], status: [action | state.status]}}
  end

  def resolve(
        %State{pending: [[action, {:received, %{__struct__: t, identifier: id}}] | rest]} = state,
        {:received, %{__struct__: t, identifier: id}} = expected
      ) do
    {:ok, %State{state | pending: rest, status: [expected, action | state.status]}}
  end

  # When we are awaiting a package to dispatch, replace the package
  # with the message given by the user; this allow us to support user
  # defined properties on packages such as pubrec, pubrel, pubcomp,
  # etc.
  def resolve(
        %State{pending: [[{:dispatch, %{__struct__: t, identifier: id}}, resolution] | rest]} =
          state,
        {:dispatch, %{__struct__: t, identifier: id}} = dispatch
      ) do
    {:ok, %State{state | pending: [[dispatch, resolution] | rest]}}
  end

  # the value has previously been received; here we should stay where
  # we are at and retry the transmission
  def resolve(
        %State{status: [{same, %{__struct__: t, identifier: id}} | _]} = state,
        {same, %{__struct__: t, identifier: id}}
      ) do
    {:ok, state}
  end

  def resolve(%State{pending: []} = state, :cleanup) do
    {:ok, state}
  end

  def resolve(%State{}, {:received, package}) do
    {:error, {:protocol_violation, {:unexpected_package_from_remote, package}}}
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
      pending: [
        [
          {:dispatch, %Package.Puback{identifier: id}},
          :cleanup
        ]
      ]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Publish{qos: 1, identifier: id} = publish)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Publish,
      polarity: :negative,
      caller: {pid, ref},
      identifier: id,
      pending: [
        [
          {:dispatch, publish},
          {:received, %Package.Puback{identifier: id}}
        ],
        [
          {:respond, {pid, ref}},
          :cleanup
        ]
      ]
    }
  end

  def create(:positive, %Package.Publish{identifier: id, qos: 2} = publish) do
    %State{
      type: Package.Publish,
      polarity: :positive,
      identifier: id,
      status: [{:received, publish}],
      pending: [
        [
          {:dispatch, %Package.Pubrec{identifier: id}},
          {:received, %Package.Pubrel{identifier: id}}
        ],
        [
          {:dispatch, %Package.Pubcomp{identifier: id}},
          :cleanup
        ]
      ]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Publish{identifier: id, qos: 2} = publish)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Publish,
      polarity: :negative,
      caller: {pid, ref},
      identifier: id,
      pending: [
        [
          {:dispatch, publish},
          {:received, %Package.Pubrec{identifier: id}}
        ],
        [
          {:dispatch, %Package.Pubrel{identifier: id}},
          {:received, %Package.Pubcomp{identifier: id}}
        ],
        [
          {:respond, {pid, ref}},
          :cleanup
        ]
      ]
    }
  end

  # subscription
  def create({:negative, {pid, ref}}, %Package.Subscribe{identifier: id} = subscribe)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Subscribe,
      polarity: :negative,
      caller: {pid, ref},
      identifier: id,
      pending: [
        [
          {:dispatch, subscribe},
          {:received, %Package.Suback{identifier: id}}
        ],
        [
          {:respond, {pid, ref}},
          :cleanup
        ]
      ]
    }
  end

  def create({:negative, {pid, ref}}, %Package.Unsubscribe{identifier: id} = unsubscribe)
      when is_pid(pid) and is_reference(ref) do
    %State{
      type: Package.Unsubscribe,
      polarity: :negative,
      caller: {pid, ref},
      identifier: id,
      pending: [
        [
          {:dispatch, unsubscribe},
          {:received, %Package.Unsuback{identifier: id}}
        ],
        [
          {:respond, {pid, ref}},
          :cleanup
        ]
      ]
    }
  end

  # calculate result
  def result(%State{type: Package.Publish}) do
    {:ok, :ok}
  end

  def result(%State{
        type: Package.Unsubscribe,
        status: [
          {:received, %Package.Unsuback{results: _results}},
          {:dispatch, %Package.Unsubscribe{topics: topics}} | _other
        ]
      }) do
    # todo, merge the unsuback results with the topic list
    {:ok, topics}
  end

  def result(%State{
        type: Package.Subscribe,
        status: [
          {:received, %Package.Suback{acks: acks}},
          {:dispatch, %Package.Subscribe{topics: topics}} | _other
        ]
      }) do
    result =
      List.zip([topics, acks])
      |> Enum.reduce(%{error: [], warn: [], ok: []}, fn
        {{topic, opts}, {:ok, actual}}, %{ok: oks, warn: warns} = acc ->
          case Keyword.get(opts, :qos) do
            ^actual ->
              %{acc | ok: oks ++ [{topic, actual}]}

            requested ->
              %{acc | warn: warns ++ [{topic, [requested: requested, accepted: actual]}]}
          end

        {{topic, opts}, {:error, reason}}, %{error: errors} = acc ->
          %{acc | error: errors ++ [{reason, {topic, opts}}]}
      end)

    {:ok, result}
  end
end
